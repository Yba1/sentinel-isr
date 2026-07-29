"""Fence loading/adaptation orchestration, in Jac.

WHAT LIVES HERE AND WHY
------------------------
`tracker/geofence.py` used to mix two very different things: genuine shapely
geometry kernels (Polygon/LineString construction, STRtree, `.buffer()`,
`.difference()`) and pure decision logic that never touches a shapely
geometry's math -- it only decides WHICH fields to read, WHAT kind a fence is,
HOW to namespace an id, WHICH GeoJSON feature type it is. That second category
is exactly the "graph structure and orchestration" split this project's
architecture puts in Jac (see jac/geofence.jac and jac/contracts.jac for the
same split already applied elsewhere).

This file holds that orchestration for THREE adapters and one bookkeeping
helper:

  decide_ring_fence      -- geofence_from_ring's field/argument bookkeeping
  decide_mapping_fence    -- geofence_from_mapping's field-resolution orchestration
  decide_geojson_fences   -- load_geojson_fences's FeatureCollection walking,
                             per-feature kind/label/id/buffer decisions
  decide_build_index      -- build_index's layer-namespacing/collision bookkeeping

None of these functions call a shapely constructor or a shapely method
directly. Every actual geometry build (Polygon/LineString/MultiPolygon
construction, `.buffer()`) happens in a small, clearly-named Python kernel in
tracker/geofence.py (`polygon_fence`, `corridor_fence`, `_as_ring`,
`_geom_from_coords`, `_feature_geometry`, `_buffer_geometry`, ...), and this
file calls back into those. `Geofence` and `GeofenceIndex` stay Python
dataclasses; this file constructs `Geofence` instances (a plain dataclass
call, not a geometry operation) but never builds or mutates a `.geom` itself.

THE MECHANISM (see jac/contracts.jac and tracker/contracts.py for the proven
sibling of this exact trick)
------------------------------------------------------------------------
tracker/geofence.py does:

    <everything Jac needs is defined first: Geofence, GeofenceIndex,
     polygon_fence, corridor_fence, GeofenceContractError, normalize_kind,
     CANONICAL_KINDS, _as_ring, _polygon_from_rings, _geom_from_coords,
     _feature_geometry, _buffer_geometry, _POLYGONAL, _LINEAL>

    import jaclang                      # registers the .jac meta importer
    from jac.fences import (
        decide_ring_fence, decide_mapping_fence,
        decide_geojson_fences, decide_build_index,
    )

    <then the public geofence_from_ring / geofence_from_mapping /
     load_geojson_fences / build_index become thin wrappers over the above>

This LOOKS circular (tracker.geofence imports jac.fences, and jac.fences
below imports back from tracker.geofence) but resolves cleanly for the exact
reason tracker/contracts.py's docstring gives: by the time this file's
`import from tracker.geofence { ... }` line runs, tracker.geofence's module
object already has every name this file needs, because they were all defined
BEFORE tracker/geofence.py's `from jac.fences import ...` line executed.

No `with entry` bootstrap block is needed for THIS direction (Python calling
Jac) -- that bootstrap is only needed when Jac calls INTO Python, because
`jac run`/`jac import` do not put the repo root on sys.path automatically.
Here, this module is imported the ordinary Python way (via `from jac.fences
import ...` after `import jaclang`), so it inherits the caller's sys.path,
which already has the repo root on it (tracker.geofence itself could not have
been imported otherwise).

Coordinates that cross this file are whatever tracker/geofence.py's own public
functions accept (ENU metres for the ring/mapping adapters, lon/lat degrees
for the GeoJSON loader) -- this file does not itself convert or interpret
coordinates, it forwards them to the Python kernels that do.
"""

import os;
import json;
import from typing { Any, Mapping }
import from shapely.geometry.base { BaseGeometry }

import from tracker.geofence {
    Geofence,
    GeofenceContractError,
    normalize_kind,
    CANONICAL_KINDS,
    polygon_fence,
    _as_ring,
    _geom_from_coords,
    _feature_geometry,
    _buffer_geometry,
    _POLYGONAL,
    _LINEAL
}
import from tracker.contracts {
    resolve_field,
    default_buffer_m,
    FIELD_ALIASES,
    namespaced_id,
    assert_unique_ids,
    ContractError
}


# ---------------------------------------------------------------------------
# geofence_from_ring orchestration
# ---------------------------------------------------------------------------

def decide_ring_fence(id: str, kind: str, label: str, ring: object, buffer_m: float) -> Geofence {
    """Field/argument bookkeeping for Abhi's `ring` shape: normalize the kind,
    coerce the buffer, and hand the ring off to the Python ring-coercion +
    Polygon-construction kernel. No shapely call happens in this function.""";
    resolved_kind = normalize_kind(kind);
    return polygon_fence(
        id,
        resolved_kind,
        label,
        _as_ring(ring),
        float(buffer_m)
    );
}


# ---------------------------------------------------------------------------
# geofence_from_mapping orchestration
# ---------------------------------------------------------------------------

#: Geometry-field allowlist. A strict superset of
#: contracts.FIELD_ALIASES["geometry"] -- see tracker/geofence.py's module
#: docstring for why geometry stays a local table rather than a contracts one.
glob _GEOM_FIELDS: list = ["geom", "polygon", "ring", "coordinates", "geometry", "rings"];


def _resolve_geom_field(m: object) -> Any {
    """First present, non-None (name, value) from a dict OR an object, over
    `_GEOM_FIELDS`. Duck-typed the same way contracts.resolve_field is, so a
    plain dict, a dataclass instance and an ad-hoc namespace all work.""";
    for name in _GEOM_FIELDS {
        if isinstance(m, Mapping) {
            if name in m and m[name] is not None {
                return (name, m[name]);
            }
        } else {
            val = getattr(m, name, None);
            if val is not None {
                return (name, val);
            }
        }
    }
    return None;
}


def decide_mapping_fence(m: object, buffer_m_arg: Any) -> Geofence {
    """Field-resolution orchestration for any of the three contract shapes.

    Resolves id/label/kind/buffer_m via tracker.contracts.resolve_field and
    tracker.contracts.FIELD_ALIASES, decides which of the three geometry
    cases applies (already-buffered areal shapely geometry / raw zero-area
    shapely line requiring an explicit buffer / bare coordinates to
    polygonize), and calls back into the Python kernels (`_geom_from_coords`,
    `_buffer_geometry`) to do the actual shapely work. See
    tracker.geofence.geofence_from_mapping's docstring for the full contract
    this implements byte-for-byte.""";
    found_id = resolve_field(m, "id", default=None);
    if found_id is None {
        raise GeofenceContractError(
            f"geofence is missing an id: none of {FIELD_ALIASES['id']} "
            f"present on {type(m).__name__}"
        );
    }
    fence_id = str(found_id);

    found_geom = _resolve_geom_field(m);
    if found_geom is None {
        raise GeofenceContractError(
            f"geofence {fence_id!r} is missing a geometry: none of {_GEOM_FIELDS} "
            f"present on {type(m).__name__}. Refusing to guess a geometry."
        );
    }

    found_kind = resolve_field(m, "kind", default=None);
    if found_kind is None {
        raise GeofenceContractError(
            f"geofence {fence_id!r} is missing a kind: none of "
            f"{FIELD_ALIASES['kind']} present on {type(m).__name__}; "
            f"expected one of {CANONICAL_KINDS} or a known alias"
        );
    }
    kind = normalize_kind(found_kind);

    found_label = resolve_field(m, "label", default=None);
    if found_label is not None {
        label = str(found_label);
    } else {
        label = fence_id;
    }

    # `buf` is the EXPLICIT value only (field or argument), never defaulted --
    # it gates the raw-shapely-line REQUIRED check below. `effective_buf` is
    # `buf` with the per-kind default filled in.
    if buffer_m_arg is not None {
        buf = float(buffer_m_arg);
    } else {
        found_buf = resolve_field(m, "buffer_m", default=None);
        if found_buf is not None {
            buf = float(found_buf);
        } else {
            buf = None;
        }
    }
    if buf is not None {
        effective_buf = buf;
    } else {
        effective_buf = default_buffer_m(kind);
    }

    raw_geom = found_geom[1];
    # isinstance FIRST: a shapely geometry is iterable-ish enough that coercing
    # it as a coordinate sequence fails in a confusing way instead of a clear one.
    if isinstance(raw_geom, BaseGeometry) {
        if raw_geom.is_empty {
            raise GeofenceContractError(
                f"geofence {fence_id!r} has an empty geometry ({raw_geom.geom_type})"
            );
        }
        if raw_geom.area > 0.0 {
            geom = raw_geom;             # already buffered; verbatim
            final_buf = effective_buf;
        } else {
            if buf is None or buf <= 0.0 {
                raise GeofenceContractError(
                    f"geofence {fence_id!r} has a zero-area "
                    f"{raw_geom.geom_type} geometry and no explicit buffer_m; a "
                    f"zero-buffered line can never contain a point. Pass "
                    f"buffer_m > 0 (as a field or the buffer_m= argument) for "
                    f"a corridor."
                );
            }
            geom = _buffer_geometry(raw_geom, buf);
            final_buf = buf;
        }
    } else {
        geom = _geom_from_coords(raw_geom);
        if effective_buf > 0.0 {
            geom = _buffer_geometry(geom, effective_buf);
        }
        final_buf = effective_buf;
    }

    return Geofence(id=fence_id, kind=kind, label=label, geom=geom, buffer_m=final_buf);
}


# ---------------------------------------------------------------------------
# load_geojson_fences orchestration
# ---------------------------------------------------------------------------

glob _KIND_PROPERTY_KEYS: tuple = ("kind", "type", "category", "class", "fence_type", "layer");
glob _LABEL_PROPERTY_KEYS: tuple = ("label", "name", "title", "sanctuary");
glob _ID_PROPERTY_KEYS: tuple = ("id", "fence_id", "geofence_id", "poly_id");


def _norm_token(raw: object) -> str {
    """Lowercase, trim, and fold spaces/hyphens/dots to single underscores.""";
    s = str(raw).strip().lower();
    for ch in (" ", "-", ".", "/") {
        s = s.replace(ch, "_");
    }
    while "__" in s {
        s = s.replace("__", "_");
    }
    return s.strip("_");
}


def _prop_lookup(props: object, keys: object) -> Any {
    """Case-insensitive first hit over `keys` in a properties dict.""";
    lowered = {};
    for k in props.keys() {
        lowered[_norm_token(k)] = props[k];
    }
    for key in keys {
        if key in lowered {
            val = lowered[key];
            if val is not None and val != "" {
                return val;
            }
        }
    }
    return None;
}


def _features_of(doc: object, path: str) -> list {
    """Normalize FeatureCollection / Feature / bare geometry into features --
    the GeoJSON document-shape decision, no geometry math involved.""";
    doc_type = doc.get("type");
    if doc_type == "FeatureCollection" {
        feats = doc.get("features");
        if feats is None {
            raise GeofenceContractError(
                f"{path}: FeatureCollection has no 'features' member"
            );
        }
        return list(feats);
    }
    if doc_type == "Feature" {
        return [doc];
    }
    if doc_type in _POLYGONAL or doc_type in _LINEAL {
        return [{"type": "Feature", "geometry": doc, "properties": {}}];
    }
    raise GeofenceContractError(
        f"{path}: unsupported GeoJSON type {doc_type!r}; expected "
        f"FeatureCollection, Feature, or one of {_POLYGONAL + _LINEAL}"
    );
}


def decide_geojson_fences(
    path: str, origin_lonlat: object, default_buffer_m_val: float,
    kind: Any, label: Any, layer: Any
) -> list {
    """Walks a GeoJSON FeatureCollection/Feature/bare-geometry document and
    decides, per feature: which geometry-builder call to make (via
    `_feature_geometry`), whether/how much to buffer (via `_buffer_geometry`),
    and what kind/label/id the resulting fence gets. No coordinate math and no
    shapely construction happens directly in this function -- both are the
    Python kernels this file calls back into.""";
    path_s = os.fspath(path);
    stem = os.path.splitext(os.path.basename(path_s))[0];
    fh = open(path_s, "r", encoding="utf-8");
    doc = json.load(fh);
    fh.close();

    buf = float(default_buffer_m_val);
    out = [];
    seen = {};

    feats = _features_of(doc, path_s);
    i = 0;
    for feat in feats {
        geometry = None;
        if isinstance(feat, Mapping) {
            geometry = feat.get("geometry");
        }
        if not geometry {
            raise GeofenceContractError(
                f"{path_s}: feature {i} has no geometry (null-geometry features "
                f"are not fences)"
            );
        }
        gtype = geometry.get("type");
        coords = geometry.get("coordinates");
        if coords is None {
            raise GeofenceContractError(
                f"{path_s}: feature {i} geometry {gtype!r} has no 'coordinates'"
            );
        }
        props = feat.get("properties");
        if not props {
            props = {};
        }

        # --- geometry: decide which kernel call, and whether to buffer -----
        if gtype in _LINEAL {
            if buf <= 0.0 {
                raise GeofenceContractError(
                    f"{path_s}: feature {i} is a {gtype} and default_buffer_m="
                    f"{buf}. A zero-buffered line has no area and can never "
                    f"contain anything, so this fence would silently never "
                    f"fire. Pass default_buffer_m > 0 for a cable/route layer."
                );
            }
            geom = _feature_geometry(gtype, coords, origin_lonlat);
            geom = _buffer_geometry(geom, buf);
        } elif gtype in _POLYGONAL {
            geom = _feature_geometry(gtype, coords, origin_lonlat);
            if buf > 0.0 {
                geom = _buffer_geometry(geom, buf);
            }
        } else {
            raise GeofenceContractError(
                f"{path_s}: feature {i} has unsupported geometry type {gtype!r}; "
                f"supported: {_POLYGONAL + _LINEAL}"
            );
        }

        # --- kind ------------------------------------------------------
        if kind is not None {
            fkind = normalize_kind(kind);
        } else {
            raw_kind = _prop_lookup(props, _KIND_PROPERTY_KEYS);
            if raw_kind is not None {
                fkind = normalize_kind(raw_kind);
            } elif gtype in _LINEAL {
                fkind = "cable";
            } else {
                raise GeofenceContractError(
                    f"{path_s}: feature {i} declares no kind (looked for "
                    f"properties {_KIND_PROPERTY_KEYS}) and its geometry "
                    f"({gtype}) does not imply one. Pass kind= explicitly."
                );
            }
        }

        # --- label and id ------------------------------------------------
        if label is not None {
            flabel = label;
        } else {
            raw_label = _prop_lookup(props, _LABEL_PROPERTY_KEYS);
            if raw_label is not None {
                flabel = str(raw_label);
            } else {
                flabel = stem;
            }
        }

        raw_id = _prop_lookup(props, _ID_PROPERTY_KEYS);
        if raw_id is not None {
            fid = str(raw_id);
        } else {
            fid = f"{stem}-{i}";
        }
        if fid in seen {
            seen[fid] = seen[fid] + 1;
            fid = f"{fid}#{seen[fid]}";
        } else {
            seen[fid] = 0;
        }

        if layer is not None {
            try {
                fid = namespaced_id(layer, fid);
            } except ContractError as exc {
                raise GeofenceContractError(str(exc)) from exc;
            }
        }

        out.append(Geofence(id=fid, kind=fkind, label=flabel, geom=geom, buffer_m=buf));
        i += 1;
    }

    return out;
}


# ---------------------------------------------------------------------------
# build_index orchestration
# ---------------------------------------------------------------------------

def decide_build_index(fences_by_layer: object) -> list {
    """Layer-namespacing/collision bookkeeping: decides which layer prefix to
    apply to which fence id and detects collisions across the combined set --
    no shapely involved at all. Returns the namespaced fence LIST; the caller
    (tracker.geofence.build_index) wraps it in a GeofenceIndex, since building
    the STRtree is the genuine geometry kernel this function must not touch.""";
    namespaced = [];
    for layer_name in fences_by_layer {
        fences = fences_by_layer[layer_name];
        for f in fences {
            if ":" in f.id {
                namespaced.append(f);
            } else {
                try {
                    new_id = namespaced_id(layer_name, f.id);
                } except ContractError as exc {
                    raise GeofenceContractError(str(exc)) from exc;
                }
                namespaced.append(f.__class__(
                    id=new_id, kind=f.kind, label=f.label, geom=f.geom, buffer_m=f.buffer_m
                ));
            }
        }
    }

    try {
        assert_unique_ids([f.id for f in namespaced]);
    } except ContractError as exc {
        raise GeofenceContractError(str(exc)) from exc;
    }

    return namespaced;
}
