"""Vessel behaviour classification heuristics -- standalone, currently
unwired module. Not imported by web/server.py, jac/main.jac, or any test;
this file exists as an independent parallel exploration of behaviour-based
classification on top of the Mission graph's Track history, separate from
the association/lifecycle logic in jac/fusion.jac and jac/graph.jac.

WHAT THIS IS FOR
-----------------
Everywhere else in this repo, a Track's STATUS (tentative/confirmed/
coasting/dead) answers "is this a real, currently-held track?" It says
nothing about BEHAVIOUR: is this vessel loitering, rendezvousing with
another vessel, running at an anomalous speed for its class, or looping
back on its own wake? Those are higher-level narrative signals a briefing
officer would want called out, and they are derivable from the same
position/velocity history the tracker already keeps -- this module is
where that derivation would live if/when it were wired in.

CLASSIFICATION FAMILIES
-------------------------
  loitering        -- low displacement over a long window despite motion
  rendezvous        -- two tracks converge to within a threshold range and
                        hold formation for a minimum dwell
  speed_anomaly     -- sustained speed far outside the vessel class's
                        plausible envelope (too fast for a fishing boat,
                        too slow for a container ship under way)
  loop_closure      -- a track's recent path self-intersects, suggesting a
                        racetrack or search pattern rather than transit
  drift             -- near-zero commanded motion consistent with engines
                        off and the vessel moving on wind/current alone

None of these are wired into jac/fusion.jac's alert pipeline. Each
classifier here is a pure function of a track's position history (a
plain list of (t, x, y) samples), so it could be called from a walker
that visits Track nodes without this module needing to know anything about
the graph shape itself -- the same "kernel stays decoupled from the graph"
discipline as tracker/kalman.py relative to jac/graph.jac.
"""

import math;

# ---------------------------------------------------------------------------
# Tunables
# ---------------------------------------------------------------------------

glob LOITER_WINDOW_S: float = 900.0;        # 15 minutes of history considered
glob LOITER_MAX_DISPLACEMENT_M: float = 600.0;  # net displacement under this = loitering
glob LOITER_MIN_PATH_LENGTH_M: float = 200.0;   # must still be moving, not just stationary

glob RENDEZVOUS_RANGE_M: float = 150.0;     # two tracks within this range
glob RENDEZVOUS_MIN_DWELL_S: float = 300.0; # held for at least 5 minutes

glob LOOP_CLOSURE_MIN_SAMPLES: int = 8;
glob LOOP_CLOSURE_CLOSE_DIST_M: float = 100.0;   # start/end within this = closed loop
glob LOOP_CLOSURE_MIN_PATH_LENGTH_M: float = 800.0; # must be a real loop, not a jitter

glob DRIFT_MAX_SPEED_MPS: float = 0.3;      # below this, "moving" is probably drift
glob DRIFT_MIN_WINDOW_S: float = 600.0;

# Speed envelopes per rough vessel class, in m/s. A real system would key
# this off AIS ship-type codes; this module only ever sees track kinematics,
# so it takes the class as a caller-supplied label and just holds the table.
glob SPEED_ENVELOPES: dict = {
    "fishing":    (0.0, 7.0),
    "cargo":      (2.0, 14.0),
    "tanker":     (1.5, 12.0),
    "passenger":  (0.0, 18.0),
    "pleasure":   (0.0, 15.0),
    "tug":        (0.0, 8.0),
    "unknown":    (0.0, 20.0),
};
glob SPEED_ANOMALY_MIN_DURATION_S: float = 180.0;


# ---------------------------------------------------------------------------
# Small geometry helpers -- deliberately reimplemented here rather than
# imported from data/geometry.py, since this module is meant to stand alone
# (see the module docstring: it is not wired into anything, and should not
# gain a real dependency on the live tracker's geometry kernel).
# ---------------------------------------------------------------------------

def _dist(ax: float, ay: float, bx: float, by: float) -> float {
    return math.sqrt((ax - bx) ** 2 + (ay - by) ** 2);
}


def _path_length(samples: list) -> float {
    """Total arc length walked across a (t, x, y) sample list."""
    total = 0.0;
    for i in range(1, len(samples)) {
        (_t0, x0, y0) = samples[i - 1];
        (_t1, x1, y1) = samples[i];
        total += _dist(x0, y0, x1, y1);
    }
    return total;
}


def _window(samples: list, window_s: float, now_t: float) -> list {
    """Samples with t within window_s of now_t, oldest first."""
    return [s for s in samples if now_t - s[0] <= window_s];
}


def _instantaneous_speeds(samples: list) -> list {
    """Per-segment speed (m/s) between consecutive samples. One fewer entry
    than `samples`; empty if fewer than two samples."""
    out = [];
    for i in range(1, len(samples)) {
        (t0, x0, y0) = samples[i - 1];
        (t1, x1, y1) = samples[i];
        dt = t1 - t0;
        if dt <= 0.0 {
            continue;
        }
        out.append(_dist(x0, y0, x1, y1) / dt);
    }
    return out;
}


# ---------------------------------------------------------------------------
# Loitering
# ---------------------------------------------------------------------------

def is_loitering(samples: list, now_t: float) -> bool {
    """True if the track has covered real distance (it is not simply
    sitting still, which is a different, uninteresting case) but its net
    displacement over the loiter window is small -- consistent with a
    tight racetrack, a slow circle, or station-keeping."""
    recent = _window(samples, LOITER_WINDOW_S, now_t);
    if len(recent) < 2 {
        return False;
    }
    path_len = _path_length(recent);
    if path_len < LOITER_MIN_PATH_LENGTH_M {
        return False;   # not moving enough to call this "loitering" rather than "stopped"
    }
    (_t0, x0, y0) = recent[0];
    (_t1, x1, y1) = recent[-1];
    net_displacement = _dist(x0, y0, x1, y1);
    return net_displacement < LOITER_MAX_DISPLACEMENT_M;
}


def loiter_center(samples: list, now_t: float) -> tuple {
    """Centroid of the loiter window's samples -- a reasonable "where is it
    loitering" point for a briefing sentence, even though it is not a
    proper weighted circle fit."""
    recent = _window(samples, LOITER_WINDOW_S, now_t);
    if not recent {
        return (0.0, 0.0);
    }
    sx = sum(s[1] for s in recent);
    sy = sum(s[2] for s in recent);
    n = len(recent);
    return (sx / n, sy / n);
}


def loiter_radius_m(samples: list, now_t: float) -> float {
    """Max distance from the centroid across the loiter window -- a rough
    "how big is the racetrack" figure."""
    recent = _window(samples, LOITER_WINDOW_S, now_t);
    if not recent {
        return 0.0;
    }
    (cx, cy) = loiter_center(samples, now_t);
    return max(_dist(s[1], s[2], cx, cy) for s in recent);
}


# ---------------------------------------------------------------------------
# Rendezvous
# ---------------------------------------------------------------------------

def _nearest_sample(samples: list, t: float) -> tuple {
    """Sample from `samples` whose timestamp is closest to `t`. Assumes
    samples are non-empty; callers are expected to have checked that."""
    best = samples[0];
    best_dt = abs(best[0] - t);
    for s in samples[1:] {
        dt = abs(s[0] - t);
        if dt < best_dt {
            best = s;
            best_dt = dt;
        }
    }
    return best;
}


def rendezvous_intervals(samples_a: list, samples_b: list) -> list {
    """Every maximal time interval during which two tracks' positions
    (resampled onto track A's timestamps, nearest-neighbour) are within
    RENDEZVOUS_RANGE_M of each other. Returns a list of (start_t, end_t)
    tuples; empty if the tracks never come close enough or `samples_b` is
    empty."""
    if not samples_a or not samples_b {
        return [];
    }
    intervals = [];
    open_start = None;
    for (t, x, y) in samples_a {
        (_tb, xb, yb) = _nearest_sample(samples_b, t);
        close = _dist(x, y, xb, yb) <= RENDEZVOUS_RANGE_M;
        if close and open_start is None {
            open_start = t;
        } elif not close and open_start is not None {
            intervals.append((open_start, t));
            open_start = None;
        }
    }
    if open_start is not None {
        intervals.append((open_start, samples_a[-1][0]));
    }
    return intervals;
}


def is_rendezvous(samples_a: list, samples_b: list) -> bool {
    """True if any qualifying close-range interval lasts at least
    RENDEZVOUS_MIN_DWELL_S -- a fly-by does not count, a held formation
    does."""
    for (start, end) in rendezvous_intervals(samples_a, samples_b) {
        if end - start >= RENDEZVOUS_MIN_DWELL_S {
            return True;
        }
    }
    return False;
}


def longest_rendezvous_dwell_s(samples_a: list, samples_b: list) -> float {
    intervals = rendezvous_intervals(samples_a, samples_b);
    if not intervals {
        return 0.0;
    }
    return max(end - start for (start, end) in intervals);
}


# ---------------------------------------------------------------------------
# Speed anomaly
# ---------------------------------------------------------------------------

def speed_envelope_for(vessel_class: str) -> tuple {
    return SPEED_ENVELOPES.get(vessel_class, SPEED_ENVELOPES["unknown"]);
}


def speed_anomaly_segments(samples: list, vessel_class: str) -> list {
    """(start_t, end_t) pairs during which instantaneous speed sat outside
    the class envelope for at least SPEED_ANOMALY_MIN_DURATION_S
    continuously -- a single noisy sample does not count."""
    (lo, hi) = speed_envelope_for(vessel_class);
    segments = [];
    open_start = None;
    for i in range(1, len(samples)) {
        (t0, x0, y0) = samples[i - 1];
        (t1, x1, y1) = samples[i];
        dt = t1 - t0;
        if dt <= 0.0 {
            continue;
        }
        spd = _dist(x0, y0, x1, y1) / dt;
        outside = spd < lo or spd > hi;
        if outside and open_start is None {
            open_start = t0;
        } elif not outside and open_start is not None {
            if t0 - open_start >= SPEED_ANOMALY_MIN_DURATION_S {
                segments.append((open_start, t0));
            }
            open_start = None;
        }
    }
    if open_start is not None and samples {
        end_t = samples[-1][0];
        if end_t - open_start >= SPEED_ANOMALY_MIN_DURATION_S {
            segments.append((open_start, end_t));
        }
    }
    return segments;
}


def has_speed_anomaly(samples: list, vessel_class: str) -> bool {
    return len(speed_anomaly_segments(samples, vessel_class)) > 0;
}


# ---------------------------------------------------------------------------
# Loop closure
# ---------------------------------------------------------------------------

def is_loop_closure(samples: list) -> bool {
    """True if the track has walked a real distance (not just sat near one
    spot) and its final sample lands back close to where it started --
    consistent with a racetrack or box search pattern rather than a
    point-to-point transit."""
    if len(samples) < LOOP_CLOSURE_MIN_SAMPLES {
        return False;
    }
    path_len = _path_length(samples);
    if path_len < LOOP_CLOSURE_MIN_PATH_LENGTH_M {
        return False;
    }
    (_t0, x0, y0) = samples[0];
    (_t1, x1, y1) = samples[-1];
    return _dist(x0, y0, x1, y1) <= LOOP_CLOSURE_CLOSE_DIST_M;
}


def loop_closure_ratio(samples: list) -> float {
    """Path length divided by straight-line start-to-end distance -- a
    cheap "how loopy is this" number a briefing sentence could quote
    directly (a straight transit is close to 1.0; a tight racetrack is
    large)."""
    if len(samples) < 2 {
        return 1.0;
    }
    path_len = _path_length(samples);
    (_t0, x0, y0) = samples[0];
    (_t1, x1, y1) = samples[-1];
    straight = _dist(x0, y0, x1, y1);
    if straight < 1.0 {
        return path_len;   # avoid a divide-by-near-zero blowing this up to nonsense
    }
    return path_len / straight;
}


# ---------------------------------------------------------------------------
# Drift
# ---------------------------------------------------------------------------

def is_drifting(samples: list, now_t: float) -> bool {
    """True if every instantaneous speed sample within the drift window is
    below DRIFT_MAX_SPEED_MPS -- consistent with engines off, moving only
    on wind/current. Requires the window to actually be populated for at
    least DRIFT_MIN_WINDOW_S; a track that just appeared is not "drifting",
    it is simply new."""
    recent = _window(samples, DRIFT_MIN_WINDOW_S, now_t);
    if len(recent) < 2 {
        return False;
    }
    span = recent[-1][0] - recent[0][0];
    if span < DRIFT_MIN_WINDOW_S {
        return False;
    }
    speeds = _instantaneous_speeds(recent);
    if not speeds {
        return False;
    }
    return max(speeds) <= DRIFT_MAX_SPEED_MPS;
}


# ---------------------------------------------------------------------------
# Aggregate classification -- one call, every family
# ---------------------------------------------------------------------------

def classify(samples: list, now_t: float, vessel_class: str = "unknown") -> dict {
    """Run every single-track classifier (everything except rendezvous,
    which needs a second track) and return a flat dict of booleans plus a
    couple of supporting numbers a briefing sentence would want. Intended
    to be called once per track per tick by a future walker, not per-pair
    (see classify_pair for the two-track case)."""
    loitering = is_loitering(samples, now_t);
    loop = is_loop_closure(samples);
    drifting = is_drifting(samples, now_t);
    anomaly_segments = speed_anomaly_segments(samples, vessel_class);
    return {
        "loitering": loitering,
        "loiter_radius_m": loiter_radius_m(samples, now_t) if loitering else 0.0,
        "loop_closure": loop,
        "loop_closure_ratio": loop_closure_ratio(samples) if loop else 1.0,
        "drifting": drifting,
        "speed_anomaly": len(anomaly_segments) > 0,
        "speed_anomaly_segments": anomaly_segments,
    };
}


def classify_pair(samples_a: list, samples_b: list) -> dict {
    """The one classifier family that needs two tracks: rendezvous."""
    return {
        "rendezvous": is_rendezvous(samples_a, samples_b),
        "rendezvous_dwell_s": longest_rendezvous_dwell_s(samples_a, samples_b),
    };
}


# ---------------------------------------------------------------------------
# Briefing text -- deterministic, template-based, matching the rest of the
# codebase's "no LLM call inside a scoring/classification kernel" rule
# (see jac/jtms.jac's brief_for() for the same discipline applied to belief
# revision instead of behaviour classification).
# ---------------------------------------------------------------------------

def describe(track_id: str, result: dict) -> str {
    """One-line, deterministic description of a classify() result. Order of
    checks is fixed so the same input always produces the same sentence,
    and multiple simultaneous behaviours are joined rather than one being
    silently dropped."""
    clauses = [];
    if result.get("loitering") {
        clauses.append(f"loitering (radius ~{result['loiter_radius_m']:.0f} m)");
    }
    if result.get("loop_closure") {
        clauses.append(f"tracing a closed loop (ratio {result['loop_closure_ratio']:.1f})");
    }
    if result.get("drifting") {
        clauses.append("drifting (no sustained propulsion detected)");
    }
    if result.get("speed_anomaly") {
        n = len(result.get("speed_anomaly_segments", []));
        clauses.append(f"{n} speed-anomaly segment(s) outside its class envelope");
    }
    if not clauses {
        return f"{track_id}: nominal transit, no behaviour flags";
    }
    return f"{track_id}: " + "; ".join(clauses);
}


def describe_pair(track_a: str, track_b: str, result: dict) -> str {
    if result.get("rendezvous") {
        return (
            f"{track_a} and {track_b}: rendezvous held for "
            f"{result['rendezvous_dwell_s']:.0f} s"
        );
    }
    return f"{track_a} and {track_b}: no rendezvous detected";
}


# ---------------------------------------------------------------------------
# Fleet-level pattern matching -- multi-track heuristics layered on top of
# the single-track / two-track classifiers above. Still standalone, still
# unwired: these operate on a caller-supplied {track_id: samples} dict, not
# on the live Mission graph, so nothing here can ever be reached from
# jac/fusion.jac's frame loop without a caller explicitly choosing to.
# ---------------------------------------------------------------------------

glob CONVOY_MIN_SIZE: int = 3;
glob CONVOY_MAX_SPACING_M: float = 400.0;
glob CONVOY_MIN_DWELL_S: float = 600.0;
glob CONVOY_HEADING_TOLERANCE_DEG: float = 20.0;

glob PICKET_LINE_MIN_SIZE: int = 3;
glob PICKET_LINE_COLINEARITY_TOL_M: float = 250.0;

glob SHADOWING_MAX_RANGE_M: float = 800.0;
glob SHADOWING_MIN_DWELL_S: float = 900.0;
glob SHADOWING_MAX_BEARING_DRIFT_DEG: float = 15.0;


def _heading_deg(samples: list, i: int) -> float {
    """Course made good between sample i-1 and i, degrees clockwise from
    true north. Returns 0.0 for i == 0 (no prior sample to differ against)
    rather than raising -- callers scanning a whole track expect a value
    per index, not a ragged list."""
    if i <= 0 or i >= len(samples) {
        return 0.0;
    }
    (_t0, x0, y0) = samples[i - 1];
    (_t1, x1, y1) = samples[i];
    return math.degrees(math.atan2(x1 - x0, y1 - y0)) % 360.0;
}


def _mean_heading_deg(samples: list) -> float {
    """Circular mean of per-segment headings -- a plain arithmetic mean
    would be wrong near the 0/360 wrap, so this averages the unit vectors
    instead."""
    if len(samples) < 2 {
        return 0.0;
    }
    sx = 0.0;
    sy = 0.0;
    for i in range(1, len(samples)) {
        h = math.radians(_heading_deg(samples, i));
        sx += math.sin(h);
        sy += math.cos(h);
    }
    return math.degrees(math.atan2(sx, sy)) % 360.0;
}


def _heading_diff_deg(a: float, b: float) -> float {
    """Smallest signed difference between two headings, in [0, 180]."""
    d = abs(a - b) % 360.0;
    return d if d <= 180.0 else 360.0 - d;
}


def is_convoy(fleet_samples: dict, now_t: float) -> bool {
    """True if at least CONVOY_MIN_SIZE tracks are simultaneously within
    CONVOY_MAX_SPACING_M of each other's most recent position, holding a
    shared heading within CONVOY_HEADING_TOLERANCE_DEG, for at least
    CONVOY_MIN_DWELL_S. This is a coarse spatial-clustering heuristic, not
    a proper formation-flying detector -- it does not distinguish a real
    convoy from three unrelated vessels that happen to be crossing the same
    strait at the same time, which is exactly why this stays an unwired
    exploration rather than something feeding a real alert."""
    ids = list(fleet_samples.keys());
    if len(ids) < CONVOY_MIN_SIZE {
        return False;
    }
    recent_by_id = {
        tid: _window(fleet_samples[tid], LOITER_WINDOW_S, now_t)
        for tid in ids
    };
    recent_by_id = {tid: s for (tid, s) in recent_by_id.items() if len(s) >= 2};
    if len(recent_by_id) < CONVOY_MIN_SIZE {
        return False;
    }

    headings = {tid: _mean_heading_deg(s) for (tid, s) in recent_by_id.items()};
    last_pos = {tid: (s[-1][1], s[-1][2]) for (tid, s) in recent_by_id.items()};

    cluster_ids = list(recent_by_id.keys());
    ref = cluster_ids[0];
    (rx, ry) = last_pos[ref];
    ref_heading = headings[ref];

    cluster = [ref];
    for tid in cluster_ids[1:] {
        (x, y) = last_pos[tid];
        close = _dist(x, y, rx, ry) <= CONVOY_MAX_SPACING_M;
        aligned = _heading_diff_deg(headings[tid], ref_heading) <= CONVOY_HEADING_TOLERANCE_DEG;
        if close and aligned {
            cluster.append(tid);
        }
    }
    if len(cluster) < CONVOY_MIN_SIZE {
        return False;
    }

    spans = [];
    for tid in cluster {
        s = recent_by_id[tid];
        spans.append(s[-1][0] - s[0][0]);
    }
    return min(spans) >= CONVOY_MIN_DWELL_S;
}


def _colinearity_residual_m(points: list) -> float {
    """Max perpendicular distance from any point to the least-squares line
    through all of them -- near zero for a tight line abreast, large for a
    scattered cluster. A hand-rolled total-least-squares fit (via the
    centroid and the direction of maximum variance) rather than pulling in
    a numerical library, since this module deliberately has no numpy
    dependency (see the module docstring: no real dependency on the live
    tracker's kernels)."""
    n = len(points);
    if n < 2 {
        return 0.0;
    }
    cx = sum(p[0] for p in points) / n;
    cy = sum(p[1] for p in points) / n;
    sxx = sum((p[0] - cx) ** 2 for p in points);
    syy = sum((p[1] - cy) ** 2 for p in points);
    sxy = sum((p[0] - cx) * (p[1] - cy) for p in points);
    # Principal axis angle from the 2x2 scatter matrix, closed form.
    theta = 0.5 * math.atan2(2.0 * sxy, sxx - syy);
    dx = math.cos(theta);
    dy = math.sin(theta);
    # Perpendicular residual of each point against the axis through the centroid.
    residuals = [];
    for (px, py) in points {
        rx = px - cx;
        ry = py - cy;
        perp = abs(rx * (-dy) + ry * dx);
        residuals.append(perp);
    }
    return max(residuals);
}


def is_picket_line(fleet_samples: dict, now_t: float) -> bool {
    """True if at least PICKET_LINE_MIN_SIZE tracks' most recent positions
    are nearly colinear (residual under PICKET_LINE_COLINEARITY_TOL_M) --
    consistent with vessels holding a search line or blockade line rather
    than transiting independently."""
    ids = list(fleet_samples.keys());
    if len(ids) < PICKET_LINE_MIN_SIZE {
        return False;
    }
    points = [];
    for tid in ids {
        s = fleet_samples[tid];
        if not s {
            continue;
        }
        recent = _window(s, LOITER_WINDOW_S, now_t);
        if not recent {
            continue;
        }
        (_t, x, y) = recent[-1];
        points.append((x, y));
    }
    if len(points) < PICKET_LINE_MIN_SIZE {
        return False;
    }
    return _colinearity_residual_m(points) <= PICKET_LINE_COLINEARITY_TOL_M;
}


def _bearing_deg(from_x: float, from_y: float, to_x: float, to_y: float) -> float {
    return math.degrees(math.atan2(to_x - from_x, to_y - from_y)) % 360.0;
}


def is_shadowing(samples_a: list, samples_b: list) -> bool {
    """True if track A stays within SHADOWING_MAX_RANGE_M of track B for at
    least SHADOWING_MIN_DWELL_S while the bearing from B to A drifts by no
    more than SHADOWING_MAX_BEARING_DRIFT_DEG over that window -- unlike
    is_rendezvous() (which only cares about range and dwell), this also
    requires A to hold a roughly constant relative bearing to B, consistent
    with A trailing B rather than the two simply crossing paths at close
    range."""
    if len(samples_a) < 2 or not samples_b {
        return False;
    }
    bearings = [];
    open_start = None;
    best_run_s = 0.0;
    for (t, x, y) in samples_a {
        (_tb, xb, yb) = _nearest_sample(samples_b, t);
        in_range = _dist(x, y, xb, yb) <= SHADOWING_MAX_RANGE_M;
        if in_range {
            bearings.append(_bearing_deg(xb, yb, x, y));
            if open_start is None {
                open_start = t;
            }
            span = t - open_start;
            drift = 0.0 if len(bearings) < 2 else max(
                _heading_diff_deg(b, bearings[0]) for b in bearings
            );
            if drift <= SHADOWING_MAX_BEARING_DRIFT_DEG {
                best_run_s = max(best_run_s, span);
            } else {
                open_start = t;
                bearings = [bearings[-1]];
            }
        } else {
            open_start = None;
            bearings = [];
        }
    }
    return best_run_s >= SHADOWING_MIN_DWELL_S;
}


# ---------------------------------------------------------------------------
# Fleet-level briefing text
# ---------------------------------------------------------------------------

def describe_fleet(fleet_samples: dict, now_t: float) -> list {
    """Every fleet-level pattern this module knows how to name, as
    deterministic one-line sentences -- empty list if none apply. Order is
    fixed (convoy, then picket line) so repeated calls against the same
    input are stable, matching jac/jtms.jac's brief_for() discipline of
    "same state, same string"."""
    lines = [];
    if is_convoy(fleet_samples, now_t) {
        lines.append(
            f"possible convoy: {len(fleet_samples)} tracks holding formation"
        );
    }
    if is_picket_line(fleet_samples, now_t) {
        lines.append(
            f"possible picket line: {len(fleet_samples)} tracks nearly colinear"
        );
    }
    return lines;
}


# ---------------------------------------------------------------------------
# Self-check fixtures -- deterministic synthetic tracks used to sanity-eye
# each classifier's behaviour by hand (not wired to pytest/jac test; this
# module is explicitly not part of the test suite, see the module docstring).
# ---------------------------------------------------------------------------

def _synthetic_loiter_track(n: int = 30, radius_m: float = 200.0, dt: float = 30.0) -> list {
    """A tight circle centred on the origin -- should trip is_loitering()
    and is_loop_closure() but not is_drifting() or has_speed_anomaly()."""
    samples = [];
    for i in range(n) {
        theta = 2.0 * math.pi * i / max(n - 1, 1);
        x = radius_m * math.cos(theta);
        y = radius_m * math.sin(theta);
        samples.append((i * dt, x, y));
    }
    return samples;
}


def _synthetic_transit_track(n: int = 30, speed_mps: float = 8.0, dt: float = 30.0) -> list {
    """A straight-line transit at constant speed -- should trip none of the
    single-track classifiers when given a matching vessel_class envelope."""
    samples = [];
    for i in range(n) {
        t = i * dt;
        samples.append((t, speed_mps * t, 0.0));
    }
    return samples;
}


def _synthetic_drift_track(n: int = 30, dt: float = 30.0, jitter_m: float = 5.0) -> list {
    """Near-stationary with only small jitter -- should trip is_drifting()
    once DRIFT_MIN_WINDOW_S worth of samples exist."""
    samples = [];
    for i in range(n) {
        wobble = jitter_m * math.sin(i * 0.7);
        samples.append((i * dt, wobble, -wobble));
    }
    return samples;
}


def _synthetic_speed_burst_track(
    n_before: int = 10, n_burst: int = 10, n_after: int = 10,
    cruise_mps: float = 5.0, burst_mps: float = 22.0, dt: float = 30.0,
) -> list {
    """Cruise, then a sustained fast burst, then back to cruise -- should
    trip has_speed_anomaly() for a vessel_class whose envelope tops out
    below burst_mps, and should NOT trip it for "unknown" (whose envelope
    is wide enough to cover the burst)."""
    samples = [];
    t = 0.0;
    x = 0.0;
    for _i in range(n_before) {
        samples.append((t, x, 0.0));
        t += dt;
        x += cruise_mps * dt;
    }
    for _i in range(n_burst) {
        samples.append((t, x, 0.0));
        t += dt;
        x += burst_mps * dt;
    }
    for _i in range(n_after) {
        samples.append((t, x, 0.0));
        t += dt;
        x += cruise_mps * dt;
    }
    return samples;
}


def _synthetic_convoy(n_vessels: int = 3, spacing_m: float = 100.0,
                       n_samples: int = 25, speed_mps: float = 6.0,
                       dt: float = 30.0) -> dict {
    """n_vessels holding a line-abreast formation on a shared heading --
    should trip is_convoy() and, since the formation is a straight line
    perpendicular to travel, should also trip is_picket_line() on the
    final-position snapshot."""
    fleet = {};
    for v in range(n_vessels) {
        offset = (v - (n_vessels - 1) / 2.0) * spacing_m;
        samples = [];
        for i in range(n_samples) {
            t = i * dt;
            samples.append((t, speed_mps * t, offset));
        }
        fleet[f"convoy-{v}"] = samples;
    }
    return fleet;
}


def _synthetic_shadow_pair(n: int = 30, trail_range_m: float = 300.0,
                            speed_mps: float = 7.0, dt: float = 30.0) -> tuple {
    """Track B leads, track A trails directly astern at a fixed range --
    should trip is_shadowing() (constant bearing, in-range) but NOT
    is_rendezvous() (range exceeds RENDEZVOUS_RANGE_M)."""
    lead = [];
    trail = [];
    for i in range(n) {
        t = i * dt;
        x = speed_mps * t;
        lead.append((t, x, 0.0));
        trail.append((t, x - trail_range_m, 0.0));
    }
    return (trail, lead);
}


def self_check_summary() -> dict {
    """Runs every synthetic fixture above through the classifiers it is
    meant to exercise and reports which ones fired. A hand-inspection aid,
    not an automated assertion -- see the module docstring for why this
    file has no real test wiring."""
    now_t = 900.0;
    loiter = _synthetic_loiter_track();
    transit = _synthetic_transit_track();
    drift = _synthetic_drift_track();
    burst = _synthetic_speed_burst_track();
    convoy_fleet = _synthetic_convoy();
    (shadow_trail, shadow_lead) = _synthetic_shadow_pair();

    return {
        "loiter_track": classify(loiter, now_t),
        "transit_track": classify(transit, now_t, vessel_class="cargo"),
        "drift_track": classify(drift, DRIFT_MIN_WINDOW_S + 1.0),
        "burst_track_vs_fishing": classify(burst, burst[-1][0], vessel_class="fishing"),
        "burst_track_vs_unknown": classify(burst, burst[-1][0], vessel_class="unknown"),
        "convoy_fleet": describe_fleet(convoy_fleet, convoy_fleet["convoy-0"][-1][0]),
        "shadowing": is_shadowing(shadow_trail, shadow_lead),
        "shadow_pair_not_rendezvous": is_rendezvous(shadow_trail, shadow_lead),
    };
}


def self_check_report(result: dict) -> str {
    """Turns self_check_summary()'s dict into a human-readable multi-line
    report -- one line per fixture, expected-vs-observed, so a hand
    inspection does not require reading raw dict output."""
    lines = [];
    lines.append("=== classifier.jac self-check ===");

    loiter = result.get("loiter_track", {});
    lines.append(
        f"loiter fixture: loitering={loiter.get('loitering')} "
        f"(expected True), loop_closure={loiter.get('loop_closure')} (expected True)"
    );

    transit = result.get("transit_track", {});
    lines.append(
        f"transit fixture: loitering={transit.get('loitering')} (expected False), "
        f"speed_anomaly={transit.get('speed_anomaly')} (expected False)"
    );

    drift = result.get("drift_track", {});
    lines.append(f"drift fixture: drifting={drift.get('drifting')} (expected True)");

    burst_fish = result.get("burst_track_vs_fishing", {});
    burst_unk = result.get("burst_track_vs_unknown", {});
    lines.append(
        f"speed-burst fixture: anomaly_vs_fishing={burst_fish.get('speed_anomaly')} "
        f"(expected True), anomaly_vs_unknown={burst_unk.get('speed_anomaly')} (expected False)"
    );

    convoy_lines = result.get("convoy_fleet", []);
    lines.append(f"convoy fixture: {len(convoy_lines)} fleet pattern(s) detected (expected >= 1)");
    for cl in convoy_lines {
        lines.append(f"  - {cl}");
    }

    lines.append(
        f"shadow fixture: shadowing={result.get('shadowing')} (expected True), "
        f"rendezvous={result.get('shadow_pair_not_rendezvous')} (expected False)"
    );
    return "\n".join(lines);
}


with entry:__main__ {
    print(self_check_report(self_check_summary()));
}


# ---------------------------------------------------------------------------
# Version / provenance marker -- lets a caller confirm which revision of
# this standalone module a given self-check report came from, the same
# lightweight discipline as tracker/eval.py's PackResult carrying `path`.
# ---------------------------------------------------------------------------

glob CLASSIFIER_MODULE_VERSION: str = "0.1.0-unwired";

def module_info() -> dict {
    """Static metadata about this module -- version, and an explicit,
    honest statement of its wiring status, so nothing downstream ever has
    to guess whether classify()'s output reflects live tracker data."""
    return {
        "version": CLASSIFIER_MODULE_VERSION,
        "wired_into_pipeline": False,
        "note": (
            "Standalone behaviour-classification exploration. Not imported "
            "by jac/main.jac, jac/fusion.jac, or web/server.py. Operates on "
            "caller-supplied (t, x, y) sample lists, not live Track nodes."
        ),
    };
}


def classifier_family_names() -> list {
    """Every classification family this module implements, by name."""
    return ["loitering", "rendezvous", "speed_anomaly", "loop_closure",
            "drift", "convoy", "picket_line", "shadowing"];
}


def classifier_family_count() -> int {
    return len(classifier_family_names());
}


def summarize_families(fleet_samples: dict, single_samples: dict, now_t: float,
                        vessel_classes: dict = {}) -> dict {
    """Convenience wrapper: run every single-track classifier over
    `single_samples` (track_id -> samples) plus the fleet-level checks over
    `fleet_samples`, keyed the same way classify()/describe_fleet() already
    are. Purely a caller-ergonomics helper -- it adds no new detection
    logic, just batches calls that would otherwise be a manual loop."""
    per_track = {};
    for (tid, samples) in single_samples.items() {
        vclass = vessel_classes.get(tid, "unknown");
        per_track[tid] = classify(samples, now_t, vessel_class=vclass);
    }
    fleet_lines = describe_fleet(fleet_samples, now_t) if fleet_samples else [];
    return {"per_track": per_track, "fleet_lines": fleet_lines};
}


def summarize_families_report(result: dict) -> str {
    """Human-readable rendering of summarize_families()'s output, one line
    per track plus the fleet-level lines -- the multi-track analogue of
    describe()/self_check_report() above."""
    lines = ["=== fleet + per-track summary ==="];
    for (tid, r) in result.get("per_track", {}).items() {
        lines.append(describe(tid, r));
    }
    for fl in result.get("fleet_lines", []) {
        lines.append(fl);
    }
    if len(lines) == 1 {
        lines.append("(no tracks, no fleet patterns)");
    }
    return "\n".join(lines);
}
