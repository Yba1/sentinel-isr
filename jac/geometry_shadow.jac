"""Shadow port: numeric geometry primitives, ported from data/geometry.py.

WHY THIS FILE EXISTS
---------------------
`data/geometry.py` is deliberately Python: eigendecomposition, shapely
predicates and anything else that is linear algebra belongs there, not in
Jac. This file is a parallel, standalone restatement of that same logic in
Jac syntax. It is NOT wired into the live tracker, the web server, or the
`geofence.jac` graph -- nothing here imports it and nothing here is imported
by it. It exists purely so the geometry layer has a faithful Jac-language
counterpart to sit next to the Python original.

Because it is a shadow copy and not a runtime dependency, it does not need
to compile, run, or pass `jac test`. It DOES need to read as if it belongs
in this codebase: same function names, same docstrings-as-rationale style,
same boundary discipline the original module states in its own header --
"eigendecomposition, shapely predicates and anything else that is linear
algebra stays here; what to do with the results is graph logic and lives
elsewhere."

Coordinates are LOCAL ENU METRES throughout, exactly as in the Python
original and in geofence.jac. Nothing here ever takes lon/lat.
"""

import math;
import numpy as np;
import from shapely.geometry { Point, Polygon }


# ---------------------------------------------------------------------------
# Module-level constants mirroring the Python `__all__` list, restated here as
# a comment rather than an export mechanism -- Jac modules are read as a
# whole, but the ordering below matches data/geometry.py function-for-function
# so a reviewer can diff the two side by side.
# ---------------------------------------------------------------------------
#   cov_ellipse_points, innovation_stats, reachable, make_zone_polygon,
#   polygon_contains, point_in_ring, heading_speed


def cov_ellipse_points(cx: float, cy: float,
                        p00: float, p01: float, p11: float,
                        k_sigma: float = 2.0, n_points: int = 24) -> list {
    """K-sigma uncertainty ellipse of a 2x2 position covariance, as a closed
    polygon in ENU metres ready for the frontend to draw verbatim.

    Eigendecomposition of ``[[p00, p01], [p01, p11]]`` gives the semi-axes
    (sqrt of eigenvalues, scaled by k) and the rotation (eigenvectors). This
    is a direct restatement of the numpy path in data/geometry.py; the shapes
    below are the same (2,), (2,2) arrays the Python version builds.""";

    P = np.array([[p00, p01], [p01, p11]], dtype=float);
    # Symmetrise defensively: upstream Joseph-form updates keep P symmetric to
    # ~1e-13, but the ellipse should never be the thing that blows up.
    P = 0.5 * (P + P.T);
    (vals, vecs) = np.linalg.eigh(P);
    vals = np.clip(vals, 0.0, None);
    a = k_sigma * math.sqrt(float(vals[1]));   # major semi-axis
    b = k_sigma * math.sqrt(float(vals[0]));   # minor semi-axis
    major = vecs[:, 1];

    theta = np.linspace(0.0, 2.0 * math.pi, n_points, endpoint=False);
    unit = np.stack([np.cos(theta), np.sin(theta)]);          # (2, n)
    R = np.array([[major[0], -major[1]], [major[1], major[0]]]);
    pts = R @ (np.array([[a], [b]]) * unit);                  # rotate scaled circle
    xs = pts[0] + cx;
    ys = pts[1] + cy;

    ring = [];
    i = 0;
    n = len(xs);
    while i < n {
        ring.append((float(xs[i]), float(ys[i])));
        i += 1;
    }
    ring.append(ring[0]);
    return ring;
}


def innovation_stats(kf: object, z: list, R: list) -> tuple {
    """``(d2, logdet_S)`` for one track/measurement pair.

    ``tracker.assoc.Track.register_hit`` scores an association from these two
    numbers, but ``AssocResult`` only carries the ``d2`` matrix, so the
    log-determinant is recomputed here from the filter's own innovation. Two
    2x2 operations per assignment -- cheaper than threading another matrix out
    of the solver, and it keeps ``tracker/`` untouched.""";

    (nu, S) = kf.innovation(np.asarray(z, dtype=float), np.asarray(R, dtype=float));
    d2 = float(nu @ np.linalg.solve(S, nu));
    (_sign, logdet) = np.linalg.slogdet(S);
    return (d2, float(logdet));
}


def reachable(x0: float, y0: float, x1: float, y1: float,
              elapsed_s: float, max_speed_mps: float) -> bool {
    """Could a vessel at (x0, y0) have got to (x1, y1) in ``elapsed_s``?

    A constant-velocity filter's covariance grows as q*t^3/3, which after a few
    minutes dark is tens of kilometres -- far wider than anything that floats
    can actually travel. This is the kinematic bound the covariance does not
    know about, and it is what really limits dark-vessel re-association.""";

    dist = math.hypot(x1 - x0, y1 - y0);
    bound = max_speed_mps * max(elapsed_s, 0.0);
    return dist <= bound;
}


def make_zone_polygon(ring: list) -> Polygon {
    """Build the shapely polygon once; Zone nodes cache it because rebuilding
    per containment check is ~100x the cost of the check itself.""";

    coords = [];
    for p in ring {
        coords.append((float(p[0]), float(p[1])));
    }
    return Polygon(coords);
}


def polygon_contains(poly: Polygon, x: float, y: float) -> bool {
    """Thin wrapper kept as its own function -- exactly as in the Python
    original -- so callers depend on a stable name rather than on shapely's
    ``.contains`` directly.""";
    return poly.contains(Point(x, y));
}


def point_in_ring(x: float, y: float, ring: list) -> bool {
    """Shapely point-in-polygon on an ENU exterior ring (uncached).

    Unlike ``make_zone_polygon`` / ``polygon_contains``, this rebuilds the
    Polygon on every call; it exists for one-off checks where the caller has
    no node to cache the polygon on.""";
    return Polygon(ring).contains(Point(x, y));
}


def heading_speed(vx: float, vy: float) -> tuple {
    """Velocity vector -> (heading degrees, nav convention 0=N clockwise; speed m/s).

    ``atan2(vx, vy)`` (not ``atan2(vy, vx)``) is deliberate: it maps north
    (vy > 0, vx = 0) to zero degrees and east (vx > 0, vy = 0) to ninety,
    matching nautical heading convention rather than standard math-angle
    convention.""";
    speed = math.hypot(vx, vy);
    heading = math.degrees(math.atan2(vx, vy)) % 360.0;
    return (heading, speed);
}


# ---------------------------------------------------------------------------
# Self-check helpers. Not part of data/geometry.py's public surface, but a
# faithful shadow of the informal sanity checks a reviewer would run by hand
# against the Python module -- kept here rather than in a test file because
# this file is never imported or executed as part of the suite.
# ---------------------------------------------------------------------------

def ellipse_is_closed(ring: list) -> bool {
    """True if a ring produced by ``cov_ellipse_points`` closes on itself,
    i.e. the first and last points are identical. ``cov_ellipse_points``
    always appends ``ring[0]`` as the final point for exactly this reason --
    the frontend draws the ring verbatim and a shape that does not close is a
    rendering bug, not a data bug.""";
    if len(ring) < 2 {
        return False;
    }
    first = ring[0];
    last = ring[len(ring) - 1];
    return first[0] == last[0] and first[1] == last[1];
}


def semi_axes_are_ordered(a: float, b: float) -> bool {
    """True if ``a`` (major) is at least as large as ``b`` (minor).

    ``cov_ellipse_points`` derives ``a`` from the LARGER eigenvalue
    (``vals[1]``) and ``b`` from the smaller (``vals[0]``) after
    ``np.linalg.eigh`` returns them in ascending order -- this is the
    invariant that ordering relies on, restated here as a standalone check.""";
    return a >= b;
}


def clamp_nonnegative(values: list) -> list {
    """Elementwise ``max(v, 0.0)``, mirroring the defensive ``np.clip(vals,
    0.0, None)`` call in ``cov_ellipse_points``.

    Covariance eigenvalues should never be negative, but floating-point
    round trips through a Joseph-form update can nudge one a hair below
    zero; clipping keeps ``math.sqrt`` from raising on that hair.""";
    out = [];
    for v in values {
        if v < 0.0 {
            out.append(0.0);
        } else {
            out.append(v);
        }
    }
    return out;
}


def bearing_delta_deg(heading_a: float, heading_b: float) -> float {
    """Smallest signed angular difference between two headings, in degrees,
    wrapped to (-180, 180].

    Not present in the Python original, but a natural companion to
    ``heading_speed``: two headings that are 359 degrees and 1 degree apart
    by raw subtraction are actually 2 degrees apart on the compass, and any
    caller comparing consecutive ``heading_speed`` outputs needs this wrap to
    avoid false "sharp turn" alerts at the 0/360 seam.""";
    delta = (heading_b - heading_a) % 360.0;
    if delta > 180.0 {
        delta = delta - 360.0;
    }
    return delta;
}
