"""Phase 5 acceptance tests for jac/brief.jac -- the brief PANEL data/walker
layer that sits on top of jac/jtms.jac's deterministic explain()/brief_for().

Scope note: this file tests ``jac/brief.jac`` only. jtms.jac's own
propagation/explain()/brief_for() correctness is covered by
tests/test_jtms.py and is treated here as an already-verified source of
truth -- these tests never re-check IN/OUT propagation logic itself, only
that brief.jac consumes it correctly.

Marked ``@pytest.mark.jac`` because it needs jaclang on a Python 3.12
interpreter, matching tests/test_jtms.py and tests/test_geofence_jac.py;
deselect with ``-m "not jac"``. The module is driven in-process via
jaclang's meta importer (``import jaclang`` then ``import brief``).

LLM PATH NOTE (read before touching the LLM-path tests below)
-----------------------------------------------------------------
No real LLM provider API key is configured in this environment (checked:
no OPENAI_API_KEY/ANTHROPIC_API_KEY/etc.). brief.jac defaults to "mockllm"
(byllm's offline stub, same convention as origin/abhi/web-frontend's
alerts.jac), which DOES succeed here -- but a mockllm success is not a
genuine billed LLM call, so its cost_usd is honestly 0.0, not > 0. Per the
task's own instructions ("if it does NOT work in this environment ... test
the FALLBACK path thoroughly instead and mark clearly in a comment which
path is exercised and why"), this file:

  1. Tests the mockllm "success" tier as it actually behaves here
     (model_used == "mockllm", not "template"; cost_usd == 0.0, honestly,
     since no real billing occurred) -- test_mockllm_tier_succeeds_honestly.
  2. Thoroughly tests the FALLBACK-TO-TEMPLATE path by pointing
     brief.set_llm_model() at a real-but-unregistered model name
     ("definitely-not-a-real-model-xyz"), which makes both the byllm tier
     and the direct-litellm tier fail immediately with a genuine litellm
     BadRequestError (verified manually: no network access or API key
     needed, litellm rejects an unroutable model name synchronously) --
     this is the "reasonable attempt, then fall back" path fully exercised,
     offline and deterministically.
"""

from __future__ import annotations

import json
import os
import sys

import pytest

pytestmark = pytest.mark.jac

_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_JAC_DIR = os.path.join(_REPO_ROOT, "jac")

_BAD_MODEL = "definitely-not-a-real-model-xyz"


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture(scope="module")
def jtms_mod():
    """The compiled jac/jtms.jac, imported as a Python module."""
    pytest.importorskip("jaclang", reason="jaclang (Python 3.12+) not installed")
    import jaclang  # noqa: F401  -- installs the .jac meta importer

    if _JAC_DIR not in sys.path:
        sys.path.insert(0, _JAC_DIR)
    import jtms as jac_jtms

    return jac_jtms


@pytest.fixture(scope="module")
def brief_mod(jtms_mod):
    """The compiled jac/brief.jac, imported as a Python module.

    Depends on jtms_mod purely for import ordering / sys.path setup; brief.jac
    imports jtms itself (Jac-importing-Jac, plain sibling `import jtms;`)."""
    pytest.importorskip("byllm", reason="byllm not installed")
    pytest.importorskip("litellm", reason="litellm not installed")

    if _JAC_DIR not in sys.path:
        sys.path.insert(0, _JAC_DIR)
    import brief as jac_brief

    return jac_brief


@pytest.fixture
def b(brief_mod, jtms_mod):
    """A fully clean slate for each test: jtms graph, cost ledger, and the
    LLM model box all reset. This is the exact triple ACCEPTANCE 9 in this
    file's own test list asks for: jtms.reset() + reset_ledger() (+ the LLM
    model restored to default) leave nothing behind for the next test."""
    jtms_mod.reset()
    brief_mod.reset_ledger()
    brief_mod.reset_llm_model()
    yield brief_mod
    # Leave no bad model configured for whatever runs next in this session.
    brief_mod.reset_llm_model()


def build_mmsi_spoof(b) -> None:
    """The shared jtms fixture, unmodified -- do not invent a different one
    (per the task instructions), so this file and test_jtms.py cannot drift
    apart."""
    import jtms as jac_jtms
    jac_jtms.build_mmsi_spoof_demo()
    jac_jtms.propagate()


# ===========================================================================
# ACCEPTANCE 1: source_ids_for() on the mmsi-spoof scenario
# ===========================================================================

def test_source_ids_for_before_retraction(b):
    build_mmsi_spoof(b)

    ids = b.source_ids_for("identity_b_confirmed")
    assert ids == ["broadcast_b_mmsi", "spoof_detected"]


def test_source_ids_for_after_retraction_reflects_real_behaviour(b):
    """After retract('broadcast_b_mmsi'), identity_b_confirmed's single
    justification (j_b1) is unchanged in STRUCTURE -- it still names the
    same antecedent and inhibitor, only their believed/satisfied state
    changed. source_ids_for() reads structure, not satisfaction, so the set
    (and order) is the same before and after. Asserting the REAL behaviour,
    not an assumption.
    """
    import jtms as jac_jtms
    build_mmsi_spoof(b)

    before = b.source_ids_for("identity_b_confirmed")
    jac_jtms.retract("broadcast_b_mmsi")
    after = b.source_ids_for("identity_b_confirmed")

    assert before == ["broadcast_b_mmsi", "spoof_detected"]
    assert after == before


def test_source_ids_for_deduplicates_across_justifications():
    """A Conclusion whose two OR'd justifications share an antecedent must
    report that antecedent only once, in first-seen order."""
    import jaclang  # noqa: F401
    if _JAC_DIR not in sys.path:
        sys.path.insert(0, _JAC_DIR)
    import jtms as jac_jtms
    import brief as jac_brief

    jac_jtms.reset()
    jac_brief.reset_ledger()
    jac_jtms.add_fact("shared", "a fact used by both justifications")
    jac_jtms.add_fact("only_b", "a fact used only by jB")
    jac_jtms.add_conclusion("c1", "derived from shared, or shared+only_b")
    jac_jtms.justify("c1", "jA", supports_ids=["shared"])
    jac_jtms.justify("c1", "jB", supports_ids=["shared", "only_b"])
    jac_jtms.propagate()

    assert jac_brief.source_ids_for("c1") == ["shared", "only_b"]


def test_source_ids_for_spoof_detected_lists_both_broadcasts_and_impossibility(b):
    build_mmsi_spoof(b)
    ids = b.source_ids_for("spoof_detected")
    assert ids == ["physically_impossible", "broadcast_a_mmsi", "broadcast_b_mmsi"]


# ===========================================================================
# ACCEPTANCE 2: determinism
# ===========================================================================

def test_source_ids_for_is_deterministic_for_unchanged_state(b):
    build_mmsi_spoof(b)

    first = b.source_ids_for("spoof_detected")
    second = b.source_ids_for("spoof_detected")
    assert first == second


# ===========================================================================
# ACCEPTANCE 3: panel_payload() -- genuinely JSON-serialisable
# ===========================================================================

def test_panel_payload_is_json_serialisable_full_llm_mode(b):
    build_mmsi_spoof(b)
    concl_ids = ["identity_a_confirmed", "identity_b_confirmed", "spoof_detected"]

    payload = b.panel_payload(concl_ids, use_llm=True)

    text = json.dumps(payload)  # raises TypeError if anything is non-primitive
    roundtripped = json.loads(text)
    assert roundtripped == payload

    assert len(payload) == 3
    for row in payload:
        assert set(row.keys()) == {
            "concl_id", "text", "model_used", "cost_usd", "source_ids", "status"
        }
        assert isinstance(row["concl_id"], str)
        assert isinstance(row["text"], str)
        assert isinstance(row["model_used"], str)
        assert isinstance(row["cost_usd"], float)
        assert isinstance(row["source_ids"], list)
        assert all(isinstance(x, str) for x in row["source_ids"])
        assert isinstance(row["status"], str)
        assert row["status"] in ("IN", "OUT")


def test_panel_payload_is_json_serialisable_template_only_mode(b):
    build_mmsi_spoof(b)
    concl_ids = ["identity_a_confirmed", "identity_b_confirmed", "spoof_detected"]

    payload = b.panel_payload(concl_ids, use_llm=False)

    json.dumps(payload)  # must not raise
    for row in payload:
        assert row["model_used"] == "template"
        assert row["cost_usd"] == 0.0


# ===========================================================================
# ACCEPTANCE 4: the LLM path -- mockllm succeeds honestly (see module docstring)
# ===========================================================================

def test_mockllm_tier_succeeds_honestly(b):
    """mockllm is the only reachable "successful" LLM tier in this
    environment (no real provider key configured). Confirms model_used is
    honestly reported as "mockllm" (never silently relabelled "template"),
    and that cost_usd stays 0.0 -- honest, since a mock call is never
    actually billed, not an invented plausible-looking number."""
    build_mmsi_spoof(b)

    brief_node = b.compose_brief("identity_a_confirmed", use_llm=True)

    assert brief_node.model_used == "mockllm"
    assert brief_node.model_used != "template"
    assert brief_node.cost_usd == 0.0
    assert isinstance(brief_node.polished_text, str)
    assert len(brief_node.polished_text) > 0

    summary = b.ledger_summary()
    assert summary["calls"] == 1
    assert summary["usd"] == 0.0


# ===========================================================================
# ACCEPTANCE 5: fallback-to-template path, forced offline and deterministically
# ===========================================================================

def test_fallback_to_template_when_both_llm_tiers_fail(b):
    """Point the model at a real-but-unregistered name: both the byllm tier
    and the direct-litellm tier fail fast with a genuine litellm
    BadRequestError (verified manually -- no network access or API key
    needed), driving Briefer all the way to the deterministic template
    tier. This is the thorough fallback-path test the task asks for given
    that no real provider key is configured here.
    """
    build_mmsi_spoof(b)
    b.set_llm_model(_BAD_MODEL)

    brief_node = b.compose_brief("identity_b_confirmed", use_llm=True)

    assert brief_node.model_used == "template"
    assert brief_node.cost_usd == 0.0
    assert brief_node.polished_text == brief_node.deterministic_text
    import jtms as jac_jtms
    assert brief_node.deterministic_text == jac_jtms.brief_for("identity_b_confirmed")


def test_fallback_to_template_does_not_touch_the_ledger(b):
    build_mmsi_spoof(b)
    b.set_llm_model(_BAD_MODEL)

    b.compose_brief("identity_a_confirmed", use_llm=True)
    b.compose_brief("identity_b_confirmed", use_llm=True)

    summary = b.ledger_summary()
    assert summary["calls"] == 0
    assert summary["usd"] == 0.0


def test_use_llm_false_skips_the_attempt_entirely_and_is_the_cheap_mode(b):
    build_mmsi_spoof(b)

    brief_node = b.compose_brief("spoof_detected", use_llm=False)

    assert brief_node.model_used == "template"
    assert brief_node.cost_usd == 0.0
    assert brief_node.polished_text == brief_node.deterministic_text

    summary = b.ledger_summary()
    assert summary["calls"] == 0


# ===========================================================================
# ACCEPTANCE 6: cost ledger bookkeeping
# ===========================================================================

def test_record_call_twice_accumulates(b):
    b.record_call("some-model", 0.01)
    b.record_call("some-model", 0.02)

    summary = b.ledger_summary()
    assert summary["calls"] == 2
    assert round(summary["usd"], 6) == 0.03


def test_reset_ledger_zeroes_it(b):
    b.record_call("some-model", 0.05)
    assert b.ledger_summary()["calls"] == 1

    b.reset_ledger()

    summary = b.ledger_summary()
    assert summary["calls"] == 0
    assert summary["usd"] == 0.0


def test_template_only_fallback_call_does_not_increment_ledger_via_compose(b):
    """The end-to-end version of the "template fallback does not count as a
    call" rule: driving it through compose_brief() with use_llm=False,
    rather than by calling record_call() directly."""
    build_mmsi_spoof(b)

    b.compose_brief("identity_a_confirmed", use_llm=False)
    b.compose_brief("identity_b_confirmed", use_llm=False)
    b.compose_brief("spoof_detected", use_llm=False)

    assert b.ledger_summary() == {"calls": 0, "usd": 0.0}


def test_full_llm_run_vs_cheaper_run_comparison(b):
    """The "34 calls / $0.41 against 3 calls / $0.04" comparison the build
    plan describes, reproduced at this scenario's scale (3 conclusions):
    a full LLM-per-conclusion run increments the ledger once per
    conclusion; a template-only run leaves it at zero."""
    build_mmsi_spoof(b)
    concl_ids = ["identity_a_confirmed", "identity_b_confirmed", "spoof_detected"]

    b.reset_ledger()
    b.panel_payload(concl_ids, use_llm=True)
    full_summary = b.ledger_summary()

    b.reset_ledger()
    b.panel_payload(concl_ids, use_llm=False)
    cheap_summary = b.ledger_summary()

    assert full_summary["calls"] == len(concl_ids)
    assert cheap_summary["calls"] == 0
    assert full_summary["calls"] > cheap_summary["calls"]


# ===========================================================================
# ACCEPTANCE 7: fallback-to-template path, exact field values
# ===========================================================================

def test_fallback_field_values_are_exact(b):
    build_mmsi_spoof(b)
    b.set_llm_model(_BAD_MODEL)

    brief_node = b.compose_brief("identity_a_confirmed", use_llm=True)

    assert brief_node.model_used == "template"
    assert brief_node.cost_usd == 0.0
    assert brief_node.polished_text == brief_node.deterministic_text


# ===========================================================================
# ACCEPTANCE 8: reset() on jtms + reset_ledger() together leave a clean slate
# ===========================================================================

def test_reset_together_leaves_a_fully_clean_slate_for_a_second_run(b):
    import jtms as jac_jtms

    build_mmsi_spoof(b)
    b.compose_brief("identity_a_confirmed", use_llm=True)
    assert b.ledger_summary()["calls"] == 1

    jac_jtms.reset()
    b.reset_ledger()
    b.reset_llm_model()

    assert jac_jtms.fact_ids() == []
    assert jac_jtms.conclusion_ids() == []
    assert b.ledger_summary() == {"calls": 0, "usd": 0.0}

    # Second scenario run in the same session: no pollution from the first.
    build_mmsi_spoof(b)
    assert jac_jtms.conclusion_status("identity_b_confirmed") == "OUT"
    payload = b.panel_payload(["identity_b_confirmed"], use_llm=True)
    assert payload[0]["status"] == "OUT"
    assert b.ledger_summary()["calls"] == 1
