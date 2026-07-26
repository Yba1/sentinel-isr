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
    # Geofence is in ENU metres: the sanctuary spans a few km around the origin.
    ring_x = [p[0] for p in s02.geofences[0].ring]
    assert 2_000 < max(ring_x) - min(ring_x) < 10_000


def test_geofence_contains(s02):
    fence = s02.geofences[0]
    assert fence.contains(0.0, 1500.0)              # mid-sanctuary
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


def test_ais_off_suppresses_and_radar_contact_injects(s02):
    ghost_meas = [
        m for f in s02.frames for m in f.measurements
        if s02.ground_truth[m.meas_id] == "ghost_1"
    ]
    ais = [m for m in ghost_meas if m.source == "ais"]
    radar = [m for m in ghost_meas if m.source == "radar"]
    assert max(m.t for m in ais) < 600.0            # dark from ev_dark onward
    assert sorted(m.t for m in radar) == [1500.0, 2400.0]
    assert all(m.sigma == 50.0 for m in radar)
    # The vessel still exists while dark: truth continues past the event.
    assert s02.true_tracks["ghost_1"][-1][0] >= 3600.0 - 30.0


def test_radar_contact_lands_near_truth(s02):
    from data.scenario import _true_position_at
    for f in s02.frames:
        for m in f.measurements:
            if m.source != "radar":
                continue
            pos = _true_position_at(s02.true_tracks["ghost_1"], m.t)
            err = ((m.x - pos[0]) ** 2 + (m.y - pos[1]) ** 2) ** 0.5
            assert err < 5 * 50.0                   # within 5 sigma of truth


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


def test_identity_change_swaps_display_only(s02_swap=None):
    s01_pack = load_scenario(S02)                   # no identity_change here
    assert s01_pack.display_id("ghost_1", 9_999.0) == "ghost_1"


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
def test_s01_identity_change_display_swap(s01):
    assert s01.display_id("spoofer_1", 0.0) == "spoofer_1"
    assert s01.display_id("spoofer_1", 2400.0) == "mmsi:999999999"


def test_pack_swap_needs_no_code_changes():
    """Same call, different pack id -- the whole acceptance criterion."""
    for pack in (S02, S01) if os.path.isfile(_S01_CSV) else (S02,):
        s = load_scenario(pack)
        assert s.frames and s.geofences
