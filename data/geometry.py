"""Numeric geometry primitives for the Jac layer. Deliberately Python.

The boundary rule: eigendecomposition, shapely predicates and anything else
that is linear algebra stays here; what to *do* with the results (colors,
polygons in FrameDeltas, alert decisions) is graph logic and lives in Jac.
"""

from __future__ import annotations

import math
from typing import List, Sequence, Tuple

import numpy as np
from shapely.geometry import Point, Polygon

__all__ = [
    "cov_ellipse_points",
    "make_zone_polygon",
    "polygon_contains",
    "point_in_ring",
    "heading_speed",
]


def cov_ellipse_points(cx: float, cy: float,
                       p00: float, p01: float, p11: float,
                       k_sigma: float = 2.0, n_points: int = 24
                       ) -> List[Tuple[float, float]]:
    """K-sigma uncertainty ellipse of a 2x2 position covariance, as a closed
    polygon in ENU metres ready for the frontend to draw verbatim.

    Eigendecomposition of ``[[p00, p01], [p01, p11]]`` gives the semi-axes
    (sqrt of eigenvalues, scaled by k) and the rotation (eigenvectors).
    """
    P = np.array([[p00, p01], [p01, p11]], dtype=float)
    # Symmetrise defensively: upstream Joseph-form updates keep P symmetric to
    # ~1e-13, but the ellipse should never be the thing that blows up.
    P = 0.5 * (P + P.T)
    vals, vecs = np.linalg.eigh(P)
    vals = np.clip(vals, 0.0, None)
    a = k_sigma * math.sqrt(float(vals[1]))   # major semi-axis
    b = k_sigma * math.sqrt(float(vals[0]))   # minor semi-axis
    major = vecs[:, 1]

    theta = np.linspace(0.0, 2.0 * math.pi, n_points, endpoint=False)
    unit = np.stack([np.cos(theta), np.sin(theta)])          # (2, n)
    R = np.array([[major[0], -major[1]], [major[1], major[0]]])
    pts = R @ (np.array([[a], [b]]) * unit)                  # rotate scaled circle
    xs = pts[0] + cx
    ys = pts[1] + cy
    ring = [(float(x), float(y)) for x, y in zip(xs, ys)]
    ring.append(ring[0])
    return ring


def make_zone_polygon(ring: Sequence[Sequence[float]]) -> Polygon:
    """Build the shapely polygon once; Zone nodes cache it because rebuilding
    per containment check is ~100x the cost of the check itself."""
    return Polygon([(float(p[0]), float(p[1])) for p in ring])


def polygon_contains(poly: Polygon, x: float, y: float) -> bool:
    return poly.contains(Point(x, y))


def point_in_ring(x: float, y: float,
                  ring: Sequence[Tuple[float, float]]) -> bool:
    """Shapely point-in-polygon on an ENU exterior ring (uncached)."""
    return Polygon(ring).contains(Point(x, y))


def heading_speed(vx: float, vy: float) -> Tuple[float, float]:
    """Velocity vector -> (heading degrees, nav convention 0=N clockwise; speed m/s)."""
    speed = math.hypot(vx, vy)
    heading = math.degrees(math.atan2(vx, vy)) % 360.0
    return heading, speed
