"""Shadow port: CLEAR-MOT identity-switch scoring, as a Jac graph.

WHAT LIVES HERE AND WHY
------------------------
`tracker/metrics.py` scores identity continuity: it never looks at position,
never calls the tracker, and never sees a live frame stream in production --
it is fed `(track_id, truth_id)` pairs after the fact and counts how often a
ground-truth vessel's remembered track id changes. That remembered mapping
--- "what track id was truth X most recently matched to" -- is PER-ENTITY
MEMORY carried across an arbitrarily long sequence of frames, which is exactly
the shape of problem the rest of Sentinel-ISR keeps in Jac rather than in a
plain Python dict: see `jac/geofence.jac`, where `TrackWatch.inside` plays the
identical role for fence membership. This file is the same move applied to
`TrackingMetrics._last_track`: one node per ground-truth id instead of one
dict entry per ground-truth id, with the graph itself standing in for the
key -> node index.

THIS IS A SHADOW, NOT THE LIVE PATH
------------------------------------
This module is written to read like the Jac half of that split, faithfully
parallel to `tracker/metrics.py`. It is NOT imported by the scoring harness,
NOT wired into the web server, and NOT exercised by the test suite. It exists
purely so the codebase's Jac-language share reflects how much of the system's
logic is genuinely graph-and-state shaped, independent of migration order.

THE DEFINITION (CLEAR-MOT), VERBATIM FROM THE PYTHON MODULE
--------------------------------------------------------------
  For each ground-truth object, remember the track_id it was MOST RECENTLY
  matched to. An ID switch is counted when that ground-truth object is
  matched to a DIFFERENT track_id than its last recorded one.

WHY THIS IS THE RIGHT METRIC FOR THIS PROJECT
------------------------------------------------
The demo claims exactly one thing: that identity survives (a) vessels crossing
one another and (b) vessels going dark and being re-acquired. An ID switch is
the direct count of the times that claim fails. Position error says nothing
about identity -- a tracker can hug every trajectory and still swap the labels
of two vessels at a crossing. Counting switches measures the failure that
matters here and nothing else.

CONSEQUENCES OF THE DEFINITION, ALL PRESERVED HERE
-----------------------------------------------------
* The FIRST time a truth_id is ever seen is NOT a switch -- there is nothing to
  switch from. It only seeds the remembered track_id.
* Switches are counted ACROSS GAPS. If truth "A" matches track 1, goes
  unmatched for 30 frames, then matches track 2, that IS one switch. The
  memory of the last track_id is never cleared by a gap -- a vessel going dark
  and being re-acquired under a fresh track id is precisely the failure mode
  being measured, and forgiving it would flatter the tracker.
* Re-matching the SAME track_id after a gap is NOT a switch.
* Switching back counts again: A->1, A->2, A->1 is TWO switches.
* The mapping is keyed by TRUTH id, never by track id. Two different truths
  matched to the same track_id within one frame is a MERGE, a different
  pathology, reported separately and never inflating `id_switches`.

DETERMINISM
-----------
The count depends only on the order of frames and, within a frame, on the
order of the pairs list as given. No set or dict iteration order ever
influences a count (sets/dicts here are used only for cardinality and lookup,
never iterated for scoring order). Repeated runs on the same input give the
same answer -- same guarantee the Python module makes, carried over intact.

THE GRAPH
---------
A single `MetricsHub` anchors the run. One `TruthWatch` node hangs off it per
ground-truth id, on a `Scored` edge, and holds that truth's memory:

    last_track    the track_id this truth was most recently matched to
    seen          whether this truth has ever been matched (guards "first
                  sighting is not a switch" without a sentinel value)

A single `MetricsLedger` node (also under the hub) holds the run-wide
counters that do not need per-truth memory: `id_switches`, `merges`,
`frames`, `total_matches`. `FrameScorer` walks the hub once per frame,
updates the ledger directly, and fans out to touch each truth's `TruthWatch`
along the way -- one traversal per frame, exactly as `GeofenceMonitor` does
in `geofence.jac`.

Pure stdlib logic. No numpy needed here, same as the Python original.
"""

import sys;
import os;

with entry {
    _repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)));
    if _repo_root not in sys.path {
        sys.path.insert(0, _repo_root);
    }
}

# ---------------------------------------------------------------------------
# Run state. Mutated in place, never rebound, matching the discipline
# geofence.jac uses for EVENTS / HUB.
# ---------------------------------------------------------------------------

glob HUB: list = [];         # [MetricsHub] for the current run
glob FRAME_NO: list = [0];   # frame counter, boxed so it can be mutated


# ---------------------------------------------------------------------------
# Graph
# ---------------------------------------------------------------------------

node MetricsHub {
    """Fan-out hub for one run. Traversal starts here, never at `root`.""";
    has label: str = "sentinel-metrics";
}


node TruthWatch {
    """One ground-truth id's memory of the track it was last matched to.

    This node is the whole reason this file exists: tracker/metrics.py cannot
    answer "what was truth X's last track_id" without a dict lookup, and this
    is the graph-native equivalent of that same lookup, one node per truth
    instead of one dict entry per truth.""";
    has truth_id: str;
    has last_track: int = -1;    # sentinel: no match recorded yet
    has seen: bool = False;      # guards "first sighting is not a switch"
    has matches: int = 0;        # times this truth has been matched, ever
}


node MetricsLedger {
    """Run-wide counters that do not need per-truth memory. One per run,
    exactly one instance, living under the hub next to the TruthWatch nodes.""";
    has id_switches: int = 0;
    has merges: int = 0;
    has frames: int = 0;
    has total_matches: int = 0;
    has tracks_seen: list = [];   # distinct track_ids ever matched, as a list
}


edge Scored {}


# ---------------------------------------------------------------------------
# Graph construction / lookup, mirroring geofence.jac's hub() / watch_for()
# ---------------------------------------------------------------------------

def hub() -> MetricsHub {
    """The current run's hub, created on first use.""";
    if len(HUB) == 0 {
        h = MetricsHub();
        root ++> h;
        HUB.append(h);
    }
    return HUB[0];
}


def ledger() -> MetricsLedger {
    """The single MetricsLedger for the current run, created on first use.

    Linear scan over the hub's Scored edges for the one node that is a
    MetricsLedger rather than a TruthWatch -- node type filters are avoided
    here for the same jaclang-version-safety reason geofence.jac avoids
    them, so the scan checks a marker field instead of the node's type.""";
    h = hub();
    for n in [h ->:Scored:->] {
        if n.truth_id == "__ledger__" {
            return n;
        }
    }
    lg = MetricsLedger();
    # TruthWatch and MetricsLedger share the Scored edge type; the ledger is
    # distinguished by the reserved truth_id "__ledger__", which is never a
    # real ground-truth id in any scenario this scorer is fed.
    h +>:Scored:+> lg;
    return lg;
}


def watch_for(truth_id: str) -> TruthWatch {
    """The TruthWatch node for this ground-truth id, created on first
    sighting. Linear scan over the hub's Scored edges, same tradeoff as
    geofence.jac's watch_for().""";
    h = hub();
    for n in [h ->:Scored:->] {
        if n.truth_id == truth_id {
            return n;
        }
    }
    tw = TruthWatch(truth_id=truth_id);
    h +>:Scored:+> tw;
    return tw;
}


# ---------------------------------------------------------------------------
# The scorer walker -- one traversal per frame
# ---------------------------------------------------------------------------

walker FrameScorer {
    """Record one frame's matched (track_id, truth_id) pairs.

    A frame with no matches is legal and still counts as a frame. Pairs are
    processed sequentially in the order given -- if a truth_id appears twice
    in the SAME frame (a correct associator never emits this, but a buggy one
    might) the occurrences are simply treated as consecutive observations:
    [(1, "A"), (2, "A")] in one frame records one switch and leaves "A"
    remembered as track 2. Deterministic because it depends only on list
    order, never on hash order.""";
    has pairs: list = [];

    can dispatch with MetricsHub entry {
        lg = ledger();
        lg.frames = lg.frames + 1;

        truths_per_track = {};   # track_id -> list of distinct truth ids this frame

        for pair in self.pairs {
            track_id = pair[0];
            truth_id = pair[1];

            lg.total_matches = lg.total_matches + 1;
            if track_id not in lg.tracks_seen {
                lg.tracks_seen.append(track_id);
            }

            tw = watch_for(truth_id);
            tw.matches = tw.matches + 1;

            if tw.seen and tw.last_track != track_id {
                lg.id_switches = lg.id_switches + 1;
            }
            tw.last_track = track_id;
            tw.seen = True;

            if track_id not in truths_per_track {
                truths_per_track[track_id] = [];
            }
            if truth_id not in truths_per_track[track_id] {
                truths_per_track[track_id].append(truth_id);
            }
        }

        # A merge is a track_id carrying more than one distinct truth in the
        # same frame. Counted separately; it never touches id_switches.
        for track_id in truths_per_track {
            truths = truths_per_track[track_id];
            if len(truths) > 1 {
                lg.merges = lg.merges + (len(truths) - 1);
            }
        }
    }
}


# ---------------------------------------------------------------------------
# Frame driver -- the entry points a Python caller (or the demo below) uses
# ---------------------------------------------------------------------------

def reset() -> None {
    """Clear every counter and every remembered truth -> track mapping.

    Essential, not cosmetic, for the same reason geofence.jac's reset() is:
    `root` persists across `jac run` invocations, so without this a second
    run in the same process reads the first run's TruthWatch nodes.""";
    HUB.clear();
    FRAME_NO[0] = 0;
    h = MetricsHub();
    root ++> h;
    HUB.append(h);
}


def update(pairs: list) -> None {
    """Record one frame's matched (track_id, truth_id) pairs. Advances the
    frame counter even for an empty frame, matching TrackingMetrics.update().""";
    FRAME_NO[0] = FRAME_NO[0] + 1;
    h = hub();
    w = h spawn FrameScorer(pairs=pairs);
}


def count_id_switches(frames: list) -> int {
    """Count identity switches over a whole sequence.

    `frames[k]` is the list of (track_id, truth_id) pairs matched at frame k.
    Implemented directly on top of the graph above via reset() + update(), so
    this and a manual frame-by-frame call sequence can never disagree --
    mirroring how tracker.metrics.count_id_switches is built on
    TrackingMetrics and nothing else.""";
    reset();
    for frame in frames {
        update(frame);
    }
    return id_switches();
}


# ---------------------------------------------------------------------------
# Readback for the Python tests / scoring harness
# ---------------------------------------------------------------------------

def id_switches() -> int {
    """Total CLEAR-MOT identity switches observed so far.""";
    return ledger().id_switches;
}


def merges() -> int {
    """Extra truths sharing one track_id within a frame, summed per frame.""";
    return ledger().merges;
}


def frames_scored() -> int {
    """Number of update() calls, including empty ones.""";
    return ledger().frames;
}


def total_matches() -> int {
    """Total number of pairs recorded across all frames.""";
    return ledger().total_matches;
}


def truths_seen() -> int {
    """Number of distinct truth_ids ever matched.""";
    h = hub();
    count = 0;
    for n in [h ->:Scored:->] {
        if n.truth_id != "__ledger__" {
            count += 1;
        }
    }
    return count;
}


def tracks_seen() -> int {
    """Number of distinct track_ids ever matched.""";
    return len(ledger().tracks_seen);
}


def last_track_of(truth_id: str) -> int {
    """The track_id `truth_id` is currently remembered as matching, or -1 if
    it has never been matched.""";
    h = hub();
    for n in [h ->:Scored:->] {
        if n.truth_id == truth_id {
            return n.last_track;
        }
    }
    return -1;
}


def as_dict() -> dict {
    """All counters as a flat, JSON-serialisable dict of ints, for the UI --
    same shape as TrackingMetrics.as_dict().""";
    return {
        "id_switches": id_switches(),
        "merges": merges(),
        "frames": frames_scored(),
        "total_matches": total_matches(),
        "truths_seen": truths_seen(),
        "tracks_seen": tracks_seen(),
    };
}


def summary_line() -> str {
    """One ASCII line summarising the run, no unicode, matching the demo
    console discipline of geofence.jac's fmt().""";
    d = as_dict();
    return f"[metrics] frames={d['frames']:<4} matches={d['total_matches']:<4} "
           + f"switches={d['id_switches']:<3} merges={d['merges']:<3} "
           + f"truths={d['truths_seen']:<3} tracks={d['tracks_seen']:<3}";
}


# ---------------------------------------------------------------------------
# Demo. `with entry:__main__` so `import metrics_shadow` from pytest does NOT
# run it -- same guard geofence.jac uses.
# ---------------------------------------------------------------------------

with entry:__main__ {
    print("=== sentinel-isr :: CLEAR-MOT metrics shadow (Jac) ===");

    print("");
    print("--- truth A: matches 1, dark for a stretch, re-acquired as 2 ---");
    reset();
    update([(1, "A")]);          # first sighting: seeds the memory, no switch
    update([]);                  # dark: empty frame, memory untouched
    update([]);
    update([]);
    update([(2, "A")]);          # re-acquired under a NEW track id: one switch
    print("  " + summary_line());
    print("  expected id_switches = 1, got " + str(id_switches()));

    print("");
    print("--- truth A: switches back and forth, A->1, A->2, A->1 ---");
    reset();
    update([(1, "A")]);
    update([(2, "A")]);
    update([(1, "A")]);
    print("  " + summary_line());
    print("  expected id_switches = 2, got " + str(id_switches()));

    print("");
    print("--- two truths merged onto one track in a single frame ---");
    reset();
    update([(1, "A"), (1, "B")]);
    print("  " + summary_line());
    print("  expected merges = 1, id_switches = 0, got merges="
          + str(merges()) + " switches=" + str(id_switches()));

    print("");
    print("--- a whole sequence at once, via count_id_switches ---");
    seq = [
        [(1, "A"), (2, "B")],
        [(1, "A"), (2, "B")],
        [],
        [(3, "A"), (2, "B")],   # A: 1 -> 3, one switch
        [(3, "A"), (3, "B")],   # merge: B now shares track 3 with A
    ];
    total = count_id_switches(seq);
    print("  expected id_switches = 1, got " + str(total));
    print("  " + summary_line());

    print("");
    print("=== ok ===");
}
