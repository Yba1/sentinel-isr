"""ScenarioDriver: scripted-event dispatch as graph mutation.

One driver spawns on the Mission per frame. It reads the frame's raw,
unsuppressed measurement set from the Python replay layer and decides what
the tracker is allowed to see this tick:

  - ais_off / ais_on     flip the actor's ActorState switchboard node
  - radar_contact        samples a noisy unlabelled detection at the actor's
                         true (possibly dark) position, records it as a
                         Contact evidence node, and adds it to the frame
  - identity_change      swaps the actor's *display* identity on ActorState;
                         measurements are untouched because they carry no
                         identity to swap

The driver is replay-side scenario logic: it may consult ground truth (that
is HOW ais_off works), but nothing derived from identity flows into what the
Fusion walker feeds association -- only the surviving Measurement objects do,
and those are structurally identity-free.
"""

import numpy as np;
import from data.contracts { Measurement, RADAR_SIGMA_M }
import from data.scenario { true_position_at }
import from jac.graph { Mission, Contact, actor_state }


walker ScenarioDriver {
    has scenario: object = None;
    has frame: object = None;
    # Outputs, read by the Fusion walker and the renderer after the spawn:
    has effective: list = [];      # measurements the tracker may see this frame
    has injected: list = [];       # radar contacts added by events
    has suppressed_count: int = 0;
    has log: list = [];            # operator log lines, already formatted

    can dispatch with Mission entry {
        here.frame_idx = self.frame.idx;
        here.t = self.frame.t;

        # Events first: an ais_off at t must suppress the same frame's fix.
        for ev in self.frame.events {
            self.apply_event(here, ev);
        }

        for m in self.frame.measurements {
            actor = self.scenario.ground_truth[m.meas_id];
            st = actor_state(here, actor);
            if st.ais_suppressed {
                self.suppressed_count += 1;
                continue;
            }
            self.effective.append(m);
        }
        self.effective.extend(self.injected);
    }

    def apply_event(m: Mission, ev: object) -> None {
        st = actor_state(m, ev.actor);
        if ev.kind == "ais_off" {
            st.ais_suppressed = True;
            st.dark_since = ev.t;
            self.log.append(
                f"[{fmt_t(ev.t)}] EVENT ais_off: a vessel stopped transmitting"
            );
        } elif ev.kind == "ais_on" {
            st.ais_suppressed = False;
            st.dark_since = -1.0;
            self.log.append(
                f"[{fmt_t(ev.t)}] EVENT ais_on: transmission resumed"
            );
        } elif ev.kind == "radar_contact" {
            self.inject_radar(m, ev, st);
        } elif ev.kind == "identity_change" {
            old = st.display_id;
            st.display_id = str(ev.params["new_display_id"]);
            self.log.append(
                f"[{fmt_t(ev.t)}] EVENT identity_change: display identity "
                f"{old} -> {st.display_id}"
            );
        } else {
            raise ValueError(f"unknown scenario event kind {ev.kind}");
        }
    }

    def inject_radar(m: Mission, ev: object, st: object) -> None {
        # Scripted position wins; otherwise the actor's true (dark) position.
        if "x" in ev.params and "y" in ev.params {
            px = float(ev.params["x"]);
            py = float(ev.params["y"]);
        } else {
            pos = true_position_at(self.scenario.true_tracks[ev.actor], ev.t);
            if pos is None {
                raise ValueError(
                    f"radar_contact {ev.event_id}: {ev.actor} has no true "
                    f"position at t={ev.t}"
                );
            }
            px = pos[0];
            py = pos[1];
        }
        sigma = float(ev.params.get("sigma", RADAR_SIGMA_M));
        rng = m.meta["rng"];
        noise = rng.normal(0.0, sigma, 2);
        # mint_meas_id keeps the ground-truth side table the only place
        # identity exists -- the Measurement itself stays anonymous.
        mid = self.scenario.mint_meas_id(ev.actor);
        meas = Measurement(
            meas_id=mid,
            t=self.frame.t,
            x=px + float(noise[0]),
            y=py + float(noise[1]),
            source="radar",
            sigma=sigma,
        );
        m ++> Contact(
            meas_id=mid, t=self.frame.t, x=meas.x, y=meas.y,
            source="radar", sigma=sigma,
        );
        self.injected.append(meas);
        self.log.append(
            f"[{fmt_t(self.frame.t)}] EVENT radar_contact: unlabelled detection "
            f"at ({meas.x:.0f} E, {meas.y:.0f} N) sigma {sigma:.0f} m"
        );
    }
}


"""Seconds-since-start -> H:MM:SS for operator log lines."""
def fmt_t(t: float) -> str {
    h = int(t) // 3600;
    mnt = (int(t) % 3600) // 60;
    s = int(t) % 60;
    return f"{h}:{mnt:02d}:{s:02d}";
}


# ----------------------------------------------------------------------- tests

import from data.contracts { Frame, ScenarioEvent }
import from jac.graph { build_mission }


obj _FakeScenario {
    has ground_truth: dict = {};
    has true_tracks: dict = {};
    has seq: int = 0;

    def mint_meas_id(actor: str) -> str {
        mid = f"m{self.seq:06d}x";
        self.seq += 1;
        self.ground_truth[mid] = actor;
        return mid;
    }
}

def _mk_mission(sc: object) -> Mission {
    m = Mission(pack_id="test");
    root ++> m;
    m.meta["actor_states"] = {};
    m.meta["rng"] = np.random.default_rng(7);
    m.meta["scenario"] = sc;
    return m;
}

test "ais_off suppresses the same frame and onward" {
    sc = _FakeScenario();
    m1 = Measurement(meas_id="a1", t=0.0, x=0.0, y=0.0, source="ais", sigma=5.0);
    sc.ground_truth["a1"] = "ghost";
    ev = ScenarioEvent(event_id="e1", t=0.0, kind="ais_off", actor="ghost");
    frame = Frame(idx=0, t=0.0, measurements=(m1,), events=(ev,));
    m = _mk_mission(sc);
    d = ScenarioDriver(scenario=sc, frame=frame) spawn m;
    assert d.effective == [];
    assert d.suppressed_count == 1;
}

test "radar_contact injects an anonymous noisy detection with evidence node" {
    sc = _FakeScenario();
    sc.true_tracks["ghost"] = [(0.0, 100.0, 200.0), (30.0, 130.0, 200.0)];
    ev = ScenarioEvent(
        event_id="e2", t=30.0, kind="radar_contact", actor="ghost",
        params={"sigma": 50.0},
    );
    frame = Frame(idx=1, t=30.0, measurements=(), events=(ev,));
    m = _mk_mission(sc);
    d = ScenarioDriver(scenario=sc, frame=frame) spawn m;
    assert len(d.effective) == 1;
    contact = d.effective[0];
    assert contact.source == "radar";
    # Lands within 5 sigma of the true dark position.
    assert abs(contact.x - 130.0) < 250.0 and abs(contact.y - 200.0) < 250.0;
    # Identity lives only in the side table, never on the measurement.
    assert sc.ground_truth[contact.meas_id] == "ghost";
    assert len([m -->[?:Contact]]) == 1;
}

test "identity_change swaps display id on the switchboard only" {
    sc = _FakeScenario();
    ev = ScenarioEvent(
        event_id="e3", t=0.0, kind="identity_change", actor="spoofer",
        params={"new_display_id": "mmsi:999"},
    );
    frame = Frame(idx=0, t=0.0, measurements=(), events=(ev,));
    m = _mk_mission(sc);
    ScenarioDriver(scenario=sc, frame=frame) spawn m;
    assert actor_state(m, "spoofer").display_id == "mmsi:999";
}

test "ais_on restores transmission" {
    sc = _FakeScenario();
    m1 = Measurement(meas_id="a2", t=30.0, x=0.0, y=0.0, source="ais", sigma=5.0);
    sc.ground_truth["a2"] = "ghost";
    off = ScenarioEvent(event_id="e4", t=0.0, kind="ais_off", actor="ghost");
    on = ScenarioEvent(event_id="e5", t=30.0, kind="ais_on", actor="ghost");
    m = _mk_mission(sc);
    ScenarioDriver(scenario=sc, frame=Frame(idx=0, t=0.0, measurements=(), events=(off,))) spawn m;
    d2 = ScenarioDriver(scenario=sc, frame=Frame(idx=1, t=30.0, measurements=(m1,), events=(on,))) spawn m;
    assert len(d2.effective) == 1;
}
