"""Monte Carlo prediction for AIS-silent vessels using observed navigation data."""

from __future__ import annotations

import math
import random
from typing import Any

from data.maritime_context import maritime_context

EARTH_RADIUS_M = 6_371_008.8
KNOT_TO_MPS = 0.514444
HORIZON_MINUTES = 30
STEP_MINUTES = 2
SAMPLE_COUNT = 600


def _destination(lat: float, lon: float, bearing_deg: float, distance_m: float) -> tuple[float, float]:
    angular = distance_m / EARTH_RADIUS_M
    bearing = math.radians(bearing_deg)
    lat1 = math.radians(lat)
    lon1 = math.radians(lon)
    lat2 = math.asin(
        math.sin(lat1) * math.cos(angular)
        + math.cos(lat1) * math.sin(angular) * math.cos(bearing)
    )
    lon2 = lon1 + math.atan2(
        math.sin(bearing) * math.sin(angular) * math.cos(lat1),
        math.cos(angular) - math.sin(lat1) * math.sin(lat2),
    )
    return math.degrees(lat2), ((math.degrees(lon2) + 180) % 360) - 180


def _valid_bearing(value: object) -> bool:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return False
    return math.isfinite(number) and 0 <= number < 360


def _valid_speed(value: object) -> bool:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return False
    return math.isfinite(number) and 0 <= number < 80


def _cluster(samples: list[dict[str, Any]], count: int, origin: tuple[float, float]) -> list[dict[str, Any]]:
    lat0, lon0 = origin
    cos_lat = max(0.1, math.cos(math.radians(lat0)))

    def xy(sample: dict[str, Any]) -> tuple[float, float]:
        lat, lon = sample["path"][-1]
        return ((lon - lon0) * 111_320 * cos_lat, (lat - lat0) * 111_320)

    points = [xy(sample) for sample in samples]
    ordered = sorted(range(len(points)), key=lambda i: math.atan2(points[i][0], points[i][1]))
    centroids = [points[ordered[min(len(ordered) - 1, int((i + 0.5) * len(ordered) / count))]] for i in range(count)]
    assignments = [0] * len(points)
    for _ in range(8):
        for index, point in enumerate(points):
            assignments[index] = min(
                range(count),
                key=lambda cluster: (point[0] - centroids[cluster][0]) ** 2
                + (point[1] - centroids[cluster][1]) ** 2,
            )
        for cluster in range(count):
            members = [points[i] for i, assigned in enumerate(assignments) if assigned == cluster]
            if members:
                centroids[cluster] = (
                    sum(point[0] for point in members) / len(members),
                    sum(point[1] for point in members) / len(members),
                )

    scenarios = []
    for cluster in range(count):
        members = [i for i, assigned in enumerate(assignments) if assigned == cluster]
        if not members:
            continue
        center = centroids[cluster]
        representative = min(
            members,
            key=lambda i: (points[i][0] - center[0]) ** 2 + (points[i][1] - center[1]) ** 2,
        )
        distances = sorted(
            math.hypot(points[i][0] - center[0], points[i][1] - center[1])
            for i in members
        )
        radius = distances[min(len(distances) - 1, int(len(distances) * 0.9))]
        path = samples[representative]["path"]
        distance_m = sum(
            math.hypot(
                (path[i][1] - path[i - 1][1]) * 111_320 * cos_lat,
                (path[i][0] - path[i - 1][0]) * 111_320,
            )
            for i in range(1, len(path))
        )
        scenarios.append({
            "probability": round(len(members) / len(samples), 4),
            "path": [[round(lat, 5), round(lon, 5)] for lat, lon in path],
            "distance_nm": round(distance_m / 1852, 1),
            "uncertainty_radius_m": round(max(100.0, radius)),
        })
    scenarios.sort(key=lambda scenario: scenario["probability"], reverse=True)
    return scenarios


def predict_dark_vessel(vessel: dict[str, Any]) -> dict[str, Any]:
    """Return deterministic Monte Carlo branches from the latest real AIS fix."""
    if not vessel.get("dark"):
        raise ValueError("prediction is only valid for AIS-silent vessels")

    lat = float(vessel["lat"])
    lon = float(vessel["lon"])
    age_s = max(0.0, float(vessel.get("age_s", 0.0)))
    has_course = _valid_bearing(vessel.get("course"))
    has_heading = _valid_bearing(vessel.get("heading"))
    has_speed = _valid_speed(vessel.get("speed_kn"))
    history_points = len(vessel.get("history") or [])
    base_bearing = (
        float(vessel["course"]) if has_course
        else float(vessel["heading"]) if has_heading
        else 0.0
    )
    base_speed = float(vessel.get("speed_kn", 0.0)) if has_speed else 8.0
    raw_turn = vessel.get("rate_of_turn")
    try:
        turn_rate = max(-3.0, min(3.0, float(raw_turn)))
        has_turn_rate = math.isfinite(float(raw_turn))
    except (TypeError, ValueError):
        turn_rate = 0.0
        has_turn_rate = False

    missing = [
        name for name, available in (
            ("course_over_ground", has_course),
            ("true_heading", has_heading),
            ("speed_over_ground", has_speed),
            ("rate_of_turn", has_turn_rate),
            ("track_history", history_points >= 3),
        ) if not available
    ]
    heading_sigma = 7.0 + min(38.0, age_s / 60 * 1.8) + len(missing) * 7.0
    speed_sigma = max(0.8, base_speed * 0.12) + len(missing) * 0.45
    desired_scenarios = max(
        2,
        min(10, 2 + len(missing) + int(age_s // 300)),
    )
    seed = int(vessel.get("mmsi", 0)) ^ int(float(vessel.get("last_seen", 0.0)))
    rng = random.Random(seed)
    context = maritime_context()
    samples: list[dict[str, Any]] = []
    constrained_samples = 0
    steps = HORIZON_MINUTES // STEP_MINUTES
    for _ in range(SAMPLE_COUNT):
        bearing = (base_bearing + rng.gauss(0, heading_sigma)) % 360
        speed = max(0.0, rng.gauss(base_speed, speed_sigma))
        sample_turn = turn_rate + rng.gauss(0, heading_sigma / 45)
        sample_lat, sample_lon = lat, lon
        path = [[sample_lat, sample_lon]]
        constrained = False
        for _step in range(steps):
            bearing = (bearing + sample_turn * STEP_MINUTES + rng.gauss(0, 1.2)) % 360
            speed = max(0.0, speed + rng.gauss(0, speed_sigma * 0.08))
            next_lat, next_lon = _destination(
                sample_lat,
                sample_lon,
                bearing,
                speed * KNOT_TO_MPS * STEP_MINUTES * 60,
            )
            terrain = context.terrain_status(next_lat, next_lon)
            if terrain["available"] and terrain["on_land"]:
                constrained = True
                bearing = (bearing + (90 if rng.random() < 0.5 else -90)) % 360
                next_lat, next_lon = _destination(
                    sample_lat,
                    sample_lon,
                    bearing,
                    speed * KNOT_TO_MPS * STEP_MINUTES * 30,
                )
                if context.terrain_status(next_lat, next_lon)["on_land"]:
                    next_lat, next_lon = sample_lat, sample_lon
                    speed *= 0.5
            sample_lat, sample_lon = next_lat, next_lon
            path.append([sample_lat, sample_lon])
        constrained_samples += int(constrained)
        samples.append({"path": path})

    scenarios = _cluster(samples, desired_scenarios, (lat, lon))
    terrain_here = context.terrain_status(lat, lon)
    return {
        "model": "monte_carlo_dead_reckoning_v1",
        "samples": SAMPLE_COUNT,
        "horizon_minutes": HORIZON_MINUTES,
        "step_minutes": STEP_MINUTES,
        "scenario_count": len(scenarios),
        "scenarios": scenarios,
        "inputs": {
            "mmsi": vessel.get("mmsi"),
            "last_position": [lat, lon],
            "ais_silence_s": round(age_s, 1),
            "course_deg": base_bearing if has_course or has_heading else None,
            "speed_kn": base_speed if has_speed else None,
            "history_points": history_points,
            "regional_terrain_constraint": terrain_here["available"],
        },
        "uncertainty_drivers": missing,
        "signal_availability": {
            "ais_vhf_navigation": True,
            "independent_radio_frequency": False,
            "satellite_observation": False,
            "peer_vessel_observation": False,
            "global_terrain": False,
        },
        "terrain_constrained_samples": constrained_samples,
    }
