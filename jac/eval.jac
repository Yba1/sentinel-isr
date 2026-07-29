"""Scenario-pack regression harness -- orchestration, in Jac.

WHAT LIVES HERE AND WHY
------------------------
`tracker/eval.py` is the public, importable surface (dataclasses, a couple of
thin wrapper functions, and the CHECKERS/PACK_CHECKS registries so tests can
monkeypatch them). Everything that actually decides what a pack run means --
pack discovery, pack loading, the per-key and per-pack iteration loops, every
individual checker's comparison logic, the projector report, and the CLI --
lives here. None of it is a numerical kernel: it is graph-shaped orchestration
over JSON, exactly the category that belongs in Jac.

THE SEAM WITH PYTHON
---------------------
Every function here that used to return a `CheckResult` now returns a plain
`dict` with the same fields (`key`, `outcome`, `detail`, `expected`, `actual`,
`marginal`). `tracker/eval.py` is the thin Python wrapper that turns those
dicts into the frozen `CheckResult`/`PackResult` dataclasses the public API
promises, so Jac never needs to import the dataclass module -- no circular
import, and the checker/pack-check registries (`CHECKERS`, `PACK_CHECKS`) live
in `tracker/eval.py` as plain Python objects that tests can monkeypatch. The
functions here that iterate them (`evaluate_pack_core`, `evaluate_all_core`,
`main_core`) always take them as PARAMETERS, looked up by the Python wrapper
at call time -- never as a cached reference -- so a monkeypatched entry or a
rebound registry is honoured immediately.

`format_report` and `as_jsonable` are the exception: they are handed the real
`PackResult`/`CheckResult` dataclass instances built by the Python wrapper, and
read them by plain attribute access (`r.pack_id`, `c.marginal`, `r.ok`, ...).
Jac's attribute access is just compiled Python attribute access, so this works
on any Python object without Jac needing to know the dataclass's module.

JAC 0.16.7 QUIRKS WORKED AROUND HERE (verified empirically against this
interpreter, not assumed from docs)
------------------------------------------------------------------------
* `root` is a reserved word (the graph root); a parameter or local named
  `root` silently aliases to it and corrupts type inference into an Internal
  Compiler Error. Every "repo root" parameter here is named `root_dir`.
* `obj` is a reserved word too; avoided as an identifier.
* `for a, b in pairs { ... }` (tuple-unpacking for-loop target) and
  `[(a, b) for a, b in pairs]` (tuple-unpacking comprehension target) are both
  parse errors. Every such loop here takes a single loop variable and indexes
  it (`pair[0]`, `pair[1]`) instead.
* `from module import name;` at module level is a parse error; Jac's spelling
  is `import from module { name }`.
* Nested `def` (a function returning a function) works and is used for
  `make_not_built_checker`, mirroring the original closure-based factory.
* `try { ... } except Exc as e { ... }`, `raise X from Y`, keyword-only
  parameters (`*, results: dict = None`), f-strings with format specs
  (`f"{x:.2f}"`), `dict | None` unions, and calling a callable passed in as a
  parameter all work as in Python.

Independence from the replay layer, the two kinds of check, both contract
spellings, and the rest of the design rationale are exactly as in the original
`tracker/eval.py` docstring (kept there, not duplicated here) -- porting the
orchestration changed nothing about what is checked or why.
"""

import json;
import re;
import sys;
import math;
import argparse;
import from pathlib { Path }
import from datetime { datetime, timezone }


# --------------------------------------------------------------------------- #
# outcomes and constants
# --------------------------------------------------------------------------- #

glob PASS: str = "pass";
glob FAIL: str = "fail";
glob SKIP: str = "skip";

glob NON_CHECK_KEYS: set = {"notes"};

#: Private key injected by load_pack() so a PackResult can report where the
#: pack came from without changing evaluate_pack's frozen signature.
glob SOURCE_PATH_KEY: str = "_source_path";

glob OFFSET_TOLERANCE_FRAC: float = 0.20;
glob EARTH_RADIUS_KM: float = 6371.0088;
glob WGS84_A_KM: float = 6378.137;
glob WGS84_F: float = 1.0 / 298.257223563;
glob MARGIN_WARN_FRAC: float = 0.01;
glob MAX_DETAIL_CHARS: int = 132;

glob FILE_REF_KEYS: set = {"file", "path", "csv", "geojson", "filename", "source", "ais_window"};
glob EXT_RE: re.Pattern = re.compile(r"\.[A-Za-z0-9]{1,8}$");

glob WINDOW_KEY_PAIRS: tuple = (("start_t", "end_t"), ("start", "end"), ("t_start", "t_end"));
glob WINDOW_CONTAINERS: tuple = ("time_window", "ais_window", "ais", None);

glob JTMS_MSG: str = "no JTMS retraction layer (Phase 5 Option A)";
glob OFAC_MSG: str = "no OFAC watchlist lookup wired into the tracker";
glob RELINK_MSG: str = "no behaviour-based relink layer (kinematic continuity across an MMSI change)";
glob SEVERITY_MSG: str = "no alert-severity model, so escalation on relink cannot be observed";

glob EXIT_USAGE: int = 2;

glob _LABEL: dict = {"pass": "PASS", "fail": "FAIL", "skip": "SKIP"};
glob _COLOUR: dict = {"pass": "\x1b[32m", "fail": "\x1b[1;31m", "skip": "\x1b[33m"};
glob _DIM: str = "\x1b[2m";
glob _BOLD: str = "\x1b[1m";
glob _RESET: str = "\x1b[0m";
glob _RULE_MIN: int = 70;
glob _RULE_MAX: int = 132;


# --------------------------------------------------------------------------- #
# small result constructors -- plain dicts, shaped like CheckResult's fields
# --------------------------------------------------------------------------- #

def _row(key: str, outcome: str, detail: str, expected: any = None, actual: any = None, marginal: bool = False) -> dict {
    return {"key": key, "outcome": outcome, "detail": detail, "expected": expected, "actual": actual, "marginal": marginal};
}

def _passed(key: str, detail: str, expected: any = None, actual: any = None, marginal: bool = False) -> dict {
    return _row(key, PASS, detail, expected, actual, marginal);
}

def _failed(key: str, detail: str, expected: any = None, actual: any = None) -> dict {
    return _row(key, FAIL, detail, expected, actual, False);
}

def _skipped(key: str, reason: str, expected: any = None) -> dict {
    return _row(key, SKIP, reason, expected, None, False);
}


# --------------------------------------------------------------------------- #
# pack introspection helpers
# --------------------------------------------------------------------------- #

def _actor_ids(pack: dict) -> list {
    out = [];
    actors = pack.get("synthetic_actors") or ();
    for actor in actors {
        if isinstance(actor, dict) {
            aid = actor.get("actor_id") or actor.get("id");
            if aid is not None {
                out.append(str(aid));
            }
        }
    }
    return out;
}

def _actor(pack: dict, actor_id: str) -> any {
    actors = pack.get("synthetic_actors") or ();
    for actor in actors {
        if isinstance(actor, dict) and str(actor.get("actor_id") or actor.get("id")) == actor_id {
            return actor;
        }
    }
    return None;
}

def _actor_start_latlon(actor: dict) -> any {
    params = actor.get("params") or {};
    for key in ("start_latlon", "start_lat_lon", "latlon", "start") {
        val = params.get(key);
        if isinstance(val, (list, tuple)) and len(val) == 2 {
            try {
                return (float(val[0]), float(val[1]));
            } except (TypeError, ValueError) {
                return None;
            }
        }
    }
    lat = params.get("lat");
    lon = params.get("lon");
    if lat is not None and lon is not None {
        try {
            return (float(lat), float(lon));
        } except (TypeError, ValueError) {
            return None;
        }
    }
    return None;
}

def _event_kind(event: dict) -> tuple {
    if "kind" in event {
        if event["kind"] is None {
            return (None, "kind");
        }
        return (str(event["kind"]), "kind");
    }
    if "type" in event {
        if event["type"] is None {
            return (None, "type");
        }
        return (str(event["type"]), "type");
    }
    return (None, None);
}

def _events_of_kind(pack: dict, kind: str) -> list {
    out = [];
    events = pack.get("events") or ();
    for event in events {
        if not isinstance(event, dict) {
            continue;
        }
        found_pair = _event_kind(event);
        found = found_pair[0];
        key_used = found_pair[1];
        if found == kind and key_used is not None {
            out.append((event, key_used));
        }
    }
    return out;
}

def _fence_names(pack: dict) -> list {
    names = [];
    layers = pack.get("geofence_layers") or ();
    for layer in layers {
        if isinstance(layer, str) {
            names.append(Path(layer).stem);
            continue;
        }
        if not isinstance(layer, dict) {
            continue;
        }
        for key in ("id", "name", "fence_id", "layer_id") {
            val = layer.get(key);
            if val {
                names.append(str(val));
            }
        }
        file_ref = layer.get("file") or layer.get("path");
        if file_ref {
            names.append(Path(str(file_ref)).stem);
        }
    }
    return names;
}


# --------------------------------------------------------------------------- #
# time and bbox: both contract spellings
# --------------------------------------------------------------------------- #

def _parse_epoch(value: any) -> tuple {
    if isinstance(value, bool) {
        return (None, f"{value!r} is not a time");
    }
    if isinstance(value, (int, float)) {
        if math.isfinite(float(value)) {
            return (float(value), None);
        }
        return (None, f"{value!r} is not a finite time");
    }
    if isinstance(value, str) {
        try {
            dt = datetime.fromisoformat(value.strip());
        } except ValueError {
            return (None, f"{value!r} is not an ISO-8601 timestamp");
        }
        if dt.tzinfo is None {
            dt = dt.replace(tzinfo=timezone.utc);
        }
        return (dt.timestamp(), None);
    }
    return (None, f"{value!r} is not a time");
}

def _window_bounds(pack: dict) -> tuple {
    for container_key in WINDOW_CONTAINERS {
        if container_key is None {
            container = pack;
        } else {
            container = pack.get(container_key);
        }
        if not isinstance(container, dict) {
            continue;
        }
        for key_pair in WINDOW_KEY_PAIRS {
            start_key = key_pair[0];
            end_key = key_pair[1];
            if start_key not in container or end_key not in container {
                continue;
            }
            pair0 = _parse_epoch(container[start_key]);
            t0 = pair0[0];
            err0 = pair0[1];
            pair1 = _parse_epoch(container[end_key]);
            t1 = pair1[0];
            err1 = pair1[1];
            if t0 is not None and t1 is not None {
                return ((t0, t1), None);
            }
            if t0 is not None or t1 is not None {
                if container_key is None {
                    where = "pack root";
                } else {
                    where = container_key;
                }
                if t0 is not None {
                    bad_key = end_key;
                    bad_err = err1;
                } else {
                    bad_key = start_key;
                    bad_err = err0;
                }
                return (None, f"{where}.{bad_key}: {bad_err}");
            }
        }
    }
    return (None, None);
}

def _window_duration_s(pack: dict) -> any {
    result = _window_bounds(pack);
    bounds = result[0];
    if bounds is None {
        return None;
    }
    return bounds[1] - bounds[0];
}

def _bbox_bounds(pack: dict) -> tuple {
    bbox = pack.get("bbox");
    if bbox is None {
        return (None, None);
    }
    if isinstance(bbox, dict) {
        try {
            bounds = (float(bbox["lon_min"]), float(bbox["lat_min"]), float(bbox["lon_max"]), float(bbox["lat_max"]));
            return (bounds, None);
        } except (KeyError, TypeError, ValueError) as exc {
            return (None, f"bbox object is missing or has a non-numeric corner ({exc})");
        }
    }
    if isinstance(bbox, (list, tuple)) {
        if len(bbox) != 4 {
            return (None, f"bbox array has {len(bbox)} entries, expected 4 [lon_min, lat_min, lon_max, lat_max]");
        }
        try {
            vals = [float(v) for v in bbox];
        } except (TypeError, ValueError) {
            return (None, "bbox array has a non-numeric entry");
        }
        return ((vals[0], vals[1], vals[2], vals[3]), None);
    }
    return (None, f"bbox is {type(bbox).__name__}, expected an array of 4 or an object");
}


# --------------------------------------------------------------------------- #
# file references
# --------------------------------------------------------------------------- #

def _is_ref_key(key: str) -> bool {
    if key.startswith("_") {
        return False;
    }
    k = key.lower();
    if k in FILE_REF_KEYS {
        return True;
    }
    if "file" in k {
        return True;
    }
    return k.endswith(("_path", "_csv", "_geojson"));
}

def _collect_file_refs(data_node: any, out: list, trail: str = "") -> None {
    if isinstance(data_node, dict) {
        for key in data_node {
            value = data_node[key];
            if trail {
                where = f"{trail}.{key}";
            } else {
                where = str(key);
            }
            if isinstance(value, str) and _is_ref_key(str(key)) {
                ref = value.strip();
                if not ref or "://" in ref {
                    continue;
                }
                if str(key).lower() not in ("file", "path", "csv", "geojson", "filename") {
                    if not EXT_RE.search(ref) {
                        continue;
                    }
                }
                out.append((where, ref));
                continue;
            }
            _collect_file_refs(value, out, where);
        }
    } elif isinstance(data_node, list) {
        i = 0;
        for value in data_node {
            _collect_file_refs(value, out, f"{trail}[{i}]");
            i += 1;
        }
    }
}

def _notes_path_candidates(pack: dict) -> list {
    texts = [];
    expected_block = pack.get("expected") or {};
    sources = (pack.get("notes"), expected_block.get("notes"));
    for source in sources {
        if isinstance(source, str) {
            texts.append(source);
        }
    }
    found = [];
    for text in texts {
        for raw in text.split() {
            token = raw.strip("(),;:'\"[]{}<>");
            if "/" not in token or "://" in token {
                continue;
            }
            if not EXT_RE.search(token) {
                continue;
            }
            if token not in found {
                found.append(token);
            }
        }
    }
    return found;
}

def _haversine_km(a: tuple, b: tuple) -> float {
    lat1 = math.radians(a[0]);
    lon1 = math.radians(a[1]);
    lat2 = math.radians(b[0]);
    lon2 = math.radians(b[1]);
    dlat = lat2 - lat1;
    dlon = lon2 - lon1;
    h = math.sin(dlat / 2.0) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin(dlon / 2.0) ** 2;
    return 2.0 * EARTH_RADIUS_KM * math.asin(math.sqrt(min(1.0, h)));
}

def _ellipsoidal_km(a: tuple, b: tuple) -> float {
    e2 = WGS84_F * (2.0 - WGS84_F);
    phi = math.radians((a[0] + b[0]) / 2.0);
    s2 = math.sin(phi) ** 2;
    meridional = WGS84_A_KM * (1.0 - e2) / (1.0 - e2 * s2) ** 1.5;
    prime_vertical = WGS84_A_KM / math.sqrt(1.0 - e2 * s2);
    y = meridional * math.radians(b[0] - a[0]);
    x = prime_vertical * math.cos(phi) * math.radians(b[1] - a[1]);
    return math.hypot(x, y);
}

def _run_value(results: any, key: str, check_key: str) -> tuple {
    if results is None {
        return (False, None, _skipped(check_key, "no run data supplied (structural checks only)"));
    }
    if key not in results {
        return (False, None, _skipped(check_key, f"run data supplied but has no {key!r} entry"));
    }
    return (True, results[key], None);
}


# --------------------------------------------------------------------------- #
# STRUCTURAL checkers -- these work with no engine run at all
# --------------------------------------------------------------------------- #

def check_dark_actor(expected: any, pack: dict, results: any) -> dict {
    ids = _actor_ids(pack);
    name = str(expected);
    if name in ids {
        return _passed("dark_actor", f"actor {name!r} is defined in synthetic_actors", expected, name);
    }
    if ids {
        shown = ids;
    } else {
        shown = "none";
    }
    return _failed("dark_actor", f"actor {name!r} is NOT defined in synthetic_actors (defined: {shown})", expected, ids);
}

def check_actors(expected: any, pack: dict, results: any) -> dict {
    ids = _actor_ids(pack);
    if isinstance(expected, (list, tuple)) {
        wanted = [str(a) for a in expected];
    } else {
        wanted = [str(expected)];
    }
    missing = [a for a in wanted if a not in ids];
    if not missing {
        return _passed("actors", f"all {len(wanted)} named actor(s) defined in synthetic_actors: {', '.join(wanted)}", expected, ids);
    }
    if ids {
        shown = ids;
    } else {
        shown = "none";
    }
    return _failed("actors", f"named actor(s) not defined in synthetic_actors: {', '.join(missing)} (defined: {shown})", expected, ids);
}

def check_intrusion_fence(expected: any, pack: dict, results: any) -> dict {
    names = _fence_names(pack);
    want = str(expected);
    if not names {
        return _failed("intrusion_fence", f"fence {want!r} expected but the pack declares no geofence_layers", expected, names);
    }
    if want in names {
        return _passed("intrusion_fence", f"fence {want!r} found in geofence_layers", expected, want);
    }
    uniq = sorted(set(names));
    return _failed("intrusion_fence", f"fence {want!r} not in geofence_layers (found: {', '.join(uniq)})", expected, names);
}

def check_spoof_mmsi(expected: any, pack: dict, results: any) -> dict {
    want = str(expected);
    broadcasters = [];
    events = pack.get("events") or ();
    for event in events {
        if not isinstance(event, dict) {
            continue;
        }
        params = event.get("params") or {};
        values = [str(v) for v in params.values() if isinstance(v, (str, int, float))];
        if want in values {
            broadcasters.append(str(event.get("actor", event.get("id", "?"))));
        }
    }
    if not broadcasters {
        return _failed("spoof_mmsi", f"identity {want!r} is never broadcast by any event in the pack", expected, None);
    }
    unique = sorted(set(broadcasters));
    return _passed("spoof_mmsi", f"identity {want!r} broadcast by {len(unique)} actor(s): {', '.join(unique)}", expected, unique);
}

def _check_timing(key: str, expected: any, pack: dict, must_follow: tuple = (), event_kind: any = None) -> dict {
    try {
        t = float(expected);
    } except (TypeError, ValueError) {
        return _failed(key, f"value {expected!r} is not a number of seconds", expected, expected);
    }

    problems = [];
    facts = [];

    bounds_pair = _window_bounds(pack);
    bounds = bounds_pair[0];
    window_error = bounds_pair[1];
    if bounds is None {
        duration = None;
    } else {
        duration = bounds[1] - bounds[0];
    }
    if window_error is not None {
        problems.append(f"time window is unparseable -- {window_error}");
    } elif duration is None {
        facts.append("time_window not parseable, in-window check omitted");
    } elif 0.0 <= t <= duration {
        facts.append(f"t={t:g}s in window (0-{duration:g}s)");
    } else {
        problems.append(f"t={t:g}s is OUTSIDE the {duration:g}s time_window");
    }

    block = pack.get("expected") or {};
    for earlier in must_follow {
        if earlier not in block {
            continue;
        }
        try {
            t_earlier = float(block[earlier]);
        } except (TypeError, ValueError) {
            continue;
        }
        if t > t_earlier {
            facts.append(f"after {earlier}={t_earlier:g}s");
        } else {
            problems.append(f"NOT after {earlier}={t_earlier:g}s (ordering violated)");
        }
    }

    if event_kind is not None {
        matches = _events_of_kind(pack, event_kind);
        hit = [];
        for pair in matches {
            ev = pair[0];
            if math.isclose(float(ev.get("t", math.nan)), t, rel_tol=0.0, abs_tol=1e-6) {
                hit.append(pair);
            }
        }
        if hit {
            key_used = hit[0][1];
            if key_used == "kind" {
                note = "";
            } else {
                note = f" (via event key {key_used!r})";
            }
            facts.append(f"{event_kind} event at that t{note}");
        } elif matches {
            time_strs = [f"{float(pair[0].get('t', math.nan)):g}" for pair in matches];
            times = ", ".join(time_strs);
            problems.append(f"no {event_kind!r} event at t={t:g}s (events at: {times})");
        } else {
            problems.append(f"the pack declares no {event_kind!r} event at all");
        }
    }

    if problems {
        return _failed(key, "; ".join(problems), expected, t);
    }
    return _passed(key, "; ".join(facts), expected, t);
}

def check_sanctuary_entry_s(expected: any, pack: dict, results: any) -> dict {
    return _check_timing("sanctuary_entry_s", expected, pack);
}

def check_dark_at_s(expected: any, pack: dict, results: any) -> dict {
    return _check_timing("dark_at_s", expected, pack, ("sanctuary_entry_s",), "ais_off");
}

def check_radar_contact_at_s(expected: any, pack: dict, results: any) -> dict {
    return _check_timing("radar_contact_at_s", expected, pack, ("dark_at_s",));
}

def _positioned_actors(pack: dict) -> list {
    out = [];
    for aid in _actor_ids(pack) {
        actor = _actor(pack, aid);
        if actor is None {
            continue;
        }
        pos = _actor_start_latlon(actor);
        if pos is not None {
            out.append((aid, pos));
        }
    }
    return out;
}

def _closest_initial_pair(positioned: list, metric: any) -> tuple {
    n = len(positioned);
    if n == 2 {
        d = metric(positioned[0][1], positioned[1][1]);
        return (d, f"initial {positioned[0][0]}<->{positioned[1][0]}");
    }
    candidates = [];
    i = 0;
    while i < n {
        j = i + 1;
        while j < n {
            d = metric(positioned[i][1], positioned[j][1]);
            candidates.append((d, i, j));
            j += 1;
        }
        i += 1;
    }
    best = min(candidates);
    return (best[0], f"closest initial pair of {n} actors");
}

def check_min_separation_km(expected: any, pack: dict, results: any) -> dict {
    key = "min_separation_km";
    try {
        want = float(expected);
    } except (TypeError, ValueError) {
        return _failed(key, f"value {expected!r} is not a number of km", expected, expected);
    }

    positioned = _positioned_actors(pack);
    if len(positioned) < 2 {
        return _skipped(key, f"needs two actors with a start position; {len(positioned)} derivable from pack JSON", expected);
    }

    pair = _closest_initial_pair(positioned, _haversine_km);
    actual = pair[0];
    label = pair[1];
    margin_km = actual - want;
    margin_m = margin_km * 1000.0;
    if want {
        margin_pct = margin_km / abs(want) * 100.0;
    } else {
        margin_pct = float("inf");
    }
    head = f"{label} {actual:.3f} km vs {want:.3f} km required";
    model = f"haversine R={EARTH_RADIUS_KM:.4f} km";

    if actual < want {
        return _failed(key, f"{head}; short by {abs(margin_m):.0f} m ({abs(margin_pct):.2f}%) -- SHORT [{model}]", expected, round(actual, 3));
    }

    thin = abs(want) * MARGIN_WARN_FRAC;
    if margin_km < thin {
        return _passed(
            key,
            f"{head}; MARGIN {margin_m:.0f} m ({margin_pct:.2f}%), earth-model dependent [{model}]",
            expected, round(actual, 3), True
        );
    }
    return _passed(key, f"{head}; margin {margin_m:.0f} m ({margin_pct:.2f}%) [{model}]", expected, round(actual, 3));
}


# --------------------------------------------------------------------------- #
# MEASURED checkers -- need a results dict from a real replay run
# --------------------------------------------------------------------------- #

def check_id_switches_max(expected: any, pack: dict, results: any) -> dict {
    key = "id_switches_max";
    tup = _run_value(results, "id_switches", key);
    if not tup[0] {
        return tup[2];
    }
    actual = tup[1];
    limit = float(expected);
    detail = f"measured {actual} id switch(es) vs at most {limit:g} allowed";
    if float(actual) <= limit {
        return _passed(key, detail, expected, actual);
    }
    return _failed(key, detail + " -- OVER", expected, actual);
}

def check_reassoc_p_min(expected: any, pack: dict, results: any) -> dict {
    key = "reassoc_p_min";
    tup = _run_value(results, "reassoc_p", key);
    if not tup[0] {
        return tup[2];
    }
    actual = tup[1];
    floor = float(expected);
    detail = f"reassociation p={float(actual):.4f} vs floor {floor:.4f}";
    if float(actual) >= floor {
        return _passed(key, detail, expected, actual);
    }
    return _failed(key, detail + " -- BELOW", expected, actual);
}

def check_reassoc_correct(expected: any, pack: dict, results: any) -> dict {
    key = "reassoc_correct";
    tup = _run_value(results, "reassoc_track_id", key);
    if not tup[0] {
        return tup[2];
    }
    actual = tup[1];
    block = pack.get("expected") or {};
    truth = block.get("dark_actor");
    if truth is None {
        ids = _actor_ids(pack);
        if len(ids) != 1 {
            return _skipped(key, "ground-truth actor is ambiguous (no dark_actor and not exactly one actor)", expected);
        }
        truth = ids[0];
    }
    detail = f"reacquisition attributed to {str(actual)!r}, ground truth {str(truth)!r}";
    if str(actual) == str(truth) {
        return _passed(key, detail, truth, actual);
    }
    return _failed(key, detail + " -- MISATTRIBUTED", truth, actual);
}

def check_geofence_alert(expected: any, pack: dict, results: any) -> dict {
    key = "geofence_alert";
    tup = _run_value(results, "geofence_alerts", key);
    if not tup[0] {
        return tup[2];
    }
    alerts = list(tup[1] or ());
    want_alert = bool(expected);

    if not want_alert {
        detail = f"pack expects no geofence alert; run produced {len(alerts)}";
        if not alerts {
            return _passed(key, detail, expected, len(alerts));
        }
        return _failed(key, detail, expected, len(alerts));
    }

    if not alerts {
        return _failed(key, "pack expects a geofence alert; the run produced none", expected, []);
    }

    fence = (pack.get("expected") or {}).get("intrusion_fence");
    if fence is None {
        return _passed(key, f"{len(alerts)} geofence alert(s) fired", expected, len(alerts));
    }

    seen = [];
    for alert in alerts {
        if isinstance(alert, str) {
            seen.append(alert);
        } elif isinstance(alert, dict) {
            for k in ("fence", "fence_id", "layer", "layer_id", "name", "id") {
                if alert.get(k) {
                    seen.append(str(alert[k]));
                }
            }
        }
    }
    if str(fence) in seen {
        return _passed(key, f"{len(alerts)} alert(s), at least one on the expected fence {str(fence)!r}", expected, seen);
    }
    if seen {
        shown = ', '.join(seen);
    } else {
        shown = "unnamed";
    }
    return _failed(key, f"{len(alerts)} alert(s) but none on fence {str(fence)!r} (saw: {shown})", expected, seen);
}

def check_offset(expected: any, pack: dict, results: any) -> dict {
    key = "predicted_vs_true_offset_verified_m";
    tup = _run_value(results, "offset_m", key);
    if not tup[0] {
        return tup[2];
    }
    actual = tup[1];
    want = float(expected);
    got = float(actual);
    tol = abs(want) * OFFSET_TOLERANCE_FRAC;
    detail = f"offset {got:.0f} m vs verified {want:.0f} m (tolerance +/-{OFFSET_TOLERANCE_FRAC:.0%} = +/-{tol:.0f} m)";
    if abs(got - want) <= tol {
        return _passed(key, detail, expected, actual);
    }
    return _failed(key, detail + " -- OUT OF TOLERANCE", expected, actual);
}


# --------------------------------------------------------------------------- #
# NOT-BUILT checkers -- always SKIP, naming the capability that is missing
# --------------------------------------------------------------------------- #

def make_not_built_checker(key: str, capability: str) -> object {
    def checker(expected: any, pack: dict, results: any) -> dict {
        return _skipped(key, f"not implemented: {capability}", expected);
    }
    return checker;
}


# --------------------------------------------------------------------------- #
# PACK-LEVEL checks -- not keys in `expected`, but reported in the same rows
# --------------------------------------------------------------------------- #

def _pack_dir(pack: dict) -> any {
    source = pack.get(SOURCE_PATH_KEY);
    if not source {
        return None;
    }
    return Path(str(source)).parent;
}

def packcheck_referenced_files(pack: dict) -> any {
    key = "referenced_files";
    refs = [];
    _collect_file_refs(pack, refs);
    if not refs {
        return None;
    }

    base = _pack_dir(pack);
    if base is None {
        return _skipped(
            key,
            f"{len(refs)} file reference(s) found but the pack has no source path, "
            "so nothing can be resolved (loaded from a dict, not from disk)"
        );
    }

    missing = [pair for pair in refs if not (base / pair[1]).exists()];
    if not missing {
        listed = ", ".join(pair[1] for pair in refs);
        return _passed(key, f"all {len(refs)} referenced file(s) exist: {listed}", None, len(refs));
    }

    lead = "; ".join(f"MISSING {pair[1]}" for pair in missing);
    keys = ", ".join(pair[0] for pair in missing);
    return _failed(
        key,
        f"{lead} -- resolved against {_short_path(str(base))} "
        f"[{keys}; {len(refs) - len(missing)}/{len(refs)} refs exist]",
        None,
        [pair[1] for pair in missing]
    );
}

def packcheck_free_text_paths(pack: dict) -> any {
    key = "free_text_paths";
    candidates = _notes_path_candidates(pack);
    if not candidates {
        return None;
    }
    base = _pack_dir(pack);
    if base is None {
        return _skipped(
            key,
            f"{len(candidates)} path-like token(s) in free text, unresolvable: "
            f"the pack has no source path ({', '.join(candidates)})"
        );
    }
    stale = [c for c in candidates if not (base / c).exists()];
    if not stale {
        return None;
    }
    return _skipped(
        key,
        f"may be stale: {', '.join(stale)} is named in free text but is not under {_short_path(str(base))}"
    );
}

def packcheck_bbox(pack: dict) -> any {
    key = "bbox";
    if "bbox" not in pack {
        return None;
    }
    result = _bbox_bounds(pack);
    bounds = result[0];
    error = result[1];
    if isinstance(pack.get("bbox"), dict) {
        shape = "object";
    } else {
        shape = "array";
    }
    if bounds is None {
        return _failed(key, f"{error}", None, pack.get("bbox"));
    }
    lon_min = bounds[0];
    lat_min = bounds[1];
    lon_max = bounds[2];
    lat_max = bounds[3];
    problems = [];
    if lon_min >= lon_max {
        problems.append(f"lon_min {lon_min:g} is not west of lon_max {lon_max:g}");
    }
    if lat_min >= lat_max {
        problems.append(f"lat_min {lat_min:g} is not south of lat_max {lat_max:g}");
    }
    if not (-180.0 <= lon_min <= 180.0 and -180.0 <= lon_max <= 180.0) {
        problems.append("longitude outside [-180, 180]");
    }
    if not (-90.0 <= lat_min <= 90.0 and -90.0 <= lat_max <= 90.0) {
        problems.append("latitude outside [-90, 90]");
    }
    rendered = f"lon {lon_min:g}..{lon_max:g}, lat {lat_min:g}..{lat_max:g} ({shape} form)";
    if problems {
        return _failed(key, f"{'; '.join(problems)} -- {rendered}", None, bounds);
    }
    return _passed(key, f"well formed: {rendered}", None, bounds);
}

def packcheck_separation_earth_model(pack: dict) -> any {
    key = "separation_earth_model";
    block = pack.get("expected") or {};
    if "min_separation_km" not in block {
        return None;
    }
    positioned = _positioned_actors(pack);
    if len(positioned) < 2 {
        return None;
    }
    try {
        want = float(block["min_separation_km"]);
    } except (TypeError, ValueError) {
        return None;
    }

    sphere = _closest_initial_pair(positioned, _haversine_km)[0];
    ellipsoid = _closest_initial_pair(positioned, _ellipsoidal_km)[0];
    both = f"sphere {sphere:.3f} km, WGS-84 {ellipsoid:.3f} km, required {want:.3f} km";
    if (sphere >= want) != (ellipsoid >= want) {
        return _skipped(key, f"STRADDLE: {both} -- the models disagree, so the earth model decides this row");
    }
    spread_m = abs(sphere - ellipsoid) * 1000.0;
    return _skipped(key, f"models agree ({both}); they differ by {spread_m:.0f} m");
}

def packcheck_separation_over_replay(pack: dict) -> any {
    key = "separation_over_replay";
    block = pack.get("expected") or {};
    if "min_separation_km" not in block {
        return None;
    }
    return _skipped(
        key,
        "t=0 separation only; the minimum over the replay is not derivable from pack JSON "
        "(gen: tracks live in the replay layer)"
    );
}


# --------------------------------------------------------------------------- #
# discovery and loading
# --------------------------------------------------------------------------- #

def _default_root() -> any {
    return Path(__file__).resolve().parent.parent;
}

def discover_packs(root_dir: any = None) -> list {
    if root_dir is not None {
        base = Path(root_dir);
    } else {
        base = _default_root();
    }
    scenarios = base / "scenarios";
    if not scenarios.is_dir() {
        return [];
    }
    found = [p for p in scenarios.glob("*/pack.json") if p.is_file()];
    return sorted(found);
}

def load_pack(path: any) -> dict {
    p = Path(path);
    try {
        text = p.read_text(encoding="utf-8");
    } except OSError as exc {
        raise ValueError(f"cannot read scenario pack {p}: {exc}") from exc;
    }
    try {
        pack = json.loads(text);
    } except json.JSONDecodeError as exc {
        raise ValueError(f"malformed scenario pack {p}: {exc.msg} at line {exc.lineno} column {exc.colno}") from exc;
    }
    if not isinstance(pack, dict) {
        raise ValueError(f"malformed scenario pack {p}: top level is {type(pack).__name__}, expected an object");
    }
    pack[SOURCE_PATH_KEY] = str(p);
    return pack;
}


# --------------------------------------------------------------------------- #
# evaluation
# --------------------------------------------------------------------------- #

def evaluate_pack_core(pack: dict, results: any, checkers: dict, pack_checks: tuple) -> dict {
    block = pack.get("expected");
    checks = [];

    if not isinstance(block, dict) {
        if block is not None {
            checks.append(_failed("expected", f"pack has no usable 'expected' block (found {type(block).__name__})", None, block));
        } else {
            checks.append(_skipped("expected", "pack declares no 'expected' block, so there is nothing to check"));
        }
        block = {};
    }

    for key in block {
        value = block[key];
        if key in NON_CHECK_KEYS {
            continue;
        }
        checker = checkers.get(key);
        if checker is None {
            checks.append(_skipped(key, "no checker registered for this key", value));
            continue;
        }
        try {
            result = checker(value, pack, results);
        } except Exception as exc {
            checks.append(_failed(key, f"checker raised {type(exc).__name__}: {exc}", value, None));
            continue;
        }
        if not isinstance(result, dict) {
            checks.append(_failed(key, f"checker returned {type(result).__name__}, expected CheckResult", value, None));
            continue;
        }
        checks.append(result);
    }

    for pack_check in pack_checks {
        try {
            row = pack_check(pack);
        } except Exception as exc {
            name = getattr(pack_check, "__name__", "pack_check");
            checks.append(_failed(name, f"pack check raised {type(exc).__name__}: {exc}"));
            continue;
        }
        if isinstance(row, dict) {
            checks.append(row);
        }
    }

    return {
        "pack_id": str(pack.get("id", "<unnamed pack>")),
        "name": str(pack.get("name", "")),
        "path": str(pack.get(SOURCE_PATH_KEY, "")),
        "checks": checks
    };
}

def evaluate_all_core(root_dir: any, results_by_pack: any, checkers: dict, pack_checks: tuple) -> list {
    out = [];
    for path in discover_packs(root_dir) {
        pack = load_pack(path);
        results = None;
        if results_by_pack {
            results = results_by_pack.get(str(pack.get("id"))) or results_by_pack.get(str(path));
        }
        out.append(evaluate_pack_core(pack, results, checkers, pack_checks));
    }
    return out;
}


# --------------------------------------------------------------------------- #
# the projector-facing report
# --------------------------------------------------------------------------- #

def _short_path(path: str) -> str {
    if not path {
        return "";
    }
    p = Path(path);
    is_relative = True;
    try {
        rel = str(p.relative_to(Path.cwd()));
    } except ValueError {
        is_relative = False;
    }
    if is_relative {
        return rel;
    }
    parts = p.parts;
    if len(parts) > 3 {
        return str(Path(*parts[-3:]));
    }
    return str(p);
}

def _elide(text: any, limit: int = MAX_DETAIL_CHARS) -> str {
    flat = " ".join(str(text).split());
    if len(flat) <= limit {
        return flat;
    }
    return flat[: limit - 3].rstrip() + "...";
}

def format_report(results: list, use_colour: any = None) -> str {
    if use_colour is None {
        isatty_fn = getattr(sys.stdout, "isatty", None);
        if isatty_fn is not None {
            use_colour = bool(isatty_fn());
        } else {
            use_colour = False;
        }
    }

    def paint(text: str, code: str) -> str {
        if use_colour {
            return code + text + _RESET;
        }
        return text;
    }

    results = list(results);
    lines = [];

    if not results {
        rule = "=" * _RULE_MIN;
        lines.append(paint("Sentinel-ISR scenario regression suite", _BOLD));
        lines.append(rule);
        lines.append("no packs found -- scenarios/*/pack.json matched nothing under this root.");
        lines.append(rule);
        lines.append("TOTAL   0 packs   0 passed   0 failed   0 skipped");
        return "\n".join(lines);
    }

    key_lens = [len(c.key) for r in results for c in r.checks];
    width = max(key_lens, default=0);
    width = max(width, 12);

    row_lens = [8 + width + 2 + len(_elide(c.detail)) for r in results for c in r.checks];
    row_w = max(row_lens, default=0);
    head_lens = [];
    for r in results {
        if r.name {
            head_lens.append(len(r.pack_id) + 6 + len(_elide(r.name, 70)));
        } else {
            head_lens.append(len(r.pack_id));
        }
    }
    head_w = max(head_lens, default=0);
    rule_w = min(_RULE_MAX, max(_RULE_MIN, row_w, head_w));
    rule = "=" * rule_w;
    thin = "-" * rule_w;

    lines.append(paint("Sentinel-ISR scenario regression suite", _BOLD));
    lines.append(rule);

    total_pass = 0;
    total_fail = 0;
    total_skip = 0;
    total_marginal = 0;

    for res in results {
        lines.append("");
        if not res.name {
            header = res.pack_id;
        } else {
            header = f"{res.pack_id}  --  {_elide(res.name, 70)}";
        }
        lines.append(paint(header, _BOLD));
        if res.path {
            lines.append(paint(f"  {_short_path(res.path)}", _DIM));
        }
        if not res.checks {
            lines.append("  (no expected keys to check)");
        }
        for check in res.checks {
            label = _LABEL.get(check.outcome, check.outcome.upper()[:4]);
            colour = _COLOUR.get(check.outcome, "");
            tag = paint(label, colour);
            lines.append(f"  {tag}  {check.key.ljust(width)}  {_elide(check.detail)}");
        }
        lines.append(f"  {thin[:width + 14]}");
        summary_line = f"  {res.passed} passed   {res.failed} failed   {res.skipped} skipped   {res.marginal} marginal";
        if not res.ok {
            summary_line = summary_line + paint("   <-- FAILURES IN THIS PACK", _COLOUR[FAIL]);
        }
        lines.append(summary_line);
        total_pass += res.passed;
        total_fail += res.failed;
        total_skip += res.skipped;
        total_marginal += res.marginal;
    }

    if total_fail == 0 {
        verdict = "OK";
    } else {
        verdict = f"{total_fail} FAILED";
    }
    lines.append("");
    lines.append(rule);
    if total_fail {
        fail_colour = _COLOUR[FAIL];
    } else {
        fail_colour = "";
    }
    if total_marginal {
        marginal_colour = _COLOUR[SKIP];
    } else {
        marginal_colour = "";
    }
    if total_fail == 0 {
        verdict_colour = _BOLD + _COLOUR[PASS];
    } else {
        verdict_colour = _BOLD + _COLOUR[FAIL];
    }
    lines.append(
        f"TOTAL   {len(results)} pack(s)   "
        f"{paint(f'{total_pass} passed', _COLOUR[PASS])}   "
        f"{paint(f'{total_fail} failed', fail_colour)}   "
        f"{paint(f'{total_skip} skipped', _COLOUR[SKIP])}   "
        f"{paint(f'{total_marginal} marginal', marginal_colour)}   ->  "
        f"{paint(verdict, verdict_colour)}"
    );
    if total_marginal {
        lines.append(
            paint(
                f"        MARGIN = passed, but by under {MARGIN_WARN_FRAC:.0%} of the stated value, "
                "so the earth model decided it. Not a failure; does not affect the exit code.",
                _DIM
            )
        );
    }
    if total_skip {
        lines.append(paint("        SKIP = not checked (capability not built, or no run data). Not a failure.", _DIM));
    }
    return "\n".join(lines);
}

def as_jsonable(results: list) -> dict {
    packs = [];
    for r in results {
        check_rows = [];
        for c in r.checks {
            check_rows.append({
                "key": c.key,
                "outcome": c.outcome,
                "detail": c.detail,
                "expected": c.expected,
                "actual": c.actual,
                "marginal": c.marginal
            });
        }
        packs.append({
            "pack_id": r.pack_id,
            "name": r.name,
            "path": r.path,
            "passed": r.passed,
            "failed": r.failed,
            "skipped": r.skipped,
            "marginal": r.marginal,
            "ok": r.ok,
            "checks": check_rows
        });
    }
    passed_sum = sum(p["passed"] for p in packs);
    failed_sum = sum(p["failed"] for p in packs);
    skipped_sum = sum(p["skipped"] for p in packs);
    marginal_sum = sum(p["marginal"] for p in packs);
    ok_all = all(p["ok"] for p in packs);
    return {
        "packs": packs,
        "summary": {
            "packs": len(packs),
            "passed": passed_sum,
            "failed": failed_sum,
            "skipped": skipped_sum,
            "marginal": marginal_sum,
            "ok": ok_all
        }
    };
}


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #

def build_parser() -> object {
    parser = argparse.ArgumentParser(
        prog="python -m tracker.eval",
        description="Check every scenario pack's `expected` block. PASS / FAIL / SKIP.",
        epilog="Exit 0 unless a check FAILED (SKIPs are not failures); 2 on a usage error."
    );
    parser.add_argument("--all", action="store_true", help="check every discovered pack (default)");
    parser.add_argument("--pack", metavar="ID", default=None, help="check only the pack with this id");
    parser.add_argument("--root", metavar="DIR", default=None, help="repo root to glob scenarios/*/pack.json under");
    parser.add_argument("--json", action="store_true", help="machine-readable dump instead of the report");
    parser.add_argument("--quiet", action="store_true", help="summary line only");
    parser.add_argument(
        "--colour", "--color", dest="colour", choices=("auto", "always", "never"), default="auto",
        help="ANSI colour in the report (default: auto, i.e. only on a tty)"
    );
    return parser;
}

def main_core(argv: any, evaluate_all_fn: any, format_report_fn: any, as_jsonable_fn: any) -> int {
    if argv is not None {
        parsed_argv = list(argv);
    } else {
        parsed_argv = None;
    }
    args = build_parser().parse_args(parsed_argv);

    try {
        results = evaluate_all_fn(args.root);
    } except ValueError as exc {
        print(f"error: {exc}", file=sys.stderr);
        return EXIT_USAGE;
    }

    if args.pack is not None {
        wanted = [r for r in results if r.pack_id == args.pack];
        if not wanted {
            ids = [r.pack_id for r in results];
            if ids {
                known = ", ".join(ids);
            } else {
                known = "none";
            }
            print(f"error: no pack with id {args.pack!r} (found: {known})", file=sys.stderr);
            return EXIT_USAGE;
        }
        results = wanted;
    }

    if not results {
        print("no packs found -- scenarios/*/pack.json matched nothing. Nothing to check.");
        return 0;
    }

    failed = sum(r.failed for r in results);

    if args.json {
        print(json.dumps(as_jsonable_fn(results), indent=2, default=str));
    } elif args.quiet {
        passed = sum(r.passed for r in results);
        skipped = sum(r.skipped for r in results);
        marginal = sum(r.marginal for r in results);
        if failed == 0 {
            verdict = "OK";
        } else {
            verdict = "FAILED";
        }
        print(f"{len(results)} pack(s): {passed} passed, {failed} failed, {skipped} skipped, {marginal} marginal -> {verdict}");
    } else {
        colour_map = {"auto": None, "always": True, "never": False};
        use_colour = colour_map[args.colour];
        print(format_report_fn(results, use_colour=use_colour));
    }

    if failed {
        return 1;
    }
    return 0;
}
