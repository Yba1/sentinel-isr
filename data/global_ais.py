"""Zoomed-out global ship layer.

Two tiers, and the dashboard is told honestly which one it is getting:

  REAL  -- a live websocket feed from aisstream.io (global, free-tier AIS
           receiver network), if AISSTREAM_API_KEY is set in the environment
           (or a local, gitignored .env file) AND the connection actually
           produces at least one real position report within CONNECT_TIMEOUT_S.
  DEMO  -- a small set of procedurally-generated vessels moving along real
           major shipping lanes (great-circle-ish waypoint routes), used the
           moment the real feed is unset, unreachable, or still connecting.

This module never blocks the rest of the server on the real feed: run() is a
background task, snapshot() always returns immediately from whatever state
currently exists (empty at first tick, demo a moment later if the real feed
hasn't produced anything yet, real once it has).
"""

from __future__ import annotations

import asyncio
import json
import math
import time

import aiohttp

from data.maritime_context import maritime_context

AISSTREAM_WS_URL = "wss://stream.aisstream.io/v0/stream"
CONNECT_TIMEOUT_S = 8.0
MAX_TRACKED = 4000  # global feed can be enormous; cap memory, evict oldest-touched
DARK_AFTER_S = 45.0  # no fresh position report: render as a coasting contact
MAX_HISTORY = 20

# Busy maritime regions across every inhabited continent. A single world box
# can deliver thousands of messages per second and starve the API server; these
# boxes retain global operational coverage while keeping one process responsive.
REGIONAL_BOXES = [
    [[35, -10], [65, 30]],       # North Sea / Western Europe
    [[20, 100], [45, 145]],      # East Asia / Sea of Japan
    [[-40, 110], [-10, 155]],    # Australia
    [[25, -100], [50, -60]],     # US East Coast / Gulf / Great Lakes
    [[30, -130], [55, -115]],    # US and Canada West Coast
    [[-10, -55], [15, -30]],     # Brazil and tropical Atlantic
    [[25, -10], [45, 40]],       # Mediterranean
    [[5, 40], [30, 80]],         # Red Sea / Persian Gulf / India
    [[-10, 90], [20, 125]],      # Malacca / Indonesia
    [[-40, 10], [-20, 45]],      # Southern Africa
]

# ---------------------------------------------------------------- demo lanes
# A handful of real major shipping lanes (waypoint pairs, lon/lat), walked at
# a plausible cargo-ship speed. This is NOT real traffic and is always
# reported with live=False -- see server.py's /api/global.
_LANES = [
    ("SHANGHAI-LA", [(121.8, 31.2), (139.7, 35.4), (-157.9, 21.3), (-118.2, 33.7)]),
    ("SUEZ", [(103.8, 1.3), (80.0, 6.0), (43.3, 12.6), (32.3, 29.9), (-5.4, 36.1)]),
    ("ROTTERDAM-NY", [(4.5, 51.9), (-5.9, 49.7), (-40.0, 45.0), (-74.0, 40.7)]),
    ("PANAMA", [(-79.5, 8.9), (-90.0, 15.0), (-118.2, 33.7)]),
    ("STRAIT-OF-MALACCA", [(80.3, 6.0), (98.0, 5.5), (103.8, 1.3), (114.2, 22.3)]),
]
_DEMO_SPEED_DEG_PER_S = 0.0009  # ~ a cargo ship's degrees/second at cruise


def _demo_snapshot(n_per_lane: int = 6) -> list[dict]:
    """Deterministic-shape, time-driven synthetic global traffic. Positions
    are a function of wall-clock time and lane index only -- no state to
    carry between calls, so this needs no reset() and cannot leak across a
    server restart."""
    now = time.time()
    out = []
    mmsi = 900000000
    for lane_idx, (name, waypoints) in enumerate(_LANES):
        for k in range(n_per_lane):
            phase = (now * _DEMO_SPEED_DEG_PER_S + k * 7.0 + lane_idx * 3.0)
            seg_count = len(waypoints) - 1
            total = phase % seg_count
            seg = int(total)
            frac = total - seg
            (lon0, lat0), (lon1, lat1) = waypoints[seg], waypoints[(seg + 1) % len(waypoints)]
            lon = lon0 + (lon1 - lon0) * frac
            lat = lat0 + (lat1 - lat0) * frac
            course = math.degrees(math.atan2(lon1 - lon0, lat1 - lat0)) % 360
            age_s = 120.0 if k % 3 == 1 else 0.0
            out.append({
                "mmsi": mmsi + lane_idx * 1000 + k,
                "name": f"{name}-{k}",
                "lat": round(lat, 3),
                "lon": round(lon, 3),
                "course": round(course, 1),
                "speed_kn": 18.0,
                "ship_type": "Cargo",
                "destination": name.split("-")[-1],
                "last_seen": now - age_s,
                "age_s": age_s,
                "dark": age_s >= DARK_AFTER_S,
                "history": [],
            })
    return out


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
        self.live = False
        self._touch_order: list[int] = []
        self.connected = False
        self.messages_received = 0
        self.position_reports = 0
        self.static_reports = 0
        self.reconnects = 0
        self.last_message_at = 0.0
        self.last_error = ""

    def _record(self, mmsi: int, fix: dict) -> None:
        if mmsi not in self.vessels and len(self.vessels) >= MAX_TRACKED:
            oldest = self._touch_order.pop(0)
            self.vessels.pop(oldest, None)
        if mmsi in self._touch_order:
            self._touch_order.remove(mmsi)
        self._touch_order.append(mmsi)
        previous = self.vessels.get(mmsi, {})
        history = list(previous.get("history", []))
        if "lat" in fix and "lon" in fix:
            point = [float(fix["lat"]), float(fix["lon"])]
            if not history or history[-1] != point:
                history.append(point)
                history = history[-MAX_HISTORY:]
        self.vessels[mmsi] = {
            **previous,
            **fix,
            "mmsi": mmsi,
            "history": history,
            "last_seen": time.time(),
        }
        self.live = True

    def _record_static(self, mmsi: int, values: dict) -> None:
        if mmsi not in self.vessels and len(self.vessels) >= MAX_TRACKED:
            return
        previous = self.vessels.get(mmsi, {"mmsi": mmsi, "history": []})
        self.vessels[mmsi] = {**previous, **values}

    @staticmethod
    def _first(mapping: dict, *names: str, default=None):
        for name in names:
            value = mapping.get(name)
            if value not in (None, ""):
                return value
        return default

    def _handle_message(self, raw) -> None:
        # aisstream.io sends its JSON payloads as BINARY websocket frames
        # (confirmed empirically -- msg.type is WSMsgType.BINARY, not TEXT,
        # even though the payload itself is plain JSON text), so `raw` may
        # be str or bytes depending on which frame type carried it.
        if isinstance(raw, (bytes, bytearray)):
            raw = raw.decode("utf-8")
        data = json.loads(raw)
        self.messages_received += 1
        self.last_message_at = time.time()
        meta = data.get("MetaData") or {}
        message_type = data.get("MessageType", "")
        message = data.get("Message") or {}
        mmsi = self._first(meta, "MMSI", "Mmsi")

        if message_type in ("ShipStaticData", "StaticDataReport"):
            static = message.get(message_type) or {}
            mmsi = self._first(
                meta,
                "MMSI",
                "Mmsi",
                default=self._first(static, "UserID", "UserId"),
            )
            if mmsi is None:
                return
            self._record_static(int(mmsi), {
                "name": str(
                    self._first(
                        static,
                        "Name",
                        "ShipName",
                        default=meta.get("ShipName", ""),
                    )
                ).strip(),
                "imo": self._first(static, "ImoNumber", "IMONumber", "Imo"),
                "call_sign": str(
                    self._first(static, "CallSign", "Callsign", default="")
                ).strip(),
                "ship_type": self._first(static, "Type", "ShipType", default=""),
                "destination": str(static.get("Destination", "")).strip(),
                "draught_m": self._first(
                    static, "MaximumStaticDraught", "Draught", default=0.0
                ),
            })
            self.static_reports += 1
            return

        lat = meta.get("latitude")
        lon = meta.get("longitude")
        if mmsi is None or lat is None or lon is None:
            report = (
                message.get("PositionReport")
                or message.get("StandardClassBPositionReport")
                or {}
            )
            lat = lat if lat is not None else report.get("Latitude")
            lon = lon if lon is not None else report.get("Longitude")
        if mmsi is None or lat is None or lon is None:
            return
        report = (
            message.get("PositionReport")
            or message.get("StandardClassBPositionReport")
            or {}
        )
        self._record(int(mmsi), {
            "mmsi": int(mmsi),
            "name": (
                meta.get("ShipName", "").strip()
                or self.vessels.get(int(mmsi), {}).get("name")
                or f"MMSI {mmsi}"
            ),
            "lat": round(float(lat), 4),
            "lon": round(float(lon), 4),
            "course": report.get("Cog", 0.0),
            "speed_kn": report.get("Sog", 0.0),
            "heading": report.get("TrueHeading", 0.0),
            "navigation_status": report.get("NavigationalStatus", 0),
            "rate_of_turn": report.get("RateOfTurn", 0.0),
        })
        self.position_reports += 1

    async def run(self) -> None:
        backoff = 2.0
        while True:
            try:
                async with aiohttp.ClientSession() as session:
                    async with session.ws_connect(AISSTREAM_WS_URL) as ws:
                        self.connected = True
                        self.last_error = ""
                        await ws.send_str(json.dumps({
                            "APIKey": self.api_key,
                            "BoundingBoxes": REGIONAL_BOXES,
                            "FilterMessageTypes": [
                                "PositionReport",
                                "ShipStaticData",
                            ],
                        }))
                        backoff = 2.0
                        since_yield = 0
                        async for msg in ws:
                            if msg.type in (aiohttp.WSMsgType.TEXT, aiohttp.WSMsgType.BINARY):
                                try:
                                    self._handle_message(msg.data)
                                except (ValueError, TypeError, KeyError, UnicodeDecodeError):
                                    continue
                                since_yield += 1
                                if since_yield >= 100:
                                    since_yield = 0
                                    await asyncio.sleep(0)
                            elif msg.type in (aiohttp.WSMsgType.ERROR, aiohttp.WSMsgType.CLOSE, aiohttp.WSMsgType.CLOSED):
                                break
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                self.last_error = type(exc).__name__
            finally:
                self.connected = False
                self.reconnects += 1
            await asyncio.sleep(backoff)
            backoff = min(backoff * 2, 60.0)

    def snapshot(self) -> list[dict]:
        now = time.time()
        vessels = []
        for fix in self.vessels.values():
            if "lat" not in fix or "lon" not in fix:
                continue
            row = dict(fix)
            age_s = max(0.0, now - float(row.get("last_seen", now)))
            row["age_s"] = round(age_s, 1)
            row["dark"] = age_s >= DARK_AFTER_S
            vessels.append(maritime_context().annotate(row))
        return vessels

    def status(self) -> dict:
        return {
            "connected": self.connected,
            "messages_received": self.messages_received,
            "position_reports": self.position_reports,
            "static_reports": self.static_reports,
            "reconnects": self.reconnects,
            "last_message_at": self.last_message_at,
            "last_error": self.last_error,
            "regions": len(REGIONAL_BOXES),
            "max_tracked": MAX_TRACKED,
        }


def global_snapshot(feed: "GlobalAisFeed | None") -> dict:
    """What /api/global returns: real feed if it has ever produced a fix,
    otherwise the synthetic demo lane traffic, always labelled honestly."""
    if feed is not None and feed.live and feed.vessels:
        return {"live": True, "vessels": feed.snapshot(), "status": feed.status()}
    demo = [maritime_context().annotate(vessel) for vessel in _demo_snapshot()]
    return {
        "live": False,
        "vessels": demo,
        "status": feed.status() if feed is not None else {
            "connected": False,
            "messages_received": 0,
            "position_reports": 0,
            "static_reports": 0,
            "reconnects": 0,
            "last_message_at": 0.0,
            "last_error": "",
            "regions": len(REGIONAL_BOXES),
            "max_tracked": MAX_TRACKED,
        },
    }
