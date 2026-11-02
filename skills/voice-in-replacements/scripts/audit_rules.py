#!/usr/bin/env python3
"""Audit a Voice-In Plus replacement CSV before using it on transcripts.

Reports tier counts and data problems, and proposes deny-list entries
for triggers that are ordinary English and would fire by accident.

Usage:
  audit_rules.py replacements.csv [--deny-out deny.txt] [--rules-out rules.csv]

The word-frequency test needs the optional wordfreq package.  Without
it, every single-word trigger in the correction tier is proposed.
"""

from __future__ import annotations

import argparse
import collections
import csv
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import replacements_engine as eng  # noqa: E402

try:
    from wordfreq import zipf_frequency
except ImportError:  # pragma: no cover
    zipf_frequency = None

KNOWN_CODES = {"<newline>", "<capitalize>", "<insertspace>", "<date>", "<enter>",
               "<default>", "<case:lower>", "<case:upper>", "<case:capitalize>",
               "<case:sentence>", "<case:default>"}
SYMBOL_WORDS = {"bar", "over", "sub"}
CODE_TYPO_RE = re.compile(r"<newline >|<newlne>|<Capitalize>|<open;|<case:normal>")


def zipf(word: str) -> float:
    return zipf_frequency(word, "en") if zipf_frequency else 9.0


def risk(key: str, value: str):
    """Return a reason string when KEY is likely to fire by accident."""
    toks = key.split()
    same = value.strip().lower() == key
    if len(toks) == 1:
        z = zipf(toks[0])
        if same and z >= 4.5:
            return f"common word, case change only (zipf {z:.1f})"
        if not same and z >= 3.0:
            return f"common word (zipf {z:.1f})"
        return None
    # Spelled symbols such as "p 4 bar 2 c" are deliberate dictation.
    if len(toks) > 1 and all(len(t) <= 2 or t in SYMBOL_WORDS for t in toks):
        return None
    if not same and len(toks) <= 4:
        if all(zipf(t) >= 4.8 for t in toks):
            return "phrase of very common words"
        if all(zipf(t) >= 3.5 for t in toks):
            return "REVIEW phrase of common words"
    return None


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("csv")
    ap.add_argument("--deny-out", help="write proposed deny list here")
    ap.add_argument("--rules-out", help="write cleaned transcript-tier rules here")
    ap.add_argument("--tiers", default=",".join(eng.SAFE_TIERS))
    ap.add_argument("--allow", action="append", default=[],
                    help="rule file whose triggers are never proposed for denial, "
                         "such as contractions.csv (repeatable)")
    args = ap.parse_args(argv)

    path = Path(args.csv).expanduser()
    text = path.read_text(encoding="utf-8")
    tiers = collections.Counter()
    problems = []
    keys = collections.Counter()
    rows = []
    for line, trig, val in eng.read_csv_text(text, path.name):
        if trig is None:
            problems.append(val)
            continue
        if trig != trig.strip():
            problems.append(f"{path.name}:{line}: trigger has padding spaces: '{trig}'")
        if CODE_TYPO_RE.search(val):
            problems.append(f"{path.name}:{line}: code typo in '{trig.strip()}'")
        key = eng.normalize_trigger(trig)
        keys[key] += 1
        tier = eng.classify(trig, val)
        tiers[tier] += 1
        rows.append((key, trig.strip(), val, tier, line))
    for k, c in keys.items():
        if c > 1:
            problems.append(f"duplicate trigger '{k}' appears {c} times")
    if "||" in text:
        problems.append("note: '||' alternation in a trigger was split into separate rules")

    allowed = set()
    for extra in args.allow:
        ep = Path(extra).expanduser()
        if ep.exists():
            for _, t, _v in eng.read_csv_text(ep.read_text(encoding="utf-8"), ep.name):
                if t is not None:
                    allowed.add(eng.normalize_trigger(t))

    wanted = set(args.tiers.split(","))
    flagged = []
    for key, trig, val, tier, line in rows:
        # Expansion triggers start with a cue word such as "expand",
        # so they rarely fire by accident and are not screened.
        if tier == eng.CORRECTION and tier in wanted and key not in allowed:
            why = risk(key, val)
            if why:
                flagged.append((key, val.strip(), why))

    print(f"Rules read: {sum(tiers.values())}")
    for t in (eng.CONTRACTION, eng.CORRECTION, eng.EXPANSION,
              eng.COMMAND, eng.ACTION, eng.TEMPLATE):
        print(f"  {t:12s} {tiers[t]:5d}")
    n_review = sum(1 for f in flagged if f[2].startswith("REVIEW"))
    print(f"Proposed deny entries: {len(flagged) - n_review}")
    print(f"Phrases listed for review only: {n_review}")
    print(f"Data problems: {len(problems)}")
    for p in problems:
        print("  " + p)

    if args.deny_out:
        with open(args.deny_out, "w", encoding="utf-8") as fh:
            fh.write("# Triggers that must not fire on transcripts.\n")
            fh.write("# Generated by audit_rules.py.  Delete a line to allow that rule.\n")
            fh.write("# Format: trigger  # replacement ; reason\n")
            fh.write("#\n# Active entries (these rules are skipped):\n")
            for key, val, why in sorted(flagged):
                if not why.startswith("REVIEW"):
                    shown = val.replace("\n", " ")[:40]
                    fh.write(f"{key}  # {shown} ; {why}\n")
            fh.write("#\n# Review list.  These rules stay active.  Remove the leading\n")
            fh.write("# '#R ' from a line to deny that rule as well.\n")
            for key, val, why in sorted(flagged):
                if why.startswith("REVIEW"):
                    shown = val.replace("\n", " ")[:40]
                    fh.write(f"#R {key}  # {shown}\n")
    if args.rules_out:
        with open(args.rules_out, "w", encoding="utf-8", newline="") as fh:
            w = csv.writer(fh)
            for key, trig, val, tier, line in rows:
                if tier in wanted:
                    w.writerow([trig, val.strip()])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
