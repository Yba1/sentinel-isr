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


def _bearing_between(start: tuple[float, float], end: tuple[float, float]) -> float:
    lat1, lon1 = map(math.radians, start)
    lat2, lon2 = map(math.radians, end)
    delta_lon = lon2 - lon1
    y = math.sin(delta_lon) * math.cos(lat2)
    x = (
        math.cos(lat1) * math.sin(lat2)
        - math.sin(lat1) * math.cos(lat2) * math.cos(delta_lon)
    )
    return math.degrees(math.atan2(y, x)) % 360


def _angle_delta(target: float, source: float) -> float:
    return (target - source + 180) % 360 - 180


def _history_navigation(vessel: dict[str, Any]) -> tuple[float | None, float | None, float | None]:
    samples = vessel.get("history_samples") or []
    valid = [
        sample for sample in samples
        if isinstance(sample, dict)
        and "lat" in sample and "lon" in sample
    ]
    if len(valid) < 2:
        points = vessel.get("history") or []
        if len(points) < 2:
            return None, None, None
        return (
            _bearing_between(tuple(points[-2]), tuple(points[-1])),
            None,
            None,
        )

    latest = valid[-1]
    previous = valid[-2]
    course = _bearing_between(
        (float(previous["lat"]), float(previous["lon"])),
        (float(latest["lat"]), float(latest["lon"])),
    )
    speed = None
    elapsed = float(latest.get("time", 0)) - float(previous.get("time", 0))
    if elapsed > 1:
        mean_lat = math.radians((float(previous["lat"]) + float(latest["lat"])) / 2)
        north_m = (float(latest["lat"]) - float(previous["lat"])) * 111_320
        east_m = (
            (float(latest["lon"]) - float(previous["lon"]))
            * 111_320
            * max(0.1, math.cos(mean_lat))
        )
        speed = math.hypot(east_m, north_m) / elapsed / KNOT_TO_MPS

    history_turn = None
    if len(valid) >= 3:
        older = valid[-3]
        prior_course = _bearing_between(
            (float(older["lat"]), float(older["lon"])),
            (float(previous["lat"]), float(previous["lon"])),
        )
        turn_elapsed_min = (
            float(latest.get("time", 0)) - float(older.get("time", 0))
        ) / 120
        if turn_elapsed_min > 0:
            history_turn = _angle_delta(course, prior_course) / turn_elapsed_min
    return course, speed, history_turn


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


def _valid_turn(value: object) -> bool:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return False
    return math.isfinite(number) and -20 <= number <= 20


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


def predict_dark_vessel(
    vessel: dict[str, Any],
    ocean_conditions: dict[str, Any] | None = None,
) -> dict[str, Any]:
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
    history_course, history_speed, history_turn = _history_navigation(vessel)
    base_bearing = (
        float(vessel["course"]) if has_course
        else float(vessel["heading"]) if has_heading
        else history_course if history_course is not None
        else 0.0
    )
    if history_course is not None and (has_course or has_heading):
        difference = _angle_delta(history_course, base_bearing)
        if abs(difference) <= 45:
            base_bearing = (base_bearing + difference * 0.2) % 360
    history_speed_valid = (
        history_speed is not None and _valid_speed(history_speed)
    )
    base_speed = (
        float(vessel["speed_kn"]) if has_speed
        else float(history_speed) if history_speed_valid
        else 5.0
    )
    raw_turn = vessel.get("rate_of_turn")
    has_reported_turn = _valid_turn(raw_turn)
    has_history_turn = history_turn is not None and math.isfinite(history_turn)
    if has_reported_turn and has_history_turn:
        turn_rate = float(raw_turn) * 0.7 + float(history_turn) * 0.3
    elif has_reported_turn:
        turn_rate = float(raw_turn)
    elif has_history_turn:
        turn_rate = float(history_turn)
    else:
        turn_rate = 0.0
    turn_rate = max(-1.5, min(1.5, turn_rate))
    has_turn_rate = has_reported_turn or has_history_turn
    try:
        navigation_status = int(vessel.get("navigation_status"))
    except (TypeError, ValueError):
        navigation_status = -1
    constrained_status = navigation_status in {1, 5, 6}
    if constrained_status and base_speed < 3:
        base_speed = min(base_speed, 0.5)

    missing = [
        name for name, available in (
            ("course_over_ground", has_course),
            ("true_heading", has_heading),
            ("speed_over_ground", has_speed),
            ("rate_of_turn", has_turn_rate),
            ("track_history", history_points >= 3 or len(vessel.get("history_samples") or []) >= 3),
        ) if not available
    ]
    heading_sigma = 4.0 + min(30.0, age_s / 60 * 1.2) + len(missing) * 4.0
    speed_sigma = max(0.35, base_speed * 0.1) + len(missing) * 0.3
    if constrained_status:
        heading_sigma += 8.0
        speed_sigma = min(speed_sigma, 0.5)
    desired_scenarios = max(
        2,
        min(6, 2 + len(missing) + int(age_s // 600)),
    )
    seed = int(vessel.get("mmsi", 0)) ^ int(float(vessel.get("last_seen", 0.0)))
    rng = random.Random(seed)
    context = maritime_context()
    current = (
        ocean_conditions.get("center", {})
        if ocean_conditions and ocean_conditions.get("available")
        else {}
    )
    current_east = float(current.get("east_mps", 0.0))
    current_north = float(current.get("north_mps", 0.0))
    current_speed = math.hypot(current_east, current_north)
    current_bearing = math.degrees(math.atan2(current_east, current_north)) % 360
    samples: list[dict[str, Any]] = []
    constrained_samples = 0
    elapsed_minutes = min(60.0, age_s / 60)
    path_minutes = HORIZON_MINUTES + elapsed_minutes
    steps = max(1, math.ceil(path_minutes / STEP_MINUTES))
    for _ in range(SAMPLE_COUNT):
        intended_bearing = (base_bearing + rng.gauss(0, heading_sigma)) % 360
        bearing = intended_bearing
        target_speed = max(0.0, rng.gauss(base_speed, speed_sigma))
        speed = target_speed
        sample_turn = max(
            -1.5,
            min(1.5, turn_rate + rng.gauss(0, 0.12 + heading_sigma / 120)),
        )
        sample_lat, sample_lon = lat, lon
        path = [[sample_lat, sample_lon]]
        constrained = False
        for step in range(steps):
            turn_decay = math.exp(-(step * STEP_MINUTES) / 6.0)
            bearing = (
                bearing
                + sample_turn * STEP_MINUTES * turn_decay
                + rng.gauss(0, max(0.15, heading_sigma / 45))
            ) % 360
            speed = max(
                0.0,
                speed
                + (target_speed - speed) * 0.25
                + rng.gauss(0, speed_sigma * 0.04),
            )
            next_lat, next_lon = _destination(
                sample_lat,
                sample_lon,
                bearing,
                speed * KNOT_TO_MPS * STEP_MINUTES * 60,
            )
            if current_speed > 0:
                sampled_current = max(0.0, rng.gauss(current_speed, current_speed * 0.12))
                next_lat, next_lon = _destination(
                    next_lat,
                    next_lon,
                    current_bearing + rng.gauss(0, 5.0),
                    sampled_current * STEP_MINUTES * 60,
                )
            terrain = context.terrain_status(next_lat, next_lon)
            if terrain["available"] and terrain["on_land"]:
                constrained = True
                bearing = (
                    intended_bearing + (35 if rng.random() < 0.5 else -35)
                ) % 360
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
        "model": "monte_carlo_navigation_v2",
        "samples": SAMPLE_COUNT,
        "horizon_minutes": HORIZON_MINUTES,
        "step_minutes": STEP_MINUTES,
        "path_minutes_from_last_fix": round(path_minutes, 1),
        "scenario_count": len(scenarios),
        "scenarios": scenarios,
        "inputs": {
            "mmsi": vessel.get("mmsi"),
            "last_position": [lat, lon],
            "ais_silence_s": round(age_s, 1),
            "course_deg": base_bearing if has_course or has_heading else None,
            "speed_kn": base_speed if has_speed else None,
            "history_points": history_points,
            "history_course_deg": (
                round(history_course, 1) if history_course is not None else None
            ),
            "history_speed_kn": (
                round(float(history_speed), 1) if history_speed_valid else None
            ),
            "turn_rate_deg_min": round(turn_rate, 3) if has_turn_rate else None,
            "navigation_status": (
                navigation_status if navigation_status >= 0 else None
            ),
            "regional_terrain_constraint": terrain_here["available"],
            "copernicus_surface_current": bool(current),
        },
        "uncertainty_drivers": missing,
        "signal_availability": {
            "ais_vhf_navigation": True,
            "independent_radio_frequency": False,
            "satellite_observation": False,
            "peer_vessel_observation": False,
            "global_terrain": False,
            "ocean_currents": bool(current),
        },
        "terrain_constrained_samples": constrained_samples,
        "ocean_conditions": ocean_conditions or {
            "configured": False,
            "available": False,
            "source": "Copernicus Marine Service",
        },
    }
