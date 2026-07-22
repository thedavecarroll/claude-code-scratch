#!/usr/bin/env python3
"""Agency Unlimited — Combat Simulator.

A command-line bench for the Agency Unlimited resolution engine. Its primary
job is to expose the raw Effect result distribution across many throws so that
Trauma band boundaries can be set against real frequencies rather than by even
division. All scenarios are firearms at range.

Modes
    (default)        Interactive: configure, throw, assign, resolve.
    --distribution N Run the configured throw N times, print the distribution.
    --sweep          Run distribution across a matrix of configurations.

Python 3, standard library only.
"""

import argparse
import copy
import json
import math
import random
import sys
from collections import Counter


# ============================================================================
# --- TUNING CONSTANTS — NOT FINAL ---
#
# This block is the single source of truth for every tunable value. Nothing
# below hardcodes these numbers; all resolution reads from TUNING. Override any
# value from the command line (--set NAME=VALUE) or a config file (--config).
# ============================================================================

TUNING = {
    "COMPETENCY_TIERS": {
        "untrained_discipline": None,   # no attempt permitted
        "untrained_method":       -2,
        "untrained_practice":     -1,
        "proficient":              0,
        "untrained_talent":        0,
        "expert":                 +1,
        "master":                 +2,
    },

    "ACTION_EDGE_VALUE": 1,

    # Timing Edge is under test at +2. Change and re-run to compare.
    "TIMING_EDGE_VALUE": 2,

    "TN_LADDER": [5, 7, 9, 11, 13, 15, 17, 19, 21],

    # Range bands. TN per band is PLACEHOLDER — the ranged TN
    # construction is not settled.
    "RANGE_BANDS": {
        "contact":  5,
        "close":    7,
        "mid":     11,
        "far":     15,
    },

    # Weapon envelope: TN penalty per band outside the weapon's
    # effective range. PLACEHOLDER.
    "OUT_OF_ENVELOPE_PENALTY": 2,

    # Firearm Base Ranks. Handgun and rifle are recorded anchors.
    "WEAPONS": {
        "handgun":  {"base": 3, "envelope": ["contact", "close", "mid"]},
        "rifle":    {"base": 4, "envelope": ["close", "mid", "far"]},
        "smg":      {"base": 3, "envelope": ["contact", "close", "mid"]},
        "shotgun":  {"base": 4, "envelope": ["contact", "close"]},
    },

    # Armor steps the resulting Trauma rank down by this much.
    "ARMOR_RANK_STEP": 1,

    # Armor-piercing negates armor. If AP_NEGATES_FULLY is False,
    # AP reduces the armor step by AP_REDUCTION instead.
    "AP_NEGATES_FULLY": True,
    "AP_REDUCTION":     1,

    # Trauma bands: lower bound of each rank, ascending.
    # PLACEHOLDER — even division. Replacing these is the whole
    # point of this tool.
    "TRAUMA_BANDS": [
        (0,  "Graze"),
        (8,  "Wound"),
        (14, "Serious"),
        (20, "Critical"),
        (26, "Lethal"),
    ],
}

# Structural ordering of the range bands, nearest to farthest. Envelope
# distance is measured along this axis.
RANGE_ORDER = ["contact", "close", "mid", "far"]

DIE_SIDES = 12


# ============================================================================
# Constant overrides (command line / config file)
# ============================================================================

def load_config_file(path):
    """Merge a JSON config file into TUNING. Keys mirror TUNING names."""
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
    for key, value in data.items():
        if key not in TUNING:
            fail("Unknown config key: %r. Valid keys: %s"
                 % (key, ", ".join(sorted(TUNING))))
        if key == "TRAUMA_BANDS":
            value = [tuple(pair) for pair in value]
        TUNING[key] = value


def _coerce_scalar(text):
    """Parse a --set value into int / bool / str with no silent surprises."""
    low = text.lower()
    if low in ("true", "false"):
        return low == "true"
    try:
        return int(text)
    except ValueError:
        pass
    # Allow a JSON literal for structured overrides (lists, dicts, tuples-as-lists).
    try:
        return json.loads(text)
    except (ValueError, TypeError):
        return text


def apply_set_override(spec):
    """Apply a single NAME=VALUE or NAME.SUBKEY=VALUE override onto TUNING."""
    if "=" not in spec:
        fail("--set expects NAME=VALUE, got %r" % spec)
    name, _, raw = spec.partition("=")
    name = name.strip()
    value = _coerce_scalar(raw.strip())
    if "." in name:
        top, sub = name.split(".", 1)
        if top not in TUNING or not isinstance(TUNING[top], dict):
            fail("--set %r: %r is not an overridable mapping" % (spec, top))
        TUNING[top][sub] = value
        return
    if name not in TUNING:
        fail("--set %r: unknown constant %r" % (spec, name))
    if name == "TRAUMA_BANDS" and isinstance(value, list):
        value = [tuple(pair) for pair in value]
    TUNING[name] = value


# ============================================================================
# Failure handling — fail loudly, never substitute silently
# ============================================================================

def fail(message):
    print("ERROR: %s" % message, file=sys.stderr)
    sys.exit(2)


# ============================================================================
# Resolution engine — exact integer arithmetic throughout
# ============================================================================

def roll_die():
    return random.randint(1, DIE_SIDES)


def competency_adjustment(tier):
    """Return the integer rank adjustment for a competency tier, or None if the
    tier permits no attempt. Raises on an unknown tier."""
    tiers = TUNING["COMPETENCY_TIERS"]
    if tier not in tiers:
        fail("Unknown competency tier %r. Known tiers: %s"
             % (tier, ", ".join(tiers)))
    return tiers[tier]


def envelope_distance(weapon, band):
    """Number of range bands the shot falls outside the weapon's envelope."""
    env = TUNING["WEAPONS"][weapon]["envelope"]
    idx = RANGE_ORDER.index(band)
    env_idx = [RANGE_ORDER.index(b) for b in env]
    lo, hi = min(env_idx), max(env_idx)
    if idx < lo:
        return lo - idx
    if idx > hi:
        return idx - hi
    return 0


def derive_tn(weapon, band):
    """Derive the TN for a weapon at a range band from the tuning constants.

    Returns (tn, base, distance, penalty)."""
    base = TUNING["RANGE_BANDS"][band]
    distance = envelope_distance(weapon, band)
    penalty = distance * TUNING["OUT_OF_ENVELOPE_PENALTY"]
    return base + penalty, base, distance, penalty


def resolve_timing(face, attribute, timing_edge):
    """Timing total = face + Attribute + Timing Edge. Does not feed Effect."""
    edge = TUNING["TIMING_EDGE_VALUE"] if timing_edge else 0
    total = face + attribute + edge
    parts = [("Timing face", face), ("Attribute", attribute)]
    if timing_edge:
        parts.append(("Timing Edge", edge))
    return total, parts


def resolve_action(face, attribute, comp_adj, action_edge, tn):
    """Action total = face + Attribute + Competency adj + Action Edge.

    Returns (total, margin, success, parts)."""
    edge = TUNING["ACTION_EDGE_VALUE"] if action_edge else 0
    total = face + attribute + comp_adj + edge
    margin = total - tn
    parts = [("Action face", face), ("Attribute", attribute),
             ("Competency", comp_adj)]
    if action_edge:
        parts.append(("Action Edge", edge))
    return total, margin, total >= tn, parts


def resolve_effect(effect_face, action_margin, base_rank):
    """Effect result = Effect face + Action margin + weapon Base Rank.

    Effect Dice take no character modifiers."""
    result = effect_face + action_margin + base_rank
    parts = [("Effect face", effect_face),
             ("Action margin", action_margin),
             ("Weapon Base Rank", base_rank)]
    return result, parts


def trauma_index(effect_result):
    """Highest Trauma rank whose lower bound is met by the Effect result."""
    idx = 0
    for i, (lower, _name) in enumerate(TUNING["TRAUMA_BANDS"]):
        if effect_result >= lower:
            idx = i
        else:
            break
    return idx


def trauma_name(index):
    return TUNING["TRAUMA_BANDS"][index][1]


def armor_step(armor, ap):
    """Rank steps removed by armor, accounting for armor-piercing."""
    if not armor:
        return 0
    if ap:
        if TUNING["AP_NEGATES_FULLY"]:
            return 0
        return max(0, TUNING["ARMOR_RANK_STEP"] - TUNING["AP_REDUCTION"])
    return TUNING["ARMOR_RANK_STEP"]


def apply_injury(base_index, armor, ap):
    """Step the Trauma rank down for armor. Floor at Graze (index 0)."""
    return max(0, base_index - armor_step(armor, ap))


# ============================================================================
# Throw configuration — held between throws, prompted when unconfigured
# ============================================================================

class Config:
    """Everything needed to resolve a throw. Fields default to None so that
    nothing is silently substituted; the operator must set each one."""

    FIELDS = ("action_dice", "effect_dice", "timing_dice", "attribute",
              "competency", "action_edge", "timing_edge", "weapon",
              "range_band", "tn_override", "armor", "ap")

    def __init__(self):
        self.action_dice = None
        self.effect_dice = None      # defaults to action_dice when unset
        self.timing_dice = None      # bool: present or absent
        self.attribute = None
        self.competency = None
        self.action_edge = None      # bool
        self.timing_edge = None      # bool
        self.weapon = None
        self.range_band = None
        self.tn_override = None       # optional direct TN entry
        self.armor = None            # bool
        self.ap = None               # bool

    # -- derived --
    def effect_count(self):
        return self.effect_dice if self.effect_dice is not None else self.action_dice

    def timing_count(self):
        return 1 if self.timing_dice else 0

    def base_rank(self):
        return TUNING["WEAPONS"][self.weapon]["base"]

    def tn(self):
        """The TN in force: the operator's override if set, else derived."""
        if self.tn_override is not None:
            return self.tn_override
        return derive_tn(self.weapon, self.range_band)[0]

    def tn_explanation(self):
        if self.tn_override is not None:
            derived = derive_tn(self.weapon, self.range_band)[0]
            return "%d (operator override; derived would be %d)" % (self.tn_override, derived)
        tn, base, dist, pen = derive_tn(self.weapon, self.range_band)
        if dist == 0:
            return "%d (%s · %s in envelope)" % (tn, self.range_band, self.weapon)
        return ("%d (%s · %s %d band%s out of envelope: %d + %d)"
                % (tn, self.range_band, self.weapon, dist,
                   "s" if dist != 1 else "", base, pen))

    def missing(self):
        """List of required fields not yet configured (effect_dice excepted —
        it legitimately defaults to the Action count)."""
        need = []
        for field in ("action_dice", "timing_dice", "attribute", "competency",
                      "action_edge", "timing_edge", "weapon", "armor", "ap"):
            if getattr(self, field) is None:
                need.append(field)
        if self.range_band is None and self.tn_override is None:
            need.append("range_band (or tn_override)")
        return need

    def attempt_permitted(self):
        return competency_adjustment(self.competency) is not None

    def summary_lines(self):
        lines = []
        eff = self.effect_count()
        eff_note = "" if self.effect_dice is not None else " (= Action count)"
        lines.append("  Action Dice     : %s" % self.action_dice)
        lines.append("  Effect Dice     : %s%s" % (eff, eff_note))
        lines.append("  Timing Dice     : %s" % ("present" if self.timing_dice else "absent"))
        lines.append("  Attribute       : %s" % self.attribute)
        adj = competency_adjustment(self.competency) if self.competency else None
        lines.append("  Competency      : %s (%s)"
                     % (self.competency, "no attempt" if adj is None else "%+d" % adj))
        lines.append("  Action Edge     : %s" % ("on (%+d)" % TUNING["ACTION_EDGE_VALUE"] if self.action_edge else "off"))
        lines.append("  Timing Edge     : %s" % ("on (%+d)" % TUNING["TIMING_EDGE_VALUE"] if self.timing_edge else "off"))
        lines.append("  Weapon          : %s (Base Rank %s)" % (self.weapon, self.base_rank() if self.weapon else "?"))
        lines.append("  Range band      : %s" % (self.range_band or "—"))
        if self.weapon and (self.range_band or self.tn_override is not None):
            lines.append("  TN              : %s" % self.tn_explanation())
        lines.append("  Armor           : %s" % ("on" if self.armor else "off"))
        lines.append("  Armor-piercing  : %s" % ("on" if self.ap else "off"))
        return lines


# ============================================================================
# Output helpers
# ============================================================================

def print_constants():
    K = TUNING
    print("=" * 68)
    print("ACTIVE TUNING CONSTANTS — NOT FINAL")
    print("=" * 68)
    print("Competency tiers :")
    for name, adj in K["COMPETENCY_TIERS"].items():
        print("    %-22s %s" % (name, "no attempt" if adj is None else "%+d" % adj))
    print("Action Edge value  : %+d" % K["ACTION_EDGE_VALUE"])
    print("Timing Edge value  : %+d" % K["TIMING_EDGE_VALUE"])
    print("TN ladder          : %s" % ", ".join(str(n) for n in K["TN_LADDER"]))
    print("Range band base TN : %s" % ", ".join("%s=%d" % (b, K["RANGE_BANDS"][b]) for b in RANGE_ORDER))
    print("Out-of-envelope    : +%d TN per band outside envelope" % K["OUT_OF_ENVELOPE_PENALTY"])
    print("Weapons            :")
    for name, spec in K["WEAPONS"].items():
        print("    %-10s base %d  envelope %s" % (name, spec["base"], ", ".join(spec["envelope"])))
    print("Armor rank step    : -%d rank" % K["ARMOR_RANK_STEP"])
    print("Armor-piercing     : %s" % ("negates armor fully" if K["AP_NEGATES_FULLY"]
                                       else "reduces armor step by %d" % K["AP_REDUCTION"]))
    print("Trauma bands       : %s" % ", ".join("%s>=%d" % (name, lb) for lb, name in K["TRAUMA_BANDS"]))
    print("=" * 68)


def bar(fraction, width=36):
    """A unicode block bar for a fraction 0..1 at eighth resolution."""
    partials = ["", "▏", "▎", "▍", "▌", "▋", "▊", "▉"]
    eighths = int(round(fraction * width * 8))
    full, rem = divmod(eighths, 8)
    return "█" * full + partials[rem]


# ============================================================================
# Statistics (float permitted here only)
# ============================================================================

def percentile(sorted_vals, p):
    n = len(sorted_vals)
    if n == 0:
        return None
    rank = max(1, math.ceil(p / 100.0 * n))
    return sorted_vals[rank - 1]


def median(sorted_vals):
    n = len(sorted_vals)
    if n == 0:
        return None
    if n % 2:
        return sorted_vals[n // 2]
    return (sorted_vals[n // 2 - 1] + sorted_vals[n // 2]) / 2.0


def mode_smallest(vals):
    if not vals:
        return None
    counts = Counter(vals)
    top = max(counts.values())
    return min(k for k, c in counts.items() if c == top)


def fmt_num(x):
    """Integers print bare; halves print with one decimal."""
    if isinstance(x, float) and not x.is_integer():
        return "%.1f" % x
    return "%d" % int(x)


# ============================================================================
# Distribution mode — the primary mode
# ============================================================================

def run_distribution_samples(cfg, n):
    """Run the configured throw n times by the stated assignment rule (highest
    face to Action, next highest to Effect) and collect outcomes.

    Returns (effect_results, failures, resolved, final_trauma_indices).
    Effect Dice take no modifiers; a failed Action produces no Effect."""
    attr = cfg.attribute
    comp = competency_adjustment(cfg.competency)
    tn = cfg.tn()
    base = cfg.base_rank()
    a = cfg.action_dice
    e = cfg.effect_count()

    effect_results = []
    final_trauma = []
    failures = 0
    resolved = 0

    for _ in range(n):
        # Roll only the dice that affect recorded outcomes. Timing does not feed
        # Effect and is not recorded here, so it is skipped for speed.
        pool = sorted((roll_die() for _ in range(a + e)), reverse=True)
        actions = pool[:a]
        effects = pool[a:a + e]
        for i in range(e):
            action_face = actions[min(i, a - 1)]
            total = action_face + attr + comp + (TUNING["ACTION_EDGE_VALUE"] if cfg.action_edge else 0)
            margin = total - tn
            resolved += 1
            if total < tn:
                failures += 1
                continue
            result = effects[i] + margin + base
            effect_results.append(result)
            final_trauma.append(apply_injury(trauma_index(result), cfg.armor, cfg.ap))

    return effect_results, failures, resolved, final_trauma


def print_distribution(cfg, n, show_constants=True):
    if not cfg.attempt_permitted():
        print("No attempt permitted: competency tier %r forbids the throw."
              % cfg.competency)
        return

    if show_constants:
        print_constants()

    effect_results, failures, resolved, final_trauma = run_distribution_samples(cfg, n)

    header = ("Attribute %d, %s%s, %s, %s range, TN %d"
              % (cfg.attribute, cfg.competency,
                 ", Action Edge" if cfg.action_edge else "",
                 cfg.weapon, cfg.range_band or "custom", cfg.tn()))

    print()
    print("RAW EFFECT DISTRIBUTION — %d throws" % n)
    print(header)
    print("Armor %s, AP %s" % ("on" if cfg.armor else "off", "on" if cfg.ap else "off"))
    print()

    if not effect_results:
        print("  No successful hits — no Effect results to distribute.")
    else:
        counts = Counter(effect_results)
        lo, hi = min(effect_results), max(effect_results)
        peak = max(counts.values())
        total = len(effect_results)
        for value in range(lo, hi + 1):
            c = counts.get(value, 0)
            frac = c / peak if peak else 0
            pctv = 100.0 * c / total if total else 0.0
            print("  %3d  %-36s %5.1f%%  (%d)" % (value, bar(frac), pctv, c))

        ordered = sorted(effect_results)
        print()
        print("  Effect results over %d successful hits (of %d resolved Actions)"
              % (total, resolved))
        print("  Mean %.1f   Median %s   Mode %d   Min %d   Max %d"
              % (sum(ordered) / total, fmt_num(median(ordered)),
                 mode_smallest(ordered), lo, hi))
        pcts = [10, 25, 50, 75, 90, 95, 99]
        print("  " + "   ".join("p%d %d" % (p, percentile(ordered, p)) for p in pcts))

    print()
    fail_pct = 100.0 * failures / resolved if resolved else 0.0
    print("  Failure rate: %.1f%%  (%d of %d resolved Actions missed the TN)"
          % (fail_pct, failures, resolved))

    print()
    print("  Trauma rank frequency (final, after armor/AP) over %d hits:"
          % len(final_trauma))
    if final_trauma:
        tcounts = Counter(final_trauma)
        for idx in range(len(TUNING["TRAUMA_BANDS"])):
            c = tcounts.get(idx, 0)
            pctv = 100.0 * c / len(final_trauma)
            print("    %-9s %5.1f%%  (%d)" % (trauma_name(idx), pctv, c))
    else:
        print("    (none)")
    print()


# ============================================================================
# Sweep mode
# ============================================================================

SWEEP_COMPETENCIES = ["untrained_method", "untrained_practice", "proficient",
                      "expert", "master"]


def run_sweep(cfg, trials):
    if not cfg.weapon:
        fail("Sweep needs a weapon configured.")
    if cfg.attribute is None:
        fail("Sweep needs an Attribute configured.")

    print_constants()
    print()
    print("SWEEP — %d trials per cell" % trials)
    print("Fixed: weapon %s (base %d), Attribute %d, Action Edge %s, "
          "%d Action / %d Effect dice"
          % (cfg.weapon, cfg.base_rank(), cfg.attribute,
             "on" if cfg.action_edge else "off",
             cfg.action_dice, cfg.effect_count()))
    print("Varying: range band, competency (method..master), armor on/off")
    print()

    cols = ("Range", "Competency", "Arm", "TN", "Fail%",
            "EffMean", "EffMed", "Effp90", "EffMax", "ModalTrauma")
    widths = (8, 20, 4, 4, 6, 8, 7, 7, 7, 12)
    header = "  " + "".join(name.ljust(w) for name, w in zip(cols, widths))
    print(header)
    print("  " + "-" * (len(header) - 2))

    for band in RANGE_ORDER:
        for comp in SWEEP_COMPETENCIES:
            for armor in (False, True):
                sub = copy.copy(cfg)
                sub.range_band = band
                sub.tn_override = None
                sub.competency = comp
                sub.armor = armor
                effect_results, failures, resolved, final_trauma = \
                    run_distribution_samples(sub, trials)
                tn = sub.tn()
                fail_pct = 100.0 * failures / resolved if resolved else 0.0
                if effect_results:
                    ordered = sorted(effect_results)
                    mean = sum(ordered) / len(ordered)
                    med = median(ordered)
                    p90 = percentile(ordered, 90)
                    emax = max(ordered)
                    modal = trauma_name(mode_smallest(final_trauma))
                    row = (band, comp, "on" if armor else "off", str(tn),
                           "%.1f" % fail_pct, "%.1f" % mean, fmt_num(med),
                           str(p90), str(emax), modal)
                else:
                    row = (band, comp, "on" if armor else "off", str(tn),
                           "%.1f" % fail_pct, "—", "—", "—", "—", "—")
                print("  " + "".join(str(v).ljust(w) for v, w in zip(row, widths)))
        print()


# ============================================================================
# Interactive mode
# ============================================================================

def ask(prompt):
    try:
        return input(prompt).strip()
    except EOFError:
        print()
        return "quit"


def ask_int(prompt, lo=None, hi=None):
    while True:
        raw = ask(prompt)
        if raw.lower() in ("q", "quit"):
            return None
        try:
            val = int(raw)
        except ValueError:
            print("  Not an integer: %r. Try again." % raw)
            continue
        if lo is not None and val < lo:
            print("  Must be >= %d." % lo)
            continue
        if hi is not None and val > hi:
            print("  Must be <= %d." % hi)
            continue
        return val


def ask_toggle(prompt):
    while True:
        raw = ask(prompt + " [y/n]: ").lower()
        if raw in ("y", "yes", "on", "1"):
            return True
        if raw in ("n", "no", "off", "0"):
            return False
        if raw in ("q", "quit"):
            return None
        print("  Answer y or n.")


def ask_choice(prompt, choices):
    print(prompt)
    for i, c in enumerate(choices, 1):
        print("    %d. %s" % (i, c))
    while True:
        val = ask_int("  Choose 1-%d: " % len(choices), 1, len(choices))
        if val is None:
            return None
        return choices[val - 1]


def configure_throw(cfg):
    print("\n-- Configure the throw --")
    val = ask_int("  Action Dice count (>=1): ", 1)
    if val is None:
        return
    cfg.action_dice = val
    same = ask_toggle("  Effect Dice = Action count (%d)?" % cfg.action_dice)
    if same is None:
        return
    if same:
        cfg.effect_dice = None
    else:
        cfg.effect_dice = ask_int("  Effect Dice count (>=1): ", 1)
    tim = ask_toggle("  Timing Dice present?")
    if tim is None:
        return
    cfg.timing_dice = tim
    print("  Throw configured.")


def configure_character(cfg):
    print("\n-- Configure character & weapon --")
    attr = ask_int("  Attribute (1-6): ", 1, 6)
    if attr is None:
        return
    cfg.attribute = attr
    comp = ask_choice("  Competency tier:", list(TUNING["COMPETENCY_TIERS"]))
    if comp is None:
        return
    cfg.competency = comp
    if competency_adjustment(comp) is None:
        print("  Note: %s permits no attempt — throws will be refused." % comp)
    ae = ask_toggle("  Action Edge present?")
    if ae is None:
        return
    cfg.action_edge = ae
    te = ask_toggle("  Timing Edge present?")
    if te is None:
        return
    cfg.timing_edge = te
    weapon = ask_choice("  Weapon:", list(TUNING["WEAPONS"]))
    if weapon is None:
        return
    cfg.weapon = weapon
    band = ask_choice("  Range band:", RANGE_ORDER)
    if band is None:
        return
    cfg.range_band = band
    cfg.tn_override = None
    tn, base, dist, pen = derive_tn(weapon, band)
    print("  Derived TN: %s" % cfg.tn_explanation())
    override = ask_toggle("  Override the derived TN with a direct entry?")
    if override:
        cfg.tn_override = ask_int("  TN: ", 1)
    armor = ask_toggle("  Target armor on?")
    if armor is None:
        return
    cfg.armor = armor
    ap = ask_toggle("  Armor-piercing on?")
    if ap is None:
        return
    cfg.ap = ap
    print("  Character & weapon configured.")


def prompt_index(prompt, faces, consumed):
    """Prompt for a 1-based pool index that is in range and not yet consumed."""
    while True:
        val = ask_int(prompt, 1, len(faces))
        if val is None:
            return None
        if val in consumed:
            print("  Index %d already consumed. Choose another." % val)
            continue
        return val


def do_throw(cfg):
    missing = cfg.missing()
    if missing:
        print("\nCannot throw — unconfigured: %s" % ", ".join(missing))
        print("Configure the throw and the character first.")
        return
    if not cfg.attempt_permitted():
        print("\nNo attempt permitted: competency tier %r forbids the throw."
              % cfg.competency)
        return

    a = cfg.action_dice
    e = cfg.effect_count()
    t = cfg.timing_count()
    total_dice = a + e + t

    faces = [roll_die() for _ in range(total_dice)]

    parts = []
    if t:
        parts.append("%d Timing" % t)
    parts.append("%d Action" % a)
    parts.append("%d Effect" % e)
    print("\nTHROW — %s  (%d dice)\n" % (", ".join(parts), total_dice))
    print("  " + "    ".join("[%d] %2d" % (i + 1, f) for i, f in enumerate(faces)))
    print()

    consumed = set()

    # Step 1 — Timing
    timing_face = None
    if t:
        print("Step 1 — Timing. Select one face.")
        idx = prompt_index("  Timing index: ", faces, consumed)
        if idx is None:
            return
        consumed.add(idx)
        timing_face = faces[idx - 1]
    else:
        print("Step 1 — Timing. (no Timing Dice — skipped)")

    # Step 2 — Action
    print("Step 2 — Action. Select %d face%s." % (a, "s" if a != 1 else ""))
    action_faces = []
    for k in range(a):
        idx = prompt_index("  Action %d index: " % (k + 1), faces, consumed)
        if idx is None:
            return
        consumed.add(idx)
        action_faces.append(faces[idx - 1])

    # Step 3 — Effect
    print("Step 3 — Effect. Select %d face%s." % (e, "s" if e != 1 else ""))
    effect_faces = []
    for k in range(e):
        idx = prompt_index("  Effect %d index: " % (k + 1), faces, consumed)
        if idx is None:
            return
        consumed.add(idx)
        effect_faces.append(faces[idx - 1])

    resolve_and_report(cfg, timing_face, action_faces, effect_faces)


def resolve_and_report(cfg, timing_face, action_faces, effect_faces):
    tn = cfg.tn()
    comp = competency_adjustment(cfg.competency)
    print("\n" + "-" * 40)

    if timing_face is not None:
        total, parts = resolve_timing(timing_face, cfg.attribute, cfg.timing_edge)
        for label, v in parts:
            print("    %-16s : %+d" % (label, v) if label != "Timing face"
                  else "    %-16s : %d" % (label, v))
        print("    " + "-" * 16)
        print("    %-16s : %d" % ("Timing total", total))
        print()

    actions = []
    for i, face in enumerate(action_faces, 1):
        total, margin, success, parts = resolve_action(
            face, cfg.attribute, comp, cfg.action_edge, tn)
        print("  Action %d" % i)
        for label, v in parts:
            if label == "Action face":
                print("    %-16s : %d" % (label, v))
            elif label == "Competency":
                print("    %-16s : %+d   (%s)" % (label, v, cfg.competency))
            else:
                print("    %-16s : %+d" % (label, v))
        print("    " + "-" * 16)
        print("    %-16s : %d" % ("Action total", total))
        print("    %-16s : %s" % ("TN", cfg.tn_explanation()))
        print("    %-16s : %+d   %s" % ("Margin", margin, "SUCCESS" if success else "MISS"))
        print()
        actions.append({"n": i, "margin": margin, "success": success})

    if not effect_faces:
        print("  No Effect Dice assigned.")
        return

    print("  Pair each Effect with an Action.")
    for j, eface in enumerate(effect_faces, 1):
        choices = ["Action %d (margin %+d, %s)"
                   % (act["n"], act["margin"], "SUCCESS" if act["success"] else "MISS")
                   for act in actions]
        pick = ask_choice("  Effect %d (face %d) pairs with:" % (j, eface), choices)
        if pick is None:
            return
        act = actions[choices.index(pick)]
        print()
        if not act["success"]:
            print("    Effect face      : %d" % eface)
            print("    Paired Action %d failed — no Effect. Moving on." % act["n"])
            print()
            continue
        result, parts = resolve_effect(eface, act["margin"], cfg.base_rank())
        for label, v in parts:
            if label == "Effect face":
                print("    %-16s : %d" % (label, v))
            else:
                print("    %-16s : %+d%s" % (label, v,
                      "   (%s)" % cfg.weapon if label == "Weapon Base Rank" else ""))
        print("    " + "-" * 16)
        print("    %-16s : %d" % ("Effect result", result))
        base_idx = trauma_index(result)
        print("    %-16s : %s" % ("Trauma", trauma_name(base_idx)))

        step = armor_step(cfg.armor, cfg.ap)
        if cfg.armor:
            print("    %-16s : -%d rank" % ("Armor", TUNING["ARMOR_RANK_STEP"]))
            if cfg.ap:
                if TUNING["AP_NEGATES_FULLY"]:
                    print("    %-16s : negated" % "Armor-piercing")
                else:
                    print("    %-16s : armor step -%d" % ("Armor-piercing", TUNING["AP_REDUCTION"]))
            final_idx = apply_injury(base_idx, cfg.armor, cfg.ap)
            print("    " + "-" * 16)
            print("    %-16s : %s" % ("Final Trauma", trauma_name(final_idx)))
        else:
            print("    %-16s : none" % "Armor")
            print("    " + "-" * 16)
            print("    %-16s : %s" % ("Final Trauma", trauma_name(base_idx)))
        print()


def interactive_loop(cfg):
    print("Agency Unlimited — Combat Simulator")
    print_constants()
    while True:
        print("\n" + "=" * 40)
        for line in cfg.summary_lines():
            print(line)
        miss = cfg.missing()
        if miss:
            print("  UNCONFIGURED: %s" % ", ".join(miss))
        print("=" * 40)
        cmd = ask("[t]hrow-config  [c]haracter  [r] throw  "
                  "[d]istribution  [s]weep  [k]constants  [q]uit : ").lower()
        if cmd in ("q", "quit"):
            print("Done.")
            return
        elif cmd == "t":
            configure_throw(cfg)
        elif cmd == "c":
            configure_character(cfg)
        elif cmd == "r":
            do_throw(cfg)
        elif cmd == "d":
            if cfg.missing():
                print("Configure fully before a distribution run.")
                continue
            n = ask_int("  Number of throws: ", 1)
            if n:
                print_distribution(cfg, n)
        elif cmd == "s":
            if cfg.action_dice is None or cfg.attribute is None or cfg.weapon is None:
                print("Configure Action dice, Attribute and weapon before a sweep.")
                continue
            n = ask_int("  Trials per cell: ", 1)
            if n:
                run_sweep(cfg, n)
        elif cmd == "k":
            print_constants()
        else:
            print("  Unknown command: %r" % cmd)


# ============================================================================
# Command-line entry
# ============================================================================

def build_config_from_args(args):
    cfg = Config()
    cfg.action_dice = args.action_dice
    cfg.effect_dice = args.effect_dice
    cfg.timing_dice = args.timing
    cfg.attribute = args.attribute
    cfg.competency = args.competency
    cfg.action_edge = args.action_edge
    cfg.timing_edge = args.timing_edge
    cfg.weapon = args.weapon
    cfg.range_band = args.range_band
    cfg.tn_override = args.tn
    cfg.armor = args.armor
    cfg.ap = args.ap
    return cfg


def require_headless_config(cfg, need_range=True):
    """Fail loudly if a headless run is missing a value with no sensible default."""
    problems = []
    if cfg.action_dice is None:
        problems.append("--action-dice")
    if cfg.attribute is None:
        problems.append("--attribute")
    if cfg.competency is None:
        problems.append("--competency")
    if cfg.weapon is None:
        problems.append("--weapon")
    if need_range and cfg.range_band is None and cfg.tn_override is None:
        problems.append("--range (or --tn)")
    if cfg.weapon is not None and cfg.weapon not in TUNING["WEAPONS"]:
        problems.append("unknown weapon %r" % cfg.weapon)
    if cfg.competency is not None and cfg.competency not in TUNING["COMPETENCY_TIERS"]:
        problems.append("unknown competency %r" % cfg.competency)
    if problems:
        fail("headless run missing required configuration: " + ", ".join(problems))


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Agency Unlimited combat resolution bench.")
    parser.add_argument("--config", metavar="FILE",
                        help="JSON file of tuning-constant overrides")
    parser.add_argument("--set", dest="sets", action="append", default=[],
                        metavar="NAME=VALUE",
                        help="override a tuning constant (repeatable); "
                             "e.g. --set TIMING_EDGE_VALUE=3 or "
                             "--set 'RANGE_BANDS.mid=9'")
    parser.add_argument("--seed", type=int, help="seed the RNG for reproducible runs")

    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--distribution", type=int, metavar="N",
                      help="run the configured throw N times and print the distribution")
    mode.add_argument("--sweep", action="store_true",
                      help="sweep distribution across a configuration matrix")
    parser.add_argument("--trials", type=int, default=5000,
                        help="trials per cell in sweep mode (default 5000)")

    # Throw / character configuration for headless modes.
    parser.add_argument("--action-dice", type=int)
    parser.add_argument("--effect-dice", type=int)
    parser.add_argument("--timing", dest="timing", action="store_true", default=None)
    parser.add_argument("--no-timing", dest="timing", action="store_false")
    parser.add_argument("--attribute", type=int)
    parser.add_argument("--competency")
    parser.add_argument("--action-edge", dest="action_edge", action="store_true", default=None)
    parser.add_argument("--no-action-edge", dest="action_edge", action="store_false")
    parser.add_argument("--timing-edge", dest="timing_edge", action="store_true", default=None)
    parser.add_argument("--no-timing-edge", dest="timing_edge", action="store_false")
    parser.add_argument("--weapon")
    parser.add_argument("--range", dest="range_band", choices=RANGE_ORDER)
    parser.add_argument("--tn", type=int, help="override the derived TN")
    parser.add_argument("--armor", dest="armor", action="store_true", default=None)
    parser.add_argument("--no-armor", dest="armor", action="store_false")
    parser.add_argument("--ap", dest="ap", action="store_true", default=None)
    parser.add_argument("--no-ap", dest="ap", action="store_false")

    args = parser.parse_args(argv)

    if args.config:
        load_config_file(args.config)
    for spec in args.sets:
        apply_set_override(spec)
    if args.attribute is not None and not (1 <= args.attribute <= 6):
        fail("--attribute must be 1..6")
    if args.seed is not None:
        random.seed(args.seed)

    if args.distribution is not None:
        cfg = build_config_from_args(args)
        # Headless toggles that are legitimately binary default to off, and the
        # full active config is printed below so nothing is hidden.
        cfg.timing_dice = bool(args.timing)
        cfg.action_edge = bool(args.action_edge)
        cfg.timing_edge = bool(args.timing_edge)
        cfg.armor = bool(args.armor)
        cfg.ap = bool(args.ap)
        require_headless_config(cfg)
        print("Configured throw:")
        for line in cfg.summary_lines():
            print(line)
        print_distribution(cfg, args.distribution)
        return

    if args.sweep:
        cfg = build_config_from_args(args)
        cfg.timing_dice = bool(args.timing)
        cfg.action_edge = bool(args.action_edge)
        cfg.armor = bool(args.armor)
        cfg.ap = bool(args.ap)
        require_headless_config(cfg, need_range=False)
        run_sweep(cfg, args.trials)
        return

    interactive_loop(build_config_from_args(args))


if __name__ == "__main__":
    main()
