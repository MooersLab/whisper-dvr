"""Run the shared replacement cases against the Python engine."""

import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "scripts"))
import replacements_engine as eng  # noqa: E402

FIXTURE = HERE / "fixture-replacements.csv"
DENY = HERE / "fixture-deny.txt"


def unescape(s):
    return s.replace("\\n", "\n").replace("\\t", "\t")


def cases():
    for raw in (HERE / "replacement-cases.tsv").read_text(encoding="utf-8").splitlines():
        if not raw or raw.startswith("#"):
            continue
        parts = raw.split("\t")
        parts += [""] * (4 - len(parts))
        yield pytest.param(*parts[:4], id=parts[0])


@pytest.mark.parametrize("name,options,text,expected", list(cases()))
def test_case(name, options, text, expected):
    opts = options.split(",") if options not in ("", "-") else []
    tiers = eng.DEFAULT_TIERS
    for o in opts:
        if o.startswith("tiers="):
            tiers = o[6:].split("+")
    deny = None if "nodeny" in opts else DENY
    rs = eng.load([FIXTURE], deny, tiers)
    got, _ = eng.apply(unescape(text), rs, skip_ambiguous="skip-ambiguous" in opts,
                       today="2026-11-01", context="no-context" not in opts)
    assert got == unescape(expected)


def test_tiers_of_fixture():
    rs = eng.load([FIXTURE], None, eng.SAFE_TIERS)
    tiers = {r.trigger: r.tier for r in rs.rules}
    assert tiers["open pdb"] == eng.ACTION
    assert tiers["insert python code"] == eng.TEMPLATE
    assert tiers["new sentence"] == eng.COMMAND
    assert tiers["expand saxs"] == eng.EXPANSION
    assert tiers["can't"] == eng.CONTRACTION


def test_hits_reported():
    rs = eng.load([FIXTURE], DENY)
    _, hits = eng.apply("I can't use emax", rs)
    assert [(s, r) for s, r, _ in hits] == [("can't", "cannot"), ("emax", "Emacs")]


def test_contractions_csv_header_and_override(tmp_path):
    extra = tmp_path / "contractions.csv"
    extra.write_text("contraction,expansion\ncan't,can not\nain't,am not\n", encoding="utf-8")
    rs = eng.load([FIXTURE, extra])
    got, _ = eng.apply("I can't and ain't", rs)
    assert got == "I can not and am not"
    assert "contraction" not in rs.table


def test_missing_file_is_a_problem():
    rs = eng.load([HERE / "nope.csv"])
    assert rs.table == {} and rs.problems


def test_idempotent_on_fixture():
    rs = eng.load([FIXTURE], DENY)
    once, _ = eng.apply("I can't use emax w.r.t. settle cassin", rs)
    twice, _ = eng.apply(once, rs)
    assert once == twice
