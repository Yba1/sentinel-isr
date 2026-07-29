"""Phase 3.5: geofence intrusion, as a Jac graph.

WHAT LIVES HERE AND WHY
-----------------------
Sentinel-ISR splits every phase the same way: numerical kernels in Python,
*state and rules* in Jac. Phase 3.5 is the cleanest example of that split so far.

`tracker/geofence.py` owns exactly one question, and it is a geometry question:
"given this point, right now, which fences contain it?" That is shapely, an
STRtree, and nothing else. It is STATELESS -- it has no idea what happened last
frame, and it never will.

This file owns everything that depends on *time*. A geofence alert is not a
point-in-polygon test; it is a TRANSITION. A vessel sitting inside Monterey Bay
NMS for fifty frames is fifty successful point-in-polygon tests and exactly ONE
event. Turning a stream of stateless answers into a stream of transitions needs
per-track memory, and per-track memory with a walker over it is what Jac is for:
each track is a node, the monitor is a walker, and one traversal per frame
updates every track and emits every event.

The narrative this buys is the whole point of the phase. "Vessel went dark" is a
sensor dropout. "Vessel went dark INSIDE a marine protected area" is illegal
fishing. Same AIS gap, different story, and the difference is entirely a
question of state this file holds and the geometry module does not.

THE MODEL
---------
A single `Watchtower` hub node anchors the run. One `TrackWatch` node hangs off
it per track, on a `Watching` edge, and holds that track's memory:

    inside  the sorted fence ids the track was in AS OF THE LAST FRAME
    dark    whether AIS was silent as of the last frame
    fired   which fences have already produced a compound alert during the
            CURRENT dark episode

`GeofenceMonitor` walks the hub, fans out over the `Watching` edges, and on each
`TrackWatch` diffs this frame's observation against those three fields. Nothing
is a dict keyed by track id; the graph IS the index.

TRANSITION RULES
----------------
  outside -> inside   geofence_enter                 (once)
  inside  -> outside  geofence_exit                  (once)
  still inside        nothing at all
  light -> dark, outside every fence   ais_dark      (ordinary event)
  dark, and inside a fence not yet fired this episode
                      dark_inside_protected_area     (THE COMPOUND ONE)
  dark -> light       ais_resume, and the fired set is cleared

The compound rule is stated as a condition on the (track, fence, dark-episode)
triple rather than as a reaction to one specific transition, and that is
deliberate: it covers "went dark while already inside" AND "wandered in while
already dark" with the same line of code, fires once in both, and re-arms
correctly when the vessel resurfaces and goes dark a second time. A plain
`geofence_enter` is NEVER suppressed by darkness -- enter means enter, so the
"exactly one enter" invariant stays testable without dragging AIS state into it.

Leaving a fence drops it from `fired` too, so leave-and-re-enter while still
dark alerts again. That is the right call operationally: it is a new intrusion.

SEVERITY
--------
An ordered scale, info < warning < critical < emergency, with the rank carried
as an integer ON the event so a test can assert strict ordering instead of
comparing strings. The rule table below is data, in Jac, not code: entering an
`mpa` is a warning where entering a `port` is merely info, and going dark inside
an `mpa` is an emergency where going dark inside a `port` is critical. The one
invariant the table must satisfy, for EVERY fence kind, is
`dark_inside_severity(kind) > enter_severity(kind)`, strictly.

DRIVING IT FROM PYTHON
----------------------
    import jaclang                      # installs the .jac meta importer
    sys.path.insert(0, "jac")
    import geofence as gf

    gf.set_index(GeofenceIndex([...]))  # fences in LOCAL ENU METRES
    gf.reset()
    gf.ingest_frame(["V-77"], [[5000.0, 10000.0]], ["V-77"])
    gf.events()

Coordinates are LOCAL ENU METRES everywhere, never lon/lat.
"""

import sys;
import os;

# `jac run` puts the .jac file's OWN directory on sys.path, not the repo root.
# Jac executes top-level statements in source order (imports are NOT hoisted
# above entry blocks), so this bootstrap runs before the tracker import below.
# Verified to work both under `jac run` and under jaclang's meta importer, where
# `__file__` is also set.
with entry {
    _repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)));
    if _repo_root not in sys.path {
        sys.path.insert(0, _repo_root);
    }
}

import from tracker.geofence { GeofenceIndex, polygon_fence, corridor_fence }


# ---------------------------------------------------------------------------
# Severity. Globals rather than walker fields: this is scenario configuration,
# and the tests read the tables by name to prove the ordering invariant holds
# for every fence kind rather than just for the one the demo happens to use.
# ---------------------------------------------------------------------------

glob SEV_RANK: dict = {"info": 0, "warning": 1, "critical": 2, "emergency": 3};

# Crossing a fence line. An mpa or a live cable corridor is a real finding; a
# port boundary is routine traffic and only worth an info line.
glob ENTER_SEV: dict = {
    "mpa": "warning",
    "danger": "warning",
    "cable": "warning",
    "port": "info"
};

# Going dark inside one. Every entry here outranks its ENTER_SEV counterpart,
# which is the invariant that makes the compound event mean something.
glob DARK_INSIDE_SEV: dict = {
    "mpa": "emergency",
    "danger": "critical",
    "cable": "critical",
    "port": "critical"
};

glob EXIT_SEV: str = "info";
glob DARK_OUTSIDE_SEV: str = "warning";
glob NO_FENCE: str = "";        # geofence_id for events with no fence

# Run state. Mutated in place, never rebound, so Python keeps live references to
# the same objects (the same discipline hypothesis.jac uses for LOG / ROOTS).
glob EVENTS: list = [];         # every emitted event dict, in order
glob HUB: list = [];            # [Watchtower] for the CURRENT run
glob INDEX: list = [];          # [GeofenceIndex] -- the Python geometry oracle
glob FRAME_NO: list = [0];      # frame counter, boxed so it can be mutated

# `root` is PERSISTED to .jac/data/*.db across `jac run` invocations, so anything
# reachable from it accumulates run over run. Every traversal here starts from
# HUB[0], which is process-local and rebuilt by reset().


# ---------------------------------------------------------------------------
# Graph
# ---------------------------------------------------------------------------

node Watchtower {
    """Fan-out hub for one run. Traversal starts here, never at `root`."""
    has label: str = "sentinel";
}


node TrackWatch {
    """One track's memory of the last frame. This is the whole point of the file:
    tracker/geofence.py cannot answer any question that needs these three fields.
    """
    has track_id: str;
    has inside: list = [];      # sorted fence ids, as of the last frame
    has dark: bool = False;     # AIS silent, as of the last frame
    has fired: list = [];       # fences already alerted this dark episode
    has frames_seen: int = 0;
}


edge Watching {}


# ---------------------------------------------------------------------------
# Severity helpers
# ---------------------------------------------------------------------------

def severity_rank(sev: str) -> int {
    """Numeric rank on the info < warning < critical < emergency scale.

    Exposed at module level so a test can assert strict ordering between two
    severities without hard-coding the table.""";
    if sev in SEV_RANK {
        return SEV_RANK[sev];
    }
    return 0;
}


def enter_severity(kind: str) -> str {
    """Severity of crossing INTO a fence of this kind.""";
    if kind in ENTER_SEV {
        return ENTER_SEV[kind];
    }
    return "warning";
}


def dark_inside_severity(kind: str) -> str {
    """Severity of going dark inside a fence of this kind. Strictly outranks
    enter_severity(kind) for every kind in the table -- that is the invariant.""";
    if kind in DARK_INSIDE_SEV {
        return DARK_INSIDE_SEV[kind];
    }
    return "critical";
}


# ---------------------------------------------------------------------------
# Fence metadata. Read through GeofenceIndex.get() only -- the Python module is
# the single source of truth for what a fence IS, this file only remembers what
# a track DID about it.
# ---------------------------------------------------------------------------

def fence_kind(fid: str) -> str {
    if len(INDEX) == 0 {
        return "mpa";
    }
    f = INDEX[0].get(fid);
    if f is None {
        return "mpa";
    }
    return f.kind;
}


def fence_label(fid: str) -> str {
    if len(INDEX) == 0 {
        return fid;
    }
    f = INDEX[0].get(fid);
    if f is None {
        return fid;
    }
    return f.label;
}


# ---------------------------------------------------------------------------
# Event emission. One choke point, so EVENTS is a faithful ordered log.
# ---------------------------------------------------------------------------

def emit(kind_of_event: str, actor: str, fid: str, sev: str, detail: str) -> dict {
    """Append one event to the ordered log and return it.

    `severity_rank` rides along in the dict so a caller can compare two events
    numerically without re-deriving the scale.""";
    ev = {
        "type": kind_of_event,
        "actor": actor,
        "geofence_id": fid,
        "severity": sev,
        "severity_rank": severity_rank(sev),
        "detail": detail,
        "frame": FRAME_NO[0]
    };
    EVENTS.append(ev);
    return ev;
}


def fmt(ev: dict) -> str {
    """One ASCII log line. No unicode -- the demo has to print on a cp1252
    Windows console without raising UnicodeEncodeError.""";
    return f"[geofence] f{ev['frame']:02d} {ev['severity'].upper():<9} "
           + f"{ev['type']:<26} {ev['actor']:<6} {ev['detail']}";
}


# ---------------------------------------------------------------------------
# Graph construction / lookup. Lookup is a traversal over Watching edges, not a
# dict: the brief for this phase is that the watch set IS graph structure.
# ---------------------------------------------------------------------------

def hub() -> Watchtower {
    """The current run's hub, created on first use.""";
    if len(HUB) == 0 {
        h = Watchtower();
        root ++> h;             # anchor in the persistent graph
        HUB.append(h);
    }
    return HUB[0];
}


def watch_for(track_id: str) -> TrackWatch {
    """The TrackWatch node for this track, created on first sighting.

    Linear scan over the hub's Watching edges. Node type filters are broken in
    jaclang 0.16.7 (`(?Type)` is an internal compiler error), but the graph is
    typed per-edge -- following Watching can only ever reach TrackWatch -- so no
    filter is needed.""";
    h = hub();
    for w in [h ->:Watching:->] {
        if w.track_id == track_id {
            return w;
        }
    }
    tw = TrackWatch(track_id=track_id);
    h +>:Watching:+> tw;
    return tw;
}


# ---------------------------------------------------------------------------
# The monitor walker -- one traversal per frame
# ---------------------------------------------------------------------------

walker GeofenceMonitor {
    """Diff this frame's observation against every track's remembered state.

    `frame` maps track_id -> [sorted fence ids this frame, dark this frame].
    A track absent from `frame` was not observed and is left completely
    untouched: a missing observation is not evidence that it left a fence.
    """
    has frame: dict = {};
    has emitted: list = [];

    can dispatch with Watchtower entry {
        visit [->:Watching:->];
    }

    can check with TrackWatch entry {
        if here.track_id not in self.frame {
            return;
        }

        obs = self.frame[here.track_id];
        now_ids = sorted(obs[0]);
        now_dark = obs[1];
        was_ids = here.inside;
        was_dark = here.dark;
        here.frames_seen = here.frames_seen + 1;

        # -- 1. EXITS. Before enters, so that a track which swaps one fence for
        #       another in a single frame reports the departure first.
        for fid in was_ids {
            if fid not in now_ids {
                kind = fence_kind(fid);
                self.log(
                    "geofence_exit", here.track_id, fid, EXIT_SEV,
                    f"{here.track_id} left {fence_label(fid)} ({kind})"
                );
                # Re-arm: coming back in is a NEW intrusion, even if the vessel
                # never turned its transponder back on.
                if fid in here.fired {
                    here.fired.remove(fid);
                }
            }
        }

        # -- 2. ENTERS. One per fence, so a track inside two overlapping fences
        #       produces two events rather than one merged one. Never suppressed
        #       or upgraded by darkness -- the compound rule below is separate.
        for fid in now_ids {
            if fid not in was_ids {
                kind = fence_kind(fid);
                self.log(
                    "geofence_enter", here.track_id, fid, enter_severity(kind),
                    f"{here.track_id} entered {fence_label(fid)} ({kind})"
                );
            }
        }

        here.inside = now_ids;

        # -- 3. AIS TRANSITIONS.
        if now_dark and not was_dark {
            # Going dark OUTSIDE every fence is an ordinary event. Going dark
            # inside one is handled by step 4 and is NOT an ais_dark.
            if len(now_ids) == 0 {
                self.log(
                    "ais_dark", here.track_id, NO_FENCE, DARK_OUTSIDE_SEV,
                    f"{here.track_id} stopped transmitting AIS in open water"
                );
            }
        }
        if was_dark and not now_dark {
            self.log(
                "ais_resume", here.track_id, NO_FENCE, "info",
                f"{here.track_id} resumed AIS"
            );
            # New episode: every fence is alertable again.
            here.fired = [];
        }
        here.dark = now_dark;

        # -- 4. THE COMPOUND EVENT. Stated as a condition on the state pair
        #       (inside AND dark), not as a reaction to one transition, so it
        #       covers "went dark while inside" and "drifted in while dark"
        #       identically -- and `fired` makes it once per dark episode.
        if now_dark {
            for fid in now_ids {
                if fid not in here.fired {
                    here.fired.append(fid);
                    kind = fence_kind(fid);
                    self.log(
                        "dark_inside_protected_area", here.track_id, fid,
                        dark_inside_severity(kind),
                        f"{here.track_id} went dark INSIDE {fence_label(fid)} ({kind})"
                    );
                }
            }
        }
    }

    def log(kind_of_event: str, actor: str, fid: str, sev: str, detail: str) -> None {
        """Record on the global log and on this traversal's own list, so a caller
        can ask either 'everything so far' or 'just this frame'.""";
        ev = emit(kind_of_event, actor, fid, sev, detail);
        self.emitted.append(ev);
    }
}


# ---------------------------------------------------------------------------
# Frame driver -- the entry point Python calls
# ---------------------------------------------------------------------------

def set_index(idx: GeofenceIndex) -> None {
    """Install the Python geometry oracle. Not cleared by reset(), so the order
    of the two calls does not matter.""";
    INDEX.clear();
    INDEX.append(idx);
}


def reset() -> None {
    """Start a fresh run: new hub, empty event log, frame counter back to zero.

    Essential, not cosmetic. Globals live for the whole process and `root` is
    persisted to disk between `jac run` invocations, so without this the second
    test in a pytest session would read the first test's events.""";
    EVENTS.clear();
    HUB.clear();
    FRAME_NO[0] = 0;
    h = Watchtower();
    root ++> h;
    HUB.append(h);
}


def ingest_frame(track_ids: list, points: list, dark_ids: list = []) -> list {
    """Advance every track by one frame. Returns the events emitted THIS frame.

    `points` is one [x, y] in LOCAL ENU METRES per entry of `track_ids`, in the
    same order. `dark_ids` lists the tracks whose AIS is silent this frame.

    The only call into Python geometry is `query_many`, and it is a batch call:
    one STRtree query for the whole frame rather than one per track.""";
    FRAME_NO[0] = FRAME_NO[0] + 1;

    per_point = [];
    if len(INDEX) > 0 and len(points) > 0 {
        per_point = INDEX[0].query_many(points);
    } else {
        for p in points {
            per_point.append([]);
        }
    }

    frame = {};
    i = 0;
    for tid in track_ids {
        fids = [];
        if i < len(per_point) {
            fids = list(per_point[i]);
        }
        is_dark = tid in dark_ids;
        frame[tid] = [fids, is_dark];
        watch_for(tid);         # make sure the node exists before the traversal
        i += 1;
    }

    h = hub();
    w = h spawn GeofenceMonitor(frame=frame);
    return w.emitted;
}


# ---------------------------------------------------------------------------
# Readback for the Python tests / scoring harness
# ---------------------------------------------------------------------------

def events() -> list {
    return list(EVENTS);
}


def event_count() -> int {
    return len(EVENTS);
}


def event_types() -> list {
    out = [];
    for ev in EVENTS {
        out.append(ev["type"]);
    }
    return out;
}


def events_of_type(t: str) -> list {
    out = [];
    for ev in EVENTS {
        if ev["type"] == t {
            out.append(ev);
        }
    }
    return out;
}


def events_for(actor: str) -> list {
    out = [];
    for ev in EVENTS {
        if ev["actor"] == actor {
            out.append(ev);
        }
    }
    return out;
}


def count_of_type(t: str) -> int {
    return len(events_of_type(t));
}


def inside_of(track_id: str) -> list {
    """The fence ids `track_id` is currently believed to be inside.""";
    h = hub();
    for w in [h ->:Watching:->] {
        if w.track_id == track_id {
            return list(w.inside);
        }
    }
    return [];
}


def is_dark(track_id: str) -> bool {
    h = hub();
    for w in [h ->:Watching:->] {
        if w.track_id == track_id {
            return w.dark;
        }
    }
    return False;
}


def watch_count() -> int {
    """Number of tracks under watch in the CURRENT run. Counted off HUB[0], not
    off `root`, so it is not inflated by previous `jac run` invocations.""";
    h = hub();
    return len([h ->:Watching:->]);
}


def event_lines() -> list {
    out = [];
    for ev in EVENTS {
        out.append(fmt(ev));
    }
    return out;
}


# ---------------------------------------------------------------------------
# Demo. `with entry:__main__` so `import geofence` from pytest does NOT run it.
#
# Geometry, in LOCAL ENU METRES about an origin near 36.80 N, 121.90 W:
#   mbnms     20 km square, the Monterey Bay NMS stand-in           (mpa)
#   elkhorn   a smaller mpa overlapping mbnms's eastern edge        (mpa)
#   trans_pac a buffered cable corridor running north               (cable)
#   moss_port the harbour at the bottom left                        (port)
# ---------------------------------------------------------------------------

with entry:__main__ {
    print("=== sentinel-isr :: phase 3.5 geofence intrusion ===");

    mbnms = polygon_fence(
        "mbnms", "mpa", "Monterey Bay NMS",
        [[0.0, 0.0], [20000.0, 0.0], [20000.0, 20000.0], [0.0, 20000.0]]
    );
    elkhorn = polygon_fence(
        "elkhorn", "mpa", "Elkhorn Slough Reserve",
        [[15000.0, 5000.0], [25000.0, 5000.0], [25000.0, 15000.0], [15000.0, 15000.0]]
    );
    cable = corridor_fence(
        "trans_pac", "Trans-Pacific Cable",
        [[40000.0, 0.0], [40000.0, 30000.0]], 1500.0
    );
    harbour = polygon_fence(
        "moss_port", "port", "Moss Landing Harbour",
        [[-8000.0, -6000.0], [-4000.0, -6000.0], [-4000.0, -2000.0], [-8000.0, -2000.0]]
    );

    idx = GeofenceIndex([mbnms, elkhorn, cable, harbour]);
    set_index(idx);
    print("fences loaded            : " + str(len(idx)));

    # -- Scenario A: the headline. enter -> stay -> stay -> go dark -> exit ----
    print("");
    print("--- V-77 :: enter -> stay -> go dark inside -> exit ---");
    reset();

    ingest_frame(["V-77"], [[-5000.0, 10000.0]]);              # open water
    ingest_frame(["V-77"], [[5000.0, 10000.0]]);               # ENTER
    ingest_frame(["V-77"], [[6000.0, 10000.0]]);               # stay: silence
    ingest_frame(["V-77"], [[7000.0, 10000.0]]);               # stay: silence
    ingest_frame(["V-77"], [[8000.0, 10000.0]], ["V-77"]);     # DARK inside
    ingest_frame(["V-77"], [[9000.0, 10000.0]], ["V-77"]);     # still dark: silence
    ingest_frame(["V-77"], [[-5000.0, 10000.0]], ["V-77"]);    # EXIT

    for line in event_lines() {
        print("  " + line);
    }
    print("  events total           : " + str(event_count())
          + "   (7 frames, 3 events -- the 4 quiet frames say nothing)");

    # -- Scenario B: fifty frames inside. Exactly one enter. ------------------
    print("");
    print("--- V-12 :: 50 consecutive frames inside the sanctuary ---");
    reset();
    ingest_frame(["V-12"], [[-1000.0, 10000.0]]);
    i = 0;
    while i < 50 {
        ingest_frame(["V-12"], [[1000.0 + i * 100.0, 10000.0]]);
        i += 1;
    }
    print("  geofence_enter events  : " + str(count_of_type("geofence_enter"))
          + "   (51 frames in, 1 event out)");
    print("  all events             : " + str(event_types()));

    # -- Scenario C: overlapping fences, one event each -----------------------
    print("");
    print("--- V-31 :: sails into the mbnms / elkhorn overlap ---");
    reset();
    ingest_frame(["V-31"], [[5000.0, 10000.0]]);               # mbnms only
    ingest_frame(["V-31"], [[17000.0, 10000.0]]);              # + elkhorn
    for line in event_lines() {
        print("  " + line);
    }
    print("  currently inside       : " + str(inside_of("V-31")));

    # -- Scenario D: dark in open water is NOT the compound event -------------
    print("");
    print("--- V-05 :: goes dark in open water, twice, with a resume between ---");
    reset();
    ingest_frame(["V-05"], [[-30000.0, -30000.0]]);
    ingest_frame(["V-05"], [[-30000.0, -29000.0]], ["V-05"]);  # dark, outside
    ingest_frame(["V-05"], [[-30000.0, -28000.0]]);            # back
    ingest_frame(["V-05"], [[-30000.0, -27000.0]], ["V-05"]);  # dark again
    for line in event_lines() {
        print("  " + line);
    }
    print("  compound events        : "
          + str(count_of_type("dark_inside_protected_area")) + "   (correctly zero)");

    # -- Scenario E: the severity table, every kind ---------------------------
    print("");
    print("--- severity table: dark-inside strictly outranks enter, per kind ---");
    for k in ["mpa", "danger", "cable", "port"] {
        e = enter_severity(k);
        d = dark_inside_severity(k);
        ok = "ok";
        if severity_rank(d) <= severity_rank(e) {
            ok = "BROKEN";
        }
        print(f"  {k:<7} enter={e:<9}({severity_rank(e)})  "
              + f"dark_inside={d:<10}({severity_rank(d)})  {ok}");
    }

    # -- Scenario F: multi-track frame, one traversal -------------------------
    print("");
    print("--- one frame, three vessels, one walker traversal ---");
    reset();
    ingest_frame(["V-77", "V-31", "V-05"],
                 [[-5000.0, 10000.0], [-5000.0, 10000.0], [-30000.0, -30000.0]]);
    fired = ingest_frame(["V-77", "V-31", "V-05"],
                         [[5000.0, 10000.0], [17000.0, 10000.0], [40000.0, 15000.0]],
                         ["V-31"]);
    for ev in fired {
        print("  " + fmt(ev));
    }
    print("  tracks under watch     : " + str(watch_count()));

    print("");
    print("=== ok ===");
}
