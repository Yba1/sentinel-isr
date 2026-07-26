# Roadmap -- scenarios and integrations not built this cycle

Framed deliberately as designed-for breadth, not a gap: the engine (scenario
pack -> replay -> tracker -> Jac graph -> alerts) is built to take a new pack
and, for most of these, a new data source, without a new engine. Each pack
below is a plausible future demo, not a promise for this submission.

## Option A / B / C -- what was actually chosen this cycle

The build plan considered three ways to spend the JTMS/belief-revision slot
this cycle:

- **Option A -- JTMS retraction (chosen, built this cycle)**: a
 justification-based truth-maintenance system (Doyle 1979) over `Fact` and
 `Conclusion` nodes with `supports`/`refutes` edges, so retracting a false
 belief (e.g. a spoofed MMSI broadcast) cascades into every dependent
 conclusion flipping automatically, to a fixpoint. In progress on
 `jac/jtms.jac` as of this writing.
- **Option B -- Viterbi behaviour segmentation (not chosen)**: would have
 segmented a track's kinematic history into discrete behavior states
 (transit / loiter / drift / evasive maneuver) via a hidden-Markov-style
 Viterbi decode over the position/velocity sequence, so "loitering near a
 cable landing point" becomes a labeled state transition instead of
 something a human has to eyeball off the trail. Demonstrates: automatic
 behavior classification from kinematics alone, no LLM involved.
- **Option C -- Dawid-Skene consensus (not chosen)**: would have modeled
 multiple independent detection sources (radar, AIS, a hypothetical
 satellite pass) as noisy labelers of the same underlying event and fused
 their confidence via the Dawid-Skene EM algorithm rather than a fixed
 weighting rule. Demonstrates: principled multi-sensor confidence fusion
 when sensors disagree, instead of a hand-tuned trust weight per sensor.

Both B and C are real roads not taken for this cycle, not roads that failed -- 
either could still become a future scenario pack.

## Ten deferred integrations

| # | Integration | What it would show | Data / integration needed |
|---|---|---|---|
| 1 | **Copernicus SAR** (Sentinel-1) | Dark-vessel detection from synthetic-aperture radar imagery itself, not just AIS-gap inference -- catching a vessel that was never broadcasting at all, not one that stopped. | Copernicus Open Access Hub API access, SAR image ingestion/preprocessing pipeline, a detection model or heuristic over the imagery. |
| 2 | **xView3-SAR** (dataset/model) | A trained dark-vessel-in-SAR detector as the front end feeding this tracker, rather than a synthetic or replayed AIS gap standing in for "vessel went dark." | The xView3 dataset and a trained detection model; a bridge from its output format into this project's `Measurement` contract. |
| 3 | **Global Fishing Watch API** | Real IUU fishing-effort signatures (apparent fishing behavior scores) layered on top of tracked positions, so "anomalous movement pattern near a closed area" gets corroborated by an independent fishing-effort signal. | GFW API key, effort-score ingestion, a new scenario pack correlating effort scores against geofence intrusions. |
| 4 | **ITU MARS / IMO GISIS / USCG PSIX** | Vessel-registry cross-reference: does the MMSI/name a track is broadcasting actually match a registered vessel, of the claimed type and flag? Turns "identity change" from a bare event into a registry-verified anomaly. | Registry API/bulk-data access for each (ITU MARS, IMO GISIS, USCG PSIX), a lookup layer, and a new alert kind for registry mismatch. |
| 5 | **NOAA NDBC / CO-OPS** | Environmental context (buoy wind/wave/current data, tide/water-level stations) so an anomalous course change can be checked against "was this just weather" before being flagged as behaviorally suspicious. | NDBC/CO-OPS station API ingestion, a time/location join against the tracked vessel's position, and a suppression rule for weather-explained deviation. |
| 6 | **NTSB CAROL / IncidentNews / ERMA** | Cross-referencing a tracked incident (collision, grounding, spill) against real incident databases, so a geofence/behavior alert during an actual reported casualty gets corroborated rather than standing alone. | Bulk data or API access to each database, an incident-matching join on time/location, a new "corroborated incident" alert kind. |
| 7 | **VIIRS** (nighttime lights / boat detection) | Independent nighttime detection of vessels using deck lights (common on fishing fleets attracting squid/other catch), corroborating or contradicting the AIS/radar picture at night specifically. | VIIRS Day/Night Band data access, a detection/thresholding pipeline, a bridge into the `Measurement` contract as a third sensor modality. |
| 8 | **UN Consolidated List** (sanctions) | Sanctions-list cross-reference broader than the current OFAC SDN subset already used in `s03_ghost_fleet` -- an international, not just US, sanctions surface. | UN Consolidated List bulk data, a lookup layer parallel to the existing OFAC check, and a distinct alert severity/attribution for non-US sanctions regimes. |
| 9 | **Viterbi behaviour segmentation** (Option B, not chosen this cycle) | See "Option B" above. | A labeled or heuristic behavior-state model, a Viterbi decoder over the kinematic history, a new derived field on `Track` for current behavior state. |
| 10 | **Dawid-Skene consensus** (Option C, not chosen this cycle) | See "Option C" above. | Multiple independent noisy-source scenario support (currently the engine has one authoritative measurement stream per frame), an EM implementation, and a new confidence-fusion layer ahead of the existing gated association. |

Each of these needs a new scenario pack and, for most, a new external data
source or API integration -- not a new engine. The pack/replay/tracker/Jac-graph
pipeline this project already built is the same substrate all ten would run on.
