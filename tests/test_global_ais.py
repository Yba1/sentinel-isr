import json

from data import global_ais


def test_unconfigured_feed_returns_no_synthetic_contacts():
    result = global_ais.global_snapshot(None)

    assert result["live"] is False
    assert result["vessels"] == []
    assert result["status"]["configured"] is False


def test_real_contact_becomes_dark_after_report_timeout(monkeypatch):
    now = [1_700_000_000.0]
    monkeypatch.setattr(global_ais.time, "time", lambda: now[0])
    feed = global_ais.GlobalAisFeed("not-a-real-key")
    feed._record(
        123456789,
        {
            "mmsi": 123456789,
            "name": "Test Vessel",
            "lat": 37.8,
            "lon": -122.4,
            "course": 90.0,
            "speed_kn": 12.0,
        },
    )

    assert feed.snapshot()[0]["dark"] is False
    now[0] += global_ais.DARK_AFTER_S + 1
    assert feed.snapshot()[0]["dark"] is True


def test_static_voyage_data_merges_without_refreshing_position_age(monkeypatch):
    now = [1_700_000_000.0]
    monkeypatch.setattr(global_ais.time, "time", lambda: now[0])
    feed = global_ais.GlobalAisFeed("not-a-real-key")
    feed._record(123456789, {"lat": 1.0, "lon": 2.0, "name": "Old"})
    now[0] += 10

    feed._handle_message(json.dumps({
        "MessageType": "ShipStaticData",
        "MetaData": {"MMSI": 123456789},
        "Message": {
            "ShipStaticData": {
                "Name": "AEGIS TEST",
                "ImoNumber": 7654321,
                "CallSign": "WXYZ",
                "Type": 70,
                "Destination": "SFO",
                "MaximumStaticDraught": 8.5,
            }
        },
    }))

    vessel = feed.snapshot()[0]
    assert vessel["name"] == "AEGIS TEST"
    assert vessel["imo"] == 7654321
    assert vessel["destination"] == "SFO"
    assert vessel["age_s"] == 10


def test_static_only_reports_do_not_consume_position_contact_capacity():
    feed = global_ais.GlobalAisFeed("not-a-real-key")
    feed._record_static(123456789, {"name": "STATIC FIRST", "imo": 7654321})

    assert feed.vessels == {}
    assert feed.static_data[123456789]["name"] == "STATIC FIRST"

    feed._record(123456789, {"lat": 1.0, "lon": 2.0})

    assert feed.vessels[123456789]["name"] == "STATIC FIRST"
    assert feed.vessels[123456789]["imo"] == 7654321
    assert feed.static_data == {}


def test_live_identity_switch_count_uses_observed_static_changes():
    feed = global_ais.GlobalAisFeed("not-a-real-key")
    feed._record(
        123456789,
        {
            "lat": 1.0,
            "lon": 2.0,
            "name": "VESSEL ONE",
            "imo": 7654321,
            "call_sign": "CALL1",
        },
    )

    feed._record_static(
        123456789,
        {"name": "VESSEL TWO", "imo": 7654321, "call_sign": "CALL1"},
    )
    feed._record_static(
        123456789,
        {"name": "VESSEL TWO", "imo": 7654321, "call_sign": "CALL1"},
    )
    feed._record(
        123456789,
        {
            "lat": 1.1,
            "lon": 2.1,
            "name": "VESSEL THREE",
            "imo": 7654321,
            "call_sign": "CALL1",
        },
    )

    assert feed.identity_switches == 2
    assert feed.status()["identity_switches"] == 2


def test_position_reports_build_bounded_history():
    feed = global_ais.GlobalAisFeed("not-a-real-key")
    for index in range(global_ais.MAX_HISTORY + 5):
        feed._record(123456789, {"lat": float(index), "lon": float(index)})

    assert len(feed.vessels[123456789]["history"]) == global_ais.MAX_HISTORY
