"""Standalone alternate briefing-template library -- currently unwired, not
imported by jac/brief.jac, web/server.py, or any test. jac/brief.jac's
compose_brief() always starts from jtms.brief_for()'s single deterministic
template and only varies the LLM-polish layer on top of it; this module is
a parallel exploration of varying the deterministic template itself by
audience (operator console vs. command-brief vs. public-facing summary),
independent of anything jac/brief.jac actually does.

WHY THIS EXISTS
-----------------
A JTMS conclusion's brief_for() sentence ("identity_b_confirmed: IN -> OUT
(justification j_b1 not satisfied: ...)") is precise and audit-friendly,
but it is also exactly the same register regardless of who is reading it.
An operator at a console wants the precise justification-graph language; a
watch commander skimming a shift-change brief wants a two-clause summary;
a public-facing incident report wants no internal identifiers
("track") at all. This module explores three template registers over the
SAME explain()-shaped input jac/jtms.jac already produces, without ever
calling jac/jtms.jac itself (it operates on a caller-supplied dict shaped
like explain()'s return value, so it could be pointed at jtms.explain()'s
real output without a hard import dependency on that module).
"""

import math;

# ---------------------------------------------------------------------------
# Register enum (as a plain string constant set, since Jac's node/enum
# story is still being explored elsewhere in this codebase -- see
# jac/hypothesis.jac's notes on avoiding certain compiler-fragile
# constructs; a plain string is the same discipline applied here).
# ---------------------------------------------------------------------------

glob REGISTER_OPERATOR: str = "operator";
glob REGISTER_COMMAND: str = "command";
glob REGISTER_PUBLIC: str = "public";

glob ALL_REGISTERS: list = [REGISTER_OPERATOR, REGISTER_COMMAND, REGISTER_PUBLIC];


# ---------------------------------------------------------------------------
# Shared helpers -- reading an explain()-shaped dict without depending on
# jac/jtms.jac's actual Conclusion/Fact node types.
# ---------------------------------------------------------------------------

def _satisfied_justification(explanation: dict) -> dict {
    """The first satisfied justification in an explain()-shaped dict, or
    an empty dict if none are (e.g. the conclusion is OUT)."""
    for j in explanation.get("justifications", []) {
        if j.get("satisfied") {
            return j;
        }
    }
    return {};
}


def _first_unsatisfied_justification(explanation: dict) -> dict {
    justs = explanation.get("justifications", []);
    if not justs {
        return {};
    }
    return justs[0];
}


def _antecedent_labels(justification: dict) -> list {
    return [a.get("label", "") for a in justification.get("antecedents", [])];
}


def _inhibitor_labels(justification: dict) -> list {
    return [i.get("label", "") for i in justification.get("inhibitors", [])];
}


def _failing_antecedent_labels(justification: dict) -> list {
    return [
        a.get("label", "") for a in justification.get("antecedents", [])
        if not a.get("satisfied", True)
    ];
}


def _failing_inhibitor_labels(justification: dict) -> list {
    return [
        i.get("label", "") for i in justification.get("inhibitors", [])
        if not i.get("satisfied", True)
    ];
}


# ---------------------------------------------------------------------------
# Operator register -- maximally precise, names every justification id and
# every antecedent/inhibitor, matches jac/jtms.jac's own brief_for() closely
# in spirit but is generated independently here.
# ---------------------------------------------------------------------------

def operator_brief(explanation: dict) -> str {
    """Full justification-graph detail: status, which justification (by
    id) is doing the work or failing, and every antecedent/inhibitor by
    name. The console-operator register: precise over readable."""
    concl_id = explanation.get("concl_id", "?");
    status = explanation.get("status", "?");
    if status == "IN" {
        j = _satisfied_justification(explanation);
        if not j {
            return f"{concl_id}: IN (no satisfied justification found -- inconsistent state)";
        }
        parts = [];
        for label in _antecedent_labels(j) {
            parts.append(f"{label} believed");
        }
        for label in _inhibitor_labels(j) {
            parts.append(f"{label} not believed");
        }
        detail = " and ".join(parts) if parts else "trivially";
        return f"{concl_id}: IN via {j.get('justification_id', '?')} ({detail})";
    }
    j = _first_unsatisfied_justification(explanation);
    if not j {
        return f"{concl_id}: OUT (no justification exists)";
    }
    failing = _failing_antecedent_labels(j) + [
        f"{label} now believed" for label in _failing_inhibitor_labels(j)
    ];
    detail = " and ".join(failing) if failing else "unknown reason";
    n_other = len(explanation.get("justifications", [])) - 1;
    extra = f"; {n_other} other justification(s) also unsatisfied" if n_other > 0 else "";
    return f"{concl_id}: OUT via {j.get('justification_id', '?')} failing ({detail}){extra}";
}


# ---------------------------------------------------------------------------
# Command register -- two clauses max, no justification ids, no internal
# vocabulary ("antecedent", "inhibitor"), suitable for a shift-change
# verbal brief rather than a console readout.
# ---------------------------------------------------------------------------

def command_brief(explanation: dict) -> str {
    """A two-clause plain-language summary: what is currently believed,
    and (if relevant) what changed it. No justification ids, no internal
    JTMS vocabulary -- this is what a watch commander skimming ten of
    these in a row actually wants."""
    concl_id = explanation.get("concl_id", "?");
    label = explanation.get("label", concl_id);
    status = explanation.get("status", "?");
    if status == "IN" {
        j = _satisfied_justification(explanation);
        support_labels = _antecedent_labels(j);
        if support_labels {
            basis = support_labels[0] if len(support_labels) == 1 else f"{len(support_labels)} corroborating signals";
            return f"{label}: currently holds, supported by {basis}.";
        }
        return f"{label}: currently holds.";
    }
    j = _first_unsatisfied_justification(explanation);
    failing_inhibitors = _failing_inhibitor_labels(j);
    if failing_inhibitors {
        return f"{label}: does not hold -- contradicted by {failing_inhibitors[0]}.";
    }
    failing_antecedents = _failing_antecedent_labels(j);
    if failing_antecedents {
        return f"{label}: does not hold -- {failing_antecedents[0]} is no longer supported.";
    }
    return f"{label}: does not hold.";
}


# ---------------------------------------------------------------------------
# Public register -- no track/vessel identifiers, no internal ids, present
# tense, suitable for a redacted incident summary. Deliberately the
# vaguest register: it is meant to be safe to show outside the operations
# room, not to be informative to an analyst.
# ---------------------------------------------------------------------------

def public_brief(explanation: dict) -> str {
    """A maximally generic status sentence with no identifiers at all --
    suitable for a public-facing incident log where naming a specific
    vessel/track would itself be the sensitive detail."""
    status = explanation.get("status", "?");
    if status == "IN" {
        return "An identity assessment in this incident remains confirmed.";
    }
    return "An identity assessment in this incident has been revised.";
}


# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

def brief_in_register(explanation: dict, register: str) -> str {
    """Render `explanation` in the requested register; raises ValueError
    on an unknown register rather than silently falling back to one,
    matching jac/jtms.jac's "raise, don't guess" discipline for unknown
    ids elsewhere in this codebase's Jac modules."""
    if register == REGISTER_OPERATOR {
        return operator_brief(explanation);
    }
    if register == REGISTER_COMMAND {
        return command_brief(explanation);
    }
    if register == REGISTER_PUBLIC {
        return public_brief(explanation);
    }
    raise ValueError(f"unknown register: {register}");
}


def brief_all_registers(explanation: dict) -> dict {
    """Every register's rendering of the same explanation, keyed by
    register name -- convenient for a side-by-side comparison view."""
    return {r: brief_in_register(explanation, r) for r in ALL_REGISTERS};
}


# ---------------------------------------------------------------------------
# Batch rendering -- multiple conclusions, one register, one panel payload
# shape roughly mirroring jac/brief.jac's panel_payload() (but without any
# LLM call anywhere in this file -- every one of these functions is a pure
# template, not a `by llm()` ability).
# ---------------------------------------------------------------------------

def panel_payload_in_register(explanations: list, register: str) -> list {
    """One dict per explanation, in the given register -- the deterministic
    analogue of jac/brief.jac's panel_payload(), useful as a fallback panel
    if an LLM-polish layer were ever disabled entirely rather than merely
    skipped per-call (jac/brief.jac's `use_llm=False` path already covers
    the per-call case; this module's contribution is the audience-register
    axis, which jac/brief.jac does not have at all)."""
    out = [];
    for explanation in explanations {
        out.append({
            "concl_id": explanation.get("concl_id", "?"),
            "register": register,
            "text": brief_in_register(explanation, register),
            "status": explanation.get("status", "?"),
        });
    }
    return out;
}


def panel_payload_all_registers(explanations: list) -> dict {
    """panel_payload_in_register() for every register, keyed by register
    name -- the full three-register comparison a UI toggle between
    "operator/command/public" views would want to render from without
    three separate calls."""
    return {r: panel_payload_in_register(explanations, r) for r in ALL_REGISTERS};
}


# ---------------------------------------------------------------------------
# Self-check fixtures -- deterministic explain()-shaped dicts covering an
# IN conclusion via one satisfied justification, and an OUT conclusion via
# an inhibitor becoming believed (mirroring jac/jtms.jac's mmsi-spoof
# fixture, without importing that module).
# ---------------------------------------------------------------------------

def _synthetic_in_explanation() -> dict {
    return {
        "concl_id": "vessel_a_confirmed",
        "label": "vessel A's identity is confirmed",
        "status": "IN",
        "justifications": [
            {
                "justification_id": "j_a1",
                "satisfied": True,
                "antecedents": [
                    {"id": "broadcast_a", "label": "vessel A's MMSI broadcast",
                     "in_or_believed": True, "satisfied": True},
                ],
                "inhibitors": [],
            },
        ],
    };
}


def _synthetic_out_explanation() -> dict {
    return {
        "concl_id": "vessel_b_confirmed",
        "label": "vessel B's identity is confirmed",
        "status": "OUT",
        "justifications": [
            {
                "justification_id": "j_b1",
                "satisfied": False,
                "antecedents": [
                    {"id": "broadcast_b", "label": "vessel B's MMSI broadcast",
                     "in_or_believed": True, "satisfied": True},
                ],
                "inhibitors": [
                    {"id": "spoof_detected", "label": "an MMSI spoof is in progress",
                     "in_or_believed": True, "satisfied": False},
                ],
            },
        ],
    };
}


def self_check_report() -> str {
    """Deterministic hand-inspection report -- not wired to pytest/jac
    test, matching this repo's other standalone modules' self-check
    discipline (see jac/classifier.jac, jac/replay_control.jac)."""
    in_expl = _synthetic_in_explanation();
    out_expl = _synthetic_out_explanation();

    lines = ["=== brief_templates.jac self-check ==="];
    lines.append("-- IN conclusion, all three registers --");
    for (register, text) in brief_all_registers(in_expl).items() {
        lines.append(f"  [{register}] {text}");
    }
    lines.append("-- OUT conclusion, all three registers --");
    for (register, text) in brief_all_registers(out_expl).items() {
        lines.append(f"  [{register}] {text}");
    }

    payload = panel_payload_all_registers([in_expl, out_expl]);
    lines.append(f"-- panel_payload_all_registers keys: {sorted(payload.keys())} --");
    lines.append(f"-- operator register payload rows: {len(payload[REGISTER_OPERATOR])} --");
    return "\n".join(lines);
}


with entry:__main__ {
    print(self_check_report());
}


# ---------------------------------------------------------------------------
# Localization scaffolding -- a further standalone extension: wrapping each
# register's fixed English phrases behind a lookup table, so a future
# translation layer would only need to populate PHRASE_TABLE for a new
# locale rather than touch any of the render functions above. No locale
# besides "en" is populated; this is scaffolding, not a translation effort.
# ---------------------------------------------------------------------------

glob DEFAULT_LOCALE: str = "en";

glob PHRASE_TABLE: dict = {
    "en": {
        "currently_holds": "currently holds",
        "currently_holds_supported_by": "currently holds, supported by",
        "does_not_hold": "does not hold",
        "does_not_hold_contradicted_by": "does not hold -- contradicted by",
        "does_not_hold_unsupported": "does not hold -- {antecedent} is no longer supported",
        "public_in": "An identity assessment in this incident remains confirmed.",
        "public_out": "An identity assessment in this incident has been revised.",
        "corroborating_signals": "{n} corroborating signals",
    },
};


def phrase(key: str, locale: str = DEFAULT_LOCALE, **kwargs: dict) -> str {
    """Look up `key` in PHRASE_TABLE for `locale`, falling back to
    DEFAULT_LOCALE if the requested locale has no table at all (never to a
    different key within the same locale -- a missing key is a bug to
    surface, not paper over). Applies **kwargs as .format() substitutions
    if the phrase contains any {placeholder} markers."""
    table = PHRASE_TABLE.get(locale, PHRASE_TABLE[DEFAULT_LOCALE]);
    raw = table.get(key, f"<<missing phrase: {key}>>");
    if kwargs {
        return raw.format(**kwargs);
    }
    return raw;
}


def command_brief_localized(explanation: dict, locale: str = DEFAULT_LOCALE) -> str {
    """Locale-aware counterpart to command_brief() -- same logic, but every
    fixed English phrase is routed through phrase() instead of being
    hardcoded inline, so a future locale only needs a new PHRASE_TABLE
    entry, no changes to this function."""
    concl_id = explanation.get("concl_id", "?");
    label = explanation.get("label", concl_id);
    status = explanation.get("status", "?");
    if status == "IN" {
        j = _satisfied_justification(explanation);
        support_labels = _antecedent_labels(j);
        if support_labels {
            if len(support_labels) == 1 {
                basis = support_labels[0];
            } else {
                basis = phrase("corroborating_signals", locale=locale, n=len(support_labels));
            }
            verb = phrase("currently_holds_supported_by", locale=locale);
            return f"{label}: {verb} {basis}.";
        }
        return f"{label}: {phrase('currently_holds', locale=locale)}.";
    }
    j = _first_unsatisfied_justification(explanation);
    failing_inhibitors = _failing_inhibitor_labels(j);
    if failing_inhibitors {
        verb = phrase("does_not_hold_contradicted_by", locale=locale);
        return f"{label}: {verb} {failing_inhibitors[0]}.";
    }
    failing_antecedents = _failing_antecedent_labels(j);
    if failing_antecedents {
        return f"{label}: " + phrase(
            "does_not_hold_unsupported", locale=locale, antecedent=failing_antecedents[0]
        ) + ".";
    }
    return f"{label}: {phrase('does_not_hold', locale=locale)}.";
}


def public_brief_localized(explanation: dict, locale: str = DEFAULT_LOCALE) -> str {
    status = explanation.get("status", "?");
    if status == "IN" {
        return phrase("public_in", locale=locale);
    }
    return phrase("public_out", locale=locale);
}


def known_locales() -> list {
    return sorted(PHRASE_TABLE.keys());
}


def register_locale(locale: str, phrases: dict) -> None {
    """Add or replace a locale's phrase table -- raises ValueError if
    `phrases` is missing any key the "en" table defines, so a partially
    translated locale fails loudly at registration time rather than
    producing "<<missing phrase>>" strings in production output."""
    required = set(PHRASE_TABLE[DEFAULT_LOCALE].keys());
    provided = set(phrases.keys());
    missing = required - provided;
    if missing {
        raise ValueError(f"locale '{locale}' missing phrases: {sorted(missing)}");
    }
    PHRASE_TABLE[locale] = dict(phrases);
}


# ---------------------------------------------------------------------------
# Extended self-check covering localization scaffolding
# ---------------------------------------------------------------------------

def localization_self_check_report() -> str {
    """Hand-inspection report for the localization layer -- registers a
    trivial "en-GB" locale (identical phrases, since no real translation
    exists) purely to exercise register_locale()'s validation path, then
    renders both locales side by side."""
    in_expl = _synthetic_in_explanation();
    out_expl = _synthetic_out_explanation();

    lines = ["=== brief_templates.jac localization self-check ==="];
    lines.append(f"known locales before registration: {known_locales()}");

    register_locale("en-GB", dict(PHRASE_TABLE[DEFAULT_LOCALE]));
    lines.append(f"known locales after registering en-GB: {known_locales()}");

    for locale in known_locales() {
        lines.append(f"-- locale={locale} --");
        lines.append(f"  IN:  {command_brief_localized(in_expl, locale=locale)}");
        lines.append(f"  OUT: {command_brief_localized(out_expl, locale=locale)}");
        lines.append(f"  public IN:  {public_brief_localized(in_expl, locale=locale)}");
        lines.append(f"  public OUT: {public_brief_localized(out_expl, locale=locale)}");
    }
    return "\n".join(lines);
}


# ---------------------------------------------------------------------------
# Redaction layer -- a further standalone extension: given a rendered
# brief string and a set of terms considered sensitive in the current
# context (e.g. a vessel's real name before attribution is confirmed),
# produce a redacted variant. Operates purely on strings, independent of
# the register/locale machinery above, so it can wrap any of this module's
# render functions (or, in principle, jac/jtms.jac's own brief_for()
# output, though this file never imports that module directly).
# ---------------------------------------------------------------------------

glob REDACTION_PLACEHOLDER: str = "[REDACTED]";


def redact_terms(text: str, sensitive_terms: list) -> str {
    """Replace every case-sensitive exact occurrence of each term in
    `sensitive_terms` with REDACTION_PLACEHOLDER. Longer terms are applied
    first so that a shorter term nested inside a longer one (e.g. "Vessel
    A" inside "Vessel A Confirmed") does not get partially redacted in a
    way that leaves the longer phrase readable."""
    ordered = sorted(sensitive_terms, key=lambda t: object: -len(t));
    result = text;
    for term in ordered {
        if term {
            result = result.replace(term, REDACTION_PLACEHOLDER);
        }
    }
    return result;
}


def redact_brief(explanation: dict, register: str, sensitive_terms: list) -> str {
    """brief_in_register() followed by redact_terms() -- the composed
    operation a caller preparing a partially-declassified brief would
    actually want in one call."""
    rendered = brief_in_register(explanation, register);
    return redact_terms(rendered, sensitive_terms);
}


def sensitive_terms_from_explanation(explanation: dict) -> list {
    """Every antecedent/inhibitor label mentioned anywhere in an
    explain()-shaped dict -- a reasonable default "redact all the specific
    evidence names" term list, though a caller may want to pass a curated
    subset instead (e.g. only vessel names, not zone names)."""
    terms = set();
    for j in explanation.get("justifications", []) {
        for a in j.get("antecedents", []) {
            label = a.get("label", "");
            if label {
                terms.add(label);
            }
        }
        for i in j.get("inhibitors", []) {
            label = i.get("label", "");
            if label {
                terms.add(label);
            }
        }
    }
    return sorted(terms);
}


def fully_redacted_brief(explanation: dict, register: str) -> str {
    """Convenience wrapper: redact every evidence-name term this
    explanation mentions, using sensitive_terms_from_explanation() as the
    term list -- the "maximum redaction" case, as opposed to
    redact_brief()'s caller-supplied term list."""
    terms = sensitive_terms_from_explanation(explanation);
    return redact_brief(explanation, register, terms);
}


# ---------------------------------------------------------------------------
# Redaction self-check
# ---------------------------------------------------------------------------

def redaction_self_check_report() -> str {
    """Hand-inspection report for the redaction layer, covering both a
    caller-supplied term list and the automatic
    sensitive_terms_from_explanation() path."""
    in_expl = _synthetic_in_explanation();
    out_expl = _synthetic_out_explanation();

    lines = ["=== brief_templates.jac redaction self-check ==="];
    lines.append("-- operator register, unredacted --");
    lines.append(f"  IN:  {operator_brief(in_expl)}");
    lines.append(f"  OUT: {operator_brief(out_expl)}");

    lines.append("-- operator register, fully redacted --");
    lines.append(f"  IN:  {fully_redacted_brief(in_expl, REGISTER_OPERATOR)}");
    lines.append(f"  OUT: {fully_redacted_brief(out_expl, REGISTER_OPERATOR)}");

    lines.append("-- command register, custom term list --");
    custom_terms = ["vessel A's MMSI broadcast"];
    lines.append(f"  IN:  {redact_brief(in_expl, REGISTER_COMMAND, custom_terms)}");

    return "\n".join(lines);
}


# ---------------------------------------------------------------------------
# Full self-check -- runs every self-check function this module defines,
# in one call, so a single `jac run` invocation exercises everything.
# ---------------------------------------------------------------------------

def full_self_check_report() -> str {
    return "\n\n".join([
        self_check_report(),
        localization_self_check_report(),
        redaction_self_check_report(),
    ]);
}


# ---------------------------------------------------------------------------
# Batch redaction across a panel -- applies fully_redacted_brief() to every
# row a panel_payload_in_register() call would produce, for a "declassify
# this whole panel" operation in one call.
# ---------------------------------------------------------------------------

def redacted_panel_payload(explanations: list, register: str) -> list {
    out = [];
    for explanation in explanations {
        out.append({
            "concl_id": explanation.get("concl_id", "?"),
            "register": register,
            "text": fully_redacted_brief(explanation, register),
            "status": explanation.get("status", "?"),
        });
    }
    return out;
}


def redaction_coverage_fraction(original: str, redacted: str) -> float {
    """Rough fraction of `original`'s character count that ended up inside
    a REDACTION_PLACEHOLDER span in `redacted` -- a cheap sanity metric for
    "did this redaction actually remove a meaningful amount of text", not a
    precise character-alignment diff."""
    if not original {
        return 0.0;
    }
    n_placeholders = redacted.count(REDACTION_PLACEHOLDER);
    removed_chars_estimate = n_placeholders * (len(REDACTION_PLACEHOLDER) + 8);
    return min(1.0, removed_chars_estimate / max(1, len(original)));
}
