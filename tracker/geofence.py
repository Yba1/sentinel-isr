"""Geofence containment geometry for maritime intrusion detection.

Scope
-----
Phase 3.5 asks a single question: *which named areas is this point inside,
right now?* Areas are marine protected areas, buffered submarine-cable
corridors, port approaches and danger zones. This module answers exactly that
and nothing more -- it is stateless, pure geometry.

**Transition tracking is deliberately not here.** "Was this track inside last
frame?", "emit an INTRUSION event", "a dark vessel inside an MPA is severity
CRITICAL" -- all of that is per-track state and lives in the Jac layer, on the
hypothesis graph where the rest of the track lifecycle already lives. Putting a
`previous_inside` flag in this file would fork the tracker's state across two
languages. If you are about to add a member that remembers a track, stop: it
belongs in Jac.

Coordinates
-----------
Every coordinate crossing this API is **local ENU metres**, never lon/lat
degrees. The scenario loader projects GeoJSON to ENU once at load time, so
buffers are plain metres, containment is Euclidean, and no code downstream has
to reason about degrees shrinking with latitude. The single exception is
:func:`lonlat_to_enu`, which *is* that converter.

Why an in-memory STRtree and not PostGIS
----------------------------------------
A spatial database earns its keep when you query a small slice of a large
corpus. Here the opposite holds: there are a couple of dozen fences, they are
static for the whole replay, and every frame touches *all* live tracks anyway.
There is no selective query to optimise and no persistence requirement -- only
raw per-frame throughput, at 60x replay speed. A `shapely.STRtree` built once in
:meth:`GeofenceIndex.__init__` and reused gives that with zero I/O, and its
vectorized bulk `query` resolves a whole frame of points in one call into C
rather than a Python loop per track.

Why cable corridors are pre-buffered
------------------------------------
A submarine cable is a LineString; the protected corridor is that line dilated
by a few hundred metres. `LineString.buffer()` is expensive -- it is a real
offsetting operation, orders of magnitude dearer than a containment test. So
:func:`corridor_fence` buffers **once**, at construction, and stores a polygon.
The hot path never buffers, never sees a line, and treats every fence
identically.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Iterable, Sequence

import numpy as np
import shapely
from shapely.geometry import LineString, Polygon

__all__ = [
    "Geofence",
    "GeofenceIndex",
    "polygon_fence",
    "corridor_fence",
    "lonlat_to_enu",
    "EARTH_RADIUS_M",
]

# WGS84 semi-major axis. Used as a sphere radius by the equirectangular
# projection below -- the flattening correction is far smaller than the
# projection's own distortion over a scenario box, so it would be false rigour.
EARTH_RADIUS_M: float = 6378137.0


@dataclass(frozen=True)
class Geofence:
    """One named area, ready to test against.

    ``geom`` is a shapely Polygon/MultiPolygon in ENU metres that is **already
    buffered** -- ``buffer_m`` is retained for provenance and reporting (an
    operator wants to see "500 m cable corridor"), never re-applied at query
    time. Frozen so a fence cannot be mutated out from under the STRtree, whose
    bounding boxes are snapshotted at build time and would silently go stale.
    """

    id: str
    kind: str  # "mpa" | "cable" | "port" | "danger"
    label: str
    geom: object  # shapely Polygon/MultiPolygon, ENU metres, already buffered
    buffer_m: float = 0.0


def polygon_fence(
    id: str,
    kind: str,
    label: str,
    coords: Sequence[Sequence[float]],
    buffer_m: float = 0.0,
) -> Geofence:
    """Build a fence from a polygon ring.

    ``coords`` is ``[[x, y], ...]`` in ENU metres. ``buffer_m > 0`` dilates the
    polygon outward, which is how an MPA gets an advisory margin.
    """
    geom = Polygon([(float(x), float(y)) for x, y in coords])
    if buffer_m > 0.0:
        # Only when asked: buffer(0) is not a no-op -- it re-noders the ring and
        # can quietly repair or collapse geometry we were handed deliberately.
        geom = geom.buffer(float(buffer_m))
    return Geofence(id=id, kind=kind, label=label, geom=geom, buffer_m=float(buffer_m))


def corridor_fence(
    id: str,
    label: str,
    coords: Sequence[Sequence[float]],
    buffer_m: float,
    kind: str = "cable",
) -> Geofence:
    """Build a corridor fence: a route polyline dilated into a polygon.

    ``coords`` is the cable route ``[[x, y], ...]`` in ENU metres. Buffering
    happens here, once, so the hot path only ever tests point-in-polygon.
    """
    geom = LineString([(float(x), float(y)) for x, y in coords]).buffer(float(buffer_m))
    return Geofence(id=id, kind=kind, label=label, geom=geom, buffer_m=float(buffer_m))


class GeofenceIndex:
    """Immutable spatial index over a fence set; the only stateful thing here
    is the tree itself, which is a pure function of the fences."""

    __slots__ = ("_fences", "_ids", "_by_id", "_tree")

    def __init__(self, fences: Sequence[Geofence]) -> None:
        self._fences: tuple[Geofence, ...] = tuple(fences)
        # Index-aligned with the tree: STRtree returns positional indices, so
        # id lookup is a tuple index rather than a dict hash on the hot path.
        self._ids: tuple[str, ...] = tuple(f.id for f in self._fences)
        self._by_id: dict[str, Geofence] = {f.id: f for f in self._fences}
        self._tree = shapely.STRtree([f.geom for f in self._fences])

    def __len__(self) -> int:
        return len(self._fences)

    @property
    def fences(self) -> tuple[Geofence, ...]:
        """The indexed fences, in build order."""
        return self._fences

    def query(self, xy: Sequence[float]) -> list[str]:
        """Ids of every fence containing the single point ``(x, y)``, sorted.

        Delegates to :meth:`query_many` on purpose: one predicate call exists in
        this module, so the fence/point argument order can only be right or
        wrong in one place.
        """
        return self.query_many([xy])[0]

    def query_many(self, pts) -> list[list[str]]:
        """One sorted id-list per input point. ``pts`` is (N, 2) ENU metres.

        Hot path: a single bulk STRtree call for the whole frame.
        """
        arr = np.asarray(pts, dtype=float).reshape(-1, 2)
        n = arr.shape[0]
        out: list[list[str]] = [[] for _ in range(n)]
        if n == 0 or not self._fences:
            # Also dodges the shape ambiguity of an empty tree/point result.
            return out

        # PREDICATE ORDER, verified empirically against shapely 2.1.2 and NOT
        # what you would guess: STRtree.query evaluates
        # ``predicate(input_geometry, tree_geometry)`` -- the *input* is on the
        # left. Our inputs are points and the tree holds fences, so asking for
        # "contains" asks whether a point contains a polygon, which is never
        # true and returns an empty result set with no error. "within" is the
        # correct spelling of "fence contains point". See test_geofence.py,
        # which pins this with nested fences in both directions.
        idx = self._tree.query(shapely.points(arr), predicate="within")

        # idx is (2, K): row 0 = input point index, row 1 = tree/fence index.
        ids = self._ids
        for pi, fi in zip(idx[0].tolist(), idx[1].tolist()):
            out[pi].append(ids[fi])
        # Sort by id, not by tree order: tree order depends on STRtree's
        # internal packing and is not a stable contract to hand downstream.
        for hits in out:
            hits.sort()
        return out

    def get(self, fence_id: str) -> Geofence:
        """The fence with this id. Raises ``KeyError`` if there is none."""
        return self._by_id[fence_id]


def lonlat_to_enu(
    lonlat: Iterable[Sequence[float]],
    origin_lonlat: Sequence[float],
) -> np.ndarray:
    """Project lon/lat degrees to local ENU metres about ``origin_lonlat``.

    Equirectangular about the origin latitude::

        x = R * (lon - lon0) * cos(lat0)
        y = R * (lat - lat0)

    Accurate to well under a metre across a ~100 km scenario box -- far below
    even AIS position noise -- and a couple of orders of magnitude cheaper than
    a pyproj transform, which we would otherwise pay for on every scenario load.
    Returns an (N, 2) array; the origin maps to exactly (0, 0).
    """
    arr = np.asarray(lonlat, dtype=float).reshape(-1, 2)
    lon0, lat0 = float(origin_lonlat[0]), float(origin_lonlat[1])
    # cos of the *origin* latitude, not per-point: that is what makes the
    # projection an affine map, so ENU metres stay a consistent linear frame.
    cos_lat0 = np.cos(np.radians(lat0))
    out = np.empty_like(arr)
    out[:, 0] = EARTH_RADIUS_M * np.radians(arr[:, 0] - lon0) * cos_lat0
    out[:, 1] = EARTH_RADIUS_M * np.radians(arr[:, 1] - lat0)
    return out
