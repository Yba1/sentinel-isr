"""Phase 4, shadow copy: dark-vessel re-association, ported to Jac.

WHAT THIS FILE IS
------------------
`tracker/dark.py` answers one question in pure numerical Python: *a vessel
switched its AIS transponder off some minutes ago; an unattributed radar
detection has just appeared -- is it the same vessel, and how sure are we?*
That module is deliberately stateless -- it reads no files, holds no globals,
and knows nothing about zones, severities, or the hypothesis graph.

This file is a **parallel** re-expression of the same arithmetic in Jac, built
the way `jac/geofence.jac` builds Phase 3.5: a small hub node fans out over one
node per coasting track, and a walker traverses the fan-out to do the scoring
that the Python module would otherwise do with a single batched call into
`numpy.linalg`. It exists so that the dark-vessel logic can ALSO be read,
audited, and eventually extended as graph state and walker rules -- the same
split Sentinel-ISR uses everywhere else: numerical kernels can live in either
language, but per-entity memory and multi-step traversal are Jac's job.

This module is NOT imported by the live web server and NOT wired into
`tracker/dark.py`. It is a standalone, faithful re-implementation kept for
its own sake -- a second read of the same physics, in a second language, so
that a reviewer who only trusts Jac has something to check the Python math
against, line for line.

Coasting semantics (unchanged from the Python original)
---------------------------------------------------------
While a track is dark the filter only ever ``predict``s. With no measurement
to pull it back, the position covariance ``P`` grows **without bound** -- under
the DWNA model the position variance accumulates roughly ``q*dt*T^3/3`` over a
dark interval ``T`` stepped at cadence ``dt``. That growth is not a bug to be
capped; it is the entire point. An uncertainty ellipse that widens
super-linearly in time is the honest statement "the vessel is somewhere in
here", and it is why a re-attribution after ten dark minutes must score as a
strictly weaker claim than one after two.

Two chi-squared constants, and why they differ
------------------------------------------------
``CHI2_95_2DOF = 5.991`` is the DISPLAY constant -- the 95% confidence region
drawn on the chart. ``GATE_CHI2 = 9.21034`` is the ASSOCIATION gate -- the 99%
threshold a candidate must clear even to be considered. They are deliberately
different numbers: a drawn region should read as "almost certainly in there"
without swallowing half the chart, while a gate should reject only what is
genuinely implausible, since being stingy at the gate throws away correct
re-attributions -- the expensive error in this phase. A detection can
therefore legitimately sit outside the drawn ellipse and still be accepted:
the 95-99% annulus between 5.991 and 9.21 is intended, not an inconsistency.

The false-alarm term
----------------------
The posterior for candidate ``i`` is

    p_i = L_i / (sum_j L_j + BETA_FA_REACQ)

where each ``L_i`` is a Gaussian density in m^-2 and ``BETA_FA_REACQ`` is the
spatial density of detections that belong to no coasted track at all -- new
contacts, clutter, a vessel that was never tracked. It is the same physical
quantity as ``beta_fa`` in the Phase 2 association module, which is what makes
adding it into a sum of densities dimensionally honest.

Without that term a single surviving candidate always scores ``p = 1.0`` no
matter how absurd the geometry, because it is the only explanation on offer.
With it, "none of these" is always an explanation on offer, so ``p < 1``
strictly, with no clamping needed. A strong match on a tight prediction still
reaches roughly 0.96; a marginal one at the edge of the gate lands near 0.18.

Calibration
------------
With a single candidate, ``p = L / (L + beta)``, so ``p > 0.90`` needs
``L > 9*beta``. A perfect detection (``d2 = 0``) on an isotropic
``S ~ SIGMA^2 I`` gives ``L = 1 / (2*pi*SIGMA^2)``, hence a hard ceiling on how
uncertain a track may be and still be re-attributed with confidence::

    beta_fa     SIGMA ceiling at p = 0.90
    1e-6            133 m
    1e-7            421 m
    1e-8           1330 m
    1e-9           4205 m      <- BETA_FA_REACQ
    1e-10         13298 m

Measured against the actual filter (q = 0.01 m^2/s^3, coasted at a 10 s radar
cadence), the position sigma of a dark track reaches roughly 970 m at 5
minutes and 2720 m at 10 minutes. ``1e-9`` clears the whole 5-10 minute demo
window with margin.

``1e-9 m^-2`` is about one unattributed contact per 1000 km^2 -- three decades
below the Phase 2 default of ``beta_fa = 1e-6``, and legitimately so:
re-association is only ever asked about a detection that has already failed
normal association, so the population it competes against is the residue, not
the raw plot rate.

The two acceptance criteria pull in opposite directions. ``p(d2=0) > 0.90``
needs ``sigma < 4205 m``; ``p(d2=6.25) < 0.94`` (a 2.5-sigma offset must NOT
score like a match) needs ``sigma > 668 m``. At ``beta = 1e-9`` both hold for
``sigma in (668 m, 4205 m)``, roughly 4 to 13 minutes dark at a 10 s coast
cadence. Below that band the track is so tight that even a 2.5-sigma miss
scores 0.99 -- correct, but not the demo window. Above it, confidence in a
perfect hit falls under 0.90 and the vessel is effectively lost.

This is not "make beta tiny so p comes out high". The far end is carried by
the gate, not by beta: a detection 10 sigma out has ``d2 = 100 >> 9.21`` and is
rejected outright regardless of beta.

Numerics
---------
``det(2*pi*S)`` for a 2x2 ``S`` is ``(2*pi)^2 * det(S)``. A track dark for ten
minutes has ``P_pos ~ 7e6 m^2``, so ``det(S) ~ 5e13`` and ``L ~ 2e-8``:
computing the density directly is a race between a vanishing exponential and
an enormous determinant, and the naive expression silently returns zero.
Everything here is therefore done in log space, with the maximum log-term --
INCLUDING ``log(beta)`` -- subtracted before any exponentiation, so the
largest term is exactly 1.0 and nothing underflows.

The log-likelihood

    log L = -0.5*d2 - log(2*pi) - 0.5*logdet(S)

is precisely the negated cost of an "assign" hypothesis in the Phase 2
association module, minus its ``p_D`` term -- the two modules score a pair
identically. Jac has no ``numpy.linalg`` binding at this layer, so the 2x2
solves, determinants and eigendecompositions that the Python original hands
to LAPACK are written out here as closed-form 2x2 formulas -- exact, not an
approximation, since every matrix in this file is exactly 2x2.
"""

import math;

# ---------------------------------------------------------------------------
# Constants. Mirror tracker/dark.py exactly -- these must never drift apart
# from the Python originals, since the whole point of this file is to let a
# reviewer check one against the other line by line.
# ---------------------------------------------------------------------------

# 95th percentile of chi-squared with 2 dof: the DISPLAY ellipse.
glob CHI2_95_2DOF: float = 5.991;

# 99th percentile, 2 dof: the association gate. In tracker.dark this is
# re-exported from tracker.assoc so the two phases can never drift apart; here
# it is simply re-typed, with this comment doing the job a shared import does
# in the Python layer.
glob GATE_CHI2: float = 9.21034;

# False-alarm spatial density for re-acquisition, m^-2. About one unattributed
# contact per 1000 km^2. Chosen so a vessel dark for the 5-10 minute demo
# window still clears p = 0.90 on a perfect detection; see the module
# docstring's calibration section.
glob BETA_FA_REACQ: float = 1e-9;

# 1 m/s in knots (1 kn = 1852 m/h exactly).
glob MPS_TO_KN: float = 1.943844492440605;

glob _LOG_2PI: float = math.log(2.0 * math.pi);

# Run state for the graph-driven scoring path below. Mutated in place, never
# rebound, following the same discipline as geofence.jac's EVENTS / HUB.
glob HUB: list = [];           # [ReassocHub] for the current scoring pass
glob RESULTS: list = [];       # last reassociate() call's ReassocCandidate list


# ---------------------------------------------------------------------------
# 2x2 linear algebra. tracker.dark leans on np.linalg.solve / slogdet / eigh;
# every matrix that ever reaches this file is exactly 2x2 (a position
# covariance plus a measurement covariance), so those three LAPACK calls have
# exact closed forms and are written out below rather than bound to a
# numerical library. This is not an approximation of the numpy path -- for a
# 2x2 matrix it is the SAME arithmetic LAPACK performs, just unrolled.
# ---------------------------------------------------------------------------

def mat2_symmetrize(P: list) -> list {
    """Return ``0.5*(P + P^T)`` for a 2x2 matrix given as ``[[a,b],[c,d]]``.

    A covariance propagated through millions of predict cycles can pick up
    femto-scale asymmetry; symmetrizing before anything else keeps the
    eigendecomposition below from reading an arbitrary half of a matrix that
    is supposed to be exactly symmetric.""";
    a = P[0][0];
    b = (P[0][1] + P[1][0]) / 2.0;
    d = P[1][1];
    return [[a, b], [b, d]];
}

def mat2_add(A: list, B: list) -> list {
    """Elementwise 2x2 sum. Used to build the innovation covariance
    ``S = P_pos + R``.""";
    return [
        [A[0][0] + B[0][0], A[0][1] + B[0][1]],
        [A[1][0] + B[1][0], A[1][1] + B[1][1]]
    ];
}

def mat2_det(A: list) -> float {
    """Determinant of a 2x2 matrix. ``ad - bc``, nothing more.""";
    return A[0][0] * A[1][1] - A[0][1] * A[1][0];
}

def mat2_solve(A: list, v: list) -> list {
    """Solve ``A x = v`` for a 2x2 ``A`` via Cramer's rule -- a genuine solve,
    never an explicit inverse, matching the discipline of
    ``np.linalg.solve`` in the Python original (which is chosen there
    specifically to avoid forming ``A^-1``).""";
    det = mat2_det(A);
    x0 = (v[0] * A[1][1] - A[0][1] * v[1]) / det;
    x1 = (A[0][0] * v[1] - v[0] * A[1][0]) / det;
    return [x0, x1];
}

def mat2_slogdet(A: list) -> tuple {
    """Return ``(sign, log(|det(A)|))``, mirroring ``np.linalg.slogdet``.

    Splitting sign and log-magnitude is what lets the caller detect a
    non-positive-definite ``S`` (sign <= 0) before trusting the log value at
    all, exactly as the Python original does before ever computing a
    likelihood from it.""";
    d = mat2_det(A);
    if d > 0.0 {
        return (1.0, math.log(d));
    } elif d < 0.0 {
        return (-1.0, math.log(-d));
    } else {
        return (0.0, float('-inf'));
    }
}

def mat2_eigh(P: list) -> tuple {
    """Eigenvalues (ascending) and eigenvectors of a SYMMETRIC 2x2 matrix.

    Closed form via the standard 2x2 symmetric formula:

        lambda = (tr +/- sqrt(tr^2 - 4*det)) / 2

    returned smallest-first, matching ``np.linalg.eigh``'s convention -- which
    is why ``ellipse_axes`` below reads the MAJOR axis off the LAST column,
    not the first. Getting that backwards draws every ellipse rotated 90
    degrees, wrong exactly on a long-dark track where the covariance is
    genuinely elongated -- the case that matters most here.

    Returns ``(val_small, val_large, vec_small, vec_large)`` where each
    eigenvector is a ``[x, y]`` pair. For a circular (or near-circular) input
    the eigenvectors are not uniquely determined; the axis-aligned choice
    ``[1, 0]`` / ``[0, 1]`` is returned, which is as good as any other.""";
    a = P[0][0];
    b = P[0][1];
    d = P[1][1];
    tr = a + d;
    det = a * d - b * b;
    disc = tr * tr - 4.0 * det;
    if disc < 0.0 {
        # Round-off on a matrix that is PSD in exact arithmetic; clamp rather
        # than propagate a spurious imaginary part.
        disc = 0.0;
    }
    root = math.sqrt(disc);
    val_small = (tr - root) / 2.0;
    val_large = (tr + root) / 2.0;

    if b == 0.0 {
        if a >= d {
            return (val_small, val_large, [0.0, 1.0], [1.0, 0.0]);
        } else {
            return (val_small, val_large, [1.0, 0.0], [0.0, 1.0]);
        }
    }

    # Eigenvector for val_large solves (a - val_large)*x + b*y = 0.
    vx = b;
    vy = val_large - a;
    norm = math.sqrt(vx * vx + vy * vy);
    if norm == 0.0 {
        vec_large = [1.0, 0.0];
    } else {
        vec_large = [vx / norm, vy / norm];
    }
    # The small-eigenvalue eigenvector is orthogonal to the large one.
    vec_small = [-vec_large[1], vec_large[0]];

    return (val_small, val_large, vec_small, vec_large);
}


# ---------------------------------------------------------------------------
# Sigma ceiling. Free function, no graph state -- a pure inversion of the
# posterior formula, exactly mirroring tracker.dark.sigma_ceiling_for_p90.
# ---------------------------------------------------------------------------

def sigma_ceiling_for_p90(beta_fa: float = BETA_FA_REACQ) -> float {
    """Largest isotropic sigma (m) at which a PERFECT detection still scores
    ``p > 0.90``.

    Inverts ``p = L / (L + beta) > 0.9`` with ``L = 1 / (2*pi*sigma^2)`` at
    ``d2 = 0``. Exposed so a demo brief can state "this track is re-acquirable
    for another N metres of drift" instead of hard-coding a number that would
    rot the moment ``BETA_FA_REACQ`` moves. Mirrors the sibling
    ``max_assignable_sigma`` ceiling in the association phase -- same
    tension, same single knob, two different thresholds.""";
    return math.sqrt(1.0 / (18.0 * math.pi * beta_fa));
}


# ---------------------------------------------------------------------------
# Ellipse geometry.
# ---------------------------------------------------------------------------

def ellipse_axes(P_pos: list, conf_chi2: float = CHI2_95_2DOF) -> tuple {
    """Return ``(semi_major_m, semi_minor_m, theta_degrees)`` of the confidence
    ellipse described by 2x2 covariance ``P_pos``.

    ``theta`` is the bearing of the major axis measured counter-clockwise from
    the ENU +x (east) axis, in degrees. An ellipse axis is undirected, so
    ``theta`` and ``theta +/- 180`` describe the same ellipse -- which one
    comes out depends on the arbitrary sign the eigenvector formula settles
    on, and that ambiguity is not normalised away here because normalising it
    would hide the ambiguity rather than remove it.

    Uses the symmetric-2x2 eigen-formula in ``mat2_eigh`` rather than a
    generic eigensolver -- ``P_pos`` is guaranteed symmetric, and asking for
    that specialisation is what guarantees real eigenvalues and orthonormal
    eigenvectors without a library call.""";
    P = mat2_symmetrize(P_pos);
    val_small, val_large, vec_small, vec_large = mat2_eigh(P);

    # A PSD-but-near-singular block can yield a tiny negative eigenvalue from
    # round-off; sqrt of that would be NaN and poison the whole ellipse.
    val_small = math.sqrt(conf_chi2 * max(val_small, 0.0));
    val_large = math.sqrt(conf_chi2 * max(val_large, 0.0));

    a = val_large;
    b = val_small;
    theta = math.degrees(math.atan2(vec_large[1], vec_large[0]));

    return (a, b, theta);
}

def ellipse_polygon(center: list, P_pos: list,
                    conf_chi2: float = CHI2_95_2DOF, n: int = 64) -> list {
    """``n``-point polygon approximation of the confidence ellipse, in ENU
    metres, returned as a list of ``[x, y]`` vertices (an OPEN ring -- the
    Python original leaves the ring open too, since shapely closes polygons
    itself and an explicit duplicate last vertex would show up in every
    coordinate count downstream; the same convention is kept here even
    without shapely to consume it).

    ``n = 64`` keeps the maximum radial error under 0.1% of the semi-major
    axis -- below a pixel at any sane display scale. Built by rotating the
    axis-aligned ellipse rather than by sampling a parametric bearing, so it
    stays exact for highly eccentric covariances where the two would
    otherwise differ.""";
    a, b, theta_deg = ellipse_axes(P_pos, conf_chi2);
    th = math.radians(theta_deg);
    cos_t = math.cos(th);
    sin_t = math.sin(th);

    pts = [];
    i = 0;
    while i < n {
        t = 2.0 * math.pi * (float(i) / float(n));
        ex = a * math.cos(t);
        ey = b * math.sin(t);
        x = center[0] + cos_t * ex - sin_t * ey;
        y = center[1] + sin_t * ex + cos_t * ey;
        pts.append([x, y]);
        i += 1;
    }
    return pts;
}

def clip_to_water(poly: list, land: list) -> list {
    """Placeholder for "subtract dry land from the uncertainty region".

    The Python original calls into shapely (``poly.difference(land)``) to
    remove any part of the search region that covers a headland, since a
    vessel cannot be ashore and an unclipped region overstates the area to
    search. This Jac layer has no polygon-difference primitive of its own --
    that geometry belongs to ``tracker/dark.py`` and ``tracker/geofence.py``
    -- so this function documents the contract (tolerate ``land`` being
    empty, return ``poly`` unchanged in that case) without re-implementing
    computational geometry that already exists, and is correct, in Python.

    Real callers wanting the clipped polygon should go through
    ``tracker.dark.clip_to_water`` directly; this stub exists only so the
    Jac-side re-derivation of the rest of the module has a matching symbol
    to call, for readers walking the two files side by side.""";
    if len(land) == 0 {
        return poly;
    }
    # No local difference primitive: return the unclipped region rather than
    # silently fabricating a wrong one.
    return poly;
}


# ---------------------------------------------------------------------------
# Data shapes. ``ReassocCandidate`` mirrors the frozen dataclass in
# tracker.dark exactly, field for field. ``DarkTrack`` becomes a Jac node so
# that it can sit in the fan-out graph the walker below traverses -- the
# Python version is explicitly NOT a live reference to a filter for exactly
# the reason its docstring gives (a live track mutates under ``predict``);
# a node snapshot here is just as frozen, since nothing in this file ever
# calls ``predict`` on it.
# ---------------------------------------------------------------------------

obj ReassocCandidate {
    """One coasting track scored as an explanation for one unattributed
    detection.

    Rejected candidates are represented too, with their real ``d2`` and
    ``likelihood`` but ``p = 0.0`` and a populated ``reason``. An
    intelligence brief that says "considered and rejected 3 other tracks,
    nearest at 14 sigma" is far more convincing than one that silently shows
    a single answer.

    ``implied_speed_*`` is the speed the vessel would have had to sustain to
    get from its last MEASURED fix to this detection. It plays no part in the
    probability at all -- it is a plausibility cross-check for the operator,
    because the filter will happily accept a geometrically fine hypothesis
    that requires 60 knots from a bulk carrier.""";
    has track_id: int;
    has p: float = 0.0;
    has d2: float = 0.0;
    has sigma_distance: float = 0.0;
    has likelihood: float = 0.0;
    has time_dark_s: float = 0.0;
    has range_m: float = 0.0;
    has implied_speed_mps: float = 0.0;
    has implied_speed_kn: float = 0.0;
    has gated_out: bool = False;
    has reason: str = "";
}

node DarkTrack {
    """Minimal standalone view of a coasting track, as a graph node.

    Deliberately not a reference to a live filter: this node is a snapshot
    scored once by the walker below, and holding a live track would mean the
    numbers in a brief silently change if anything called ``predict`` between
    scoring and rendering.

    ``last_fix_xy`` / ``last_fix_t`` describe the last position actually
    MEASURED, not the current prediction. They exist only for the range and
    implied-speed cross-check; the probability computation below uses
    ``pos`` / ``pos_cov`` only.""";
    has track_id: int;
    has pos: list = [0.0, 0.0];          # [x, y], current PREDICTED position
    has pos_cov: list = [[0.0, 0.0], [0.0, 0.0]];  # 2x2 predicted covariance
    has last_fix_xy: list = [0.0, 0.0];
    has last_fix_t: float = 0.0;
    has label: str = "";

    # Scoring scratch space, filled in by ReassocScorer.score and consumed
    # by the aggregation pass in reassociate(). Not meaningful outside a
    # single reassociate() call.
    has d2: float = 0.0;
    has log_L: float = 0.0;
    has gated_in: bool = False;
}

edge Scored {}


node ReassocHub {
    """Fan-out anchor for one reassociate() pass, mirroring geofence.jac's
    Watchtower. Traversal starts here, never at ``root``.""";
    has label: str = "dark_shadow";
}


# ---------------------------------------------------------------------------
# Graph construction / lookup, following the exact discipline of
# geofence.jac's hub() / watch_for(): a linear scan over typed edges rather
# than a dict, since the graph itself is the index.
# ---------------------------------------------------------------------------

def hub() -> ReassocHub {
    """The current pass's hub, created on first use.""";
    if len(HUB) == 0 {
        h = ReassocHub();
        root ++> h;
        HUB.append(h);
    }
    return HUB[0];
}

def reset() -> None {
    """Start a fresh scoring pass: new hub, empty results.

    Essential rather than cosmetic -- ``root`` persists across ``jac run``
    invocations, so without this a second reassociate() call in the same
    process would fan out over the previous call's tracks as well as its
    own.""";
    RESULTS.clear();
    HUB.clear();
    h = ReassocHub();
    root ++> h;
    HUB.append(h);
}

def add_dark_track(track_id: int, pos: list, pos_cov: list,
                   last_fix_xy: list, last_fix_t: float,
                   label: str = "") -> DarkTrack {
    """Attach one coasting track to the current hub as a fresh node.

    Unlike ``geofence.jac``'s ``watch_for``, this is not idempotent by
    design: a reassociate() pass scores one frozen snapshot per track, so
    calling this twice for the same ``track_id`` within a pass is a caller
    bug, not a resighting -- there is no "last frame" for a dark-vessel
    score to update.""";
    h = hub();
    tw = DarkTrack(track_id=track_id, pos=pos, pos_cov=pos_cov,
                   last_fix_xy=last_fix_xy, last_fix_t=last_fix_t, label=label);
    h +>:Scored:+> tw;
    return tw;
}


# ---------------------------------------------------------------------------
# The scoring walker -- one traversal per unattributed detection ``z``.
#
# The Python original batches every track's solve/slogdet into two LAPACK
# calls; a Jac walker instead visits each DarkTrack node once and computes
# that track's own d2 / log-likelihood locally. The two are mathematically
# identical per-candidate -- batching is a performance choice in the Python
# layer, not a change of formula -- and the walker's per-node independence is
# exactly what lets a future extension attach per-track scoring rules (a
# vessel-class prior, a lane constraint) without touching the aggregation
# step below.
# ---------------------------------------------------------------------------

walker DarkScorer {
    """Score every DarkTrack under the current hub against one detection.

    ``z`` and ``R`` describe the unattributed detection: position and
    measurement covariance, in the same ENU frame as every track's ``pos`` /
    ``pos_cov``. ``t_now`` is the frame timestamp used for the implied-speed
    cross-check. The posterior itself is NOT computed per-node -- it needs
    the full set of accepted log-likelihoods at once for the log-sum-exp, so
    this walker's job stops at populating ``d2`` / ``log_L`` / ``gated_in``
    on each node, and ``reassociate()`` does the aggregation once the
    traversal completes.""";
    has z: list = [0.0, 0.0];
    has R: list = [[0.0, 0.0], [0.0, 0.0]];
    has t_now: float = 0.0;
    has gate_chi2: float = GATE_CHI2;

    can dispatch with ReassocHub entry {
        visit [->:Scored:->];
    }

    can score with DarkTrack entry {
        S = mat2_add(here.pos_cov, self.R);
        nu = [self.z[0] - here.pos[0], self.z[1] - here.pos[1]];

        sign, logdet = mat2_slogdet(S);
        if sign <= 0.0 {
            # Mirrors the Python original's hard failure: an innovation
            # covariance that is not positive definite means R or a track's
            # pos_cov is broken upstream, and silently continuing would
            # produce a likelihood with no meaning.
            here.d2 = float('inf');
            here.log_L = float('-inf');
            here.gated_in = False;
            return;
        }

        sol = mat2_solve(S, nu);
        d2 = nu[0] * sol[0] + nu[1] * sol[1];

        # log L = -0.5*d2 - log(2*pi) - 0.5*logdet(S): identical to the
        # negated "assign" cost in the association phase, minus its p_D
        # term -- the consistency argument the module docstring makes.
        log_L = -0.5 * d2 - _LOG_2PI - 0.5 * logdet;

        here.d2 = d2;
        here.log_L = log_L;
        here.gated_in = d2 <= self.gate_chi2;
    }
}


def _implied_speed(z: list, last_fix_xy: list, last_fix_t: float,
                   t_now: float) -> tuple {
    """Return ``(range_m, speed_mps, speed_kn)`` from a track's last measured
    fix to detection ``z``.

    A non-positive dark interval means the caller handed us a fix at or after
    ``t_now``: speed is undefined, not infinite, so it is reported as 0.0
    rather than dividing -- matching the Python original exactly.""";
    dx = z[0] - last_fix_xy[0];
    dy = z[1] - last_fix_xy[1];
    rng = math.sqrt(dx * dx + dy * dy);
    time_dark = t_now - last_fix_t;
    if time_dark > 0.0 {
        v = rng / time_dark;
    } else {
        v = 0.0;
    }
    return (rng, v, v * MPS_TO_KN);
}


def reassociate(
    z: list,
    R: list,
    t_now: float,
    beta_fa: float = BETA_FA_REACQ,
    gate_chi2: float = GATE_CHI2
) -> list {
    """Rank every DarkTrack node under the current hub as an explanation for
    one unattributed detection ``z``.

    Returns all candidates sorted by ``p`` descending (ties broken by
    ascending ``d2``, so the rejected tail reads nearest-first), including
    gated-out candidates with ``p = 0.0`` and a populated ``reason``.
    Gated-out candidates are excluded from the log-sum-exp denominator: a
    hypothesis the gate has already ruled out must not dilute the
    probability of the survivors -- the same rule the Python original
    enforces by masking ``accepted`` before summing.

    An empty hub (no DarkTrack nodes attached) returns ``[]`` -- there is no
    track to blame, which is a perfectly ordinary frame, not an error.""";
    h = hub();
    tracks = [->:Scored:->];  # placeholder for readability; real fetch below
    tracks = [];
    for tw in [h ->:Scored:->] {
        tracks.append(tw);
    }

    if len(tracks) == 0 {
        RESULTS.clear();
        return [];
    }

    w = h spawn DarkScorer(z=z, R=R, t_now=t_now, gate_chi2=gate_chi2);

    # --- aggregation: log-sum-exp over accepted candidates plus log(beta) ---
    accepted_terms = [];
    for tw in tracks {
        if tw.gated_in {
            accepted_terms.append(tw.log_L);
        }
    }

    log_beta = math.log(beta_fa);
    m = log_beta;
    for term in accepted_terms {
        if term > m {
            m = term;
        }
    }

    denom = math.exp(log_beta - m);
    for term in accepted_terms {
        denom += math.exp(term - m);
    }

    out = [];
    for tw in tracks {
        sig = math.sqrt(max(tw.d2, 0.0));
        rng, v_mps, v_kn = _implied_speed(z, tw.last_fix_xy, tw.last_fix_t, t_now);
        time_dark = t_now - tw.last_fix_t;

        if tw.gated_in {
            p = math.exp(tw.log_L - m) / denom;
            reason = "";
        } else {
            p = 0.0;
            reason = f"gated out: d2={tw.d2:.2f} > {gate_chi2:.2f} ({sig:.1f} sigma)";
        }

        if tw.log_L == float('-inf') {
            L = 0.0;
        } else {
            L = math.exp(tw.log_L);
        }

        out.append(ReassocCandidate(
            track_id=tw.track_id,
            p=p,
            d2=tw.d2,
            sigma_distance=sig,
            likelihood=L,
            time_dark_s=time_dark,
            range_m=rng,
            implied_speed_mps=v_mps,
            implied_speed_kn=v_kn,
            gated_out=not tw.gated_in,
            reason=reason
        ));
    }

    out.sort(key=lambda c: can (c.p * -1.0, c.d2, c.track_id));

    RESULTS.clear();
    for c in out {
        RESULTS.append(c);
    }
    return out;
}


# ---------------------------------------------------------------------------
# Readback helpers, mirroring geofence.jac's events()/event_count() family.
# ---------------------------------------------------------------------------

def last_results() -> list {
    """The ReassocCandidate list from the most recent reassociate() call.""";
    return list(RESULTS);
}

def best_candidate() -> ReassocCandidate {
    """The top-ranked candidate from the most recent reassociate() call, or
    None if the last call had nothing to rank.""";
    if len(RESULTS) == 0 {
        return None;
    }
    return RESULTS[0];
}

def accepted_count() -> int {
    """How many candidates from the most recent call cleared the gate.""";
    n = 0;
    for c in RESULTS {
        if not c.gated_out {
            n += 1;
        }
    }
    return n;
}


# ---------------------------------------------------------------------------
# Demo. `with entry:__main__` so `import dark_shadow` from a test harness does
# NOT run it -- matching geofence.jac's convention exactly.
# ---------------------------------------------------------------------------

with entry:__main__ {
    print("=== sentinel-isr :: phase 4 shadow :: dark-vessel re-association ===");

    print("");
    print("--- sigma ceiling for p90, across beta_fa ---");
    for beta in [1e-6, 1e-7, 1e-8, 1e-9, 1e-10] {
        ceil = sigma_ceiling_for_p90(beta);
        print(f"  beta_fa={beta:.0e}   sigma ceiling = {ceil:.1f} m");
    }

    print("");
    print("--- ellipse_axes on an elongated dark-track covariance ---");
    P_elong = [[9.0e6, 3.0e6], [3.0e6, 2.0e6]];
    a, b, theta = ellipse_axes(P_elong);
    print(f"  semi-major={a:.1f} m  semi-minor={b:.1f} m  theta={theta:.1f} deg");

    print("");
    print("--- reassociate: one detection, three coasting tracks ---");
    reset();
    add_dark_track(101, [8000.0, 10000.0], [[9.0e5, 0.0], [0.0, 9.0e5]],
                   [5000.0, 10000.0], 0.0, label="V-77");
    add_dark_track(102, [8500.0, 10600.0], [[2.5e6, 0.0], [0.0, 2.5e6]],
                   [4000.0, 9500.0], 0.0, label="V-12");
    add_dark_track(103, [40000.0, 40000.0], [[4.0e5, 0.0], [0.0, 4.0e5]],
                   [39500.0, 39500.0], 0.0, label="V-05");

    z = [8020.0, 10010.0];
    R = [[2500.0, 0.0], [0.0, 2500.0]];
    candidates = reassociate(z, R, 600.0);

    for c in candidates {
        print(f"  track={c.track_id:<4} p={c.p:.3f}  d2={c.d2:.2f}  "
              + f"sigma={c.sigma_distance:.2f}  gated_out={c.gated_out}  {c.reason}");
    }

    print("");
    print(f"  accepted candidates    : {accepted_count()}");
    best = best_candidate();
    if best is not None {
        print(f"  best explanation       : track {best.track_id} at p={best.p:.3f}");
    }

    print("");
    print("=== ok ===");
}
