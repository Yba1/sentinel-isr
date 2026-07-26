# Sentinel-ISR

Maritime domain awareness. Built at JacHacks SF, Founders Inc.

Replays real San Francisco Bay AIS traffic as **unlabelled** radar detections. Runs
multi-hypothesis tracking to hold vessel identity through crossings. Alerts when a track
enters a protected area. When a vessel goes dark, it keeps predicting position with a
growing uncertainty ellipse, then re-attributes a later unlabelled detection to the
correct vessel with a stated probability.

Identity is never used for association — recovering it from kinematics alone is the project.

## Status

| Phase | Module | State |
|---|---|---|
| 1 | `tracker/kalman.py` — constant-velocity Kalman filter | **done**, 27 tests |
| 2 | `tracker/assoc.py`, `tracker/metrics.py` — gating, NLL cost, padded Hungarian, lifecycle | **done**, 95 tests |
| 3 | Hypothesis branching as Jac walker spawning | not started |
| 4 | Geofence intrusion + dark-vessel re-association | not started |

122 tests total, all passing.

## Phase 2 acceptance

| Criterion | Target | Measured |
|---|---|---|
| Crossing targets: greedy loses identity, global does not | greedy >= 1 switch, global 0 | deterministic trap: **greedy 2, global 0** |
| ID-switch counter vs held-out identity, exposed in metrics | CLEAR-MOT | `tracker/metrics.py`, tested directly |
| 40x40 solve | < 20 ms | **0.95 ms** |
| Zero measurements / zero tracks / all gated out | no crash, well-formed result | covered for both algorithms |

Over **800 unscreened seeds** of an 18 kn, 30 s revisit crossing (four disjoint 200-seed
windows): greedy lost identity 116 times, global 22 — greedy switches about **5x as
often**. Per-window the ratio moves between 3.8x and 15x, so the pooled figure is the one
to quote.

That ratio, not a "global never fails", is the honest claim. In a symmetric two-target
crossing the two failure probabilities are tied together by the geometry, so there is no
configuration where global is clean on every seed while greedy visibly fails. The
deterministic trap above is the case where global's advantage is structural rather than
statistical: a converged track sits nearer its neighbour's plot, greedy commits to it,
and the neighbour is left starved.

## Association design

Costs are negative log-likelihoods so that assign, miss and birth are commensurable in one
linear assignment solve:

```
cost_assign = 0.5*d2 + log(2*pi) + 0.5*logdet(S) - log(p_D)
cost_miss   = -log(1 - p_D)
cost_birth  = -log(beta_fa)
```

The determinant term charges a track for its own uncertainty. Without it, a coasting track
with a covariance the size of a harbour would hoover up its neighbours' measurements,
because inflating S shrinks every d2 it produces. It does **not** decide the symmetric
crossing — equal S cancels there — it earns its keep when a confident track competes
against an uncertain one.

Gating is batched: one broadcast `np.linalg.solve` and one `slogdet` build the whole
(N, M) problem, never an explicit inverse and never a per-pair call. Gated-out pairs carry
a finite `BIG = cost_miss + cost_birth + 1`, provably dominated by taking miss+birth, which
avoids inf/nan inside the augmenting-path reduction.

`associate_greedy` shares the same gate and the same cost matrix — only the strategy
differs. Swapping the distance metric too would rig the comparison.

### Known constraint for Phase 4

`max_assignable_sigma()` — above a certain prediction uncertainty, `cost_assign` exceeds
`cost_miss + cost_birth` even at d2 = 0, so a measurement sitting exactly on the prediction
is still declared a birth. At the default `beta_fa = 1e-6` the ceiling is **1197 m**, and
the chi-squared gate is not what rejects it. This governs how long a dark vessel stays
re-acquirable, so dark-vessel re-association will need a smaller `beta_fa` or a
re-association step that does not compete against birth in the same solve. Pinned as a test.

## Phase 1 acceptance

| Criterion | Target | Measured |
|---|---|---|
| Filtered RMSE below measurement noise floor (sigma = 50 m) | < 50 m | **15.39 m** vs 48.22 m floor |
| P symmetric and PSD over 1000 steps | both, every step | max abs(P - P.T) = **1.14e-13**, min eigenvalue **2.95** |
| 1000 predict+update cycles | < 100 ms | **28.94 ms** |

Fusion check: interleaved AIS/radar through one filter gives 3.82 m RMSE, between the
AIS-only 2.92 m and radar-only 17.19 m baselines.

## Design notes

State is `[x, y, vx, vy]` in local ENU metres. No lat/lon inside the tracker, no database —
every frame touches all state, so there is no query to optimise.

`R` is a **per-call** argument to `update()`, never a constructor field. AIS fixes carry
`diag(25, 25) m^2` and radar plots `diag(2500, 2500) m^2`, a 100x variance ratio. That
asymmetry is what makes this fusion rather than a merge.

Speed comes from three things: Joseph-form covariance update (symmetric and PSD across the
millions of cycles a 60x replay accumulates), a closed-form 2x2 inverse of the innovation
covariance instead of `np.linalg.inv`, and slicing rather than multiplying by the constant
selection matrix `H`.

`tracker/kalman.py` knows nothing about vessels, sensors, MMSI or scenarios. It takes raw
`(z, R, dt)` only, so the frozen `Measurement` contract can land without touching it.

## Run

```bash
python -m pytest tests/ -q
```

Requires Python 3.11, numpy, scipy, pytest. No API keys, no network.
