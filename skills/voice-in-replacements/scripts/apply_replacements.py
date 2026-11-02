#!/usr/bin/env python3
"""Apply Voice-In Plus text replacements to a text file or to stdin.

Examples:
  apply_replacements.py notes.txt                 # writes notes-replaced.txt
  apply_replacements.py notes.txt --dry-run       # prints a unified diff
  cat notes.txt | apply_replacements.py - -o -    # filter mode

By default the rules come from the data folder next to this script:
data/rules.csv, then data/contractions.csv, then data/whisper-extra.csv,
each optional and each overriding the one before, with data/deny.txt as the
deny list.  Use --csv (repeatable) and --deny to point elsewhere, for
example at the full Voice-In export in Claude Code.
"""

from __future__ import annotations

import argparse
import collections
import difflib
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import replacements_engine as eng  # noqa: E402

DATA = HERE.parent / "data"


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("input", help="text file, or - for stdin")
    ap.add_argument("-o", "--output", help="output file, or - for stdout")
    ap.add_argument("--csv", action="append", help="rule file (repeatable)")
    ap.add_argument("--deny", help="deny-list file")
    ap.add_argument("--tiers", default=",".join(eng.DEFAULT_TIERS),
                    help="comma list from contraction,correction,expansion")
    ap.add_argument("--skip-ambiguous", action="store_true",
                    help="leave contractions such as I'd for a later LLM step")
    ap.add_argument("--no-context", action="store_true",
                    help="do not read had/would and is/has from the next word")
    ap.add_argument("--dry-run", action="store_true", help="print a diff only")
    ap.add_argument("--log", help="write the hit list as JSON to this file")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args(argv)

    csvs = args.csv or [DATA / "rules.csv", DATA / "contractions.csv",
                        DATA / "whisper-extra.csv"]
    deny = args.deny if args.deny is not None else DATA / "deny.txt"
    tiers = [t.strip() for t in args.tiers.split(",") if t.strip()]
    bad = set(tiers) - set(eng.SAFE_TIERS)
    if bad:
        ap.error(f"tiers not allowed on prose: {', '.join(sorted(bad))}")
    rs = eng.load([c for c in csvs if Path(c).expanduser().exists()], deny, tiers)

    if args.input == "-":
        text = sys.stdin.read()
    else:
        text = Path(args.input).expanduser().read_text(encoding="utf-8")
    new, hits = eng.apply(text, rs, skip_ambiguous=args.skip_ambiguous,
                          context=not args.no_context)

    if args.dry_run:
        sys.stdout.writelines(difflib.unified_diff(
            text.splitlines(True), new.splitlines(True), "original", "replaced"))
    else:
        out = args.output
        if out is None:
            if args.input == "-":
                out = "-"
            else:
                p = Path(args.input)
                out = str(p.with_name(p.stem + "-replaced" + p.suffix))
        if out == "-":
            sys.stdout.write(new)
        else:
            Path(out).write_text(new, encoding="utf-8")
            if not args.quiet:
                print(f"wrote {out}", file=sys.stderr)

    if args.log:
        Path(args.log).write_text(json.dumps(
            [{"source": s, "replacement": r, "token": i} for s, r, i in hits],
            indent=1), encoding="utf-8")
    if not args.quiet:
        counts = collections.Counter(s.lower() for s, _, _ in hits)
        print(f"{len(rs.table)} rules loaded, {len(hits)} replacements made",
              file=sys.stderr)
        for k, c in counts.most_common(5):
            print(f"  {c:4d}  {k}", file=sys.stderr)
        amb = [s for s, _, _ in hits if s.lower() in eng.AMBIGUOUS]
        if amb:
            print(f"  ambiguous contractions expanded: {len(amb)} "
                  "(check had/would and is/has)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
