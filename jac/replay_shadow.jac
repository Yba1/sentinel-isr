"""Shadow port: replay engine, ported from data/replay.py.

WHAT THIS IS AND WHY
---------------------
`data/replay.py` paces a materialised Scenario through wall time: it loads
every frame up front, so ``seek`` is an index assignment and ``reset`` never
re-parses anything. This file restates that same engine -- the same cursor,
the same speed multiplier, the same generator-of-frames shape -- in Jac
syntax, as a node/walker archetype instead of a plain class.

This is a STANDALONE shadow copy, in the same spirit as geometry_shadow.jac
next to it. Nothing in the live server, the Jac geofence graph, or any test
imports this file, and it imports nothing from them. It exists to give the
replay layer a faithful Jac-language counterpart; it is not expected to
compile or execute, and no effort has gone into making it do so. What matters
is that the control-flow and the rationale in the docstrings match the
Python original line for line.

THE MODEL
---------
Where replay.py has a plain ``ReplayEngine`` class holding ``scenario``,
``speed`` and ``_cursor``, this file uses a single ``ReplayCursor`` node to
hold the same three fields, and a ``Pacer`` walker to do the one thing that
actually needs traversal semantics: draining frames from the cursor to the
end while re-reading ``speed`` on every step, exactly as ``play()`` re-reads
``self._speed`` each iteration so a live speed change takes effect
immediately. Everything else (``seek``, ``reset``, ``step``) is a plain
function operating on the node's fields, because those are O(1) index
operations with no fan-out -- there is nothing for a walker to traverse.

Frames themselves are left as opaque dicts here (``t``, ``idx``,
``measurements``, ``events``) rather than a full contract type, since the
real ``Frame``/``Scenario`` contracts live in ``data/contracts.py`` and
``data/scenario.py`` and this file must not depend on them.
"""

import sys;
import time;

glob SPEEDS: tuple = (1.0, 10.0, 60.0);

# Process-local run state, in the same discipline as geofence.jac's globals:
# mutated in place, never rebound, so a caller (if one ever existed) would see
# live state rather than a stale snapshot. Boxed in lists purely so a plain
# value (an int, a float) can still be mutated through a shared reference.
glob SCENARIOS: dict = {};      # pack_id -> materialised scenario dict
glob CURSORS: list = [];        # [ReplayCursor] for the current run


# ---------------------------------------------------------------------------
# Graph
# ---------------------------------------------------------------------------

node ReplayCursor {
    """Frame cursor over one materialised scenario, with wall-clock pacing.

    Mirrors ``ReplayEngine``'s three pieces of instance state:
      speed    replay multiplier (1x / 10x / 60x, any positive float works)
      cursor   index of the next frame ``play``/``step`` will emit
      scenario the materialised pack this cursor walks
    """;
    has pack_id: str = "";
    has scenario: dict = {};
    has speed: float = 1.0;
    has cursor: int = 0;
}


# ---------------------------------------------------------------------------
# Construction / lookup
# ---------------------------------------------------------------------------

def from_pack(name_or_path: str, speed: float = 1.0) -> ReplayCursor {
    """Load (or reuse) a materialised scenario and hand back a fresh cursor
    over it, at frame 0.

    ``load_scenario`` in the Python original materialises every frame once;
    here that means the scenario dict is loaded into ``SCENARIOS`` at most
    once per pack id, and every subsequent ``from_pack`` call for the same id
    reuses it -- reset() never re-parses, and neither does a second cursor.""";

    if name_or_path not in SCENARIOS {
        SCENARIOS[name_or_path] = load_scenario_stub(name_or_path);
    }
    s = SCENARIOS[name_or_path];

    rc = ReplayCursor(pack_id=name_or_path, scenario=s, speed=speed, cursor=0);
    root ++> rc;
    CURSORS.append(rc);
    return rc;
}


def load_scenario_stub(name_or_path: str) -> dict {
    """Placeholder standing in for ``data.scenario.load_scenario``.

    The real loader parses a pack.json plus its measurement/event streams
    into a fully materialised ``Scenario``. This shadow file does not depend
    on that module, so a minimal empty-but-well-shaped dict is returned
    instead: same keys the rest of this file reads (``frames``,
    ``frame_interval_s``, ``pack_id``, ``name``, ``n_vessels``, ``geofences``,
    ``events``), just no frames in it.""";

    return {
        "pack_id": name_or_path,
        "name": name_or_path,
        "frames": [],
        "frame_interval_s": 1.0,
        "n_vessels": 0,
        "geofences": [],
        "events": [],
    };
}


# ---------------------------------------------------------------------------
# Speed validation. A plain function rather than a property setter -- Jac
# nodes don't have Python-style ``@speed.setter`` decorators, so the guard
# that used to live in the setter is a function every mutator calls through.
# ---------------------------------------------------------------------------

def set_speed(rc: ReplayCursor, value: float) -> None {
    """Validate and install a new speed. Raises on non-positive values, same
    as the ``@speed.setter`` in replay.py.""";
    v = float(value);
    if v <= 0.0 {
        raise ValueError(f"speed must be positive, got {v}");
    }
    rc.speed = v;
}


# ---------------------------------------------------------------------------
# Read-only properties, restated as functions over the node
# ---------------------------------------------------------------------------

def n_frames(rc: ReplayCursor) -> int {
    return len(rc.scenario["frames"]);
}


def finished(rc: ReplayCursor) -> bool {
    return rc.cursor >= n_frames(rc);
}


def cursor_of(rc: ReplayCursor) -> int {
    """Index of the next frame ``play``/``step`` will emit.""";
    return rc.cursor;
}


# ---------------------------------------------------------------------------
# Control: seek / reset / step -- all O(1), no traversal needed
# ---------------------------------------------------------------------------

def seek(rc: ReplayCursor, frame_idx: int) -> dict {
    """Jump the cursor. Instant: frames are pre-materialised, nothing is
    re-parsed. Returns the frame at the new cursor.""";
    total = n_frames(rc);
    if not (0 <= frame_idx and frame_idx < total) {
        raise IndexError(f"frame {frame_idx} out of range [0, {total})");
    }
    rc.cursor = frame_idx;
    return rc.scenario["frames"][frame_idx];
}


def reset(rc: ReplayCursor) -> None {
    """Rewind to the start. No I/O, no parsing.""";
    rc.cursor = 0;
}


def step(rc: ReplayCursor) -> dict {
    """Emit the next frame immediately (no pacing), or an empty dict when
    finished -- Jac has no ``Optional`` return here, so an empty dict stands
    in for ``None``.""";
    if finished(rc) {
        return {};
    }
    frame = rc.scenario["frames"][rc.cursor];
    rc.cursor = rc.cursor + 1;
    return frame;
}


# ---------------------------------------------------------------------------
# The pacing walker -- one traversal drains the cursor to the end
# ---------------------------------------------------------------------------

walker Pacer {
    """Walk a ``ReplayCursor`` from wherever it currently sits to the end,
    yielding frames paced by wall clock.

    With ``realtime=True`` the gap between yields is
    ``frame_interval_s / speed`` (``rc.speed`` is re-read every frame, so
    changing it mid-flight takes effect immediately, exactly as the Python
    generator re-reads ``self._speed`` on every iteration). With
    ``realtime=False`` frames are drained as fast as possible, for tests and
    benchmarks.
    """;
    has realtime: bool = True;
    has emitted: list = [];

    can drain with ReplayCursor entry {
        interval = here.scenario["frame_interval_s"];
        while not finished(here) {
            start = time.monotonic();
            frame = here.scenario["frames"][here.cursor];
            here.cursor = here.cursor + 1;
            self.emitted.append(frame);
            if self.realtime and not finished(here) {
                delay = interval / here.speed - (time.monotonic() - start);
                if delay > 0 {
                    time.sleep(delay);
                }
            }
        }
    }
}


def play(rc: ReplayCursor, realtime: bool = True) -> list {
    """Drive one ``Pacer`` traversal over ``rc`` and return every frame it
    emitted, in order -- the Jac-side equivalent of iterating
    ``engine.play(realtime=...)`` to exhaustion.""";
    w = rc spawn Pacer(realtime=realtime);
    return w.emitted;
}


# ---------------------------------------------------------------------------
# Smoke-run helpers -- mirror of replay.py's ``_main``
# ---------------------------------------------------------------------------

def measurement_count(rc: ReplayCursor) -> int {
    """Total measurements across every materialised frame.""";
    total = 0;
    for f in rc.scenario["frames"] {
        total = total + len(f["measurements"]);
    }
    return total;
}


def radar_measurement_count(rc: ReplayCursor) -> int {
    """Total measurements whose source is radar, across every frame -- the
    same filtered count ``_main`` prints alongside the raw total.""";
    total = 0;
    for f in rc.scenario["frames"] {
        for m in f["measurements"] {
            if m["source"] == "radar" {
                total = total + 1;
            }
        }
    }
    return total;
}


def fence_ids(rc: ReplayCursor) -> list {
    """Fence ids attached to the scenario, in load order.""";
    out = [];
    for fence in rc.scenario["geofences"] {
        out.append(fence["fence_id"]);
    }
    return out;
}


def event_summary(rc: ReplayCursor) -> list {
    """(t, kind, actor) triples for every scripted event in the pack, the
    same shape ``_main`` prints under the ``events`` line.""";
    out = [];
    for e in rc.scenario["events"] {
        out.append((e["t"], e["kind"], e["actor"]));
    }
    return out;
}


def smoke_run(name_or_path: str, speed: float = 60.0, realtime: bool = False) -> dict {
    """Load a pack, touch the acceptance-relevant numbers, dry-run a full
    replay, and report timings -- a faithful restatement of replay.py's
    ``_main``, minus the argparse/print plumbing which belongs to a CLI
    entry point, not to this module.""";

    t_load = time.perf_counter();
    rc = from_pack(name_or_path, speed);
    load_s = time.perf_counter() - t_load;

    mid = n_frames(rc) // 2;
    t_seek = time.perf_counter();
    if n_frames(rc) > 0 {
        seek(rc, mid);
    }
    reset(rc);
    seek_reset_us = (time.perf_counter() - t_seek) * 1e6;

    t_run = time.perf_counter();
    frames = play(rc, realtime=realtime);
    run_s = time.perf_counter() - t_run;

    return {
        "pack_id": rc.scenario["pack_id"],
        "name": rc.scenario["name"],
        "load_s": load_s,
        "n_frames": n_frames(rc),
        "n_vessels": rc.scenario["n_vessels"],
        "n_measurements": measurement_count(rc),
        "n_radar": radar_measurement_count(rc),
        "fences": fence_ids(rc),
        "events": event_summary(rc),
        "seek_reset_us": seek_reset_us,
        "frames_emitted": len(frames),
        "run_s": run_s,
        "speed": speed,
        "realtime": realtime,
    };
}


with entry:__main__ {
    print("=== sentinel-isr :: replay engine (shadow) ===");
    report = smoke_run("demo_pack", speed=60.0, realtime=False);
    print(f"pack        {report['pack_id']} -- {report['name']}");
    print(f"load        {report['load_s']:.2f} s ({report['n_frames']} frames)");
    print(f"vessels     {report['n_vessels']}  measurements {report['n_measurements']} "
          + f"({report['n_radar']} radar)");
    print(f"geofences   {report['fences']}");
    print(f"events      {report['events']}");
    print(f"seek+reset  {report['seek_reset_us']:.0f} us");
    print(f"full replay {report['run_s']:.3f} s, {report['frames_emitted']} frames, "
          + f"speed x{report['speed']}");
}
