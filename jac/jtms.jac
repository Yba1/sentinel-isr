"""Phase 5 (Option A): a justification-based truth maintenance system (JTMS),
as a Jac graph -- Doyle 1979, IN/OUT belief propagation to a fixpoint.

WHAT LIVES HERE AND WHY
------------------------
Every other phase in this repo splits numerical kernels (Python) from state and
rules (Jac). This phase has no numerical kernel at all: a JTMS is nothing but a
dependency graph and a propagation rule, so the whole feature lives here, in
Jac, the same way the hypothesis lifecycle (jac/hypothesis.jac) and the
geofence transition rules (jac/geofence.jac) do. No matrix, no LLM call, no
network I/O -- deterministic graph math only, same discipline as this
project's "no LLM calls inside the filter or association loop" rule.

THE DEMO BEAT
-------------
Two synthetic vessels broadcast the same MMSI simultaneously, 40 km apart --
physically impossible, so one broadcast is a spoof. Conclusions were drawn
believing BOTH broadcasts ("vessel_a is confirmed as this MMSI", "vessel_b is
confirmed as this MMSI"). Once an operator (or the system) decides the b
broadcast is the fake one and retracts the underlying Fact, every Conclusion
that depended on it must flip automatically, to a fixpoint, and a
human-readable brief must be regeneratable from the surviving conclusions.
This is Reid MHT (Phase 3) territory upgraded: showing the belief revision
LIVE, on stage, is the new part.

THE MODEL -- classic JTMS justification structure
--------------------------------------------------
A `Fact` is a raw, directly-assertable premise: `believed` is the thing that
gets retracted / reinstated. A `Conclusion` is derived and its `status` ("IN"
or "OUT") is never set directly -- it is always RECOMPUTED from the
justification graph.

A Conclusion can have one or more JUSTIFICATIONS (an OR across justifications:
the Conclusion is IN iff at least one justification is satisfied). Each
justification is itself an AND-group: a set of ANTECEDENTS (Facts or other
Conclusions, via a `supports` edge) that must ALL be IN/believed, and a set of
INHIBITORS (via a `refutes` edge) that must ALL be OUT/not-believed. Edges
sharing the same `justification_id` belong to the same AND-group; distinct
justification_ids on the same Conclusion are the OR.

This is what makes the mmsi-spoof fixture interesting: `spoof_detected`
refutes `identity_b_confirmed`'s only justification, so even though
`broadcast_b_mmsi` is nominally still "believed" as a raw Fact, the
Conclusion built on it is blocked (OUT) the moment the impossibility is
noticed -- propagation on GRAPH CONSTRUCTION, not only on an explicit
retract() call. See `mmsi_spoof_demo()` below and tests/test_jtms.py for the
full worked trace.

INTEGRATION SEAM -- alignment with Abhi's unmerged jac/graph.jac
------------------------------------------------------------------
On origin/abhi/jac-boundary:jac/graph.jac (read-only reference; NOT imported
here, and not present in this tree), edges include `supports` / `refutes` /
`derived_from`, and node kinds include `Conclusion` / `Alert` / `Brief`. This
file is deliberately self-contained -- it does not import his module -- but
DELIBERATELY reuses his names where they overlap: the `Conclusion` node kind
and the `supports` / `refutes` edge kinds here are meant to be the SAME
vocabulary, so that a later merge is a rename-free drop-in rather than a
redesign. This file does not need `derived_from`, `Alert`, or `Brief` as
first-class graph citizens -- `derived_from` is subsumed by `supports` here
(a Conclusion supporting another Conclusion IS "derived_from" it), and
`Alert` / `Brief` are output-shaping concerns for his layer, not belief-state
concerns for this one. `explain()` / `brief_for()` below are the deterministic
substrate his (future) `by llm()` brief-polish layer would consume, the same
pattern jac/geofence.jac established: deterministic severity + detail string
first, LLM polish is a separate, later layer. No `by llm()` call exists
anywhere in this file.

JUSTIFICATION-ID BOOKKEEPING
------------------------------
Node type filters (`[x --> (?Type)]`) are broken in jaclang 0.16.7 (internal
compiler error) -- confirmed in jac/hypothesis.jac and jac/geofence.jac, and
reconfirmed while writing this file. Rather than fight the compiler bug, this
module keeps its own Python-side registries of every Fact / Conclusion /
justification-edge as they are created (FACTS, CONCLUSIONS, EDGES), exactly
the pattern jac/geofence.jac's GeofenceMonitor uses for TrackWatch nodes.
Graph edges (`supports` / `refutes`) still exist as real Jac edges between
real nodes -- the registries are an index on top of the graph, not a
replacement for it, and `+>:supports:+>` / `+>:refutes:+>` are still what
actually creates the wiring.

PROPAGATION -- naive-to-fixpoint, with a hard cap
----------------------------------------------------
`retract()` / `reinstate()` flip one Fact's `believed` flag, then recompute
EVERY Conclusion's status from the justification rule, repeatedly, until one
full pass changes nothing (a fixpoint). At this scale (a handful of
conclusions per scenario) a full-graph recompute per pass is fine and is not
over-engineered into an incremental worklist algorithm. A cyclic justification
graph (Conclusion A's justification depends on Conclusion B and vice versa)
could in principle oscillate forever, so passes are capped at MAX_PASSES; if
the cap is hit the function raises a plain `RuntimeError` naming the pass
count, rather than either looping forever or silently returning a
possibly-unsettled graph. A custom exception type was considered and
rejected: jac/contracts.jac's docstring already documents (and this file
reconfirms) that `obj Foo(Exception) {}` compiles but fails AT RAISE TIME with
`__init__() takes 1 positional argument but 2 were given`, because Jac
archetypes are dataclass-like and do not inherit BaseException's varargs
`__init__`. contracts.jac's workaround is to keep the real exception class in
Python and resolve it lazily via `importlib`; that machinery is not worth
introducing for one internal cap-guard, so this file just raises the builtin
`RuntimeError` directly.

DRIVING IT FROM PYTHON
------------------------
    import jaclang                      # installs the .jac meta importer
    sys.path.insert(0, "jac")
    import jtms

    jtms.reset()
    jtms.add_fact("f1", "MMSI ... broadcast by vessel_a")
    jtms.add_conclusion("c1", "vessel_a identity confirmed")
    jtms.justify("c1", "j1", supports_ids=["f1"], refutes_ids=[])
    jtms.propagate()                    # or call once after building the graph
    jtms.retract("f1")                  # -> list of flipped Conclusion ids
    jtms.explain("c1")                  # -> dict
    jtms.brief_for("c1")                # -> deterministic ASCII sentence

No `with entry:__main__` demo block is required for pytest to exercise this
module live (the test file drives it directly, matching jac/geofence.jac's
and jac/hypothesis.jac's pattern), but one is included below for a `jac run`
walkthrough since it costs nothing and helps stage rehearsal.
"""

# ---------------------------------------------------------------------------
# Tunables / run state. Globals rather than walker fields: this is scenario
# configuration and process-local bookkeeping, not per-traversal state -- the
# same discipline as jac/hypothesis.jac's LOG/ROOTS and jac/geofence.jac's
# EVENTS/HUB.
# ---------------------------------------------------------------------------

glob MAX_PASSES: int = 64;      # fixpoint iteration cap; a cyclic justification
                                 # graph raises rather than looping forever

glob FACTS: dict = {};          # fact_id -> Fact
glob CONCLUSIONS: dict = {};    # concl_id -> Conclusion
# justification_id -> {"concl_id": str, "supports": [antecedent_id...],
#                       "refutes": [inhibitor_id...]}
glob JUSTS: dict = {};
# concl_id -> [justification_id...], insertion order, for stable iteration/explain()
glob JUST_ORDER: dict = {};

# `root` is persistent across `jac run` invocations (see jac/hypothesis.jac's
# and jac/geofence.jac's notes on this), so this module never walks from
# `root` -- every lookup goes through FACTS/CONCLUSIONS/JUSTS, rebuilt by
# reset().
#
# No custom exception type is declared here. See the module docstring's
# PROPAGATION section: `obj Foo(Exception) {}` compiles in Jac 0.16.7 but
# fails at raise time (`__init__() takes 1 positional argument but 2 were
# given`), so the fixpoint-cap guard below raises a plain `RuntimeError`.

# `PREV_STATUS` powers brief_for()'s "what changed" framing: the status of
# every Conclusion as of the START of the most recently completed propagate()
# call (retract()/reinstate() both go through propagate()). brief_for() reads
# it to render "A -> B" when the most recent propagation actually flipped this
# conclusion, or a stable one-line description otherwise.
glob PREV_STATUS: dict = {};


# ---------------------------------------------------------------------------
# Graph vocabulary -- see INTEGRATION SEAM in the module docstring: `Conclusion`
# and the `supports` / `refutes` edge kinds are the same names Abhi's unmerged
# jac/graph.jac uses, so this is a rename-free merge on those three names.
# ---------------------------------------------------------------------------

node Fact {
    has fact_id: str;
    has label: str;                # human-readable, e.g. "MMSI 412345678 broadcast by vessel_a"
    has believed: bool = True;     # the thing that can be retracted
}


node Conclusion {
    has concl_id: str;
    has label: str;
    has status: str = "IN";        # "IN" (believed) | "OUT" (retracted/unsupported)
    # Never set directly outside this module -- always recomputed by
    # _recompute_all_once() from the justification rule: IN iff at least one
    # justification is fully satisfied (all its antecedents IN/believed and
    # none of its inhibitors are IN). A freshly-created Conclusion keeps this
    # field's literal default of "IN" -- the naive "the system currently
    # believes this" state a caller had BEFORE the JTMS ever ran a pass -- and
    # the first propagate() call (whether invoked directly, or indirectly via
    # the first retract()/reinstate()) is what corrects it against the real
    # justification graph. That is deliberate: it is what lets a test observe
    # a Conclusion flip on the very first propagation, before any retract()
    # call exists to blame.
}


edge supports { has justification_id: str = ""; }   # antecedent -> Conclusion, positive support
edge refutes  { has justification_id: str = ""; }   # antecedent -> Conclusion, an "inhibitor":
                                                     # if the antecedent is IN, this justification
                                                     # is BLOCKED even if its supports are all IN


# ---------------------------------------------------------------------------
# Graph construction
# ---------------------------------------------------------------------------

def add_fact(fact_id: str, label: str, believed: bool = True) -> Fact {
    """Register a new Fact and anchor it in the persistent graph.

    Raises ValueError on a duplicate fact_id -- a silently overwritten Fact
    would leave stale `supports`/`refutes` edges pointing at an orphaned node,
    exactly the kind of silent-failure trap this project's Jac modules are
    built to close (see jac/fences.jac on colliding fence ids for the same
    discipline).""";
    if fact_id in FACTS {
        raise ValueError(f"duplicate fact_id: {fact_id}");
    }
    f = Fact(fact_id=fact_id, label=label, believed=believed);
    root ++> f;
    FACTS[fact_id] = f;
    return f;
}


def add_conclusion(concl_id: str, label: str) -> Conclusion {
    """Register a new Conclusion and anchor it in the persistent graph.

    Status starts at the node's literal default ("IN") until a propagate()
    call recomputes it for real -- see the Conclusion node docstring.""";
    if concl_id in CONCLUSIONS {
        raise ValueError(f"duplicate concl_id: {concl_id}");
    }
    c = Conclusion(concl_id=concl_id, label=label);
    root ++> c;
    CONCLUSIONS[concl_id] = c;
    JUST_ORDER[concl_id] = [];
    return c;
}


def _node_for(node_id: str) -> any {
    """Fact or Conclusion node for `node_id`; raises ValueError if neither
    exists. Typed `-> any` (not `-> Fact`/`-> Conclusion`) because it hands
    back either archetype interchangeably -- callers only ever use it to
    attach an edge, never to read a field off the return value.""";
    if node_id in FACTS {
        return FACTS[node_id];
    }
    if node_id in CONCLUSIONS {
        return CONCLUSIONS[node_id];
    }
    raise ValueError(f"unknown fact/conclusion id: {node_id}");
}


def justify(concl_id: str, justification_id: str,
            supports_ids: list = [], refutes_ids: list = []) -> None {
    """Add one justification (an AND-group) to a Conclusion.

    `supports_ids` and `refutes_ids` are lists of Fact or Conclusion ids --
    the Conclusion is IN once at least one justification like this one has
    every support antecedent IN/believed and every refute inhibitor OUT/not-
    believed. Creates one real `supports` or `refutes` edge per antecedent,
    all carrying this call's `justification_id` so they group as one AND-group
    (see the module docstring's JUSTIFICATION-ID BOOKKEEPING section for why
    JUSTS/JUST_ORDER, not edge traversal, is what propagation actually reads).
    Parameters are named `*_ids`, not `supports`/`refutes`, so a local
    parameter never shadows the `supports`/`refutes` edge archetype names used
    a few lines below in `+>:supports(...):+>` / `+>:refutes(...):+>`.

    Raises ValueError on an unknown concl_id/antecedent/inhibitor id, or a
    justification_id already used (on this Conclusion or any other -- ids are
    global, matching fact_id/concl_id).""";
    if concl_id not in CONCLUSIONS {
        raise ValueError(f"unknown concl_id: {concl_id}");
    }
    if justification_id in JUSTS {
        raise ValueError(f"duplicate justification_id: {justification_id}");
    }
    concl_node = CONCLUSIONS[concl_id];

    for aid in supports_ids {
        ante_node = _node_for(aid);
        ante_node +>:supports(justification_id=justification_id):+> concl_node;
    }
    for rid in refutes_ids {
        inhib_node = _node_for(rid);
        inhib_node +>:refutes(justification_id=justification_id):+> concl_node;
    }

    JUSTS[justification_id] = {
        "concl_id": concl_id,
        "supports": list(supports_ids),
        "refutes": list(refutes_ids)
    };
    JUST_ORDER[concl_id].append(justification_id);
}


# ---------------------------------------------------------------------------
# Propagation -- the justification rule, recomputed to a fixpoint
# ---------------------------------------------------------------------------

def _antecedent_believed(node_id: str) -> bool {
    """Whether `node_id` currently counts as IN/believed: a Fact's `believed`
    flag, or a Conclusion's `status == "IN"`, read from STORED state (the
    snapshot as of the start of the current pass -- see
    _recompute_all_once()).""";
    if node_id in FACTS {
        return FACTS[node_id].believed;
    }
    if node_id in CONCLUSIONS {
        return CONCLUSIONS[node_id].status == "IN";
    }
    raise ValueError(f"unknown antecedent/inhibitor id: {node_id}");
}


def _justification_satisfied(justification_id: str) -> bool {
    """One AND-group: every `supports` antecedent IN/believed, every
    `refutes` inhibitor OUT/not-believed.""";
    j = JUSTS[justification_id];
    for aid in j["supports"] {
        if not _antecedent_believed(aid) {
            return False;
        }
    }
    for rid in j["refutes"] {
        if _antecedent_believed(rid) {
            return False;
        }
    }
    return True;
}


def _conclusion_should_be_in(concl_id: str) -> bool {
    """IN iff at least one of this Conclusion's justifications is satisfied.
    A Conclusion with zero justifications is vacuously OUT -- there is nothing
    to be IN by.""";
    jids = JUST_ORDER[concl_id];
    if len(jids) == 0 {
        return False;
    }
    for jid in jids {
        if _justification_satisfied(jid) {
            return True;
        }
    }
    return False;
}


def _recompute_all_once() -> list {
    """One Jacobi-style pass: compute every Conclusion's wanted status from
    the CURRENT stored snapshot (read-only first loop), then apply every
    change at once (write-only second loop). Snapshot semantics, not
    sequential/Gauss-Seidel update, is deliberate -- it is what makes a
    mutually-refuting cycle (A's only justification requires B OUT, B's only
    justification requires A OUT) oscillate IN/OUT/IN/OUT forever rather than
    settling by accident on whichever node happens to be recomputed first,
    which is exactly the case the MAX_PASSES cap in propagate() exists to
    catch. Returns the ids that changed this pass.""";
    wanted = {};
    for concl_id in CONCLUSIONS {
        if _conclusion_should_be_in(concl_id) {
            wanted[concl_id] = "IN";
        } else {
            wanted[concl_id] = "OUT";
        }
    }
    changed = [];
    for concl_id in CONCLUSIONS {
        c_node = CONCLUSIONS[concl_id];
        if c_node.status != wanted[concl_id] {
            c_node.status = wanted[concl_id];
            changed.append(concl_id);
        }
    }
    return changed;
}


def propagate() -> list {
    """Recompute every Conclusion's status to a fixpoint and report every id
    whose status differs from what it was before this call.

    This is the one function retract()/reinstate() both call, and it is also
    safe (and meaningful) to call directly right after building a graph --
    that is precisely how the mmsi-spoof fixture demonstrates a Conclusion
    flipping OUT via a `refutes` edge with NO retract() involved at all: the
    first-ever propagate() call corrects every Conclusion away from its raw
    node-default ("IN") to what the justification graph actually supports.

    Raises RuntimeError if no fixpoint is reached within MAX_PASSES passes
    (a cyclic justification graph) -- reported clearly rather than looping
    forever or returning a possibly-unsettled graph.""";
    before = {};
    for concl_id in CONCLUSIONS {
        before[concl_id] = CONCLUSIONS[concl_id].status;
    }

    passes = 0;
    while True {
        if passes >= MAX_PASSES {
            raise RuntimeError(
                f"JTMS propagation did not reach a fixpoint within "
                f"{MAX_PASSES} passes -- likely a cyclic justification graph"
            );
        }
        changed = _recompute_all_once();
        passes += 1;
        if len(changed) == 0 {
            break;
        }
    }

    flipped = [];
    for concl_id in CONCLUSIONS {
        if before[concl_id] != CONCLUSIONS[concl_id].status {
            flipped.append(concl_id);
        }
    }
    PREV_STATUS.clear();
    for concl_id in before {
        PREV_STATUS[concl_id] = before[concl_id];
    }
    return sorted(flipped);
}


def retract(fact_id: str) -> list {
    """Mark a Fact disbelieved and propagate to a fixpoint. Returns the ids of
    every Conclusion whose status flipped as a result (this is what the demo
    narrates: "N conclusions flipped").""";
    if fact_id not in FACTS {
        raise ValueError(f"unknown fact_id: {fact_id}");
    }
    FACTS[fact_id].believed = False;
    return propagate();
}


def reinstate(fact_id: str) -> list {
    """Mark a Fact believed again and propagate to a fixpoint. Symmetric to
    retract() -- a Conclusion that flipped OUT can flip back IN if this
    restores one of its justifications (and nothing else still blocks it).""";
    if fact_id not in FACTS {
        raise ValueError(f"unknown fact_id: {fact_id}");
    }
    FACTS[fact_id].believed = True;
    return propagate();
}


# ---------------------------------------------------------------------------
# Explanation / brief -- deterministic, template-based, NO by llm() anywhere.
# This is the substrate a future by-llm() brief-polish layer would consume;
# see the module docstring's INTEGRATION SEAM section.
# ---------------------------------------------------------------------------

def _label_of(node_id: str) -> str {
    """Human-readable label for a Fact or Conclusion id, falling back to the
    raw id if somehow neither (should not happen once justify() has run,
    since it validates every id up front).""";
    if node_id in FACTS {
        return FACTS[node_id].label;
    }
    if node_id in CONCLUSIONS {
        return CONCLUSIONS[node_id].label;
    }
    return node_id;
}


def explain(concl_id: str) -> dict {
    """The CURRENT justification structure for one Conclusion: its status,
    and for EACH justification, its antecedents/inhibitors and whether each
    is currently satisfied. This is the structure brief_for() renders into a
    sentence, and what a future brief-panel/by-llm() layer would consume as
    its source of truth.""";
    if concl_id not in CONCLUSIONS {
        raise ValueError(f"unknown concl_id: {concl_id}");
    }
    c_node = CONCLUSIONS[concl_id];

    justifications = [];
    for jid in JUST_ORDER[concl_id] {
        j = JUSTS[jid];
        antecedents = [];
        for aid in j["supports"] {
            believed = _antecedent_believed(aid);
            antecedents.append({
                "id": aid, "label": _label_of(aid),
                "in_or_believed": believed, "satisfied": believed
            });
        }
        inhibitors = [];
        for rid in j["refutes"] {
            in_or_believed = _antecedent_believed(rid);
            inhibitors.append({
                "id": rid, "label": _label_of(rid),
                "in_or_believed": in_or_believed, "satisfied": not in_or_believed
            });
        }
        sat = True;
        for a in antecedents {
            if not a["satisfied"] {
                sat = False;
            }
        }
        for i in inhibitors {
            if not i["satisfied"] {
                sat = False;
            }
        }
        justifications.append({
            "justification_id": jid,
            "satisfied": sat,
            "antecedents": antecedents,
            "inhibitors": inhibitors
        });
    }

    return {
        "concl_id": concl_id,
        "label": c_node.label,
        "status": c_node.status,
        "justifications": justifications
    };
}


def _antecedent_clause(justification: dict) -> str {
    """'X is believed and Y is not believed' -- the human-readable reading of
    one justification's antecedents/inhibitors, used when it IS satisfied.""";
    parts = [];
    for a in justification["antecedents"] {
        parts.append(a["label"] + " is believed");
    }
    for i in justification["inhibitors"] {
        parts.append(i["label"] + " is not believed");
    }
    if len(parts) == 0 {
        return "trivially (no antecedents or inhibitors)";
    }
    return " and ".join(parts);
}


def _unsatisfied_clause(justification: dict) -> str {
    """Names only the pieces that are CURRENTLY failing this justification --
    used when it is NOT satisfied.""";
    bad = [];
    for a in justification["antecedents"] {
        if not a["satisfied"] {
            bad.append(a["label"] + " is no longer believed");
        }
    }
    for i in justification["inhibitors"] {
        if not i["satisfied"] {
            bad.append(i["label"] + " is now believed");
        }
    }
    if len(bad) == 0 {
        return "unknown reason";
    }
    return " and ".join(bad);
}


def _reason_sentence(explanation: dict) -> str {
    """The clause fragment inside brief_for()'s parentheses: which
    justification is doing the work (if IN), or which one just failed and
    whether an alternate still stands (if OUT). Justification order is
    JUST_ORDER's insertion order, which is stable and deterministic, so the
    SAME graph state always produces the SAME sentence.""";
    justifications = explanation["justifications"];
    if len(justifications) == 0 {
        return "no justification exists";
    }
    if explanation["status"] == "IN" {
        for j in justifications {
            if j["satisfied"] {
                return f"justification {j['justification_id']} satisfied: " + _antecedent_clause(j);
            }
        }
        return "no satisfied justification found";
    }
    primary = justifications[0];
    detail = _unsatisfied_clause(primary);
    extra = "";
    if len(justifications) > 1 {
        extra = f"; no alternate justification holds ({len(justifications) - 1} other(s) also unsatisfied)";
    }
    return f"justification {primary['justification_id']} not satisfied: {detail}{extra}";
}


def brief_for(concl_id: str) -> str {
    """A short, deterministic, template-based (NOT by llm()) human sentence:
    what this Conclusion's status is (and, if the most recent propagate()
    call flipped it, what it changed FROM), and why -- built entirely from
    explain()'s structure. E.g.:

        "identity_b_confirmed: IN -> OUT (justification j_b1 not satisfied: "
        "vessel_b broadcasts MMSI 412345678 is no longer believed)"

    Same input state always produces the same string: no clocks, no
    randomness, no LLM call.""";
    explanation = explain(concl_id);
    status = explanation["status"];
    reason = _reason_sentence(explanation);
    prev = PREV_STATUS.get(concl_id, status);
    if prev != status {
        return f"{concl_id}: {prev} -> {status} ({reason})";
    }
    return f"{concl_id}: {status} ({reason})";
}


# ---------------------------------------------------------------------------
# Readback
# ---------------------------------------------------------------------------

def fact_believed(fact_id: str) -> bool {
    return FACTS[fact_id].believed;
}


def conclusion_status(concl_id: str) -> str {
    return CONCLUSIONS[concl_id].status;
}


def fact_ids() -> list {
    return sorted(FACTS.keys());
}


def conclusion_ids() -> list {
    return sorted(CONCLUSIONS.keys());
}


def justification_ids_for(concl_id: str) -> list {
    return list(JUST_ORDER[concl_id]);
}


# ---------------------------------------------------------------------------
# reset() -- fresh demo/test run
# ---------------------------------------------------------------------------

def reset() -> None {
    """Clear all Fact/Conclusion/justification state for a fresh run.

    Essential, not cosmetic -- the same reasoning as jac/hypothesis.jac's and
    jac/geofence.jac's reset(): globals live for the whole pytest process and
    `root` persists across `jac run` invocations, so without this a second
    scenario in the same session would see its predecessor's facts and
    conclusions. Nodes already anchored under `root` from a previous run are
    simply abandoned (unreferenced by FACTS/CONCLUSIONS, and every lookup in
    this module goes through those dicts, never a traversal from `root`), the
    same "process-local, rebuilt by reset()" discipline hypothesis.jac's
    ROOTS and geofence.jac's HUB use.""";
    FACTS.clear();
    CONCLUSIONS.clear();
    JUSTS.clear();
    JUST_ORDER.clear();
    PREV_STATUS.clear();
}


# ---------------------------------------------------------------------------
# The mmsi-spoof fixture -- shared by the demo entry block below and by
# tests/test_jtms.py, so the two cannot drift apart.
# ---------------------------------------------------------------------------

def build_mmsi_spoof_demo() -> None {
    """Build the mmsi-spoof scenario on the CURRENT (already reset) graph.

    Deliberately does NOT call propagate() itself -- the whole point of this
    fixture is that a caller can choose to inspect the graph in its raw,
    just-built state (every Conclusion still at its literal "IN" default)
    before ever running a propagation, and separately choose WHEN the first
    propagate()/retract()/reinstate() call happens, to demonstrate that the
    refutes-driven correction happens on the first propagation regardless of
    whether that propagation was triggered by an explicit propagate() call or
    by the first retract().""";
    add_fact("broadcast_a_mmsi", "vessel_a broadcasts MMSI 412345678");
    add_fact("broadcast_b_mmsi", "vessel_b broadcasts MMSI 412345678");
    add_fact(
        "physically_impossible",
        "vessel_a and vessel_b broadcasting MMSI 412345678 simultaneously, "
        "40 km apart, is physically impossible"
    );

    add_conclusion("identity_a_confirmed", "vessel_a's identity is confirmed");
    add_conclusion("identity_b_confirmed", "vessel_b's identity is confirmed");
    add_conclusion("spoof_detected", "an MMSI spoof is in progress");

    justify("identity_a_confirmed", "j_a1", supports_ids=["broadcast_a_mmsi"]);

    # The only justification for identity_b_confirmed is supported by
    # broadcast_b_mmsi AND blocked by spoof_detected -- this is the refutes
    # edge the module docstring calls out: "spoof_detected -> identity_b_confirmed".
    justify(
        "identity_b_confirmed", "j_b1",
        supports_ids=["broadcast_b_mmsi"], refutes_ids=["spoof_detected"]
    );

    # Two justifications (OR): spoof_detected is IN as soon as the physical
    # impossibility is known, together with EITHER broadcast being believed --
    # independent of which vessel turns out to be the real one.
    justify(
        "spoof_detected", "j_spoof_a",
        supports_ids=["physically_impossible", "broadcast_a_mmsi"]
    );
    justify(
        "spoof_detected", "j_spoof_b",
        supports_ids=["physically_impossible", "broadcast_b_mmsi"]
    );
}


# ---------------------------------------------------------------------------
# Demo. `with entry:__main__` so a Python `import jtms` does NOT run this.
# ---------------------------------------------------------------------------

with entry:__main__ {
    print("=== sentinel-isr :: phase 5 jtms (mmsi spoof) ===");

    reset();
    build_mmsi_spoof_demo();
    print("before any propagation:");
    print("  identity_a_confirmed  " + conclusion_status("identity_a_confirmed"));
    print("  identity_b_confirmed  " + conclusion_status("identity_b_confirmed")
          + "  (raw default, not yet computed)");
    print("  spoof_detected        " + conclusion_status("spoof_detected"));

    flipped = propagate();
    print("");
    print("first propagate() -- no retract() has been called yet:");
    print("  flipped: " + str(flipped));
    print("  " + brief_for("identity_a_confirmed"));
    print("  " + brief_for("identity_b_confirmed"));
    print("  " + brief_for("spoof_detected"));
    print("  (identity_b_confirmed is already OUT via the refutes edge -- "
          "broadcast_b_mmsi is still believed=" + str(fact_believed("broadcast_b_mmsi")) + ")");

    flipped = retract("broadcast_b_mmsi");
    print("");
    print("retract('broadcast_b_mmsi') -- the operator confirms which one was fake:");
    print("  flipped: " + str(flipped));
    print("  " + brief_for("identity_a_confirmed"));
    print("  " + brief_for("identity_b_confirmed"));
    print("  " + brief_for("spoof_detected"));

    flipped = reinstate("broadcast_b_mmsi");
    print("");
    print("reinstate('broadcast_b_mmsi') -- still blocked by spoof_detected:");
    print("  flipped: " + str(flipped));
    print("  " + brief_for("identity_b_confirmed"));

    print("");
    print("=== ok ===");
}
