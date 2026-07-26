"""PLACEHOLDER associator -- delete when Raj's ``tracker/associate.py`` lands.

The Fusion walker (jac/fusion.jac) imports ``associate_global`` from
``tracker.associate`` first and only falls back to this module. This defines
the frozen call contract so the walker does not change when the real
Mahalanobis-gating + Hungarian implementation replaces it:

    associate_global(tracks, measurements) ->
        (matches, unmatched_track_ids, unmatched_meas_ids)

    tracks:        list of (track_id, CVKalman) -- already predicted to the
                   measurement epoch; the real implementation is expected to
                   use kf.innovation(z, R) for gating.
    measurements:  list of Measurement (data.contracts)
    matches:       list of (track_id, meas_id)

This stub is greedy nearest-neighbour inside a fixed euclidean gate: globally
optimal it is not, and it knows nothing about covariance. It exists so the
Jac pipeline runs end-to-end today; every mis-association it makes is an
argument for Phase 2.
"""

from __future__ import annotations

import math
from typing import List, Sequence, Tuple

GATE_M = 500.0       # base euclidean gate; generous for 30 s frames at bay speeds
GATE_SIGMA_K = 3.0   # widen to k-sigma of the track's own position uncertainty
GATE_CAP_M = 8000.0  # never let a long-dark track claim the whole bay

IS_STUB = True  # lets the pipeline report honestly which associator ran


def _gate_for(kf: object) -> float:
    """Fixed gate for a well-updated track; grows with the filter's position
    covariance for a coasting one. This is the crudest possible nod toward
    Mahalanobis gating -- a dark track's reacquisition window IS its
    uncertainty ellipse -- so the demo works before the real gating lands."""
    p = kf.cov
    sigma = math.sqrt(max(0.0, 0.5 * (float(p[0][0]) + float(p[1][1]))))
    return min(max(GATE_M, GATE_SIGMA_K * sigma), GATE_CAP_M)


def associate_global(tracks: Sequence[Tuple[str, object]],
                     measurements: Sequence[object],
                     ) -> Tuple[List[Tuple[str, str]], List[str], List[str]]:
    """Greedy nearest-neighbour association within a covariance-scaled gate."""
    candidates = []
    for track_id, kf in tracks:
        tx, ty = float(kf.state[0]), float(kf.state[1])
        gate = _gate_for(kf)
        for m in measurements:
            d = math.hypot(m.x - tx, m.y - ty)
            if d <= gate:
                candidates.append((d, track_id, m.meas_id))
    candidates.sort()

    matches: List[Tuple[str, str]] = []
    used_tracks: set = set()
    used_meas: set = set()
    for _, track_id, meas_id in candidates:
        if track_id in used_tracks or meas_id in used_meas:
            continue
        matches.append((track_id, meas_id))
        used_tracks.add(track_id)
        used_meas.add(meas_id)

    unmatched_tracks = [tid for tid, _ in tracks if tid not in used_tracks]
    unmatched_meas = [m.meas_id for m in measurements if m.meas_id not in used_meas]
    return matches, unmatched_tracks, unmatched_meas
