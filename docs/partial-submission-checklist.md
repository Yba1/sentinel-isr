# Partial-submission checklist

Literal checkboxes against the Phase 6/7 acceptance items. Nothing here is
checked off by writing this file -- every box gets ticked by a human doing the
actual thing.

## Filing

- [ ] Partial submission filed by **5:40**.
- [ ] Final submit by **7:10**, not 7:14 -- build in slack, don't aim for the
 deadline itself.

## Script and reality

- [ ] Demo script (`docs/pitch-v2.md`) matches what actually runs on stage -- 
 re-check every [BUILT] tag against a live run within the hour before
 presenting, not against this document's word.
- [ ] Every [PLACEHOLDER] in `docs/pitch-v2.md` (re-attribution probability
 number, JTMS "N conclusions flipped" line) is filled in from an actual
 live run, not left as bracketed text on stage.
- [ ] The JTMS beat's narration matches the *actual* wired behavior once
 `jac/jtms.jac` lands -- as read during this pass, the current draft flips
 the key conclusion on the first `propagate()` call, not on the
 operator's `retract()` call; confirm which is true in the final version
 before saying "when the operator retracts it" on stage.

## Recording / repo mechanics

- [ ] Recorder tested (audio levels, screen capture region, correct display if
 multi-monitor).
- [ ] Repo is public.
- [ ] Submission video plays start-to-finish on a fresh device/browser, not
 just the machine that recorded it.
- [ ] Jac repo (jaclang/jaseci) starred, per the JacHammer category
 requirement.
- [ ] Three names on the team, spelled and credited correctly.

## Category checkboxes (select on the submission form)

- [ ] Agentic AI
- [ ] AI for Defense
- [ ] Best JacHammer

## Open items this checklist surfaces, not just tracks

- [ ] **README.md is stale relative to the actual repo state and this is a
 public-facing correctness problem, not a cosmetic one.** As read during
 this pass, `README.md`'s status table says Phase 3 ("Hypothesis
 branching as Jac walker spawning") and Phase 4 ("Geofence intrusion +
 dark-vessel re-association") are both "not started," and states "122
 tests total." The actual repo, at commit `58f4c72` on this branch, has
 both phases done, plus Phase 3.5 (geofence) and the contracts/eval Jac
 port, and the most recent commit message reports 649 tests passing. The
 repo goes public at submission -- whoever owns README.md should update
 it before then. (Not fixed here: README.md is explicitly out of scope
 for this pass.)
- [ ] **The "real San Francisco Bay AIS traffic" line needs a precise, not
 blurred, statement.** A real, cached SF Bay AIS window
 (`scenarios/s01_dark_in_sanctuary/ais_window.csv`, real MMSI/lat/lon/SOG
 rows) is committed and loads as ambient background traffic -- but on
 `origin/abhi/web-frontend`, unmerged, not on this branch -- and the
 scripted demo narrative (the dark event, the geofence entry) runs on a
 deterministic *synthetic* actor layered on top of that real traffic, not
 on the real traffic itself. Say "real SF Bay AIS as ambient traffic,
 scripted synthetic actor for the demo narrative," not an unqualified
 "real traffic," and not "synthetic only" either -- both are wrong.
- [ ] **Jac share >= 40%? Open question, not yet resolved.** Measured directly
 this session on `phase-1-kalman`, raw `wc -l` (the repo's own established
 method, `find . -name "*.jac" | xargs wc -l`): **58.0%** of product code
 (`jac/*.jac` vs. `tracker/*.py`, `jac/jtms.jac` excluded as in-progress).
 Including `tests/*.py` in the denominator instead: **27.5%** -- short of a
 40% floor if tests are counted in the denominator, comfortably over it if
 they aren't. **Which denominator the judges actually use is unresolved** --
 this is a real, open question the team needs to settle (ideally by asking
 the judges directly, not by guessing the more favorable reading) before
 relying on either number in the pitch. Also unresolved: this number is
 single-branch: merging `origin/abhi/web-frontend`'s Jac pipeline will
 change it in a direction that has not been computed (see
 `docs/devpost-draft.md`'s line-count table for the branch's own
 separately-reported 45.8%).
