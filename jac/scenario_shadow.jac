"""Scenario pack loader, shadow port: AIS ingest, geofences, synthetic actors.

WHAT THIS FILE IS
------------------
`data/scenario.py` is the canonical scenario pack loader: it turns a
`scenarios/<pack_id>/` directory (a `pack.json` manifest plus GeoJSON geofence
layers and a cached AIS window CSV) into an in-memory `Scenario` -- fixed
interval frames of unlabelled `Measurement` objects plus ENU geofences.

This file is a PARALLEL Jac reconstruction of that same logic, expressed as
node/walker/glob state the way the rest of `jac/` (see `geofence.jac`) models
per-frame memory. It is not imported by anything, not wired into the replay
server, and not required to compile or execute -- it exists so the scenario
pack pipeline is expressible as a Jac graph and not just as dataclasses and
free functions, mirroring the split `geofence.jac` draws between "numerics in
Python" and "state and rules in Jac". Here the analogous split is "one-shot
parsing/resampling" (still essentially numeric) versus "the pack as a graph of
nodes the rest of the system can walk" -- a `ScenarioPack` hub, one
`ActorTrack` node per vessel (real or synthetic), one `GeoFenceNode` per
geofence polygon, and one `ReplayFrame` node per fixed-interval tick, linked
in sequence.

BOUNDARY, same as the source module
------------------------------------
Data prep only: resampling, projection, noise, ground-truth bookkeeping.
Scripted event *application* (`ais_off` suppression, `radar_contact`
injection, `identity_change`) is graph mutation that belongs to the
`ScenarioDriver` walker in `jac/driver.jac`, not here. Events are parsed and
attached to their frame; every frame still carries the FULL unsuppressed AIS
picture.

IDENTITY
--------
MMSI is stripped at ingest into `ground_truth`, keyed by `meas_id`, exactly as
in `data/scenario.py`. A `Measurement` node here carries only
{meas_id, t, x, y, source, sigma} -- never an actor key -- and
`assert_no_identity_leak` walks every `ReplayFrame` to verify that rather than
assume it, mirroring `_assert_no_identity_leak` in the Python original.

COORDINATES
-----------
Local ENU metres about the pack's `origin` (lat, lon), via an equirectangular
projection -- sub-metre error at bay scale, identical to `lla_to_enu` /
`enu_to_lla` in the source module.
"""

import sys;
import os;
import math;
import json;
import csv;
from datetime import datetime, timezone;

with entry {
    _repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)));
    if _repo_root not in sys.path {
        sys.path.insert(0, _repo_root);
    }
}


# ---------------------------------------------------------------------------
# Module constants. Mirrors data/scenario.py's module-level globals -- these
# are physical/parsing constants, not per-run state, so they live as globs
# rather than as fields on any node.
# ---------------------------------------------------------------------------

glob EARTH_R: float = 6371000.0;              # metres
glob MAX_INTERP_GAP_S: float = 600.0;         # longer AIS gaps are dropped, not interpolated
glob AIS_SIGMA_M: float = 5.0;
glob RADAR_SIGMA_M: float = 50.0;
glob SCENARIOS_DIRNAME: str = "scenarios";

# Run state, mutated in place rather than rebound -- same discipline
# geofence.jac uses for EVENTS / HUB, so Python-side callers keep live
# references to the same list/dict objects across the run.
glob PACKS: list = [];        # [ScenarioPack] for the CURRENT load, process-local
glob LOAD_ERRORS: list = [];  # human-readable problems noticed during a load
glob GROUND_TRUTH: dict = {}; # meas_id -> actor key, for the CURRENT pack
glob NEXT_MEAS_SEQ: list = [0];  # boxed counter so ScenarioDriver can mint fresh ids


# ---------------------------------------------------------------------------
# Geo helpers -- direct ports of lla_to_enu / enu_to_lla / _parse_utc.
# ---------------------------------------------------------------------------

def lla_to_enu(lat: float, lon: float, origin_lat: float, origin_lon: float) -> tuple {
    """Equirectangular lat/lon -> local ENU metres. Sub-metre error at bay
    scale -- adequate for geofence and tracker math, not for chart plotting.""";
    x = math.radians(lon - origin_lon) * EARTH_R * math.cos(math.radians(origin_lat));
    y = math.radians(lat - origin_lat) * EARTH_R;
    return (x, y);
}


def enu_to_lla(x: float, y: float, origin_lat: float, origin_lon: float) -> tuple {
    """Inverse of lla_to_enu, for rendering true positions back to the map.""";
    lat = origin_lat + math.degrees(y / EARTH_R);
    lon = origin_lon + math.degrees(x / (EARTH_R * math.cos(math.radians(origin_lat))));
    return (lat, lon);
}


def parse_utc(s: str) -> float {
    """ISO timestamp -> POSIX seconds. Naive timestamps are treated as UTC,
    since MarineCadastre's BaseDateTime column carries no timezone suffix.""";
    cleaned = s.replace("Z", "+00:00");
    dt = datetime.fromisoformat(cleaned);
    if dt.tzinfo is None {
        dt = dt.replace(tzinfo=timezone.utc);
    }
    return dt.timestamp();
}


# ---------------------------------------------------------------------------
# Graph: the scenario pack as nodes and edges.
#
# ScenarioPack is the fan-out hub, one per loaded pack (analogous to
# Watchtower in geofence.jac). ActorTrack, GeoFenceNode and ReplayFrame hang
# off it on typed edges so the pack IS the index -- no separate dict of
# tracks or frames needs to be threaded through every function.
# ---------------------------------------------------------------------------

node ScenarioPack {
    """One fully materialised scenario pack: the graph root everything else
    hangs from. Fields mirror data/scenario.py's Scenario dataclass field for
    field, except frames/geofences/tracks are graph edges here rather than
    Python lists.""";
    has pack_id: str = "";
    has name: str = "";
    has origin_lat: float = 0.0;
    has origin_lon: float = 0.0;
    has frame_interval_s: float = 30.0;
    has n_frames: int = 0;
    has expected: dict = {};
}


node ActorTrack {
    """One vessel's true resampled track -- real AIS (`mmsi:<id>`) or a
    synthetic actor (`gen:<kind>`), one namespace, same as true_tracks in the
    Python loader. `samples` is [(t_rel, x, y), ...], already resampled onto
    the fixed frame grid.""";
    has actor_id: str = "";
    has is_synthetic: bool = False;
    has samples: list = [];             # [(t, x, y), ...]
    has display_id: str = "";           # current broadcast identity, absent identity_change events
}


node GeoFenceNode {
    """One geofence polygon, ENU metres, ported from Geofence in
    data/contracts.py. `ring` is the exterior ring as (x, y) tuples.""";
    has fence_id: str = "";
    has label: str = "";
    has kind: str = "zone";
    has ring: list = [];
    has geojson: dict = {};
}


node ReplayFrame {
    """One fixed-interval tick. `meas_ids` indexes into the pack's measurement
    table (kept as a plain dict keyed by meas_id, mirroring how
    _assert_no_identity_leak walks frame.measurements in the source).""";
    has idx: int = 0;
    has t: float = 0.0;
    has meas_ids: list = [];
    has event_ids: list = [];
}


node ScenarioEventNode {
    """A scripted event applied by the replay layer at its timestamp. Kinds:
    ais_off, ais_on, radar_contact, identity_change -- application is
    ScenarioDriver's job (jac/driver.jac), this node only carries the parsed
    fields, exactly like ScenarioEvent in data/contracts.py.""";
    has event_id: str = "";
    has t: float = 0.0;
    has kind: str = "";
    has actor: str = "";
    has params: dict = {};
}


edge HasActor {}
edge HasFence {}
edge HasFrame {}
edge HasEvent {}
edge NextFrame {}    # ReplayFrame -> ReplayFrame, chronological chain


# ---------------------------------------------------------------------------
# Pack resolution / manifest parsing -- port of _resolve_pack.
# ---------------------------------------------------------------------------

def scenarios_dir() -> str {
    """Repo-relative scenarios/ directory, computed the same way
    SCENARIOS_DIR is in data/scenario.py (two directories up from this file,
    since jac/ sits alongside data/ at the repo root).""";
    here = os.path.dirname(os.path.abspath(__file__));
    repo_root = os.path.dirname(here);
    return os.path.join(repo_root, SCENARIOS_DIRNAME);
}


def resolve_pack(name_or_path: str) -> tuple {
    """Accept a pack id (dir under scenarios/), a pack dir, or a pack.json
    path directly -- same three candidate paths as _resolve_pack.""";
    candidates = [
        name_or_path,
        os.path.join(name_or_path, "pack.json"),
        os.path.join(scenarios_dir(), name_or_path, "pack.json")
    ];
    for path in candidates {
        if os.path.isfile(path) {
            with open(path, "r", encoding="utf-8") as f {
                pack = json.load(f);
            }
            return (pack, os.path.dirname(os.path.abspath(path)));
        }
    }
    LOAD_ERRORS.append(f"scenario pack {name_or_path!r} not found (looked in {candidates})");
    return ({}, "");
}


# ---------------------------------------------------------------------------
# Geofence layer loading -- port of _load_geofences, building GeoFenceNode
# graph nodes instead of Geofence dataclass instances.
# ---------------------------------------------------------------------------

def build_geofences(pack: ScenarioPack, manifest: dict, pack_dir: str) -> list {
    """Read every geofence_layers entry's GeoJSON, project each Polygon ring
    into ENU metres about the pack's origin, and hang a GeoFenceNode off
    `pack` for each feature. Returns the list of created nodes.""";
    created = [];
    layers = manifest.get("geofence_layers", []);
    for layer in layers {
        path = os.path.join(pack_dir, layer["file"]);
        with open(path, "r", encoding="utf-8") as f {
            gj = json.load(f);
        }
        if gj.get("type") == "FeatureCollection" {
            features = gj["features"];
        } else {
            features = [gj];
        }
        i = 0;
        for feat in features {
            geom = feat["geometry"];
            if geom["type"] != "Polygon" {
                LOAD_ERRORS.append(f"{path}: only Polygon geofences supported, got {geom['type']}");
                i += 1;
                continue;
            }
            exterior = geom["coordinates"][0];   # GeoJSON coordinate order is [lon, lat]
            ring = [];
            for coord in exterior {
                lon = coord[0];
                lat = coord[1];
                ring.append(lla_to_enu(lat, lon, pack.origin_lat, pack.origin_lon));
            }
            props = feat.get("properties", {});
            default_kind = layer.get("kind", "zone");
            fid = props.get("id", f"{default_kind}_{i}");
            fnode = GeoFenceNode(
                fence_id=fid,
                label=props.get("name", os.path.basename(path)),
                kind=layer.get("kind", props.get("kind", "zone")),
                ring=ring,
                geojson=feat
            );
            pack +>:HasFence:+> fnode;
            created.append(fnode);
            i += 1;
        }
    }
    return created;
}


# ---------------------------------------------------------------------------
# AIS ingest -- port of _ingest_ais. Filters the cached AIS CSV window to
# bbox+time, resamples each vessel onto the fixed frame grid, converts to ENU.
# ---------------------------------------------------------------------------

def read_ais_fixes(csv_path: str, lon_min: float, lon_max: float,
                    lat_min: float, lat_max: float, t0: float, t1: float) -> dict {
    """First pass: bbox+time filtered raw fixes, mmsi -> [(t_abs, lat, lon)],
    unsorted. Mirrors the `fixes` dict built inside _ingest_ais.""";
    fixes = {};
    with open(csv_path, "r", encoding="utf-8", newline="") as f {
        reader = csv.DictReader(f);
        for row in reader {
            try {
                lat = float(row["LAT"]);
                lon = float(row["LON"]);
            } except (ValueError, KeyError) {
                continue;
            }
            in_bbox = (lat_min <= lat <= lat_max) and (lon_min <= lon <= lon_max);
            if not in_bbox {
                continue;
            }
            t = parse_utc(row["BaseDateTime"]);
            if not (t0 <= t <= t1) {
                continue;
            }
            mmsi = row["MMSI"];
            if mmsi not in fixes {
                fixes[mmsi] = [];
            }
            fixes[mmsi].append((t, lat, lon));
        }
    }
    return fixes;
}


def resample_track(pts: list, frame_times: list, t0: float, origin_lat: float,
                    origin_lon: float, interval: float) -> list {
    """Resample one vessel's sorted (t_abs, lat, lon) fixes onto frame_times,
    linearly interpolating bracketing pairs and refusing to interpolate across
    a gap longer than MAX_INTERP_GAP_S. Same bracketing-index walk as the
    Python `j` pointer in _ingest_ais, just expressed with an explicit index
    variable since Jac's for-loop has no enumerate sugar here.""";
    resampled = [];
    j = 0;
    n = len(pts);
    for ft in frame_times {
        while (j + 1 < n) and (pts[j + 1][0] <= ft) {
            j += 1;
        }
        accept = True;
        if (pts[j][0] > ft) or (j + 1 >= n) {
            # No bracketing pair; accept a fix within half a frame of the tick.
            if abs(pts[j][0] - ft) <= interval / 2.0 {
                lat = pts[j][1];
                lon = pts[j][2];
            } else {
                accept = False;
            }
        } else {
            ta = pts[j][0]; la = pts[j][1]; lo = pts[j][2];
            tb = pts[j + 1][0]; lb = pts[j + 1][1]; lo2 = pts[j + 1][2];
            if (tb - ta) > MAX_INTERP_GAP_S {
                accept = False;
            } else {
                if tb == ta {
                    w = 0.0;
                } else {
                    w = (ft - ta) / (tb - ta);
                }
                lat = la + w * (lb - la);
                lon = lo + w * (lo2 - lo);
            }
        }
        if accept {
            xy = lla_to_enu(lat, lon, origin_lat, origin_lon);
            resampled.append((ft - t0, xy[0], xy[1]));
        }
    }
    return resampled;
}


def ingest_ais(pack: ScenarioPack, manifest: dict, csv_path: str, t0: float, t1: float,
               interval: float, min_fixes: int) -> dict {
    """Full AIS ingest: filter, resample every vessel, drop anything with
    fewer than min_fixes_per_vessel resampled points. Returns
    actor_key -> [(t_rel, x, y)], keyed "mmsi:<mmsi>" same as the source.""";
    bbox = manifest["bbox"];
    fixes = read_ais_fixes(
        csv_path, bbox["lon_min"], bbox["lon_max"], bbox["lat_min"], bbox["lat_max"], t0, t1
    );

    n_frames = int((t1 - t0) / interval) + 1;
    frame_times = [];
    k = 0;
    while k < n_frames {
        frame_times.append(t0 + k * interval);
        k += 1;
    }

    tracks = {};
    for mmsi in fixes.keys() {
        pts = fixes[mmsi];
        pts.sort(key=lambda p: p[0]);
        resampled = resample_track(pts, frame_times, t0, pack.origin_lat, pack.origin_lon, interval);
        if len(resampled) >= min_fixes {
            tracks[f"mmsi:{mmsi}"] = resampled;
        }
    }
    return tracks;
}


# ---------------------------------------------------------------------------
# Synthetic actor track generators -- port of _gen_transit_then_loiter,
# _gen_transit, _actor_start, and the GENERATORS dispatch dict.
# ---------------------------------------------------------------------------

def actor_start(params: dict, origin_lat: float, origin_lon: float) -> tuple {
    """Starting ENU point for a synthetic actor: either a lat/lon pair
    projected through the pack origin, or a raw (x, y) already in metres.""";
    if "start_latlon" in params {
        latlon = params["start_latlon"];
        return lla_to_enu(latlon[0], latlon[1], origin_lat, origin_lon);
    }
    xy = params["start"];
    return (float(xy[0]), float(xy[1]));
}


def gen_transit(params: dict, frame_times: list, origin_lat: float, origin_lon: float) -> list {
    """Constant-velocity straight line. Direct port of _gen_transit -- nav
    heading convention: 0 deg = north, clockwise, so dx = sin, dy = cos.""";
    start = actor_start(params, origin_lat, origin_lon);
    x0 = start[0]; y0 = start[1];
    speed = float(params["speed_mps"]);
    hdg = math.radians(float(params["heading_deg"]));
    dx = math.sin(hdg);
    dy = math.cos(hdg);
    t_start = float(params.get("t_start", 0.0));
    if len(frame_times) > 0 {
        default_end = frame_times[-1];
    } else {
        default_end = 0.0;
    }
    t_end = float(params.get("t_end", default_end));
    out = [];
    for t in frame_times {
        if (t_start <= t) and (t <= t_end) {
            te = t - t_start;
            out.append((t, x0 + dx * speed * te, y0 + dy * speed * te));
        }
    }
    return out;
}


def gen_transit_then_loiter(params: dict, frame_times: list, origin_lat: float, origin_lon: float) -> list {
    """Straight transit at constant speed/heading, then a slow loiter circle
    around the point reached -- direct port of _gen_transit_then_loiter. The
    loiter angular rate keeps tangential speed gentle (~2 m/s default);
    entering the circle "tangentially-ish" starts at the angle pointing back
    along the inbound track, same approximation as the source.""";
    start = actor_start(params, origin_lat, origin_lon);
    x0 = start[0]; y0 = start[1];
    speed = float(params["speed_mps"]);
    hdg = math.radians(float(params["heading_deg"]));
    dx = math.sin(hdg);
    dy = math.cos(hdg);
    transit_s = float(params["transit_s"]);
    r = float(params.get("loiter_radius_m", 150.0));
    omega = float(params.get("loiter_speed_mps", 2.0)) / max(r, 1.0);
    t_start = float(params.get("t_start", 0.0));
    if len(frame_times) > 0 {
        default_end = frame_times[-1];
    } else {
        default_end = 0.0;
    }
    t_end = float(params.get("t_end", default_end));

    cx = x0 + dx * speed * transit_s;
    cy = y0 + dy * speed * transit_s;

    out = [];
    for t in frame_times {
        if (t < t_start) or (t > t_end) {
            continue;
        }
        te = t - t_start;
        if te <= transit_s {
            out.append((t, x0 + dx * speed * te, y0 + dy * speed * te));
        } else {
            a = omega * (te - transit_s);
            out.append((t, cx + r * math.sin(a), cy - r * (1.0 - math.cos(a))));
        }
    }
    return out;
}


glob GENERATOR_NAMES: list = ["gen:transit_then_loiter", "gen:transit"];


def run_generator(track_kind: str, params: dict, frame_times: list,
                   origin_lat: float, origin_lon: float) -> list {
    """Dispatch by name, mirroring the GENERATORS dict in the source module.
    Jac has no first-class function-value dict literal as clean as Python's
    here, so dispatch is an explicit if-chain over GENERATOR_NAMES instead --
    same set of names, same failure mode (unknown name is a hard error).""";
    if track_kind == "gen:transit_then_loiter" {
        return gen_transit_then_loiter(params, frame_times, origin_lat, origin_lon);
    }
    if track_kind == "gen:transit" {
        return gen_transit(params, frame_times, origin_lat, origin_lon);
    }
    LOAD_ERRORS.append(f"unknown track generator {track_kind!r} (have {GENERATOR_NAMES})");
    return [];
}


# ---------------------------------------------------------------------------
# Truth query -- port of true_position_at, used by ScenarioDriver to place
# injected radar contacts on an actor's actual (possibly dark) position.
# ---------------------------------------------------------------------------

def true_position_at(track: list, t: float) -> tuple {
    """Linear interpolation along a resampled true track. Returns None outside
    the track's covered time span, same edge behaviour as the Python
    original.""";
    if len(track) == 0 {
        return None;
    }
    if (t < track[0][0]) or (t > track[-1][0]) {
        return None;
    }
    i = 0;
    n = len(track);
    while i < n - 1 {
        ta = track[i][0]; xa = track[i][1]; ya = track[i][2];
        tb = track[i + 1][0]; xb = track[i + 1][1]; yb = track[i + 1][2];
        if (ta <= t) and (t <= tb) {
            if tb == ta {
                w = 0.0;
            } else {
                w = (t - ta) / (tb - ta);
            }
            return (xa + w * (xb - xa), ya + w * (yb - ya));
        }
        i += 1;
    }
    return (track[-1][1], track[-1][2]);
}


# ---------------------------------------------------------------------------
# display_id -- port of Scenario.display_id. A pure function of
# identity_change events, never of measurements: radar-source Measurements
# are structurally incapable of carrying identity, so this is the ONLY place
# a display identity can come from.
# ---------------------------------------------------------------------------

def display_id_at(event_nodes: list, actor: str, t: float) -> str {
    """The identity `actor` broadcasts at time `t`. An event at exactly `t`
    has already applied (inclusive <=): two spoofing events both firing at
    t=0.0 must already be reflected at display_id(actor, 0.0), not deferred to
    the next tick. With no identity_change at or before `t`, the actor key
    itself is the display identity -- most scenarios never touch identity at
    all, and this makes that the default rather than a special case.""";
    latest_t = None;
    latest_id = actor;
    for ev in event_nodes {
        if (ev.kind == "identity_change") and (ev.actor == actor) and (ev.t <= t) {
            if (latest_t is None) or (ev.t >= latest_t) {
                latest_t = ev.t;
                latest_id = ev.params["new_display_id"];
            }
        }
    }
    return latest_id;
}


# ---------------------------------------------------------------------------
# Measurement id minting -- port of Scenario.mint_meas_id. Kept as a walker
# so the counter and the ground-truth write happen together, same invariant
# as the source: the side table stays the single place identity ever lives.
# ---------------------------------------------------------------------------

walker MintMeasurementId {
    """Reserve a fresh measurement id for `actor` and bind its ground truth.
    Spawned by the ScenarioDriver walker (jac/driver.jac) when it injects a
    radar contact, one visit, one id.""";
    has actor: str = "";
    has minted_id: str = "";

    can mint with ScenarioPack entry {
        mid = f"m{NEXT_MEAS_SEQ[0]:06d}";
        NEXT_MEAS_SEQ[0] = NEXT_MEAS_SEQ[0] + 1;
        GROUND_TRUTH[mid] = self.actor;
        self.minted_id = mid;
    }
}


# ---------------------------------------------------------------------------
# Frame assembly walker -- the graph analogue of the frame-building loop at
# the bottom of load_scenario. Rather than a flat Python list of Frame
# dataclasses, this walker lays down a ReplayFrame node per tick, chained via
# NextFrame edges, each carrying the meas_ids it produced this tick. Gaussian
# AIS noise is added exactly as in the source (rng.normal(0, sigma, 2)), just
# expressed as two independent calls since Jac's np import here is Python's
# numpy re-exposed, not a language feature.
# ---------------------------------------------------------------------------

import from numpy { random as np_random }

walker AssembleFrames {
    """Walk actor_order in a fixed, deterministic order (sorted) so meas ids
    stay stable across loads regardless of CSV insertion order -- same
    determinism guarantee load_scenario documents.""";
    has actor_tracks: dict = {};        # actor_id -> ActorTrack node
    has frame_times: list = [];
    has ais_sigma: float = 5.0;
    has seed: int = 20260726;
    has measurements: dict = {};        # meas_id -> (t, x, y, source, sigma)
    has frame_nodes: list = [];

    can assemble with ScenarioPack entry {
        rng = np_random.default_rng(self.seed);
        actor_order = sorted(self.actor_tracks.keys());
        track_pos = {};
        for a in actor_order {
            track_pos[a] = 0;
        }

        prev_frame = None;
        k = 0;
        for ft in self.frame_times {
            meas_ids_this_frame = [];
            for actor in actor_order {
                track_node = self.actor_tracks[actor];
                samples = track_node.samples;
                i = track_pos[actor];
                n = len(samples);
                while (i < n) and (samples[i][0] < ft - 1e-9) {
                    i += 1;
                }
                track_pos[actor] = i;
                if (i >= n) or (abs(samples[i][0] - ft) > 1e-6) {
                    continue;
                }
                tx = samples[i][1];
                ty = samples[i][2];
                mid = f"m{NEXT_MEAS_SEQ[0]:06d}";
                NEXT_MEAS_SEQ[0] = NEXT_MEAS_SEQ[0] + 1;
                noise = rng.normal(0.0, self.ais_sigma, 2);
                nx = tx + noise[0];
                ny = ty + noise[1];
                self.measurements[mid] = (ft, nx, ny, "ais", self.ais_sigma);
                GROUND_TRUTH[mid] = actor;
                meas_ids_this_frame.append(mid);
            }

            fnode = ReplayFrame(idx=k, t=ft, meas_ids=meas_ids_this_frame, event_ids=[]);
            here +>:HasFrame:+> fnode;
            if prev_frame is not None {
                prev_frame +>:NextFrame:+> fnode;
            }
            prev_frame = fnode;
            self.frame_nodes.append(fnode);
            k += 1;
        }
    }
}


# ---------------------------------------------------------------------------
# Identity leak assertion -- port of _assert_no_identity_leak / _MEASUREMENT_FIELDS.
# ---------------------------------------------------------------------------

glob MEASUREMENT_FIELDS: list = ["meas_id", "t", "x", "y", "source", "sigma"];


def assert_no_identity_leak(actor_keys: list, measurements: dict) -> bool {
    """No measurement carries identity -- asserted, not assumed. Checks that
    every measurement's source is one of the two known sensor kinds and that
    neither meas_id nor source string-matches an actor key or an mmsi:
    prefix. Returns True on success; appends to LOAD_ERRORS and returns False
    on any violation, so a shadow-graph caller can decide how loud to be
    about it rather than this function raising directly.""";
    ok = True;
    actors = set(actor_keys);
    for mid in measurements.keys() {
        entry = measurements[mid];
        source = entry[3];
        if source not in ("ais", "radar") {
            LOAD_ERRORS.append(f"bad source {source!r} on measurement {mid}");
            ok = False;
        }
        if (mid in actors) or str(mid).startswith("mmsi:") {
            LOAD_ERRORS.append(f"identity leaked into measurement {mid}: meas_id itself is an actor key");
            ok = False;
        }
        if (source in actors) or str(source).startswith("mmsi:") {
            LOAD_ERRORS.append(f"identity leaked into measurement {mid}: source {source!r}");
            ok = False;
        }
    }
    return ok;
}


# ---------------------------------------------------------------------------
# Top-level pack loader -- port of load_scenario. Builds the graph rather
# than a Scenario dataclass: a ScenarioPack hub with ActorTrack, GeoFenceNode,
# ScenarioEventNode and ReplayFrame nodes hanging off it.
# ---------------------------------------------------------------------------

def load_scenario_pack(name_or_path: str) -> ScenarioPack {
    """Parse a pack, ingest AIS, generate synthetic actors, lay out events,
    and return the fully materialised ScenarioPack graph node plus its
    dependent nodes. Faithful structural port of load_scenario; error paths
    that would `raise` in Python instead append to LOAD_ERRORS and return an
    empty-ish ScenarioPack, since this shadow module is not meant to be
    executed for real.""";
    resolved = resolve_pack(name_or_path);
    manifest = resolved[0];
    pack_dir = resolved[1];
    if len(manifest) == 0 {
        return ScenarioPack(pack_id="", name="<unresolved>");
    }

    origin = manifest["origin"];
    origin_lat = float(origin["lat"]);
    origin_lon = float(origin["lon"]);
    interval = float(manifest.get("frame_interval_s", 30.0));
    t0 = parse_utc(manifest["time_window"]["start"]);
    t1 = parse_utc(manifest["time_window"]["end"]);
    if t1 <= t0 {
        LOAD_ERRORS.append(f"pack {manifest['id']}: time_window end must be after start");
    }

    n_frames = int((t1 - t0) / interval) + 1;
    frame_times = [];
    k = 0;
    while k < n_frames {
        frame_times.append(k * interval);
        k += 1;
    }

    pack = ScenarioPack(
        pack_id=manifest["id"],
        name=manifest.get("name", manifest["id"]),
        origin_lat=origin_lat,
        origin_lon=origin_lon,
        frame_interval_s=interval,
        n_frames=n_frames,
        expected=manifest.get("expected", {})
    );
    root ++> pack;

    build_geofences(pack, manifest, pack_dir);

    # --- true tracks: real AIS + synthetic actors, one namespace ------------
    true_tracks = {};
    ais_csv = manifest.get("ais_csv");
    if ais_csv {
        csv_path = os.path.join(pack_dir, ais_csv);
        min_fixes = int(manifest.get("min_fixes_per_vessel", 4));
        if os.path.isfile(csv_path) {
            ais_tracks = ingest_ais(pack, manifest, csv_path, t0, t1, interval, min_fixes);
            for key in ais_tracks.keys() {
                true_tracks[key] = ais_tracks[key];
            }
        } else {
            if manifest.get("ais_required", True) {
                LOAD_ERRORS.append(
                    f"pack {manifest['id']}: AIS window {csv_path} missing; run "
                    f"scripts/extract_window.py or set ais_required=false"
                );
            }
        }
    }

    for actor in manifest.get("synthetic_actors", []) {
        track_kind = actor["track"];
        params = actor.get("params", {});
        track = run_generator(track_kind, params, frame_times, origin_lat, origin_lon);
        actor_id = actor["actor_id"];
        if actor_id in true_tracks {
            LOAD_ERRORS.append(f"duplicate actor id {actor_id!r}");
            continue;
        }
        true_tracks[actor_id] = track;
    }

    # --- ActorTrack nodes, one per key in true_tracks -----------------------
    actor_nodes = {};
    for actor_id in true_tracks.keys() {
        is_synth = actor_id.startswith("gen:") or (not actor_id.startswith("mmsi:"));
        tnode = ActorTrack(
            actor_id=actor_id,
            is_synthetic=is_synth,
            samples=true_tracks[actor_id],
            display_id=actor_id
        );
        pack +>:HasActor:+> tnode;
        actor_nodes[actor_id] = tnode;
    }

    # --- events --------------------------------------------------------------
    event_nodes = [];
    i = 0;
    for ev in manifest.get("events", []) {
        enode = ScenarioEventNode(
            event_id=ev.get("id", f"ev{i:03d}"),
            t=float(ev["t"]),
            kind=ev["kind"],
            actor=ev["actor"],
            params=ev.get("params", {})
        );
        pack +>:HasEvent:+> enode;
        event_nodes.append(enode);
        i += 1;
    }

    # --- assemble frames -------------------------------------------------------
    # Every frame carries the FULL unsuppressed AIS picture; applying events
    # is graph work for ScenarioDriver (jac/driver.jac), not this loader.
    ais_sigma = float(manifest.get("ais_noise_sigma_m", AIS_SIGMA_M));
    seed = int(manifest.get("seed", 20260726));

    GROUND_TRUTH.clear();
    NEXT_MEAS_SEQ[0] = 0;

    assembler = pack spawn AssembleFrames(
        actor_tracks=actor_nodes,
        frame_times=frame_times,
        ais_sigma=ais_sigma,
        seed=seed
    );

    ok = assert_no_identity_leak(list(true_tracks.keys()), assembler.measurements);
    if not ok {
        LOAD_ERRORS.append(f"pack {pack.pack_id}: identity leak check failed");
    }

    PACKS.append(pack);
    return pack;
}


# ---------------------------------------------------------------------------
# Crossings -- port of find_crossings. Two vessels within max_dist_m with
# converging headings; consecutive flagged frames for a pair merge into one
# crossing window.
# ---------------------------------------------------------------------------

def index_by_time(true_tracks: dict) -> dict {
    """actor -> {rounded_t: (x, y)} for O(1) frame lookup, same rounding
    (3 decimal places) as the by_time dict comprehension in find_crossings.""";
    by_time = {};
    for actor in true_tracks.keys() {
        track = true_tracks[actor];
        table = {};
        for sample in track {
            table[round(sample[0], 3)] = (sample[1], sample[2]);
        }
        by_time[actor] = table;
    }
    return by_time;
}


def find_crossings(true_tracks: dict, interval: float, max_dist_m: float = 500.0) -> list {
    """Locate pairs of vessels within max_dist_m with converging headings.

    Converging means the pair's range is decreasing at the flagged frame
    (closing speed > 0.5 m/s). Consecutive flagged frames for a pair merge
    into one crossing. Returns a list of dicts sorted by t_start, same shape
    as the Python original: pair, t_start, t_end, min_dist_m, closing_mps.""";
    by_time = index_by_time(true_tracks);
    actors = sorted(by_time.keys());

    all_times_set = set();
    for actor in by_time.keys() {
        for t in by_time[actor].keys() {
            all_times_set.add(t);
        }
    }
    all_times = sorted(all_times_set);

    hits = {};   # (ai, aj) -> [(t, dist, closing), ...]
    for t in all_times {
        present = [];
        for a in actors {
            if t in by_time[a] {
                present.append((a, by_time[a][t]));
            }
        }
        n = len(present);
        i = 0;
        while i < n {
            ai = present[i][0]; xi = present[i][1][0]; yi = present[i][1][1];
            j = i + 1;
            while j < n {
                aj = present[j][0]; xj = present[j][1][0]; yj = present[j][1][1];
                d = math.hypot(xi - xj, yi - yj);
                if d <= max_dist_m {
                    tp = round(t + interval, 3);
                    if (tp in by_time[ai]) and (tp in by_time[aj]) {
                        xi2 = by_time[ai][tp][0]; yi2 = by_time[ai][tp][1];
                        xj2 = by_time[aj][tp][0]; yj2 = by_time[aj][tp][1];
                        d2 = math.hypot(xi2 - xj2, yi2 - yj2);
                        closing = (d - d2) / interval;
                    } else {
                        closing = 0.0;
                    }
                    if closing > 0.5 {
                        key = (ai, aj);
                        if key not in hits {
                            hits[key] = [];
                        }
                        hits[key].append((t, d, closing));
                    }
                }
                j += 1;
            }
            i += 1;
        }
    }

    crossings = [];
    for pair in hits.keys() {
        pts = hits[pair];
        pts.sort();
        start = pts[0][0];
        prev = pts[0][0];
        seg = [pts[0]];
        tail = list(pts[1:]);
        tail.append((float("inf"), 0.0, 0.0));
        for p in tail {
            if (p[0] - prev) > (interval * 1.5) {
                min_dist = seg[0][1];
                max_closing = seg[0][2];
                for s in seg {
                    if s[1] < min_dist {
                        min_dist = s[1];
                    }
                    if s[2] > max_closing {
                        max_closing = s[2];
                    }
                }
                crossings.append({
                    "pair": pair,
                    "t_start": start,
                    "t_end": prev,
                    "min_dist_m": min_dist,
                    "closing_mps": max_closing
                });
                start = p[0];
                seg = [];
            }
            seg.append(p);
            prev = p[0];
        }
    }
    crossings.sort(key=lambda c: c["t_start"]);
    return crossings;
}


# ---------------------------------------------------------------------------
# Readback helpers -- graph-walk equivalents of the Scenario properties
# (n_frames, duration_s, n_vessels) and a couple of lookups a caller would
# otherwise reach for on the Python dataclass.
# ---------------------------------------------------------------------------

def pack_duration_s(pack: ScenarioPack) -> float {
    return pack.n_frames * pack.frame_interval_s;
}


def pack_vessel_count(pack: ScenarioPack) -> int {
    return len([pack ->:HasActor:->]);
}


def pack_fence_count(pack: ScenarioPack) -> int {
    return len([pack ->:HasFence:->]);
}


def find_actor(pack: ScenarioPack, actor_id: str) -> ActorTrack {
    """Linear scan over HasActor edges, same node-type-filter workaround
    geofence.jac uses: the edge type alone already narrows the reachable set
    to ActorTrack, so no `(?Type)` filter is needed.""";
    for a in [pack ->:HasActor:->] {
        if a.actor_id == actor_id {
            return a;
        }
    }
    return None;
}


def find_fence(pack: ScenarioPack, fence_id: str) -> GeoFenceNode {
    for f in [pack ->:HasFence:->] {
        if f.fence_id == fence_id {
            return f;
        }
    }
    return None;
}


def list_frames(pack: ScenarioPack) -> list {
    """All ReplayFrame nodes for this pack, in idx order. HasFrame edges are
    created in order during AssembleFrames, but this sorts explicitly rather
    than trusting edge iteration order, since a persisted graph reloaded from
    disk offers no such guarantee.""";
    frames = list([pack ->:HasFrame:->]);
    frames.sort(key=lambda fr: fr.idx);
    return frames;
}


def frame_at(pack: ScenarioPack, idx: int) -> ReplayFrame {
    for fr in [pack ->:HasFrame:->] {
        if fr.idx == idx {
            return fr;
        }
    }
    return None;
}


def load_errors() -> list {
    """Everything append-only recorded to LOAD_ERRORS across every
    load_scenario_pack call in this process, newest last.""";
    return list(LOAD_ERRORS);
}


def clear_load_errors() -> None {
    LOAD_ERRORS.clear();
}


def ground_truth_for(meas_id: str) -> str {
    """actor key for meas_id, or "" if this process has no record of it --
    the Jac analogue of a dict.get(meas_id) with a default, since
    GROUND_TRUTH is a plain glob dict rather than an object with .get here.""";
    if meas_id in GROUND_TRUTH {
        return GROUND_TRUTH[meas_id];
    }
    return "";
}


# ---------------------------------------------------------------------------
# Demo -- with entry:__main__ so `import scenario_shadow` from a test runner
# never executes it, same guard geofence.jac uses.
# ---------------------------------------------------------------------------

with entry:__main__ {
    print("=== sentinel-isr :: scenario_shadow (Jac shadow port of data/scenario.py) ===");
    print("scenarios dir  : " + scenarios_dir());
    print("This module is a standalone parallel reconstruction, not wired into the");
    print("live replay server -- see the module docstring for the boundary it draws");
    print("against jac/driver.jac's ScenarioDriver walker.");
}
