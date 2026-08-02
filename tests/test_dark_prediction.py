import math

from data.dark_prediction import predict_dark_vessel


def _dark_vessel(**overrides):
    vessel = {
        "mmsi": 123456789,
        "lat": 37.7,
        "lon": -123.0,
        "last_seen": 1_700_000_000.0,
        "age_s": 180.0,
        "dark": True,
        "course": 95.0,
        "heading": 96.0,
        "speed_kn": 12.0,
        "rate_of_turn": 0.1,
        "history": [[37.7, -123.02], [37.7, -123.01], [37.7, -123.0]],
    }
    return {**vessel, **overrides}


def test_prediction_is_deterministic_and_probability_is_normalized():
    first = predict_dark_vessel(_dark_vessel())
    second = predict_dark_vessel(_dark_vessel())

    assert first == second
    assert first["samples"] == 600
    assert 2 <= first["scenario_count"] <= 6
    assert abs(sum(row["probability"] for row in first["scenarios"]) - 1.0) < 0.001
    expected_points = math.ceil(first["path_minutes_from_last_fix"] / 2) + 1
    assert all(len(row["path"]) == expected_points for row in first["scenarios"])


def test_missing_navigation_data_creates_more_uncertainty_branches():
    complete = predict_dark_vessel(_dark_vessel())
    sparse = predict_dark_vessel(_dark_vessel(
        course=None,
        heading=None,
        speed_kn=None,
        rate_of_turn=None,
        history=[],
        age_s=900.0,
    ))

    assert sparse["scenario_count"] > complete["scenario_count"]
    assert len(sparse["uncertainty_drivers"]) > len(complete["uncertainty_drivers"])
    assert sparse["signal_availability"]["satellite_observation"] is False


def test_active_vessels_are_not_predicted():
    try:
        predict_dark_vessel(_dark_vessel(dark=False))
    except ValueError as exc:
        assert "AIS-silent" in str(exc)
    else:
        raise AssertionError("active vessel should not receive a dark prediction")


def test_copernicus_current_changes_paths_and_is_reported():
    vessel = _dark_vessel()
    baseline = predict_dark_vessel(vessel)
    with_current = predict_dark_vessel(vessel, {
        "configured": True,
        "available": True,
        "source": "Copernicus Marine Service",
        "center": {
            "east_mps": 0.4,
            "north_mps": -0.2,
            "speed_mps": 0.4472,
            "bearing_deg": 116.6,
        },
        "vectors": [],
    })

    assert with_current["inputs"]["copernicus_surface_current"] is True
    assert with_current["signal_availability"]["ocean_currents"] is True
    assert with_current["scenarios"] != baseline["scenarios"]


def test_extreme_reported_turn_rate_decays_instead_of_spiraling():
    prediction = predict_dark_vessel(_dark_vessel(
        rate_of_turn=10.0,
        age_s=600.0,
    ))

    for scenario in prediction["scenarios"]:
        path = scenario["path"]
        mean_lat = math.radians(sum(point[0] for point in path) / len(path))

        def distance(start, end):
            return math.hypot(
                (end[1] - start[1]) * 111_320 * math.cos(mean_lat),
                (end[0] - start[0]) * 111_320,
            )

        displacement = distance(path[0], path[-1])
        travelled = sum(distance(path[index - 1], path[index]) for index in range(1, len(path)))
        assert displacement / travelled > 0.7
