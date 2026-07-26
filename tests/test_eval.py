"""Tests for the scenario-pack regression harness (``tracker.eval``).

``scenarios/`` is not present in this working tree -- the packs live on an
unmerged branch -- so every fixture here builds a pack on disk with ``tmp_path``
and ``json.dump``. That is not a workaround: it is how the harness is meant to
be tested, since it reads pack JSON directly and must work against any root.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

import pytest

from tracker.eval import (
    CHECKERS,
    FAIL,
    OFFSET_TOLERANCE_FRAC,
    PASS,
    SKIP,
    CheckResult,
    discover_packs,
    evaluate_all,
    evaluate_pack,
    format_report,
    load_pack,
    main,
)

ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")


# --------------------------------------------------------------------------- #
# fixtures: synthetic packs shaped like Omar's real ones
# --------------------------------------------------------------------------- #


def s01_pack() -> dict:
    """An s01-shaped pack whose every structural key should PASS."""
    return {
        "id": "s01_dark_in_sanctuary",
        "name": "Dark vessel loitering in the sanctuary",
        "time_window": {"start": "2024-06-15T06:00:00+00:00", "end": "2024-06-15T08:00:00+00:00"},
        "frame_interval_s": 30.0,
        "geofence_layers": [{"file": "layers/monterey_bay_nms.geojson", "kind": "sanctuary"}],
        "synthetic_actors": [
            {
                "actor_id": "target_1",
                "track": "gen:transit_then_loiter",
                "params": {"start_latlon": [36.75, -122.90], "speed_mps": 6.0},
            }
        ],
        "events": [
            {"id": "ev_dark", "t": 3135.0, "kind": "ais_off", "actor": "target_1"},
            {"id": "ev_radar", "t": 5535.0, "kind": "radar_contact", "actor": "target_1"},
        ],
        "expected": {
            "id_switches_max": 0,
            "reassoc_p_min": 0.85,
            "geofence_alert": True,
            "dark_actor": "target_1",
            "sanctuary_entry_s": 1350.0,
            "dark_at_s": 3135.0,
            "radar_contact_at_s": 5535.0,
            "intrusion_fence": "monterey_bay_nms",
            "predicted_vs_true_offset_verified_m": 1794,
            "notes": "provenance text that must never become a check",
        },
    }


def s02_pack() -> dict:
    """An s02-shaped pack: two actors 40 km apart sharing one MMSI."""
    return {
        "id": "s02_mmsi_spoof",
        "name": "Simultaneous MMSI spoof",
        "time_window": {"start": "2024-06-15T06:00:00+00:00", "end": "2024-06-15T07:00:00+00:00"},
        "synthetic_actors": [
            {"actor_id": "vessel_a", "track": "gen:transit", "params": {"start_latlon": [36.6, -121.9]}},
            {"actor_id": "vessel_b", "track": "gen:transit", "params": {"start_latlon": [36.95, -122.0]}},
        ],
        "events": [
            {
                "id": "ev_spoof_a",
                "t": 0.0,
                "kind": "identity_change",
                "actor": "vessel_a",
                "params": {"new_display_id": "mmsi:412345678"},
            },
            {
                "id": "ev_spoof_b",
                "t": 0.0,
                "kind": "identity_change",
                "actor": "vessel_b",
                "params": {"new_display_id": "mmsi:412345678"},
            },
        ],
        "expected": {
            "spoof_detected": True,
            "spoof_mmsi": "mmsi:412345678",
            "actors": ["vessel_a", "vessel_b"],
            "min_separation_km": 39.9,
            "retraction_cascade": "expected only if JTMS is implemented (Raj); if not, "
            "spoof_detected alone is the pack's minimum bar",
            "notes": "both actors broadcast the same display id from t=0",
        },
    }


def s03_pack() -> dict:
    """An s03-shaped pack: every expected key is an unbuilt capability."""
    return {
        "id": "s03_ghost_fleet",
        "name": "Ghost fleet re-flagging",
        "time_window": {"start": "2024-06-15T06:00:00+00:00", "end": "2024-06-15T07:00:00+00:00"},
        "synthetic_actors": [{"actor_id": "actor_1", "params": {"start_latlon": [36.5, -122.2]}}],
        "events": [
            {"id": "ev_reflag", "t": 1800.0, "kind": "identity_change", "actor": "actor_1"},
        ],
        "expected": {
            "relink_same_track": True,
            "ofac_hit": True,
            "ofac_hit_name": "ARTAVIL",
            "ofac_hit_mmsi": "mmsi:572469210",
            "severity_escalates_on_relink": True,
            "notes": "roadmap tier",
        },
    }


def good_s01_results() -> dict:
    """Measured run data that satisfies every measured s01 key."""
    return {
        "id_switches": 0,
        "reassoc_p": 0.93,
        "geofence_alerts": [{"fence": "monterey_bay_nms", "t": 1350.0}],
        "offset_m": 1750.0,
        "reassoc_track_id": "target_1",
    }


def write_pack(root: Path, pack: dict, *, dirname: str | None = None) -> Path:
    """Write ``pack`` to ``<root>/scenarios/<dirname>/pack.json``."""
    d = root / "scenarios" / (dirname or str(pack["id"]))
    d.mkdir(parents=True, exist_ok=True)
    path = d / "pack.json"
    path.write_text(json.dumps(pack, indent=2), encoding="utf-8")
    return path


def outcomes(result) -> dict[str, str]:
    return {c.key: c.outcome for c in result.checks}


def detail_of(result, key: str) -> str:
    return next(c.detail for c in result.checks if c.key == key)


# --------------------------------------------------------------------------- #
# discovery and loading
# --------------------------------------------------------------------------- #


def test_discover_packs_absent_scenarios_dir_returns_empty(tmp_path: Path) -> None:
    """An absent scenarios/ is the normal state of this tree. No raise."""
    assert not (tmp_path / "scenarios").exists()
    assert discover_packs(tmp_path) == []


def test_discover_packs_finds_and_sorts(tmp_path: Path) -> None:
    write_pack(tmp_path, s02_pack())
    write_pack(tmp_path, s01_pack())
    write_pack(tmp_path, s03_pack())
    found = discover_packs(tmp_path)
    assert [p.parent.name for p in found] == [
        "s01_dark_in_sanctuary",
        "s02_mmsi_spoof",
        "s03_ghost_fleet",
    ]


def test_discover_packs_ignores_other_json(tmp_path: Path) -> None:
    write_pack(tmp_path, s01_pack())
    (tmp_path / "scenarios" / "s01_dark_in_sanctuary" / "notes.json").write_text("{}", encoding="utf-8")
    assert [p.name for p in discover_packs(tmp_path)] == ["pack.json"]


def test_load_pack_records_source_path(tmp_path: Path) -> None:
    path = write_pack(tmp_path, s01_pack())
    pack = load_pack(path)
    assert evaluate_pack(pack).path == str(path)


def test_malformed_pack_json_error_names_the_file(tmp_path: Path) -> None:
    d = tmp_path / "scenarios" / "broken"
    d.mkdir(parents=True)
    path = d / "pack.json"
    path.write_text('{"id": "broken", "expected": {', encoding="utf-8")
    with pytest.raises(ValueError) as exc:
        load_pack(path)
    msg = str(exc.value)
    assert "pack.json" in msg
    assert "broken" in msg
    assert "malformed" in msg.lower()


def test_pack_json_that_is_not_an_object_is_rejected(tmp_path: Path) -> None:
    d = tmp_path / "scenarios" / "listy"
    d.mkdir(parents=True)
    path = d / "pack.json"
    path.write_text("[1, 2, 3]", encoding="utf-8")
    with pytest.raises(ValueError, match="pack.json"):
        load_pack(path)


# --------------------------------------------------------------------------- #
# structural checks on a well-formed pack
# --------------------------------------------------------------------------- #


def test_wellformed_s01_structural_keys_all_pass() -> None:
    res = evaluate_pack(s01_pack())
    got = outcomes(res)
    for key in (
        "dark_actor",
        "intrusion_fence",
        "sanctuary_entry_s",
        "dark_at_s",
        "radar_contact_at_s",
    ):
        assert got[key] == PASS, f"{key}: {detail_of(res, key)}"
    assert res.failed == 0
    assert res.ok is True


def test_notes_produces_no_row_at_all() -> None:
    res = evaluate_pack(s01_pack())
    assert "notes" not in outcomes(res)
    assert all(c.key != "notes" for c in res.checks)


def test_dark_actor_not_in_synthetic_actors_fails() -> None:
    pack = s01_pack()
    pack["expected"]["dark_actor"] = "ghost_9"
    res = evaluate_pack(pack)
    assert outcomes(res)["dark_actor"] == FAIL
    assert "ghost_9" in detail_of(res, "dark_actor")
    assert res.ok is False


def test_actors_list_with_one_undefined_member_fails() -> None:
    pack = s02_pack()
    pack["expected"]["actors"] = ["vessel_a", "vessel_z"]
    res = evaluate_pack(pack)
    assert outcomes(res)["actors"] == FAIL
    assert "vessel_z" in detail_of(res, "actors")


def test_actors_all_defined_passes() -> None:
    assert outcomes(evaluate_pack(s02_pack()))["actors"] == PASS


def test_intrusion_fence_unknown_layer_fails() -> None:
    pack = s01_pack()
    pack["expected"]["intrusion_fence"] = "central_bay_sanctuary"
    res = evaluate_pack(pack)
    assert outcomes(res)["intrusion_fence"] == FAIL
    assert "monterey_bay_nms" in detail_of(res, "intrusion_fence")


def test_intrusion_fence_with_no_layers_declared_fails() -> None:
    pack = s01_pack()
    del pack["geofence_layers"]
    assert outcomes(evaluate_pack(pack))["intrusion_fence"] == FAIL


def test_spoof_mmsi_present_passes_and_counts_broadcasters() -> None:
    res = evaluate_pack(s02_pack())
    assert outcomes(res)["spoof_mmsi"] == PASS
    detail = detail_of(res, "spoof_mmsi")
    assert "vessel_a" in detail and "vessel_b" in detail


def test_spoof_mmsi_never_broadcast_fails() -> None:
    pack = s02_pack()
    pack["expected"]["spoof_mmsi"] = "mmsi:000000000"
    assert outcomes(evaluate_pack(pack))["spoof_mmsi"] == FAIL


# --------------------------------------------------------------------------- #
# timings: window bounds, ordering, event cross-reference
# --------------------------------------------------------------------------- #


def test_out_of_order_radar_contact_before_dark_fails() -> None:
    pack = s01_pack()
    pack["expected"]["radar_contact_at_s"] = 2000.0  # before dark_at_s=3135
    res = evaluate_pack(pack)
    assert outcomes(res)["radar_contact_at_s"] == FAIL
    assert "ordering" in detail_of(res, "radar_contact_at_s").lower()


def test_dark_before_sanctuary_entry_fails() -> None:
    pack = s01_pack()
    pack["expected"]["sanctuary_entry_s"] = 4000.0
    res = evaluate_pack(pack)
    assert outcomes(res)["dark_at_s"] == FAIL
    assert "ordering" in detail_of(res, "dark_at_s").lower()


def test_timing_after_end_of_time_window_fails() -> None:
    pack = s01_pack()
    pack["expected"]["radar_contact_at_s"] = 9999.0  # window is 7200 s
    res = evaluate_pack(pack)
    assert outcomes(res)["radar_contact_at_s"] == FAIL
    assert "OUTSIDE" in detail_of(res, "radar_contact_at_s")


def test_negative_timing_fails() -> None:
    pack = s01_pack()
    pack["expected"]["sanctuary_entry_s"] = -10.0
    res = evaluate_pack(pack)
    assert outcomes(res)["sanctuary_entry_s"] == FAIL


def test_dark_at_s_must_match_an_ais_off_event() -> None:
    pack = s01_pack()
    pack["expected"]["dark_at_s"] = 3200.0  # the ais_off event is at 3135
    res = evaluate_pack(pack)
    assert outcomes(res)["dark_at_s"] == FAIL
    assert "ais_off" in detail_of(res, "dark_at_s")


def test_dark_at_s_fails_when_no_ais_off_event_exists() -> None:
    pack = s01_pack()
    pack["events"] = [e for e in pack["events"] if e["kind"] != "ais_off"]
    res = evaluate_pack(pack)
    assert outcomes(res)["dark_at_s"] == FAIL
    assert "no 'ais_off' event" in detail_of(res, "dark_at_s")


def test_events_keyed_on_kind_and_on_type_both_work() -> None:
    """Omar's packs use `kind`; `type` is accepted and the detail says so."""
    kind_pack = s01_pack()
    assert outcomes(evaluate_pack(kind_pack))["dark_at_s"] == PASS

    type_pack = s01_pack()
    type_pack["events"] = [
        {"id": e["id"], "t": e["t"], "type": e["kind"], "actor": e["actor"]} for e in type_pack["events"]
    ]
    res = evaluate_pack(type_pack)
    assert outcomes(res)["dark_at_s"] == PASS
    assert "type" in detail_of(res, "dark_at_s")


def test_unparseable_time_window_does_not_fail_the_timing_check() -> None:
    pack = s01_pack()
    pack["time_window"] = {"start": "not-a-date", "end": "also-not"}
    res = evaluate_pack(pack)
    assert outcomes(res)["dark_at_s"] == PASS
    assert "not parseable" in detail_of(res, "dark_at_s")


def test_non_numeric_timing_fails_cleanly() -> None:
    pack = s01_pack()
    pack["expected"]["dark_at_s"] = "half past three"
    assert outcomes(evaluate_pack(pack))["dark_at_s"] == FAIL


# --------------------------------------------------------------------------- #
# min_separation_km
# --------------------------------------------------------------------------- #


def test_min_separation_passes_and_reports_the_computed_value() -> None:
    res = evaluate_pack(s02_pack())
    assert outcomes(res)["min_separation_km"] == PASS
    detail = detail_of(res, "min_separation_km")
    assert "haversine" in detail
    assert "39.9" in detail  # both the computed value and the threshold


def test_min_separation_below_threshold_fails() -> None:
    pack = s02_pack()
    pack["expected"]["min_separation_km"] = 100.0
    res = evaluate_pack(pack)
    assert outcomes(res)["min_separation_km"] == FAIL
    assert "SHORT" in detail_of(res, "min_separation_km")


def test_min_separation_skips_when_positions_not_derivable() -> None:
    pack = s02_pack()
    for actor in pack["synthetic_actors"]:
        actor["params"] = {"speed_mps": 5.0}
    res = evaluate_pack(pack)
    assert outcomes(res)["min_separation_km"] == SKIP
    assert detail_of(res, "min_separation_km")


def test_min_separation_skips_with_a_single_actor() -> None:
    pack = s02_pack()
    pack["synthetic_actors"] = pack["synthetic_actors"][:1]
    assert outcomes(evaluate_pack(pack))["min_separation_km"] == SKIP


# --------------------------------------------------------------------------- #
# measured keys: results=None vs good vs bad
# --------------------------------------------------------------------------- #


MEASURED_S01 = (
    "id_switches_max",
    "reassoc_p_min",
    "geofence_alert",
    "predicted_vs_true_offset_verified_m",
)


def test_results_none_measured_keys_skip_structural_keys_still_pass() -> None:
    res = evaluate_pack(s01_pack(), results=None)
    got = outcomes(res)
    for key in MEASURED_S01:
        assert got[key] == SKIP, f"{key} should SKIP without run data"
        assert "no run data supplied" in detail_of(res, key)
    assert got["dark_actor"] == PASS
    assert got["dark_at_s"] == PASS
    assert res.failed == 0
    assert res.ok is True


def test_good_results_make_measured_keys_pass() -> None:
    res = evaluate_pack(s01_pack(), results=good_s01_results())
    got = outcomes(res)
    for key in MEASURED_S01:
        assert got[key] == PASS, f"{key}: {detail_of(res, key)}"
    assert res.failed == 0


def test_bad_id_switches_fails() -> None:
    results = good_s01_results() | {"id_switches": 3}
    res = evaluate_pack(s01_pack(), results=results)
    assert outcomes(res)["id_switches_max"] == FAIL
    assert "OVER" in detail_of(res, "id_switches_max")


def test_low_reassoc_p_fails() -> None:
    results = good_s01_results() | {"reassoc_p": 0.42}
    res = evaluate_pack(s01_pack(), results=results)
    assert outcomes(res)["reassoc_p_min"] == FAIL
    assert "BELOW" in detail_of(res, "reassoc_p_min")


def test_no_geofence_alerts_fails() -> None:
    results = good_s01_results() | {"geofence_alerts": []}
    res = evaluate_pack(s01_pack(), results=results)
    assert outcomes(res)["geofence_alert"] == FAIL


def test_geofence_alert_on_the_wrong_fence_fails() -> None:
    results = good_s01_results() | {"geofence_alerts": [{"fence": "gate_approach_restricted"}]}
    res = evaluate_pack(s01_pack(), results=results)
    assert outcomes(res)["geofence_alert"] == FAIL
    assert "monterey_bay_nms" in detail_of(res, "geofence_alert")


def test_geofence_alert_accepts_plain_string_alerts() -> None:
    results = good_s01_results() | {"geofence_alerts": ["monterey_bay_nms"]}
    assert outcomes(evaluate_pack(s01_pack(), results=results))["geofence_alert"] == PASS


def test_offset_within_documented_tolerance_passes() -> None:
    want = 1794
    edge = want * (1.0 + OFFSET_TOLERANCE_FRAC * 0.99)
    results = good_s01_results() | {"offset_m": edge}
    assert outcomes(evaluate_pack(s01_pack(), results=results))["predicted_vs_true_offset_verified_m"] == PASS


def test_offset_outside_tolerance_fails() -> None:
    results = good_s01_results() | {"offset_m": 400.0}
    res = evaluate_pack(s01_pack(), results=results)
    assert outcomes(res)["predicted_vs_true_offset_verified_m"] == FAIL
    assert "TOLERANCE" in detail_of(res, "predicted_vs_true_offset_verified_m").upper()


def test_results_supplied_but_missing_a_key_skips_with_that_reason() -> None:
    results = {k: v for k, v in good_s01_results().items() if k != "reassoc_p"}
    res = evaluate_pack(s01_pack(), results=results)
    assert outcomes(res)["reassoc_p_min"] == SKIP
    assert "reassoc_p" in detail_of(res, "reassoc_p_min")


def test_reassoc_correct_uses_dark_actor_as_ground_truth() -> None:
    pack = s01_pack()
    pack["expected"]["reassoc_correct"] = True

    good = evaluate_pack(pack, results=good_s01_results())
    assert outcomes(good)["reassoc_correct"] == PASS

    bad = evaluate_pack(pack, results=good_s01_results() | {"reassoc_track_id": "target_2"})
    assert outcomes(bad)["reassoc_correct"] == FAIL
    assert "MISATTRIBUTED" in detail_of(bad, "reassoc_correct")


# --------------------------------------------------------------------------- #
# not-built capabilities and unknown keys
# --------------------------------------------------------------------------- #


@pytest.mark.parametrize(
    "key",
    [
        "retraction_cascade",
        "spoof_detected",
        "ofac_hit",
        "ofac_hit_mmsi",
        "ofac_hit_name",
        "relink_same_track",
        "severity_escalates_on_relink",
    ],
)
def test_unbuilt_capabilities_always_skip_with_a_reason(key: str) -> None:
    """Even with perfect run data these SKIP -- the capability does not exist."""
    pack = s01_pack()
    pack["expected"] = {key: True}
    res = evaluate_pack(pack, results=good_s01_results())
    check = res.checks[0]
    assert check.key == key
    assert check.outcome == SKIP
    assert check.detail.strip()
    assert "not implemented" in check.detail


def test_jtms_skips_name_the_retraction_layer() -> None:
    res = evaluate_pack(s02_pack())
    for key in ("spoof_detected", "retraction_cascade"):
        assert "JTMS" in detail_of(res, key)


def test_ofac_skips_name_the_watchlist_lookup() -> None:
    res = evaluate_pack(s03_pack())
    assert "OFAC" in detail_of(res, "ofac_hit")
    assert res.skipped == 5
    assert res.passed == 0
    assert res.failed == 0
    assert res.ok is True


def test_verbose_string_expected_value_is_not_echoed_into_the_detail() -> None:
    """s02's retraction_cascade value is a 100-char sentence; keep it out."""
    res = evaluate_pack(s02_pack())
    detail = detail_of(res, "retraction_cascade")
    assert "minimum bar" not in detail
    assert len(detail) < 120


def test_unknown_expected_key_skips_and_does_not_raise() -> None:
    pack = s01_pack()
    pack["expected"]["wormhole_detected"] = True
    res = evaluate_pack(pack)
    assert outcomes(res)["wormhole_detected"] == SKIP
    assert "no checker registered" in detail_of(res, "wormhole_detected")
    assert res.failed == 0


def test_pack_with_no_expected_block_skips_rather_than_crashing() -> None:
    pack = s01_pack()
    del pack["expected"]
    res = evaluate_pack(pack)
    assert res.failed == 0
    assert res.skipped == 1


# --------------------------------------------------------------------------- #
# a broken checker must not take the suite down
# --------------------------------------------------------------------------- #


def test_checker_that_raises_becomes_a_fail_and_the_run_continues(monkeypatch) -> None:
    def exploding(expected, pack, results):
        raise RuntimeError("boom: geofence layer file went missing")

    monkeypatch.setitem(CHECKERS, "dark_actor", exploding)
    res = evaluate_pack(s01_pack())
    got = outcomes(res)
    assert got["dark_actor"] == FAIL
    assert "boom: geofence layer file went missing" in detail_of(res, "dark_actor")
    assert "RuntimeError" in detail_of(res, "dark_actor")
    # every other key still got checked
    assert got["dark_at_s"] == PASS
    assert got["intrusion_fence"] == PASS
    assert len(res.checks) == len(s01_pack()["expected"]) - 1  # minus notes


def test_checker_returning_the_wrong_type_becomes_a_fail(monkeypatch) -> None:
    monkeypatch.setitem(CHECKERS, "dark_actor", lambda e, p, r: "sure, looks fine")
    res = evaluate_pack(s01_pack())
    assert outcomes(res)["dark_actor"] == FAIL
    assert "CheckResult" in detail_of(res, "dark_actor")


# --------------------------------------------------------------------------- #
# evaluate_all
# --------------------------------------------------------------------------- #


def test_evaluate_all_covers_every_pack(tmp_path: Path) -> None:
    for pack in (s01_pack(), s02_pack(), s03_pack()):
        write_pack(tmp_path, pack)
    results = evaluate_all(tmp_path)
    assert [r.pack_id for r in results] == [
        "s01_dark_in_sanctuary",
        "s02_mmsi_spoof",
        "s03_ghost_fleet",
    ]
    assert all(r.ok for r in results)
    assert sum(r.failed for r in results) == 0
    assert sum(r.passed for r in results) > 0


def test_evaluate_all_routes_results_by_pack_id(tmp_path: Path) -> None:
    write_pack(tmp_path, s01_pack())
    results = evaluate_all(tmp_path, results_by_pack={"s01_dark_in_sanctuary": good_s01_results()})
    got = outcomes(results[0])
    assert got["id_switches_max"] == PASS
    assert got["reassoc_p_min"] == PASS


def test_evaluate_all_on_empty_root(tmp_path: Path) -> None:
    assert evaluate_all(tmp_path) == []


# --------------------------------------------------------------------------- #
# the report
# --------------------------------------------------------------------------- #


def test_report_has_no_ansi_escapes_when_colour_disabled(tmp_path: Path) -> None:
    for pack in (s01_pack(), s02_pack(), s03_pack()):
        write_pack(tmp_path, pack)
    text = format_report(evaluate_all(tmp_path), use_colour=False)
    assert "\x1b" not in text
    assert ANSI_RE.search(text) is None


def test_report_emits_ansi_when_colour_forced(tmp_path: Path) -> None:
    write_pack(tmp_path, s01_pack())
    text = format_report(evaluate_all(tmp_path), use_colour=True)
    assert ANSI_RE.search(text) is not None


def test_report_contains_a_row_per_check_and_a_total(tmp_path: Path) -> None:
    write_pack(tmp_path, s01_pack())
    results = evaluate_all(tmp_path)
    text = format_report(results, use_colour=False)
    for check in results[0].checks:
        assert check.key in text
    assert "notes" not in text
    assert "TOTAL" in text
    assert "s01_dark_in_sanctuary" in text


def test_report_key_column_is_aligned_across_packs(tmp_path: Path) -> None:
    for pack in (s01_pack(), s02_pack(), s03_pack()):
        write_pack(tmp_path, pack)
    text = format_report(evaluate_all(tmp_path), use_colour=False)
    rows = [ln for ln in text.splitlines() if re.match(r"^  (PASS|FAIL|SKIP)  ", ln)]
    assert len(rows) >= 15

    detail_starts = set()
    for row in rows:
        body = row[8:]  # past "  PASS  "
        key = body.split()[0]
        rest = body[len(key):]
        detail_starts.add(8 + len(key) + (len(rest) - len(rest.lstrip())))
    assert len(detail_starts) == 1, f"detail column is ragged: {sorted(detail_starts)}"


def test_report_on_no_packs_says_so(tmp_path: Path) -> None:
    text = format_report(evaluate_all(tmp_path), use_colour=False)
    assert "no packs found" in text


def test_report_flags_a_failing_pack() -> None:
    pack = s01_pack()
    pack["expected"]["dark_actor"] = "nobody"
    text = format_report([evaluate_pack(pack)], use_colour=False)
    assert "FAIL" in text
    assert "1 failed" in text
    assert "FAILURES IN THIS PACK" in text


def test_report_explains_what_skip_means() -> None:
    text = format_report([evaluate_pack(s03_pack())], use_colour=False)
    assert "Not a failure" in text


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #


def test_main_returns_zero_when_only_pass_and_skip(tmp_path: Path, capsys) -> None:
    for pack in (s01_pack(), s02_pack(), s03_pack()):
        write_pack(tmp_path, pack)
    assert main(["--all", "--root", str(tmp_path), "--colour", "never"]) == 0
    out = capsys.readouterr().out
    assert "0 failed" in out


def test_main_returns_nonzero_when_a_check_failed(tmp_path: Path) -> None:
    pack = s01_pack()
    pack["expected"]["dark_actor"] = "nobody"
    write_pack(tmp_path, pack)
    assert main(["--root", str(tmp_path), "--colour", "never"]) == 1


def test_main_on_absent_scenarios_dir_exits_zero(tmp_path: Path, capsys) -> None:
    assert main(["--all", "--root", str(tmp_path)]) == 0
    assert "no packs found" in capsys.readouterr().out


def test_main_pack_filter(tmp_path: Path, capsys) -> None:
    for pack in (s01_pack(), s02_pack()):
        write_pack(tmp_path, pack)
    assert main(["--pack", "s02_mmsi_spoof", "--root", str(tmp_path), "--colour", "never"]) == 0
    out = capsys.readouterr().out
    assert "s02_mmsi_spoof" in out
    assert "s01_dark_in_sanctuary" not in out


def test_main_unknown_pack_id_is_a_usage_error(tmp_path: Path, capsys) -> None:
    write_pack(tmp_path, s01_pack())
    assert main(["--pack", "s99_nope", "--root", str(tmp_path)]) == 2
    assert "s99_nope" in capsys.readouterr().err


def test_main_malformed_pack_reports_a_usage_error_naming_the_file(tmp_path: Path, capsys) -> None:
    d = tmp_path / "scenarios" / "broken"
    d.mkdir(parents=True)
    (d / "pack.json").write_text("{oops", encoding="utf-8")
    assert main(["--root", str(tmp_path)]) == 2
    assert "pack.json" in capsys.readouterr().err


def test_main_json_output_is_parseable(tmp_path: Path, capsys) -> None:
    for pack in (s01_pack(), s02_pack(), s03_pack()):
        write_pack(tmp_path, pack)
    assert main(["--json", "--root", str(tmp_path)]) == 0
    payload = json.loads(capsys.readouterr().out)
    assert payload["summary"]["packs"] == 3
    assert payload["summary"]["failed"] == 0
    assert payload["summary"]["ok"] is True
    ids = [p["pack_id"] for p in payload["packs"]]
    assert ids == ["s01_dark_in_sanctuary", "s02_mmsi_spoof", "s03_ghost_fleet"]
    for p in payload["packs"]:
        assert all(c["key"] != "notes" for c in p["checks"])
        assert all(c["outcome"] in {PASS, FAIL, SKIP} for c in p["checks"])


def test_main_quiet_prints_one_line(tmp_path: Path, capsys) -> None:
    write_pack(tmp_path, s01_pack())
    assert main(["--quiet", "--root", str(tmp_path)]) == 0
    out = capsys.readouterr().out.strip()
    assert out.count("\n") == 0
    assert "passed" in out and "failed" in out and "skipped" in out


def test_main_default_root_is_the_repo_root_and_does_not_crash(capsys) -> None:
    """`python -m tracker.eval --all` with no --root must be a clean exit."""
    assert main(["--all", "--colour", "never"]) == 0


# --------------------------------------------------------------------------- #
# CheckResult / PackResult shape
# --------------------------------------------------------------------------- #


def test_check_result_is_frozen() -> None:
    c = CheckResult(key="k", outcome=PASS, detail="d")
    with pytest.raises(Exception):
        c.key = "other"  # type: ignore[misc]


def test_pack_result_counts_sum_to_the_number_of_checks() -> None:
    res = evaluate_pack(s01_pack())
    assert res.passed + res.failed + res.skipped == len(res.checks)
