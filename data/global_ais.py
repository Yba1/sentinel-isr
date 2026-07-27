"""Zoomed-out global ship layer, plus real-world "gone dark" detection.

No synthetic traffic, ever: this module reports only what aisstream.io has
actually sent. If AISSTREAM_API_KEY is unset, unreachable, or simply hasn't
produced a fix yet, /api/global and /api/global/dark return an honestly
empty `{"live": false, "vessels": []}` rather than inventing plausible-looking
ships -- a synthetic layer that looks real is worse than no layer, because it
cannot be told apart from the real one at a glance, which is exactly the
failure mode this whole project is about *not* having.

This module never blocks the rest of the server on the real feed: run() is a
background task, snapshot() always returns immediately from whatever state
currently exists (empty until the feed has produced at least one real fix).

Dark-vessel detection (the actual "original plan")
----------------------------------------------------
Every real position report is appended to a per-MMSI history, throttled to
one stored point per HISTORY_MIN_INTERVAL_S and pruned past HISTORY_MAX_AGE_S
(24h) -- see `_History`. A vessel is "gone dark" when its last report is
older than DARK_AFTER_S but younger than HISTORY_MAX_AGE_S: AIS has stopped
in the past day, but we are not so far past it that a projection is
meaningless. `dark_snapshot()` freezes each such vessel at its last position
plus its last 30 minutes of trail; `hypothesis_paths()` then projects a small
set of kinematic scenarios (maintain course, turn either way, drift to a
stop) forward from that freeze point, with an uncertainty ellipse that grows
with time exactly like a coasting Kalman track (tracker/dark.py's model,
reused here without a live filter since there is no measurement to filter
into -- only the last reported course/speed/position and elapsed time).

This is intentionally NOT "satellite and RF fusion": there is no satellite
SAR/RF API key configured, and inventing one would be dishonest. What is
real: the AIS history is real aisstream.io traffic, the gap detection is a
real clock check against it, and the projected search region is the same
diffusion physics already used for the local scenario packs' dark-vessel
ellipses. A future satellite/RF detection would slot in exactly where
`reassociate()`-style scoring already lives in tracker/dark.py -- as another
candidate explanation competing against these kinematic hypotheses, not a
replacement for them.
"""

from __future__ import annotations

import asyncio
import json
import math
import os
import time
from pathlib import Path

import aiohttp

from data.scenario import lla_to_enu, enu_to_lla
from data.geometry import cov_ellipse_points

AISSTREAM_WS_URL = "wss://stream.aisstream.io/v0/stream"
CONNECT_TIMEOUT_S = 8.0
MAX_TRACKED = 4000  # global feed can be enormous; cap memory, evict oldest-touched

# ------------------------------------------------------------- dark detection
STATE_DIR = Path(__file__).resolve().parent.parent / ".ais_state"
HISTORY_PATH = STATE_DIR / "history.json"

HISTORY_MIN_INTERVAL_S = 20.0    # throttle: at most one stored point this often per vessel
HISTORY_MAX_AGE_S = 24 * 3600.0  # "in the past day" -- prune anything older
TRAIL_WINDOW_S = 30 * 60.0       # "last 30 minutes of its trail"
DARK_AFTER_S = float(os.environ.get("AIS_DARK_AFTER_S", 20 * 60))  # AIS silence -> "gone dark"
MIN_FIXES_FOR_DARK = 2  # need an established track, not a single connection-burst ping
SAVE_INTERVAL_S = 30.0

# Kinematic-projection constants. tracker/dark.py's cubic diffusion (P grows
# as q*T^3/3) is calibrated for a Kalman filter coasting for *minutes* on a
# 10s radar cadence; a global AIS gap runs tens of minutes to hours, and that
# same formula over hours produces a thousand-kilometre ellipse -- correct
# for "a random-walk acceleration integrated that long", wrong for "a ship
# holding a heading with some speed/heading error". This projection instead
# uses a dead-reckoning drift model: error grows with DISTANCE travelled
# (along-track more than cross-track, since speed is usually known better
# than heading holds), plus an isotropic term for unmodelled ocean current
# drift that accrues with time regardless of the hypothesis' own speed.
PROJ_SIGMA0_M = 30.0        # m, last-known-fix position uncertainty (typical AIS GPS)
PROJ_ALONG_FRAC = 0.15      # dead-reckoning along-track error, fraction of distance run
PROJ_CROSS_FRAC = 0.07      # cross-track error (heading holds better than speed estimate)
PROJ_CURRENT_MPS = 0.4      # ~0.8 kn nominal, unmodelled surface current drift
HYPOTHESIS_TURNS_DEG = [0.0, 35.0, -35.0]  # maintain course, turn hard right/left
DRIFT_SPEED_FRAC = 0.15  # "stopped/drifting" hypothesis: this fraction of last speed

# A position report's own COG/SOG fields are frequently absent from the
# subset of message types aisstream forwards (only PositionReport carries
# them); when absent this module previously defaulted to 0.0, which looks
# identical to "genuinely stationary, heading due north" and made every such
# vessel's hypotheses collapse onto the same non-moving point. Real course
# and speed are derived instead from the vessel's own observed displacement
# over its last KINEMATICS_WINDOW_S of history -- what it actually did, not
# what one message happened to self-report.
KINEMATICS_WINDOW_S = 300.0
KINEMATICS_MIN_DISPLACEMENT_M = 60.0  # below this, movement is GPS noise, not real motion


def derive_kinematics(fixes: list[dict]) -> tuple[float, float, str]:
    """Course and speed from a vessel's own observed track, not its
    self-reported COG/SOG -- consistent with this project's rule that
    identity/self-report is never trusted where kinematics can answer the
    same question. Returns (course_deg, speed_kn, source), where source is
    "track" (derived from real displacement), "stationary" (displacement
    below GPS noise floor -- genuinely not moving, not "unknown"), or
    "reported" (fewer than 2 fixes span enough time; falls back to the
    last message's own field rather than fabricating a bearing from noise).
    """
    last = fixes[-1]
    window_start = last["ts"] - KINEMATICS_WINDOW_S
    base = fixes[0]
    for f in fixes:
        if f["ts"] >= window_start:
            base = f
            break
    dt = last["ts"] - base["ts"]
    if dt < 5.0:
        return last.get("course", 0.0), last.get("speed_kn", 0.0), "reported"

    dx, dy = lla_to_enu(last["lat"], last["lon"], base["lat"], base["lon"])
    dist_m = math.hypot(dx, dy)
    if dist_m < KINEMATICS_MIN_DISPLACEMENT_M:
        return last.get("course", 0.0), 0.0, "stationary"

    course = math.degrees(math.atan2(dx, dy)) % 360.0
    speed_kn = (dist_m / dt) * 1.943844
    return course, speed_kn, "track"


# --------------------------------------------------------------- persistence

class _History:
    """Per-MMSI fix history: throttled writes, time-pruned, disk-backed so
    "gone dark in the past day" survives a server restart -- the whole point
    of the feature is a gap measured in real wall-clock time, which a
    process that only remembers since it last booted cannot honestly claim.
    """

    def __init__(self, path: Path):
        self.path = path
        self.by_mmsi: dict[int, list[dict]] = {}
        self._dirty = False
        self._last_saved = 0.0
        self._load()

    def _load(self) -> None:
        if not self.path.is_file():
            return
        try:
            raw = json.loads(self.path.read_text())
        except (json.JSONDecodeError, OSError):
            return
        now = time.time()
        for mmsi_str, fixes in raw.items():
            try:
                mmsi = int(mmsi_str)
            except ValueError:
                continue
            kept = [f for f in fixes if now - f.get("ts", 0) <= HISTORY_MAX_AGE_S]
            if kept:
                self.by_mmsi[mmsi] = kept

    def save(self, force: bool = False) -> None:
        now = time.time()
        if not force and (not self._dirty or now - self._last_saved < SAVE_INTERVAL_S):
            return
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_suffix(".json.tmp")
        payload = {str(mmsi): fixes for mmsi, fixes in self.by_mmsi.items()}
        tmp.write_text(json.dumps(payload))
        tmp.replace(self.path)  # atomic on POSIX: never a half-written history file
        self._dirty = False
        self._last_saved = now

    def record(self, mmsi: int, fix: dict, ts: float) -> None:
        fixes = self.by_mmsi.setdefault(mmsi, [])
        if fixes and ts - fixes[-1]["ts"] < HISTORY_MIN_INTERVAL_S:
            return  # throttled: this vessel already has a recent-enough point
        fixes.append({
            "ts": ts, "lat": fix["lat"], "lon": fix["lon"],
            "course": fix.get("course", 0.0), "speed_kn": fix.get("speed_kn", 0.0),
        })
        cutoff = ts - HISTORY_MAX_AGE_S
        while fixes and fixes[0]["ts"] < cutoff:
            fixes.pop(0)
        if not fixes:
            self.by_mmsi.pop(mmsi, None)
        self._dirty = True

    def dark_vessels(self, now: float, names: dict[int, str]) -> list[dict]:
        """Every MMSI whose newest fix is older than DARK_AFTER_S but still
        inside the HISTORY_MAX_AGE_S window -- AIS stopped, in the past day.

        Requires at least MIN_FIXES_FOR_DARK observed fixes first. A single
        ping (typical of the burst of traffic a fresh connection receives at
        startup) establishes nothing about a vessel's normal reporting
        cadence; treating it as "gone dark" the moment it ages past
        DARK_AFTER_S would flag most of a cold start's one-off contacts as
        dark, which is a startup artifact, not a real gap.
        """
        out = []
        for mmsi, fixes in self.by_mmsi.items():
            if len(fixes) < MIN_FIXES_FOR_DARK:
                continue
            last = fixes[-1]
            gap = now - last["ts"]
            if gap < DARK_AFTER_S or gap > HISTORY_MAX_AGE_S:
                continue
            trail_cutoff = last["ts"] - TRAIL_WINDOW_S
            trail = [f for f in fixes if f["ts"] >= trail_cutoff]
            course, speed_kn, source = derive_kinematics(fixes)
            out.append({
                "mmsi": mmsi,
                "name": names.get(mmsi, f"MMSI {mmsi}"),
                "last_lat": last["lat"], "last_lon": last["lon"],
                "last_course": course, "last_speed_kn": speed_kn,
                "kinematics_source": source,
                "last_seen_ts": last["ts"], "dark_s": gap,
                "trail": [[f["lat"], f["lon"], f["ts"]] for f in trail],
            })
        out.sort(key=lambda v: v["dark_s"])
        return out

    def get(self, mmsi: int) -> list[dict] | None:
        return self.by_mmsi.get(mmsi)


# ------------------------------------------------------------------- real feed

class GlobalAisFeed:
    """Background aisstream.io consumer. `run()` is started once as an
    asyncio task at server startup and never returns except on cancellation;
    reconnects with backoff on any failure. `live` only ever flips True after
    a real position report has actually been parsed -- never on connection
    open alone, so a server that connects but gets no traffic still reports
    itself honestly as not-yet-live."""

    def __init__(self, api_key: str):
        self.api_key = api_key
        self.vessels: dict[int, dict] = {}
        self.names: dict[int, str] = {}
        self.live = False
        self._touch_order: list[int] = []
        self.history = _History(HISTORY_PATH)

    def _record(self, mmsi: int, fix: dict) -> None:
        if mmsi not in self.vessels and len(self.vessels) >= MAX_TRACKED:
            oldest = self._touch_order.pop(0)
            self.vessels.pop(oldest, None)
        if mmsi in self._touch_order:
            self._touch_order.remove(mmsi)
        self._touch_order.append(mmsi)
        self.vessels[mmsi] = fix
        self.live = True
        if fix.get("name"):
            self.names[mmsi] = fix["name"]
        now = time.time()
        self.history.record(mmsi, fix, now)
        self.history.save()

    def dark_snapshot(self, now: float | None = None) -> list[dict]:
        return self.history.dark_vessels(now if now is not None else time.time(), self.names)

    def _handle_message(self, raw) -> None:
        # aisstream.io sends its JSON payloads as BINARY websocket frames
        # (confirmed empirically -- msg.type is WSMsgType.BINARY, not TEXT,
        # even though the payload itself is plain JSON text), so `raw` may
        # be str or bytes depending on which frame type carried it.
        if isinstance(raw, (bytes, bytearray)):
            raw = raw.decode("utf-8")
        data = json.loads(raw)
        meta = data.get("MetaData") or {}
        mmsi = meta.get("MMSI")
        lat = meta.get("latitude")
        lon = meta.get("longitude")
        if mmsi is None or lat is None or lon is None:
            report = (data.get("Message") or {}).get("PositionReport") or {}
            lat = lat if lat is not None else report.get("Latitude")
            lon = lon if lon is not None else report.get("Longitude")
        if mmsi is None or lat is None or lon is None:
            return
        report = (data.get("Message") or {}).get("PositionReport") or {}
        self._record(int(mmsi), {
            "mmsi": int(mmsi),
            "name": meta.get("ShipName", "").strip() or f"MMSI {mmsi}",
            "lat": round(float(lat), 4),
            "lon": round(float(lon), 4),
            "course": report.get("Cog", 0.0),
            "speed_kn": report.get("Sog", 0.0),
        })

    async def run(self) -> None:
        backoff = 2.0
        while True:
            try:
                async with aiohttp.ClientSession() as session:
                    async with session.ws_connect(AISSTREAM_WS_URL) as ws:
                        # NOT the whole planet: a global bbox floods this
                        # process with the full worldwide AIS message rate
                        # (thousands/sec), which is enough synchronous JSON
                        # parsing to starve the asyncio loop and make the
                        # HTTP server itself stop responding. A handful of
                        # busy regional boxes gives genuinely live, real,
                        # moving multi-continent traffic at a volume this
                        # single process can parse without blocking.
                        await ws.send_str(json.dumps({
                            "APIKey": self.api_key,
                            "BoundingBoxes": [
                                [[35, -10], [65, 30]],      # North Sea / Western Europe
                                [[20, 100], [45, 145]],     # East Asia / Sea of Japan
                                [[-40, 110], [-10, 155]],   # Australia east coast
                                [[25, -95], [45, -65]],     # US East Coast / Gulf
                                [[-10, -50], [15, -30]],    # Brazil coast
                            ],
                        }))
                        backoff = 2.0
                        async for msg in ws:
                            if msg.type in (aiohttp.WSMsgType.TEXT, aiohttp.WSMsgType.BINARY):
                                try:
                                    self._handle_message(msg.data)
                                except (ValueError, TypeError, KeyError, UnicodeDecodeError):
                                    continue
                            elif msg.type in (aiohttp.WSMsgType.ERROR, aiohttp.WSMsgType.CLOSE, aiohttp.WSMsgType.CLOSED):
                                break
            except asyncio.CancelledError:
                raise
            except Exception:
                pass
            await asyncio.sleep(backoff)
            backoff = min(backoff * 2, 60.0)

    def snapshot(self) -> list[dict]:
        return list(self.vessels.values())


def global_snapshot(feed: "GlobalAisFeed | None") -> dict:
    """What /api/global returns: exactly what the real feed has, nothing
    invented. Empty and live=false until aisstream.io produces a first fix."""
    if feed is not None and feed.live and feed.vessels:
        return {"live": True, "vessels": feed.snapshot()}
    return {"live": False, "vessels": []}


def dark_snapshot(feed: "GlobalAisFeed | None") -> dict:
    """What /api/global/dark returns: real gone-dark vessels from the live
    feed's own history, or an honest empty list before any real gap has
    accumulated -- see DARK_AFTER_S."""
    if feed is None:
        return {"live": False, "vessels": []}
    return {"live": feed.live, "vessels": feed.dark_snapshot()}


# --------------------------------------------------- kinematic hypotheses
# "The animation of the scenarios it could have gone": constant-velocity
# projection along a handful of plausible headings, each with an uncertainty
# ellipse that grows with elapsed dark time using the same diffusion model as
# a coasting Kalman filter (tracker/dark.py) -- reimplemented here in closed
# form because there is no live filter object for a vessel we never had
# under track, only its last reported course/speed/position.

K_SIGMA = 2.0  # 2-sigma / ~95% confidence region, matching tracker/dark.py's display constant


def _hypothesis_frames(lat0: float, lon0: float, course_deg: float, speed_kn: float,
                       dark_s: float, horizon_s: float, steps: int) -> list[dict]:
    """Frames span t = dark_s .. dark_s + horizon_s, i.e. from RIGHT NOW
    (the vessel has already been dark for dark_s seconds, and its search
    region has already grown that much) forward through the projection
    horizon. Starting the clock at 0 here would understate every already-
    dark vessel's current uncertainty by exactly how long it's been dark."""
    speed_mps = speed_kn * 0.5144444
    heading = math.radians(course_deg)
    # ENU: x=east, y=north. u = along-track unit vector, v = cross-track (rotate u by 90).
    ux, uy = math.sin(heading), math.cos(heading)
    vx, vy = uy, -ux
    frames = []
    for i in range(steps):
        t = dark_s + horizon_s * i / max(steps - 1, 1)
        dist = speed_mps * t
        x, y = ux * dist, uy * dist

        current_term = PROJ_CURRENT_MPS * t
        sigma_along = math.sqrt(PROJ_SIGMA0_M ** 2 + (PROJ_ALONG_FRAC * dist) ** 2 + current_term ** 2)
        sigma_cross = math.sqrt(PROJ_SIGMA0_M ** 2 + (PROJ_CROSS_FRAC * dist) ** 2 + current_term ** 2)

        # Covariance of (sigma_along^2 in the u direction, sigma_cross^2 in v)
        # expressed back in the ENU x/y basis.
        p00 = sigma_along ** 2 * ux ** 2 + sigma_cross ** 2 * vx ** 2
        p11 = sigma_along ** 2 * uy ** 2 + sigma_cross ** 2 * vy ** 2
        p01 = sigma_along ** 2 * ux * uy + sigma_cross ** 2 * vx * vy

        ring_enu = cov_ellipse_points(x, y, p00, p01, p11, k_sigma=K_SIGMA, n_points=24)
        lat, lon = enu_to_lla(x, y, lat0, lon0)
        ellipse = [list(enu_to_lla(px, py, lat0, lon0)) for px, py in ring_enu]
        # Equivalent-circle radius of the 2-sigma ellipse, for a single
        # readable number: geometric mean of the semi-axes preserves area.
        radius_km = K_SIGMA * math.sqrt(sigma_along * sigma_cross) / 1000.0
        frames.append({
            "t": round(t, 1), "lat": round(lat, 5), "lon": round(lon, 5), "ellipse": ellipse,
            "distance_km": round(dist / 1000.0, 2), "radius_km": round(radius_km, 2),
        })
    return frames


def hypothesis_paths(feed: "GlobalAisFeed | None", mmsi: int,
                     horizon_s: float | None = None, steps: int = 20) -> dict | None:
    """Kinematic "where could it have gone" projection for one real dark
    vessel. Returns None if `mmsi` is not currently a gone-dark vessel in the
    live feed's history -- a genuinely unknown id, which is a 404 upstream.
    """
    origin = None
    if feed is not None:
        for v in feed.dark_snapshot():
            if v["mmsi"] == mmsi:
                origin = v
                break
    if origin is None:
        return None

    dark_s = origin["dark_s"]
    if horizon_s is None:
        horizon_s = max(3.0 * dark_s, 3600.0)  # project at least as far as it's already been dark

    def _build(label: str, course_deg: float, speed_kn: float) -> dict:
        frames = _hypothesis_frames(origin["last_lat"], origin["last_lon"], course_deg, speed_kn,
                                    dark_s, horizon_s, steps)
        return {
            "label": label, "course_deg": course_deg, "speed_kn": speed_kn, "frames": frames,
            "radius_km_now": frames[0]["radius_km"], "radius_km_horizon": frames[-1]["radius_km"],
            "distance_km_now": frames[0]["distance_km"], "distance_km_horizon": frames[-1]["distance_km"],
        }

    hypotheses = []
    for turn in HYPOTHESIS_TURNS_DEG:
        label = "MAINTAIN COURSE" if turn == 0.0 else f"TURN {'+' if turn > 0 else ''}{turn:.0f}\u00b0"
        hypotheses.append(_build(label, (origin["last_course"] + turn) % 360.0, origin["last_speed_kn"]))
    hypotheses.append(_build("ENGINE STOP / DRIFT", origin["last_course"], origin["last_speed_kn"] * DRIFT_SPEED_FRAC))

    return {
        "mmsi": mmsi, "name": origin["name"],
        "origin": {"lat": origin["last_lat"], "lon": origin["last_lon"],
                   "ts": origin["last_seen_ts"], "course": origin["last_course"],
                   "speed_kn": origin["last_speed_kn"],
                   "kinematics_source": origin.get("kinematics_source", "reported")},
        "dark_s": dark_s, "horizon_s": horizon_s,
        "note": "kinematic projection only -- no satellite/RF detection feed configured",
        "hypotheses": hypotheses,
    }
