"""Fusion: the frame loop as a walker, one spawn per frame.

Sequence per spawn on the Mission node:

  1. `advance with Mission entry` -- predict every live filter to the frame
     epoch, run association (below), mint tentative tracks from the leftover
     detections, then `visit` the Track nodes.
  2. `apply with Track entry` -- each track applies its own outcome:
     `register_hit` + Kalman update, or `register_miss`. Raj's
     `tracker.assoc.Track` decides what that does to the lifecycle; this
     walker only reads the resulting status and turns transitions into graph
     consequences (zone edges, alerts, deltas).

TWO-STAGE ASSOCIATION. Raj's `max_assignable_sigma()` documents the binding
constraint: once a track's innovation sigma passes ~1197 m at the default
`beta_fa`, `cost_assign` exceeds `cost_miss + cost_birth` even at d2 = 0, so
the solver always prefers to call it missed and the measurement a birth. A
coasting vessel crosses that ceiling in about one minute, which would make
dark-vessel re-acquisition impossible in a single solve. He named two ways
out; this takes the second -- "a re-association step that does not put the
track in competition with birth in the same assignment":

  Stage 1  live tracks (tentative/confirmed) vs all measurements, at mission
           params. Ordinary tracking; births are decided here.
  Stage 2  coasting (dark) tracks vs only the leftovers, at REACQ_PARAMS.
           Nothing in this solve is a plausible birth -- stage 1 already
           declined to claim them -- so `beta_fa` can go low enough to lift
           the ceiling above a dark track's covariance.

Stage 2 is gated on physics, not on the filter: a CV covariance grows as
q*t^3/3 and is tens of kilometres wide after a few minutes, so a reachability
test at REACQ_MAX_SPEED_MPS from the track's last MEASURED fix is what
actually decides who may claim a detection.
"""

import from tracker.kalman { CVKalman }
import from tracker.assoc {
    Track as RTrack, AssocParams, associate_global, max_assignable_sigma,
}
import from data.geometry { innovation_stats, reachable }
import from jac.graph {
    Mission, Track, Zone, Alert, InZone,
    zones_of, tracks_of, mint_track_id,
    STATUS_TENTATIVE, STATUS_CONFIRMED, STATUS_COASTING, STATUS_DEAD,
    DARK_MIN_HITS, REACQ_MIN_COAST,
}
import from jac.alerts { raise_alert }
import from jac.driver { fmt_t }

# Mission params: Raj's defaults, with the deletion counter opened up. Holding
# a dark vessel long enough to re-acquire it IS the product, and his LLR floor
# is the better pruner anyway -- a weak track bleeds out on score long before
# 60 frames, while a well-evidenced one survives to be re-acquired.
glob MISSION_PARAMS = AssocParams(delete_after_misses=60);

# A vessel that has deliberately stopped transmitting is not a vessel we
# expected to detect and failed to. Scoring a dark track's silence at
# p_detect = 0.9 bleeds ~2.3 LLR per frame and kills it in minutes; at 0.05
# silence is nearly free evidence, which is the honest model. Applied only to
# `register_miss` on already-coasting tracks.
glob DARK_PARAMS = AssocParams(p_detect=0.05, delete_after_misses=60);

# Stage-2 params. beta_fa is set low enough that max_assignable_sigma clears
# the kinematic reach below by a wide margin -- the point is to take the
# numeric ceiling OFF the critical path so that physics, not the cost
# function, decides who may claim a detection. The invariant is pinned as a
# test. p_detect is honest about a dark contact only occasionally being
# painted by radar.
glob REACQ_PARAMS = AssocParams(
    p_detect=0.5, beta_fa=1e-11, delete_after_misses=60,
);

# ~39 kn: comfortably above anything in the bay, including the ferries.
glob REACQ_MAX_SPEED_MPS: float = 20.0;

# Stop trying after 10 minutes dark. Not a numerical limit -- a credibility
# one: at 20 m/s the reachable disc is already 12 km across, and re-attributing
# a detection anywhere in that circle is a claim we would not want to defend.
glob REACQ_MAX_GAP_S: float = 600.0;

# Two-point track birth: consecutive-frame detections must be kinematically
# reachable -- 15 m/s (~30 kn) across one 30 s frame, plus noise slack.
glob BIRTH_GATE_MPS: float = 15.0;


"""Provenance for the run summary: which associator ran, and the dark-vessel
ceiling the chosen params imply. Printed rather than assumed so nobody demos a
re-acquisition the numbers do not actually support."""
def assoc_provenance() -> str {
    return (
        f"tracker.assoc (global, padded Hungarian); reacq ceiling "
        f"{max_assignable_sigma(REACQ_PARAMS)/1000.0:.0f} km, "
        f"reach gate {REACQ_MAX_SPEED_MPS:.0f} m/s"
    );
}


walker Fusion {
    has t: float = 0.0;
    has dt: float = 30.0;
    has meas: list = [];               # from ScenarioDriver.effective
    # Outputs for the renderer / delta assembly:
    has new_alerts: list = [];
    has born: list = [];
    has dropped_ids: list = [];
    has log: list = [];
    has n_matched: int = 0;
    has n_reacquired: int = 0;
    # Internal: track_id -> (Measurement, d2, logdet_S) for the visit phase,
    # plus per-frame caches. Re-deriving mission/zones inside every Track
    # ability rescans the Mission node's whole adjacency (hundreds of children
    # on real traffic) and dominated the profile; one scan per frame is plenty.
    has assigned: dict = {};
    has mission: object = None;
    has zones: list = [];

    can advance with Mission entry {
        self.mission = here;
        self.zones = zones_of(here);
        live = tracks_of(here);

        # Predict every live filter to the frame epoch. The step is per-track:
        # one born mid-run has its kf.t at its birth frame.
        for trk in live {
            step = self.t - trk._rt.kf.t;
            if step > 0.0 {
                trk._rt.kf.predict(step);
            }
        }

        # Stage 1: tracks we are actively holding, against everything.
        primary = [t for t in live if t.status != STATUS_COASTING];
        leftovers = self.solve(primary, self.meas, MISSION_PARAMS);

        # Stage 2: dark tracks against what stage 1 declined, in their own
        # solve so they never bid against a birth at mission prices.
        dark = [t for t in live if t.status == STATUS_COASTING];
        leftovers = self.solve_reacquire(dark, leftovers);

        self.birth_tracks(here, leftovers);
        visit [here -->[?:Track]];
    }

    can apply with Track entry {
        if here.status == STATUS_DEAD {
            return;
        }
        if here.born_t == self.t and here.track_id not in self.assigned {
            # Born from this frame's leftovers: it cannot have an assignment
            # yet, and scoring that as a miss would penalise it for existing.
            here.sync_from_tracker();
            return;
        }
        if here.track_id in self.assigned {
            self.fuse_measurement(here, self.assigned[here.track_id]);
        } else {
            self.miss(here);
        }
        here.sync_from_tracker();
        if here.status == STATUS_DEAD {
            self.dropped_ids.append(here.track_id);
            self.log.append(
                f"[{fmt_t(self.t)}] TRACK {here.track_id} deleted "
                f"(misses={here.misses}, score={here.llr:.1f})"
            );
        } else {
            self.check_zones(here);
        }
    }

    # ------------------------------------------------------------ association

    """Run one association solve and return the Measurements it left over.
    Records assignments (with the statistics `register_hit` needs) for the
    visit phase."""
    def solve(nodes: list, meas: list, params: object) -> list {
        if not nodes or not meas {
            return list(meas);
        }
        rts = [n._rt for n in nodes];
        zs = [[m.x, m.y] for m in meas];
        Rs = [m.R() for m in meas];
        res = associate_global(rts, zs, Rs, params=params);

        for (ti, mi) in res.assignments {
            trk = nodes[ti];
            m = meas[mi];
            (d2, logdet) = innovation_stats(trk._rt.kf, [m.x, m.y], m.R());
            self.assigned[trk.track_id] = (m, d2, logdet, params);
            self.n_matched += 1;
        }
        return [meas[i] for i in res.unassigned_meas];
    }

    """Stage 2: give dark tracks a shot at the leftovers, alone.

    The reachability pre-filter is what makes this safe. A track dark for ten
    minutes has a covariance tens of kilometres wide and would otherwise pass
    the chi-squared gate on almost any detection in the bay; a vessel that
    physically could not have got there is excluded before the solver sees
    it."""
    def solve_reacquire(dark: list, meas: list) -> list {
        if not dark or not meas {
            return list(meas);
        }
        fresh = [t for t in dark if self.t - t.last_t <= REACQ_MAX_GAP_S];
        if not fresh {
            return list(meas);
        }
        candidates = [];
        for m in meas {
            for trk in fresh {
                gap = self.t - trk.last_t;
                if reachable(trk.last_fix_x, trk.last_fix_y, m.x, m.y,
                             gap, REACQ_MAX_SPEED_MPS) {
                    candidates.append(m);
                    break;
                }
            }
        }
        if not candidates {
            return list(meas);
        }
        claimed = self.solve(fresh, candidates, REACQ_PARAMS);
        unclaimed = {m.meas_id for m in claimed};
        return [
            m for m in meas
            if m not in candidates or m.meas_id in unclaimed
        ];
    }

    # ------------------------------------------------------------ per track

    def fuse_measurement(trk: Track, assignment: tuple) -> None {
        (m, d2, logdet, params) = assignment;
        was_coasting = trk.status == STATUS_COASTING;
        dark_frames = trk.misses;

        # Raj's Track scores the association and moves the lifecycle; the
        # filter update is a separate, deliberate step.
        trk._rt.register_hit(d2, logdet, params=params);
        trk._rt.kf.update(m.z(), m.R());

        trk.last_t = self.t;
        trk.last_source = m.source;
        trk.last_meas_id = m.meas_id;
        trk.last_fix_x = m.x;
        trk.last_fix_y = m.y;

        if was_coasting {
            # The reacquire moment: an unlabelled detection fused into a track
            # that had been running on prediction alone. A two-frame AIS gap
            # is routine and resumes silently; a real dark period alerts.
            self.n_reacquired += 1;
            if dark_frames >= REACQ_MIN_COAST {
                a = raise_alert(
                    self.mission, trk, "reacquired", None, self.t, [m.meas_id],
                );
                self.new_alerts.append(a);
                self.log.append(
                    f"[{fmt_t(self.t)}] TRACK {trk.track_id} reacquired via "
                    f"{m.source} detection after {dark_frames} frames dark "
                    f"(d2={d2:.1f})"
                );
            }
        } elif trk.status == STATUS_TENTATIVE
                and trk._rt.status == STATUS_CONFIRMED {
            self.log.append(
                f"[{fmt_t(self.t)}] TRACK {trk.track_id} confirmed "
                f"({trk._rt.hits} fixes, score {trk._rt.llr:.1f})"
            );
        }
    }

    def miss(trk: Track) -> None {
        was_live = trk.status != STATUS_COASTING;
        # Silence from a vessel that already went dark is weak evidence of
        # absence, so it is scored under DARK_PARAMS. See the glob comment.
        trk._rt.register_miss(
            params=MISSION_PARAMS if was_live else DARK_PARAMS,
        );
        if was_live and trk._rt.status == STATUS_COASTING {
            trk.was_dark = True;
            # Real bay traffic has hundreds of vessels with ragged AIS
            # coverage; a track without history going quiet is noise, not an
            # alert. The state still flips so the ellipse grows either way.
            if trk._rt.hits >= DARK_MIN_HITS {
                a = raise_alert(self.mission, trk, "went_dark", None, self.t, []);
                self.new_alerts.append(a);
                self.log.append(
                    f"[{fmt_t(self.t)}] TRACK {trk.track_id} went dark; "
                    f"coasting on prediction"
                );
            }
        }
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
            tid = mint_track_id(m);
            rt = RTrack(
                id=m.meta["next_track"], kf=kf, params=MISSION_PARAMS,
            );
            # Two detections already went into the two-point initialiser, so
            # seed the history with them rather than letting the track claim
            # confirmation on measurements it has not seen yet.
            rt.hits = 2;
            rt.hit_history.append(True);
            rt.hit_history.append(True);
            trk = Track(
                track_id=tid,
                _rt=rt,
                born_t=self.t,
                last_t=self.t,
                last_source=best.source,
                last_meas_id=best.meas_id,
                last_fix_x=best.x,
                last_fix_y=best.y,
            );
            trk.sync_from_tracker();
            m ++> trk;
            self.born.append(tid);
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
    return Fusion(t=t, dt=30.0, meas=meas) spawn m;
}

test "two detections birth a tentative track; third confirms it" {
    m = _mission();
    _run_frame(m, 0.0, [_meas("s1", 0.0, 0.0, 0.0)]);
    _run_frame(m, 30.0, [_meas("s2", 30.0, 150.0, 0.0)]);
    trks = [m -->[?:Track]];
    assert len(trks) == 1;
    assert trks[0].status == STATUS_TENTATIVE;
    _run_frame(m, 60.0, [_meas("s3", 60.0, 300.0, 0.0)]);
    assert trks[0].status == STATUS_CONFIRMED;      # Raj's 3-of-5 window
    assert abs(trks[0].vx - 5.0) < 2.0;             # ~5 m/s eastbound
}

test "the graph never writes lifecycle state, it projects it" {
    m = _mission();
    _feed_transit(m, 4);
    trk = [m -->[?:Track]][0];
    assert trk.status == trk._rt.status;
    assert trk.hits == trk._rt.hits;
    assert trk.llr == trk._rt.llr;
    assert trk.llr > 0.0;      # accumulating evidence
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
    f = _run_frame(m, 360.0, [_meas("rr", 360.0, 1790.0, 10.0, "radar")]);
    trk = [m -->[?:Track]][0];
    assert trk.status == STATUS_CONFIRMED;
    assert f.n_reacquired == 1;
    reacqs = [a for a in [m -->[?:Alert]] if a.kind == "reacquired"];
    assert len(reacqs) == 1;
    assert reacqs[0].severity == "warning";    # dark reacquire outranks info
}

test "the numeric ceiling is off the critical path; kinematics bind" {
    # Raj's max_assignable_sigma is what kills dark re-association at default
    # params. Stage 2 is only honest if that ceiling clears the widest claim
    # the reachability gate can ever allow -- otherwise the cost function is
    # silently vetoing physically plausible re-acquisitions.
    reach = REACQ_MAX_SPEED_MPS * REACQ_MAX_GAP_S;
    assert max_assignable_sigma(REACQ_PARAMS) > reach;
    # And the mission default must NOT clear it -- that is why stage 2 exists.
    assert max_assignable_sigma(MISSION_PARAMS) < reach;
}

test "reachability, not covariance, bounds re-acquisition" {
    m = _mission();
    _feed_transit(m, 7);
    for i in range(5) {
        _run_frame(m, 210.0 + 30.0 * i, []);
    }
    # 150 s dark: the filter's ellipse is kilometres wide and would gate this
    # in, but 80 km away is not somewhere a ship can have got to.
    f = _run_frame(m, 360.0, [_meas("far", 360.0, 80_000.0, 0.0, "radar")]);
    trk = [m -->[?:Track]][0];
    assert trk.status == STATUS_COASTING;      # not claimed
    assert f.n_reacquired == 0;
}

test "a two-frame AIS gap resumes silently" {
    m = _mission();
    _feed_transit(m, 7);
    _run_frame(m, 210.0, []);
    _run_frame(m, 240.0, []);                  # coasting, 1 dark frame counted
    _run_frame(m, 270.0, [_meas("g1", 270.0, 1350.0, 0.0)]);
    trk = [m -->[?:Track]][0];
    assert trk.status == STATUS_CONFIRMED;
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
