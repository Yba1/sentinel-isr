"""Scenario-pack regression harness for the Sentinel-ISR maritime tracker.

What this is for
----------------
Every scenario pack under ``scenarios/*/pack.json`` carries an ``expected``
block: the pack's author writing down, up front, what the engine is supposed to
do with that scenario. This turns the pack set into a regression suite::

    python -m tracker.eval --all

prints one pass/fail/skip row per expected key, per pack, and exits non-zero if
anything genuinely failed. Three outcomes, never two -- PASS/FAIL/SKIP -- and a
SKIP is never a failure. See ``jac/eval.jac`` for the full design rationale
(independence from the replay layer, structural vs measured checks, both
contract spellings, the margin/earth-model story): the logic lives there now,
this module is the public, importable surface.

WHERE THE LOGIC LIVES
----------------------
Everything that used to be 1250 lines of pack discovery, iteration, checker
bodies, report formatting and CLI parsing now lives in ``jac/eval.jac`` --
graph-shaped orchestration over JSON, not a numerical kernel, which is exactly
the category the project's own architecture doc assigns to Jac.

What stays here, and why: the two frozen dataclasses (``CheckResult`` and
``PackResult``), because Jac interop with Python dataclasses is easiest if the
dataclasses themselves stay Python; the ``CHECKERS`` and ``PACK_CHECKS``
registries, kept as plain Python module globals so existing tests can
monkeypatch a single checker (``monkeypatch.setitem(CHECKERS, ...)``) or the
whole pack-check tuple (``monkeypatch.setattr(tracker.eval, "PACK_CHECKS",
...)``) and have that change take effect immediately -- the Jac orchestration
functions always take ``CHECKERS``/``PACK_CHECKS`` as parameters, read from
this module at call time, never as a value captured once at import time; and a
handful of thin wrapper functions that convert the plain dicts Jac returns into
those dataclasses.

Pure stdlib on this side too: dataclasses, typing. No numpy, no network, no LLM.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Literal, Sequence

__all__ = [
    "CheckOutcome",
    "PASS",
    "FAIL",
    "SKIP",
    "CheckResult",
    "PackResult",
    "CHECKERS",
    "PACK_CHECKS",
    "OFFSET_TOLERANCE_FRAC",
    "EARTH_RADIUS_KM",
    "MARGIN_WARN_FRAC",
    "WGS84_A_KM",
    "WGS84_F",
    "discover_packs",
    "load_pack",
    "evaluate_pack",
    "evaluate_all",
    "format_report",
    "main",
]

# --------------------------------------------------------------------------- #
# outcomes -- plain strings, defined here (not in Jac) so the dataclasses
# below can reference them without any cross-language dependency.
# --------------------------------------------------------------------------- #

CheckOutcome = Literal["pass", "fail", "skip"]

PASS: CheckOutcome = "pass"
FAIL: CheckOutcome = "fail"
SKIP: CheckOutcome = "skip"


@dataclass(frozen=True)
class CheckResult:
    """The outcome of one expected-block key.

    ``marginal`` is deliberately the LAST field so that any existing positional
    construction of a CheckResult keeps working. It is an annotation on a PASS,
    not a fourth outcome: a marginal check held, but only just, and by a margin
    thin enough that the earth model decided it.
    """

    key: str
    outcome: str
    detail: str
    expected: object = None
    actual: object = None
    marginal: bool = False


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
    def marginal(self) -> int:
        """Checks that held by a margin thin enough to be model-dependent."""
        return sum(1 for c in self.checks if c.marginal)

    @property
    def ok(self) -> bool:
        """True when nothing FAILED. SKIPs are allowed."""
        return self.failed == 0


# --------------------------------------------------------------------------- #
# Jac interop. Bare `import jaclang` registers the .jac meta-importer; the
# `from jac.eval import ...` below then works as an ordinary import. jac/eval.jac
# is self-contained (no import of this module), so there is no circular import
# here at all -- the coupling the other direction (Jac reading CHECKERS /
# PACK_CHECKS) happens only by these being passed as plain function ARGUMENTS
# from the wrapper functions below, never by Jac importing this module.
# --------------------------------------------------------------------------- #

import jaclang  # noqa: F401  (registers the .jac meta importer)

from jac.eval import (  # noqa: E402
    OFFSET_TOLERANCE_FRAC,
    EARTH_RADIUS_KM,
    MARGIN_WARN_FRAC,
    WGS84_A_KM,
    WGS84_F,
    check_dark_actor,
    check_actors,
    check_intrusion_fence,
    check_spoof_mmsi,
    check_sanctuary_entry_s,
    check_dark_at_s,
    check_radar_contact_at_s,
    check_min_separation_km,
    check_id_switches_max,
    check_reassoc_p_min,
    check_reassoc_correct,
    check_geofence_alert,
    check_offset,
    make_not_built_checker,
    packcheck_referenced_files,
    packcheck_free_text_paths,
    packcheck_bbox,
    packcheck_separation_earth_model,
    packcheck_separation_over_replay,
    discover_packs as _jac_discover_packs,
    load_pack as _jac_load_pack,
    evaluate_pack_core as _jac_evaluate_pack_core,
    evaluate_all_core as _jac_evaluate_all_core,
    format_report as _jac_format_report,
    as_jsonable as _jac_as_jsonable,
    main_core as _jac_main_core,
    _bbox_bounds,
    _collect_file_refs,
    _ellipsoidal_km,
    _haversine_km,
    _parse_epoch,
    _window_bounds,
)

_JTMS = "no JTMS retraction layer (Phase 5 Option A)"
_OFAC = "no OFAC watchlist lookup wired into the tracker"
_RELINK = "no behaviour-based relink layer (kinematic continuity across an MMSI change)"
_SEVERITY = "no alert-severity model, so escalation on relink cannot be observed"

#: The registry -- adding a checker is one line. Looked up at call time by the
#: Jac orchestration (passed in fresh on every call), so tests that monkeypatch
#: an entry (``monkeypatch.setitem(CHECKERS, "dark_actor", ...)``) take effect
#: immediately.
CHECKERS = {
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
    "spoof_detected": make_not_built_checker("spoof_detected", _JTMS),
    "retraction_cascade": make_not_built_checker("retraction_cascade", _JTMS),
    "ofac_hit": make_not_built_checker("ofac_hit", _OFAC),
    "ofac_hit_mmsi": make_not_built_checker("ofac_hit_mmsi", _OFAC),
    "ofac_hit_name": make_not_built_checker("ofac_hit_name", _OFAC),
    "relink_same_track": make_not_built_checker("relink_same_track", _RELINK),
    "severity_escalates_on_relink": make_not_built_checker("severity_escalates_on_relink", _SEVERITY),
}

#: Pack-level checks, run after the ``expected`` rows, in this order. A plain
#: module attribute (not a value baked into a closure) so a test can rebind it
#: wholesale with ``monkeypatch.setattr(tracker.eval, "PACK_CHECKS", (...))``.
PACK_CHECKS = (
    packcheck_referenced_files,
    packcheck_free_text_paths,
    packcheck_bbox,
    packcheck_separation_earth_model,
    packcheck_separation_over_replay,
)


# --------------------------------------------------------------------------- #
# thin wrappers -- convert Jac's plain dicts into the public dataclasses, and
# always read CHECKERS / PACK_CHECKS from this module's own globals so a
# monkeypatch is honoured on the very next call.
# --------------------------------------------------------------------------- #


def _to_check_result(row: dict) -> CheckResult:
    return CheckResult(
        key=row["key"],
        outcome=row["outcome"],
        detail=row["detail"],
        expected=row.get("expected"),
        actual=row.get("actual"),
        marginal=bool(row.get("marginal", False)),
    )


def _to_pack_result(raw: dict) -> PackResult:
    return PackResult(
        pack_id=raw["pack_id"],
        name=raw["name"],
        path=raw["path"],
        checks=tuple(_to_check_result(r) for r in raw["checks"]),
    )


def discover_packs(root=None) -> list:
    """Sorted ``scenarios/*/pack.json`` under ``root``. Never raises."""
    return _jac_discover_packs(root)


def load_pack(path) -> dict:
    """Read one ``pack.json``, with an error that names the file if it is bad."""
    return _jac_load_pack(path)


def evaluate_pack(pack: dict, *, results: dict | None = None) -> PackResult:
    """Run every registered checker over one pack's ``expected`` block."""
    raw = _jac_evaluate_pack_core(pack, results, CHECKERS, PACK_CHECKS)
    return _to_pack_result(raw)


def evaluate_all(root=None, *, results_by_pack: dict | None = None) -> list:
    """Evaluate every discovered pack. Empty list when there are no packs."""
    raw_list = _jac_evaluate_all_core(root, results_by_pack, CHECKERS, PACK_CHECKS)
    return [_to_pack_result(raw) for raw in raw_list]


def format_report(results: Sequence[PackResult], *, use_colour: bool | None = None) -> str:
    """Render the aligned pass/fail/skip report."""
    return _jac_format_report(list(results), use_colour)


def _as_jsonable(results: Sequence[PackResult]) -> dict:
    return _jac_as_jsonable(list(results))


def main(argv: Sequence[str] | None = None) -> int:
    """CLI entry point. Returns 0 unless a check FAILED."""
    return _jac_main_core(argv, evaluate_all, format_report, _as_jsonable)


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
