"""Fusion: the frame loop as a walker, one spawn per frame.

Sequence per spawn on the Mission node:

  1. `advance with Mission entry` -- predict every live track's CVKalman to
     the frame epoch, hand (track, kf) pairs plus the driver's surviving
     measurements to Raj's `associate_global`, mint new tentative tracks from
     leftover detections (two-point differencing across consecutive frames),
     then `visit` the Track nodes.
  2. `apply with Track entry` -- each track applies its own assignment:
     Kalman update + lifecycle transitions (tentative -> active -> coasting ->
     dropped), then re-checks zone containment and raises alerts on
     transitions. The mathematics is Raj's; the lifecycle and the graph
     consequences are this walker's.

The associator resolves to `tracker.associate.associate_global` when Raj's
Phase 2 lands and falls back to the greedy stub in `data.assoc_stub` until
then; `assoc_source` reports which one ran so nobody demos the stub thinking
it is the real thing.
"""

import importlib;
import from tracker.kalman { CVKalman }
import from jac.graph {
    Mission, Track, Zone, Alert, InZone,
    zones_of, tracks_of, mint_track_id,
    STATUS_TENTATIVE, STATUS_ACTIVE, STATUS_COASTING, STATUS_DROPPED,
    CONFIRM_HITS, COAST_AFTER_MISSES, DROP_AFTER_COAST,
    DARK_MIN_HITS, REACQ_MIN_COAST,
}
import from jac.alerts { raise_alert }
import from jac.driver { fmt_t }

# Two-point track birth: consecutive-frame detections must be kinematically
# reachable -- 15 m/s (~30 kn) across one 30 s frame, plus noise slack.
glob BIRTH_GATE_MPS: float = 15.0;


"""Resolve the association function once per run. Preferring the real tracker
module by name (not a try-import at module level) keeps this file loadable
even while tracker/associate.py does not exist yet."""
def resolve_associator() -> tuple {
    try {
        mod = importlib.import_module("tracker.associate");
        return (mod.associate_global, "tracker.associate");
    } except Exception {
        mod = importlib.import_module("data.assoc_stub");
        return (mod.associate_global, "data.assoc_stub (PLACEHOLDER)");
    }
}


walker Fusion {
    has t: float = 0.0;
    has dt: float = 30.0;
    has meas: list = [];               # from ScenarioDriver.effective
    has associate: object = None;      # resolved associate_global
    # Outputs for the renderer / delta assembly:
    has new_alerts: list = [];
    has born: list = [];
    has dropped_ids: list = [];
    has log: list = [];
    has n_matched: int = 0;
    # Internal: track_id -> Measurement for the visit phase, plus per-frame
    # caches. Re-deriving mission/zones inside every Track ability rescans the
    # Mission node's whole adjacency (hundreds of children on real traffic)
    # and dominated the profile; one scan per frame is plenty.
    has assigned: dict = {};
    has mission: object = None;
    has zones: list = [];

    can advance with Mission entry {
        self.mission = here;
        self.zones = zones_of(here);
        live = tracks_of(here);
        by_id = {m.meas_id: m for m in self.meas};

        # Predict every live filter to the frame epoch. dt is per-track: a
        # track born mid-run has kf.t at its birth frame.
        pairs = [];
        for trk in live {
            step = self.t - trk.kf.t;
            if step > 0.0 {
                trk.kf.predict(step);
            }
            pairs.append((trk.track_id, trk.kf));
        }

        # Raj's boundary: plain (track_id, kf) pairs and Measurements in,
        # (matches, unmatched_tracks, unmatched_meas) out.
        (matches, _un_tracks, un_meas) = self.associate(pairs, self.meas);
        self.assigned = {tid: by_id[mid] for (tid, mid) in matches};
        self.n_matched = len(matches);

        self.birth_tracks(here, [by_id[mid] for mid in un_meas]);
        visit [here -->[?:Track]];
    }

    can apply with Track entry {
        if here.status == STATUS_DROPPED {
            return;
        }
        if here.born_t == self.t and here.track_id not in self.assigned {
            # Born from this frame's leftovers: it cannot have an assignment
            # yet, and counting that as a miss would drop it instantly.
            self.refresh_snapshot(here);
            return;
        }
        if here.track_id in self.assigned {
            self.fuse_measurement(here, self.assigned[here.track_id]);
        } else {
            self.coast(here);
        }
        self.refresh_snapshot(here);
        if here.status in [STATUS_ACTIVE, STATUS_COASTING] {
            self.check_zones(here);
        }
    }

    # ------------------------------------------------------------ per track

    def fuse_measurement(trk: Track, m: object) -> None {
        was_coasting = trk.status == STATUS_COASTING;
        dark_frames = trk.coast_frames;
        trk.kf.update(m.z(), m.R());
        trk.hits += 1;
        trk.misses = 0;
        trk.coast_frames = 0;
        trk.last_t = self.t;
        trk.last_source = m.source;
        trk.last_meas_id = m.meas_id;

        if trk.status == STATUS_TENTATIVE and trk.hits >= CONFIRM_HITS {
            trk.status = STATUS_ACTIVE;
            self.log.append(
                f"[{fmt_t(self.t)}] TRACK {trk.track_id} confirmed "
                f"({trk.hits} consecutive fixes)"
            );
        } elif was_coasting {
            # The reacquire moment: an unlabelled detection fused into a track
            # that had been running on prediction alone. A two-frame AIS gap
            # is routine and resumes silently; a real dark period alerts.
            trk.status = STATUS_ACTIVE;
            if dark_frames >= REACQ_MIN_COAST {
                a = raise_alert(
                    self.mission, trk, "reacquired", None, self.t, [m.meas_id],
                );
                self.new_alerts.append(a);
                self.log.append(
                    f"[{fmt_t(self.t)}] TRACK {trk.track_id} reacquired via "
                    f"{m.source} detection {m.meas_id} after {dark_frames} "
                    f"frames dark"
                );
            }
        }
    }

    def coast(trk: Track) -> None {
        trk.misses += 1;
        if trk.status == STATUS_TENTATIVE {
            # Tentative tracks get no benefit of the doubt: one empty frame
            # and the birth was probably clutter.
            trk.status = STATUS_DROPPED;
            self.dropped_ids.append(trk.track_id);
            return;
        }
        if trk.status == STATUS_ACTIVE and trk.misses >= COAST_AFTER_MISSES {
            trk.status = STATUS_COASTING;
            trk.was_dark = True;
            # Real bay traffic has hundreds of vessels with ragged AIS
            # coverage; a track without history going quiet is noise, not an
            # alert. The state still flips so the ellipse grows either way.
            if trk.hits >= DARK_MIN_HITS {
                a = raise_alert(self.mission, trk, "went_dark", None, self.t, []);
                self.new_alerts.append(a);
                self.log.append(
                    f"[{fmt_t(self.t)}] TRACK {trk.track_id} went dark; "
                    f"coasting on prediction"
                );
            }
        }
        if trk.status == STATUS_COASTING {
            trk.coast_frames += 1;
            if trk.coast_frames > DROP_AFTER_COAST {
                trk.status = STATUS_DROPPED;
                self.dropped_ids.append(trk.track_id);
                self.log.append(
                    f"[{fmt_t(self.t)}] TRACK {trk.track_id} dropped after "
                    f"{trk.coast_frames} frames dark"
                );
            }
        }
    }

    def refresh_snapshot(trk: Track) -> None {
        # Mirror filter state into plain node fields so the renderer and the
        # graph tests never touch numpy mid-frame.
        st = trk.kf.state;
        cv = trk.kf.cov;
        trk.x = float(st[0]);
        trk.y = float(st[1]);
        trk.vx = float(st[2]);
        trk.vy = float(st[3]);
        trk.p00 = float(cv[0][0]);
        trk.p01 = float(cv[0][1]);
        trk.p11 = float(cv[1][1]);
    }

    def check_zones(trk: Track) -> None {
        for z in self.zones {
            inside = z.contains(trk.x, trk.y);
            was_inside = z.zone_id in trk.zones_in;
            if inside and not was_inside {
                trk.zones_in.append(z.zone_id);
                trk +>: InZone(since_t=self.t, active=True) :+> z;
                evidence = [trk.last_meas_id] if trk.last_meas_id else [];
                a = raise_alert(self.mission, trk, "intrusion", z, self.t, evidence);
                self.new_alerts.append(a);
                self.log.append(
                    f"[{fmt_t(self.t)}] ZONE {trk.track_id} entered "
                    f"{z.zone_id} ({trk.status})"
                );
            } elif was_inside and not inside {
                trk.zones_in.remove(z.zone_id);
                for e in [edge trk ->:InZone:->] {
                    e.active = False;
                }
                self.log.append(
                    f"[{fmt_t(self.t)}] ZONE {trk.track_id} exited {z.zone_id}"
                );
            }
        }
    }

    # ---------------------------------------------------------------- births

    # Pair this frame's leftover detections with last frame's leftovers; a
    # kinematically consistent pair seeds a tentative track via Raj's
    # two-point initialiser.
    def birth_tracks(m: Mission, unmatched: list) -> None {
        pending = m.meta["pending_births"];
        gate = BIRTH_GATE_MPS * self.dt + 100.0;
        still_pending = [];
        used = set();

        for prev in pending {
            best = None;
            best_d = gate;
            for cur in unmatched {
                if cur.meas_id in used {
                    continue;
                }
                d = ((cur.x - prev.x) ** 2 + (cur.y - prev.y) ** 2) ** 0.5;
                if d < best_d {
                    best = cur;
                    best_d = d;
                }
            }
            if best is None {
                continue;
            }
            used.add(best.meas_id);
            kf = CVKalman.init_two_point(
                prev.z(), prev.t, best.z(), best.t, best.R(),
            );
            trk = Track(
                track_id=mint_track_id(m),
                kf=kf,
                status=STATUS_TENTATIVE,
                hits=2,
                born_t=self.t,
                last_t=self.t,
                last_source=best.source,
                last_meas_id=best.meas_id,
            );
            m ++> trk;
            self.born.append(trk.track_id);

        }
        for cur in unmatched {
            if cur.meas_id not in used {
                still_pending.append(cur);
            }
        }
        m.meta["pending_births"] = still_pending;
    }
}


# ----------------------------------------------------------------------- tests

import numpy as np;
import from data.contracts { Measurement }
import from jac.graph { build_mission }
import from data.assoc_stub { associate_global }


obj _SyntheticScenario {
    has pack_id: str = "fusion-test";
    has name: str = "fusion test";
    has frame_interval_s: float = 30.0;
    has geofences: list = [];
}

def _mission() -> Mission {
    m = Mission(pack_id="fusion-test");
    root ++> m;
    m.meta["actor_states"] = {};
    m.meta["pending_births"] = [];
    m.meta["next_track"] = 1;
    m.meta["next_alert"] = 1;
    return m;
}

def _meas(mid: str, t: float, x: float, y: float, src: str = "ais") -> Measurement {
    return Measurement(meas_id=mid, t=t, x=x, y=y, source=src, sigma=5.0);
}

def _run_frame(m: Mission, t: float, meas: list) -> Fusion {
    f = Fusion(t=t, dt=30.0, meas=meas, associate=associate_global);
    return f spawn m;
}

test "two detections birth a tentative track; third confirms it" {
    m = _mission();
    _run_frame(m, 0.0, [_meas("s1", 0.0, 0.0, 0.0)]);
    _run_frame(m, 30.0, [_meas("s2", 30.0, 150.0, 0.0)]);
    trks = [m -->[?:Track]];
    assert len(trks) == 1;
    assert trks[0].status == STATUS_TENTATIVE;
    f3 = _run_frame(m, 60.0, [_meas("s3", 60.0, 300.0, 0.0)]);
    assert trks[0].status == STATUS_ACTIVE;
    assert abs(trks[0].vx - 5.0) < 2.0;   # ~5 m/s eastbound
}

# Feed k straight-line fixes at 5 m/s eastbound, one per 30 s frame.
def _feed_transit(m: Mission, k: int) -> None {
    for i in range(k) {
        t = 30.0 * i;
        _run_frame(m, t, [_meas(f"f{i}", t, 5.0 * t, 0.0)]);
    }
}

test "missed frames coast a mature track and raise went_dark once" {
    m = _mission();
    _feed_transit(m, 7);           # hits reach DARK_MIN_HITS
    _run_frame(m, 210.0, []);
    _run_frame(m, 240.0, []);
    _run_frame(m, 270.0, []);
    trk = [m -->[?:Track]][0];
    assert trk.status == STATUS_COASTING;
    darks = [a for a in [m -->[?:Alert]] if a.kind == "went_dark"];
    assert len(darks) == 1;
}

test "immature tracks coast silently -- no went_dark spam" {
    m = _mission();
    _feed_transit(m, 4);           # only 4 hits, below DARK_MIN_HITS
    _run_frame(m, 120.0, []);
    _run_frame(m, 150.0, []);
    trk = [m -->[?:Track]][0];
    assert trk.status == STATUS_COASTING;      # state flips regardless
    assert [a for a in [m -->[?:Alert]] if a.kind == "went_dark"] == [];
}

test "radar detection reacquires a track dark long enough to matter" {
    m = _mission();
    _feed_transit(m, 7);                        # solid history to t=180
    for i in range(5) {
        _run_frame(m, 210.0 + 30.0 * i, []);    # dark t=210..330
    }
    # Dark vessel kept moving east at ~5 m/s; radar sees it near x=1800.
    _run_frame(m, 360.0, [_meas("rr", 360.0, 1790.0, 10.0, "radar")]);
    trk = [m -->[?:Track]][0];
    assert trk.status == STATUS_ACTIVE;
    reacqs = [a for a in [m -->[?:Alert]] if a.kind == "reacquired"];
    assert len(reacqs) == 1;
    assert reacqs[0].severity == "warning";    # dark reacquire outranks info
}

test "a two-frame AIS gap resumes silently" {
    m = _mission();
    _feed_transit(m, 7);
    _run_frame(m, 210.0, []);
    _run_frame(m, 240.0, []);                  # coasting, 1 dark frame counted
    _run_frame(m, 270.0, [_meas("g1", 270.0, 1350.0, 0.0)]);
    trk = [m -->[?:Track]][0];
    assert trk.status == STATUS_ACTIVE;
    assert [a for a in [m -->[?:Alert]] if a.kind == "reacquired"] == [];
}

test "zone entry creates InZone edge and an intrusion alert" {
    m = _mission();
    z = Zone(
        zone_id="box", name="Box", kind="sanctuary",
        ring=[[400.0, -50.0], [900.0, -50.0], [900.0, 50.0], [400.0, 50.0]],
    );
    m ++> z;
    _run_frame(m, 0.0, [_meas("z1", 0.0, 200.0, 0.0)]);
    _run_frame(m, 30.0, [_meas("z2", 30.0, 350.0, 0.0)]);
    _run_frame(m, 60.0, [_meas("z3", 60.0, 500.0, 0.0)]);   # inside now
    trk = [m -->[?:Track]][0];
    assert "box" in trk.zones_in;
    assert len([edge trk ->:InZone:->]) == 1;
    intr = [a for a in [m -->[?:Alert]] if a.kind == "intrusion"];
    assert len(intr) == 1;
}
