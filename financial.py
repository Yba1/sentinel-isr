"""Transparent maritime incident-response cost estimates.

The figures are planning ranges, not predicted damages or realized losses.
They intentionally use only safety signals already present in a frame delta.
"""

from __future__ import annotations

from typing import Any


_EVENT_COSTS = {
    ("intrusion", "critical"): (15_000, 75_000, "Protected-water response coordination"),
    ("intrusion", "warning"): (5_000, 25_000, "Protected-area investigation"),
    ("went_dark", "warning"): (2_500, 12_000, "Dark-vessel verification and monitoring"),
    ("reacquired", "warning"): (1_500, 8_000, "Reacquisition review and evidence handling"),
    ("identity_change", "warning"): (3_000, 18_000, "Identity-spoofing investigation"),
}


def estimate_response_cost(frame_delta: dict[str, Any]) -> dict[str, Any]:
    """Return a conservative response-budget range for one rendered frame.

    Alert events are priced from a visible rule table. Coasting tracks without
    a fresh alert receive a small monitoring allowance, deduplicated by track.
    """

    items: list[dict[str, Any]] = []
    covered_tracks: set[str] = set()

    for alert in frame_delta.get("alerts", ()):
        key = (str(alert.get("kind", "")), str(alert.get("severity", "info")))
        cost = _EVENT_COSTS.get(key)
        if cost is None:
            continue
        low, high, label = cost
        track_id = str(alert.get("track_id", ""))
        if track_id:
            covered_tracks.add(track_id)
        items.append(
            {
                "track_id": track_id,
                "kind": key[0],
                "severity": key[1],
                "label": f"{label}{f' · {track_id}' if track_id else ''}",
                "low_usd": low,
                "high_usd": high,
                "basis": "Deterministic Aegis response-cost rule; excludes cargo value and claimed damages.",
            }
        )

    for track in frame_delta.get("tracks", ()):
        track_id = str(track.get("track_id", ""))
        if not track.get("dark") or track_id in covered_tracks:
            continue
        items.append(
            {
                "track_id": track_id,
                "kind": "dark_monitoring",
                "severity": "warning",
                "label": f"Continued dark-track monitoring · {track_id}",
                "low_usd": 1_000,
                "high_usd": 5_000,
                "basis": "Planning allowance for analyst time and sensor tasking while the contact remains dark.",
            }
        )

    return {
        "currency": "USD",
        "low_usd": sum(item["low_usd"] for item in items),
        "high_usd": sum(item["high_usd"] for item in items),
        "items": items,
        "disclaimer": "Planning range only; not a forecast, valuation, or realized loss.",
    }
