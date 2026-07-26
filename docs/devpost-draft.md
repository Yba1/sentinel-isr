# Devpost draft -- Sentinel-ISR

This revises the existing draft on `origin/omar/pitch-materials:docs/devpost-draft.md`
(unmerged) rather than replacing it -- that draft is correct about the framing
and prior-art discipline; this version updates the technical claims and numbers
against what has actually landed on `phase-1-kalman` since it was written
(Phase 3.5 geofencing, Phase 4 dark-vessel re-association, and the
contracts/eval/geofence Jac port). `[METRIC]` marks a number that genuinely
could not be found in any source file, log, or test docstring after reading
them -- none were invented.

---

## Inspiration

Vessels broadcast their position over AIS -- until they don't. Bad actors
switch transponders off deliberately: to fish in closed waters, to move
cargo without a paper trail, to evade enforcement. Dark-vessel detection is
solved-enough that whole companies (Global Fishing Watch, Skylight, Windward)
are built on it. What caught our attention at a language workshop for Jac was
narrower: multiple-hypothesis tracking is, underneath, a branching-and-pruning
problem over a graph -- and Jac's walker/spawn model maps onto that almost
directly. We wanted to see whether a graph-native language could express a
45-year-old tracking algorithm (Reid's MHT, 1979) more naturally than the
object-soup most tracking codebases turn into.

## What it does

Sentinel-ISR replays maritime traffic as unlabelled radar/AIS detections and:

- Runs multi-hypothesis tracking (`jac/hypothesis.jac`) to hold vessel
 identity through crossings that a naive nearest-neighbor tracker gets wrong.
 Measured over 800 unscreened seeds of an 18 kn, 30 s-revisit crossing:
 greedy association loses identity **~5x as often** as the globally optimal
 assignment (pooled 116/22 across four 200-seed windows; per-window ratio
 3.8x-15x -- the ratio is the honest claim, not "global never fails").
- Fires a geofence alert the instant a track crosses into a protected area
 (`jac/geofence.jac`), against a real NOAA Monterey Bay National Marine
 Sanctuary boundary, and exactly once per intrusion, not once per frame
 inside it.
- When AIS goes dark, keeps predicting position with a growing, honestly-drawn
 uncertainty ellipse (`tracker/dark.py`), clipped so it never claims a vessel
 is on dry land, and re-attributes a later radar contact to the same vessel
 with a **stated probability** rather than a false certainty -- measured
 **p = 0.947** for a detection on-prediction after 10 minutes dark, falling
 to **p = 0.165** at the edge of the association gate.
- Distinguishes "AIS dropout" from "AIS dropout inside a sanctuary" -- same
 sensor event, different narrative, purely because the geofence layer holds
 state the geometry layer deliberately does not.

Two additional scenario packs are authored and loadable on the identical
engine, ahead of dedicated detection logic for what they represent: an MMSI
spoof (two vessels broadcasting the same identity 40 km apart) and a ghost-fleet
re-flagging against a real OFAC SDN vessel-list entry. All three packs
(`scenarios/s01_dark_in_sanctuary`, `s02_mmsi_spoof`, `s03_ghost_fleet`) run on
the same engine with zero code changes between them -- that is the point of the
architecture, and it is verified in the pack's own description, not
aspirational. **Caveat**: the scenario/replay layer and the packs themselves
live on unmerged branches (`origin/abhi/web-frontend`,
`origin/omar/scenario-packs`) as of this writing, not on `phase-1-kalman`.

A justification-based truth-maintenance layer (`jac/jtms.jac`, Doyle 1979
IN/OUT belief propagation) for the MMSI-spoof scenario -- retract a false
belief and every conclusion that depended on it flips, to a fixpoint -- is
**in progress by a teammate as of this writing** and is not claimed as
finished here.

## How we built it

- **Tracking core (Python)**: a constant-velocity Kalman filter
 (`tracker/kalman.py`, Joseph-form covariance update, closed-form 2x2
 innovation inverse), gated Mahalanobis association with a Kuhn-Munkres
 (Hungarian) global assignment and a greedy baseline sharing the same cost
 matrix (`tracker/assoc.py`), an ambiguity margin in nats that decides when
 to fork a hypothesis (`tracker/ambiguity.py`), dark-vessel ellipse geometry
 and re-attribution probability (`tracker/dark.py`), and shapely/STRtree
 point-in-polygon geofence containment (`tracker/geofence.py`).
- **State and rules (Jac)**: the hypothesis lifecycle -- fork, N-scan collapse,
 weight-floor kill, hard cap -- as a graph of `Hypothesis` nodes and `Fork`
 edges (`jac/hypothesis.jac`); geofence transition tracking as a
 `Watchtower`/`TrackWatch` graph walked once per frame by `GeofenceMonitor`
 (`jac/geofence.jac`); and, as of the most recent pass, the pack/geofence
 vocabulary contract, the full scenario-pack regression harness, and the
 geofence decision logic ported from Python into Jac
 (`jac/contracts.jac`, `jac/eval.jac`, `jac/fences.jac`) -- moving "graph
 structure and orchestration" into Jac while keeping the numerical kernels
 (shapely geometry, eigendecomposition, scipy) in Python.
- **Toolchain**: `jaclang` requires Python 3.12+ specifically, because it uses
 `typing.override`, which does not exist before 3.12 -- every jaclang release
 from 0.13.2 on refuses to install on 3.11 with no working fallback. We
 migrated the whole toolchain to 3.12.4; nothing in `tracker/` needed
 touching for the migration.
- **Scenario/data layer** (unmerged, `origin/abhi/web-frontend` +
 `origin/omar/scenario-packs`): fixed-interval scenario packs that combine a
 real, cached San Francisco Bay AIS window with scripted synthetic actors
 (AIS on/off, radar contact, identity change) and real geo layers -- NOAA
 Monterey Bay NMS boundary, Natural Earth coastline, MarineCadastre
 submarine-cable corridors, an OFAC SDN vessel subset. Ground truth is
 stripped from every measurement at ingest, so identity recovery is real,
 not read from a hidden field.

### Explicit Jac feature list

Checked against the actual source before writing any of this down.

- **Hypothesis lifecycle as a literal graph** (`jac/hypothesis.jac`) -- the
 headline claim. Each `Hypothesis` is a node, `Fork` edges point parent to
 child, and pruning (N-scan collapse at depth 3, weight-floor kill at 0.01,
 a hard cap of 8 live hypotheses) is graph traversal, not a hand-rolled list.
 The file has zero imports, including no import of the tracker itself -- the
 hypothesis *shape* is pure graph structure.
- **`spawn`** -- `root spawn Splitter()` / `here spawn W()` pattern, used for
 the `LiveLeaves` and `BranchRoot` traversal walkers in `jac/hypothesis.jac`
 and `GeofenceMonitor` in `jac/geofence.jac`.
- **Node / edge archetypes** -- `Hypothesis`/`Fork` (hypothesis.jac),
 `Watchtower`/`TrackWatch`/`Watching` (geofence.jac), `Fact`/`Conclusion`/
 `supports`/`refutes` (jtms.jac, in progress).
- **Walkers, confirmed by name in source, not by plan**: `GeofenceMonitor`
 (`jac/geofence.jac`, this branch), plus `ScenarioDriver`, `Fusion`,
 `AlertScribe`, `Briefer`, and `Renderer` on `origin/abhi/web-frontend`
 (unmerged). Three names sometimes assumed for this project -- 
 `TrackWalker`, `AnomalyDetector`, `ThreatScorer` -- do **not** exist in any
 branch's source as of this writing.
- **`by llm()`** -- used on `origin/abhi/web-frontend`'s `jac/alerts.jac` only,
 narrowly, for alert-headline phrasing; severity itself is a deterministic
 rule table, never an LLM decision, and provenance (`model_used`: real model
 name, `"litellm-fallback"`, or `"template"`) is recorded so a judge can
 verify what actually generated a given headline. Not present on
 `phase-1-kalman`.
- **`jac serve`** and **bitemporal edges** -- real roadmap items, not shipped.
 `origin/abhi/web-frontend`'s `InZone` edge carries one timestamp
 (`since_t`), not independent event-time/decision-time axes -- confirmed by
 reading `jac/graph.jac` directly, not assumed.

### Jac vs. Python, by line count

Measured directly on `phase-1-kalman` at commit `58f4c72` (this session),
`wc -l` on `jac/*.jac` vs. `tracker/*.py` -- the same method the repo's own
commit history uses (`find . -name "*.jac" | xargs wc -l`, per the
`ff17230`/`5c67d67` commit messages):

| Scope | Jac (lines) | Python, tracker/ (lines) | Jac share |
|---|---|---|---|
| Product code, `jac/jtms.jac` excluded (in-progress, untracked) | 3,890 | 2,817 | **58.0%** |
| Product code, `jac/jtms.jac` included as currently drafted | 4,651 | 2,817 | 62.3% |
| Including `tests/*.py` (7,435 lines) in the denominator, jtms excluded | 3,890 | 2,817 + 7,435 tests | 27.5% |

All three rows are raw `wc -l`, the same method the repo's own history uses --
no non-blank/non-comment variant is reported here: a first attempt at that
count had a docstring-boundary bug (a closing `"""` on the same line as other
text does not toggle the same way an opening one does), so it is dropped
rather than published as a second, unverified number.

The most recent commit on this branch (`58f4c72`) reports **59.6%** for the
product-code figure in its own message; the small drift from the 58.0% number
above is real (`tracker/contracts.py` is 77 lines now vs. 67 at that commit,
and other files moved slightly since). **This is a single-branch, as-measured
number, not the final one** -- `origin/abhi/web-frontend`'s Jac pipeline
(`jac/graph.jac`, `driver.jac`, `fusion.jac`, `alerts.jac`, `render.jac`,
`main.jac`) and `origin/omar/scenario-packs` are not merged in; that branch's
own README reports 1,755 Jac / 2,077 Python lines (45.8% Jac) on its own,
non-overlapping code. The combined, post-merge number will differ from both
and should be recomputed once the branches land -- recomputing before
submission, not guessing, is the discipline this project has followed at
every prior Jac-port commit.

Whether the tests-included denominator (27.5%) or the product-code-only
denominator (58.0-62.3%) is the one that counts toward any stated Jac-share
floor is an **open question with the judges' actual counting method**,
unresolved as of this writing (see `docs/partial-submission-checklist.md`).

## Challenges we ran into

- **Python 3.11 vs. 3.12**: `jaclang` needs `typing.override`, a 3.12-only
 stdlib addition. On 3.11, pip silently back-solves to `jaclang 0.10.2`,
 which then dies at import (`ImportError: cannot import name 'override'`).
 Every release from 0.13.2 on declares `requires_python >= 3.12`; there is no
 working jaclang for 3.11. Cost real setup time and required moving the
 whole toolchain, and incidentally broke `numba` on one machine via a
 transitive `llvmlite` bump when jaclang was installed into the wrong Python
 environment -- fixed by pinning `llvmlite==0.42.0` back and removing a stale
 cached package tree pip's uninstall left behind.
- **The shapely `STRtree` predicate-direction trap**: `STRtree.query`
 evaluates `predicate(input_geometry, tree_geometry)` -- the *input* is on
 the left. With points as input and fences in the tree, asking for
 `predicate="contains"` asks whether a *point* contains a *polygon*, which
 is never true, and returns an empty result set **with no error** -- a
 geofence layer that silently never fires looks identical to a scenario
 with no intrusions. The correct spelling is `predicate="within"`. Caught by
 a test with nested fences in both directions, not by inspection -- this is
 documented directly in `tracker/geofence.py`'s source.
- **A three-way contract divergence across teammates**: the written geofence
 contract, one teammate's shape, and a second teammate's dataclass had each
 independently implemented the same `Geofence` object three different ways
 (different field names, different kind vocabularies, one missing
 `buffer_m` entirely). Reconciled in `tracker/contracts.py` as a single
 source of truth with a resolver that raises -- rather than guessing -- on
 genuinely unresolvable input, since a silent fallback (e.g. defaulting an
 unrecognized kind to `"mpa"`) would invent a protected area and manufacture
 the demo's own top-severity alert out of a typo.
- **A circular-import trap in the Jac port**: `jac/contracts.jac` needs
 Python's `ContractError` exception class, but `ContractError` is defined in
 `tracker/contracts.py`, which now re-exports from `jac/contracts.jac` -- 
 an eager import in either direction only resolved under one import order
 and broke under the other with a partially-initialized-module error. Fixed
 by resolving `ContractError` **lazily**, via `importlib`, on first actual
 raise rather than at module load -- confirmed by testing hostile import
 order directly (importing each module first, in both orders, in isolated
 subprocesses), not assumed safe.
- Jac archetypes can subclass `ValueError` syntactically (`obj Foo(Exception)`
 compiles), but they don't inherit `BaseException`'s varargs `__init__`, so
 `raise ContractError("msg")` fails **at raise time**, not at compile time -- 
 a second, related trap that surfaced independently in both
 `jac/contracts.jac` and the in-progress `jac/jtms.jac`.

## Accomplishments we're proud of

- The greedy-vs-global statistical comparison is a real, repeatable measurement,
 not a cherry-picked run: 800 seeds, four disjoint windows, ratio bounds
 reported honestly (3.8x-15x) alongside the pooled figure (~5x), rather than
 a single flattering seed.
- A regression harness that treats scenario packs as an executable
 specification, not just fixtures: `tracker/eval.py` / `jac/eval.jac` reads
 every pack's own `expected` block and reports PASS/FAIL/SKIP against the
 live engine, exiting non-zero on a genuine failure -- including surfacing a
 real dangling-file reference in a teammate's own pack (a path mentioned only
 in scenario notes, not the actual committed CSV) and a genuine
 earth-model straddle in one pack's stated distance requirement (39.9 km
 required, 39.924 km on an equirectangular projection, 39.853 km on an
 ellipsoidal one -- close enough that the two earth models disagree about
 pass/fail, and the harness reports that honestly as `MARGIN` rather than a
 silent green).
- The Jac line-share measured directly at 58-62% of product code (see table
 above) as of this session, up from a starting point in the low 20s
 according to this branch's own commit history -- moved by porting orchestration
 logic (contract vocabulary, eval harness, geofence decision rules), not
 padding with restated Python.
- Real NOAA/Natural Earth/MarineCadastre/OFAC geo layers loading and
 measurably correct: the Monterey Bay NMS boundary area matches its own
 published `AREA_KM` property to within 0.07% after our own ENU projection.
 **A real, cached San Francisco Bay AIS window is committed and loaded** as
 ambient background traffic (confirmed: `scenarios/s01_dark_in_sanctuary/ais_window.csv`
 on `origin/abhi/web-frontend`, real MMSI/lat/lon/SOG/COG rows) -- this is not
 a fallback claim, though it lives on an unmerged branch as of this writing.
 The scripted demo narrative (dark event, geofence entry) layers a
 deterministic synthetic actor on top of that real traffic for repeatable
 timing, and that distinction -- real ambient traffic, scripted narrative
 actor -- should be stated plainly rather than blurred.

## What we learned

- Framing matters as much as the algorithm: the tracking math (MHT, Kalman
 gating, Hungarian assignment) is 45-70 years old, and the room includes
 people who will know Reid 1979 by name. The defensible claim is narrower -- 
 hypothesis branching maps onto Jac's walker/spawn model natively -- and
 saying only that, not "we invented tracking," is what holds up under
 questioning.
- Movement data alone cannot establish intent or cargo. Every place this
 project describes a tracked vessel's behavior, it says "anomalous movement
 pattern," never "proven smuggling" or "confirmed illegal activity."
- A silent fallback is more dangerous than a raised error in a system that
 produces demo-facing alerts: three separate places in this codebase
 (contract kind vocabulary, cable-corridor zero-buffer, geofence id
 collision) chose "raise and name the ambiguity" over "guess and move on,"
 because guessing wrong here manufactures the system's own top-severity
 claim.

## What's next

- Merge the three active branches (`phase-1-kalman`'s Jac-ported orchestration,
 `origin/abhi/web-frontend`'s live fusion pipeline, `origin/omar/scenario-packs`'
 authored packs) into one buildable tree, and recompute the Jac line-share on
 the merged result rather than quoting any single branch's number.
- Wire the in-progress JTMS layer (`jac/jtms.jac`) into the MMSI-spoof
 scenario end-to-end, including the frontend's alert/brief rendering.
- `jac serve` behind a real endpoint, and bitemporal edges (independent
 event-time/decision-time axes) so "what did we believe, and when" is a
 graph query.
- The ten deferred scenario integrations in `docs/roadmap.md` -- each needs a
 new scenario pack and, for a few, a new external data source, not a new
 engine.
