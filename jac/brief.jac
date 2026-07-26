"""Phase 5 (ABHI layer, Option A backend): the brief PANEL data/walker layer
that sits on top of jac/jtms.jac's deterministic explain()/brief_for().

WHAT LIVES HERE AND WHY
------------------------
jac/jtms.jac's own module docstring says it explicitly: "by llm() brief
POLISH belongs to Abhi's layer, consuming YOUR deterministic
explain()/brief_for() output as its source of truth". THAT layer is this
file. jtms.jac's propagation logic (IN/OUT, retract/reinstate, explain,
brief_for) is READ-ONLY here -- this module never second-guesses it, only
consumes it.

This file builds the BACKEND/DATA contract for the brief panel described in
the build plan's ABHI Phase 5 spec: "Brief panel sliding in from the right,
each sentence carrying its source node IDs as a data attribute. Click-to-
justify -- highlights supporting nodes on the map and the subgraph in the
log... Cost counter -- LLM calls and dollars live." There is no frontend in
this repo yet (Abhi's real frontend lives on an unmerged branch), so this
module produces exactly the JSON-shaped payload such a frontend would
consume, with zero redesign needed once it merges:

  - `Brief` node / `compose_brief()`: one polished sentence per Conclusion,
    with an honest provenance marker (model_used) and cost.
  - `source_ids_for()`: the click-to-justify data -- every antecedent id a
    sentence depends on, flat and JSON-ready.
  - `CostLedger` / `record_call()` / `ledger_summary()`: the live cost
    counter, countable separately for a full LLM-per-conclusion run vs a
    cheaper template-only run (see `compose_brief(..., use_llm=False)`).
  - `panel_payload()`: the full per-conclusion dict list a WebSocket/JSON
    layer would ship straight to the browser.

`by llm()` PATTERN -- CONFIRMED AGAINST origin/abhi/web-frontend:jac/alerts.jac
--------------------------------------------------------------------------------
Read-only reference (`git show origin/abhi/web-frontend:jac/alerts.jac`,
this branch does not have that file). Its AlertScribe walker establishes the
pattern this module copies exactly: severity/structure is deterministic,
only the headline TEXT gets LLM polish, and the `by llm()` call lives INSIDE
a walker ability, never at module level -- module-level `by llm()` calls
have thrown NotImplementedError under jac-scale. Confirmed empirically while
building this file (see MODEL_BOX below) that a walker ability targeting a
real node archetype (not `root` itself) is what actually runs: `can X with
root entry` raised an internal "issubclass() arg 2 must be a class" error at
spawn time, while `can X with Brief entry` (a real archetype) works cleanly.

Three-tier fallback, same as AlertScribe: `by llm()` (byllm/Model) -> a
direct `litellm.completion()` call -> the deterministic text verbatim. Each
tier is tried inside `Briefer.compose`, and `model_used` records exactly
which one produced the text ("mockllm"/a real model name, "litellm-
fallback", or "template") -- "judges can trust the provenance marker", to
borrow alerts.jac's own phrasing for why this must be honest.

MODEL_BOX -- WHY A ONE-ELEMENT LIST, NOT A GLOB Model DIRECTLY
------------------------------------------------------------------
`by <expr>()` accepts any expression that evaluates to a Model, not just a
bare name (confirmed: `by MODEL_BOX[0]()` works exactly like `by llm()`
does in alerts.jac). Keeping the live Model in a mutable box, rather than a
plain `glob llm: Model = Model(...)`, lets `set_llm_model()` swap it at
runtime -- which is what makes the fallback path testable OFFLINE and
DETERMINISTICALLY: pointing MODEL_BOX at a real-but-unregistered model name
("definitely-not-a-real-model-xyz") makes both the byllm call and the
direct litellm call fail immediately with a real, fast litellm
BadRequestError (verified empirically, no network access needed and no
API key required), driving the walker all the way down to the template
tier. This is the FALLBACK path this module's test suite actually
exercises end to end (see tests/test_brief.py) -- there is no real LLM
provider API key configured in this environment, so "mockllm" (this
module's default, same convention as alerts.jac) is the only "successful"
LLM tier reachable here, and it is honestly not a billed call: cost_usd
stays 0.0 for it rather than inventing a number, per the epistemic-honesty
rule this whole project runs on.

EPISTEMIC HONESTY
------------------
The LLM polish is a REWRITE, never a re-derivation: `polish_text()`'s own
docstring instructs it to preserve every fact in the deterministic sentence
and add none. jtms.explain()/brief_for() remain the sole source of truth
for WHAT is true; this layer only ever touches how it reads.

JAC-IMPORTING-JAC
-------------------
Two Python-side invocation conventions exist in this repo: tracker/*.py uses
`from jac.X import Y` (repo root on sys.path, jac/ resolved as a package,
established by tracker/contracts.py and tracker/geofence.py), while
tests/test_jtms.py and tests/test_brief.py instead put jac/ ITSELF on
sys.path and `import jtms`/`import brief` as flat top-level modules. A plain
`import jtms;` here resolves under the second convention (and under bare
`jac run`) but raises `ModuleNotFoundError: No module named 'jtms'` under
the first, since jaclang's meta importer then sees this file as `jac.brief`
and looks for a sibling `jac.jtms`, not a top-level `jtms`. Caught by testing
`from jac.brief import panel_payload` directly, not assumed safe from the
tests/test_brief.py convention alone. Try both, so this module is not the
one file in the repo tied to a single invocation style.
"""

import os;
import litellm;
import from byllm.llm { Model }
import importlib;

def _resolve_jtms() -> object {
    # A bare module-level `try`/`except` around an `import` statement is a
    # parse error in Jac 0.16.7 (error[E0005]); a `try`/`except` INSIDE a
    # function body is ordinary control flow and compiles fine, so the
    # resolution has to happen here rather than at the top level.
    #
    # Under `from jac.brief import ...` this file is `jac.brief`, so a bare
    # `import jtms` looks for a top-level `jtms` module and raises
    # ModuleNotFoundError -- confirmed by testing that exact call, not
    # assumed safe from the `sys.path.insert(0, "jac"); import jtms`
    # convention tests/test_brief.py/test_jtms.py use alone.
    #
    # ORDER MATTERS, and got this wrong once: trying "jac.jtms" FIRST looked
    # right in isolation, but conftest.py puts the repo root on sys.path for
    # every pytest run, so "jac.jtms" ALSO resolves successfully even under
    # the flat-import test convention -- producing a SECOND, independent
    # jtms module instance with its own empty graph, disconnected from the
    # one the test fixtures actually populated via their own `import jtms`.
    # 15 of 17 tests in tests/test_brief.py failed with "unknown concl_id"
    # from exactly this state split before the order was reversed here.
    # Bare "jtms" first matches this file's own house convention and what
    # it was built and tested against; "jac.jtms" is the fallback for a
    # caller that only put the repo root (not jac/ itself) on sys.path.
    try {
        return importlib.import_module("jtms");
    } except Exception {
        return importlib.import_module("jac.jtms");
    }
}

glob jtms = _resolve_jtms();

# litellm prints a red "Provider List" banner to stderr on every mock/failed
# call; one flag turns it off (same fix as alerts.jac).
glob _quiet_litellm = setattr(litellm, "suppress_debug_info", True);

# mockllm keeps this whole module runnable offline and in tests, same
# convention as alerts.jac's LLM_MODEL_NAME. Set SENTINEL_LLM (e.g.
# "gpt-4o-mini") plus the provider key to go live.
glob LLM_MODEL_NAME: str = os.environ.get("SENTINEL_LLM", "mockllm");
glob LLM_MODEL_NAME_BOX: list = [LLM_MODEL_NAME];

glob _MOCK_OUTPUTS: list = [
    "Belief status update: this conclusion's support has just been "
    "recomputed from the justification graph.",
    "The evidence behind this conclusion has shifted, and its status "
    "now reflects that.",
    "This conclusion's justification structure was re-evaluated against "
    "current beliefs.",
];

glob MODEL_BOX: list = [Model(model_name=LLM_MODEL_NAME, config={"outputs": _MOCK_OUTPUTS * 20})];


def set_llm_model(name: str) -> None {
    """Swap the Model backing polish_text() at runtime.

    This is what makes the byllm -> litellm -> template fallback testable
    OFFLINE and deterministically: point this at a real-but-unregistered
    model name and both the byllm tier and the direct-litellm tier fail
    fast with a genuine litellm error, with no network access and no API
    key -- see the module docstring's MODEL_BOX section.

    `config={"outputs": list(_MOCK_OUTPUTS)}` copies the canned-outputs list
    rather than sharing `_MOCK_OUTPUTS` by reference: mockllm's Model POPS
    from its outputs list on every call (confirmed empirically -- it raises
    a plain IndexError once exhausted), so passing the same list object to
    every Model() call would silently deplete it across every reset in the
    same process and starve the mockllm tier after only len(_MOCK_OUTPUTS)
    total calls, process-wide.""";
    MODEL_BOX.clear();
    MODEL_BOX.append(Model(model_name=name, config={"outputs": _MOCK_OUTPUTS * 20}));
    LLM_MODEL_NAME_BOX[0] = name;
}


def reset_llm_model() -> None {
    """Restore the default model (SENTINEL_LLM env var, or "mockllm").""";
    set_llm_model(os.environ.get("SENTINEL_LLM", "mockllm"));
}


"""One-sentence rewrite of a deterministic JTMS brief sentence: same facts,
better prose. MUST NOT add, remove, or alter any factual claim present in
the input sentence -- only rephrase it. If nothing can be improved, return
it unchanged."""
def polish_text(deterministic_text: str) -> str by MODEL_BOX[0]();

sem polish_text.deterministic_text = "The exact deterministic JTMS brief_for() sentence to rewrite; preserve every fact stated in it, invent none.";


# ---------------------------------------------------------------------------
# Graph vocabulary
# ---------------------------------------------------------------------------

node Brief {
    has concl_id: str;
    has deterministic_text: str;
    has polished_text: str = "";
    has model_used: str = "";      # model name, "litellm-fallback", or "template"
    has cost_usd: float = 0.0;
    has source_ids: list = [];
}


node CostLedger {
    has total_calls: int = 0;
    has total_usd: float = 0.0;
}


glob LEDGER: list = [];    # [CostLedger] for the current process, like
                           # geofence.jac's HUB / jtms.jac's registries


def _ledger() -> CostLedger {
    """The current run's CostLedger, created on first use.""";
    if len(LEDGER) == 0 {
        l = CostLedger();
        root ++> l;
        LEDGER.append(l);
    }
    return LEDGER[0];
}


def record_call(model_used: str, cost_usd: float) -> None {
    """Count one ATTEMPTED LLM/litellm call.

    Only Briefer.compose's byllm-success and litellm-fallback branches call
    this -- the template branch never does, so a template-only fallback run
    does not inflate the ledger. This is what lets a caller compare "N
    conclusions x a real LLM call each" against "N conclusions, template
    only" honestly.""";
    l = _ledger();
    l.total_calls = l.total_calls + 1;
    l.total_usd = l.total_usd + cost_usd;
}


def ledger_summary() -> dict {
    l = _ledger();
    return {"calls": l.total_calls, "usd": l.total_usd};
}


def reset_ledger() -> None {
    """Zero the cost ledger for a fresh run/comparison.

    Same "abandon the old node, rebuild on next use" discipline as
    jtms.reset() / geofence.reset() -- LEDGER is process-local bookkeeping,
    not something read back off `root`.""";
    LEDGER.clear();
}


# ---------------------------------------------------------------------------
# source_ids_for() -- the click-to-justify data contract
# ---------------------------------------------------------------------------

def source_ids_for(concl_id: str) -> list {
    """Every antecedent (Fact or Conclusion) id across every justification of
    `concl_id`, deduplicated, in deterministic first-seen order (justification
    order, then within a justification: antecedents before inhibitors --
    JUST_ORDER's insertion order, which jtms.explain() already returns
    stably). This is exactly what a future 'click a sentence -> highlight
    supporting nodes' frontend feature would consume: a flat list of plain
    strings, ready to serialize with zero further processing.""";
    explanation = jtms.explain(concl_id);
    seen = set();
    ids = [];
    for j in explanation["justifications"] {
        for a in j["antecedents"] {
            if a["id"] not in seen {
                seen.add(a["id"]);
                ids.append(a["id"]);
            }
        }
        for i in j["inhibitors"] {
            if i["id"] not in seen {
                seen.add(i["id"]);
                ids.append(i["id"]);
            }
        }
    }
    return ids;
}


# ---------------------------------------------------------------------------
# Direct-litellm fallback (tier 2) -- bypasses byllm entirely
# ---------------------------------------------------------------------------

def _litellm_polish(text: str) -> dict {
    """Direct litellm completion, bypassing byllm -- the documented fallback
    for the module-level-`by llm()`-NotImplementedError failure mode (see
    the module docstring and origin/abhi/web-frontend:jac/alerts.jac's
    `_litellm_headline`). Returns {"text": ..., "cost": ...}; cost is a real
    litellm.completion_cost() estimate when one can be computed, else 0.0 --
    never an invented number.""";
    import litellm;
    resp = litellm.completion(
        model=LLM_MODEL_NAME_BOX[0],
        messages=[{
            "role": "user",
            "content": (
                "Rewrite this one sentence with clearer prose. Preserve "
                "every fact exactly; add nothing, remove nothing: " + text
            )
        }],
        max_tokens=60,
        timeout=10
    );
    out_text = resp.choices[0].message.content.strip();
    cost = 0.0;
    try {
        cost = float(litellm.completion_cost(completion_response=resp));
    } except Exception {
        cost = 0.0;
    }
    return {"text": out_text, "cost": cost};
}


# ---------------------------------------------------------------------------
# The Briefer walker -- three-tier fallback, exactly alerts.jac's discipline
# ---------------------------------------------------------------------------

walker Briefer {
    """Visits a freshly-built Brief node and upgrades polished_text via the
    LLM. Tier 1: `by llm()` (byllm/Model, via polish_text()). Tier 2: a
    direct litellm.completion() call. Tier 3 (always available): the
    deterministic text verbatim, model_used="template". Only tiers 1 and 2
    count as an attempted call for the cost ledger."""

    can compose with Brief entry {
        try {
            polished = polish_text(here.deterministic_text);
            here.polished_text = polished;
            here.model_used = LLM_MODEL_NAME_BOX[0];
            here.cost_usd = 0.0;    # honest: byllm gives no raw response to
                                     # cost, and mockllm is never billed
            record_call(here.model_used, here.cost_usd);
        } except Exception {
            try {
                result = _litellm_polish(here.deterministic_text);
                here.polished_text = result["text"];
                here.model_used = "litellm-fallback";
                here.cost_usd = result["cost"];
                record_call(here.model_used, here.cost_usd);
            } except Exception {
                here.polished_text = here.deterministic_text;
                here.model_used = "template";
                here.cost_usd = 0.0;
                # No record_call() here -- the template tier is free and
                # deliberately uncounted, see record_call()'s docstring.
            }
        }
    }
}


# ---------------------------------------------------------------------------
# Orchestration -- what a Python/JSON boundary actually calls
# ---------------------------------------------------------------------------

def compose_brief(concl_id: str, use_llm: bool = True) -> Brief {
    """Build one Brief node for `concl_id`: the deterministic substrate
    first (jtms.explain()/jtms.brief_for(), the ALREADY-VERIFIED source of
    truth -- never reimplemented or second-guessed here), then, if
    `use_llm`, attempt the LLM polish via Briefer's three-tier fallback.

    `use_llm=False` skips the LLM attempt ENTIRELY -- no ledger call at
    all, not even a failed one. This is the "cheaper mode" this module's
    cost-ledger comparison is built to demonstrate: a full LLM-per-
    conclusion run vs. a template-only run over the same conclusions.""";
    det_text = jtms.brief_for(concl_id);
    ids = source_ids_for(concl_id);
    b = Brief(
        concl_id=concl_id,
        deterministic_text=det_text,
        polished_text=det_text,
        model_used="template",
        cost_usd=0.0,
        source_ids=ids
    );
    root ++> b;
    if use_llm {
        b spawn Briefer();
    }
    return b;
}


def panel_payload(concl_ids: list, use_llm: bool = True) -> list {
    """The full payload a brief PANEL frontend would receive: one dict per
    concl_id, carrying the polished (or fallback) text, honest provenance,
    cost, click-to-justify source_ids, and current IN/OUT status.

    Every value is a plain str/float/int/bool/list -- JSON-serialisable
    with zero further processing (see tests/test_brief.py's json.dumps
    roundtrip test).""";
    out = [];
    for concl_id in concl_ids {
        b = compose_brief(concl_id, use_llm=use_llm);
        out.append({
            "concl_id": b.concl_id,
            "text": b.polished_text,
            "model_used": b.model_used,
            "cost_usd": float(b.cost_usd),
            "source_ids": list(b.source_ids),
            "status": jtms.conclusion_status(concl_id)
        });
    }
    return out;
}


# ---------------------------------------------------------------------------
# Demo. `with entry:__main__` so `import brief` from pytest does NOT run it.
# ---------------------------------------------------------------------------

with entry:__main__ {
    print("=== sentinel-isr :: phase 5 brief panel (mmsi spoof) ===");

    jtms.reset();
    reset_ledger();
    reset_llm_model();
    jtms.build_mmsi_spoof_demo();
    jtms.propagate();
    jtms.retract("broadcast_b_mmsi");

    concl_ids = ["identity_a_confirmed", "identity_b_confirmed", "spoof_detected"];

    print("");
    print("--- full LLM-per-conclusion run (use_llm=True, mockllm) ---");
    reset_ledger();
    full_payload = panel_payload(concl_ids, use_llm=True);
    for row in full_payload {
        print("  " + str(row));
    }
    full_summary = ledger_summary();
    print("  ledger: " + str(full_summary));

    print("");
    print("--- cheaper template-only run (use_llm=False) ---");
    reset_ledger();
    cheap_payload = panel_payload(concl_ids, use_llm=False);
    for row in cheap_payload {
        print("  " + str(row));
    }
    cheap_summary = ledger_summary();
    print("  ledger: " + str(cheap_summary));

    print("");
    print("--- comparison ---");
    print(
        "  full run:    " + str(full_summary["calls"]) + " calls / $"
        + str(full_summary["usd"])
    );
    print(
        "  cheaper run: " + str(cheap_summary["calls"]) + " calls / $"
        + str(cheap_summary["usd"])
    );

    print("");
    print("--- source_ids_for(identity_b_confirmed), click-to-justify data ---");
    print("  " + str(source_ids_for("identity_b_confirmed")));

    print("");
    print("=== ok ===");
}
