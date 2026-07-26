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

CONTRACT DIVERGENCE (read before merging)
-----------------------------------------
Three implementations of "a geofence" exist. This module keeps its own shape and
*adapts* the other two at the boundary; nothing downstream has to care.

===============  ==================  ==========================  ===================
this module      build-plan dict     Abhi (data/contracts.py)    resolved by
===============  ==================  ==========================  ===================
``id``           ``id``              ``fence_id``                ``geofence_from_mapping``
``label``        ``label``           ``name``                    ``geofence_from_mapping``
``kind``         ``type``            ``kind``                    ``normalize_kind``
``geom``         ``polygon``         ``ring`` (+ ``geojson``)     ``geofence_from_mapping``
``buffer_m``     ``buffer_m``        *absent*                    defaults to ``0.0``
===============  ==================  ==========================  ===================

Field-name note: ``kind`` stays ``kind`` here. It already carries the build
plan's *vocabulary* (mpa/cable/port/danger), ``type`` shadows a builtin, and
Abhi chose ``kind`` independently -- two of three spellings agree.

Kind vocabulary: Abhi's values ("sanctuary", "restricted", "anchorage", ...) are
a different vocabulary for the same four concepts. :data:`KIND_ALIASES` maps them
onto :data:`CANONICAL_KINDS`; see :func:`normalize_kind` for the unknown-input
policy (it raises -- it never guesses).

**buffer_m is absent from Abhi's dataclass, so adapters default it to 0.0.**
That is correct for a polygon and *wrong for a cable corridor*: a zero-buffered
route has no area and can never contain anything, so a cable layer imported
through Abhi's shape would silently never fire. Whoever loads a cable layer must
pass ``buffer_m`` / ``default_buffer_m`` explicitly. For line geometries this
module refuses to guess and raises instead (see :func:`load_geojson_fences`).

Omar's scenario packs (``origin/omar/scenario-packs``) are a *fourth* shape, and
not a Geofence at all. ``pack.json`` keys the layer list as ``geofence_layers``
(build plan says ``layers``), and each entry is a file reference, verified as::

    {"file": "layers/monterey_bay_nms.geojson", "kind": "sanctuary"}

No id, no label, no geometry, no ``buffer_m`` -- so :func:`geofence_from_mapping`
cannot and must not consume it. The correct consumer is::

    load_geojson_fences(pack_dir / entry["file"], origin, kind=entry["kind"])

Two consequences for the pack loader (which is not this module): the pack's
``origin`` is ``{"lat": ..., "lon": ...}``, not the ``[lon, lat]`` sequence this
module's converters take, and a pack layer entry has **nowhere to declare a
buffer**, so a cable layer referenced from a pack cannot be loaded at all until
the entry grows a ``buffer_m`` (this module raises rather than load a
zero-buffered line). Omar's event objects also use ``kind`` where the build plan
says ``type``; that is the event contract, not this one.
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass
from typing import Any, Iterable, Mapping, Sequence

import numpy as np
import shapely
from shapely.geometry import LineString, MultiLineString, MultiPolygon, Polygon
from shapely.geometry.base import BaseGeometry

__all__ = [
    "Geofence",
    "GeofenceIndex",
    "GeofenceContractError",
    "polygon_fence",
    "corridor_fence",
    "lonlat_to_enu",
    "normalize_kind",
    "geofence_from_ring",
    "geofence_from_mapping",
    "load_geojson_fences",
    "CANONICAL_KINDS",
    "KIND_ALIASES",
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


# ==========================================================================
# INTEROP: kind vocabulary, foreign-shape adapters, GeoJSON loading
# ==========================================================================


class GeofenceContractError(ValueError):
    """A foreign fence shape could not be adapted, and guessing would be worse.

    A ``ValueError`` subclass so existing ``except ValueError`` handlers still
    catch it, but nameable on its own for callers that want to report "your fence
    file is wrong" distinctly from arithmetic failures.
    """


#: The only kind values that may reach :class:`Geofence`. Downstream severity
#: rules (Jac) switch on these four strings; anything else is a merge bug.
CANONICAL_KINDS: tuple[str, ...] = ("mpa", "cable", "port", "danger")

#: Foreign vocabulary -> canonical kind. Keys are already normalized (lowercase,
#: underscore-separated); :func:`normalize_kind` normalizes its input the same
#: way, so "Marine Sanctuary", "marine-sanctuary" and "MARINE_SANCTUARY" all hit
#: the same entry. Includes Abhi's vocabulary and the GeoJSON property values
#: that show up in NOAA / Natural Earth / NGA layers.
KIND_ALIASES: dict[str, str] = {
    # -> mpa
    "mpa": "mpa",
    "sanctuary": "mpa",
    "marine_sanctuary": "mpa",
    "national_marine_sanctuary": "mpa",
    "nms": "mpa",
    "protected": "mpa",
    "protected_area": "mpa",
    "marine_protected_area": "mpa",
    "reserve": "mpa",
    "preserve": "mpa",
    # -> danger
    "danger": "danger",
    "danger_zone": "danger",
    "restricted": "danger",
    "restricted_area": "danger",
    "military": "danger",
    "military_area": "danger",
    "exclusion": "danger",
    "exclusion_zone": "danger",
    "hazard": "danger",
    # -> port
    "port": "port",
    "anchorage": "port",
    "harbor": "port",
    "harbour": "port",
    "terminal": "port",
    "berth": "port",
    # -> cable
    "cable": "cable",
    "cable_corridor": "cable",
    "corridor": "cable",
    "submarine_cable": "cable",
    "subsea_cable": "cable",
    "pipeline": "cable",
}

# Sentinel distinguishing "caller passed default=None" from "caller passed no
# default at all". None is a legitimate thing to want back.
_NO_DEFAULT = object()

# Property keys a GeoJSON feature may use to declare its kind. An allowlist, on
# purpose: scanning every property value for something alias-shaped is how a
# fence silently acquires a kind from an unrelated attribute.
_KIND_PROPERTY_KEYS = ("kind", "type", "category", "class", "fence_type", "layer")
_LABEL_PROPERTY_KEYS = ("label", "name", "title", "sanctuary")
_ID_PROPERTY_KEYS = ("id", "fence_id", "geofence_id", "poly_id")

_ID_FIELDS = ("id", "fence_id", "geofence_id")
_LABEL_FIELDS = ("label", "name", "title")
_KIND_FIELDS = ("kind", "type", "category")
_GEOM_FIELDS = ("geom", "polygon", "ring", "coordinates")


def _norm_token(raw: object) -> str:
    """Lowercase, trim, and fold spaces/hyphens/dots to single underscores."""
    s = str(raw).strip().lower()
    for ch in (" ", "-", ".", "/"):
        s = s.replace(ch, "_")
    while "__" in s:
        s = s.replace("__", "_")
    return s.strip("_")


def normalize_kind(raw: str, *, default: Any = _NO_DEFAULT) -> str:
    """Map any known fence vocabulary onto one of :data:`CANONICAL_KINDS`.

    Case-insensitive and tolerant of spaces, hyphens and underscores, so
    ``"Marine Sanctuary"``, ``"marine-sanctuary"`` and ``"MARINE_SANCTUARY"``
    all resolve to ``"mpa"``.

    UNKNOWN INPUT RAISES :class:`GeofenceContractError`. It is not mapped to
    anything. The reasoning:

    * Falling back to ``"mpa"`` invents a marine protected area that does not
      exist. Downstream, "dark vessel inside an MPA" is the CRITICAL rule -- a
      typo in a properties field would manufacture the demo's top alert.
    * Falling back to ``"danger"`` is the *conservative* choice for alerting,
      and it is what a hot path with no operator present should do -- but this
      is not a hot path. Kinds are resolved once, at scenario load, from a
      handful of static files, by a human who can fix the typo in seconds.
      Silently laundering "sancturay" into "danger" trades a loud failure at
      load time for a quiet wrong severity for the whole replay.
    * The two fallbacks disagree about which way to be wrong, which is itself
      evidence that neither is a safe default.

    Callers who genuinely want a fallback must say so explicitly, per call, via
    the keyword-only ``default`` -- which is then returned verbatim and *not*
    validated, so ``default="danger"`` is available to anyone who wants the
    conservative behaviour and has decided it is right for their layer.
    """
    token = _norm_token(raw)
    hit = KIND_ALIASES.get(token)
    if hit is not None:
        return hit
    if default is not _NO_DEFAULT:
        return default
    raise GeofenceContractError(
        f"unknown geofence kind {raw!r} (normalized to {token!r}); "
        f"canonical kinds are {CANONICAL_KINDS}. Add an entry to "
        f"tracker.geofence.KIND_ALIASES, pass an explicit kind=, or pass "
        f"normalize_kind(..., default=...) if a fallback is genuinely correct. "
        f"Refusing to guess: an invented kind changes alert severity."
    )


def _resolve_field(m: object, names: Sequence[str]) -> tuple[str, Any] | None:
    """First present, non-None ``(name, value)`` from a dict OR an object.

    Duck-typed so a plain dict, a ``dataclass`` instance and an ad-hoc namespace
    all work without importing anything from a teammate's branch.
    """
    for name in names:
        if isinstance(m, Mapping):
            if name in m and m[name] is not None:
                return name, m[name]
        else:
            val = getattr(m, name, None)
            if val is not None:
                return name, val
    return None


def _coord_depth(obj: object) -> int:
    """Nesting depth of a coordinate structure: 1 for ``[x, y]``, 2 for a ring,
    3 for a list of rings. Works on lists, tuples and numpy arrays."""
    if isinstance(obj, np.ndarray):
        return int(obj.ndim)
    depth = 0
    cur = obj
    while isinstance(cur, (list, tuple)) and len(cur) > 0:
        depth += 1
        cur = cur[0]
    return depth


def _as_ring(coords: object) -> list[tuple[float, float]]:
    """Coerce anything ring-shaped into a list of ``(x, y)`` float tuples.

    Accepts lists of lists, lists of tuples and ``(N, 2)`` numpy arrays. Closed
    rings (first == last) and unclosed ones both work: shapely closes a ring
    itself, and a duplicated final vertex is harmless, so we do not touch it.
    """
    arr = np.asarray(coords, dtype=float)
    if arr.ndim != 2 or arr.shape[1] < 2:
        raise GeofenceContractError(
            f"expected a ring of [x, y] pairs, got array of shape {arr.shape}"
        )
    if arr.shape[0] < 3:
        raise GeofenceContractError(
            f"a polygon ring needs at least 3 distinct vertices, got {arr.shape[0]}"
        )
    return [(float(x), float(y)) for x, y in arr[:, :2]]


def _polygon_from_rings(rings: Sequence[object]) -> Polygon:
    """``Polygon(shell, holes)`` from ``[shell, hole, hole, ...]``.

    HOLES MATTER: ``rings[1:]`` are interior boundaries, not extra polygons. A
    sanctuary with a hole punched in it (an excluded harbour, say) must not
    contain points in that hole, so the holes go into the Polygon constructor
    rather than being dropped or unioned.
    """
    shell = _as_ring(rings[0])
    holes = [_as_ring(r) for r in rings[1:]]
    return Polygon(shell, holes)


def _geom_from_coords(coords: object) -> Polygon:
    """Build a polygon from bare coordinates: a ring, or a list of rings."""
    depth = _coord_depth(coords)
    if depth == 2:
        return Polygon(_as_ring(coords))
    if depth == 3:
        return _polygon_from_rings(list(coords))
    raise GeofenceContractError(
        f"cannot read geometry from coordinates of nesting depth {depth}; "
        f"expected a ring [[x, y], ...] (depth 2) or a list of rings "
        f"[shell, hole, ...] (depth 3)"
    )


def geofence_from_ring(
    id: str,
    kind: str,
    label: str,
    ring: Sequence[object],
    buffer_m: float = 0.0,
) -> Geofence:
    """Build a fence from an exterior ring of ``(x, y)`` ENU tuples.

    This is Abhi's ``Geofence.ring`` shape (``Tuple[Tuple[float, float], ...]``,
    closure not required). ``kind`` goes through :func:`normalize_kind`, so his
    vocabulary is accepted here and only canonical kinds leave.
    """
    return polygon_fence(
        id=id,
        kind=normalize_kind(kind),
        label=label,
        coords=_as_ring(ring),
        buffer_m=float(buffer_m),
    )


def geofence_from_mapping(m: object, *, buffer_m: float | None = None) -> Geofence:
    """Build a :class:`Geofence` from any of the three contract shapes.

    Duck-typed: ``m`` may be a ``dict`` (the build plan's shape, or a scenario
    pack's layer entry) or any object with attributes (Abhi's frozen dataclass,
    a namespace, an ORM row). Resolution order, first match wins:

    ==========  =====================================================
    ``id``      ``id`` / ``fence_id`` / ``geofence_id``
    ``label``   ``label`` / ``name`` / ``title``  (falls back to ``id``)
    ``kind``    ``kind`` / ``type`` / ``category``, then :func:`normalize_kind`
    geometry    ``geom`` / ``polygon`` / ``ring`` / ``coordinates``
    ``buffer_m````buffer_m``, else the ``buffer_m=`` argument, else ``0.0``
    ==========  =====================================================

    ``buffer_m`` defaults to ``0.0`` because Abhi's dataclass has no such field.
    That is right for polygons and WRONG for cable corridors -- pass
    ``buffer_m=`` when importing a cable layer through this adapter.

    RE-BUFFER RULE. ``Geofence.geom`` is *already buffered* and ``buffer_m`` is
    provenance only, so this adapter must not double-buffer a round trip:

    * geometry arrives as an areal shapely geometry (Polygon/MultiPolygon)
      -> taken verbatim, ``buffer_m`` recorded as provenance, nothing applied;
    * geometry arrives as raw coordinates -> polygonized, then buffered if
      ``buffer_m > 0``;
    * geometry arrives as a shapely line -> buffered, and ``buffer_m > 0`` is
      REQUIRED, because a zero-buffered line has no area and can never contain
      anything.

    Raises :class:`GeofenceContractError` naming the field that was missing.
    A geometry is never guessed or synthesised.
    """
    found_id = _resolve_field(m, _ID_FIELDS)
    if found_id is None:
        raise GeofenceContractError(
            f"geofence is missing an id: none of {_ID_FIELDS} present on "
            f"{type(m).__name__}"
        )
    fence_id = str(found_id[1])

    found_geom = _resolve_field(m, _GEOM_FIELDS)
    if found_geom is None:
        raise GeofenceContractError(
            f"geofence {fence_id!r} is missing a geometry: none of {_GEOM_FIELDS} "
            f"present on {type(m).__name__}. Refusing to guess a geometry."
        )

    found_kind = _resolve_field(m, _KIND_FIELDS)
    if found_kind is None:
        raise GeofenceContractError(
            f"geofence {fence_id!r} is missing a kind: none of {_KIND_FIELDS} "
            f"present on {type(m).__name__}; expected one of {CANONICAL_KINDS} "
            f"or a known alias"
        )
    kind = normalize_kind(found_kind[1])

    found_label = _resolve_field(m, _LABEL_FIELDS)
    label = str(found_label[1]) if found_label is not None else fence_id

    if buffer_m is None:
        found_buf = _resolve_field(m, ("buffer_m",))
        buf = float(found_buf[1]) if found_buf is not None else 0.0
    else:
        buf = float(buffer_m)

    raw_geom = found_geom[1]
    # isinstance FIRST: a shapely geometry is iterable-ish enough that coercing
    # it as a coordinate sequence fails in a confusing way instead of a clear
    # one, and the asdict round trip hands us exactly that.
    if isinstance(raw_geom, BaseGeometry):
        if raw_geom.is_empty:
            raise GeofenceContractError(
                f"geofence {fence_id!r} has an empty geometry ({raw_geom.geom_type})"
            )
        if raw_geom.area > 0.0:
            geom: BaseGeometry = raw_geom          # already buffered; verbatim
        else:
            if buf <= 0.0:
                raise GeofenceContractError(
                    f"geofence {fence_id!r} has a zero-area "
                    f"{raw_geom.geom_type} geometry and buffer_m={buf}; a "
                    f"zero-buffered line can never contain a point. Pass "
                    f"buffer_m > 0 for a corridor."
                )
            geom = raw_geom.buffer(buf)
    else:
        geom = _geom_from_coords(raw_geom)
        if buf > 0.0:
            geom = geom.buffer(buf)

    return Geofence(id=fence_id, kind=kind, label=label, geom=geom, buffer_m=buf)


# --------------------------------------------------------------------------
# GeoJSON loading (WGS84 lon/lat in, ENU-metre fences out)
# --------------------------------------------------------------------------

_POLYGONAL = ("Polygon", "MultiPolygon")
_LINEAL = ("LineString", "MultiLineString")


def _features_of(doc: Mapping[str, Any], path: str) -> list[Mapping[str, Any]]:
    """Normalize FeatureCollection / Feature / bare geometry into features."""
    doc_type = doc.get("type")
    if doc_type == "FeatureCollection":
        feats = doc.get("features")
        if feats is None:
            raise GeofenceContractError(
                f"{path}: FeatureCollection has no 'features' member"
            )
        return list(feats)
    if doc_type == "Feature":
        return [doc]
    if doc_type in _POLYGONAL + _LINEAL:
        # Bare geometry: wrap it so one code path handles everything.
        return [{"type": "Feature", "geometry": doc, "properties": {}}]
    raise GeofenceContractError(
        f"{path}: unsupported GeoJSON type {doc_type!r}; expected "
        f"FeatureCollection, Feature, or one of {_POLYGONAL + _LINEAL}"
    )


def _prop_lookup(props: Mapping[str, Any], keys: Sequence[str]) -> Any:
    """Case-insensitive first hit over ``keys`` in a properties dict."""
    lowered = {_norm_token(k): v for k, v in props.items()}
    for key in keys:
        val = lowered.get(key)
        if val is not None and val != "":
            return val
    return None


def _project(coords: Sequence[Sequence[float]], origin) -> np.ndarray:
    """Project one GeoJSON position list to ENU, dropping any elevation.

    GeoJSON positions are legally ``[lon, lat]`` OR ``[lon, lat, alt]``, and
    ``lonlat_to_enu`` reshapes to (-1, 2) -- which for an (N, 3) input with even
    N does not raise, it reinterprets the buffer into garbage coordinates that
    still pass "area > 0". So the third ordinate is sliced off *here*, before the
    converter sees it. Not fixed inside ``lonlat_to_enu``: other modules import
    it and its (-1, 2) contract is theirs too.
    """
    arr = np.asarray(coords, dtype=float)
    if arr.ndim != 2 or arr.shape[1] < 2:
        raise GeofenceContractError(
            f"expected a list of [lon, lat] positions, got shape {arr.shape}"
        )
    return lonlat_to_enu(arr[:, :2], origin)


def _rings_to_enu(rings: Sequence[Sequence[Sequence[float]]], origin) -> Polygon:
    """One GeoJSON polygon (shell + holes), each ring projected separately."""
    enu = [_project(r, origin) for r in rings]
    return _polygon_from_rings(enu)


def load_geojson_fences(
    path: str | os.PathLike[str],
    origin_lonlat: Sequence[float],
    *,
    default_buffer_m: float = 0.0,
    kind: str | None = None,
    label: str | None = None,
) -> list[Geofence]:
    """Load a WGS84 lon/lat GeoJSON file into ENU-metre :class:`Geofence` objects.

    Every coordinate is projected through :func:`lonlat_to_enu` about
    ``origin_lonlat`` at load time, so nothing downstream ever sees degrees.

    Accepts a ``FeatureCollection``, a single ``Feature``, or a bare geometry.

    ONE GEOFENCE PER FEATURE, including MultiPolygon. A multi-part feature keeps
    its parts in a single MultiPolygon geometry under one id rather than being
    split into N fences: a feature is one *named* area, and splitting it would
    make a vessel crossing between parts of the same sanctuary look like it left
    one fence and entered another, breaking alert de-duplication downstream.

    Line geometries (a cable route) are buffered into a corridor here, once.
    **A non-zero buffer is required for lines** -- a zero-buffered line has no
    area, can never contain a point, and would silently never fire. Enforced
    per *geometry*, so a mixed collection only demands a buffer for its line
    features.

    ``kind`` resolution: the explicit ``kind=`` argument, else an allowlisted
    feature property (``kind`` / ``type`` / ``category`` / ``class`` /
    ``fence_type`` / ``layer``) through :func:`normalize_kind`, else ``"cable"``
    for a line geometry (geometry is dispositive: a buffered line *is* a
    corridor), else raise. Kind is never inferred from the filename -- that is
    the same guessing :func:`normalize_kind` refuses to do.

    ``label`` resolution: the explicit ``label=`` argument, else a feature
    property (``label`` / ``name`` / ``title`` / ``sanctuary``), else the
    filename stem. Ids come from ``id`` / ``fence_id`` / ``geofence_id`` /
    ``poly_id`` properties, else ``<stem>-<index>``; duplicates get a ``#n``
    suffix so :class:`GeofenceIndex` lookups stay unambiguous.
    """
    path_s = os.fspath(path)
    stem = os.path.splitext(os.path.basename(path_s))[0]
    with open(path_s, "r", encoding="utf-8") as fh:
        doc = json.load(fh)

    buf = float(default_buffer_m)
    out: list[Geofence] = []
    seen: dict[str, int] = {}

    for i, feat in enumerate(_features_of(doc, path_s)):
        geometry = feat.get("geometry") if isinstance(feat, Mapping) else None
        if not geometry:
            raise GeofenceContractError(
                f"{path_s}: feature {i} has no geometry (null-geometry features "
                f"are not fences)"
            )
        gtype = geometry.get("type")
        coords = geometry.get("coordinates")
        if coords is None:
            raise GeofenceContractError(
                f"{path_s}: feature {i} geometry {gtype!r} has no 'coordinates'"
            )
        props = feat.get("properties") or {}

        # --- geometry ----------------------------------------------------
        if gtype == "Polygon":
            geom: BaseGeometry = _rings_to_enu(coords, origin_lonlat)
            if buf > 0.0:
                geom = geom.buffer(buf)
        elif gtype == "MultiPolygon":
            parts = [_rings_to_enu(rings, origin_lonlat) for rings in coords]
            geom = MultiPolygon(parts)
            if buf > 0.0:
                geom = geom.buffer(buf)
        elif gtype in _LINEAL:
            if buf <= 0.0:
                raise GeofenceContractError(
                    f"{path_s}: feature {i} is a {gtype} and default_buffer_m="
                    f"{buf}. A zero-buffered line has no area and can never "
                    f"contain anything, so this fence would silently never "
                    f"fire. Pass default_buffer_m > 0 for a cable/route layer."
                )
            if gtype == "LineString":
                line: BaseGeometry = LineString(_project(coords, origin_lonlat))
            else:
                line = MultiLineString(
                    [_project(part, origin_lonlat) for part in coords]
                )
            geom = line.buffer(buf)
        else:
            raise GeofenceContractError(
                f"{path_s}: feature {i} has unsupported geometry type {gtype!r}; "
                f"supported: {_POLYGONAL + _LINEAL}"
            )

        # --- kind --------------------------------------------------------
        if kind is not None:
            fkind = normalize_kind(kind)
        else:
            raw_kind = _prop_lookup(props, _KIND_PROPERTY_KEYS)
            if raw_kind is not None:
                fkind = normalize_kind(raw_kind)
            elif gtype in _LINEAL:
                fkind = "cable"
            else:
                raise GeofenceContractError(
                    f"{path_s}: feature {i} declares no kind (looked for "
                    f"properties {_KIND_PROPERTY_KEYS}) and its geometry "
                    f"({gtype}) does not imply one. Pass kind= explicitly."
                )

        # --- label and id ------------------------------------------------
        if label is not None:
            flabel = label
        else:
            raw_label = _prop_lookup(props, _LABEL_PROPERTY_KEYS)
            flabel = str(raw_label) if raw_label is not None else stem

        raw_id = _prop_lookup(props, _ID_PROPERTY_KEYS)
        fid = str(raw_id) if raw_id is not None else f"{stem}-{i}"
        if fid in seen:
            seen[fid] += 1
            fid = f"{fid}#{seen[fid]}"
        else:
            seen[fid] = 0

        out.append(
            Geofence(id=fid, kind=fkind, label=flabel, geom=geom, buffer_m=buf)
        )

    return out
