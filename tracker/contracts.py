"""Thin Python re-export of the real implementation in jac/contracts.jac.

WHY: this module used to hold ~570 lines of pure vocabulary/validation/parsing
logic with zero numerical kernels -- no scipy, no eigendecomposition, no
shapely. That is exactly the "graph structure and orchestration" category this
project's architecture puts in Jac, not Python (see jac/geofence.jac and
jac/hypothesis.jac for the same split already applied elsewhere). The real
implementation now lives in jac/contracts.jac; this file is a re-export shim so
every existing caller (tracker.geofence, tracker.eval, their tests) keeps
working unchanged.

THE MECHANISM: a bare `import jaclang` registers the `.jac` meta-importer, and
after that `from jac.contracts import ...` is an ordinary Python import that
resolves jac/contracts.jac. No `with entry` trick is needed for this direction
(that's only for Jac calling out to Python).

ContractError is defined here, not in jac/contracts.jac: a Jac object
archetype can subclass ValueError syntactically, but it does not inherit
BaseException's varargs `__init__`, so `raise ContractError("msg")` fails at
runtime (verified). jac/contracts.jac never imports this class at module load
time -- it resolves it LAZILY, on first actual raise, via its own
`contract_error_type()` / `contract_error()` helpers (see that file's module
docstring). That is deliberate, not incidental: an eager import back from
jac/contracts.jac would be circular with this module's own import below, and
the cycle only resolves for whichever module happens to start the import
chain first -- confirmed to break when something imports jac.contracts
directly, ahead of this module. Deferring the lookup past both modules'
import time removes that ordering dependency entirely.
"""


class ContractError(ValueError):
    """A value could not be reconciled across the three contracts, and
    guessing would be worse than failing. A ValueError subclass so existing
    ``except ValueError`` handlers still catch it.

    NOTE: this is *not* ``tracker.geofence.GeofenceContractError``; the two
    are unrelated, and ``ValueError`` is the only handler that spans both.
    """


import jaclang  # noqa: E402,F401  -- registers the .jac import hook

from jac.contracts import (  # noqa: E402
    CANONICAL_KINDS,
    DEFAULT_BUFFER_M_BY_KIND,
    FIELD_ALIASES,
    KIND_ALIASES,
    assert_unique_ids,
    dedupe_ids,
    default_buffer_m,
    namespaced_id,
    normalize_kind,
    parse_bbox,
    parse_epoch,
    parse_origin,
    parse_time_window,
    resolve_field,
)

__all__ = [
    "ContractError",
    "CANONICAL_KINDS",
    "KIND_ALIASES",
    "normalize_kind",
    "FIELD_ALIASES",
    "resolve_field",
    "parse_origin",
    "parse_bbox",
    "DEFAULT_BUFFER_M_BY_KIND",
    "default_buffer_m",
    "namespaced_id",
    "dedupe_ids",
    "assert_unique_ids",
    "parse_epoch",
    "parse_time_window",
]
