"""Phase 3: the multi-hypothesis lifecycle, as a Jac graph.

WHAT LIVES HERE AND WHY
----------------------
Sentinel-ISR deliberately splits the tracker in two. Numerical kernels stay in
Python -- the Kalman filter (tracker/kalman.py), the NLL cost matrix and the
Hungarian solve (tracker/assoc.py), the ambiguity margin (tracker/ambiguity.py).
Everything about the *shape* of the hypothesis space lives here, in Jac, because
that is what Jac is for: the hypothesis space is literally a graph, hypotheses
are nodes, a fork is an edge, and pruning is a traversal. Writing it as Python
dictionaries-of-lists would be re-implementing a graph database by hand.

So: no matrix ever enters this file, and no lifecycle rule ever leaves it. This
file has no imports at all -- not even tracker -- so it runs under a bare
`jac run` with no PYTHONPATH. The caller (Python) decides *whether* a frame is
ambiguous and with what two weights; this file decides what the hypothesis tree
does about it.

THE MODEL
---------
Each `Hypothesis` node is one interpretation of the scenario so far: "measurement
3 belongs to track A, not track B, and that choice was made 2 scans ago".
`Fork` edges point parent -> child. A hypothesis is LIVE (`alive == True`) while
it is still a candidate; it stops being live either because it was SUPERSEDED
(it split into two children that replace it) or because it was PRUNED (killed by
one of the three pruning rules). Superseded and pruned nodes stay in the graph:
the branch history is the audit trail for why a track ID ended up where it did.

Invariant: an alive node never has an alive child, because `split` supersedes the
parent in the same operation that creates the children. So "live leaves" and
"alive nodes" are the same set, and the weights of that set sum to 1.

`depth` is the count of scans this line of reasoning has survived. An ambiguous
frame advances depth by branching (children are one deeper); an unambiguous frame
advances it in place, because a hypothesis that faces no decision needs no new
node -- it has simply survived another scan. Both cases age the hypothesis, which
is what the N-scan window measures.

ORDER OF OPERATIONS (`maintain`) -- THIS ORDER IS LOAD-BEARING
--------------------------------------------------------------
    1. normalize        put the live leaves back on a probability scale
    2. N-scan collapse  commit to decisions older than NSCAN_DEPTH scans
    3. weight kill      drop leaves below WEIGHT_FLOOR
    4. cap enforce      drop the lowest-weight leaves until <= MAX_LIVE
    5. normalize        the three pruning steps removed weight; restore sum = 1

Step 1 must precede 3 and 4 because both compare against absolute thresholds
(0.01, and "lowest weight"), which are only meaningful once the weights are a
distribution. Step 5 must exist because 2, 3 and 4 all delete weight without
redistributing it -- skip it and the live weights sum to less than 1, and every
subsequent threshold test is silently wrong (a leaf drifts under 0.01 not because
it is implausible but because its siblings were deleted). Collapse runs before
kill and cap because it is the cheapest reducer: it usually takes the live set
down far enough that the other two have nothing to do.

The sum-to-1 invariant therefore holds at frame boundaries -- after `reset` and
after every `run_frame` -- and NOT between the individual steps of `maintain`.

PRUNING RULES
-------------
  * N-SCAN COLLAPSE (depth >= NSCAN_DEPTH): standard MHT deferred decision. Once
    a branch is NSCAN_DEPTH scans deep, the evidence that arrived since the
    branch point is taken as sufficient, and the whole branch collapses to its
    highest-weight leaf. Grouping is by the branch's ROOT hypothesis (walk Fork
    edges up until there are none), never by arithmetic on stored `depth`:
    superseded parents freeze their depth at supersession while live leaves keep
    ageing, so "the ancestor at depth d - 3" is not a value that reliably exists
    in the chain.
  * WEIGHT KILL (weight < WEIGHT_FLOOR): a hypothesis with 1% of the belief mass
    costs the same to carry as one with 60%. The highest-weight leaf is exempt so
    the rule can never empty the tree.
  * HARD CAP (MAX_LIVE): the cost of MHT is exponential in branch count; the cap
    is what makes it real-time. Lowest weight dies first, one at a time,
    re-checking after each kill.

Every split and every prune emits one log line, ASCII only (`->`, not a unicode
arrow) so the demo prints on a Windows cp1252 console without raising
UnicodeEncodeError:

    [Hypothesis] split h_04 -> h_04a (0.61) / h_04b (0.39)
    [Hypothesis] pruned h_04b

DRIVING IT FROM PYTHON
----------------------
`import jaclang` installs the meta importer, then `import hypothesis` after
putting this directory on sys.path. Call `reset(n)`, then `run_frame(...)` per
frame, then read back with `live_state()` / `live_ids()` / `get_log()`.
"""

# ---------------------------------------------------------------------------
# Tunables. Deliberately globals rather than walker fields: they are scenario
# configuration, not per-traversal state, and the test reads them by name.
# ---------------------------------------------------------------------------

glob NSCAN_DEPTH: int = 3;      # scans of deferred decision before collapse
glob WEIGHT_FLOOR: float = 0.01;  # below this share of belief, a leaf dies
glob MAX_LIVE: int = 8;         # hard cap on simultaneous live hypotheses

# Run state. Mutated in place, never rebound, so no global-rebinding syntax is
# needed and Python holds live references to the same objects.
glob LOG: list = [];            # every split/prune line, in order
glob ROOTS: list = [];          # root hypotheses of the CURRENT run

# `root` is persistent across `jac run` invocations (jac writes .jac/data/*.db),
# so anything reachable from it accumulates run over run. Every traversal here
# starts from ROOTS instead, which is process-local and rebuilt by reset().


node Hypothesis {
    has hyp_id: str;
    has weight: float = 1.0;
    has depth: int = 0;
    has alive: bool = True;         # live leaf
    has parent_id: str = "";
    has superseded: bool = False;   # replaced by children, as opposed to pruned
    has prune_reason: str = "";     # "", "nscan", "weight", "cap"
}


edge Fork {}


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

def fmt2(w: float) -> str {
    """Two decimals, ASCII -- the one place log weights get stringified.

    `format(w, ".2f")` rather than an f-string: `f"{w:.2f}"` does work on 0.16.7
    (verified), but every log line here is built by `+` concatenation, and one
    function keeps the rounding rule in one place instead of repeating a format
    spec at each call site.""";
    return format(w, ".2f");
}


def emit(line: str) -> None {
    """Single choke point for every lifecycle event, so a test can read LOG back.""";
    LOG.append(line);
    print(line);
}


# ---------------------------------------------------------------------------
# Traversal
# ---------------------------------------------------------------------------

walker LiveLeaves {
    """Collect every live hypothesis in the subtree below the spawn node."""
    has found: list = [];

    can gather with Hypothesis entry {
        if here.alive {
            self.found.append(here);
        }
        visit [->:Fork:->];
    }
}


walker BranchRoot {
    """Climb Fork edges to the top of this hypothesis's branch.

    Used as the N-scan grouping key. Node type filters are broken in jaclang
    0.16.7 (both `(\\`?Hypothesis)` and `(?Hypothesis)` fail, the second with an
    internal compiler error), but the graph is typed per-edge, so following Fork
    upward can only ever reach Hypothesis nodes and no filter is needed.
    """
    has top: list = [];

    can climb with Hypothesis entry {
        parents = [<-:Fork:<-];
        if len(parents) == 0 {
            self.top.append(here);
            return;
        }
        visit parents;
    }
}


def live_leaves() -> list {
    """Every live hypothesis across every root of the current run.""";
    out = [];
    for r in ROOTS {
        w = r spawn LiveLeaves();
        for h in w.found {
            out.append(h);
        }
    }
    return out;
}


def branch_root_id(h: Hypothesis) -> str {
    """Id of the root hypothesis of h's branch.""";
    w = h spawn BranchRoot();
    if len(w.top) == 0 {
        return h.hyp_id;
    }
    return w.top[0].hyp_id;
}


# ---------------------------------------------------------------------------
# Selection helpers. Explicit loops with an id tie-break rather than sorted(),
# so the choice is reproducible on the exact ties that symmetric crossing
# geometry produces routinely.
# ---------------------------------------------------------------------------

def heaviest(hs: list) -> Hypothesis {
    best = hs[0];
    for h in hs {
        if h.weight > best.weight or (h.weight == best.weight and h.hyp_id < best.hyp_id) {
            best = h;
        }
    }
    return best;
}


def lightest(hs: list) -> Hypothesis {
    worst = hs[0];
    for h in hs {
        if h.weight < worst.weight or (h.weight == worst.weight and h.hyp_id > worst.hyp_id) {
            worst = h;
        }
    }
    return worst;
}


# ---------------------------------------------------------------------------
# Lifecycle primitives
# ---------------------------------------------------------------------------

def normalize() -> None {
    """Rescale live-leaf weights to sum to 1.""";
    leaves = live_leaves();
    if len(leaves) == 0 {
        return;
    }
    total = 0.0;
    for h in leaves {
        total += h.weight;
    }
    if total <= 0.0 {
        # Every leaf underflowed to zero: fall back to a uniform prior rather
        # than dividing by zero. Unreachable while the floor rule is on.
        for h in leaves {
            h.weight = 1.0 / len(leaves);
        }
        return;
    }
    for h in leaves {
        h.weight = h.weight / total;
    }
}


def prune(h: Hypothesis, reason: str) -> None {
    """Kill one live leaf and log it. Weight is NOT redistributed here -- the
    final normalize() of maintain() does that once, for all prunes at once.""";
    if not h.alive {
        return;
    }
    h.alive = False;
    h.prune_reason = reason;
    emit("[Hypothesis] pruned " + h.hyp_id);
}


def split(h: Hypothesis, w1: float, w2: float) -> list {
    """Fork one live hypothesis into two children carrying the two normalized
    ambiguity weights, and supersede the parent.

    Children inherit `parent.weight * w_i`, so a fork deep in the tree cannot
    inflate its branch's share of the belief mass: the split is local and the
    global sum is preserved before normalize() even runs.
    """;
    a = Hypothesis(hyp_id=h.hyp_id + "a", weight=h.weight * w1,
                   depth=h.depth + 1, parent_id=h.hyp_id);
    b = Hypothesis(hyp_id=h.hyp_id + "b", weight=h.weight * w2,
                   depth=h.depth + 1, parent_id=h.hyp_id);
    h +>:Fork:+> a;
    h +>:Fork:+> b;

    # Superseded, not pruned: the parent is history, not a mistake, so it emits
    # no prune line.
    h.alive = False;
    h.superseded = True;

    emit("[Hypothesis] split " + h.hyp_id + " -> "
         + a.hyp_id + " (" + fmt2(a.weight) + ") / "
         + b.hyp_id + " (" + fmt2(b.weight) + ")");
    return [a, b];
}


# ---------------------------------------------------------------------------
# Pruning rules
# ---------------------------------------------------------------------------

def nscan_collapse() -> None {
    """Collapse any branch that has run NSCAN_DEPTH scans deep to its best leaf.""";
    leaves = live_leaves();
    if len(leaves) == 0 {
        return;
    }

    # Group live leaves by the root of their branch.
    groups = {};
    for h in leaves {
        key = branch_root_id(h);
        if key not in groups {
            groups[key] = [];
        }
        groups[key].append(h);
    }

    for key in groups {
        members = groups[key];
        # The branch only collapses once SOMETHING in it is old enough; a
        # younger sibling in the same branch collapses with it, because the
        # decision being committed to is the one at the branch point.
        deep = False;
        for h in members {
            if h.depth >= NSCAN_DEPTH {
                deep = True;
            }
        }
        if not deep or len(members) < 2 {
            continue;
        }
        keep = heaviest(members);
        for h in members {
            if h.hyp_id != keep.hyp_id {
                prune(h, "nscan");
            }
        }
    }
}


def weight_kill() -> None {
    """Drop every live leaf below WEIGHT_FLOOR, except the best one.""";
    leaves = live_leaves();
    if len(leaves) < 2 {
        return;
    }
    # Exempting the heaviest leaf makes the rule total: it can never empty the
    # tree, even if normalize() has not run yet and every weight is tiny.
    keep = heaviest(leaves);
    for h in leaves {
        if h.hyp_id != keep.hyp_id and h.weight < WEIGHT_FLOOR {
            prune(h, "weight");
        }
    }
}


def cap_enforce() -> None {
    """Kill the lowest-weight leaf, repeatedly, until at most MAX_LIVE remain.""";
    leaves = live_leaves();
    while len(leaves) > MAX_LIVE {
        prune(lightest(leaves), "cap");
        leaves = live_leaves();
    }
}


def maintain() -> None {
    """The pipeline. See the ORDER OF OPERATIONS section of the module docstring
    -- normalize / collapse / kill / cap / normalize -- and do not reorder it.""";
    normalize();
    nscan_collapse();
    weight_kill();
    cap_enforce();
    normalize();
}


# ---------------------------------------------------------------------------
# Frame driver -- the entry point Python calls
# ---------------------------------------------------------------------------

def pad2(i: int) -> str {
    s = str(i);
    if len(s) < 2 {
        s = "0" + s;
    }
    return s;
}


def reset(n_roots: int = 1) -> None {
    """Start a fresh run with `n_roots` equally weighted root hypotheses.

    More than one root models a first frame that was ambiguous several ways at
    once (a cluster of contacts with no prior). LOG is cleared too: globals live
    for the whole process, so without this a second test in the same pytest
    session would read the first test's log lines.
    """;
    ROOTS.clear();
    LOG.clear();
    i = 0;
    while i < n_roots {
        h = Hypothesis(hyp_id="h_" + pad2(i), weight=1.0, depth=0);
        root ++> h;             # keep the run anchored in the persistent graph
        ROOTS.append(h);
        i += 1;
    }
    normalize();
}


def run_frame(ambiguous: bool, w1: float = 0.5, w2: float = 0.5,
              fork_all: bool = False) -> None {
    """Advance the hypothesis tree by one scan.

    `ambiguous` and `(w1, w2)` come from tracker.ambiguity.detect_ambiguity on
    the real frame; nothing numerical is recomputed here. `fork_all` forks every
    live leaf (the same measurement ambiguity affects every interpretation);
    otherwise only the current best hypothesis forks.
    """;
    leaves = live_leaves();
    if len(leaves) == 0 {
        return;
    }

    if ambiguous {
        targets = leaves;
        if not fork_all {
            targets = [heaviest(leaves)];
        }
        for h in targets {
            split(h, w1, w2);
        }
    } else {
        # No decision to make: every surviving hypothesis simply ages one scan.
        # Depth still advances, which is what lets the N-scan window close on a
        # fork that no later frame disambiguated.
        for h in leaves {
            h.depth = h.depth + 1;
        }
    }

    maintain();
}


# ---------------------------------------------------------------------------
# Readback for the Python test / scoring harness
# ---------------------------------------------------------------------------

def live_ids() -> list {
    out = [];
    for h in live_leaves() {
        out.append(h.hyp_id);
    }
    return sorted(out);
}


def live_count() -> int {
    return len(live_leaves());
}


def live_weight_sum() -> float {
    total = 0.0;
    for h in live_leaves() {
        total += h.weight;
    }
    return total;
}


def live_state() -> list {
    """[(hyp_id, weight, depth)] for every live leaf, sorted by id.""";
    rows = [];
    for h in live_leaves() {
        rows.append((h.hyp_id, h.weight, h.depth));
    }
    return sorted(rows);
}


def max_live_depth() -> int {
    d = 0;
    for h in live_leaves() {
        if h.depth > d {
            d = h.depth;
        }
    }
    return d;
}


def get_log() -> list {
    return list(LOG);
}


# ---------------------------------------------------------------------------
# Demo: one crossing. Frame 1 is ambiguous 0.61/0.39 -> a visible fork; frames
# 2 and 3 bring no new evidence, so both hypotheses age; at depth 3 the N-scan
# window closes and the branch collapses to its heavier leaf.
# `with entry:__main__` so a Python `import hypothesis` does NOT run this.
# ---------------------------------------------------------------------------

with entry:__main__ {
    print("=== sentinel-isr :: phase 3 hypothesis lifecycle ===");

    reset(1);
    print("frame 0  live=" + str(live_ids()));

    run_frame(True, 0.61, 0.39);
    print("frame 1  live=" + str(live_ids()) + "  (fork)");

    run_frame(False);
    print("frame 2  live=" + str(live_ids()));

    run_frame(False);
    print("frame 3  live=" + str(live_ids()) + "  (n-scan collapse at depth "
           + str(NSCAN_DEPTH) + ")");

    print("weights  " + str(live_state()));
    print("sum      " + fmt2(live_weight_sum()));

    print("--- cap: 6 roots, fork every leaf, cap holds at " + str(MAX_LIVE) + " ---");
    reset(6);
    run_frame(True, 0.60, 0.40, True);
    print("wide     live=" + str(live_count()) + "  sum=" + fmt2(live_weight_sum()));
    run_frame(True, 0.60, 0.40, True);
    print("wide     live=" + str(live_count()) + "  sum=" + fmt2(live_weight_sum()));

    print("=== ok ===");
}
