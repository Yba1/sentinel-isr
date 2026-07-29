"""Phase 6 (proposed): batch scenario stress-test harness, as a Jac graph.

WHAT LIVES HERE AND WHY
------------------------
Every scenario pack under `scenarios/*/pack.json` is a hand-authored fixture:
one dark-vessel event, one geofence, one particular crossing geometry, checked
by `eval.jac` against a fixed `expected` block. That is exactly the right tool
for regression -- "did this specific known-good scenario stay good" -- and
exactly the wrong tool for the question this file exists to answer: "across
the huge space of scenarios we did NOT hand-author, where does the tracker
quietly fall over?" A hand-authored pack tells you about the point in
parameter space someone thought to write down. It tells you nothing about the
neighbourhood around that point.

So `stress.jac` is a generator, not a fixture. It manufactures a large batch
of SYNTHETIC scenario variants by walking a seeded grid over three axes that
are known (from the geometry in `eval.jac`'s `check_min_separation_km` and the
dark-window timing chain `check_dark_at_s` / `check_radar_contact_at_s`) to be
the ones that stress the tracker hardest:

  * vessel density      -- more simultaneous contacts means more crossing
                            geometry means more Mahalanobis-gated association
                            decisions land near the gate boundary instead of
                            deep inside or deep outside it.
  * closing speed        -- a faster closing speed compresses the number of
                            scans available to disambiguate a crossing before
                            the two tracks are close enough to be genuinely
                            confusable, which is exactly the depth budget
                            `hypothesis.jac`'s NSCAN_DEPTH collapse is betting
                            against.
  * dark-window duration -- a longer AIS-off window means the reassociation
                            search has to reach further in state space (larger
                            predicted covariance ellipse) to find the same
                            physical vessel again, which is exactly what
                            widens the Mahalanobis gate the dark-vessel
                            re-association logic checks against.

This module is deliberately NOT wired into the live web server and is NOT
imported by anything else in the repo. It is a standalone harness: point a
human or a CI job at it, get back a pass/fail verdict against configurable
thresholds, and the numbers behind that verdict are also here for someone
doing the actual investigation. It exists to grow the surface of scenario
space that gets *some* automated coverage between the (much sparser) set of
hand-authored packs `eval.jac` checks.

THE MODEL
---------
`ScenarioVariant` nodes are the generated scenario descriptions -- pure
parameters, no engine run yet. `StressPass` edges connect a variant to the
`RunOutcome` node holding the (simulated) result of scoring that variant once.
`StressBatch` is the root-adjacent container node for one whole invocation:
it owns the seed, the axis ranges, and aggregates the summary statistics once
every variant in the batch has an outcome attached.

Why a graph at all, instead of three parallel Python lists (variants, results,
stats)? Because the natural question asked of this harness is never "give me
list index 47" -- it is "walk every outcome attached to this batch and bucket
it by which axis was extreme", which is a traversal over a small typed graph,
not list arithmetic. That is the same argument `hypothesis.jac`'s module
docstring makes for the hypothesis tree, applied one level up: the batch/
variant/outcome relationship is graph-shaped, so it is a graph.

SEEDING AND REPRODUCIBILITY
----------------------------
Every variant is generated from a single integer seed plus its own index in
the batch, combined with a splitting step (`_split_seed`) so that:
  (a) the SAME top-level seed always reproduces the SAME batch, byte for
      byte, which is what makes a "regression in the stress harness itself"
      a meaningful, debuggable statement rather than noise chasing noise; and
  (b) two DIFFERENT variants in the same batch never draw from the same
      sub-stream, so a change to variant 12's parameter count never perturbs
      variant 13's random draws (a classic footgun with a single shared
      global RNG advanced in a loop).
No dependency on numpy's Generator/PCG64 or any other heavyweight RNG: the
generator here is a plain linear congruential generator (LCG), because this
file has no other numerical dependency and does not want to acquire one just
to jitter a handful of scenario parameters. It is not cryptographic and is
not supposed to be; it is supposed to be deterministic, portable, and legible.

SCORING IS SIMULATED, NOT REAL
--------------------------------
`run_scoring_pass` in this file does NOT invoke the real Kalman filter, the
real Hungarian solve, or the real JTMS belief revision -- those are numerical
kernels in `tracker/kalman.py`, `tracker/assoc.py`, and the JTMS retraction
layer noted as not-yet-built in `eval.jac`'s `JTMS_MSG`. Wiring a batch
harness to the real engine is future work (see `_NOT_WIRED_MSG` below); until
then, this file's scoring pass is a stand-in that derives a PLAUSIBLE outcome
from the variant's own parameters via closed-form heuristics that mirror the
real failure modes (tighter gate -> more false alarms; longer dark window ->
lower reassociation confidence; higher density -> more id switches), so the
aggregate statistics this harness produces are shaped like what the real
engine's would be, even though no frame of AIS data is actually replayed.
Anyone wiring this up for real need only replace `run_scoring_pass`'s body;
every other function in this file (generation, aggregation, reporting)
already consumes just the `RunOutcome` node shape.

THRESHOLDS AND THE REAL CONSTANTS
-----------------------------------
Two thresholds here are not invented for this file: `CHI2_GATE_2DOF_99` and
`CHI2_95_2DOF` are the real chi-squared critical values used elsewhere in
Sentinel-ISR's association gating (99th and 95th percentile of the chi-square
distribution with 2 degrees of freedom, for a 2-D [lat, lon] or [x, y]
innovation vector). They are reproduced here, not imported, because this file
has no import dependency on the tracker package at all (same reasoning as
`hypothesis.jac`'s "no imports" stance) -- but a stress harness that talks
about gate width without the actual gate thresholds nearby would be checking
against nothing. Every other threshold below (`ID_SWITCH_RATE_MAX`,
`REASSOC_SUCCESS_MIN`, `FALSE_ALARM_RATE_MAX`, `WORST_CASE_OFFSET_M_MAX`) is
this harness's own configurable pass/fail bar, tunable at the top of the file
exactly like `hypothesis.jac`'s NSCAN_DEPTH / WEIGHT_FLOOR / MAX_LIVE.

REPORT SHAPE
-------------
The pass/fail report this file prints mirrors `eval.jac`'s `format_report`
deliberately: a per-batch header, one line per aggregate metric with a
PASS/FAIL/MARGINAL tag, then a single TOTAL line with an overall verdict. Two
tools that read alike are cheaper to maintain and cheaper for a human to
context-switch between.

DRIVING IT FROM PYTHON (future; not required for this file to exist)
----------------------------------------------------------------------
`import jaclang` installs the meta importer, then `import stress` after this
directory is on `sys.path`. Call `run_stress_batch(seed, n_variants, ...)`,
then read back `batch_summary(batch)` for the aggregate dict, or
`format_stress_report(batch)` for the printable form. None of this is called
by the live server today; this module is grown, not wired.
"""

# ---------------------------------------------------------------------------
# Real association-gating constants, reproduced (not imported) so the harness
# has the actual gate thresholds to compare generated gate widths against.
# See the module docstring, "THRESHOLDS AND THE REAL CONSTANTS".
# ---------------------------------------------------------------------------

glob CHI2_GATE_2DOF_99: float = 9.21034;   # 99th pct, chi-square, 2 dof -- the gate
glob CHI2_95_2DOF: float = 5.991;          # 95th pct, chi-square, 2 dof -- tighter gate

# ---------------------------------------------------------------------------
# This harness's own pass/fail bar. Deliberately separate from the two
# constants above: those are physics (the chi-square distribution does not
# care about this harness's opinions), these are engineering targets and are
# expected to move as the tracker improves.
# ---------------------------------------------------------------------------

glob ID_SWITCH_RATE_MAX: float = 0.08;        # at most 8% of variants may id-switch
glob REASSOC_SUCCESS_MIN: float = 0.85;       # at least 85% of dark variants reassoc
glob FALSE_ALARM_RATE_MAX: float = 0.05;      # at most 5% spurious geofence alerts
glob WORST_CASE_OFFSET_M_MAX: float = 650.0;  # single worst predicted/true offset

# Marginal band: a metric that passes but sits within this fraction of its
# threshold is flagged MARGINAL in the report, exactly as `eval.jac`'s
# MARGIN_WARN_FRAC flags a passing-but-thin geometric margin.
glob MARGIN_WARN_FRAC: float = 0.10;

# ---------------------------------------------------------------------------
# Generation axis ranges. A "grid + jitter" design: the three axes are swept
# on a coarse grid so the batch has deliberate coverage of corners (sparse
# traffic / slow / short dark window vs. dense / fast / long dark window),
# and the seeded LCG jitters within each grid cell so two variants in the
# same cell are not bit-identical.
# ---------------------------------------------------------------------------

glob DENSITY_GRID: tuple = (2, 4, 8, 16, 32);            # simultaneous vessel count
glob CLOSING_SPEED_GRID_KN: tuple = (5.0, 12.0, 22.0, 35.0);  # knots, closing speed
glob DARK_WINDOW_GRID_S: tuple = (30.0, 120.0, 300.0, 900.0, 1800.0);  # AIS-off seconds

glob JITTER_DENSITY_FRAC: float = 0.0;      # density is discrete headcount, no jitter
glob JITTER_SPEED_FRAC: float = 0.15;        # +/-15% of grid speed
glob JITTER_DARK_WINDOW_FRAC: float = 0.20;  # +/-20% of grid dark-window duration

glob _NOT_WIRED_MSG: str = "scoring pass is a closed-form stand-in, not the live tracker (see module docstring)";


# ---------------------------------------------------------------------------
# Seeded, splittable LCG. Parameters are the classic Numerical-Recipes
# constants; nothing about this needs to be cryptographically strong, only
# deterministic and cheap.
# ---------------------------------------------------------------------------

glob _LCG_A: int = 1664525;
glob _LCG_C: int = 1013904223;
glob _LCG_M: int = 4294967296;  # 2**32


def _lcg_next(state: int) -> int {
    """One LCG step. Pure function of state -> state; no hidden global draw
    counter, so replaying the same state always replays the same stream.""";
    return (_LCG_A * state + _LCG_C) % _LCG_M;
}


def _split_seed(seed: int, index: int) -> int {
    """Derive an independent sub-stream seed for variant `index` of a batch
    rooted at `seed`, so no two variants in the same batch ever draw from the
    same LCG stream (see module docstring, SEEDING AND REPRODUCIBILITY).

    The mixing step below is intentionally NOT just `seed + index`: adjacent
    indices would then start one LCG step apart, and an LCG's short-range
    output is not independent enough step-to-step for that to be safe. One
    extra multiply-and-fold (Weyl-sequence style, odd multiplier so it is a
    bijection mod 2**32) spreads adjacent indices far apart in state space
    before the per-variant LCG stream even starts.
    """;
    mixed = (seed * 2654435761 + index * 40503 + 1) % _LCG_M;
    return _lcg_next(mixed);
}


def _unit_float(state: int) -> tuple {
    """Advance the LCG once, return (next_state, value in [0.0, 1.0)).""";
    nxt = _lcg_next(state);
    return (nxt, float(nxt) / float(_LCG_M));
}


def _jittered(state: int, centre: float, frac: float) -> tuple {
    """Advance the LCG once, return (next_state, centre jittered by +/-frac).

    frac == 0.0 short-circuits to (state, centre) so a caller can pass a
    discrete axis (vessel density) through the same call shape as a
    continuous one (speed, dark-window duration) without spending an LCG
    draw on a jitter that would immediately be rounded away.
    """;
    if frac <= 0.0 {
        return (state, centre);
    }
    pair = _unit_float(state);
    nxt = pair[0];
    u = pair[1];
    offset = (u * 2.0 - 1.0) * frac * centre;
    return (nxt, centre + offset);
}


def _pick_grid(state: int, grid: tuple) -> tuple {
    """Advance the LCG once, return (next_state, one entry of grid) chosen
    uniformly. Used instead of `random.choice` so the whole file stays on one
    seeded generator rather than mixing an unseeded stdlib RNG in for this one
    call.""";
    pair = _unit_float(state);
    nxt = pair[0];
    u = pair[1];
    idx = int(u * len(grid));
    if idx >= len(grid) {
        idx = len(grid) - 1;
    }
    return (nxt, grid[idx]);
}


# ---------------------------------------------------------------------------
# Graph shape
# ---------------------------------------------------------------------------

node ScenarioVariant {
    has variant_id: str;
    has seed: int = 0;
    has vessel_density: int = 2;
    has closing_speed_kn: float = 10.0;
    has dark_window_s: float = 60.0;
    #: derived at generation time, cached rather than recomputed on every read
    has gate_chi2: float = CHI2_GATE_2DOF_99;
    #: which grid corner this variant nominally belongs to, for readable
    #: reporting ("dense/fast/long" etc.) -- cosmetic, never read for logic
    has corner_label: str = "";
}


node RunOutcome {
    has id_switches: int = 0;
    has reassoc_attempted: bool = False;
    has reassoc_succeeded: bool = False;
    has false_alarms: int = 0;
    has predicted_vs_true_offset_m: float = 0.0;
    has scoring_note: str = _NOT_WIRED_MSG;
}


node StressBatch {
    has batch_id: str;
    has seed: int = 0;
    has n_variants: int = 0;
    has created_note: str = "";
}


edge Generated {}   #: StressBatch -> ScenarioVariant
edge Scored {}       #: ScenarioVariant -> RunOutcome


# ---------------------------------------------------------------------------
# Run state. Mirrors hypothesis.jac's ROOTS/LOG pattern: mutated in place so
# no global-rebinding syntax is needed, cleared explicitly by the entry point
# rather than relying on process exit, so repeated calls in one process (e.g.
# a pytest session) never see a prior run's variants bleed into a new batch.
# ---------------------------------------------------------------------------

glob BATCHES: list = [];   #: every StressBatch node created this process
glob LOG: list = [];        #: ASCII, single-choke-point log lines


def emit(line: str) -> None {
    """Single choke point for every stress-harness log line, ASCII only, so a
    test can read LOG back and the demo prints cleanly on a cp1252 console --
    same discipline as hypothesis.jac's emit().""";
    LOG.append(line);
    print(line);
}


def reset_stress_state() -> None {
    """Clear the process-local batch registry and log. Does not touch the
    persistent `root` graph -- ScenarioVariant/RunOutcome nodes already
    anchored there stay reachable for anyone walking from root directly, but
    a fresh call to run_stress_batch() builds a fresh BATCHES list so repeated
    invocations in one process do not accumulate unboundedly.""";
    BATCHES.clear();
    LOG.clear();
}


# ---------------------------------------------------------------------------
# Generation
# ---------------------------------------------------------------------------

def _corner_label(density: int, speed_kn: float, dark_s: float) -> str {
    """Human-readable corner tag for report rows. Thresholds are simply the
    midpoints of each grid's min/max, so labels are consistent even as the
    grids themselves are retuned.""";
    density_lo = DENSITY_GRID[0];
    density_hi = DENSITY_GRID[len(DENSITY_GRID) - 1];
    speed_lo = CLOSING_SPEED_GRID_KN[0];
    speed_hi = CLOSING_SPEED_GRID_KN[len(CLOSING_SPEED_GRID_KN) - 1];
    dark_lo = DARK_WINDOW_GRID_S[0];
    dark_hi = DARK_WINDOW_GRID_S[len(DARK_WINDOW_GRID_S) - 1];

    density_mid = (density_lo + density_hi) / 2.0;
    speed_mid = (speed_lo + speed_hi) / 2.0;
    dark_mid = (dark_lo + dark_hi) / 2.0;

    if density >= density_mid {
        density_word = "dense";
    } else {
        density_word = "sparse";
    }
    if speed_kn >= speed_mid {
        speed_word = "fast";
    } else {
        speed_word = "slow";
    }
    if dark_s >= dark_mid {
        dark_word = "long-dark";
    } else {
        dark_word = "short-dark";
    }
    return density_word + "/" + speed_word + "/" + dark_word;
}


def _variant_gate(closing_speed_kn: float, dark_window_s: float) -> float {
    """Plausible per-variant gate chi-square: the reassociation search after a
    LONG dark window has to accept a wider innovation before it can even
    consider a candidate a match (the predicted-position covariance has grown
    with the unobserved time), so this stand-in widens the gate from the
    tight 95% threshold towards the looser 99% one as dark_window_s grows,
    and narrows it slightly as closing speed grows (a fast closing geometry
    leaves less room before two tracks are within each other's gates whether
    the analyst likes it or not, so the effective operating gate is kept
    tighter to compensate). This is a heuristic surface for stress-testing
    report shape, not a re-derivation of the real covariance propagation in
    tracker/kalman.py.
    """;
    dark_lo = DARK_WINDOW_GRID_S[0];
    dark_hi = DARK_WINDOW_GRID_S[len(DARK_WINDOW_GRID_S) - 1];
    span = dark_hi - dark_lo;
    if span <= 0.0 {
        frac = 0.0;
    } else {
        frac = (dark_window_s - dark_lo) / span;
    }
    if frac < 0.0 {
        frac = 0.0;
    }
    if frac > 1.0 {
        frac = 1.0;
    }
    base = CHI2_95_2DOF + frac * (CHI2_GATE_2DOF_99 - CHI2_95_2DOF);

    speed_lo = CLOSING_SPEED_GRID_KN[0];
    speed_hi = CLOSING_SPEED_GRID_KN[len(CLOSING_SPEED_GRID_KN) - 1];
    speed_span = speed_hi - speed_lo;
    if speed_span <= 0.0 {
        speed_frac = 0.0;
    } else {
        speed_frac = (closing_speed_kn - speed_lo) / speed_span;
    }
    if speed_frac < 0.0 {
        speed_frac = 0.0;
    }
    if speed_frac > 1.0 {
        speed_frac = 1.0;
    }
    tightening = speed_frac * 0.35 * (CHI2_GATE_2DOF_99 - CHI2_95_2DOF);
    return base - tightening;
}


def generate_variant(batch: StressBatch, index: int) -> ScenarioVariant {
    """Build one seeded ScenarioVariant, attach it under `batch`, and return
    it. Deterministic in (batch.seed, index): see _split_seed for why two
    indices in the same batch never share a sub-stream.""";
    state = _split_seed(batch.seed, index);

    pair_density = _pick_grid(state, DENSITY_GRID);
    state = pair_density[0];
    density_centre = pair_density[1];
    pair_density_j = _jittered(state, float(density_centre), JITTER_DENSITY_FRAC);
    state = pair_density_j[0];
    density = int(round(pair_density_j[1]));
    if density < 1 {
        density = 1;
    }

    pair_speed = _pick_grid(state, CLOSING_SPEED_GRID_KN);
    state = pair_speed[0];
    speed_centre = pair_speed[1];
    pair_speed_j = _jittered(state, speed_centre, JITTER_SPEED_FRAC);
    state = pair_speed_j[0];
    speed_kn = pair_speed_j[1];
    if speed_kn < 0.1 {
        speed_kn = 0.1;
    }

    pair_dark = _pick_grid(state, DARK_WINDOW_GRID_S);
    state = pair_dark[0];
    dark_centre = pair_dark[1];
    pair_dark_j = _jittered(state, dark_centre, JITTER_DARK_WINDOW_FRAC);
    state = pair_dark_j[0];
    dark_window_s = pair_dark_j[1];
    if dark_window_s < 1.0 {
        dark_window_s = 1.0;
    }

    gate = _variant_gate(speed_kn, dark_window_s);
    label = _corner_label(density, speed_kn, dark_window_s);

    variant_id = batch.batch_id + "-v" + _pad4(index);
    variant = ScenarioVariant(
        variant_id=variant_id,
        seed=state,
        vessel_density=density,
        closing_speed_kn=speed_kn,
        dark_window_s=dark_window_s,
        gate_chi2=gate,
        corner_label=label
    );
    batch +>:Generated:+> variant;
    return variant;
}


def _pad4(i: int) -> str {
    """Zero-pad to 4 digits (comfortably covers batches up to 9999 variants,
    matching hypothesis.jac's pad2 in spirit for a wider count).""";
    s = str(i);
    while len(s) < 4 {
        s = "0" + s;
    }
    return s;
}


def generate_batch(seed: int, n_variants: int, batch_id: str = "") -> StressBatch {
    """Create a StressBatch and populate it with `n_variants` seeded
    ScenarioVariant children. Returns the batch; variants are reachable from
    it via Generated edges, not returned directly, because every downstream
    consumer (scoring, aggregation, reporting) walks the batch rather than
    holding a list.""";
    if not batch_id {
        batch_id = "batch-" + str(seed);
    }
    batch = StressBatch(batch_id=batch_id, seed=seed, n_variants=n_variants);
    root ++> batch;
    BATCHES.append(batch);

    i = 0;
    while i < n_variants {
        generate_variant(batch, i);
        i += 1;
    }
    emit("[stress] generated " + str(n_variants) + " variant(s) for " + batch_id
         + " (seed=" + str(seed) + ")");
    return batch;
}


# ---------------------------------------------------------------------------
# Traversal helpers -- walking a batch's children, mirroring hypothesis.jac's
# LiveLeaves / BranchRoot walker pattern.
# ---------------------------------------------------------------------------

walker BatchVariants {
    """Collect every ScenarioVariant generated under the spawn batch."""
    has found: list = [];

    can gather with StressBatch entry {
        visit [->:Generated:->];
    }

    can collect with ScenarioVariant entry {
        self.found.append(here);
    }
}


walker VariantOutcome {
    """Collect the RunOutcome (if any) scored for the spawn variant."""
    has found: any = None;

    can gather with ScenarioVariant entry {
        visit [->:Scored:->];
    }

    can collect with RunOutcome entry {
        self.found = here;
    }
}


def batch_variants(batch: StressBatch) -> list {
    """Every ScenarioVariant attached to `batch`, in generation order (the
    walker visits Generated edges in the order they were added, and edges are
    added in increasing index by generate_batch)."""
    w = batch spawn BatchVariants();
    return w.found;
}


def variant_outcome(variant: ScenarioVariant) -> any {
    """The RunOutcome scored for `variant`, or None if it has not been scored
    yet."""
    w = variant spawn VariantOutcome();
    return w.found;
}


# ---------------------------------------------------------------------------
# Scoring pass -- see module docstring, "SCORING IS SIMULATED, NOT REAL".
# ---------------------------------------------------------------------------

def _expected_id_switches(variant: ScenarioVariant) -> float {
    """Closed-form stand-in for expected id-switch count: grows with vessel
    density (more simultaneous crossing opportunities) and with closing
    speed (less time inside the gate to disambiguate before hypotheses would
    otherwise have separated), consistent with the reasoning that motivated
    NSCAN_DEPTH in hypothesis.jac -- a fast crossing eats into the deferred-
    decision budget before enough evidence accumulates.
    """;
    density_term = (float(variant.vessel_density) - 1.0) * 0.015;
    speed_term = (variant.closing_speed_kn / CLOSING_SPEED_GRID_KN[len(CLOSING_SPEED_GRID_KN) - 1]) * 0.12;
    return density_term + speed_term;
}


def _reassoc_success_probability(variant: ScenarioVariant) -> float {
    """Closed-form stand-in for probability of successful dark-vessel
    reassociation: decays as the dark window grows (predicted covariance
    grows with unobserved time, so the true contact drifts towards the edge
    of, then outside, the gate), and decays further as vessel density grows
    (more candidate contacts competing for the same gated region, so a
    correct match is more likely to lose a Mahalanobis-distance tie-break to
    a wrong one). Floors at 0.05 rather than 0.0: a real gate does not go to
    literally zero probability even in the worst modelled case, it just gets
    very small, and a hard zero would make every worst-case batch identical.
    """;
    dark_hi = DARK_WINDOW_GRID_S[len(DARK_WINDOW_GRID_S) - 1];
    dark_frac = variant.dark_window_s / dark_hi;
    if dark_frac > 1.0 {
        dark_frac = 1.0;
    }
    decay = 1.0 - 0.55 * dark_frac;
    density_penalty = 1.0 - (float(variant.vessel_density) - 1.0) * 0.01;
    if density_penalty < 0.3 {
        density_penalty = 0.3;
    }
    p = decay * density_penalty;
    if p < 0.05 {
        p = 0.05;
    }
    if p > 0.99 {
        p = 0.99;
    }
    return p;
}


def _expected_false_alarm_rate(variant: ScenarioVariant) -> float {
    """Closed-form stand-in for spurious geofence-alert rate: a TIGHTER gate
    (closer to CHI2_95_2DOF than CHI2_GATE_2DOF_99) is more trigger-happy,
    because it accepts a smaller innovation as 'still inside the fence
    boundary uncertainty' before flagging, so this stand-in scales inversely
    with how far the variant's own gate sits above the 95% threshold.""";
    span = CHI2_GATE_2DOF_99 - CHI2_95_2DOF;
    if span <= 0.0 {
        return 0.02;
    }
    looseness = (variant.gate_chi2 - CHI2_95_2DOF) / span;
    if looseness < 0.0 {
        looseness = 0.0;
    }
    if looseness > 1.0 {
        looseness = 1.0;
    }
    # Looser gate -> fewer spurious alarms (fewer borderline innovations get
    # rejected outward into "must be a new/foreign contact").
    return 0.03 + (1.0 - looseness) * 0.05;
}


def _worst_case_offset_m(variant: ScenarioVariant, state: int) -> tuple {
    """Closed-form stand-in for predicted-vs-true offset at reacquisition, in
    metres. Grows with dark_window_s (more time for the true position to
    diverge from the last predicted one) with a seeded jitter so repeated
    variants at the same grid corner are not bit-identical in this metric
    either. Returns (next_state, offset_m).""";
    base = 40.0 + variant.dark_window_s * 0.55;
    pair = _unit_float(state);
    nxt = pair[0];
    u = pair[1];
    jitter = (u * 2.0 - 1.0) * 0.25 * base;
    return (nxt, base + jitter);
}


def run_scoring_pass(variant: ScenarioVariant) -> RunOutcome {
    """Score one ScenarioVariant and attach the RunOutcome under it via a
    Scored edge. See module docstring, "SCORING IS SIMULATED, NOT REAL": this
    is a closed-form stand-in, not a real replay through tracker/kalman.py
    and tracker/assoc.py. Deterministic in variant.seed, same reproducibility
    contract as generation.
    """;
    state = variant.seed;

    expected_switches = _expected_id_switches(variant);
    pair_sw = _unit_float(state);
    state = pair_sw[0];
    u_sw = pair_sw[1];
    # Poisson-ish via a single uniform draw against the expectation: cheap and
    # deterministic, not intended to be a rigorous Poisson sampler.
    if u_sw < expected_switches {
        id_switches = 1;
    } else {
        id_switches = 0;
    }
    if u_sw < expected_switches * 0.08 {
        # Rare dense/fast corners can produce a second switch.
        id_switches += 1;
    }

    reassoc_attempted = variant.dark_window_s > 0.0;
    p_succeed = _reassoc_success_probability(variant);
    pair_re = _unit_float(state);
    state = pair_re[0];
    u_re = pair_re[1];
    reassoc_succeeded = reassoc_attempted and (u_re < p_succeed);

    fa_rate = _expected_false_alarm_rate(variant);
    pair_fa = _unit_float(state);
    state = pair_fa[0];
    u_fa = pair_fa[1];
    if u_fa < fa_rate {
        false_alarms = 1;
    } else {
        false_alarms = 0;
    }

    offset_pair = _worst_case_offset_m(variant, state);
    state = offset_pair[0];
    offset_m = offset_pair[1];
    if not reassoc_succeeded {
        # A failed reassociation has no meaningful "predicted vs true" pairing
        # to measure -- the tracker never closed the loop -- so the offset
        # metric only carries information on attempts that succeeded.
        offset_m = 0.0;
    }

    outcome = RunOutcome(
        id_switches=id_switches,
        reassoc_attempted=reassoc_attempted,
        reassoc_succeeded=reassoc_succeeded,
        false_alarms=false_alarms,
        predicted_vs_true_offset_m=offset_m
    );
    variant +>:Scored:+> outcome;
    return outcome;
}


def score_batch(batch: StressBatch) -> None {
    """Run the scoring pass over every variant in `batch` that has not
    already been scored. Idempotent: re-running on an already-scored batch
    leaves existing outcomes untouched rather than double-scoring."""
    variants = batch_variants(batch);
    scored_count = 0;
    for variant in variants {
        existing = variant_outcome(variant);
        if existing is not None {
            continue;
        }
        run_scoring_pass(variant);
        scored_count += 1;
    }
    emit("[stress] scored " + str(scored_count) + " variant(s) in " + batch.batch_id);
}


# ---------------------------------------------------------------------------
# Aggregation
# ---------------------------------------------------------------------------

def id_switch_distribution(batch: StressBatch) -> dict {
    """Histogram of id-switch counts across every scored variant in `batch`,
    keyed by switch count as a string (Jac dict keys read back cleanly as
    strings across the Python boundary, matching eval.jac's dict-of-plain-
    values contract)."""
    hist = {};
    for variant in batch_variants(batch) {
        outcome = variant_outcome(variant);
        if outcome is None {
            continue;
        }
        key = str(outcome.id_switches);
        if key not in hist {
            hist[key] = 0;
        }
        hist[key] = hist[key] + 1;
    }
    return hist;
}


def id_switch_rate(batch: StressBatch) -> float {
    """Fraction of scored variants with at least one id switch."""
    variants = batch_variants(batch);
    total = 0;
    switched = 0;
    for variant in variants {
        outcome = variant_outcome(variant);
        if outcome is None {
            continue;
        }
        total += 1;
        if outcome.id_switches > 0 {
            switched += 1;
        }
    }
    if total == 0 {
        return 0.0;
    }
    return float(switched) / float(total);
}


def reassociation_success_rate(batch: StressBatch) -> float {
    """Fraction of variants that ATTEMPTED reassociation (dark_window_s > 0)
    which SUCCEEDED. Variants with no dark window at all are excluded from
    the denominator: a variant that never went dark cannot inform this rate
    either way."""
    attempted = 0;
    succeeded = 0;
    for variant in batch_variants(batch) {
        outcome = variant_outcome(variant);
        if outcome is None or not outcome.reassoc_attempted {
            continue;
        }
        attempted += 1;
        if outcome.reassoc_succeeded {
            succeeded += 1;
        }
    }
    if attempted == 0 {
        return 1.0;
    }
    return float(succeeded) / float(attempted);
}


def false_alarm_rate(batch: StressBatch) -> float {
    """Fraction of scored variants with at least one spurious geofence
    alert."""
    total = 0;
    alarmed = 0;
    for variant in batch_variants(batch) {
        outcome = variant_outcome(variant);
        if outcome is None {
            continue;
        }
        total += 1;
        if outcome.false_alarms > 0 {
            alarmed += 1;
        }
    }
    if total == 0 {
        return 0.0;
    }
    return float(alarmed) / float(total);
}


def worst_case_offset_m(batch: StressBatch) -> tuple {
    """(offset_m, variant_id) of the single largest predicted-vs-true offset
    among variants whose reassociation succeeded. Returns (0.0, "") if no
    variant in the batch has a scored, successful reassociation -- distinct
    from a genuine zero offset, which callers should treat as "no evidence"
    rather than "perfect"."""
    worst = 0.0;
    worst_id = "";
    any_found = False;
    for variant in batch_variants(batch) {
        outcome = variant_outcome(variant);
        if outcome is None or not outcome.reassoc_succeeded {
            continue;
        }
        any_found = True;
        if outcome.predicted_vs_true_offset_m > worst {
            worst = outcome.predicted_vs_true_offset_m;
            worst_id = variant.variant_id;
        }
    }
    if not any_found {
        return (0.0, "");
    }
    return (worst, worst_id);
}


def worst_corners(batch: StressBatch, top_n: int = 3) -> list {
    """The `top_n` variants with the largest predicted-vs-true offset among
    successfully-reassociated variants, as (variant_id, corner_label,
    offset_m) tuples, worst first. Explicit selection loop rather than
    sorted(key=...) with a lambda, for the same reproducible-tie-break reason
    hypothesis.jac's heaviest()/lightest() avoid sorted(): ties broken on
    variant_id keep the ordering stable run to run.
    """;
    rows = [];
    for variant in batch_variants(batch) {
        outcome = variant_outcome(variant);
        if outcome is None or not outcome.reassoc_succeeded {
            continue;
        }
        rows.append((outcome.predicted_vs_true_offset_m, variant.variant_id, variant.corner_label));
    }
    picked = [];
    remaining = list(rows);
    while len(picked) < top_n and len(remaining) > 0 {
        best = remaining[0];
        for row in remaining {
            if row[0] > best[0] or (row[0] == best[0] and row[1] < best[1]) {
                best = row;
            }
        }
        picked.append(best);
        remaining.remove(best);
    }
    out = [];
    for row in picked {
        out.append((row[1], row[2], row[0]));
    }
    return out;
}


def batch_summary(batch: StressBatch) -> dict {
    """The full aggregate-statistics dict for `batch`: everything
    format_stress_report needs, plain Python types throughout so a caller on
    the Python side of the boundary (or json.dumps) never has to know a Jac
    node touched this data."""
    worst_pair = worst_case_offset_m(batch);
    corners = worst_corners(batch, 3);
    corner_rows = [];
    for row in corners {
        corner_rows.append({"variant_id": row[0], "corner": row[1], "offset_m": row[2]});
    }
    return {
        "batch_id": batch.batch_id,
        "seed": batch.seed,
        "n_variants": len(batch_variants(batch)),
        "id_switch_rate": id_switch_rate(batch),
        "id_switch_distribution": id_switch_distribution(batch),
        "reassociation_success_rate": reassociation_success_rate(batch),
        "false_alarm_rate": false_alarm_rate(batch),
        "worst_case_offset_m": worst_pair[0],
        "worst_case_variant_id": worst_pair[1],
        "worst_corners": corner_rows
    };
}


# ---------------------------------------------------------------------------
# Pass/fail thresholding
# ---------------------------------------------------------------------------

def _metric_verdict(actual: float, limit: float, lower_is_better: bool, margin_frac: float = MARGIN_WARN_FRAC) -> str {
    """"pass" / "marginal" / "fail" for one metric against one threshold.
    `lower_is_better` selects which side of `limit` is the good side (rate
    ceilings vs. success floors both appear in this file's thresholds, so
    both directions are needed)."""
    if lower_is_better {
        if actual > limit {
            return "fail";
        }
        span = limit;
        if span <= 0.0 {
            return "pass";
        }
        if (limit - actual) / span <= margin_frac {
            return "marginal";
        }
        return "pass";
    } else {
        if actual < limit {
            return "fail";
        }
        span = 1.0 - limit;
        if span <= 0.0 {
            return "pass";
        }
        if (actual - limit) / span <= margin_frac {
            return "marginal";
        }
        return "pass";
    }
}


def pass_fail_summary(batch: StressBatch) -> dict {
    """Evaluate `batch_summary(batch)` against this file's configurable
    thresholds and return a report dict shaped like eval.jac's per-check rows
    (key / outcome / detail / expected / actual), one row per aggregate
    metric, plus an overall "ok" flag. Mirrors evaluate_pack_core's shape
    deliberately -- see module docstring, REPORT SHAPE.
    """;
    summary = batch_summary(batch);
    rows = [];

    sw_rate = summary["id_switch_rate"];
    sw_verdict = _metric_verdict(sw_rate, ID_SWITCH_RATE_MAX, True);
    rows.append({
        "key": "id_switch_rate",
        "outcome": sw_verdict,
        "detail": f"{sw_rate:.3f} vs at most {ID_SWITCH_RATE_MAX:.3f} allowed",
        "expected": ID_SWITCH_RATE_MAX,
        "actual": sw_rate
    });

    re_rate = summary["reassociation_success_rate"];
    re_verdict = _metric_verdict(re_rate, REASSOC_SUCCESS_MIN, False);
    rows.append({
        "key": "reassociation_success_rate",
        "outcome": re_verdict,
        "detail": f"{re_rate:.3f} vs at least {REASSOC_SUCCESS_MIN:.3f} required",
        "expected": REASSOC_SUCCESS_MIN,
        "actual": re_rate
    });

    fa_rate = summary["false_alarm_rate"];
    fa_verdict = _metric_verdict(fa_rate, FALSE_ALARM_RATE_MAX, True);
    rows.append({
        "key": "false_alarm_rate",
        "outcome": fa_verdict,
        "detail": f"{fa_rate:.3f} vs at most {FALSE_ALARM_RATE_MAX:.3f} allowed",
        "expected": FALSE_ALARM_RATE_MAX,
        "actual": fa_rate
    });

    worst_m = summary["worst_case_offset_m"];
    worst_verdict = _metric_verdict(worst_m, WORST_CASE_OFFSET_M_MAX, True);
    worst_detail = f"{worst_m:.0f} m vs at most {WORST_CASE_OFFSET_M_MAX:.0f} m allowed";
    if summary["worst_case_variant_id"] {
        worst_detail = worst_detail + " (variant " + summary["worst_case_variant_id"] + ")";
    }
    rows.append({
        "key": "worst_case_offset_m",
        "outcome": worst_verdict,
        "detail": worst_detail,
        "expected": WORST_CASE_OFFSET_M_MAX,
        "actual": worst_m
    });

    any_fail = False;
    for row in rows {
        if row["outcome"] == "fail" {
            any_fail = True;
        }
    }

    return {
        "batch_id": batch.batch_id,
        "rows": rows,
        "ok": not any_fail,
        "summary": summary
    };
}


# ---------------------------------------------------------------------------
# Report formatting -- deliberately shaped like eval.jac's format_report.
# ---------------------------------------------------------------------------

glob _VERDICT_LABEL: dict = {"pass": "PASS", "fail": "FAIL", "marginal": "MARGINAL"};


def format_stress_report(report: dict) -> str {
    """Human-readable pass/fail report for one pass_fail_summary() dict.
    Plain ASCII, no colour codes: this harness is meant to run as easily in a
    CI log as at a terminal, and eval.jac's colour handling is not worth
    duplicating for a report this short."""
    lines = [];
    rule = "=" * 78;
    lines.append("Sentinel-ISR batch stress-test report");
    lines.append(rule);
    lines.append("batch: " + report["batch_id"]);

    summary = report["summary"];
    lines.append(f"variants: {summary['n_variants']}   seed: {summary['seed']}");
    lines.append("");

    for row in report["rows"] {
        label = _VERDICT_LABEL.get(row["outcome"], row["outcome"].upper());
        key_padded = row["key"];
        while len(key_padded) < 28 {
            key_padded = key_padded + " ";
        }
        lines.append("  " + label.ljust(9) + key_padded + row["detail"]);
    }

    lines.append("");
    lines.append("id-switch distribution: " + str(summary["id_switch_distribution"]));
    lines.append("worst corners (offset, descending):");
    for corner in summary["worst_corners"] {
        lines.append(
            "  " + corner["variant_id"] + "  " + corner["corner"]
            + "  " + f"{corner['offset_m']:.0f} m"
        );
    }

    lines.append("");
    lines.append(rule);
    if report["ok"] {
        verdict = "OK";
    } else {
        verdict = "FAILED";
    }
    lines.append("VERDICT: " + verdict);
    return "\n".join(lines);
}


# ---------------------------------------------------------------------------
# Top-level entry point: generate, score, aggregate, report -- one call.
# ---------------------------------------------------------------------------

def run_stress_batch(seed: int, n_variants: int, batch_id: str = "") -> dict {
    """Generate a batch of `n_variants` seeded scenario variants from `seed`,
    run the (simulated) scoring pass over all of them, and return the
    pass_fail_summary() report dict. This is the one function a caller
    (human, test, or future CI job) is expected to reach for; everything
    above exists to make this single call's output legible and reproducible.
    """;
    batch = generate_batch(seed, n_variants, batch_id);
    score_batch(batch);
    report = pass_fail_summary(batch);
    if report["ok"] {
        tag = "OK";
    } else {
        tag = "FAILED";
    }
    emit("[stress] " + batch.batch_id + " -> " + tag);
    return report;
}


def run_stress_sweep(seeds: list, n_variants_per_seed: int) -> list {
    """Run run_stress_batch() once per seed in `seeds`, returning a list of
    report dicts. Useful for a coarse seed sweep -- "does this harness
    disagree with itself across ten different seeds at the same
    n_variants" -- which is itself a cheap sanity check on the generator's
    seeding discipline described in the module docstring, before spending any
    of it on the real tracker.
    """;
    out = [];
    for seed in seeds {
        report = run_stress_batch(seed, n_variants_per_seed);
        out.append(report);
    }
    return out;
}


def sweep_all_ok(reports: list) -> bool {
    """True only if every report in a run_stress_sweep() result passed.""";
    for report in reports {
        if not report["ok"] {
            return False;
        }
    }
    return True;
}


# ---------------------------------------------------------------------------
# Demo: one batch at a middling size, printed as a full report, then a small
# five-seed sweep to show the aggregate-of-aggregates use case.
# `with entry:__main__` so a Python `import stress` does NOT run this -- same
# discipline as hypothesis.jac, and doubly important here since this module
# is explicitly not wired into anything.
# ---------------------------------------------------------------------------

with entry:__main__ {
    print("=== sentinel-isr :: batch scenario stress-test harness (demo) ===");
    print("(" + _NOT_WIRED_MSG + ")");
    print("");

    reset_stress_state();

    report = run_stress_batch(20260726, 64, "demo-batch");
    print("");
    print(format_stress_report(report));

    print("");
    print("=== five-seed sweep, 32 variants each ===");
    sweep_seeds = [1, 2, 3, 4, 5];
    sweep_reports = run_stress_sweep(sweep_seeds, 32);
    i = 0;
    while i < len(sweep_reports) {
        r = sweep_reports[i];
        if r["ok"] {
            tag = "OK";
        } else {
            tag = "FAILED";
        }
        print("  seed " + str(sweep_seeds[i]) + "  " + r["batch_id"] + "  -> " + tag);
        i += 1;
    }
    if sweep_all_ok(sweep_reports) {
        print("sweep verdict: all batches OK");
    } else {
        print("sweep verdict: at least one batch FAILED");
    }

    print("=== ok ===");
}
