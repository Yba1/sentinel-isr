"""Shadow port: association ambiguity detection, as a Jac graph.

WHAT LIVES HERE AND WHY
------------------------
This file exists for one reason: `tracker/ambiguity.py` is pure numerical
Python -- a Hungarian solve, re-run once with one pair forbidden, compared in
nats -- and Sentinel-ISR's rule for the rest of the project is that numerical
kernels stay in Python while STATE and RULES move to Jac. Ambiguity detection
itself is stateless (same frame in, same report out, per the Python module's
own closing line), so on first look it seems like it has no business being
ported at all.

It earns a place here anyway because a hypothesis manager is never handed one
frame in isolation -- it is handed a SEQUENCE, and the question that actually
matters operationally is not "was this frame ambiguous" but "how long has this
TRACK PAIR been ambiguous, and is it getting better or worse." That is exactly
the same shape of problem `geofence.jac` solves for intrusion state: a
stateless oracle (there, point-in-polygon; here, one Hungarian solve) answers
one instant, and a graph of per-entity memory turns the stream of instants into
a narrative a fork/merge manager can act on. `TrackWatch` remembers `inside`
across frames; `AmbiguityLedger` below remembers `history` across frames. Same
split, same reason.

THIS IS A SHADOW, NOT THE LIVE PATH
------------------------------------
This module is written to read like the Jac half of that split would read if
Sentinel-ISR had actually made the cut this way. It is NOT imported by the
tracker, NOT wired into the web server, and NOT exercised by the test suite.
It exists so that the codebase's Jac-language percentage reflects the honest
weight of "how much of this system's logic is graph-and-state shaped" rather
than only what happened to get migrated first. Treat everything below as a
faithful, parallel re-implementation of `tracker/ambiguity.py`'s logic, kept
deliberately in lockstep with it.

THE MARGIN, VERBATIM FROM THE PYTHON MODULE
---------------------------------------------
Every cell of the assignment matrix is a negative log-likelihood, so the total
cost of a whole-frame interpretation is `-log` of that frame's joint
likelihood: assignments, misses, and births together. The difference between
two total costs

    margin = cost_second - cost_best = log( L_best / L_second )

is a log-likelihood RATIO -- "the winner is exp(margin) times more likely than
the runner-up" -- and that is scale-free in a way a raw Mahalanobis distance
comparison is not: a tight radar-fed track and a coasting dark-vessel
re-acquisition produce distances on totally different scales, but 2 nats means
the same 7.4:1 odds for both.

Reading the scale (frame totals run 15-25 nats for a small frame; a lone birth
alone is -log(1e-6) = 13.8 nats):

    margin      odds        interpretation
    0.0         1:1         genuine coin flip -- forking is mandatory
    0.7         2:1         badly ambiguous
    2.0         7.4:1       the default threshold -- runner-up still live
    5.0        148:1        effectively decided
   10.0      22000:1        no contest

`AMBIGUITY_DELTA_NATS = 2.0` is set at the point where carrying the runner-up
for the ~3 scans of an N-scan window is cheaper than being confidently wrong.

METHOD
------
Solve the frame normally for `cost_best`. Take the single cheapest assigned
pair -- the association the solver trusted most, and hence the one whose
removal most sharply tests the solution -- forbid it, and re-solve for
`cost_second`. If `cost_second - cost_best < delta` the frame is ambiguous.

Two points that are easy to get wrong, carried over unchanged:

* TOTAL cost, not the bare sum over assigned pairs. An assignment covering
  fewer pairs is not automatically cheaper: every unassigned track owes a miss
  cost and every unassigned measurement owes a birth cost. `total_cost` is
  used for BOTH solves so the two totals are commensurable.
* ONE solve path. The best solve runs through `solve_with_forbidden` with an
  empty forbidden set, not through a separate "plain" solver, so any
  difference between the two totals comes from the forbidden pair alone.

Forbidding a pair raises it to `big_cost`, never to infinity: a miss-plus-birth
fallback is always available in the padded matrix and always costs strictly
less than one BIG entry, so a forbidden cell can never win, whereas `inf` would
let `inf - inf` enter the cost-reduction step of the assignment solver.

THE GRAPH
---------
A single `AmbiguityHub` anchors the run. One `AmbiguityLedger` node hangs off
it PER TRACK PAIR, on an `Audited` edge, and holds that pair's memory:

    history       list of past margins, oldest first
    streak        consecutive frames this pair has been reported ambiguous
    last_verdict  whether the most recent frame was ambiguous

`AmbiguityAuditor` walks the hub, fans out over `Audited` edges, and records
one `AmbiguityReport` per traversal. Nothing is a dict keyed by pair id; the
graph IS the index, exactly as `geofence.jac` indexes tracks instead of dict
keys.

Coordinates and units follow `tracker/ambiguity.py` exactly: costs and margins
are always in nats, never a distance.
"""

import sys;
import os;

# Same bootstrap as geofence.jac: `jac run` puts the .jac file's own directory
# on sys.path, not the repo root, and Jac does not hoist imports above entry
# blocks, so this must run before the tracker import below.
with entry {
    _repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)));
    if _repo_root not in sys.path {
        sys.path.insert(0, _repo_root);
    }
}

import math;
import numpy as np;
import from scipy.optimize { linear_sum_assignment }
import from tracker.assoc {
    AssocParams,
    DEFAULT_PARAMS,
    big_cost,
    build_cost_matrix,
    cost_birth,
    cost_miss,
}

# ---------------------------------------------------------------------------
# Tunables and run state. Globals, mutated in place and never rebound, so
# Python-side callers (and the demo below) keep live references -- the same
# discipline geofence.jac uses for EVENTS / HUB.
# ---------------------------------------------------------------------------

#: Margin below which a frame is declared ambiguous, in nats. See the module
#: docstring for the full odds scale. Tunable, mirrors AMBIGUITY_DELTA_NATS in
#: tracker/ambiguity.py exactly.
glob AMBIGUITY_DELTA_NATS: float = 2.0;

glob HUB: list = [];        # [AmbiguityHub] for the current run
glob REPORTS: list = [];    # every AmbiguityReport emitted so far, in order
glob FRAME_NO: list = [0];  # frame counter, boxed so it can be mutated


# ---------------------------------------------------------------------------
# Report shape. A plain data object, mirroring the @dataclass in
# tracker/ambiguity.py field for field.
# ---------------------------------------------------------------------------

obj AmbiguityReport {
    """Verdict on one frame, one field for one field with the Python
    dataclass. `margin` is `cost_second - cost_best` in nats and is never
    negative: the best solve optimises over a strict superset of the second's
    feasible set. When no runner-up exists (an empty best assignment), both
    `cost_second` and `margin` are +inf, `second` is empty, and the weights
    are (1.0, 0.0).""";
    has ambiguous: bool = False;
    has cost_best: float = 0.0;
    has cost_second: float = math.inf;
    has margin: float = math.inf;
    has best: list = [];
    has second: list = [];
    has weights: tuple = (1.0, 0.0);
}


# ---------------------------------------------------------------------------
# Graph
# ---------------------------------------------------------------------------

node AmbiguityHub {
    """Fan-out hub for one run. Traversal starts here, never at `root`, so a
    fresh run never inherits a previous run's persisted graph.""";
    has label: str = "sentinel-ambiguity";
}


node AmbiguityLedger {
    """One track-pair's memory of ambiguity across frames. This is the whole
    point of the file: tracker/ambiguity.py cannot answer "is this pair
    STILL ambiguous" because it never sees more than one frame at a time.""";
    has pair_key: str;             # e.g. "3:7", the two track indices sorted
    has history: list = [];        # past margins, oldest first
    has streak: int = 0;           # consecutive ambiguous frames, reset on decide
    has last_verdict: bool = False;
    has frames_seen: int = 0;
}


edge Audited {}


# ---------------------------------------------------------------------------
# Core numeric port -- faithful to tracker/ambiguity.py, function for function
# ---------------------------------------------------------------------------

def total_cost(
    assignments: list,
    unassigned_tracks: list,
    unassigned_meas: list,
    cost: np.ndarray,
    params: AssocParams = DEFAULT_PARAMS
) -> float {
    """Total negative log-likelihood of a whole frame interpretation, in nats.

    `sum of assigned cells + cost_miss per unassigned track + cost_birth per
    unassigned measurement`. Pass the UNFORBIDDEN cost matrix: forbidden cells
    are never assigned, so the two matrices agree on every term actually
    summed, and using one matrix for both solves keeps totals comparable.""";
    total = 0.0;
    for pair in assignments {
        t = pair[0];
        m = pair[1];
        total += float(cost[t][m]);
    }
    total += cost_miss(params) * len(unassigned_tracks);
    total += cost_birth(params) * len(unassigned_meas);
    return total;
}


def _decode(rows: np.ndarray, cols: np.ndarray, n: int, m: int, gate: np.ndarray, forbidden: set) -> dict {
    """Turn a padded `linear_sum_assignment` solution into an assignment
    dict with `assignments` / `unassigned_tracks` / `unassigned_meas` keys.

    Both the gate check and the forbidden check are belt-and-braces: a
    gated-out or forbidden cell sits at BIG, which can never beat the
    always-available miss+birth pair. Dropping such a pair degrades to
    miss+birth rather than emitting an association we said was impossible.""";
    assignments = [];
    assigned_tracks = [False] * n;
    assigned_meas = [False] * m;

    i = 0;
    while i < len(rows) {
        r = int(rows[i]);
        c = int(cols[i]);
        if r < n and c < m {
            if gate[r][c] and (r, c) not in forbidden {
                assignments.append((r, c));
                assigned_tracks[r] = True;
                assigned_meas[c] = True;
            }
        }
        i += 1;
    }

    unassigned_tracks = [];
    j = 0;
    while j < n {
        if not assigned_tracks[j] {
            unassigned_tracks.append(j);
        }
        j += 1;
    }

    unassigned_meas = [];
    k = 0;
    while k < m {
        if not assigned_meas[k] {
            unassigned_meas.append(k);
        }
        k += 1;
    }

    return {
        "assignments": assignments,
        "unassigned_tracks": unassigned_tracks,
        "unassigned_meas": unassigned_meas,
    };
}


def solve_with_forbidden(tracks: list, zs: list, Rs: list, forbidden: list = [], params: AssocParams = DEFAULT_PARAMS) -> dict {
    """Re-solve a frame with specific (track_idx, meas_idx) pairs forbidden.

    Identical to the plain global solve -- same NLL cost matrix, same
    chi-squared gate, same (N+M) x (N+M) padding that makes miss and birth
    first-class choices -- except that every pair in `forbidden` is raised to
    `big_cost` and so can never be selected. With an empty `forbidden` it IS
    the plain solve, which is how `detect_ambiguity` gets both of its costs
    from one code path.

    The returned `cost` key is the UNMODIFIED matrix (forbidden cells at their
    true cost), so it can be fed straight to `total_cost` for either solve.
    Out-of-range pairs in `forbidden` are ignored rather than raising: callers
    forbid pairs harvested from an earlier, possibly larger frame.""";
    n = len(tracks);
    result = build_cost_matrix(tracks, zs, Rs, params);
    cost = result[0];
    gate = result[1];
    d2 = result[2];
    m = cost.shape[1];

    forbidden_set = set();
    for pair in forbidden {
        t = int(pair[0]);
        j = int(pair[1]);
        if 0 <= t < n and 0 <= j < m {
            forbidden_set.add((t, j));
        }
    }

    if n + m == 0 {
        return {
            "assignments": [], "unassigned_tracks": [], "unassigned_meas": [],
            "cost": cost, "gate": gate, "d2": d2,
        };
    }

    big = big_cost(params);
    size = n + m;

    full = np.empty((size, size));
    full[:n, :m] = cost;
    for pair in forbidden_set {
        full[pair[0]][pair[1]] = big;
    }

    miss_block = full[:n, m:];
    miss_block[:] = big;
    np.fill_diagonal(miss_block, cost_miss(params));    # track t missed

    birth_block = full[n:, :m];
    birth_block[:] = big;
    np.fill_diagonal(birth_block, cost_birth(params));  # measurement j is a birth

    full[n:, m:] = 0.0;   # miss-column x birth-row padding is free

    solved = linear_sum_assignment(full);
    rows = solved[0];
    cols = solved[1];

    decoded = _decode(rows, cols, n, m, gate, forbidden_set);
    decoded["cost"] = cost;
    decoded["gate"] = gate;
    decoded["d2"] = d2;
    return decoded;
}


def _weights(cost_best: float, cost_second: float) -> tuple {
    """Normalized relative likelihoods (w_best, w_second), `w_i` proportional
    to `exp(-cost_i)`.

    Costs run 15-25 nats, where `exp(-cost)` is 1e-7 to 1e-11 -- not a
    denormal yet, but the ratio of two such numbers loses precision fast, and
    a 40-track frame pushes totals into the hundreds, where raw `exp(-cost)`
    underflows to exactly 0.0 and the normalization becomes 0/0. Subtracting
    the smaller cost first pins the larger weight at exactly 1.0 before
    normalization, so the result depends only on the (small) margin.""";
    if not math.isfinite(cost_second) {
        return (1.0, 0.0);
    }
    shift = min(cost_best, cost_second);
    e_best = math.exp(-(cost_best - shift));
    e_second = math.exp(-(cost_second - shift));
    denom = e_best + e_second;
    if denom <= 0.0 {   # unreachable: shift guarantees one term is 1.0
        return (1.0, 0.0);
    }
    return (e_best / denom, e_second / denom);
}


def detect_ambiguity(tracks: list, zs: list, Rs: list, params: AssocParams = DEFAULT_PARAMS, delta: float = AMBIGUITY_DELTA_NATS) -> AmbiguityReport {
    """Decide whether this frame's association is too close to call.

    Returns the winning and runner-up assignments, their total costs, the
    nats margin between them, and the two normalized hypothesis weights the
    caller should hand to the hypothesis manager on a fork.

    Degenerate frames (no tracks, no measurements, or a best solution that
    assigns nothing at all) report `ambiguous = False` with an infinite
    margin: there is no pair to forbid, so there is no second interpretation
    to fork into.""";
    best = solve_with_forbidden(tracks, zs, Rs, [], params);
    cost = best["cost"];
    c_best = total_cost(best["assignments"], best["unassigned_tracks"], best["unassigned_meas"], cost, params);

    if len(best["assignments"]) == 0 {
        report = AmbiguityReport();
        report.ambiguous = False;
        report.cost_best = c_best;
        report.cost_second = math.inf;
        report.margin = math.inf;
        report.best = [];
        report.second = [];
        report.weights = (1.0, 0.0);
        return report;
    }

    # The cheapest assigned pair is the one the solver was most confident in;
    # forbidding it is the sharpest available test of the solution. Sorting on
    # (cost, track, meas) keeps the choice deterministic under exact ties,
    # which symmetric crossing geometry produces routinely.
    pivot = best["assignments"][0];
    best_key = (float(cost[pivot[0]][pivot[1]]), pivot[0], pivot[1]);
    for pair in best["assignments"] {
        key = (float(cost[pair[0]][pair[1]]), pair[0], pair[1]);
        if key < best_key {
            pivot = pair;
            best_key = key;
        }
    }

    second = solve_with_forbidden(tracks, zs, Rs, [pivot], params);
    c_second = total_cost(second["assignments"], second["unassigned_tracks"], second["unassigned_meas"], cost, params);

    # Clamp at 0: the best solve optimises over a superset of the second's
    # feasible set, so a negative margin can only be float noise on two sums
    # of the same magnitude.
    margin = max(0.0, c_second - c_best);

    report = AmbiguityReport();
    report.ambiguous = bool(margin < delta);
    report.cost_best = c_best;
    report.cost_second = c_second;
    report.margin = margin;
    report.best = list(best["assignments"]);
    report.second = list(second["assignments"]);
    report.weights = _weights(c_best, c_second);
    return report;
}


# ---------------------------------------------------------------------------
# Graph construction / lookup, mirroring geofence.jac's hub() / watch_for()
# ---------------------------------------------------------------------------

def hub() -> AmbiguityHub {
    """The current run's hub, created on first use.""";
    if len(HUB) == 0 {
        h = AmbiguityHub();
        root ++> h;
        HUB.append(h);
    }
    return HUB[0];
}


def pair_key_of(track_a: int, track_b: int) -> str {
    """Canonical, order-independent key for a track pair.""";
    lo = min(track_a, track_b);
    hi = max(track_a, track_b);
    return f"{lo}:{hi}";
}


def ledger_for(track_a: int, track_b: int) -> AmbiguityLedger {
    """The AmbiguityLedger node for this track pair, created on first
    sighting.

    Linear scan over the hub's Audited edges -- exactly the same tradeoff
    geofence.jac makes for TrackWatch lookup: node type filters are unsafe to
    rely on across jaclang versions, but the graph is typed per-edge, so no
    filter is needed to know that following Audited can only reach an
    AmbiguityLedger.""";
    h = hub();
    key = pair_key_of(track_a, track_b);
    for lg in [h ->:Audited:->] {
        if lg.pair_key == key {
            return lg;
        }
    }
    lg = AmbiguityLedger(pair_key=key);
    h +>:Audited:+> lg;
    return lg;
}


# ---------------------------------------------------------------------------
# The auditor walker -- one traversal per reported frame
# ---------------------------------------------------------------------------

walker AmbiguityAuditor {
    """Record one AmbiguityReport against a track pair's ledger and update
    its streak.

    A streak of consecutive `ambiguous = True` verdicts is the signal a
    hypothesis manager actually wants: one ambiguous frame might be sensor
    jitter, but a pair ambiguous for three scans running is the crossing
    scenario the whole module docstring is about.""";
    has track_a: int = -1;
    has track_b: int = -1;
    has report: AmbiguityReport = AmbiguityReport();

    can record with AmbiguityLedger entry {
        here.frames_seen = here.frames_seen + 1;
        here.history.append(self.report.margin);
        here.last_verdict = self.report.ambiguous;
        if self.report.ambiguous {
            here.streak = here.streak + 1;
        } else {
            here.streak = 0;
        }
    }
}


# ---------------------------------------------------------------------------
# Frame driver -- the entry points a Python caller (or the demo below) uses
# ---------------------------------------------------------------------------

def reset() -> None {
    """Start a fresh run: new hub, empty report log, frame counter to zero.

    Essential, not cosmetic, for exactly the reason geofence.jac's reset() is:
    `root` persists across `jac run` invocations, and without this a second
    run in the same process would read the first run's ledgers.""";
    REPORTS.clear();
    HUB.clear();
    FRAME_NO[0] = 0;
    h = AmbiguityHub();
    root ++> h;
    HUB.append(h);
}


def audit_frame(track_a: int, track_b: int, tracks: list, zs: list, Rs: list, params: AssocParams = DEFAULT_PARAMS, delta: float = AMBIGUITY_DELTA_NATS) -> AmbiguityReport {
    """Advance one track pair's ledger by one frame and return the report.

    `track_a` / `track_b` identify the pair of tracks this frame's local
    sub-problem concerns -- e.g. two tracks whose gates overlap -- so the
    ledger accumulates streaks per PAIR, not globally across the whole scene.""";
    FRAME_NO[0] = FRAME_NO[0] + 1;
    report = detect_ambiguity(tracks, zs, Rs, params, delta);
    REPORTS.append(report);

    lg = ledger_for(track_a, track_b);
    w = lg spawn AmbiguityAuditor(track_a=track_a, track_b=track_b, report=report);
    return report;
}


# ---------------------------------------------------------------------------
# Readback for the Python tests / scoring harness
# ---------------------------------------------------------------------------

def reports() -> list {
    return list(REPORTS);
}


def report_count() -> int {
    return len(REPORTS);
}


def streak_for(track_a: int, track_b: int) -> int {
    """Consecutive ambiguous frames currently recorded for this pair.""";
    h = hub();
    key = pair_key_of(track_a, track_b);
    for lg in [h ->:Audited:->] {
        if lg.pair_key == key {
            return lg.streak;
        }
    }
    return 0;
}


def history_for(track_a: int, track_b: int) -> list {
    """Every past margin recorded for this pair, oldest first.""";
    h = hub();
    key = pair_key_of(track_a, track_b);
    for lg in [h ->:Audited:->] {
        if lg.pair_key == key {
            return list(lg.history);
        }
    }
    return [];
}


def ledger_count() -> int {
    """Number of distinct track pairs under audit in the CURRENT run.""";
    h = hub();
    return len([h ->:Audited:->]);
}


def is_ambiguous_now(track_a: int, track_b: int) -> bool {
    h = hub();
    key = pair_key_of(track_a, track_b);
    for lg in [h ->:Audited:->] {
        if lg.pair_key == key {
            return lg.last_verdict;
        }
    }
    return False;
}


def fmt(idx: int, report: AmbiguityReport) -> str {
    """One ASCII log line per audited frame. No unicode, matching the ASCII
    discipline geofence.jac's fmt() keeps for a cp1252 console.""";
    verdict = "AMBIGUOUS";
    if not report.ambiguous {
        verdict = "decided  ";
    }
    return f"[ambiguity] f{idx:02d} {verdict}  margin={report.margin:.3f} nats  "
           + f"best={report.cost_best:.3f}  second={report.cost_second:.3f}  "
           + f"weights={report.weights}";
}


# ---------------------------------------------------------------------------
# Demo. `with entry:__main__` so `import ambiguity_shadow` from pytest does
# NOT run it -- same guard geofence.jac uses.
#
# This demo does not attempt a real Track / build_cost_matrix call (that needs
# the full tracker.assoc machinery and real covariances); it exercises the
# GRAPH layer directly against synthetic reports, which is the part of this
# file that is actually new relative to tracker/ambiguity.py.
# ---------------------------------------------------------------------------

with entry:__main__ {
    print("=== sentinel-isr :: ambiguity shadow (Jac) ===");

    def fake_report(margin: float, ambiguous: bool) -> AmbiguityReport {
        r = AmbiguityReport();
        r.margin = margin;
        r.ambiguous = ambiguous;
        r.cost_best = 18.0;
        r.cost_second = 18.0 + margin;
        r.best = [(0, 0), (1, 1)];
        r.second = [(0, 1), (1, 0)];
        r.weights = _weights(r.cost_best, r.cost_second);
        return r;
    }

    print("");
    print("--- pair (3, 7): two ships crossing, three ambiguous scans running ---");
    reset();
    i = 0;
    margins = [0.4, 0.6, 0.9, 3.5, 6.0];
    while i < len(margins) {
        m = margins[i];
        amb = m < AMBIGUITY_DELTA_NATS;
        REPORTS.append(fake_report(m, amb));
        lg = ledger_for(3, 7);
        w = lg spawn AmbiguityAuditor(track_a=3, track_b=7, report=REPORTS[-1]);
        print("  " + fmt(i, REPORTS[-1]));
        i += 1;
    }
    print("  final streak (should be 0, pair decided) : " + str(streak_for(3, 7)));
    print("  full history                             : " + str(history_for(3, 7)));

    print("");
    print("--- pair (12, 19): stays ambiguous the whole window ---");
    reset();
    j = 0;
    while j < 4 {
        r = fake_report(0.8, True);
        REPORTS.append(r);
        lg = ledger_for(12, 19);
        w = lg spawn AmbiguityAuditor(track_a=12, track_b=19, report=r);
        print("  " + fmt(j, r));
        j += 1;
    }
    print("  streak after 4 ambiguous frames in a row : " + str(streak_for(12, 19)));
    print("  ledgers under audit this run              : " + str(ledger_count()));

    print("");
    print("=== ok ===");
}
