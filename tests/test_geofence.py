"""Tests for tracker.geofence -- pure ENU-metre containment geometry.

All coordinates here are ENU metres unless the test is explicitly about
lonlat_to_enu. Nothing in this file tests transitions or event emission: that
state lives in the Jac layer and is covered there.
"""

import time

import numpy as np
import pytest

from tracker.geofence import (
    EARTH_RADIUS_M,
    Geofence,
    GeofenceIndex,
    corridor_fence,
    lonlat_to_enu,
    polygon_fence,
)


def _square(cx, cy, half):
    """Axis-aligned square ring centred on (cx, cy)."""
    return [
        [cx - half, cy - half],
        [cx + half, cy - half],
        [cx + half, cy + half],
        [cx - half, cy + half],
    ]


# --------------------------------------------------------------------------
# Containment correctness, including the STRtree argument-order trap
# --------------------------------------------------------------------------

def _nested_index():
    """A small fence wholly inside a big one -- the argument-order canary."""
    big = polygon_fence("big", "mpa", "Big MPA", _square(0.0, 0.0, 5000.0))
    small = polygon_fence("small", "port", "Small Port", _square(0.0, 0.0, 500.0))
    return GeofenceIndex([big, small])


def test_nested_fences_point_in_both():
    # Dead centre: inside the small fence AND the big one that encloses it.
    assert _nested_index().query([0.0, 0.0]) == ["big", "small"]


def test_nested_fences_point_in_big_only():
    # 3 km out: still in the big fence, well clear of the small one. Together
    # with the test above this fails if the predicate is reversed -- a flipped
    # "fence contains point" -> "point contains fence" yields [] for both, and
    # any symmetric predicate (e.g. intersects on the wrong operand) cannot
    # produce ["big", "small"] here and ["big"] there.
    assert _nested_index().query([3000.0, 0.0]) == ["big"]


def test_point_outside_everything():
    assert _nested_index().query([99999.0, 99999.0]) == []


def test_query_many_matches_query_pointwise():
    idx = _nested_index()
    pts = np.array([[0.0, 0.0], [3000.0, 0.0], [99999.0, 0.0]])
    assert idx.query_many(pts) == [["big", "small"], ["big"], []]
    assert idx.query_many(pts) == [idx.query(p) for p in pts]


def test_ids_are_sorted_not_build_order():
    # Build order puts "zulu" first; the contract is sorted id order.
    a = polygon_fence("zulu", "mpa", "Z", _square(0.0, 0.0, 1000.0))
    b = polygon_fence("alpha", "mpa", "A", _square(0.0, 0.0, 1000.0))
    assert GeofenceIndex([a, b]).query([0.0, 0.0]) == ["alpha", "zulu"]


def test_len_and_fences_property():
    idx = _nested_index()
    assert len(idx) == 2
    assert [f.id for f in idx.fences] == ["big", "small"]
    assert isinstance(idx.fences, tuple)
    assert all(isinstance(f, Geofence) for f in idx.fences)


# --------------------------------------------------------------------------
# Boundary semantics -- measured, not guessed
# --------------------------------------------------------------------------

def test_point_exactly_on_boundary_is_outside():
    # PINNED BEHAVIOUR (shapely 2.1.2, OGC "contains" semantics): a point lying
    # exactly on the polygon edge is NOT contained -- contains/within exclude
    # the boundary, since the point's only intersection with the fence is with
    # the fence's boundary, not its interior. Verified, not assumed. We keep
    # this rather than switching to "intersects" because the frozen API says
    # containment; a vessel exactly on a sanctuary line is not yet inside it.
    idx = GeofenceIndex([polygon_fence("f", "mpa", "F", _square(0.0, 0.0, 1000.0))])
    assert idx.query([1000.0, 0.0]) == []       # on the edge -> outside
    assert idx.query([1000.0, 1000.0]) == []    # on a vertex -> outside
    assert idx.query([999.9, 0.0]) == ["f"]     # just inside -> inside


# --------------------------------------------------------------------------
# Buffering: corridors and dilated polygons
# --------------------------------------------------------------------------

def test_corridor_fence_buffer_width():
    coords = [[0.0, 0.0], [10000.0, 0.0]]  # cable running due east
    off_axis = [5000.0, 100.0]             # 100 m off the route

    wide = GeofenceIndex([corridor_fence("c", "Cable", coords, buffer_m=500.0)])
    narrow = GeofenceIndex([corridor_fence("c", "Cable", coords, buffer_m=50.0)])

    assert wide.query(off_axis) == ["c"]
    assert narrow.query(off_axis) == []
    # The route itself is inside either way.
    assert narrow.query([5000.0, 0.0]) == ["c"]


def test_corridor_fence_defaults_to_cable_kind():
    f = corridor_fence("c", "Cable", [[0.0, 0.0], [1000.0, 0.0]], buffer_m=200.0)
    assert f.kind == "cable"
    assert f.buffer_m == 200.0
    # Buffering happened at construction: the stored geometry is already areal.
    assert f.geom.area > 0.0


def test_polygon_fence_buffer_dilates():
    coords = _square(0.0, 0.0, 1000.0)
    just_outside = [1200.0, 0.0]

    plain = GeofenceIndex([polygon_fence("p", "mpa", "P", coords)])
    dilated = GeofenceIndex([polygon_fence("p", "mpa", "P", coords, buffer_m=500.0)])

    assert plain.query(just_outside) == []
    assert dilated.query(just_outside) == ["p"]
    assert dilated.get("p").buffer_m == 500.0


def test_polygon_fence_zero_buffer_preserves_area():
    coords = _square(0.0, 0.0, 1000.0)
    f = polygon_fence("p", "mpa", "P", coords)
    assert f.geom.area == pytest.approx(2000.0 * 2000.0)
    assert f.buffer_m == 0.0


# --------------------------------------------------------------------------
# Degenerate cases
# --------------------------------------------------------------------------

def test_empty_index():
    idx = GeofenceIndex([])
    assert len(idx) == 0
    assert idx.fences == ()
    assert idx.query([0.0, 0.0]) == []
    assert idx.query_many(np.array([[0.0, 0.0], [1.0, 1.0]])) == [[], []]


def test_empty_point_array():
    assert _nested_index().query_many(np.empty((0, 2))) == []
    assert GeofenceIndex([]).query_many(np.empty((0, 2))) == []


def test_query_many_length_always_matches_input():
    idx = _nested_index()
    for n in (0, 1, 3, 17):
        pts = np.zeros((n, 2))
        assert len(idx.query_many(pts)) == n


def test_get_missing_id_raises():
    with pytest.raises(KeyError):
        _nested_index().get("no-such-fence")


def test_get_returns_the_fence():
    idx = _nested_index()
    assert idx.get("small").label == "Small Port"
    assert idx.get("small").kind == "port"


# --------------------------------------------------------------------------
# lonlat_to_enu
# --------------------------------------------------------------------------

def test_lonlat_origin_maps_to_zero():
    origin = [-9.5, 38.7]  # off Lisbon
    out = lonlat_to_enu([origin], origin)
    assert out.shape == (1, 2)
    np.testing.assert_allclose(out[0], [0.0, 0.0], atol=1e-9)


def test_earth_radius_is_wgs84_semi_major():
    # The exported constant is load-bearing for the hand-computed metres below.
    assert EARTH_RADIUS_M == 6378137.0


def test_lonlat_known_offset_in_metres():
    origin = [-9.5, 38.7]
    # 0.01 deg north, and 0.01 deg east (which shrinks by cos(lat0)).
    out = lonlat_to_enu([[-9.5, 38.71], [-9.49, 38.7]], origin)

    # Independent expected values, NOT recomputed from the module's own formula
    # (that would pass even if R or the cos factor were wrong in both places):
    #   0.01 deg of latitude  = 6378137 * 0.01 * pi/180            = 1113.2 m
    #   0.01 deg of longitude at 38.7 N = 1113.2 * cos(38.7 deg)   =  868.8 m
    assert out[0, 0] == pytest.approx(0.0, abs=1e-9)
    assert out[0, 1] == pytest.approx(1113.2, abs=2.0)   # north
    assert out[1, 0] == pytest.approx(868.8, abs=2.0)    # east, cos-shrunk
    assert out[1, 1] == pytest.approx(0.0, abs=1e-9)
    # Sanity on the cos(lat0) shrink: east is shorter than north at 38.7 N.
    assert out[1, 0] < out[0, 1]


def test_lonlat_shape_preserved():
    origin = [0.0, 0.0]
    pts = np.array([[0.0, 0.0], [0.1, 0.1], [-0.2, 0.3], [1.0, -1.0]])
    assert lonlat_to_enu(pts, origin).shape == (4, 2)


def test_lonlat_feeds_fences_end_to_end():
    # The realistic path: GeoJSON degrees -> ENU -> fence -> containment.
    origin = [-9.5, 38.7]
    ring = lonlat_to_enu(
        [[-9.55, 38.65], [-9.45, 38.65], [-9.45, 38.75], [-9.55, 38.75]], origin
    )
    idx = GeofenceIndex([polygon_fence("mpa1", "mpa", "Sanctuary", ring.tolist())])
    inside = lonlat_to_enu([[-9.50, 38.70]], origin)[0]
    outside = lonlat_to_enu([[-9.20, 38.70]], origin)[0]
    assert idx.query(inside) == ["mpa1"]
    assert idx.query(outside) == []


# --------------------------------------------------------------------------
# ACCEPTANCE: 40 tracks resolved in well under 1 ms
# --------------------------------------------------------------------------

def _realistic_index():
    """Seven fences of mixed kind, roughly a 100 km scenario box."""
    return GeofenceIndex([
        polygon_fence("mpa_north", "mpa", "North Sanctuary", _square(-20000, 20000, 8000)),
        polygon_fence("mpa_south", "mpa", "South Sanctuary", _square(15000, -25000, 12000)),
        polygon_fence("port_a", "port", "Port A", _square(0, 0, 3000), buffer_m=1000.0),
        polygon_fence("port_b", "port", "Port B", _square(30000, 30000, 2500)),
        polygon_fence("danger_1", "danger", "Firing Range", _square(-30000, -30000, 6000)),
        corridor_fence("cable_e", "East Cable", [[-40000, 0], [40000, 5000]], 750.0),
        corridor_fence("cable_n", "North Cable", [[0, -40000], [5000, 40000]], 500.0),
    ])


def test_query_many_40_points_under_1ms():
    idx = _realistic_index()
    rng = np.random.default_rng(20260726)

    # Half the points are seeded inside real fences so the tree actually has to
    # do containment work and return hits, rather than rejecting on bbox alone.
    seeded = np.array([
        [-20000.0, 20000.0], [-18000.0, 22000.0],   # mpa_north
        [15000.0, -25000.0], [18000.0, -22000.0],   # mpa_south
        [0.0, 0.0], [3500.0, 0.0],                  # port_a (+1 km buffer)
        [30000.0, 30000.0],                         # port_b
        [-30000.0, -30000.0],                       # danger_1
        [0.0, 2500.0], [20000.0, 3750.0],           # cable_e corridor
        [2500.0, 0.0], [1250.0, -20000.0],          # cable_n corridor
        [0.0, 1.0], [1000.0, 1000.0],               # port_a and cable_e
    ])
    scatter = rng.uniform(-50000.0, 50000.0, size=(40 - len(seeded), 2))
    pts = np.vstack([seeded, scatter])
    assert pts.shape == (40, 2)

    # Correctness first: a fast wrong answer is not the acceptance criterion.
    hits = idx.query_many(pts)
    assert len(hits) == 40
    n_hits = sum(len(h) for h in hits)
    assert n_hits >= 12, f"expected the seeded points to hit fences, got {n_hits}"

    # Warm up: first call pays numpy/shapely import-time and branch-predictor
    # costs that are not representative of the steady-state replay loop.
    for _ in range(5):
        idx.query_many(pts)

    # perf_counter ONLY: time.time has ~15 ms resolution on Windows, which is
    # 15x the entire budget -- it would measure nothing but zero.
    best = float("inf")
    for _ in range(5):
        t0 = time.perf_counter()
        idx.query_many(pts)
        best = min(best, time.perf_counter() - t0)

    assert best < 1e-3, (
        f"query_many for 40 points took {best * 1e6:.1f} us "
        f"(budget 1000.0 us) over 7 fences with {n_hits} hits"
    )
