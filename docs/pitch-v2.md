# Sentinel-ISR -- demo script v2 (timed)

Rewritten against what is actually built on `phase-1-kalman` at commit `58f4c72`,
not the aspirational plan. Every beat is tagged:

- **[BUILT]** -- runs today, on this branch, verified by a test or a docstring's
 "verified by running" claim.
- **[BUILT, unmerged]** -- real code, but on a teammate's branch that has not
 merged into `phase-1-kalman` yet (`origin/abhi/web-frontend`,
 `origin/omar/scenario-packs`). Confirm the merge landed before rehearsing this
 beat as-is.
- **[PLACEHOLDER]** -- the number or artifact does not exist yet; a human fills
 it in from a live run.
- **[CUT]** -- cuttable without a rewrite; see the contingency note under each
 beat and the priority list at the bottom.

Target runtime: **~4:00**. A dry run against a stopwatch is still required -- 
nothing below has been timed on stage.

---

## Beat table

Tags are bare on purpose -- swap one and the edit is done, no rewrite. Full
sourcing for every claim is in the numbered notes right after the table, keyed
to the note markers in the "Said" column.

| Time | On screen | Said (verbatim) | Tag | If cut |
|---|---|---|---|---|
| 0:00-0:15 | Title card / map of Monterey Bay + SF Bay region, no tracks yet | "Sentinel-ISR: we track ships without ever looking at who they say they are." | [BUILT] | Drop the card, say the line over the first crossing beat instead. |
| 0:15-0:45 | Two synthetic tracks converge on a crossing course, naive nearest-neighbor mode | "Watch the two ships cross. A naive tracker -- nearest measurement wins -- swaps their identities right here." [1] | [BUILT] | Skip straight to the global-assignment beat and just assert naive trackers get this wrong; costs the visual contrast, not the claim. |
| 0:45-1:05 | Toggle to global (Hungarian) assignment; same two tracks, IDs hold | "Same geometry, the optimal assignment solve instead of the greedy one. Zero switches. This is Kuhn and Munkres' Hungarian algorithm, 1955/1957." [2] | [BUILT] | Merge into the prior beat as one continuous toggle demo rather than two separate holds. |
| 1:05-1:35 | Naive-vs-MHT toggle: same crossing, now with hypothesis forking on | **Raj:** "This is Reid's MHT from 1979, standard in defense systems. What's new isn't the algorithm -- it's that hypothesis branching is native to Jac. A fork is a walker spawn." [3] | [BUILT, unmerged UI] | If the toggle UI (unmerged) isn't ready, narrate the fork over a static crossing screenshot instead of a live toggle. |
| 1:35-2:05 | Terminal or log panel showing the fork | "The moment the margin between the best and second-best assignment drops under 2 nats -- about 7:1 odds -- the tracker doesn't guess. It forks." Show the log line live. [4] | [BUILT] | Narrate the fork verbally over the toggle beat instead of a dedicated log panel -- this is the anchor cut, see priority list below (position 6). |
| 2:05-2:30 | Map: track enters the Monterey Bay NMS boundary (real NOAA layer), alert banner fires | "The vessel just entered a National Marine Sanctuary. The system knows, and it says so -- once, not on every frame it stays inside. Nothing here is a dictionary keyed by track ID -- the graph is the index; the graph is the database." [5] | [BUILT, unmerged banner] | Say the line over a static screenshot of the alert log if live banner rendering (unmerged) isn't wired -- this is the other anchor cut, see priority list below (position 7). |
| 2:30-3:15 | AIS icon goes dark; growing uncertainty ellipse around the last known position; a later radar blip appears | "AIS just went silent. We don't lose the vessel -- we keep predicting, and we say how uncertain we are, honestly, as it grows." (ellipse visibly widens) "Ten minutes later, a radar contact appears near the edge of that ellipse. Same vessel, re-attributed with a stated probability: [NUMBER FROM LIVE RUN]." [6] | [BUILT] | Never cut -- this is the load-bearing image of the whole pitch (see priority list, position 8, "cut last"). If time is short elsewhere, shorten the narration, not this beat. |
| 3:15-3:35 | Scenario dropdown switches from the sanctuary pack to the MMSI-spoof pack, same engine, no restart | (Omar or Raj) "Same engine, no code change. The only thing that's different between these two demos is data." [7] | [BUILT, unmerged] | Skip the live dropdown switch; say the line and cut straight to the JTMS beat's static description. |
| 3:35-3:55 | JTMS panel: two vessels broadcast the same MMSI 40 km apart; operator retracts one broadcast; dependent conclusions flip | "Two vessels claiming the same identity is a contradiction. Retract the false belief, and every conclusion that depended on it flips -- automatically, to a fixpoint. [PLACEHOLDER -- fill from jac/jtms.jac once it lands: expected shape is "N conclusions flipped"]." [8] | [PLACEHOLDER] | First to cut if the merge/wiring isn't done -- fold the dual-use close forward and end on the dark-vessel beat instead. |
| 3:55-4:00 | Fade to close text | (see close, below) | [BUILT] | Can be said as a voiceover with no dedicated screen time if the clock is tight. |

Total as laid out: ~4:00. This has real slack in the 1:05-2:05 stretch if the
toggle UI turns out not to be ready -- see cut priorities.

### Notes (sourcing, one line each)

1. `tracker/assoc.py`'s `associate_greedy`; the deterministic trap in README:
   greedy 2 switches, global 0, on the same geometry. Over 800 seeds, greedy
   switches about 5x as often as global (pooled; per-window ratio 3.8x-15x).
2. `tracker/assoc.py::associate_global`, 0.95 ms on a 40x40 solve (budget was
   20 ms).
3. Verbatim from `docs/prior-art.md` on `origin/omar/pitch-materials`
   (unmerged), already attributed to Raj there. The forking mechanism itself
   (`jac/hypothesis.jac`) is built on this branch; the live crossing-scenario
   toggle UI is on `origin/abhi/web-frontend`, unmerged -- confirm it exists
   before rehearsing this beat as scripted.
4. `jac/hypothesis.jac`, verified log format: `[Hypothesis] split h_04 ->
   h_04a (0.61) / h_04b (0.39)` then `[Hypothesis] pruned h_04b`. Margin math
   and the 2-nat threshold are `tracker/ambiguity.py`.
5. `jac/geofence.jac` fires exactly one `geofence_enter` event on the
   outside->inside transition; the boundary is Omar's real NOAA Monterey Bay
   NMS GeoJSON, loaded and verified (15,794.4 km^2 measured vs. 15,782.98
   km^2 published AREA_KM, 0.07% projection cost). "The graph IS the index"
   is close-to-verbatim from `jac/geofence.jac`'s own module docstring.
   Full alert-banner rendering is on `origin/abhi/web-frontend`, unmerged.
6. `tracker/dark.py`. Ellipse: 95% confidence region (`chi2=5.991`, 2 dof),
   growing 12 m -> 6,650 m over 610 s of coasting in the measured test,
   clipped against real CA coastline so it never covers dry land.
   Re-attribution: measured **p = 0.947** for a detection landing on the
   10-minute-dark prediction, falling to **p = 0.165** at the association
   gate edge (99% gate, `chi2=9.21`) -- both from `tracker/dark.py`'s
   docstring, pinned by `tests/test_dark.py`. Use whatever number the live
   rehearsal actually produces for that seed; do not read 0.947 off a
   different scenario's run.
7. Near-verbatim from `s02_mmsi_spoof/pack.json`'s own description on
   `origin/omar/scenario-packs` (unmerged): "Runs on the identical scenario
   engine as s01 with zero code changes; the only difference is data."
8. `jac/jtms.jac` exists in the working tree as of this writing (Doyle 1979
   IN/OUT propagation, `Fact`/`Conclusion` nodes, `supports`/`refutes`
   edges, a working `mmsi_spoof_demo()`), but it is explicitly a teammate's
   in-flight file per this doc's own brief and must be treated as
   unfinished. Read but not relied on for a hard number: in the current
   draft, the dramatic flip (`identity_b_confirmed` going IN->OUT) happens
   on the *first* `propagate()` call -- the moment the contradictory graph
   is built -- not on the operator's `retract()` call, because
   `spoof_detected`'s `refutes` edge already blocks it. If that holds in the
   final version, say "the moment we notice the contradiction," not "when
   the operator retracts it" -- confirm the actual wired behavior with the
   teammate before finalizing this line.

## MMSI withholding line

Not a beat with its own time slot -- say it whenever a judge asks "how do you
know it's the same ship without the transponder ID?" Verbatim from this
repo's own `README.md`:

> "Identity is never used for association -- recovering it from kinematics
> alone is the project."

## The close (three lines, dual-use)

> "The same dark-vessel tracking serves illegal fishing enforcement, search
> and rescue, and sanctions monitoring -- three different budget holders, one
> engine, because the underlying problem -- something went dark, where is it
> now -- doesn't change."

(Sourced near-verbatim from `docs/dual-use.md` on `origin/omar/pitch-materials`,
unmerged -- read first, not duplicated from scratch.) Say plainly, if asked: this
shows an **anomalous movement pattern**, never "proven smuggling" or "illegal
fishing confirmed" -- movement data alone cannot establish what cargo moved or
whether a crime occurred.

---

## Cut priority order

**The build plan's own cut list was not found committed anywhere in this
repo** (checked README.md, JAC_SETUP.md, all commit messages on all branches,
and `origin/omar/jac-workshop-notes`). Two positions are given directly in this
task's brief and are treated as ground truth here: **hypothesis spawning cuts
6th**, **geofence rendering cuts 7th**. The rest of the ordering below is
**RECONSTRUCTED** by demo-dependency risk (what's least load-bearing / easiest
to narrate around goes first) -- replace it with the real plan document's list
if it surfaces before the run.

1. *(cut first)* Impact/dual-use close as an on-screen slide -- can be said
 verbally over the fade with no visual loss.
2. JTMS beat -- already the most placeholder-heavy beat; cutting it costs one
 line of narration, not a demo path.
3. Live log-panel display of the hypothesis fork -- narrate the fork verbally
 instead of pointing at a terminal.
4. The specific re-attribution probability readout -- say "high confidence"
 instead of the exact number if the live run's number looks off mid-demo.
5. Naive-vs-MHT toggle as a dedicated beat -- fold it into the crossing beat by
 just showing MHT and mentioning naive trackers get this wrong, rather than
 demoing both.
6. Hypothesis spawning *(anchor: given as 6th in the task brief)*.
7. Geofence rendering *(anchor: given as 7th in the task brief)*.
8. *(cut last / never)* Dark-vessel uncertainty ellipse -- this is the single
 image that carries the whole "honest uncertainty" pitch; everything else
 can be narrated around its absence, this can't.
