from data import global_ais


def test_demo_contacts_include_live_and_coasting_states(monkeypatch):
    monkeypatch.setattr(global_ais.time, "time", lambda: 1_700_000_000.0)

    contacts = global_ais._demo_snapshot(n_per_lane=3)

    assert contacts
    assert {contact["dark"] for contact in contacts} == {False, True}
    assert all("last_seen" in contact and "age_s" in contact for contact in contacts)


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
