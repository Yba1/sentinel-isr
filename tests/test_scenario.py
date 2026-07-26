"""Phase 1 acceptance tests for the scenario loader (data/scenario.py).

The synthetic pack (s02) tests always run. The real-AIS pack (s01) tests need
its cached ais_window.csv, which is committed with the pack; they skip with a
loud reason if it is missing rather than failing someone who hasn't pulled it.
"""

import os
import time

import pytest

from data.contracts import AIS_SIGMA_M, Measurement
from data.scenario import SCENARIOS_DIR, find_crossings, lla_to_enu, load_scenario

S01 = "s01_dark_in_sanctuary"
S02 = "s02_synthetic_demo"
_S01_CSV = os.path.join(SCENARIOS_DIR, S01, "ais_window.csv")

needs_ais = pytest.mark.skipif(
    not os.path.isfile(_S01_CSV),
    reason=f"{_S01_CSV} missing -- run scripts/extract_window.py",
)


@pytest.fixture(scope="module")
def s02():
    return load_scenario(S02)


@pytest.fixture(scope="module")
def s01():
    if not os.path.isfile(_S01_CSV):
        pytest.skip("s01 AIS window not extracted")
    return load_scenario(S01)


# ------------------------------------------------------------------ geometry

def test_enu_roundtrip_and_scale():
    # One degree of longitude at 37.825N is ~88 km; sanity-check the projection.
    x, y = lla_to_enu(37.825, -122.4 + 1.0, 37.825, -122.4)
    assert 87_000 < x < 89_000 and abs(y) < 1.0
    x, y = lla_to_enu(37.825 + 0.01, -122.4, 37.825, -122.4)
    assert 1_050 < y < 1_170 and abs(x) < 1e-6


# ------------------------------------------------------- loader, synthetic pack

def test_load_returns_frames_and_geofences(s02):
    assert s02.n_frames == 121                      # 60 min at 30 s + fencepost
    assert s02.frames[1].t - s02.frames[0].t == 30.0
    assert [g.fence_id for g in s02.geofences] == ["central_bay_sanctuary"]
    # Geofence is in ENU metres: the Alcatraz box is ~1.8 km wide, west of origin.
    ring_x = [p[0] for p in s02.geofences[0].ring]
    assert 1_000 < max(ring_x) - min(ring_x) < 5_000
    assert max(ring_x) < 0                          # entirely west of origin


def test_geofence_contains(s02):
    fence = s02.geofences[0]
    assert fence.contains(-1900.0, 200.0)           # Alcatraz waters
    assert not fence.contains(0.0, 0.0)             # scenario origin is outside
    assert not fence.contains(50_000.0, 50_000.0)


def test_ground_truth_covers_every_measurement(s02):
    for frame in s02.frames:
        for m in frame.measurements:
            assert m.meas_id in s02.ground_truth
            assert s02.ground_truth[m.meas_id] in s02.true_tracks


def test_no_measurement_carries_identity(s02):
    """The headline rule: identity never rides on a Measurement.

    The dataclass has no identity field, and its actual field set is pinned so
    adding one later fails here, not in a demo.
    """
    assert set(Measurement.__dataclass_fields__) == {
        "meas_id", "t", "x", "y", "source", "sigma",
    }
    for frame in s02.frames:
        for m in frame.measurements:
            assert not hasattr(m, "mmsi")
            if m.source == "radar":
                # Radar detections are anonymous by construction; the only
                # link to identity is the ground-truth side table.
                assert not any(str(v).startswith("mmsi:") for v in
                               (m.meas_id, m.source))


def test_loader_leaves_events_unapplied(s02):
    """Boundary rule: the loader emits the FULL unsuppressed AIS picture.

    Suppression, radar injection and identity swaps are graph mutations owned
    by the ScenarioDriver walker (jac/driver.jac), so the ghost's AIS must
    continue past its ais_off timestamp here, and no radar measurement may
    exist at load time.
    """
    ghost_ais = [
        m for f in s02.frames for m in f.measurements
        if s02.ground_truth[m.meas_id] == "ghost_1"
    ]
    assert all(m.source == "ais" for m in ghost_ais)
    assert max(m.t for m in ghost_ais) > 600.0      # NOT suppressed at load
    assert not any(
        m.source == "radar" for f in s02.frames for m in f.measurements
    )
    # Events ride on their frame for the driver to dispatch.
    ev_frames = {ev.kind: f.idx for f in s02.frames for ev in f.events}
    assert ev_frames["ais_off"] == 6                # t=180 at 30 s frames
    assert "radar_contact" in ev_frames


def test_true_position_at_interpolates():
    from data.scenario import true_position_at
    track = [(0.0, 0.0, 0.0), (30.0, 300.0, -60.0)]
    assert true_position_at(track, 15.0) == (150.0, -30.0)
    assert true_position_at(track, 45.0) is None    # beyond the track
    assert true_position_at([], 0.0) is None


def test_mint_meas_id_extends_ground_truth(s02):
    """Radar contacts injected by the driver get collision-free ids and their
    identity lands in the side table, never on a measurement."""
    before = s02.next_meas_seq
    mid = s02.mint_meas_id("ghost_1")
    assert mid == f"m{before:06d}"
    assert s02.ground_truth[mid] == "ghost_1"
    assert s02.next_meas_seq == before + 1


def test_synthetic_crossing_found(s02):
    crossings = find_crossings(s02.true_tracks, s02.frame_interval_s)
    pairs = {c["pair"] for c in crossings}
    assert ("eastbound_1", "westbound_1") in pairs
    assert all(c["min_dist_m"] <= 500.0 for c in crossings)


def test_loads_are_deterministic():
    a = load_scenario(S02)
    b = load_scenario(S02)
    assert [m for f in a.frames for m in f.measurements] == \
           [m for f in b.frames for m in f.measurements]


def test_events_parsed_with_params(s02):
    kinds = {ev.kind for ev in s02.events}
    assert kinds == {"ais_off", "radar_contact"}
    radar = [ev for ev in s02.events if ev.kind == "radar_contact"]
    assert all(ev.params["sigma"] == 50.0 for ev in radar)


# ----------------------------------------------------------- real AIS pack

@needs_ais
def test_s01_vessel_count_and_crossings(s01):
    assert s01.n_vessels >= s01.expected["min_vessels"]         # 30+
    crossings = find_crossings(s01.true_tracks, s01.frame_interval_s)
    genuine = [c for c in crossings
               if not set(c["pair"]) & {"ghost_1", "spoofer_1"}]
    assert len(genuine) >= s01.expected["min_crossings"]        # >= 2 real ones


@needs_ais
def test_s01_load_under_five_seconds():
    start = time.perf_counter()
    load_scenario(S01)
    assert time.perf_counter() - start < 5.0


@needs_ais
def test_s01_identity_stripped_from_real_ais(s01):
    # MMSI exists only in the ground-truth side table, keyed by meas_id.
    real = [a for a in s01.true_tracks if a.startswith("mmsi:")]
    assert len(real) >= 30
    for frame in s01.frames[:40]:
        for m in frame.measurements:
            assert not hasattr(m, "mmsi")


@needs_ais
def test_s01_identity_change_event_parsed(s01):
    swaps = [ev for ev in s01.events if ev.kind == "identity_change"]
    assert len(swaps) == 1
    assert swaps[0].actor == "spoofer_1"
    assert swaps[0].params["new_display_id"] == "mmsi:999999999"
    # Application is the ScenarioDriver walker's job, not the loader's.


def test_pack_swap_needs_no_code_changes():
    """Same call, different pack id -- the whole acceptance criterion."""
    for pack in (S02, S01) if os.path.isfile(_S01_CSV) else (S02,):
        s = load_scenario(pack)
        assert s.frames and s.geofences
