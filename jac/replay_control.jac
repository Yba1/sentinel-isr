"""Standalone playback-control heuristics -- currently unwired, not
imported by web/server.py, jac/main.jac, or any test. Parallel exploration
of adaptive replay pacing on top of the frame stream jac/main.jac already
produces, independent of the actual player_loop in web/server.py (which
stays untouched: fixed-interval sleep keyed off state["speed"]).

WHAT THIS IS FOR
-----------------
web/server.py's player_loop() advances one frame every
`frame_interval_s / speed` seconds, uniformly, regardless of what is
happening in that frame -- a quiet stretch of open water plays back at the
same pace as the moment a dark vessel gets re-acquired. This module is a
standalone exploration of the alternative: pacing that slows down around
narratively significant moments (a fresh alert, a track going dark, a
re-association) and speeds through quiet stretches, without ever exceeding
an operator-chosen ceiling multiplier. None of it is wired into the live
player loop; it operates on a caller-supplied list of per-frame summaries,
not the live Mission graph or the real WebSocket broadcast loop.

DESIGN
-------
Every function here is a pure function of frame summaries (plain dicts:
{"frame_idx", "t", "n_alerts", "n_dark", "id_switches_delta"}) and a
handful of tunables, so it could in principle be called once per
precomputed pack (like web/server.py's precompute()) to annotate each
frame with a suggested playback multiplier -- but nothing currently calls
it, by design (see the module docstring above).
"""

import math;

# ---------------------------------------------------------------------------
# Tunables
# ---------------------------------------------------------------------------

glob BASE_SPEED: float = 10.0;
glob MIN_SPEED: float = 1.0;
glob MAX_SPEED: float = 60.0;

glob ALERT_SLOWDOWN_FACTOR: float = 0.35;   # multiply speed by this when an alert fires
glob DARK_SLOWDOWN_FACTOR: float = 0.5;     # multiply speed while any track is dark
glob SWITCH_SLOWDOWN_FACTOR: float = 0.2;   # multiply speed on an id-switch frame

glob QUIET_SPEEDUP_FACTOR: float = 1.6;     # multiply speed during long quiet stretches
glob QUIET_STREAK_MIN_FRAMES: int = 20;     # frames of "nothing happening" before speeding up

glob RAMP_FRAMES: int = 6;   # frames over which a speed change interpolates, not snaps

# ---------------------------------------------------------------------------
# Per-frame significance scoring
# ---------------------------------------------------------------------------

def is_quiet_frame(summary: dict) -> bool {
    """A frame with no alerts, no dark tracks, and no id-switch this tick --
    the kind of frame that is safe to blast through at speed."""
    return (
        summary.get("n_alerts", 0) == 0
        and summary.get("n_dark", 0) == 0
        and summary.get("id_switches_delta", 0) == 0
    );
}


def frame_target_speed(summary: dict, quiet_streak: int, base_speed: float = BASE_SPEED) -> float {
    """The playback speed this single frame "wants", ignoring ramping --
    the slowest applicable slowdown wins (multiple simultaneous factors do
    not compound multiplicatively, which would make a busy frame crawl to
    a near-stop; the single worst factor is enough to signal "slow down
    here")."""
    factors = [1.0];
    if summary.get("id_switches_delta", 0) > 0 {
        factors.append(SWITCH_SLOWDOWN_FACTOR);
    }
    if summary.get("n_alerts", 0) > 0 {
        factors.append(ALERT_SLOWDOWN_FACTOR);
    }
    if summary.get("n_dark", 0) > 0 {
        factors.append(DARK_SLOWDOWN_FACTOR);
    }
    worst = min(factors);
    if worst < 1.0 {
        return max(MIN_SPEED, base_speed * worst);
    }
    if quiet_streak >= QUIET_STREAK_MIN_FRAMES {
        return min(MAX_SPEED, base_speed * QUIET_SPEEDUP_FACTOR);
    }
    return base_speed;
}


# ---------------------------------------------------------------------------
# Whole-run annotation
# ---------------------------------------------------------------------------

def annotate_speeds(summaries: list, base_speed: float = BASE_SPEED) -> list {
    """Every frame's raw target speed (no ramping yet) -- one float per
    input summary, same order, same length."""
    out = [];
    quiet_streak = 0;
    for summary in summaries {
        target = frame_target_speed(summary, quiet_streak, base_speed=base_speed);
        out.append(target);
        if is_quiet_frame(summary) {
            quiet_streak += 1;
        } else {
            quiet_streak = 0;
        }
    }
    return out;
}


def _ramp(current: float, target: float, frames_left: int) -> float {
    """One linear interpolation step toward `target`, `frames_left` steps
    remaining -- avoids a jarring instantaneous jump in playback speed the
    moment a slowdown/speedup condition first fires."""
    if frames_left <= 0 {
        return target;
    }
    return current + (target - current) / frames_left;
}


def ramp_speeds(raw_speeds: list, ramp_frames: int = RAMP_FRAMES) -> list {
    """Smooths annotate_speeds()'s raw per-frame targets so speed changes
    take `ramp_frames` frames to fully take effect, rather than snapping
    instantly -- the same reasoning a camera operator would apply to a
    zoom, not a hard cut."""
    if not raw_speeds {
        return [];
    }
    smoothed = [raw_speeds[0]];
    current = raw_speeds[0];
    for i in range(1, len(raw_speeds)) {
        target = raw_speeds[i];
        current = _ramp(current, target, ramp_frames);
        smoothed.append(current);
    }
    return smoothed;
}


def annotate_and_ramp(summaries: list, base_speed: float = BASE_SPEED,
                       ramp_frames: int = RAMP_FRAMES) -> list {
    """Convenience wrapper: annotate_speeds() then ramp_speeds() in one
    call, since every caller of this module wants both stages together."""
    raw = annotate_speeds(summaries, base_speed=base_speed);
    return ramp_speeds(raw, ramp_frames=ramp_frames);
}


# ---------------------------------------------------------------------------
# Bookmark extraction -- "where would a highlight reel cut to"
# ---------------------------------------------------------------------------

def bookmark_frames(summaries: list) -> list {
    """Frame indices where something narratively significant first started
    (an alert, a track going dark, or an id-switch) -- the transition
    point, not every frame the condition holds. Deduplicated: a run of ten
    consecutive alert frames yields one bookmark, at the first frame of
    that run."""
    marks = [];
    was_significant = False;
    for summary in summaries {
        significant = not is_quiet_frame(summary);
        if significant and not was_significant {
            marks.append(summary.get("frame_idx", len(marks)));
        }
        was_significant = significant;
    }
    return marks;
}


def bookmark_labels(summaries: list) -> list {
    """Human-readable label per bookmark_frames() entry -- what kind of
    event triggered this bookmark, for a scrubber-bar tick label a future
    UI could render (not currently wired to web/dashboard.js's scrubber,
    which has no bookmark ticks at all)."""
    idx_by_frame = {s.get("frame_idx", i): s for (i, s) in enumerate(summaries)};
    labels = [];
    for frame_idx in bookmark_frames(summaries) {
        s = idx_by_frame.get(frame_idx, {});
        if s.get("id_switches_delta", 0) > 0 {
            labels.append((frame_idx, "id switch"));
        } elif s.get("n_alerts", 0) > 0 {
            labels.append((frame_idx, "alert"));
        } elif s.get("n_dark", 0) > 0 {
            labels.append((frame_idx, "track dark"));
        } else {
            labels.append((frame_idx, "event"));
        }
    }
    return labels;
}


# ---------------------------------------------------------------------------
# Highlight-reel window selection
# ---------------------------------------------------------------------------

def highlight_windows(summaries: list, pad_frames: int = 4) -> list {
    """(start_idx, end_idx) windows around every non-quiet stretch, padded
    by `pad_frames` on each side and merged where they overlap -- a
    plausible "auto-generate a highlight reel" building block for a demo
    reel feature that does not exist anywhere else in this repo."""
    n = len(summaries);
    if n == 0 {
        return [];
    }
    raw_windows = [];
    i = 0;
    while i < n {
        if not is_quiet_frame(summaries[i]) {
            j = i;
            while j < n and not is_quiet_frame(summaries[j]) {
                j += 1;
            }
            start = max(0, i - pad_frames);
            end = min(n - 1, j - 1 + pad_frames);
            raw_windows.append((start, end));
            i = j;
        } else {
            i += 1;
        }
    }
    if not raw_windows {
        return [];
    }
    merged = [raw_windows[0]];
    for (start, end) in raw_windows[1:] {
        (last_start, last_end) = merged[-1];
        if start <= last_end + 1 {
            merged[-1] = (last_start, max(last_end, end));
        } else {
            merged.append((start, end));
        }
    }
    return merged;
}


def highlight_reel_frame_count(summaries: list, pad_frames: int = 4) -> int {
    """Total frame count a highlight reel built from highlight_windows()
    would contain -- a cheap "is this worth building" sanity check before
    any real reel-assembly logic exists."""
    total = 0;
    for (start, end) in highlight_windows(summaries, pad_frames=pad_frames) {
        total += end - start + 1;
    }
    return total;
}


# ---------------------------------------------------------------------------
# Self-check fixture
# ---------------------------------------------------------------------------

def _synthetic_summaries(n: int = 60) -> list {
    """A run that is quiet, then busy (alert + dark track), then quiet
    again, then a single id-switch frame, then quiet -- exercises every
    branch in frame_target_speed()/is_quiet_frame() at least once."""
    out = [];
    for i in range(n) {
        n_alerts = 0;
        n_dark = 0;
        id_switches_delta = 0;
        if 20 <= i < 30 {
            n_alerts = 1;
            n_dark = 1;
        }
        if i == 45 {
            id_switches_delta = 1;
        }
        out.append({
            "frame_idx": i,
            "t": i * 30.0,
            "n_alerts": n_alerts,
            "n_dark": n_dark,
            "id_switches_delta": id_switches_delta,
        });
    }
    return out;
}


def self_check_report() -> str {
    """Deterministic hand-inspection report -- not wired to pytest/jac
    test, matching jac/classifier.jac's self_check_report() discipline."""
    summaries = _synthetic_summaries();
    ramped = annotate_and_ramp(summaries);
    marks = bookmark_labels(summaries);
    windows = highlight_windows(summaries);
    reel_frames = highlight_reel_frame_count(summaries);

    lines = ["=== replay_control.jac self-check ==="];
    lines.append(f"frame count: {len(summaries)}");
    lines.append(f"speed at busy frame 25 (expect < base): {ramped[25]:.2f}");
    lines.append(f"speed at quiet frame 5 (expect == base): {ramped[5]:.2f}");
    lines.append(f"speed at long-quiet frame 59 (expect > base, sped up): {ramped[59]:.2f}");
    lines.append(f"bookmarks: {marks}");
    lines.append(f"highlight windows: {windows}");
    lines.append(f"highlight reel frame count: {reel_frames} / {len(summaries)}");
    return "\n".join(lines);
}


with entry:__main__ {
    print(self_check_report());
}


# ---------------------------------------------------------------------------
# Multi-run comparison -- "which of these precomputed packs would benefit
# most from adaptive pacing" exploration. Still standalone: takes a dict of
# {pack_id: summaries} and returns comparative statistics, never touches
# web/server.py's actual cache dict shape.
# ---------------------------------------------------------------------------

def quiet_fraction(summaries: list) -> float {
    """Fraction of frames that are quiet by is_quiet_frame()'s definition --
    0.0 if there are no frames at all, to avoid a divide-by-zero rather than
    raising on an empty pack."""
    if not summaries {
        return 0.0;
    }
    quiet = sum(1 for s in summaries if is_quiet_frame(s));
    return quiet / len(summaries);
}


def busiest_stretch(summaries: list) -> tuple {
    """The single longest unbroken run of non-quiet frames, as
    (start_idx, length) -- (0, 0) if the pack never has a non-quiet frame
    at all."""
    best_start = 0;
    best_len = 0;
    cur_start = None;
    cur_len = 0;
    for (i, s) in enumerate(summaries) {
        if not is_quiet_frame(s) {
            if cur_start is None {
                cur_start = i;
                cur_len = 1;
            } else {
                cur_len += 1;
            }
            if cur_len > best_len {
                best_len = cur_len;
                best_start = cur_start;
            }
        } else {
            cur_start = None;
            cur_len = 0;
        }
    }
    return (best_start, best_len);
}


def pacing_benefit_score(summaries: list) -> float {
    """A rough single-number "how much would adaptive pacing help this
    pack" score: high quiet fraction with a short busiest stretch means a
    fixed-speed playback wastes a lot of viewer time on nothing; a pack
    that is busy almost everywhere gets little benefit from speeding up
    quiet stretches, because there mostly aren't any. Not a calibrated
    metric -- a comparative one, useful only relative to other packs run
    through the same function."""
    if not summaries {
        return 0.0;
    }
    qf = quiet_fraction(summaries);
    (_start, busiest_len) = busiest_stretch(summaries);
    busy_fraction = busiest_len / len(summaries);
    return qf * (1.0 - busy_fraction);
}


def compare_packs(pack_summaries: dict) -> list {
    """One row per pack_id: quiet_fraction, busiest_stretch, and
    pacing_benefit_score, sorted by benefit score descending -- "which pack
    would look best with adaptive pacing turned on" ranking for a future
    demo-prep tool that does not otherwise exist in this repo."""
    rows = [];
    for (pack_id, summaries) in pack_summaries.items() {
        (start, length) = busiest_stretch(summaries);
        rows.append({
            "pack_id": pack_id,
            "n_frames": len(summaries),
            "quiet_fraction": quiet_fraction(summaries),
            "busiest_stretch_start": start,
            "busiest_stretch_len": length,
            "pacing_benefit_score": pacing_benefit_score(summaries),
        });
    }
    rows.sort(key=lambda r: object: -r["pacing_benefit_score"]);
    return rows;
}


def compare_packs_report(rows: list) -> str {
    """Human-readable rendering of compare_packs()'s output, one line per
    pack, ranked."""
    lines = ["=== pacing benefit ranking ==="];
    for (rank, row) in enumerate(rows) {
        lines.append(
            f"{rank + 1}. {row['pack_id']}: benefit={row['pacing_benefit_score']:.3f} "
            f"(quiet={row['quiet_fraction']:.2f}, busiest run={row['busiest_stretch_len']}/"
            f"{row['n_frames']} frames starting at {row['busiest_stretch_start']})"
        );
    }
    if len(lines) == 1 {
        lines.append("(no packs supplied)");
    }
    return "\n".join(lines);
}


# ---------------------------------------------------------------------------
# Operator override -- a manual "pin the speed here" escape hatch layered
# on top of the automatic pacing, for the case where a presenter wants to
# linger on a specific frame range regardless of what the heuristics say.
# ---------------------------------------------------------------------------

def apply_pin_overrides(ramped_speeds: list, pins: list) -> list {
    """`pins` is a list of (start_idx, end_idx, speed) tuples; within each
    range (inclusive), the ramped speed is replaced outright rather than
    blended -- a presenter's explicit choice should not be diluted by the
    automatic heuristics fighting it. Later pins in the list win over
    earlier ones on overlapping ranges, so callers can express "override
    the override" by ordering pins from general to specific."""
    out = list(ramped_speeds);
    for (start, end, speed) in pins {
        lo = max(0, start);
        hi = min(len(out) - 1, end);
        for i in range(lo, hi + 1) {
            out[i] = speed;
        }
    }
    return out;
}


def validate_pins(pins: list, n_frames: int) -> list {
    """Every pin that is out of range or has a non-positive speed, as
    human-readable complaint strings -- callers can decide whether to
    reject the whole pin list or just drop the bad entries; this function
    only reports, it never mutates or raises."""
    problems = [];
    for (i, (start, end, speed)) in enumerate(pins) {
        if start < 0 or end >= n_frames {
            problems.append(f"pin {i}: range ({start}, {end}) outside 0..{n_frames - 1}");
        }
        if start > end {
            problems.append(f"pin {i}: start {start} > end {end}");
        }
        if speed <= 0.0 {
            problems.append(f"pin {i}: non-positive speed {speed}");
        }
    }
    return problems;
}


# ---------------------------------------------------------------------------
# Speed-profile export -- turning the ramped speed list into something a
# future scrubber UI could render as a sparkline underneath the timeline,
# the way many video editors show an audio waveform under the seek bar.
# ---------------------------------------------------------------------------

glob SPARKLINE_BUCKETS: int = 80;   # roughly one per horizontal pixel-column at typical widths


def _bucket_bounds(n_frames: int, n_buckets: int) -> list {
    """n_buckets (start_idx, end_idx) ranges covering 0..n_frames-1 as
    evenly as integer division allows -- the last bucket absorbs any
    remainder so every frame is covered exactly once."""
    if n_buckets <= 0 or n_frames <= 0 {
        return [];
    }
    size = n_frames // n_buckets;
    if size == 0 {
        return [(i, i) for i in range(n_frames)];
    }
    bounds = [];
    start = 0;
    for b in range(n_buckets) {
        end = start + size - 1;
        if b == n_buckets - 1 {
            end = n_frames - 1;
        }
        bounds.append((start, end));
        start = end + 1;
        if start >= n_frames {
            break;
        }
    }
    return bounds;
}


def speed_sparkline(ramped_speeds: list, n_buckets: int = SPARKLINE_BUCKETS) -> list {
    """Downsample a full per-frame speed curve to at most n_buckets mean
    values -- a sparkline-friendly summary, not a lossless representation.
    Empty input yields an empty sparkline rather than raising."""
    if not ramped_speeds {
        return [];
    }
    bounds = _bucket_bounds(len(ramped_speeds), n_buckets);
    out = [];
    for (start, end) in bounds {
        chunk = ramped_speeds[start:end + 1];
        out.append(sum(chunk) / len(chunk));
    }
    return out;
}


def normalize_sparkline(values: list, lo: float = MIN_SPEED, hi: float = MAX_SPEED) -> list {
    """Map a sparkline's raw speed values into 0..1 for direct use as a bar
    height fraction -- clamps rather than raising if a value falls outside
    [lo, hi] (a ramp mid-transition can technically dip slightly outside
    the nominal envelope for one interpolation step)."""
    span = hi - lo;
    if span <= 0.0 {
        return [0.5 for _ in values];
    }
    out = [];
    for v in values {
        frac = (v - lo) / span;
        out.append(max(0.0, min(1.0, frac)));
    }
    return out;
}


def sparkline_ascii(values: list, width_chars: int = 40) -> str {
    """A crude ASCII rendering of a normalized sparkline, purely for a
    terminal self-check -- not meant for a real UI, which would use SVG or
    canvas the way jac/render.jac's ellipse rings are meant for Leaflet,
    not a text console."""
    if not values {
        return "(empty)";
    }
    ramp_chars = " .:-=+*#%@";
    step = max(1, len(values) // width_chars);
    sampled = values[::step][:width_chars];
    chars = [];
    for v in sampled {
        idx = min(len(ramp_chars) - 1, int(v * (len(ramp_chars) - 1)));
        chars.append(ramp_chars[idx]);
    }
    return "".join(chars);
}


# ---------------------------------------------------------------------------
# Whole-pipeline convenience entry point
# ---------------------------------------------------------------------------

def full_pacing_report(summaries: list, base_speed: float = BASE_SPEED) -> str {
    """Everything this module can say about one pack's summaries, in one
    deterministic multi-line report -- annotate/ramp, bookmarks, highlight
    windows, and an ASCII sparkline, so a hand inspection needs only one
    function call."""
    ramped = annotate_and_ramp(summaries, base_speed=base_speed);
    marks = bookmark_labels(summaries);
    windows = highlight_windows(summaries);
    spark = normalize_sparkline(speed_sparkline(ramped));

    lines = ["=== full pacing report ==="];
    lines.append(f"frames: {len(summaries)}  quiet_fraction: {quiet_fraction(summaries):.2f}");
    lines.append(f"bookmarks: {marks}");
    lines.append(f"highlight windows: {windows}");
    lines.append(f"speed sparkline: {sparkline_ascii(spark)}");
    return "\n".join(lines);
}


# ---------------------------------------------------------------------------
# Multi-track dwell accounting -- a further standalone extension: given a
# per-frame count of how many tracks are currently inside each geofence
# zone, compute dwell-time statistics per zone across a whole run. This has
# nothing to do with playback speed directly, but lives in this file
# because it consumes the same per-frame summary shape this module already
# defines, extended with a "zone_occupancy" field the caller may or may not
# populate.
# ---------------------------------------------------------------------------

def zone_dwell_seconds(summaries: list, zone_id: str, frame_interval_s: float) -> float {
    """Total wall-clock time (in the scenario's own frame_interval_s units)
    that at least one track was inside `zone_id`, across every summary
    that carries a "zone_occupancy" dict ({zone_id: count})."""
    occupied_frames = 0;
    for s in summaries {
        occ = s.get("zone_occupancy", {});
        if occ.get(zone_id, 0) > 0 {
            occupied_frames += 1;
        }
    }
    return occupied_frames * frame_interval_s;
}


def zone_max_concurrent(summaries: list, zone_id: str) -> int {
    """Peak simultaneous track count inside `zone_id` across the run --
    0 if the zone never appears in any summary's zone_occupancy."""
    best = 0;
    for s in summaries {
        occ = s.get("zone_occupancy", {});
        best = max(best, occ.get(zone_id, 0));
    }
    return best;
}


def all_zone_ids(summaries: list) -> list {
    """Every zone_id that appears in any summary's zone_occupancy, sorted
    for stable iteration order regardless of dict insertion order."""
    ids = set();
    for s in summaries {
        occ = s.get("zone_occupancy", {});
        for zid in occ.keys() {
            ids.add(zid);
        }
    }
    return sorted(ids);
}


def zone_dwell_report(summaries: list, frame_interval_s: float) -> str {
    """One line per zone: total dwell time and peak concurrent occupancy,
    sorted by dwell time descending -- the busiest zone first."""
    ids = all_zone_ids(summaries);
    rows = [];
    for zid in ids {
        rows.append((
            zid,
            zone_dwell_seconds(summaries, zid, frame_interval_s),
            zone_max_concurrent(summaries, zid),
        ));
    }
    rows.sort(key=lambda r: object: -r[1]);

    lines = ["=== zone dwell report ==="];
    for (zid, dwell_s, peak) in rows {
        lines.append(f"{zid}: dwell={dwell_s:.0f}s, peak concurrent={peak}");
    }
    if not rows {
        lines.append("(no zone occupancy data supplied)");
    }
    return "\n".join(lines);
}


# ---------------------------------------------------------------------------
# Session-length estimation -- "how long would a full unattended playback
# of this pack actually take at the current pacing settings", a number a
# presenter would want before starting a demo cold.
# ---------------------------------------------------------------------------

def estimated_wallclock_seconds(ramped_speeds: list, frame_interval_s: float) -> float {
    """Sum of frame_interval_s / speed across every frame -- the real-world
    seconds a full unattended playback would take at the given per-frame
    speed curve, as opposed to scenario time (frame_interval_s * n_frames),
    which is what the underlying data covers, not what watching it takes."""
    total = 0.0;
    for speed in ramped_speeds {
        if speed <= 0.0 {
            continue;
        }
        total += frame_interval_s / speed;
    }
    return total;
}


def format_duration(seconds: float) -> str {
    """MM:SS (or H:MM:SS for anything over an hour) rendering of a duration
    -- deterministic, no locale dependence, matching the rest of the
    codebase's "no ambiguity in a displayed number" discipline."""
    total_s = int(round(seconds));
    hours = total_s // 3600;
    minutes = (total_s % 3600) // 60;
    secs = total_s % 60;
    if hours > 0 {
        return f"{hours}:{minutes:02d}:{secs:02d}";
    }
    return f"{minutes}:{secs:02d}";
}


def session_length_report(summaries: list, frame_interval_s: float,
                           base_speed: float = BASE_SPEED) -> str {
    """Compares estimated wallclock duration under fixed-speed playback
    against adaptive pacing -- the headline number a presenter deciding
    whether to enable adaptive pacing for a demo would actually want."""
    n = len(summaries);
    fixed_speeds = [base_speed for _ in summaries];
    ramped = annotate_and_ramp(summaries, base_speed=base_speed);

    fixed_s = estimated_wallclock_seconds(fixed_speeds, frame_interval_s);
    adaptive_s = estimated_wallclock_seconds(ramped, frame_interval_s);
    scenario_s = n * frame_interval_s;

    lines = ["=== session length estimate ==="];
    lines.append(f"scenario covers {format_duration(scenario_s)} of scenario time");
    lines.append(f"fixed speed ({base_speed:.0f}x): {format_duration(fixed_s)} wallclock");
    lines.append(f"adaptive pacing: {format_duration(adaptive_s)} wallclock");
    if fixed_s > 0.0 {
        delta_pct = 100.0 * (adaptive_s - fixed_s) / fixed_s;
        sign = "+" if delta_pct >= 0.0 else "";
        lines.append(f"adaptive vs fixed: {sign}{delta_pct:.1f}%");
    }
    return "\n".join(lines);
}


# ---------------------------------------------------------------------------
# Confidence-weighted pacing -- a variant of frame_target_speed() that also
# considers a per-frame "confidence" signal (e.g. a hypothetical MHT weight
# or reassociation likelihood a caller might supply), slowing further when
# confidence is low even if no alert/dark/switch condition is active. Kept
# as a separate function rather than folded into frame_target_speed() so
# that module's simpler contract (works on any summary dict, no optional
# confidence field required) stays unchanged for existing callers of this
# still-entirely-standalone module.
# ---------------------------------------------------------------------------

glob LOW_CONFIDENCE_THRESHOLD: float = 0.4;
glob LOW_CONFIDENCE_SLOWDOWN_FACTOR: float = 0.6;


def frame_target_speed_confidence_aware(
    summary: dict, quiet_streak: int, base_speed: float = BASE_SPEED,
) -> float {
    """frame_target_speed() plus one more factor: if the summary carries a
    "confidence" field below LOW_CONFIDENCE_THRESHOLD, that also counts as
    a slowdown trigger, on the same "worst factor wins" rule as the other
    conditions."""
    base_target = frame_target_speed(summary, quiet_streak, base_speed=base_speed);
    confidence = summary.get("confidence", 1.0);
    if confidence < LOW_CONFIDENCE_THRESHOLD {
        low_conf_target = max(MIN_SPEED, base_speed * LOW_CONFIDENCE_SLOWDOWN_FACTOR);
        return min(base_target, low_conf_target);
    }
    return base_target;
}


def annotate_speeds_confidence_aware(summaries: list, base_speed: float = BASE_SPEED) -> list {
    """Confidence-aware counterpart to annotate_speeds() -- same quiet-streak
    bookkeeping, different per-frame scoring function."""
    out = [];
    quiet_streak = 0;
    for summary in summaries {
        target = frame_target_speed_confidence_aware(summary, quiet_streak, base_speed=base_speed);
        out.append(target);
        if is_quiet_frame(summary) {
            quiet_streak += 1;
        } else {
            quiet_streak = 0;
        }
    }
    return out;
}


def mean_confidence(summaries: list) -> float {
    """Mean of every summary's "confidence" field (defaulting missing
    entries to 1.0, i.e. "fully confident" -- a caller that never supplies
    confidence data should not have every frame silently treated as
    low-confidence). 1.0 for an empty list, since there is nothing to be
    unconfident about."""
    if not summaries {
        return 1.0;
    }
    total = sum(s.get("confidence", 1.0) for s in summaries);
    return total / len(summaries);
}


def low_confidence_stretches(summaries: list) -> list {
    """(start_idx, end_idx) runs where confidence stayed continuously below
    LOW_CONFIDENCE_THRESHOLD -- the confidence-aware analogue of
    highlight_windows(), without the padding (this is meant for a
    diagnostic list, not a video-editing use case)."""
    n = len(summaries);
    windows = [];
    i = 0;
    while i < n {
        conf = summaries[i].get("confidence", 1.0);
        if conf < LOW_CONFIDENCE_THRESHOLD {
            j = i;
            while j < n and summaries[j].get("confidence", 1.0) < LOW_CONFIDENCE_THRESHOLD {
                j += 1;
            }
            windows.append((i, j - 1));
            i = j;
        } else {
            i += 1;
        }
    }
    return windows;
}


def confidence_report(summaries: list) -> str {
    """One-shot human-readable summary of the confidence-aware pacing
    layer: mean confidence, low-confidence stretches, and a side-by-side
    comparison of confidence-aware vs plain adaptive pacing's estimated
    wallclock duration (reusing estimated_wallclock_seconds() from
    earlier in this file, since both speed lists share the same units)."""
    plain = annotate_and_ramp(summaries);
    aware_raw = annotate_speeds_confidence_aware(summaries);
    aware = ramp_speeds(aware_raw);

    lines = ["=== confidence-aware pacing report ==="];
    lines.append(f"mean confidence: {mean_confidence(summaries):.2f}");
    lines.append(f"low-confidence stretches: {low_confidence_stretches(summaries)}");
    lines.append(
        f"plain adaptive final-frame speed: {plain[-1]:.2f}"
        if plain else "plain adaptive final-frame speed: n/a"
    );
    lines.append(
        f"confidence-aware final-frame speed: {aware[-1]:.2f}"
        if aware else "confidence-aware final-frame speed: n/a"
    );
    return "\n".join(lines);
}


# ---------------------------------------------------------------------------
# Combined self-check, covering the confidence-aware and zone-dwell
# extensions added after the original self_check_report() above.
# ---------------------------------------------------------------------------

def _synthetic_summaries_with_confidence(n: int = 40) -> list {
    """Reuses the quiet/busy/switch pattern from _synthetic_summaries()
    (defined earlier in this file) but adds a confidence field that dips
    low from frame 10-15 and a zone_occupancy field that is populated for
    a single made-up zone from frame 5-25."""
    base = _synthetic_summaries(n);
    out = [];
    for s in base {
        s = dict(s);
        i = s["frame_idx"];
        s["confidence"] = 0.2 if 10 <= i < 15 else 0.9;
        s["zone_occupancy"] = {"demo_zone": 2 if 5 <= i < 25 else 0};
        out.append(s);
    }
    return out;
}


def extended_self_check_report() -> str {
    """Hand-inspection report covering the confidence-aware pacing and
    zone-dwell extensions -- separate from self_check_report() (which
    predates these extensions) so neither report grows unwieldy."""
    summaries = _synthetic_summaries_with_confidence();
    lines = [confidence_report(summaries)];
    lines.append("");
    lines.append(zone_dwell_report(summaries, frame_interval_s=30.0));
    lines.append("");
    lines.append(session_length_report(summaries, frame_interval_s=30.0));
    return "\n".join(lines);
}


# ---------------------------------------------------------------------------
# Scenario-comparison export -- a standalone "diff two runs" helper: given
# two packs' summaries (e.g. the same pack under greedy vs global
# association, mirroring jac/fusion.jac's real assoc_mode toggle), report
# where their narrative beats diverge. Purely exploratory; nothing in
# web/server.py or web/dashboard.js calls this.
# ---------------------------------------------------------------------------

def _narrative_signature(summary: dict) -> tuple {
    """A coarse per-frame signature for narrative-alignment comparison:
    whether the frame is quiet, and how many alerts/id-switches it carries.
    Two runs whose signatures diverge at the same frame index are telling
    a meaningfully different story at that point, not just differing in
    exact track positions (which will always differ frame-to-frame between
    two association strategies even when the narrative is the same)."""
    return (
        is_quiet_frame(summary),
        summary.get("n_alerts", 0),
        summary.get("id_switches_delta", 0),
    );
}


def narrative_divergence_frames(summaries_a: list, summaries_b: list) -> list {
    """Frame indices where two runs' narrative signatures differ, up to the
    shorter run's length -- a run that ends early is not itself flagged as
    diverging past that point, since there is nothing to compare against."""
    n = min(len(summaries_a), len(summaries_b));
    diverge = [];
    for i in range(n) {
        sig_a = _narrative_signature(summaries_a[i]);
        sig_b = _narrative_signature(summaries_b[i]);
        if sig_a != sig_b {
            diverge.append(i);
        }
    }
    return diverge;
}


def narrative_agreement_fraction(summaries_a: list, summaries_b: list) -> float {
    """1.0 minus the divergence rate over the compared span -- 1.0 for two
    empty/identical runs, since there is nothing to disagree about."""
    n = min(len(summaries_a), len(summaries_b));
    if n == 0 {
        return 1.0;
    }
    diverge = narrative_divergence_frames(summaries_a, summaries_b);
    return 1.0 - (len(diverge) / n);
}


def comparison_report(label_a: str, summaries_a: list,
                       label_b: str, summaries_b: list) -> str {
    """Human-readable summary of narrative_divergence_frames()'s output --
    agreement fraction plus the first handful of divergence points, so a
    long divergence list does not flood the report."""
    diverge = narrative_divergence_frames(summaries_a, summaries_b);
    agreement = narrative_agreement_fraction(summaries_a, summaries_b);
    shown = diverge[:15];

    lines = [f"=== {label_a} vs {label_b} narrative comparison ==="];
    lines.append(f"compared frames: {min(len(summaries_a), len(summaries_b))}");
    lines.append(f"narrative agreement: {agreement:.1%}");
    lines.append(f"divergence points ({len(diverge)} total, first {len(shown)} shown): {shown}");
    return "\n".join(lines);
}


# ---------------------------------------------------------------------------
# Export helpers -- turning any of this module's report strings into a flat
# JSON-serialisable dict, for a hypothetical future REST endpoint that does
# not exist anywhere in web/server.py today.
# ---------------------------------------------------------------------------

def pacing_summary_dict(summaries: list, frame_interval_s: float,
                         base_speed: float = BASE_SPEED) -> dict {
    """Everything full_pacing_report()/session_length_report() compute,
    as a plain dict rather than a formatted string -- the shape a JSON
    endpoint would actually want to return, as opposed to the
    human-readable report functions elsewhere in this file."""
    ramped = annotate_and_ramp(summaries, base_speed=base_speed);
    marks = bookmark_labels(summaries);
    windows = highlight_windows(summaries);

    fixed_speeds = [base_speed for _ in summaries];
    fixed_s = estimated_wallclock_seconds(fixed_speeds, frame_interval_s);
    adaptive_s = estimated_wallclock_seconds(ramped, frame_interval_s);

    return {
        "n_frames": len(summaries),
        "quiet_fraction": quiet_fraction(summaries),
        "bookmarks": marks,
        "highlight_windows": windows,
        "fixed_wallclock_s": fixed_s,
        "adaptive_wallclock_s": adaptive_s,
        "sparkline": normalize_sparkline(speed_sparkline(ramped)),
    };
}


def multi_pack_pacing_summary(pack_summaries: dict, frame_interval_s: float,
                               base_speed: float = BASE_SPEED) -> dict {
    """pacing_summary_dict() for every pack in `pack_summaries`, keyed the
    same way -- the batch form a future "compare all my precomputed packs"
    endpoint would call once at startup rather than per-request."""
    out = {};
    for (pack_id, summaries) in pack_summaries.items() {
        out[pack_id] = pacing_summary_dict(summaries, frame_interval_s, base_speed=base_speed);
    }
    return out;
}
