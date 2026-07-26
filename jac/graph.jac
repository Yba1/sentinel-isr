"""Sentinel-ISR graph schema: the mission picture as an object-spatial graph.

Everything the system believes at time t IS this graph: Track nodes are the
fused picture, Zone nodes are the protected geometry, ActorState nodes are the
scenario's per-actor switchboard (AIS on/off, display identity), Alert and
Brief nodes are the operator-facing product, and Contact nodes are the
evidence radar detections that justify claims. Edges carry the relationships
the frontend renders and the judges ask about: which track is inside which
zone (InZone), which alert concerns which track and zone (RaisedOn /
Concerning), and which detections justify which alert (JustifiedBy).

The tracker mathematics never lives here -- a Track node HOLDS a CVKalman
object, it does not reimplement one.
"""

import logging;
import from data.geometry { make_zone_polygon, polygon_contains }

# Walkers legitimately carry plain Python dataclasses (Frame, Measurement)
# across the boundary; the runtime serializer warns it falls back to str()
# for them on every spawn. Nothing here persists, so the fallback is fine
# and the per-frame warning is pure noise.
glob _quiet_serializer = logging.getLogger(
    "jaclang.runtimelib.serializer"
).setLevel(logging.ERROR);

# ------------------------------------------------------------- track lifecycle

glob STATUS_TENTATIVE: str = "tentative";   # born, not yet confirmed
glob STATUS_ACTIVE: str = "active";         # confirmed, receiving measurements
glob STATUS_COASTING: str = "coasting";     # prediction only -- dark or occluded
glob STATUS_DROPPED: str = "dropped";       # coasted too long, retired

glob CONFIRM_HITS: int = 3;        # tentative -> active after this many updates
glob COAST_AFTER_MISSES: int = 2;  # active -> coasting after this many empty frames
# Holding dark tracks long enough to reacquire them IS the product, so the
# coast budget is generous: 60 frames = 30 min at the 30 s frame interval.
glob DROP_AFTER_COAST: int = 60;

# Alert dampers, tuned on real SF Bay traffic where hundreds of vessels have
# ragged AIS coverage. State transitions always happen; ALERTS are reserved
# for tracks with enough history to make "went dark" meaningful, and for
# reacquisitions after a genuine dark period rather than a two-frame gap.
glob DARK_MIN_HITS: int = 6;      # updates required before went_dark alerts
glob REACQ_MIN_COAST: int = 4;    # dark frames required before reacquired alerts


# --------------------------------------------------------------------- nodes

node Mission {
    has pack_id: str = "";
    has name: str = "";
    has frame_interval_s: float = 30.0;
    has frame_idx: int = -1;
    has t: float = 0.0;
    # Mutable machinery that is state-of-the-run rather than state-of-the-world:
    # rng for injection noise, id counters, actor-state cache, pending births.
    has meta: dict = {};
}

node Zone {
    has zone_id: str = "";
    has name: str = "";
    has kind: str = "zone";        # "sanctuary" | "restricted" | ...
    has ring: list = [];           # ENU exterior ring [(x, y), ...]
    has geojson: dict = {};        # original lat/lon feature, verbatim for the map
    has poly: object = None;       # cached shapely polygon (built once)

    def contains(x: float, y: float) -> bool {
        if self.poly is None {
            self.poly = make_zone_polygon(self.ring);
        }
        return polygon_contains(self.poly, x, y);
    }
}

"""Per-actor scenario switchboard. This is REPLAY-side state: the tracker
never sees actors, so nothing here may flow into association."""
node ActorState {
    has actor: str = "";
    has ais_suppressed: bool = False;
    has dark_since: float = -1.0;      # -1 when lit
    has display_id: str = "";          # what the UI would show, post identity_change
}

"""One fused vessel hypothesis. `kf` is Raj's CVKalman; the snapshot fields
mirror kf.state / kf.cov after each frame so the graph (and the renderer)
never reach into filter internals mid-flight."""
node Track {
    has track_id: str = "";
    has kf: object = None;
    has x: float = 0.0;
    has y: float = 0.0;
    has vx: float = 0.0;
    has vy: float = 0.0;
    has p00: float = 0.0;          # position covariance for the ellipse
    has p01: float = 0.0;
    has p11: float = 0.0;
    has status: str = "tentative";
    has hits: int = 0;
    has misses: int = 0;
    has coast_frames: int = 0;
    has born_t: float = 0.0;
    has last_t: float = 0.0;
    has last_source: str = "";     # sensor of the last fused measurement
    has last_meas_id: str = "";
    has zones_in: list = [];       # zone_ids currently containing this track
    has was_dark: bool = False;    # coasted at least once (for reacquire alerts)
}

"""Evidence node: an unlabelled detection worth keeping in the graph --
every injected radar contact, plus any measurement an alert cites."""
node Contact {
    has meas_id: str = "";
    has t: float = 0.0;
    has x: float = 0.0;
    has y: float = 0.0;
    has source: str = "";
    has sigma: float = 0.0;
}

node Alert {
    has alert_id: str = "";
    has kind: str = "";            # "intrusion" | "went_dark" | "reacquired" | "identity_change"
    has severity: str = "info";    # "info" | "warning" | "critical"
    has t: float = 0.0;
    has track_id: str = "";
    has zone_id: str = "";
    has headline: str = "";        # by llm(), composed by AlertScribe
    has detail: str = "";          # deterministic long-form, always present
    has model_used: str = "";      # honesty marker: llm name | "template"
}

node Brief {
    has t: float = 0.0;
    has text: str = "";
    has alert_count: int = 0;
    has model_used: str = "";
}


# --------------------------------------------------------------------- edges

"""Track was inside Zone. Created on first entry and kept as evidence;
`active` mirrors current containment so history survives an exit."""
edge InZone {
    has since_t: float = 0.0;
    has active: bool = True;
}

edge RaisedOn {}       # Alert -> Track
edge Concerning {}     # Alert -> Zone
edge JustifiedBy {     # Alert -> Contact: the detections behind the claim
    has weight: float = 1.0;
}
edge Summarizes {}     # Brief -> Alert


# ------------------------------------------------------------------- helpers

"""Materialise the static graph for a loaded scenario: Mission node, one Zone
per geofence, and the run machinery in meta."""
def build_mission(scenario: object) -> Mission {
    m = Mission(
        pack_id=scenario.pack_id,
        name=scenario.name,
        frame_interval_s=scenario.frame_interval_s,
    );
    root ++> m;
    for gf in scenario.geofences {
        m ++> Zone(
            zone_id=gf.fence_id,
            name=gf.name,
            kind=gf.kind,
            ring=[[p[0], p[1]] for p in gf.ring],
            geojson=gf.geojson,
        );
    }
    # NOTE: never stash the Scenario (or any large Python object) on a node.
    # The runtime serializes and hashes dirty anchors after every spawn, and a
    # 69k-measurement scenario in meta turns each frame into seconds of
    # serializer work. Walkers receive the scenario by argument instead.
    m.meta["actor_states"] = {};
    m.meta["pending_births"] = [];
    m.meta["next_track"] = 1;
    m.meta["next_alert"] = 1;
    return m;
}

def zones_of(m: Mission) -> list {
    return [m -->[?:Zone]];
}

def tracks_of(m: Mission) -> list {
    return [t for t in [m -->[?:Track]] if t.status != STATUS_DROPPED];
}

def alerts_of(m: Mission) -> list {
    return [m -->[?:Alert]];
}

"""Find-or-create the per-actor switchboard node. Cached in meta because a
linear scan of [m --> ActorState] per measurement would be O(actors^2) per
frame with 300+ vessels."""
def actor_state(m: Mission, actor: str) -> ActorState {
    cache = m.meta["actor_states"];
    if actor not in cache {
        st = ActorState(actor=actor, display_id=actor);
        m ++> st;
        cache[actor] = st;
    }
    return cache[actor];
}

def mint_track_id(m: Mission) -> str {
    tid = f"T-{m.meta['next_track']:03d}";
    m.meta["next_track"] += 1;
    return tid;
}

def mint_alert_id(m: Mission) -> str {
    aid = f"A-{m.meta['next_alert']:03d}";
    m.meta["next_alert"] += 1;
    return aid;
}


# --------------------------------------------------------------------- tests

test "zone containment uses cached shapely polygon" {
    z = Zone(zone_id="zt", ring=[[0.0, 0.0], [10.0, 0.0], [10.0, 10.0], [0.0, 10.0]]);
    assert z.contains(5.0, 5.0);
    assert not z.contains(15.0, 5.0);
    assert z.poly is not None;  # cached after first call
}

test "actor_state creates once and caches" {
    m = Mission(pack_id="t");
    root ++> m;
    m.meta["actor_states"] = {};
    a1 = actor_state(m, "mmsi:1");
    a2 = actor_state(m, "mmsi:1");
    assert a1 is a2;
    assert len([m -->[?:ActorState]]) == 1;
    assert a1.display_id == "mmsi:1";
}

test "track id minting is sequential" {
    m = Mission(pack_id="t2");
    root ++> m;
    m.meta["next_track"] = 1;
    assert mint_track_id(m) == "T-001";
    assert mint_track_id(m) == "T-002";
}
