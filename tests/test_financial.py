from financial import estimate_response_cost


def test_critical_intrusion_has_transparent_response_range():
    result = estimate_response_cost(
        {
            "alerts": [
                {
                    "kind": "intrusion",
                    "severity": "critical",
                    "track_id": "T-007",
                }
            ],
            "tracks": [{"track_id": "T-007", "dark": True}],
        }
    )

    assert result["low_usd"] == 15_000
    assert result["high_usd"] == 75_000
    assert result["items"][0]["track_id"] == "T-007"
    assert "Planning range" in result["disclaimer"]


def test_dark_monitoring_is_added_without_double_counting_alerted_track():
    result = estimate_response_cost(
        {
            "alerts": [
                {
                    "kind": "went_dark",
                    "severity": "warning",
                    "track_id": "T-001",
                }
            ],
            "tracks": [
                {"track_id": "T-001", "dark": True},
                {"track_id": "T-002", "dark": True},
            ],
        }
    )

    assert [item["track_id"] for item in result["items"]] == ["T-001", "T-002"]
    assert result["low_usd"] == 3_500
    assert result["high_usd"] == 17_000


def test_clear_frame_has_zero_estimated_cost():
    assert estimate_response_cost({"alerts": [], "tracks": []})["high_usd"] == 0
