"""Small, cached Copernicus Marine current fields for dark-vessel prediction."""

from __future__ import annotations

import math
import os
import threading
import time
from datetime import datetime, timedelta, timezone
from typing import Any

CURRENT_DATASET = "cmems_mod_glo_phy-cur_anfc_0.083deg_P1D-m"


class OceanConditionsClient:
    """Fetch a compact surface-current grid only when an operator selects a vessel."""

    def __init__(self, username: str = "", password: str = "") -> None:
        self.username = username or os.environ.get("COPERNICUS_MARINE_USERNAME", "")
        self.password = password or os.environ.get("COPERNICUS_MARINE_PASSWORD", "")
        self._cache: dict[tuple[int, int, str], tuple[float, dict[str, Any]]] = {}
        self._lock = threading.Lock()

    @property
    def configured(self) -> bool:
        return bool(self.username and self.password)

    def current_grid(self, lat: float, lon: float) -> dict[str, Any]:
        if not self.configured:
            return {
                "configured": False,
                "available": False,
                "source": "Copernicus Marine Service",
            }
        now = datetime.now(timezone.utc)
        key = (round(lat * 4), round(lon * 4), now.date().isoformat())
        cached = self._cache.get(key)
        if cached and time.monotonic() - cached[0] < 1800:
            return cached[1]
        with self._lock:
            cached = self._cache.get(key)
            if cached and time.monotonic() - cached[0] < 1800:
                return cached[1]
            payload = self._fetch(lat, lon, now)
            self._cache[key] = (time.monotonic(), payload)
            return payload

    def _fetch(self, lat: float, lon: float, now: datetime) -> dict[str, Any]:
        try:
            import copernicusmarine

            frame = copernicusmarine.read_dataframe(
                dataset_id=CURRENT_DATASET,
                username=self.username,
                password=self.password,
                variables=["uo", "vo"],
                minimum_longitude=max(-179.99, lon - 0.18),
                maximum_longitude=min(179.99, lon + 0.18),
                minimum_latitude=max(-89.9, lat - 0.18),
                maximum_latitude=min(89.9, lat + 0.18),
                minimum_depth=0.494025,
                maximum_depth=0.494025,
                start_datetime=now - timedelta(days=1),
                end_datetime=now + timedelta(days=1),
                coordinates_selection_method="nearest",
                disable_progress_bar=True,
            ).reset_index()
            frame = frame.dropna(subset=["uo", "vo"])
            if frame.empty:
                return {
                    "configured": True,
                    "available": False,
                    "source": "Copernicus Marine Service",
                    "dataset": CURRENT_DATASET,
                    "error": "no_ocean_cell",
                }
            frame["_time_delta"] = (
                frame["time"].dt.tz_localize("UTC") - now
            ).abs()
            nearest_time = frame.loc[frame["_time_delta"].idxmin(), "time"]
            frame = frame[frame["time"] == nearest_time]
            vectors = []
            for row in frame.itertuples():
                east = float(row.uo)
                north = float(row.vo)
                vectors.append({
                    "lat": round(float(row.latitude), 5),
                    "lon": round(float(row.longitude), 5),
                    "east_mps": round(east, 4),
                    "north_mps": round(north, 4),
                    "speed_mps": round(math.hypot(east, north), 4),
                    "bearing_deg": round(math.degrees(math.atan2(east, north)) % 360, 1),
                })
            center = min(
                vectors,
                key=lambda vector: (
                    (vector["lat"] - lat) ** 2
                    + (vector["lon"] - lon) ** 2
                ),
            )
            return {
                "configured": True,
                "available": True,
                "source": "Copernicus Marine Service",
                "dataset": CURRENT_DATASET,
                "valid_at": nearest_time.isoformat(),
                "center": center,
                "vectors": vectors[:25],
            }
        except Exception as exc:
            return {
                "configured": True,
                "available": False,
                "source": "Copernicus Marine Service",
                "dataset": CURRENT_DATASET,
                "error": type(exc).__name__,
            }
