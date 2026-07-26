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
| 1 | `tracker/kalman.py` — constant-velocity Kalman filter | **done**, 27 tests passing |
| 2 | Mahalanobis gating + Hungarian assignment | not started |
| 3 | Hypothesis branching as Jac walker spawning | not started |
| 4 | Geofence intrusion + dark-vessel re-association | not started |

## Data layer (scenario packs + replay)

`data/scenario.py` loads a scenario pack (`scenarios/<id>/pack.json`) into memory: real
SF Bay AIS resampled to 30 s frames in local ENU, geofence GeoJSON layers, synthetic
actors from `gen:` track generators, and scripted events (`ais_off`, `radar_contact`,
`identity_change`). MMSI is stripped at ingest into a ground-truth side table — a
`Measurement` is structurally incapable of carrying identity, and the loader asserts it.
`data/replay.py` paces frames at 1x/10x/60x with instant `seek()` and `reset()`.

```bash
# one-time: fetch a MarineCadastre day and cache the pack's window (~1 MB, committed)
python scripts/extract_window.py --zip data/raw/AIS_2024_06_15.zip --pack s01_dark_in_sanctuary
python scripts/find_crossings.py --pack s01_dark_in_sanctuary   # pick/verify the window
python -m data.replay s01_dark_in_sanctuary                     # smoke run
```

Measured on `s01_dark_in_sanctuary`: 328 vessels, 69,530 measurements, load 0.24 s,
seek 3 µs. Swapping packs is a string change (`s02_synthetic_demo` is the
synthetic-only fallback).

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
