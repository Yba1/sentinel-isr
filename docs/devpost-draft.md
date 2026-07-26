# Devpost draft — Sentinel-ISR

Draft for submission. `[METRIC]` marks numbers only Raj can fill in from the
tracker's actual test/eval runs — do not guess these. The Jac line-count
percentage below is computed from the repo as of this snapshot and should be
recomputed right before submission since the codebase is still moving.

---

## Inspiration

Vessels broadcast their position over AIS — until they don't. Bad actors
switch transponders off deliberately: to fish in closed waters, to move
sanctioned cargo, to evade enforcement. Existing dark-vessel detection is a
solved-enough problem that companies (Global Fishing Watch, Skylight,
Windward) are built on it. What caught our attention at a language workshop
for Jac was narrower: multiple-hypothesis tracking is, at its core, a
branching-and-pruning problem — and Jac's walker/spawn model maps onto that
almost directly. We wanted to see if a graph-native agentic language could
express a 45-year-old tracking algorithm (Reid's MHT, 1979) more naturally
than the object-soup most tracking codebases turn into.

## What it does

Sentinel-ISR is air-traffic-control-style tracking for ships. Today, the
pipeline (`jac/main.jac`: ScenarioDriver → Fusion → AlertScribe → Briefer →
Renderer):

- Ingests AIS positions and predicts where a vessel must be after it goes
  dark, drawing a growing region of possible locations the longer the gap.
- Re-identifies the vessel when it reappears on radar, with a stated
  probability rather than a false certainty (two-stage association: live
  tracks first, then a reachability-gated re-association pass for coasting
  tracks against the leftovers).
- Keeps vessel identities straight when tracks cross — a case naive
  nearest-neighbor association gets wrong.
- Flags when a vessel goes dark inside a protected marine sanctuary
  (`intrusion` / `went_dark` / `reacquired` alert kinds today).

Two capabilities are staged as scenario packs the engine can already load and
run, ahead of the detection logic that would make them fire an alert:

- **`s02_mmsi_spoof`** — two vessels broadcasting the same MMSI 40 km apart
  simultaneously. The engine runs this pack today; a dedicated
  `spoof_detected` alert (and, if Raj's JTMS lands, a full belief-retraction
  cascade instead of a single flag) is the detection logic still to be
  written.
- **`s03_ghost_fleet`** — a vessel that changes MMSI and display name
  mid-replay, checked against a real OFAC SDN vessel entry
  (`scenarios/s03_ghost_fleet/ofac_sdn_vessels_subset.csv`). The `kind:
  "identity_change"` alert already fires on the re-flag; the OFAC lookup
  itself is scenario-side data, not yet wired into the alert pipeline.

All three packs (`scenarios/s01_dark_in_sanctuary`, `s02_mmsi_spoof`,
`s03_ghost_fleet`) drive the identical engine with zero code changes between
them — that part is verified, not aspirational.

## How we built it

- **Tracking core**: Kalman filtering + gated assignment (Kuhn–Munkres) for
  single-hypothesis association, [METRIC: single-hypothesis assignment
  accuracy] on the crossing-track test cases.
- **Multi-hypothesis layer, in Jac**: an open association ambiguity forks the
  hypothesis tree — each `Hypothesis` is a graph node, weighted, and pruning
  (N-scan collapse, weight-floor kill, live-set cap) is traversal over that
  graph, not a hand-maintained list. [METRIC: hypothesis count at peak
  ambiguity / pruning latency].
- **Data layer**: scenario packs (JSON) drive a fixed-interval replay engine
  that ingests real MarineCadastre AIS windows and/or synthetic actors,
  applies scripted events (AIS on/off, radar contact, identity change), and
  produces unlabelled measurements — ground truth is stripped before it
  reaches the tracker, so identity recovery is real, not read from a hidden
  field.
- **Geo layers**: real NOAA Monterey Bay National Marine Sanctuary boundary,
  Natural Earth coastline, MarineCadastre submarine cable routes, and an
  OFAC SDN vessel subset, all converted to WGS84 GeoJSON.

### Explicit Jac feature list

Everything below is verified against the current source, not aspirational.

- **Hypothesis lifecycle as a graph** (`jac/hypothesis.jac`) — this is the
  headline claim and it's literal, not a metaphor: each `Hypothesis` is a
  node, `Fork` edges point parent to child, and pruning (N-scan collapse,
  weight-floor kill, live-set cap) is graph traversal over that structure,
  not a hand-rolled list of hypothesis objects. The file has zero imports —
  it doesn't even import the tracker — because the hypothesis *shape* is
  pure graph structure; the numbers (Kalman, assignment cost) stay in
  Python and never enter this file.
- **Walkers** — five in the live pipeline (`jac/main.jac`): `ScenarioDriver`
  (scripted-event dispatch), `Fusion` (association + track update),
  `AlertScribe` (alert phrasing), `Briefer` (summary composition), and
  `Renderer` (frame-delta snapshot for the frontend). One spawn per frame,
  in that order, on the shared `Mission` node.
- **`spawn`** — e.g. `Fusion(t=t, dt=30.0, meas=meas) spawn m` once per
  frame; the hypothesis fork is the same primitive at the data-structure
  level (a new `Hypothesis` node created by a graph operation, not a
  Python list append).
- **`by llm()`** — used narrowly and on purpose: severity is a deterministic
  rule table (the LLM never decides how serious an alert is), and
  `AlertScribe.compose` calls `by llm()` only to phrase the headline text,
  recording `model_used` (model name / `litellm-fallback` / `template`) so
  provenance is auditable. The pipeline runs fully with no model and no
  network.
- **OSP (object-spatial programming) graph modeling** — the whole mission
  picture *is* the graph: `Mission`, `Track`, `Zone`, `ActorState`, `Alert`,
  `Contact`, `Brief` nodes; `InZone`, `RaisedOn`, `Concerning`,
  `JustifiedBy`, `Summarizes` edges. A `Track` node holds Raj's
  `tracker.assoc.Track` (filter + lifecycle score) rather than
  reimplementing one.
- **Node / edge archetypes** — typed nodes/edges as above; the type system
  carries the invariants a Python version would need dataclasses plus
  manual checks to enforce.

**Not yet built, don't claim on stage:** `jac serve` (the WebSocket/HTTP
layer is explicitly next-phase per `jac/main.jac`'s own comment — today the
pipeline runs via `jac run` and returns an in-memory delta list) and
bitemporal edges (`InZone` currently carries one timestamp, `since_t`, not
independent event-time/decision-time axes). Both are real roadmap items, not
currently-shipping features.

### Jac vs. Python, by line count

The work is currently split across two unmerged branches (the hypothesis
lifecycle on one, the live fusion pipeline on the other — see "Challenges"
below), so this is a cross-branch estimate, not a single `wc -l` on one
checkout: **2,432 lines of Jac** (`jac/hypothesis.jac` + `jac/smoke_interop.jac`
+ the six pipeline files: graph/driver/fusion/alerts/render/main) vs.
**5,236 lines of Python** (tracker math, data layer, tests, scripts, unioned
across both branches, counting shared files once) — **~32% of the
executable logic is Jac.** Recompute this exact split once the branches
merge and right before submission; it's moving daily.

## Challenges we ran into

- Jac's toolchain requires Python 3.12+ specifically (`typing.override`);
  every jaclang release from 0.13.2 on refuses to install on 3.11, with no
  working fallback version. Cost real setup time across machines that
  defaulted to older Python.
- Parallel workstreams, unmerged: the hypothesis lifecycle (`jac/hypothesis.jac`)
  and the live fusion pipeline (`jac/main.jac` and friends) were built on
  separate branches by design, to keep each one buildable independently under
  the time box. Integrating them — wiring hypothesis forking into the same
  frame loop that drives association, alerts, and rendering — is real
  remaining work, not yet done as of this draft.
- Multi-hypothesis tracking is naturally exponential in open hypotheses;
  getting pruning to fire early enough to stay real-time without silently
  dropping the correct hypothesis took iteration. [METRIC: hypotheses
  pruned vs. hypotheses that survived to resolution].
- Demo pacing: a growing uncertainty ellipse needs several seconds of
  perceptible on-screen growth, which at a fast replay multiplier means the
  underlying "dark" interval in the scenario data has to be sized
  deliberately, not just realistically. Tuned iteratively against a
  stopwatch, not guessed.

## What we learned

- Framing matters as much as the algorithm: the tracking math (MHT, Kalman,
  Hungarian assignment) is decades old, and claiming otherwise in front of
  people with a defense or ML background would cost us credibility, not gain
  it. The actual technical claim — hypothesis branching maps onto Jac's
  walker/spawn model natively — is narrower and more defensible.
- Movement data alone cannot establish intent or cargo. We were careful to
  say "anomalous movement pattern," never "proven smuggling," throughout the
  build and the pitch.

## What's next

- Merge the hypothesis-lifecycle graph into the live fusion pipeline so
  ambiguous association actually forks a `Hypothesis` node instead of the
  two branches running independently.
- `jac serve` to put the mission graph behind a real endpoint instead of an
  in-memory `jac run` delta list — the natural next step once the frontend
  needs a live feed instead of a canned replay.
- Bitemporal edges: extend `InZone` (and similar) past today's single
  `since_t` to carry both event time and decision time, so "what did we
  believe, and when" is a graph query instead of something we'd have to
  reconstruct from logs.
- Ten scenario packs are scoped but not built this weekend (see
  `scenarios/ROADMAP.md`) — ship-to-ship transfer detection, dark-fleet
  resupply networks, closed-season MPA fishing, cable-corridor anomalies,
  AIS destination-field falsification, IMO/MMSI re-flagging churn, high-seas
  sanctions evasion, IUU fishing-effort signatures (Global Fishing Watch API),
  offshore-infrastructure swarming, and GPS-spoofing clusters. Each just
  needs a new scenario pack and, for a few, a new data source — not a new
  engine.
- Real deployments would need a live AIS feed (Spire or similar), not a
  cached window, and a proper JTMS (justification-based truth maintenance)
  layer so spoofing detection cascades into a full belief retraction instead
  of a single alert.
