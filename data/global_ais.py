"""Zoomed-out global ship layer.

The layer contains real AISStream contacts only. If no API key is configured,
or the upstream connection has not produced a position report, the API returns
an empty contact list and an explicit status instead of synthetic substitutes.

This module never blocks the rest of the server on the real feed: run() is a
background task, snapshot() always returns immediately from whatever state
currently exists.
"""

from __future__ import annotations

import asyncio
import json
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
        self.static_data: dict[int, dict] = {}
        self.live = False
        self._touch_order: list[int] = []
        self.connected = False
        self.messages_received = 0
        self.position_reports = 0
        self.static_reports = 0
        self.identity_switches = 0
        self.reconnects = 0
        self.last_message_at = 0.0
        self.last_error = ""

    @staticmethod
    def _identity_changed(mmsi: int, previous: dict, values: dict) -> bool:
        return any(
            previous.get(field) not in (None, "", 0, f"MMSI {mmsi}")
            and values.get(field) not in (None, "", 0)
            and str(previous[field]).strip().upper()
            != str(values[field]).strip().upper()
            for field in ("name", "imo", "call_sign")
        )

    def _record(self, mmsi: int, fix: dict) -> None:
        if mmsi not in self.vessels and len(self.vessels) >= MAX_TRACKED:
            oldest = self._touch_order.pop(0)
            self.vessels.pop(oldest, None)
        if mmsi in self._touch_order:
            self._touch_order.remove(mmsi)
        self._touch_order.append(mmsi)
        was_positioned = mmsi in self.vessels
        previous = self.vessels.get(mmsi)
        if previous is None:
            previous = self.static_data.pop(mmsi, {})
        if was_positioned and self._identity_changed(mmsi, previous, fix):
            self.identity_switches += 1
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
        if mmsi in self.vessels:
            previous = self.vessels[mmsi]
            if self._identity_changed(mmsi, previous, values):
                self.identity_switches += 1
            self.vessels[mmsi] = {**self.vessels[mmsi], **values}
            return
        if len(self.static_data) >= MAX_TRACKED * 2:
            self.static_data.pop(next(iter(self.static_data)))
        self.static_data[mmsi] = {**self.static_data.get(mmsi, {}), **values}

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
            "configured": True,
            "connected": self.connected,
            "messages_received": self.messages_received,
            "position_reports": self.position_reports,
            "static_reports": self.static_reports,
            "identity_switches": self.identity_switches,
            "reconnects": self.reconnects,
            "last_message_at": self.last_message_at,
            "last_error": self.last_error,
            "regions": len(REGIONAL_BOXES),
            "max_tracked": MAX_TRACKED,
        }


def global_snapshot(feed: "GlobalAisFeed | None") -> dict:
    """Return real AIS contacts, or an explicit empty/offline state."""
    if feed is not None and feed.live and feed.vessels:
        return {"live": True, "vessels": feed.snapshot(), "status": feed.status()}
    return {
        "live": False,
        "vessels": [],
        "status": {**feed.status(), "configured": True} if feed is not None else {
            "configured": False,
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
