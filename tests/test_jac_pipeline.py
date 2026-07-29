"""End-to-end tests of the Jac pipeline, driven from Python.

`import jaclang` registers the .jac meta-importer, after which the walkers
are ordinary importable objects. This is exactly how the WebSocket layer will
embed the pipeline, so these tests double as the integration contract.

The finer-grained behavioural tests live as `test` blocks inside the .jac
modules themselves; run them with:  PYTHONPATH=. jac test jac/<module>.jac
"""

import os

import pytest

import jaclang  # noqa: F401  -- registers the .jac import hook

from jac.main import run_pack  # type: ignore  # .jac module via meta-importer
from jac.graph import alerts_of, tracks_of  # type: ignore

S01_CSV = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "scenarios", "s01_dark_in_sanctuary", "ais_window.csv",
)


@pytest.fixture(scope="module")
def s02_run():
    return run_pack("s02_synthetic_demo")


def test_pipeline_tells_the_whole_story(s02_run):
    """Dark -> intrusion (critical) -> radar reacquire, all as Alert nodes."""
    alerts = alerts_of(s02_run["mission"])
    kinds = {a.kind for a in alerts}
    assert {"went_dark", "intrusion", "reacquired"} <= kinds
    crit = [a for a in alerts if a.severity == "critical"]
    assert any(a.kind == "intrusion" for a in crit)
    # Provenance is honest about which associator ran.
    assert "assoc" in s02_run["assoc_source"] or "tracker" in s02_run["assoc_source"]


def test_every_alert_has_headline_and_provenance(s02_run):
    for a in alerts_of(s02_run["mission"]):
        assert a.headline
        assert a.detail
        assert a.model_used in ("mockllm", "litellm-fallback", "template") or a.model_used


def test_deltas_are_render_ready(s02_run):
    """The dumb-frontend contract: nothing left for JavaScript to compute."""
    deltas = s02_run["deltas"]
    assert len(deltas) == 121
    assert deltas[0]["zones"], "zones must ship on frame 0"
    for d in deltas:
        assert set(d) >= {"frame_idx", "t", "clock", "tracks", "measurements",
                          "alerts", "log", "removed_track_ids", "stats"}
        for tp in d["tracks"]:
            assert tp["ellipse"][0] == tp["ellipse"][-1]
            assert tp["color"].startswith("#")
            assert "lat" in tp and "speed_kn" in tp and "label" in tp


def test_dark_ellipse_grows_while_coasting(s02_run):
    """The visual story: the ghost's uncertainty balloons between radar fixes.

    Measured over the first unbroken dark stretch rather than fixed frame
    numbers, so retiming the scripted radar contacts cannot quietly turn this
    into a test of nothing.
    """
    def ghost_extent(d):
        for tp in d["tracks"]:
            if tp["dark"]:
                xs = [p[0] for p in tp["ellipse"]]
                return max(xs) - min(xs)
        return None

    run = []
    for d in s02_run["deltas"]:
        extent = ghost_extent(d)
        if extent is not None:
            run.append(extent)
        elif run:
            break                   # first dark stretch ended at a radar fix

    assert len(run) >= 3, "expected a multi-frame dark stretch"
    assert run[-1] > 3 * run[0]


def test_identity_never_reaches_a_delta(s02_run):
    """No actor key or MMSI string may appear anywhere in the stream."""
    import json
    blob = json.dumps(s02_run["deltas"])
    assert "ghost_1" not in blob
    assert "mmsi:" not in blob


@pytest.mark.skipif(not os.path.isfile(S01_CSV), reason="s01 window not extracted")
def test_s01_real_traffic_smoke():
    """First 40 frames of the real pack: hundreds of vessels through the full
    Jac loop, and the sanctuary ships with real geometry."""
    result = run_pack("s01_dark_in_sanctuary", max_frames=40)
    mission = result["mission"]
    assert len(result["deltas"]) == 40
    assert len(tracks_of(mission)) > 200
    # Zone id from Omar's authored s01 pack (monterey_bay_nms), which replaced an
    # earlier placeholder pack that shipped two different demo zone ids
    # (central_bay_sanctuary / gate_approach_restricted) -- this test predated
    # that swap and was never updated to the real pack's actual geofence_layers.
    zones = result["deltas"][0]["zones"]
    assert {z["zone_id"] for z in zones} == {"monterey_bay_nms"}
