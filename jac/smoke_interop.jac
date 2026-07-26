"""Sentinel-ISR Jac <-> Python interop smoke test.

Proves the thing the whole architecture rests on: Jac can import the numpy/scipy
tracker package, call into it, and get real results back -- and that Jac's own
graph machinery (node / edge / walker / spawn) works in the same program.

Run it:
    <Python312>\\Scripts\\jac.exe run jac/smoke_interop.jac

No PYTHONPATH needed -- the bootstrap block below puts the repo root on sys.path.
Do run it from a WRITABLE directory though: jac creates a `.jac/` dir in the cwd.

Exits 0 on success, 1 on any failure, so setup scripts and CI can gate on it.
The FIRST run takes ~2 minutes (the Jac compiler is written in Jac and gets
compiled + cached on first use). Subsequent runs are fast.
"""

import sys;
import os;

# `jac run` puts the .jac file's OWN directory on sys.path, not the repo root, so
# `import from tracker.*` fails without help. Jac executes top-level statements in
# source order (imports are NOT hoisted above entry blocks), so this bootstrap runs
# before the tracker imports below and makes the file work from any cwd.
# Deliberately not solved with tracker/__init__.py -- namespace package is fine.
with entry {
    _repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)));
    if _repo_root not in sys.path {
        sys.path.insert(0, _repo_root);
    }
}

import from numpy { eye }
import from tracker.kalman { CVKalman }
import from tracker.assoc { Track, associate_global, DEFAULT_PARAMS }

# ---------------------------------------------------------------- Jac graph --

node Sensor {
    has name: str;
    has n_tracks: int = 0;
    has n_meas: int = 0;
}

edge Feeds {}

walker Reporter {
    has seen: list = [];

    can report with Sensor entry {
        print("[jac ] walker on node    :", here.name);
        print("[jac ] here.n_tracks     :", here.n_tracks);
        print("[jac ] here.n_meas       :", here.n_meas);
        self.seen.append(here.name);
        visit [->:Feeds:->];
    }
}

# ---------------------------------------------------------------- entry -----

with entry {
    failures = [];

    # -- 1. Python interop: build two real CVKalman-backed tracks -------------
    R = eye(2) * 4.0;
    kf_a = CVKalman.init_two_point([0.0, 0.0],   0.0, [10.0, 0.0],   1.0, R);
    kf_b = CVKalman.init_two_point([0.0, 500.0], 0.0, [10.0, 500.0], 1.0, R);

    track_a = Track(id=0, kf=kf_a);
    track_b = Track(id=1, kf=kf_b);
    tracks = [track_a, track_b];

    print("[jac ] track 0 predicted pos:", track_a.pos);
    print("[jac ] track 1 predicted pos:", track_b.pos);
    print("[jac ] gate_chi2 from params:", DEFAULT_PARAMS.gate_chi2);

    # Two measurements, one near each track.
    zs = [[11.0, 1.0], [11.0, 501.0]];
    Rs = [R, R];

    # -- 2. Call the scipy/numpy solver from Jac -----------------------------
    result = associate_global(tracks, zs, Rs);

    pairs = [];
    for a in result.assignments {
        pairs.append([a[0], a[1]]);
    }

    print("[jac ] assignments        :", pairs);
    print("[jac ] unassigned tracks  :", result.unassigned_tracks);
    print("[jac ] unassigned meas    :", result.unassigned_meas);
    print("[jac ] cost matrix shape  :", result.cost.shape);

    if pairs != [[0, 0], [1, 1]] {
        failures.append("associate_global returned " + str(pairs)
                        + ", expected [[0, 0], [1, 1]]");
    }
    if len(result.unassigned_tracks) != 0 or len(result.unassigned_meas) != 0 {
        failures.append("expected nothing unassigned, got tracks="
                        + str(result.unassigned_tracks) + " meas="
                        + str(result.unassigned_meas));
    }

    # -- 3. Jac graph: node + edge + walker, reading from `here` --------------
    up   = Sensor(name="ais_feed",   n_tracks=len(tracks), n_meas=len(zs));
    down = Sensor(name="radar_feed", n_tracks=len(tracks), n_meas=len(zs));
    root ++> up;
    up +>:Feeds:+> down;

    rep = up spawn Reporter();

    print("[jac ] walker visited     :", rep.seen);
    print("[jac ] nodes off Sensor   :", len([up -->]));
    # NOTE: `root` is PERSISTED to .jac/data/<name>.db in the cwd, so this count
    # GROWS by one on every run. Never assert on it. Delete .jac/data/ to reset.
    print("[jac ] nodes off root     :", len([root -->]), "(cumulative across runs)");

    if rep.seen != ["ais_feed", "radar_feed"] {
        failures.append("walker visited " + str(rep.seen)
                        + ", expected ['ais_feed', 'radar_feed']");
    }

    # -- 4. Verdict ----------------------------------------------------------
    if len(failures) > 0 {
        print("");
        print("SMOKE INTEROP: FAIL");
        for f in failures {
            print("  - " + f);
        }
        sys.exit(1);
    }

    print("");
    print("SMOKE INTEROP: PASS  (Jac imported tracker.*, ran numpy+scipy assoc, "
          + "and spawned a walker over its own graph)");
    sys.exit(0);
}
