"""The real implementation of the shared vocabulary/coercion contract, in Jac.

WHY THIS FILE, NOT tracker/contracts.py
----------------------------------------
This logic used to live entirely in tracker/contracts.py. It has zero numerical
kernels -- no scipy, no eigendecomposition, no shapely, nothing that needs a
matrix library. It is pure vocabulary, validation and parsing: exactly the
"graph structure and orchestration" category the project's own architecture
splits into Jac, not Python (see jac/geofence.jac and jac/hypothesis.jac for the
numeric-kernels-stay-in-Python / everything-else-goes-in-Jac split this project
already follows). So the real implementation lives here now, and
tracker/contracts.py is a thin re-export shim over it.

Behaviour is a byte-for-byte port of the original tracker/contracts.py: same
vocabulary tables, same silent-failure traps closed the same way (a swapped
origin, a zero-buffered cable corridor, a colliding fence id), same exception
type. See tracker/contracts.py's own (now much shorter) docstring, and the
original module history, for the full rationale behind each trap.

ContractError lives in tracker/contracts.py, not here -- Jac's object archetype
does not cleanly subclass a Python exception with a constructor that takes a
message (verified: `obj ContractError(ValueError) {}` compiles, but
`raise ContractError("msg")` then fails at runtime with
`__init__() takes 1 positional argument but 2 were given`; Jac archetypes are
dataclass-like and do not inherit BaseException's varargs `__init__`). So the
class stays in tracker/contracts.py, and this module resolves it LAZILY, at
the point an error actually needs raising, via `contract_error()` below --
NOT at module-import time. That is deliberate, not a style choice: an
eager `import from tracker.contracts { ContractError }` at the top of this
file is circular (tracker.contracts imports FROM jac.contracts too) and the
cycle only resolves if tracker.contracts happens to be the module that
started the import chain. Any entry point that reaches jac.contracts FIRST
(e.g. a test or tool doing `import jac.contracts` directly, or pytest
collecting a file in an order that hits this module before
tracker/contracts.py) hits a partially-initialized-module ImportError --
confirmed by direct reproduction while building this file. Deferring the
lookup past both modules' import time removes the ordering dependency
entirely: by the time anything actually calls a function in this file that
can fail, both modules are already fully loaded.

This module has NO `with entry` block on purpose: it is a pure-function
library, imported by tracker.contracts and nothing else needs it to run
anything as a program. `jac run jac/contracts.jac` on a library with no entry
block still defines everything and exits without executing any of it -- but
note `jac run` creates/touches `.jac/data/contracts.db` in the cwd regardless
of whether the file has an entry block (verified: it happens even here), so
prefer exercising this module by importing it from Python (which every real
caller does) rather than running it directly.
"""

import re;
import importlib;
import from datetime { datetime, timezone }
import from numpy { isfinite as np_isfinite, asarray as np_asarray }
import from numpy { integer as np_integer, floating as np_floating }


# Sentinel distinguishing "caller passed default=None" from "caller passed no
# default at all". None is a legitimate thing to want back.
glob NO_DEFAULT: any = object();

# Cache for the lazily-resolved ContractError class -- a one-element list so
# it can be mutated in place (see the module docstring for why this is
# resolved lazily rather than imported at module load time).
glob CE_CACHE: list = [];


def contract_error_type() -> type {
    """tracker.contracts.ContractError, resolved on first use and cached.

    Deliberately NOT imported at module level -- see the module docstring.
    By the time any caller actually triggers a validation failure, both
    tracker.contracts and this module are fully loaded, so the import here
    is always safe regardless of which module started the import chain.""";
    if len(CE_CACHE) == 0 {
        mod = importlib.import_module("tracker.contracts");
        CE_CACHE.append(mod.ContractError);
    }
    return CE_CACHE[0];
}


def contract_error(msg: str) -> Exception {
    """Build (but do not raise) a ContractError carrying `msg`.

    Every `raise ContractError(...)` in the original Python module becomes
    `raise contract_error(...)` here -- same exception type and message,
    resolved lazily. See contract_error_type().""";
    cls = contract_error_type();
    return cls(msg);
}


# ==========================================================================
# 1. KIND VOCABULARY
# ==========================================================================

#: The only kind values that may cross a module boundary. "land" is the fifth
#: kind the written contract omits -- the coastline layer is a grounding
#: hazard and clips dark-vessel uncertainty ellipses, and is neither an mpa,
#: a cable corridor, a port nor a danger zone.
glob CANONICAL_KINDS: tuple = ("mpa", "cable", "port", "danger", "land");

#: Foreign vocabulary -> canonical kind. Keys are already normalized
#: (lowercase, underscore-separated); normalize_kind() folds its input the
#: same way.
glob KIND_ALIASES: dict = {
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
    "danger": "danger",
    "danger_zone": "danger",
    "restricted": "danger",
    "restricted_area": "danger",
    "military": "danger",
    "military_area": "danger",
    "exclusion": "danger",
    "exclusion_zone": "danger",
    "hazard": "danger",
    "port": "port",
    "anchorage": "port",
    "harbor": "port",
    "harbour": "port",
    "terminal": "port",
    "berth": "port",
    "cable": "cable",
    "cable_corridor": "cable",
    "corridor": "cable",
    "submarine_cable": "cable",
    "subsea_cable": "cable",
    "pipeline": "cable",
    "land": "land",
    "coastline": "land",
    "coast": "land",
    "shore": "land",
    "shoreline": "land",
    "landmask": "land",
    "terrain": "land",
};


def norm_token(raw: object) -> str {
    """Lowercase, trim, and fold spaces/hyphens/dots/slashes to one underscore.

    Applies to kind *values* only. Field *names* are matched verbatim (see
    resolve_field): folding them would make camelCase spellings such as
    fenceId and bufferMeters unreachable.""";
    s = str(raw).strip().lower();
    for ch in [" ", "-", ".", "/"] {
        s = s.replace(ch, "_");
    }
    while "__" in s {
        s = s.replace("__", "_");
    }
    return s.strip("_");
}


def normalize_kind(raw: str, `default: any = NO_DEFAULT) -> str {
    """Map any known fence vocabulary onto one of CANONICAL_KINDS.

    UNKNOWN INPUT RAISES ContractError -- it is never mapped onto "mpa" or
    "danger" by default. Both are plausible-looking fallbacks and both are
    wrong in different ways (see tracker/contracts.py's docstring); a caller
    who genuinely wants one says so explicitly via default=.""";
    token = norm_token(raw);
    if token in KIND_ALIASES {
        return KIND_ALIASES[token];
    }
    if `default is not NO_DEFAULT {
        return `default;
    }
    raise contract_error(
        f"unknown geofence kind {raw!r} (normalized to {token!r}); canonical "
        f"kinds are {CANONICAL_KINDS}. Add an entry to "
        f"tracker.contracts.KIND_ALIASES, or pass "
        f"normalize_kind(..., default=...) if a fallback is genuinely correct. "
        f"Refusing to guess: an invented kind changes alert severity."
    );
}


# ==========================================================================
# 2. FIELD-NAME RECONCILIATION
# ==========================================================================

#: canonical field -> accepted spellings, in priority order (first match wins).
#: Spellings are matched verbatim, not normalized, so camelCase entries
#: (fenceId, bufferMeters) stay reachable.
glob FIELD_ALIASES: dict = {
    "id": ("id", "fence_id", "geofence_id", "fenceId"),
    "label": ("label", "name", "title"),
    "kind": ("kind", "type", "category"),
    "geometry": ("geometry", "geom", "polygon", "ring", "coordinates", "rings"),
    "buffer_m": ("buffer_m", "buffer", "bufferMeters"),
};


def resolve_field(`obj: object, canonical: str, `default: any = NO_DEFAULT) -> any {
    """Read one canonical field from any of the three shapes: a dict/Mapping
    or an object with attributes. Each accepted spelling in
    FIELD_ALIASES[canonical] is tried in order and the first hit wins.

    ABSENCE IS None, AND NOTHING ELSE -- 0, 0.0, "" and [] are all *present*
    values and returned as-is. This matters most for buffer_m: 0.0 is a
    meaningful, deliberate buffer, and treating it as missing would silently
    substitute a default and change the fence's geometry.""";
    if canonical not in FIELD_ALIASES {
        raise contract_error(
            f"{canonical!r} is not a canonical field; known fields are "
            f"{tuple(FIELD_ALIASES.keys())}"
        );
    }
    names = FIELD_ALIASES[canonical];
    for name in names {
        if isinstance(`obj, dict) {
            if name in `obj and `obj[name] is not None {
                return `obj[name];
            }
        } else {
            val = getattr(`obj, name, None);
            if val is not None {
                return val;
            }
        }
    }
    if `default is not NO_DEFAULT {
        return `default;
    }
    raise contract_error(
        f"cannot resolve canonical field {canonical!r} on "
        f"{type(`obj).__name__}: tried spellings {names} and found none "
        f"(a present-but-None value counts as absent). Pass an explicit "
        f"default= if absence is acceptable here."
    );
}


# ==========================================================================
# 3. ORIGIN AND BBOX PARSING  (a swapped pair is a silent ~1000 km bug)
# ==========================================================================

glob LAT_KEYS: tuple = ("lat", "latitude");
glob LON_KEYS: tuple = ("lon", "longitude", "lng", "long");


def finite(value: object, what: str) -> float {
    """float(value), refusing NaN/inf -- both propagate silently through the
    projection and produce empty geometry with no error.""";
    try {
        out = float(value);
    } except (TypeError, ValueError) as exc {
        raise contract_error(f"{what}: {value!r} is not a number") from exc;
    }
    if not np_isfinite(out) {
        raise contract_error(f"{what}: {value!r} is not finite");
    }
    return out;
}


def lookup(m: object, keys: tuple) -> any {
    for key in keys {
        if key in m and m[key] is not None {
            return m[key];
        }
    }
    return None;
}


def parse_origin(origin: object) -> tuple {
    """Coerce a scenario origin into (lon, lat) -- always that order.

    A mapping with lat/lon keys is unambiguous and always preferred. A bare
    2-sequence is ambiguous: it is read as GeoJSON order (lon, lat) when that
    reading is in range, and the function REFUSES to guess (raises) when the
    pair is only self-consistent the other way round -- silently reordering
    it is precisely how a ~1000 km position bug ships.""";
    if isinstance(origin, dict) {
        raw_lat = lookup(origin, LAT_KEYS);
        raw_lon = lookup(origin, LON_KEYS);
        if raw_lat is None or raw_lon is None {
            raise contract_error(
                f"origin mapping must carry both a latitude and a longitude: "
                f"looked for {LAT_KEYS} and {LON_KEYS}, got keys "
                f"{sorted([str(k) for k in origin.keys()])}"
            );
        }
        lat = finite(raw_lat, "origin latitude");
        lon = finite(raw_lon, "origin longitude");
        if abs(lat) > 90.0 {
            raise contract_error(f"origin latitude {lat} is outside [-90, 90]");
        }
        if abs(lon) > 180.0 {
            raise contract_error(f"origin longitude {lon} is outside [-180, 180]");
        }
        return (lon, lat);
    }

    if isinstance(origin, (list, tuple)) or hasattr(origin, "ravel") {
        seq = list(np_asarray(origin, dtype=object).ravel());
        if len(seq) != 2 {
            raise contract_error(
                f"a bare origin sequence must have exactly 2 values "
                f"(lon, lat); got {len(seq)}"
            );
        }
        a = finite(seq[0], "origin[0]");
        b = finite(seq[1], "origin[1]");
        ok_direct = abs(a) <= 180.0 and abs(b) <= 90.0;
        ok_swapped = abs(b) <= 180.0 and abs(a) <= 90.0;
        if ok_direct {
            return (a, b);
        }
        if ok_swapped {
            raise contract_error(
                f"ambiguous origin {(a, b)}: read as GeoJSON (lon, lat) the "
                f"latitude {b} is outside [-90, 90], but the pair is valid "
                f"reversed -- it looks like (lat, lon). Refusing to reorder it "
                f"for you: a silently swapped origin is a ~1000 km position "
                f'error with no other symptom. Pass {{"lat": {a}, "lon": {b}}} '
                f"to say which is which."
            );
        }
        raise contract_error(
            f"origin {(a, b)} is out of range under either reading: need "
            f"|lon| <= 180 and |lat| <= 90"
        );
    }

    raise contract_error(
        f"cannot read an origin from {type(origin).__name__}; expected "
        f'{{"lat": .., "lon": ..}} or a 2-sequence (lon, lat)'
    );
}


def parse_bbox(bbox: object) -> tuple {
    """Coerce a scenario bbox into (lon_min, lat_min, lon_max, lat_max).

    No swap heuristic here (deliberately, unlike parse_origin): a 4-element
    bbox is positional and its ordering is fixed by both the GeoJSON spec and
    the explicit-key form, so each ordinate is range-checked in place.
    Requires strict min < max -- a degenerate box has zero area and silently
    selects nothing.""";
    if isinstance(bbox, dict) {
        vals = [];
        for key in ["lon_min", "lat_min", "lon_max", "lat_max"] {
            if bbox.get(key) is None {
                raise contract_error(
                    f"bbox mapping is missing {key!r}; need lon_min, lat_min, "
                    f"lon_max, lat_max (got keys "
                    f"{sorted([str(k) for k in bbox.keys()])})"
                );
            }
            vals.append(finite(bbox[key], f"bbox {key}"));
        }
        lon_min = vals[0];
        lat_min = vals[1];
        lon_max = vals[2];
        lat_max = vals[3];
    } elif isinstance(bbox, (list, tuple)) or hasattr(bbox, "ravel") {
        seq = list(np_asarray(bbox, dtype=object).ravel());
        if len(seq) != 4 {
            raise contract_error(
                f"a bbox sequence must have exactly 4 values "
                f"(lon_min, lat_min, lon_max, lat_max); got {len(seq)}"
            );
        }
        lon_min = finite(seq[0], "bbox lon_min");
        lat_min = finite(seq[1], "bbox lat_min");
        lon_max = finite(seq[2], "bbox lon_max");
        lat_max = finite(seq[3], "bbox lat_max");
    } else {
        raise contract_error(
            f"cannot read a bbox from {type(bbox).__name__}; expected a mapping "
            f"with lon_min/lat_min/lon_max/lat_max or a 4-sequence"
        );
    }

    for pair in [("lon_min", lon_min), ("lon_max", lon_max)] {
        name = pair[0];
        value = pair[1];
        if abs(value) > 180.0 {
            raise contract_error(f"bbox {name} {value} is outside [-180, 180]");
        }
    }
    for pair in [("lat_min", lat_min), ("lat_max", lat_max)] {
        name = pair[0];
        value = pair[1];
        if abs(value) > 90.0 {
            raise contract_error(f"bbox {name} {value} is outside [-90, 90]");
        }
    }
    if not lon_min < lon_max {
        raise contract_error(
            f"bbox lon_min ({lon_min}) must be strictly less than lon_max "
            f"({lon_max}); a degenerate box has no area and selects nothing"
        );
    }
    if not lat_min < lat_max {
        raise contract_error(
            f"bbox lat_min ({lat_min}) must be strictly less than lat_max "
            f"({lat_max}); a degenerate box has no area and selects nothing"
        );
    }
    return (lon_min, lat_min, lon_max, lat_max);
}


# ==========================================================================
# 4. BUFFER DEFAULTS BY KIND
# ==========================================================================

#: canonical kind -> the buffer, in metres, to use when no buffer_m is given.
#: cable is the only non-zero entry: a cable corridor's source geometry is a
#: LineString, and with buffer_m = 0.0 the fence is a zero-area line that can
#: NEVER contain a point. Every areal kind defaults to 0.0 -- a polygon fence
#: already has area, and an unrequested buffer would quietly enlarge a
#: sanctuary and over-report intrusions.
glob DEFAULT_BUFFER_M_BY_KIND: dict = {
    "mpa": 0.0,
    "cable": 500.0,
    "port": 0.0,
    "danger": 0.0,
    "land": 0.0,
};


def default_buffer_m(kind: str) -> float {
    """The default buffer in metres for `kind`, which is normalized first.

    Normalizing first is load-bearing: a raw dict lookup on an unnormalized
    spelling like "cable_corridor" would KeyError, and a caller wrapping this
    in a try would most likely turn that back into 0.0 -- re-creating the
    exact zero-buffered-cable trap this table exists to close.""";
    return DEFAULT_BUFFER_M_BY_KIND[normalize_kind(kind)];
}


# ==========================================================================
# 5. ID NAMESPACING  (fixes a silent fence swap)
# ==========================================================================

glob NON_ALNUM = re.compile(r"[^a-z0-9]+");


def sanitise_layer(layer: str) -> str {
    """Lowercase, fold runs of non-alphanumerics to a single underscore, trim.

    Keeps namespaced ids stable across the ways a layer gets named: a file
    stem, a display name and a path fragment for the same layer must not
    produce three different id namespaces.""";
    out = NON_ALNUM.sub("_", str(layer).strip().lower()).strip("_");
    if not out {
        raise contract_error(
            f"layer name {layer!r} sanitises to the empty string; it cannot "
            f"namespace an id"
        );
    }
    return out;
}


def namespaced_id(layer: str, raw_id: object) -> str {
    """"<sanitised layer>:<raw id>", e.g. "monterey_bay_nms:1".

    Namespacing by layer makes an id collision between two layers impossible
    instead of merely unlikely (see tracker/contracts.py's docstring for the
    Monterey POLY_ID=1 collision this closes). The raw id is kept verbatim
    (only stringified) so it still matches the source file's property.""";
    text = str(raw_id).strip();
    if not text {
        raise contract_error(f"cannot namespace an empty raw id (layer {layer!r})");
    }
    return f"{sanitise_layer(layer)}:{text}";
}


def dedupe_ids(ids: list) -> list {
    """Make `ids` unique in place-order by suffixing collisions #1, #2.

    Order-preserving and deterministic: the first occurrence keeps its id,
    later ones get the lowest free suffix, re-checked against everything
    already emitted so a run like ["1", "1", "1#1"] cannot emit "1#1" twice.""";
    seen = set();
    out = [];
    for raw in ids {
        base = str(raw);
        candidate = base;
        n = 0;
        while candidate in seen {
            n += 1;
            candidate = f"{base}#{n}";
        }
        seen.add(candidate);
        out.append(candidate);
    }
    return out;
}


def assert_unique_ids(ids: object) -> None {
    """Raise ContractError listing every duplicated id, or return None.

    Complements dedupe_ids: right when duplicates mean something upstream is
    already wrong (two layers claiming the same fence) and silently renaming
    would paper over it.""";
    counts = {};
    for raw in ids {
        key = str(raw);
        if key in counts {
            counts[key] = counts[key] + 1;
        } else {
            counts[key] = 1;
        }
    }
    dupes = sorted([k for k in counts.keys() if counts[k] > 1]);
    if len(dupes) > 0 {
        parts = [];
        for k in dupes {
            parts.append(f"{k!r} x{counts[k]}");
        }
        detail = ", ".join(parts);
        raise contract_error(
            f"duplicate ids: {detail}. A last-wins id map would silently drop "
            f"one of each pair. Namespace them with namespaced_id(layer, id), "
            f"or call dedupe_ids() if a #n suffix is acceptable here."
        );
    }
}


# ==========================================================================
# 6. TIME PARSING
# ==========================================================================

def parse_epoch(value: object) -> float {
    """Coerce a timestamp to UTC epoch seconds.

    Accepted: an int/float epoch (passed through), an ISO-8601 string (with a
    Z suffix, an explicit offset, or none), or a datetime.

    A NAIVE datetime or ISO string is treated as UTC. Python's default is the
    opposite (the machine's local zone), which would replay the same scenario
    pack at a different wall-clock time on every developer's laptop and shift
    every timestamp by whole hours, silently, since the numbers stay
    plausible.""";
    if isinstance(value, bool) {
        # bool is an int subclass; a True timestamp is a bug, not epoch 1.
        raise contract_error(f"cannot read a timestamp from {value!r}");
    }
    if isinstance(value, datetime) {
        dt = value;
    } elif isinstance(value, (int, float, np_integer, np_floating)) {
        return finite(value, "epoch seconds");
    } elif isinstance(value, str) {
        text = value.strip();
        if not text {
            raise contract_error("cannot read a timestamp from an empty string");
        }
        try {
            dt = datetime.fromisoformat(text);
        } except ValueError {
            try {
                numeric = float(text);
            } except ValueError {
                raise contract_error(
                    f"cannot parse timestamp {value!r}: expected ISO-8601 "
                    f"(e.g. '2024-06-15T06:00:00+00:00') or epoch seconds"
                ) from None;
            }
            return finite(numeric, "epoch seconds");
        }
    } else {
        raise contract_error(
            f"cannot read a timestamp from {type(value).__name__}; expected "
            f"epoch seconds, an ISO-8601 string, or a datetime"
        );
    }

    if dt.tzinfo is None {
        # THE naive branch. Do not delete: without it, .timestamp() silently
        # applies the local zone.
        dt = dt.replace(tzinfo=timezone.utc);
    }
    return dt.timestamp();
}


glob START_KEYS: tuple = ("start", "start_t", "t0", "begin");
glob END_KEYS: tuple = ("end", "end_t", "t1", "finish");


def parse_time_window(tw: object) -> tuple {
    """Coerce a time window to (start_epoch, end_epoch) in UTC seconds.

    Accepts a mapping ({"start": iso, "end": iso} or {"start_t": epoch,
    "end_t": epoch}, mixed forms too) or a positional 2-sequence [start, end].
    Requires start < end: a zero-length or reversed window replays nothing
    and would otherwise look like a scenario with no detections.""";
    if isinstance(tw, dict) {
        raw_start = lookup(tw, START_KEYS);
        raw_end = lookup(tw, END_KEYS);
        if raw_start is None or raw_end is None {
            raise contract_error(
                f"time window must carry both bounds: looked for {START_KEYS} "
                f"and {END_KEYS}, got keys {sorted([str(k) for k in tw.keys()])}"
            );
        }
    } elif isinstance(tw, (list, tuple)) {
        if len(tw) != 2 {
            raise contract_error(
                f"a bare time window sequence must have exactly 2 values "
                f"(start, end); got {len(tw)}"
            );
        }
        raw_start = tw[0];
        raw_end = tw[1];
    } else {
        raise contract_error(
            f"cannot read a time window from {type(tw).__name__}; expected "
            f'{{"start": .., "end": ..}}, {{"start_t": .., "end_t": ..}} or a '
            f"2-sequence"
        );
    }

    start = parse_epoch(raw_start);
    end = parse_epoch(raw_end);
    if not start < end {
        raise contract_error(
            f"time window start ({start}) must be strictly before end ({end}); "
            f"an empty window replays nothing and looks like a scenario with no "
            f"detections"
        );
    }
    return (start, end);
}
