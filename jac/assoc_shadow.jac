"""Phase 2, shadow copy: measurement-to-track association, ported to Jac.

WHAT THIS FILE IS
------------------
`tracker/assoc.py` sits on top of `tracker/kalman.py`. Given N predicted
tracks and M position measurements for one frame, it decides which
measurement (if any) updates which track, which tracks were missed, and
which measurements are births -- and it carries each track's lifecycle
(tentative / confirmed / coasting / dead) across frames. It performs no
filter updates itself; the caller drives the filter and the lifecycle off
the assignment it returns.

This file is a parallel re-expression of the same decision procedure in Jac,
in the spirit of `jac/geofence.jac`: a hub node fans out over one Track node
per live target, and a walker plays the role the Python docstring assigns to
"the caller" -- applying the assignment, the misses, and the lifecycle
transitions in one traversal per frame. It is standalone, is not imported by
anything else in the repository, and is not wired into the live web server or
into `tracker/assoc.py` itself. It exists so the same association logic --
gating, the cost derivation, the padded assignment, and the lifecycle state
machine -- has a second, independently readable expression in the language
Sentinel-ISR uses for graph state and traversal rules.

Cost derivation (unchanged from the Python original)
-------------------------------------------------------
Every entry of the assignment matrix is a NEGATIVE LOG-LIKELIHOOD, so that
"assign", "miss" and "birth" are commensurable and a single linear-assignment
solve can trade them off. Under the standard single-target/clutter model with
Gaussian innovation ``nu ~ N(0, S)``, detection probability ``p_D`` and
false-alarm spatial density ``beta_fa`` (m^-2):

    p(assign) = p_D * N(nu; 0, S)
    cost_assign = -log p(assign)
                = 0.5*d2 + 0.5*log det(2*pi*S) - log(p_D)
                = 0.5*d2 + log(2*pi) + 0.5*logdet(S) - log(p_D)

    cost_miss  = -log(1 - p_D)      # the track existed but was not detected
    cost_birth = -log(beta_fa)      # the measurement came from clutter/new target

(``log det(2*pi*S)`` for a 2x2 ``S`` is ``2*log(2*pi) + logdet(S)``, hence the
``log(2*pi) + 0.5*logdet(S)`` term above.)

Why the determinant term matters
-----------------------------------
Dropping ``0.5*logdet(S)`` and scoring on ``d2`` alone -- the usual shortcut
-- makes an uncertain track (large ``P``) look BETTER than a confident one,
because inflating ``S`` shrinks every ``d2`` it produces. A coasting track
with a covariance the size of a harbour would then hoover up measurements
belonging to well-converged neighbours. The determinant term charges a track
for its own uncertainty and restores the correct competition. It is also what
makes ``cost_assign`` a true probability density, so comparing it against
``cost_birth`` (also a density, m^-2) is dimensionally meaningful: both are
"log per square metre", and the units cancel in the comparison.

Deviation from spec: BIG instead of +inf
--------------------------------------------
Gated-out pairs are nominally ``+inf``. This module, like the Python
original, uses a finite

    BIG = cost_miss + cost_birth + 1.0

instead. Taking a miss for the track AND a birth for the measurement is
always available in the padded matrix and always costs strictly less than
one BIG entry, so no optimal solution can ever contain a BIG entry --
behaviour is identical to ``+inf`` without letting an actual infinity enter
the assignment solve's arithmetic (an unrestricted Hungarian implementation
subtracting row/column minima can produce ``inf - inf``, which is a real
hazard). Decoded assignments are still re-checked against the gate before
being returned, so a gated-out pair can never reach the final result even if
the padded solve behaved unexpectedly.

Identity holdout
-------------------
``Track.truth_id`` (MMSI / scenario truth) is carried for SCORING ONLY and is
never read anywhere in the association path. Association depends solely on
geometry and covariance. Scrambling every ``truth_id`` must leave the
returned assignments byte-identical -- the same invariant the Python
original states and tests for.

Numerics
---------
The Python original batches gating into two LAPACK calls (one broadcast
``np.linalg.solve``, one broadcast ``np.linalg.slogdet``) so a 40x40 frame
costs one dispatch rather than 1600. Jac has no bound numpy layer at this
level, so ``build_cost_matrix`` below is a straightforward nested loop over
tracks and measurements, using the exact closed-form 2x2 solve/determinant
that `jac/dark_shadow.jac` also uses -- the two files duplicate those few
helper functions rather than sharing an import, precisely because neither is
meant to depend on the other; each is a standalone, self-contained shadow of
its Python counterpart. The loop computes the identical NLL a batched numpy
call would, just with LAPACK's broadcast replaced by an explicit ``for``.

Hungarian solve
------------------
``associate_global`` below implements the Kuhn-Munkres (Hungarian) algorithm
directly, rather than importing ``scipy.optimize.linear_sum_assignment`` --
the assignment step is squarely "logic", not a numerical kernel that needs a
LAPACK-grade implementation, and re-deriving it here keeps this file capable
of being read start to finish without leaving the language. It is the
textbook O(n^3) primal-dual algorithm on a square cost matrix, operating on
the padded (N+M)x(N+M) matrix exactly as the Python original does.
"""

import math;

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# Chi-squared 99th percentile, 2 degrees of freedom: the gate admits 99% of
# correct associations, so a miss is far more likely to be a real miss than a
# gating artefact.
glob CHI2_GATE_2DOF_99: float = 9.21034;

glob _LOG_2PI: float = math.log(2.0 * math.pi);

# Run state for the graph-driven lifecycle path below. Mutated in place,
# never rebound, matching geofence.jac's discipline for EVENTS / HUB.
glob HUB: list = [];       # [Hub] for the current run
glob FRAME_NO: list = [0]; # frame counter, boxed so it can be mutated


# ---------------------------------------------------------------------------
# 2x2 linear algebra, duplicated from dark_shadow.jac on purpose: this file is
# meant to stand alone, and every matrix here is exactly 2x2 (a position
# covariance plus a measurement covariance), so these closed forms are exact,
# not an approximation of what a general linear-algebra library would give.
# ---------------------------------------------------------------------------

def mat2_add(A: list, B: list) -> list {
    """Elementwise 2x2 sum -- builds the innovation covariance S = P_pos + R.""";
    return [
        [A[0][0] + B[0][0], A[0][1] + B[0][1]],
        [A[1][0] + B[1][0], A[1][1] + B[1][1]]
    ];
}

def mat2_det(A: list) -> float {
    """Determinant of a 2x2 matrix.""";
    return A[0][0] * A[1][1] - A[0][1] * A[1][0];
}

def mat2_solve(A: list, v: list) -> list {
    """Solve A x = v for a 2x2 A via Cramer's rule -- a genuine solve, never
    an explicit inverse.""";
    det = mat2_det(A);
    x0 = (v[0] * A[1][1] - A[0][1] * v[1]) / det;
    x1 = (A[0][0] * v[1] - v[0] * A[1][0]) / det;
    return [x0, x1];
}

def mat2_slogdet(A: list) -> tuple {
    """Return (sign, log(|det(A)|)). Splitting sign from magnitude is what
    lets the caller detect a non-positive-definite S before trusting the log
    value at all.""";
    d = mat2_det(A);
    if d > 0.0 {
        return (1.0, math.log(d));
    } elif d < 0.0 {
        return (-1.0, math.log(-d));
    } else {
        return (0.0, float('-inf'));
    }
}


# ---------------------------------------------------------------------------
# Association parameters.
# ---------------------------------------------------------------------------

obj AssocParams {
    """Association, gating and lifecycle parameters.

    ``beta_fa`` is the one knob that sets where assignment stops beating
    miss+birth. For a converged track (P_pos = diag(400, 400) m^2) seen by
    radar (R = diag(2500, 2500) m^2) the implicit d^2 cutoff at
    ``beta_fa = 1e-6`` is roughly 12.4, which brackets the 9.21 chi-squared
    gate: the gate binds first (so gating is not decoration) while marginal
    in-gate pairs can still lose to a birth.""";
    has p_detect: float = 0.9;
    has beta_fa: float = 1e-6;
    has gate_chi2: float = CHI2_GATE_2DOF_99;
    has confirm_hits: int = 3;
    has confirm_window: int = 5;
    has coast_after_misses: int = 2;
    has delete_after_misses: int = 10;
    has llr_delete_floor: float = -20.0;
}

glob DEFAULT_PARAMS: AssocParams = AssocParams();


def cost_miss(params: AssocParams = DEFAULT_PARAMS) -> float {
    """Cost of leaving a track unassigned: -log(1 - p_detect).""";
    return -math.log(1.0 - params.p_detect);
}

def cost_birth(params: AssocParams = DEFAULT_PARAMS) -> float {
    """Cost of declaring a measurement a birth/false alarm: -log(beta_fa).""";
    return -math.log(params.beta_fa);
}

def big_cost(params: AssocParams = DEFAULT_PARAMS) -> float {
    """Finite stand-in for +inf on gated-out pairs.

    Strictly greater than miss+birth, which is always available, so it can
    never be selected by an optimal solve. Exposed so a test could assert
    that no returned assignment sits at this value.""";
    return cost_miss(params) + cost_birth(params) + 1.0;
}

def max_assignable_sigma(params: AssocParams = DEFAULT_PARAMS) -> float {
    """Largest isotropic innovation sigma (metres) that can still win an
    assignment.

    Once a track's prediction gets uncertain enough, ``cost_assign`` exceeds
    ``cost_miss + cost_birth`` even at ``d2 = 0``, and the solver will always
    prefer to call the track missed and the measurement a birth -- the track
    can then never be assigned again, no matter how well a later measurement
    lines up.

    Setting ``cost_assign(d2=0) = cost_miss + cost_birth`` for an isotropic
    ``S = s*I`` gives ``log(2*pi) + log(s) - log(p_D) = cost_miss + cost_birth``,
    hence the ``sqrt(s)`` below.

    THIS IS THE BINDING CONSTRAINT ON DARK-VESSEL RE-ASSOCIATION (see the
    sibling ceiling in `jac/dark_shadow.jac`'s ``sigma_ceiling_for_p90``): a
    vessel that goes dark grows its covariance without bound, so ``beta_fa``
    -- not the gate -- sets how long it can stay re-acquirable through THIS
    module. A longer re-acquisition window is what Phase 4 exists to provide,
    precisely because this ceiling is so tight at the Phase 2 default.""";
    s = math.exp(cost_miss(params) + cost_birth(params)
                 - _LOG_2PI + math.log(params.p_detect));
    return math.sqrt(s);
}


# ---------------------------------------------------------------------------
# Track: one target hypothesis, as a graph node so it can sit under the hub
# the per-frame walker traverses. ``misses`` counts CONSECUTIVE misses and
# resets on any hit; deletion at ``delete_after_misses`` is a TOTAL
# consecutive count, not an extra budget granted after coasting begins -- a
# track that starts missing at frame k coasts at k+2 and dies at k+10, never
# k+12.
# ---------------------------------------------------------------------------

node Track {
    """One target hypothesis: a position/covariance snapshot plus its
    lifecycle bookkeeping.

    Unlike the Python original, this node does not hold a live filter --
    ``pos`` / ``pos_cov`` are set by whatever predict step runs before a
    frame, and this node's job is purely the association and lifecycle
    arithmetic on top of that snapshot.""";
    has track_id: int;
    has pos: list = [0.0, 0.0];
    has pos_cov: list = [[0.0, 0.0], [0.0, 0.0]];
    has status: str = "tentative";
    has hits: int = 0;
    has misses: int = 0;
    has hit_history: list = [];       # bounded to confirm_window by callers
    has llr: float = 0.0;
    has truth_id: str = "";           # scoring only; never read for association
    has p_detect: float = 0.9;
    has beta_fa: float = 1e-6;
    has confirm_hits: int = 3;
    has confirm_window: int = 5;
    has coast_after_misses: int = 2;
    has delete_after_misses: int = 10;
    has llr_delete_floor: float = -20.0;

    def register_hit(d2: float, logdet_S: float) -> None {
        """Record an association with squared Mahalanobis d2 and logdet_S.

        Uses this track's OWN thresholds rather than any shared default --
        defaulting to a global params object instead would silently apply
        stock thresholds to a track constructed with tuned ones, which
        matters once a hypothesis branch spawns tracks in bulk with their
        own tuning.""";
        if self.status == "dead" {
            return;
        }

        self.hits += 1;
        self.misses = 0;
        self.hit_history.append(True);
        if len(self.hit_history) > self.confirm_window {
            self.hit_history.pop(0);
        }

        # llr -= (cost_assign - cost_birth): the evidence that this
        # measurement came from the track rather than from clutter. A tight,
        # likely association raises the score; a marginal one can still
        # lower it.
        self.llr += (math.log(self.p_detect / self.beta_fa)
                     - 0.5 * d2 - _LOG_2PI - 0.5 * logdet_S);

        if self.status == "coasting" {
            # A coasting track is already confirmed history; one hit
            # reinstates it.
            self.status = "confirmed";
        } elif self.status == "tentative" {
            hit_count = 0;
            for h in self.hit_history {
                if h {
                    hit_count += 1;
                }
            }
            if hit_count >= self.confirm_hits {
                self.status = "confirmed";
            }
        }

        self.apply_llr_floor();
    }

    def register_miss() -> None {
        """Record that no measurement was associated to this track this
        frame.""";
        if self.status == "dead" {
            return;
        }

        self.misses += 1;
        self.hit_history.append(False);
        if len(self.hit_history) > self.confirm_window {
            self.hit_history.pop(0);
        }
        self.llr += math.log(1.0 - self.p_detect);

        if self.misses >= self.delete_after_misses {
            self.status = "dead";
        } elif self.status == "confirmed" and self.misses >= self.coast_after_misses {
            self.status = "coasting";
        }

        self.apply_llr_floor();
    }

    def apply_llr_floor() -> None {
        """Score-based deletion, independent of the miss counter.

        Either path can kill a track on its own; whichever fires first wins.
        This catches the track that keeps getting fed marginal, barely-in-
        gate measurements -- its miss counter never climbs, but its score
        bleeds out.""";
        if self.llr < self.llr_delete_floor {
            self.status = "dead";
        }
    }

    def is_alive() -> bool {
        """True while the track has not been deleted.""";
        return self.status != "dead";
    }
}

edge Tracking {}


node Hub {
    """Fan-out anchor for one run's Track population, mirroring
    geofence.jac's Watchtower.""";
    has label: str = "assoc_shadow";
}


def hub() -> Hub {
    """The current run's hub, created on first use.""";
    if len(HUB) == 0 {
        h = Hub();
        root ++> h;
        HUB.append(h);
    }
    return HUB[0];
}

def reset() -> None {
    """Start a fresh run: new hub, frame counter back to zero.

    Essential, not cosmetic -- ``root`` persists across ``jac run``
    invocations, so without this a second run in the same process would
    fan out over the previous run's tracks too.""";
    HUB.clear();
    FRAME_NO[0] = 0;
    h = Hub();
    root ++> h;
    HUB.append(h);
}

def spawn_track(track_id: int, pos: list, pos_cov: list,
                params: AssocParams = DEFAULT_PARAMS) -> Track {
    """Attach a new Track node to the current hub.""";
    h = hub();
    tr = Track(track_id=track_id, pos=pos, pos_cov=pos_cov,
              p_detect=params.p_detect, beta_fa=params.beta_fa,
              confirm_hits=params.confirm_hits,
              confirm_window=params.confirm_window,
              coast_after_misses=params.coast_after_misses,
              delete_after_misses=params.delete_after_misses,
              llr_delete_floor=params.llr_delete_floor);
    h +>:Tracking:+> tr;
    return tr;
}

def live_tracks() -> list {
    """Every Track node under the current hub, alive or dead alike -- the
    caller decides what to do with a dead one (typically: drop it from the
    next frame's population).""";
    h = hub();
    out = [];
    for tr in [h ->:Tracking:->] {
        out.append(tr);
    }
    return out;
}


# ---------------------------------------------------------------------------
# Cost matrix.
# ---------------------------------------------------------------------------

obj AssocResult {
    """Outcome of one association frame. Indices are positional into the
    ``tracks`` / ``zs`` lists passed to the solver.""";
    has assignments: list = [];        # list of [track_index, meas_index]
    has unassigned_tracks: list = [];
    has unassigned_meas: list = [];
    has cost: list = [];               # (N, M) as list-of-lists, BIG where gated out
    has gate: list = [];               # (N, M) bool as list-of-lists
    has d2: list = [];                 # (N, M) as list-of-lists
}

def _empty_result(n: int, m: int) -> AssocResult {
    """Result for a frame with nothing to solve (N == 0 or M == 0).""";
    unassigned_t = [];
    i = 0;
    while i < n {
        unassigned_t.append(i);
        i += 1;
    }
    unassigned_m = [];
    j = 0;
    while j < m {
        unassigned_m.append(j);
        j += 1;
    }
    return AssocResult(
        assignments=[], unassigned_tracks=unassigned_t,
        unassigned_meas=unassigned_m, cost=[], gate=[], d2=[]
    );
}

def build_cost_matrix(
    tracks: list,
    zs: list,
    Rs: list,
    params: AssocParams = DEFAULT_PARAMS
) -> tuple {
    """Build the (N, M) NLL cost matrix, gate mask, and squared Mahalanobis
    distances, as three list-of-lists.

    ``Rs`` may be a single shared 2x2 covariance (applied to every
    measurement) or one 2x2 covariance per measurement, matching the
    Python original's ``_coerce_inputs`` broadcasting rule. The Python
    version does this in two broadcast LAPACK calls; here it is one pass of
    nested loops computing the exact same closed-form 2x2 solve and
    determinant per (track, measurement) pair -- O(N*M) either way, just
    without a vectorised dispatch underneath.""";
    n = len(tracks);
    m = len(zs);

    if n == 0 or m == 0 {
        return ([], [], []);
    }

    shared_R = len(Rs) == 2 and len(Rs[0]) == 2 and (not (len(Rs) > 0 and isinstance(Rs[0][0], list) and len(Rs[0]) > 2));
    # Simpler, unambiguous test: a single shared covariance is passed as
    # [[a,b],[c,d]] (length 2, each row length 2); per-measurement Rs is
    # passed as a list of such 2x2 matrices (length M).
    single_R = len(Rs) == 2;

    cost = [];
    gate = [];
    d2_out = [];

    i = 0;
    while i < n {
        cost_row = [];
        gate_row = [];
        d2_row = [];
        pos = tracks[i].pos;
        P = tracks[i].pos_cov;

        j = 0;
        while j < m {
            if single_R {
                R = Rs;
            } else {
                R = Rs[j];
            }
            S = mat2_add(P, R);
            nu = [zs[j][0] - pos[0], zs[j][1] - pos[1]];

            sign, logdet = mat2_slogdet(S);
            if sign <= 0.0 {
                # Mirrors the Python original's hard failure on a
                # non-positive-definite innovation covariance.
                cost_row.append(big_cost(params));
                gate_row.append(False);
                d2_row.append(float('inf'));
                j += 1;
                continue;
            }

            sol = mat2_solve(S, nu);
            d2 = nu[0] * sol[0] + nu[1] * sol[1];

            c = 0.5 * d2 + _LOG_2PI + 0.5 * logdet - math.log(params.p_detect);
            g = d2 <= params.gate_chi2;
            if not g {
                # Gated-out pairs are unreachable rather than merely
                # expensive.
                c = big_cost(params);
            }

            cost_row.append(c);
            gate_row.append(g);
            d2_row.append(d2);
            j += 1;
        }

        cost.append(cost_row);
        gate.append(gate_row);
        d2_out.append(d2_row);
        i += 1;
    }

    return (cost, gate, d2_out);
}


# ---------------------------------------------------------------------------
# Hungarian (Kuhn-Munkres) assignment on a square, padded cost matrix.
#
# Textbook O(n^3) primal-dual algorithm, following the Jonker-Volgenant-style
# potential/slack bookkeeping. Operates on the SAME (N+M)x(N+M) padded matrix
# the Python original builds for scipy: rows n..n+m-1 are "measurement is a
# birth" and columns m..m+n-1 are "track is missed", with BIG elsewhere in
# those blocks and 0 in the miss/birth padding corner -- exactly mirroring
# `associate_global`'s construction below.
# ---------------------------------------------------------------------------

def _hungarian(cost: list) -> list {
    """Solve a square assignment problem. Returns ``col_for_row``, a list
    where ``col_for_row[r]`` is the column assigned to row ``r``.

    This is the classic O(n^3) Hungarian algorithm using row/column
    potentials (``u``, ``v``) and a shortest-augmenting-path search per row,
    the same structural approach ``scipy.optimize.linear_sum_assignment``
    uses internally. It is re-derived here rather than bound to a library
    because the assignment STEP, unlike the 2x2 solves above, is discrete
    combinatorial logic rather than a numerical kernel -- exactly the kind
    of "rule" this Jac layer is meant to own.""";
    size = len(cost);
    INF = float('inf');

    u = [0.0] * (size + 1);
    v = [0.0] * (size + 1);
    p = [0] * (size + 1);    # p[c] = row assigned to column c (1-indexed cols)
    way = [0] * (size + 1);

    i = 1;
    while i <= size {
        p[0] = i;
        j0 = 0;
        minv = [INF] * (size + 1);
        used = [False] * (size + 1);

        keep_going = True;
        while keep_going {
            used[j0] = True;
            i0 = p[j0];
            delta = INF;
            j1 = -1;

            j = 1;
            while j <= size {
                if not used[j] {
                    cur = cost[i0 - 1][j - 1] - u[i0] - v[j];
                    if cur < minv[j] {
                        minv[j] = cur;
                        way[j] = j0;
                    }
                    if minv[j] < delta {
                        delta = minv[j];
                        j1 = j;
                    }
                }
                j += 1;
            }

            j = 0;
            while j <= size {
                if used[j] {
                    u[p[j]] += delta;
                    v[j] -= delta;
                } else {
                    minv[j] -= delta;
                }
                j += 1;
            }

            j0 = j1;
            keep_going = p[j0] != 0;
        }

        while j0 != 0 {
            j1 = way[j0];
            p[j0] = p[j1];
            j0 = j1;
        }

        i += 1;
    }

    col_for_row = [-1] * size;
    j = 1;
    while j <= size {
        if p[j] != 0 {
            col_for_row[p[j] - 1] = j - 1;
        }
        j += 1;
    }
    return col_for_row;
}


def associate_global(
    tracks: list,
    zs: list,
    Rs: list,
    params: AssocParams = DEFAULT_PARAMS
) -> AssocResult {
    """Globally optimal association by padded Hungarian assignment.

    The (N+M) x (N+M) padded matrix makes "miss" and "birth" first-class
    choices with their own costs, so the solver minimises the total NLL of
    the WHOLE frame interpretation rather than just of the assigned subset
    -- identical in structure to the Python original's use of
    ``scipy.optimize.linear_sum_assignment`` on the same padded shape.""";
    n = len(tracks);
    m = len(zs);
    if n + m == 0 {
        return _empty_result(0, 0);
    }
    if n == 0 or m == 0 {
        return _empty_result(n, m);
    }

    cost, gate, d2 = build_cost_matrix(tracks, zs, Rs, params);

    big = big_cost(params);
    size = n + m;

    full = [];
    r = 0;
    while r < size {
        row = [0.0] * size;
        full.append(row);
        r += 1;
    }

    # Top-left (n, m): real assign costs.
    i = 0;
    while i < n {
        j = 0;
        while j < m {
            full[i][j] = cost[i][j];
            j += 1;
        }
        i += 1;
    }

    # Top-right (n, n): track i misses <-> column m+i. BIG off-diagonal so a
    # track can only be "missed" against its own padding column, never
    # another track's.
    i = 0;
    while i < n {
        j = 0;
        while j < n {
            if i == j {
                full[i][m + j] = cost_miss(params);
            } else {
                full[i][m + j] = big;
            }
            j += 1;
        }
        i += 1;
    }

    # Bottom-left (m, m): measurement j is a birth <-> row n+j. Same
    # diagonal-only structure.
    i = 0;
    while i < m {
        j = 0;
        while j < m {
            if i == j {
                full[n + i][j] = cost_birth(params);
            } else {
                full[n + i][j] = big;
            }
            j += 1;
        }
        i += 1;
    }

    # Bottom-right (m, n): miss-column x birth-row pairings carry no extra
    # cost -- pure padding.
    i = 0;
    while i < m {
        j = 0;
        while j < n {
            full[n + i][m + j] = 0.0;
            j += 1;
        }
        i += 1;
    }

    col_for_row = _hungarian(full);

    assignments = [];
    assigned_tracks = [False] * n;
    assigned_meas = [False] * m;

    r = 0;
    while r < size {
        c = col_for_row[r];
        if r < n and c < m and c >= 0 {
            # Defensive: BIG can never win against miss+birth, so this
            # should be unreachable. Dropping the pair degrades to
            # miss+birth rather than emitting an association the gate
            # rejected.
            if gate[r][c] {
                assignments.append([r, c]);
                assigned_tracks[r] = True;
                assigned_meas[c] = True;
            }
        }
        r += 1;
    }

    unassigned_tracks = [];
    i = 0;
    while i < n {
        if not assigned_tracks[i] {
            unassigned_tracks.append(i);
        }
        i += 1;
    }
    unassigned_meas = [];
    j = 0;
    while j < m {
        if not assigned_meas[j] {
            unassigned_meas.append(j);
        }
        j += 1;
    }

    return AssocResult(
        assignments=assignments,
        unassigned_tracks=unassigned_tracks,
        unassigned_meas=unassigned_meas,
        cost=cost, gate=gate, d2=d2
    );
}


def associate_greedy(
    tracks: list,
    zs: list,
    Rs: list,
    params: AssocParams = DEFAULT_PARAMS
) -> AssocResult {
    """Greedy nearest-in-NLL baseline, drop-in swappable with
    ``associate_global``.

    Deliberately shares the SAME gate and the SAME NLL cost matrix as the
    global solver; the only difference is the strategy (commit best-first,
    locally, without backtracking). An honest comparison isolates the
    assignment algorithm instead of also swapping the distance metric
    underneath it -- exactly the design intent stated in the Python
    original.""";
    n = len(tracks);
    m = len(zs);
    if n == 0 or m == 0 {
        return _empty_result(n, m);
    }

    cost, gate, d2 = build_cost_matrix(tracks, zs, Rs, params);

    candidates = [];
    i = 0;
    while i < n {
        j = 0;
        while j < m {
            if gate[i][j] {
                candidates.append([cost[i][j], i, j]);
            }
            j += 1;
        }
        i += 1;
    }

    # Sort by cost ascending, ties broken by track index then measurement
    # index -- an explicit tie-break keeps the output reproducible when two
    # pairs score identically, which is common with a shared R and
    # symmetric geometry.
    candidates.sort(key=lambda c: can (c[0], c[1], c[2]));

    assigned_tracks = [False] * n;
    assigned_meas = [False] * m;
    assignments = [];

    for cand in candidates {
        c_val = cand[0];
        t = cand[1];
        j = cand[2];
        if assigned_tracks[t] or assigned_meas[j] {
            continue;
        }
        assigned_tracks[t] = True;
        assigned_meas[j] = True;
        assignments.append([t, j]);
    }

    assignments.sort(key=lambda a: can (a[0], a[1]));

    unassigned_tracks = [];
    i = 0;
    while i < n {
        if not assigned_tracks[i] {
            unassigned_tracks.append(i);
        }
        i += 1;
    }
    unassigned_meas = [];
    j = 0;
    while j < m {
        if not assigned_meas[j] {
            unassigned_meas.append(j);
        }
        j += 1;
    }

    return AssocResult(
        assignments=assignments,
        unassigned_tracks=unassigned_tracks,
        unassigned_meas=unassigned_meas,
        cost=cost, gate=gate, d2=d2
    );
}


# ---------------------------------------------------------------------------
# The frame-lifecycle walker -- plays the role the Python docstring assigns
# to "the caller": given an AssocResult already decided by associate_global
# or associate_greedy, apply register_hit / register_miss to every Track
# node under the hub in one traversal. This is the piece that has no
# equivalent object in tracker/assoc.py at all -- there, the caller is
# whatever orchestration code drives the filter; here, it is graph state and
# a walker, which is the whole reason this shadow file exists.
# ---------------------------------------------------------------------------

walker FrameLifecycle {
    """Apply one frame's association result to every Track node under the
    hub.

    ``result`` is an AssocResult from either solver. ``d2_by_track`` /
    ``logdet_by_track`` map track index (position in the ``tracks`` list
    that produced ``result``) to the ``d2`` / ``logdet(S)`` of its assigned
    pair, so that ``register_hit`` gets the same evidence
    ``build_cost_matrix`` already computed rather than re-deriving it.""";
    has result: AssocResult = AssocResult();
    has index_by_id: dict = {};       # track_id -> position in tracks list
    has d2_by_index: dict = {};
    has logdet_by_index: dict = {};

    can dispatch with Hub entry {
        visit [->:Tracking:->];
    }

    can apply with Track entry {
        if here.track_id not in self.index_by_id {
            return;
        }
        idx = self.index_by_id[here.track_id];

        hit = False;
        for pair in self.result.assignments {
            if pair[0] == idx {
                d2 = self.d2_by_index[idx];
                logdet_S = self.logdet_by_index[idx];
                here.register_hit(d2, logdet_S);
                hit = True;
            }
        }
        if not hit {
            here.register_miss();
        }
    }
}


def apply_frame(result: AssocResult, tracks: list, logdet_by_index: dict) -> None {
    """Drive one FrameLifecycle traversal over the current hub.

    ``tracks`` must be the SAME list (same order) passed to whichever
    solver produced ``result``, since ``result.assignments`` indexes
    positionally into it. ``logdet_by_index`` supplies ``logdet(S)`` for
    each assigned track index -- callers that already have ``d2``/``gate``/
    ``cost`` from ``build_cost_matrix`` can derive it directly rather than
    recomputing a solve.""";
    index_by_id = {};
    d2_by_index = {};
    i = 0;
    while i < len(tracks) {
        index_by_id[tracks[i].track_id] = i;
        i += 1;
    }
    for pair in result.assignments {
        d2_by_index[pair[0]] = result.d2[pair[0]][pair[1]];
    }

    h = hub();
    h spawn FrameLifecycle(
        result=result, index_by_id=index_by_id,
        d2_by_index=d2_by_index, logdet_by_index=logdet_by_index
    );
    FRAME_NO[0] = FRAME_NO[0] + 1;
}


# ---------------------------------------------------------------------------
# Demo. `with entry:__main__` so `import assoc_shadow` from a test harness
# does NOT run it -- matching geofence.jac's convention.
# ---------------------------------------------------------------------------

with entry:__main__ {
    print("=== sentinel-isr :: phase 2 shadow :: measurement-to-track association ===");

    print("");
    print("--- max_assignable_sigma across beta_fa ---");
    for beta in [1e-5, 1e-6, 1e-7, 1e-8] {
        p = AssocParams(beta_fa=beta);
        print(f"  beta_fa={beta:.0e}   ceiling = {max_assignable_sigma(p):.1f} m");
    }

    print("");
    print("--- one frame: two tracks, two measurements, one clean, one ambiguous ---");
    reset();
    t0 = spawn_track(1, [1000.0, 1000.0], [[400.0, 0.0], [0.0, 400.0]]);
    t1 = spawn_track(2, [5000.0, 5000.0], [[400.0, 0.0], [0.0, 400.0]]);

    zs = [[1010.0, 990.0], [5200.0, 5200.0], [20000.0, 20000.0]];
    R_shared = [[2500.0, 0.0], [0.0, 2500.0]];

    tracks = live_tracks();
    result = associate_global(tracks, zs, R_shared);

    print(f"  assignments (track_idx, meas_idx): {result.assignments}");
    print(f"  unassigned tracks: {result.unassigned_tracks}");
    print(f"  unassigned meas  : {result.unassigned_meas}");

    logdet_by_index = {};
    for pair in result.assignments {
        S = mat2_add(tracks[pair[0]].pos_cov, R_shared);
        sign, logdet = mat2_slogdet(S);
        logdet_by_index[pair[0]] = logdet;
    }
    apply_frame(result, tracks, logdet_by_index);

    for tr in live_tracks() {
        print(f"  track {tr.track_id}: status={tr.status} hits={tr.hits} "
              + f"misses={tr.misses} llr={tr.llr:.2f}");
    }

    print("");
    print("--- greedy vs global on the same frame ---");
    greedy_result = associate_greedy(tracks, zs, R_shared);
    print(f"  global assignments: {result.assignments}");
    print(f"  greedy assignments: {greedy_result.assignments}");

    print("");
    print("=== ok ===");
}
