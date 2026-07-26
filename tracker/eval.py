"""Scenario-pack regression harness for the Sentinel-ISR maritime tracker.

What this is for
----------------
Every scenario pack under ``scenarios/*/pack.json`` carries an ``expected``
block: the pack's author writing down, up front, what the engine is supposed to
do with that scenario. Until this module existed, nothing read those blocks --
they were documentation. This turns the pack set into a regression suite::

    python -m tracker.eval --all

prints one pass/fail/skip row per expected key, per pack, and exits non-zero if
anything genuinely failed.

Three outcomes, never two
-------------------------
This is the central design decision, so it is worth stating plainly.

    PASS  the key was checked and it held.
    FAIL  the key was checked and it did not hold.
    SKIP  the key was NOT checked, and the row says why.

Some ``expected`` keys assert behaviour the engine does not implement yet
(justification-based retraction cascades, OFAC watchlist hits, behaviour-based
relinking). Reporting those as FAIL would bury the real failures in noise;
silently dropping them would be dishonest about what is and is not verified. So
they SKIP, and each SKIP names the missing capability. The summary reports all
three counts and the exit code is 0 unless something actually FAILED -- a SKIP
is not a failure.

``notes`` is free-text provenance written by the pack author. It is never a
check and never produces a row of any kind.

Independence from the replay layer
----------------------------------
Pack JSON is read with stdlib ``json`` and nothing else. This module does not
import ``data.scenario``, ``data.replay``, or ``tracker.geofence``. That is
deliberate: the loader and the packs themselves live on branches that are not
merged yet, and the geofence module is under active edit. Packs are found by
globbing ``scenarios/*/pack.json`` from the repo root, and an absent
``scenarios/`` directory is reported cleanly rather than raised. When the
branches merge, this starts checking the real packs with zero changes here.

Two kinds of check
------------------
STRUCTURAL checks need no engine run. They cross-reference the pack against
itself: does the actor named by ``dark_actor`` actually appear in
``synthetic_actors``? Do the narrative timings fall inside ``time_window`` and
run in the right order? Does ``dark_at_s`` line up with a real ``ais_off``
event? A pack that names an entity it never defines is a genuine authoring bug,
and these catch it today, with no tracker in the loop.

MEASURED checks need a ``results`` dict of actually-measured outcomes from a
replay run. When no run data is supplied they SKIP with that reason, and the
structural checks still run.

Conventions this module assumes about pack data
-----------------------------------------------
* Event kinds are read from key ``kind``, falling back to ``type``. Both are
  accepted and the detail line notes which was used.
* Narrative timings (``dark_at_s`` and friends) are seconds RELATIVE to
  ``time_window.start``, so "inside the window" means ``0 <= t <= duration``.
* ``intrusion_fence`` is matched against the filename stem of each entry in
  ``geofence_layers`` (and against an explicit ``id``/``name``/``kind`` if the
  entry carries one).
* Distances use plain haversine on a sphere of radius 6371.0088 km, chosen on
  principle before looking at any pack's numbers and never tuned to make a row
  green. The computed value is printed to three decimals so the margin against
  the stated threshold is auditable from the back of the room.
* ``min_separation_km`` is checked as the separation at t=0, computed from each
  actor's ``start_latlon``. The time-varying separation is not derivable from
  pack JSON -- track generators like ``gen:transit`` are interpreted by the
  unmerged replay layer -- so the detail line says "initial separation" rather
  than claiming more than was measured.
* ``predicted_vs_true_offset_verified_m`` is a figure the pack author verified
  with a script, not a hard engine guarantee, so it is checked against a
  documented +/-20% tolerance (``OFFSET_TOLERANCE_FRAC``).

Deviation from the build plan
-----------------------------
The plan writes the entry point as ``python -m sentinel.eval --all``. There is
no ``sentinel/`` package in this repository; the package is ``tracker/``. The
real invocation is therefore::

    python -m tracker.eval --all

Pure stdlib: json, math, argparse, dataclasses, datetime, pathlib. No numpy, no
network, no LLM.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, Callable, Literal, Sequence

__all__ = [
    "CheckOutcome",
    "PASS",
    "FAIL",
    "SKIP",
    "CheckResult",
    "PackResult",
    "CHECKERS",
    "OFFSET_TOLERANCE_FRAC",
    "EARTH_RADIUS_KM",
    "discover_packs",
    "load_pack",
    "evaluate_pack",
    "evaluate_all",
    "format_report",
    "main",
]

# --------------------------------------------------------------------------- #
# outcomes
# --------------------------------------------------------------------------- #

CheckOutcome = Literal["pass", "fail", "skip"]

PASS: CheckOutcome = "pass"
FAIL: CheckOutcome = "fail"
SKIP: CheckOutcome = "skip"

#: Keys that are provenance, not assertions. These never produce a row.
NON_CHECK_KEYS: frozenset[str] = frozenset({"notes"})

#: Private key injected by :func:`load_pack` so :class:`PackResult` can report
#: where the pack came from without changing the frozen ``evaluate_pack``
#: signature. Absent when a caller hands ``evaluate_pack`` a hand-built dict.
SOURCE_PATH_KEY = "_source_path"

#: Tolerance on ``predicted_vs_true_offset_verified_m``. The pack figure is a
#: verified authoring measurement of a naive-extrapolation miss distance, which
#: shifts with frame snapping and filter tuning; +/-20% keeps the check
#: meaningful (it would still catch an order-of-magnitude regression or a sign
#: error) without turning ordinary retuning into a red row on stage.
OFFSET_TOLERANCE_FRAC: float = 0.20

#: Mean-Earth-radius sphere, IUGG. Fixed by choice, not fitted to pack data.
EARTH_RADIUS_KM: float = 6371.0088

#: Longest detail sentence rendered before elision, so one verbose ``expected``
#: value cannot wreck the column alignment of the whole report.
MAX_DETAIL_CHARS: int = 96


@dataclass(frozen=True)
class CheckResult:
    """The outcome of one expected-block key."""

    key: str
    outcome: str
    detail: str
    expected: object = None
    actual: object = None


@dataclass(frozen=True)
class PackResult:
    """Every check run against one pack."""

    pack_id: str
    name: str
    path: str
    checks: tuple  # tuple[CheckResult, ...]

    @property
    def passed(self) -> int:
        return sum(1 for c in self.checks if c.outcome == PASS)

    @property
    def failed(self) -> int:
        return sum(1 for c in self.checks if c.outcome == FAIL)

    @property
    def skipped(self) -> int:
        return sum(1 for c in self.checks if c.outcome == SKIP)

    @property
    def ok(self) -> bool:
        """True when nothing FAILED. SKIPs are allowed."""
        return self.failed == 0


# --------------------------------------------------------------------------- #
# small result constructors
# --------------------------------------------------------------------------- #


def _passed(key: str, detail: str, expected: object = None, actual: object = None) -> CheckResult:
    return CheckResult(key=key, outcome=PASS, detail=detail, expected=expected, actual=actual)


def _failed(key: str, detail: str, expected: object = None, actual: object = None) -> CheckResult:
    return CheckResult(key=key, outcome=FAIL, detail=detail, expected=expected, actual=actual)


def _skipped(key: str, reason: str, expected: object = None) -> CheckResult:
    return CheckResult(key=key, outcome=SKIP, detail=reason, expected=expected)


# --------------------------------------------------------------------------- #
# pack introspection helpers
# --------------------------------------------------------------------------- #


def _actor_ids(pack: dict) -> list[str]:
    """Actor ids defined by ``synthetic_actors``, in pack order."""
    out: list[str] = []
    for actor in pack.get("synthetic_actors") or ():
        if isinstance(actor, dict):
            aid = actor.get("actor_id") or actor.get("id")
            if aid is not None:
                out.append(str(aid))
    return out


def _actor(pack: dict, actor_id: str) -> dict | None:
    for actor in pack.get("synthetic_actors") or ():
        if isinstance(actor, dict) and str(actor.get("actor_id") or actor.get("id")) == actor_id:
            return actor
    return None


def _actor_start_latlon(actor: dict) -> tuple[float, float] | None:
    """``(lat, lon)`` for an actor whose params carry a start position."""
    params = actor.get("params") or {}
    for key in ("start_latlon", "start_lat_lon", "latlon", "start"):
        val = params.get(key)
        if isinstance(val, (list, tuple)) and len(val) == 2:
            try:
                return float(val[0]), float(val[1])
            except (TypeError, ValueError):
                return None
    lat, lon = params.get("lat"), params.get("lon")
    if lat is not None and lon is not None:
        try:
            return float(lat), float(lon)
        except (TypeError, ValueError):
            return None
    return None


def _event_kind(event: dict) -> tuple[str | None, str | None]:
    """``(kind, key_used)``. Omar's packs use ``kind``; ``type`` is accepted."""
    if "kind" in event:
        return (None if event["kind"] is None else str(event["kind"])), "kind"
    if "type" in event:
        return (None if event["type"] is None else str(event["type"])), "type"
    return None, None


def _events_of_kind(pack: dict, kind: str) -> list[tuple[dict, str]]:
    """Every event whose kind matches, paired with the key it was read from."""
    out: list[tuple[dict, str]] = []
    for event in pack.get("events") or ():
        if not isinstance(event, dict):
            continue
        found, key_used = _event_kind(event)
        if found == kind and key_used is not None:
            out.append((event, key_used))
    return out


def _fence_names(pack: dict) -> list[str]:
    """Every name a ``geofence_layers`` entry could reasonably be called by."""
    names: list[str] = []
    for layer in pack.get("geofence_layers") or ():
        if isinstance(layer, str):
            names.append(Path(layer).stem)
            continue
        if not isinstance(layer, dict):
            continue
        for key in ("id", "name", "fence_id", "layer_id"):
            val = layer.get(key)
            if val:
                names.append(str(val))
        file = layer.get("file") or layer.get("path")
        if file:
            names.append(Path(str(file)).stem)
    return names


def _window_duration_s(pack: dict) -> float | None:
    """Length of ``time_window`` in seconds, or None if not parseable."""
    window = pack.get("time_window")
    if not isinstance(window, dict):
        return None
    start, end = window.get("start"), window.get("end")
    if isinstance(start, (int, float)) and isinstance(end, (int, float)):
        return float(end) - float(start)
    if not isinstance(start, str) or not isinstance(end, str):
        return None
    try:
        t0 = datetime.fromisoformat(start)
        t1 = datetime.fromisoformat(end)
    except ValueError:
        return None
    return (t1 - t0).total_seconds()


def _haversine_km(a: tuple[float, float], b: tuple[float, float]) -> float:
    """Great-circle distance in km between ``(lat, lon)`` pairs.

    Plain haversine on a sphere of radius :data:`EARTH_RADIUS_KM`. Not an
    ellipsoidal geodesic -- see the module docstring on why the model is fixed
    by choice rather than by whichever radius makes a threshold pass.
    """
    lat1, lon1 = math.radians(a[0]), math.radians(a[1])
    lat2, lon2 = math.radians(b[0]), math.radians(b[1])
    dlat, dlon = lat2 - lat1, lon2 - lon1
    h = math.sin(dlat / 2.0) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin(dlon / 2.0) ** 2
    return 2.0 * EARTH_RADIUS_KM * math.asin(math.sqrt(min(1.0, h)))


def _run_value(results: dict | None, key: str, check_key: str) -> tuple[bool, Any, CheckResult | None]:
    """Fetch ``key`` from run data, or the SKIP that explains its absence."""
    if results is None:
        return False, None, _skipped(check_key, "no run data supplied (structural checks only)")
    if key not in results:
        return False, None, _skipped(check_key, f"run data supplied but has no {key!r} entry")
    return True, results[key], None


# --------------------------------------------------------------------------- #
# STRUCTURAL checkers -- these work with no engine run at all
# --------------------------------------------------------------------------- #


def check_dark_actor(expected: Any, pack: dict, results: dict | None) -> CheckResult:
    """The actor named as going dark must be defined by the pack."""
    ids = _actor_ids(pack)
    name = str(expected)
    if name in ids:
        return _passed("dark_actor", f"actor {name!r} is defined in synthetic_actors", expected, name)
    return _failed(
        "dark_actor",
        f"actor {name!r} is NOT defined in synthetic_actors (defined: {ids or 'none'})",
        expected,
        ids,
    )


def check_actors(expected: Any, pack: dict, results: dict | None) -> CheckResult:
    """Every actor the expected block names must be defined by the pack."""
    ids = _actor_ids(pack)
    wanted = [str(a) for a in (expected if isinstance(expected, (list, tuple)) else [expected])]
    missing = [a for a in wanted if a not in ids]
    if not missing:
        return _passed(
            "actors",
            f"all {len(wanted)} named actor(s) defined in synthetic_actors: {', '.join(wanted)}",
            expected,
            ids,
        )
    return _failed(
        "actors",
        f"named actor(s) not defined in synthetic_actors: {', '.join(missing)} (defined: {ids or 'none'})",
        expected,
        ids,
    )


def check_intrusion_fence(expected: Any, pack: dict, results: dict | None) -> CheckResult:
    """The fence the intrusion is expected on must exist in geofence_layers."""
    names = _fence_names(pack)
    want = str(expected)
    if not names:
        return _failed(
            "intrusion_fence",
            f"fence {want!r} expected but the pack declares no geofence_layers",
            expected,
            names,
        )
    if want in names:
        return _passed("intrusion_fence", f"fence {want!r} found in geofence_layers", expected, want)
    return _failed(
        "intrusion_fence",
        f"fence {want!r} not in geofence_layers (found: {', '.join(sorted(set(names)))})",
        expected,
        names,
    )


def check_spoof_mmsi(expected: Any, pack: dict, results: dict | None) -> CheckResult:
    """The spoofed identity must actually be broadcast by some event."""
    want = str(expected)
    broadcasters: list[str] = []
    for event in pack.get("events") or ():
        if not isinstance(event, dict):
            continue
        params = event.get("params") or {}
        values = [str(v) for v in params.values() if isinstance(v, (str, int, float))]
        if want in values:
            broadcasters.append(str(event.get("actor", event.get("id", "?"))))
    if not broadcasters:
        return _failed(
            "spoof_mmsi",
            f"identity {want!r} is never broadcast by any event in the pack",
            expected,
            None,
        )
    unique = sorted(set(broadcasters))
    return _passed(
        "spoof_mmsi",
        f"identity {want!r} broadcast by {len(unique)} actor(s): {', '.join(unique)}",
        expected,
        unique,
    )


def _check_timing(
    key: str,
    expected: Any,
    pack: dict,
    *,
    must_follow: Sequence[str] = (),
    event_kind: str | None = None,
) -> CheckResult:
    """Shared body for the narrative-timing keys.

    Asserts the value is a number inside ``time_window``, that it comes after
    each earlier narrative beat that the pack also declares, and -- when
    ``event_kind`` is given -- that some event of that kind fires at that time.
    """
    try:
        t = float(expected)
    except (TypeError, ValueError):
        return _failed(key, f"value {expected!r} is not a number of seconds", expected, expected)

    problems: list[str] = []
    facts: list[str] = []

    duration = _window_duration_s(pack)
    if duration is None:
        facts.append("time_window not parseable, in-window check omitted")
    elif 0.0 <= t <= duration:
        facts.append(f"t={t:g}s in window (0-{duration:g}s)")
    else:
        problems.append(f"t={t:g}s is OUTSIDE the {duration:g}s time_window")

    block = pack.get("expected") or {}
    for earlier in must_follow:
        if earlier not in block:
            continue
        try:
            t_earlier = float(block[earlier])
        except (TypeError, ValueError):
            continue
        if t > t_earlier:
            facts.append(f"after {earlier}={t_earlier:g}s")
        else:
            problems.append(f"NOT after {earlier}={t_earlier:g}s (ordering violated)")

    if event_kind is not None:
        matches = _events_of_kind(pack, event_kind)
        hit = [(ev, k) for ev, k in matches if math.isclose(float(ev.get("t", math.nan)), t, rel_tol=0.0, abs_tol=1e-6)]
        if hit:
            _, key_used = hit[0]
            note = "" if key_used == "kind" else f" (via event key {key_used!r})"
            facts.append(f"{event_kind} event at that t{note}")
        elif matches:
            times = ", ".join(f"{float(ev.get('t', math.nan)):g}" for ev, _ in matches)
            problems.append(f"no {event_kind!r} event at t={t:g}s (events at: {times})")
        else:
            problems.append(f"the pack declares no {event_kind!r} event at all")

    if problems:
        return _failed(key, "; ".join(problems), expected, t)
    return _passed(key, "; ".join(facts), expected, t)


def check_sanctuary_entry_s(expected: Any, pack: dict, results: dict | None) -> CheckResult:
    """First narrative beat: the boundary crossing. In-window only."""
    return _check_timing("sanctuary_entry_s", expected, pack)


def check_dark_at_s(expected: Any, pack: dict, results: dict | None) -> CheckResult:
    """Second beat: AIS goes off. Must follow entry and match an ais_off event."""
    return _check_timing(
        "dark_at_s", expected, pack, must_follow=("sanctuary_entry_s",), event_kind="ais_off"
    )


def check_radar_contact_at_s(expected: Any, pack: dict, results: dict | None) -> CheckResult:
    """Third beat: radar reacquisition. Must follow going dark."""
    return _check_timing("radar_contact_at_s", expected, pack, must_follow=("dark_at_s",))


def check_min_separation_km(expected: Any, pack: dict, results: dict | None) -> CheckResult:
    """Separation at t=0 between the pack's two actors must meet the minimum.

    SKIPs when the pack does not define exactly two actors with derivable start
    positions -- the time-varying separation depends on track generators this
    module deliberately does not interpret.
    """
    key = "min_separation_km"
    try:
        want = float(expected)
    except (TypeError, ValueError):
        return _failed(key, f"value {expected!r} is not a number of km", expected, expected)

    positioned: list[tuple[str, tuple[float, float]]] = []
    for aid in _actor_ids(pack):
        actor = _actor(pack, aid)
        if actor is None:
            continue
        pos = _actor_start_latlon(actor)
        if pos is not None:
            positioned.append((aid, pos))

    if len(positioned) < 2:
        return _skipped(
            key,
            f"needs two actors with a start position; {len(positioned)} derivable from pack JSON",
            expected,
        )
    if len(positioned) > 2:
        pairs = [
            _haversine_km(positioned[i][1], positioned[j][1])
            for i in range(len(positioned))
            for j in range(i + 1, len(positioned))
        ]
        actual = min(pairs)
        label = f"closest initial pair of {len(positioned)} actors"
    else:
        actual = _haversine_km(positioned[0][1], positioned[1][1])
        label = f"initial {positioned[0][0]}<->{positioned[1][0]}"

    shared = f"{label} = {actual:.3f} km vs {want:.3f} km required (haversine, R={EARTH_RADIUS_KM:g} km)"
    if actual >= want:
        return _passed(key, shared, expected, round(actual, 3))
    return _failed(key, shared + " -- SHORT", expected, round(actual, 3))


# --------------------------------------------------------------------------- #
# MEASURED checkers -- need a results dict from a real replay run
# --------------------------------------------------------------------------- #


def check_id_switches_max(expected: Any, pack: dict, results: dict | None) -> CheckResult:
    key = "id_switches_max"
    have, actual, skip = _run_value(results, "id_switches", key)
    if not have:
        return skip  # type: ignore[return-value]
    limit = float(expected)
    detail = f"measured {actual} id switch(es) vs at most {limit:g} allowed"
    if float(actual) <= limit:
        return _passed(key, detail, expected, actual)
    return _failed(key, detail + " -- OVER", expected, actual)


def check_reassoc_p_min(expected: Any, pack: dict, results: dict | None) -> CheckResult:
    key = "reassoc_p_min"
    have, actual, skip = _run_value(results, "reassoc_p", key)
    if not have:
        return skip  # type: ignore[return-value]
    floor = float(expected)
    detail = f"reassociation p={float(actual):.4f} vs floor {floor:.4f}"
    if float(actual) >= floor:
        return _passed(key, detail, expected, actual)
    return _failed(key, detail + " -- BELOW", expected, actual)


def check_reassoc_correct(expected: Any, pack: dict, results: dict | None) -> CheckResult:
    """The reacquired detection must be attributed to the ground-truth actor."""
    key = "reassoc_correct"
    have, actual, skip = _run_value(results, "reassoc_track_id", key)
    if not have:
        return skip  # type: ignore[return-value]
    block = pack.get("expected") or {}
    truth = block.get("dark_actor")
    if truth is None:
        ids = _actor_ids(pack)
        if len(ids) != 1:
            return _skipped(
                key,
                "ground-truth actor is ambiguous (no dark_actor and not exactly one actor)",
                expected,
            )
        truth = ids[0]
    detail = f"reacquisition attributed to {str(actual)!r}, ground truth {str(truth)!r}"
    if str(actual) == str(truth):
        return _passed(key, detail, truth, actual)
    return _failed(key, detail + " -- MISATTRIBUTED", truth, actual)


def check_geofence_alert(expected: Any, pack: dict, results: dict | None) -> CheckResult:
    """At least one geofence alert must fire, on the expected fence if named."""
    key = "geofence_alert"
    have, alerts, skip = _run_value(results, "geofence_alerts", key)
    if not have:
        return skip  # type: ignore[return-value]
    alerts = list(alerts or ())
    want_alert = bool(expected)

    if not want_alert:
        detail = f"pack expects no geofence alert; run produced {len(alerts)}"
        return _passed(key, detail, expected, len(alerts)) if not alerts else _failed(
            key, detail, expected, len(alerts)
        )

    if not alerts:
        return _failed(key, "pack expects a geofence alert; the run produced none", expected, [])

    fence = (pack.get("expected") or {}).get("intrusion_fence")
    if fence is None:
        return _passed(key, f"{len(alerts)} geofence alert(s) fired", expected, len(alerts))

    seen: list[str] = []
    for alert in alerts:
        if isinstance(alert, str):
            seen.append(alert)
        elif isinstance(alert, dict):
            for k in ("fence", "fence_id", "layer", "layer_id", "name", "id"):
                if alert.get(k):
                    seen.append(str(alert[k]))
    if str(fence) in seen:
        return _passed(
            key,
            f"{len(alerts)} alert(s), at least one on the expected fence {str(fence)!r}",
            expected,
            seen,
        )
    return _failed(
        key,
        f"{len(alerts)} alert(s) but none on fence {str(fence)!r} (saw: {', '.join(seen) or 'unnamed'})",
        expected,
        seen,
    )


def check_offset(expected: Any, pack: dict, results: dict | None) -> CheckResult:
    """Naive-prediction-vs-truth miss distance, within +/-20% of the pack figure."""
    key = "predicted_vs_true_offset_verified_m"
    have, actual, skip = _run_value(results, "offset_m", key)
    if not have:
        return skip  # type: ignore[return-value]
    want = float(expected)
    got = float(actual)
    tol = abs(want) * OFFSET_TOLERANCE_FRAC
    detail = (
        f"offset {got:.0f} m vs verified {want:.0f} m "
        f"(tolerance +/-{OFFSET_TOLERANCE_FRAC:.0%} = +/-{tol:.0f} m)"
    )
    if abs(got - want) <= tol:
        return _passed(key, detail, expected, actual)
    return _failed(key, detail + " -- OUT OF TOLERANCE", expected, actual)


# --------------------------------------------------------------------------- #
# NOT-BUILT checkers -- always SKIP, naming the capability that is missing
# --------------------------------------------------------------------------- #


def _not_built(key: str, capability: str) -> Callable[[Any, dict, dict | None], CheckResult]:
    """Build a checker that always SKIPs, naming what is missing.

    The expected value is deliberately not echoed into the detail: at least one
    pack stores a hundred-character sentence there, which would wreck the
    report's alignment on a projector.
    """

    def checker(expected: Any, pack: dict, results: dict | None) -> CheckResult:
        return _skipped(key, f"not implemented: {capability}", expected)

    checker.__name__ = f"check_{key}_not_built"
    checker.__doc__ = f"Always SKIP -- {capability}."
    return checker


_JTMS = "no JTMS retraction layer (Phase 5 Option A)"
_OFAC = "no OFAC watchlist lookup wired into the tracker"
_RELINK = "no behaviour-based relink layer (kinematic continuity across an MMSI change)"
_SEVERITY = "no alert-severity model, so escalation on relink cannot be observed"


# --------------------------------------------------------------------------- #
# the registry -- adding a checker is one line
# --------------------------------------------------------------------------- #

CHECKERS: dict[str, Callable[[Any, dict, dict | None], CheckResult]] = {
    # structural
    "dark_actor": check_dark_actor,
    "actors": check_actors,
    "intrusion_fence": check_intrusion_fence,
    "spoof_mmsi": check_spoof_mmsi,
    "sanctuary_entry_s": check_sanctuary_entry_s,
    "dark_at_s": check_dark_at_s,
    "radar_contact_at_s": check_radar_contact_at_s,
    "min_separation_km": check_min_separation_km,
    # measured
    "id_switches_max": check_id_switches_max,
    "reassoc_p_min": check_reassoc_p_min,
    "reassoc_correct": check_reassoc_correct,
    "geofence_alert": check_geofence_alert,
    "predicted_vs_true_offset_verified_m": check_offset,
    # not built
    "spoof_detected": _not_built("spoof_detected", _JTMS),
    "retraction_cascade": _not_built("retraction_cascade", _JTMS),
    "ofac_hit": _not_built("ofac_hit", _OFAC),
    "ofac_hit_mmsi": _not_built("ofac_hit_mmsi", _OFAC),
    "ofac_hit_name": _not_built("ofac_hit_name", _OFAC),
    "relink_same_track": _not_built("relink_same_track", _RELINK),
    "severity_escalates_on_relink": _not_built("severity_escalates_on_relink", _SEVERITY),
}


# --------------------------------------------------------------------------- #
# discovery and loading
# --------------------------------------------------------------------------- #


def _default_root() -> Path:
    """Repo root, derived from this file's location (``<root>/tracker/eval.py``)."""
    return Path(__file__).resolve().parent.parent


def discover_packs(root: str | Path | None = None) -> list[Path]:
    """Sorted ``scenarios/*/pack.json`` under ``root``.

    Returns an empty list -- never raises -- when ``scenarios/`` is absent, so
    running the harness in a tree that has not merged the pack branch yet is a
    clean "no packs found" rather than a traceback.
    """
    base = Path(root) if root is not None else _default_root()
    scenarios = base / "scenarios"
    if not scenarios.is_dir():
        return []
    return sorted(p for p in scenarios.glob("*/pack.json") if p.is_file())


def load_pack(path: str | Path) -> dict:
    """Read one ``pack.json``, with an error that names the file if it is bad."""
    p = Path(path)
    try:
        text = p.read_text(encoding="utf-8")
    except OSError as exc:
        raise ValueError(f"cannot read scenario pack {p}: {exc}") from exc
    try:
        pack = json.loads(text)
    except json.JSONDecodeError as exc:
        raise ValueError(
            f"malformed scenario pack {p}: {exc.msg} at line {exc.lineno} column {exc.colno}"
        ) from exc
    if not isinstance(pack, dict):
        raise ValueError(f"malformed scenario pack {p}: top level is {type(pack).__name__}, expected an object")
    pack[SOURCE_PATH_KEY] = str(p)
    return pack


# --------------------------------------------------------------------------- #
# evaluation
# --------------------------------------------------------------------------- #


def evaluate_pack(pack: dict, *, results: dict | None = None) -> PackResult:
    """Run every registered checker over one pack's ``expected`` block.

    ``results`` is an optional dict of ACTUAL measured outcomes from a replay
    run. When it is None, every key that needs measured data reports SKIP with
    reason "no run data supplied"; structural keys are still checked.

    Rows come out in the pack author's own key order. No checker exception can
    abort the run: it is caught and reported as a FAIL carrying the message.
    """
    block = pack.get("expected")
    checks: list[CheckResult] = []

    if not isinstance(block, dict):
        checks.append(
            _failed(
                "expected",
                f"pack has no usable 'expected' block (found {type(block).__name__})",
                None,
                block,
            )
            if block is not None
            else _skipped("expected", "pack declares no 'expected' block, so there is nothing to check")
        )
        block = {}

    for key, value in block.items():
        if key in NON_CHECK_KEYS:
            continue  # provenance, never a check -- not even a SKIP row
        checker = CHECKERS.get(key)  # looked up at call time so tests can patch
        if checker is None:
            checks.append(_skipped(key, "no checker registered for this key", value))
            continue
        try:
            result = checker(value, pack, results)
        except Exception as exc:  # a broken checker must not kill the suite
            checks.append(
                _failed(key, f"checker raised {type(exc).__name__}: {exc}", value, None)
            )
            continue
        if not isinstance(result, CheckResult):
            checks.append(
                _failed(key, f"checker returned {type(result).__name__}, expected CheckResult", value, None)
            )
            continue
        checks.append(result)

    return PackResult(
        pack_id=str(pack.get("id", "<unnamed pack>")),
        name=str(pack.get("name", "")),
        path=str(pack.get(SOURCE_PATH_KEY, "")),
        checks=tuple(checks),
    )


def evaluate_all(
    root: str | Path | None = None, *, results_by_pack: dict | None = None
) -> list[PackResult]:
    """Evaluate every discovered pack. Empty list when there are no packs."""
    out: list[PackResult] = []
    for path in discover_packs(root):
        pack = load_pack(path)
        results = None
        if results_by_pack:
            results = results_by_pack.get(str(pack.get("id"))) or results_by_pack.get(str(path))
        out.append(evaluate_pack(pack, results=results))
    return out


# --------------------------------------------------------------------------- #
# the projector-facing report
# --------------------------------------------------------------------------- #

_LABEL = {PASS: "PASS", FAIL: "FAIL", SKIP: "SKIP"}
_COLOUR = {PASS: "\x1b[32m", FAIL: "\x1b[1;31m", SKIP: "\x1b[33m"}
_DIM = "\x1b[2m"
_BOLD = "\x1b[1m"
_RESET = "\x1b[0m"

#: The horizontal rules are sized to the widest line actually rendered, clamped
#: into this range, so the report never shows a rule shorter than its own rows.
_RULE_MIN, _RULE_MAX = 70, 132


def _short_path(path: str) -> str:
    """Trim a pack path down to something that fits on a projected line.

    Relative to the cwd when the pack is underneath it (the normal case, giving
    ``scenarios/s01_.../pack.json``); otherwise the last three components, so a
    deep temp directory does not push the whole line off the slide.
    """
    if not path:
        return ""
    p = Path(path)
    try:
        return str(p.relative_to(Path.cwd()))
    except ValueError:
        pass
    parts = p.parts
    return str(Path(*parts[-3:])) if len(parts) > 3 else str(p)


def _elide(text: str, limit: int = MAX_DETAIL_CHARS) -> str:
    text = " ".join(str(text).split())
    return text if len(text) <= limit else text[: limit - 3].rstrip() + "..."


def format_report(results: Sequence[PackResult], *, use_colour: bool | None = None) -> str:
    """Render the aligned pass/fail/skip report.

    ANSI colour is emitted only when ``use_colour`` is True, or when it is None
    and stdout is a tty. Passing False guarantees an escape-free string, which
    is what makes the output safe to assert on in tests.
    """
    if use_colour is None:
        use_colour = bool(getattr(sys.stdout, "isatty", lambda: False)())

    def paint(text: str, code: str) -> str:
        return f"{code}{text}{_RESET}" if use_colour else text

    results = list(results)
    lines: list[str] = []

    if not results:
        rule = "=" * _RULE_MIN
        lines.append(paint("Sentinel-ISR scenario regression suite", _BOLD))
        lines.append(rule)
        lines.append("no packs found -- scenarios/*/pack.json matched nothing under this root.")
        lines.append(rule)
        lines.append("TOTAL   0 packs   0 passed   0 failed   0 skipped")
        return "\n".join(lines)

    # One key column width across ALL packs, so the blocks line up with each other.
    width = max((len(c.key) for r in results for c in r.checks), default=0)
    width = max(width, 12)

    # Size the rules to the widest line this report will actually print.
    row_w = max(
        (8 + width + 2 + len(_elide(c.detail)) for r in results for c in r.checks), default=0
    )
    head_w = max(
        (len(r.pack_id) + (6 + len(_elide(r.name, 70)) if r.name else 0) for r in results), default=0
    )
    rule_w = min(_RULE_MAX, max(_RULE_MIN, row_w, head_w))
    rule = "=" * rule_w
    thin = "-" * rule_w

    lines.append(paint("Sentinel-ISR scenario regression suite", _BOLD))
    lines.append(rule)

    total_pass = total_fail = total_skip = 0

    for res in results:
        lines.append("")
        header = res.pack_id if not res.name else f"{res.pack_id}  --  {_elide(res.name, 70)}"
        lines.append(paint(header, _BOLD))
        if res.path:
            lines.append(paint(f"  {_short_path(res.path)}", _DIM))
        if not res.checks:
            lines.append("  (no expected keys to check)")
        for check in res.checks:
            tag = paint(_LABEL.get(check.outcome, check.outcome.upper()[:4]), _COLOUR.get(check.outcome, ""))
            lines.append(f"  {tag}  {check.key.ljust(width)}  {_elide(check.detail)}")
        lines.append(
            f"  {thin[:width + 14]}"
        )
        lines.append(
            f"  {res.passed} passed   {res.failed} failed   {res.skipped} skipped"
            + ("" if res.ok else paint("   <-- FAILURES IN THIS PACK", _COLOUR[FAIL]))
        )
        total_pass += res.passed
        total_fail += res.failed
        total_skip += res.skipped

    verdict = "OK" if total_fail == 0 else f"{total_fail} FAILED"
    lines.append("")
    lines.append(rule)
    lines.append(
        f"TOTAL   {len(results)} pack(s)   "
        f"{paint(f'{total_pass} passed', _COLOUR[PASS])}   "
        f"{paint(f'{total_fail} failed', _COLOUR[FAIL] if total_fail else '')}   "
        f"{paint(f'{total_skip} skipped', _COLOUR[SKIP])}   ->  "
        f"{paint(verdict, _BOLD + (_COLOUR[PASS] if total_fail == 0 else _COLOUR[FAIL]))}"
    )
    if total_skip:
        lines.append(
            paint("        SKIP = not checked (capability not built, or no run data). Not a failure.", _DIM)
        )
    return "\n".join(lines)


def _as_jsonable(results: Sequence[PackResult]) -> dict:
    packs = [
        {
            "pack_id": r.pack_id,
            "name": r.name,
            "path": r.path,
            "passed": r.passed,
            "failed": r.failed,
            "skipped": r.skipped,
            "ok": r.ok,
            "checks": [
                {
                    "key": c.key,
                    "outcome": c.outcome,
                    "detail": c.detail,
                    "expected": c.expected,
                    "actual": c.actual,
                }
                for c in r.checks
            ],
        }
        for r in results
    ]
    return {
        "packs": packs,
        "summary": {
            "packs": len(packs),
            "passed": sum(p["passed"] for p in packs),
            "failed": sum(p["failed"] for p in packs),
            "skipped": sum(p["skipped"] for p in packs),
            "ok": all(p["ok"] for p in packs),
        },
    }


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #

#: Exit code for a usage problem (unknown --pack, malformed JSON). Distinct from
#: 1, which means "a check actually FAILED".
EXIT_USAGE = 2


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python -m tracker.eval",
        description="Check every scenario pack's `expected` block. PASS / FAIL / SKIP.",
        epilog="Exit 0 unless a check FAILED (SKIPs are not failures); 2 on a usage error.",
    )
    parser.add_argument("--all", action="store_true", help="check every discovered pack (default)")
    parser.add_argument("--pack", metavar="ID", default=None, help="check only the pack with this id")
    parser.add_argument(
        "--root", metavar="DIR", default=None, help="repo root to glob scenarios/*/pack.json under"
    )
    parser.add_argument("--json", action="store_true", help="machine-readable dump instead of the report")
    parser.add_argument("--quiet", action="store_true", help="summary line only")
    parser.add_argument(
        "--colour", "--color", dest="colour", choices=("auto", "always", "never"), default="auto",
        help="ANSI colour in the report (default: auto, i.e. only on a tty)",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    """CLI entry point. Returns 0 unless a check FAILED."""
    args = _build_parser().parse_args(list(argv) if argv is not None else None)

    try:
        results = evaluate_all(args.root)
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return EXIT_USAGE

    if args.pack is not None:
        wanted = [r for r in results if r.pack_id == args.pack]
        if not wanted:
            known = ", ".join(r.pack_id for r in results) or "none"
            print(f"error: no pack with id {args.pack!r} (found: {known})", file=sys.stderr)
            return EXIT_USAGE
        results = wanted

    if not results:
        print("no packs found -- scenarios/*/pack.json matched nothing. Nothing to check.")
        return 0

    failed = sum(r.failed for r in results)

    if args.json:
        print(json.dumps(_as_jsonable(results), indent=2, default=str))
    elif args.quiet:
        passed = sum(r.passed for r in results)
        skipped = sum(r.skipped for r in results)
        verdict = "OK" if failed == 0 else "FAILED"
        print(
            f"{len(results)} pack(s): {passed} passed, {failed} failed, {skipped} skipped -> {verdict}"
        )
    else:
        use_colour = {"auto": None, "always": True, "never": False}[args.colour]
        print(format_report(results, use_colour=use_colour))

    return 1 if failed else 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
