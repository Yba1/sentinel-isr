"""Sentinel-ISR web server: precomputed replay, REST transport, WS stream.

Not part of the frontend deliverable (web/index.html, app.js, style.css) --
this is the minimum backend those files need to exist against. It runs the
exact Jac pipeline (jac/main.jac's walker sequence) once at startup, caches
every frame's render-ready delta, and then just plays the cache back. That is
what makes "scrubbing instant" true: a seek is an array index, never a
re-run of the tracker.

Identity discipline continues past the tracker boundary: the id-switch
counter is computed here from ground truth (tracker.metrics), because the
frontend must never see which track_id belongs to which vessel -- only the
scalar count crosses the wire.
"""

from __future__ import annotations

import asyncio
import json
import os
import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

import numpy as np
from aiohttp import web, WSMsgType

import jaclang  # noqa: F401  -- registers the .jac import hook

from data.scenario import load_scenario
from jac.graph import build_mission
from jac.main import run_frame_scored
from tracker.metrics import TrackingMetrics

HISTORY_CAP = 150  # log/alert lines sent on a sync; the rail is a scroller, not an archive


# --------------------------------------------------------------------- precompute

def precompute(pack_id: str, max_frames: int = -1) -> dict:
    """Run the full Jac pipeline once and cache everything the server needs.

    Returns a dict with the per-frame delta cache plus flat, prefix-summed
    log/alert history so a seek can slice "everything up to here" in O(1)
    lookup + O(k) slice, never by re-deriving it.
    """
    scenario = load_scenario(pack_id)
    mission = build_mission(scenario)
    mission.meta["rng"] = np.random.default_rng(
        int(scenario.expected.get("seed", 0)) + 20260726 + 1
    )
    metrics = TrackingMetrics()

    frames = []
    all_log: list[str] = []
    all_alerts: list[dict] = []
    log_end: list[int] = []
    alert_end: list[int] = []

    for frame in scenario.frames:
        if max_frames >= 0 and frame.idx >= max_frames:
            break
        delta, pairs = run_frame_scored(mission, scenario, frame)
        metrics.update(pairs)
        delta["id_switches"] = metrics.id_switches

        all_log.extend(delta["log"])
        all_alerts.extend(delta["alerts"])
        log_end.append(len(all_log))
        alert_end.append(len(all_alerts))
        frames.append(delta)

    return {
        "pack_id": scenario.pack_id,
        "frame_interval_s": scenario.frame_interval_s,
        "zones": frames[0]["zones"] if frames else [],
        "frames": frames,
        "all_log": all_log,
        "all_alerts": all_alerts,
        "log_end": log_end,
        "alert_end": alert_end,
        "expected": scenario.expected,
    }


def history_for(cache: dict, frame_idx: int) -> tuple[list[str], list[dict]]:
    log_upto = cache["log_end"][frame_idx]
    alert_upto = cache["alert_end"][frame_idx]
    log = cache["all_log"][max(0, log_upto - HISTORY_CAP):log_upto]
    alerts = cache["all_alerts"][max(0, alert_upto - HISTORY_CAP):alert_upto]
    return log, alerts


# ------------------------------------------------------------------- playback

def build_app(cache: dict) -> web.Application:
    app = web.Application()
    n = len(cache["frames"])
    app["cache"] = cache
    app["state"] = {"frame_idx": 0, "playing": False, "speed": 10.0}
    app["clients"] = set()
    app["n_frames"] = n

    async def broadcast(message: dict) -> None:
        dead = set()
        payload = json.dumps(message)
        for ws in app["clients"]:
            try:
                await ws.send_str(payload)
            except ConnectionResetError:
                dead.add(ws)
        app["clients"] -= dead

    app["broadcast"] = broadcast

    async def broadcast_state() -> None:
        await broadcast({"type": "state", **app["state"]})

    async def broadcast_sync(frame_idx: int) -> None:
        log, alerts = history_for(cache, frame_idx)
        await broadcast({
            "type": "sync",
            **cache["frames"][frame_idx],
            "history_log": log,
            "history_alerts": alerts,
            **app["state"],
        })

    app["broadcast_state"] = broadcast_state
    app["broadcast_sync"] = broadcast_sync

    async def player_loop(app: web.Application) -> None:
        state = app["state"]
        interval_s = cache["frame_interval_s"]
        while True:
            if state["playing"] and state["frame_idx"] < n - 1:
                await asyncio.sleep(interval_s / max(state["speed"], 1e-3))
                if not state["playing"]:
                    continue  # paused mid-sleep
                state["frame_idx"] += 1
                await app["broadcast"]({
                    "type": "frame",
                    **cache["frames"][state["frame_idx"]],
                    "playing": state["playing"],
                    "speed": state["speed"],
                })
                if state["frame_idx"] >= n - 1:
                    state["playing"] = False
                    await app["broadcast_state"]()
            else:
                await asyncio.sleep(0.05)

    async def start_player(app: web.Application) -> None:
        app["player_task"] = asyncio.create_task(player_loop(app))

    app.on_startup.append(start_player)

    # ------------------------------------------------------------------ REST

    async def api_scenario(request: web.Request) -> web.Response:
        return web.json_response({
            "pack_id": cache["pack_id"],
            "frame_interval_s": cache["frame_interval_s"],
            "total_frames": n,
            "zones": cache["zones"],
            "expected": cache["expected"],
        })

    async def api_state(request: web.Request) -> web.Response:
        return web.json_response({"total_frames": n, **app["state"]})

    async def api_play(request: web.Request) -> web.Response:
        body = await _body(request)
        state = app["state"]
        if "speed" in body:
            state["speed"] = max(float(body["speed"]), 0.1)
        if state["frame_idx"] >= n - 1:
            state["frame_idx"] = 0  # replaying past the end restarts
        state["playing"] = True
        await app["broadcast_state"]()
        return web.json_response(state)

    async def api_pause(request: web.Request) -> web.Response:
        app["state"]["playing"] = False
        await app["broadcast_state"]()
        return web.json_response(app["state"])

    async def api_speed(request: web.Request) -> web.Response:
        body = await _body(request)
        app["state"]["speed"] = max(float(body.get("speed", 1.0)), 0.1)
        await app["broadcast_state"]()
        return web.json_response(app["state"])

    async def api_seek(request: web.Request) -> web.Response:
        body = await _body(request)
        frame = max(0, min(n - 1, int(body.get("frame", 0))))
        app["state"]["frame_idx"] = frame
        await app["broadcast_sync"](frame)
        return web.json_response(app["state"])

    async def api_reset(request: web.Request) -> web.Response:
        app["state"]["frame_idx"] = 0
        app["state"]["playing"] = False
        await app["broadcast_sync"](0)
        return web.json_response(app["state"])

    app.router.add_get("/api/scenario", api_scenario)
    app.router.add_get("/api/state", api_state)
    app.router.add_post("/api/play", api_play)
    app.router.add_post("/api/pause", api_pause)
    app.router.add_post("/api/speed", api_speed)
    app.router.add_post("/api/seek", api_seek)
    app.router.add_post("/api/reset", api_reset)

    # -------------------------------------------------------------------- WS

    async def ws_handler(request: web.Request) -> web.WebSocketResponse:
        ws = web.WebSocketResponse(heartbeat=20.0)
        await ws.prepare(request)
        app["clients"].add(ws)

        await ws.send_str(json.dumps({
            "type": "init",
            "pack_id": cache["pack_id"],
            "frame_interval_s": cache["frame_interval_s"],
            "total_frames": n,
            "zones": cache["zones"],
        }))
        frame_idx = app["state"]["frame_idx"]
        log, alerts = history_for(cache, frame_idx)
        await ws.send_str(json.dumps({
            "type": "sync",
            **cache["frames"][frame_idx],
            "history_log": log,
            "history_alerts": alerts,
            **app["state"],
        }))

        try:
            async for msg in ws:
                if msg.type == WSMsgType.ERROR:
                    break
        finally:
            app["clients"].discard(ws)
        return ws

    app.router.add_get("/ws", ws_handler)

    # ---------------------------------------------------------------- static

    web_dir = Path(__file__).resolve().parent
    app.router.add_get("/", lambda r: web.FileResponse(web_dir / "index.html"))
    app.router.add_static("/", web_dir, show_index=False)

    return app


async def _body(request: web.Request) -> dict:
    if request.can_read_body:
        try:
            return await request.json()
        except json.JSONDecodeError:
            return {}
    return {}


def main() -> None:
    # Matches jac/main.jac's default: synthetic pack for a sub-second boot.
    # SENTINEL_PACK=s01_dark_in_sanctuary exercises the acceptance criteria
    # (40+ live tracks) but costs ~2-3 minutes of precompute at startup --
    # that's the whole tracker pipeline running once, not a demo-time cost.
    pack_id = os.environ.get("SENTINEL_PACK", "s02_synthetic_demo")
    max_frames = int(os.environ.get("SENTINEL_FRAMES", "-1"))
    port = int(os.environ.get("PORT", "8765"))

    print(f"[server] precomputing {pack_id} ...", flush=True)
    t0 = time.perf_counter()
    cache = precompute(pack_id, max_frames)
    n = len(cache["frames"])
    print(
        f"[server] cached {n} frames in {time.perf_counter() - t0:.1f}s "
        f"(id_switches so far: {cache['frames'][-1]['id_switches'] if n else 0})",
        flush=True,
    )

    app = build_app(cache)
    web.run_app(app, host="0.0.0.0", port=port)


if __name__ == "__main__":
    main()
