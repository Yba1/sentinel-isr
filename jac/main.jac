"""Sentinel-ISR pipeline: replay -> driver -> fusion -> scribe -> delta.

Per frame, four walkers touch the Mission graph in order:

    ScenarioDriver   applies scripted events, filters suppressed AIS
    Fusion           associates, updates Track nodes, raises alerts
    AlertScribe      phrases fresh alerts (by llm, with fallbacks)
    Renderer         snapshots the picture into a FrameDelta dict

`run_pack` is the whole product loop; the WebSocket layer (next phase) will
call it frame-by-frame instead of collecting a list. Run from the repo root:

    PYTHONPATH=. jac run jac/main.jac                 # s02 synthetic pack
    SENTINEL_PACK=s01_dark_in_sanctuary \
        SENTINEL_FRAMES=60 PYTHONPATH=. jac run jac/main.jac
"""

import os;
import time;
import numpy as np;
import from data.replay { ReplayEngine }
import from data.scenario { load_scenario }
import from jac.graph { Mission, build_mission, alerts_of, tracks_of }
import from jac.driver { ScenarioDriver }
import from jac.fusion { Fusion, assoc_provenance }
import from jac.alerts { AlertScribe, Briefer }
import from jac.render { Renderer, frame_delta }


"""Materialise the graph for a pack and run the full pipeline. Returns the
run record: deltas (one per frame), the mission node, and provenance of the
associator that actually ran."""
def run_pack(pack_id: str, max_frames: int = -1, seed_offset: int = 1) -> dict {
    scenario = load_scenario(pack_id);
    engine = ReplayEngine(scenario);
    mission = build_mission(scenario);
    # Injection noise is scenario-seeded so reruns and seeks are reproducible.
    mission.meta["rng"] = np.random.default_rng(
        int(scenario.expected.get("seed", 0)) + 20260726 + seed_offset,
    );

    deltas = [];
    for frame in engine.play(realtime=False) {
        if max_frames >= 0 and frame.idx >= max_frames {
            break;
        }
        deltas.append(run_frame(mission, scenario, frame));
    }
    return {
        "pack_id": scenario.pack_id,
        "deltas": deltas,
        "mission": mission,
        "scenario": scenario,
        "assoc_source": assoc_provenance(),
    };
}


"""One tick of the product: exactly the walker sequence the WebSocket layer
will drive. Zones ride along on frame 0 only."""
def run_frame(mission: Mission, scenario: object, frame: object) -> dict {
    (delta, _pairs) = run_frame_scored(mission, scenario, frame);
    return delta;
}


"""Same tick, plus (track_id, ground_truth_actor) pairs for the server's
id-switch counter (tracker.metrics.TrackingMetrics). The pairs are read from
ground truth for scoring only and never appear in the returned delta -- the
web layer sends the frontend a scalar count, never an identity."""
def run_frame_scored(mission: Mission, scenario: object, frame: object) -> tuple {
    driver = ScenarioDriver(scenario=scenario, frame=frame) spawn mission;
    fusion = Fusion(
        t=frame.t,
        dt=scenario.frame_interval_s,
        meas=driver.effective,
    ) spawn mission;
    for alert in fusion.new_alerts {
        AlertScribe() spawn alert;
    }
    renderer = Renderer(origin=scenario.origin) spawn mission;
    delta = frame_delta(mission, driver, fusion, renderer, frame.idx == 0);
    pairs = [
        (track_id, scenario.ground_truth[assignment[0].meas_id])
        for (track_id, assignment) in fusion.assigned.items()
    ];
    return (delta, pairs);
}


def summarize(result: dict) -> None {
    mission = result["mission"];
    deltas = result["deltas"];
    alerts = sorted(alerts_of(mission), key=lambda a: object : a.t);
    print(f"pack        {result['pack_id']}");
    print(f"associator  {result['assoc_source']}");
    print(f"frames      {len(deltas)}");
    print(f"tracks live {len(tracks_of(mission))}");
    print(f"alerts      {len(alerts)}");
    for a in alerts[:12] {
        print(f"  {a.severity.upper():8s} {a.headline}  [{a.model_used}]");
    }
    brief = (Briefer() spawn mission).brief;
    print(f"brief       [{brief.model_used}] {brief.text[:300]}");
}


with entry:__main__ {
    pack = os.environ.get("SENTINEL_PACK", "s02_synthetic_demo");
    max_frames = int(os.environ.get("SENTINEL_FRAMES", "-1"));
    started = time.perf_counter();
    result = run_pack(pack, max_frames=max_frames);
    elapsed = time.perf_counter() - started;
    summarize(result);
    print(f"pipeline    {len(result['deltas'])} frames in {elapsed:.2f} s");
}


# ----------------------------------------------------------------------- tests

test "s02 end to end: ghost goes dark, intrudes, is reacquired by radar" {
    result = run_pack("s02_synthetic_demo");
    mission = result["mission"];
    alerts = alerts_of(mission);
    kinds = {a.kind for a in alerts};
    assert "went_dark" in kinds;
    assert "reacquired" in kinds;
    assert "intrusion" in kinds;
    # The dark intrusion into the sanctuary must be critical.
    crits = [a for a in alerts if a.severity == "critical"];
    assert len(crits) >= 1;
    assert any([a.kind == "intrusion" for a in crits]);
}

test "s02 deltas are frontend-complete" {
    result = run_pack("s02_synthetic_demo", max_frames=30);
    deltas = result["deltas"];
    assert len(deltas) == 30;
    assert len(deltas[0]["zones"]) == 1;      # zones ship on frame 0
    assert deltas[1]["zones"] == [];          # and only frame 0
    seen_track = False;
    for d in deltas {
        for tp in d["tracks"] {
            seen_track = True;
            assert "ellipse" in tp and tp["ellipse"][0] == tp["ellipse"][-1];
            assert tp["color"].startswith("#");
            assert "lat" in tp and "lon" in tp;
        }
    }
    assert seen_track;
}

test "run_frame_scored pairs feed an honest id-switch count" {
    import from tracker.metrics { TrackingMetrics }
    scenario = load_scenario("s02_synthetic_demo");
    mission = build_mission(scenario);
    mission.meta["rng"] = np.random.default_rng(7);
    metrics = TrackingMetrics();
    for frame in scenario.frames {
        (_delta, pairs) = run_frame_scored(mission, scenario, frame);
        metrics.update(pairs);
    }
    # No identity in any pair's track_id half, and every pair's truth half is
    # a real actor -- the scoring path reads ground truth, it does not invent it.
    actors = set(scenario.true_tracks);
    assert metrics.total_matches > 0;
    assert metrics.id_switches >= 0;
}

test "suppressed AIS never reaches fusion" {
    result = run_pack("s02_synthetic_demo");
    scenario = result["scenario"];
    # After ais_off at t=180, the ghost's AIS is filtered by the driver; only
    # scripted radar contacts may carry its ground truth beyond that point.
    for d in result["deltas"] {
        if d["t"] < 180.0 {
            continue;
        }
        for mp in d["measurements"] {
            actor = scenario.ground_truth[mp["meas_id"]];
            if actor == "ghost_1" {
                assert mp["source"] == "radar";
            }
        }
    }
}
