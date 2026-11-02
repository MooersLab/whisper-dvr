"""Engine for applying Voice-In Plus text replacements to prose.

The same algorithm lives in whisper-dvr-replacements.el.  Both
implementations must pass tests/replacement-cases.tsv.

Rule files are two-column CSV exports from Voice-In Plus (trigger,
replacement), with no header.  Lines whose first field starts with '#'
are comments.  A deny file holds one trigger per line.
"""

from __future__ import annotations

import csv
import datetime as _dt
import io
import re
from dataclasses import dataclass, field
from pathlib import Path

# Tier names.  Only the transcript tiers are applied by default.
CONTRACTION = "contraction"
CORRECTION = "correction"
EXPANSION = "expansion"
COMMAND = "command"
ACTION = "action"
TEMPLATE = "template"
DEFAULT_TIERS = (CONTRACTION, CORRECTION)
SAFE_TIERS = (CONTRACTION, CORRECTION, EXPANSION)

# Punctuation that is peeled from token edges before matching.
# The straight apostrophe is not peeled at the front so that
# triggers such as 'cause and 'twas still match.
LEAD_CHARS = "([{\"“‘"
TRAIL_CHARS = ".,;:!?)]}\"'”’…"

# Ambiguous contractions.  The 'd forms can mean had or would, and the
# 's forms can mean is or has.  When an LLM runs afterwards these are
# best left for it to resolve from context.
# The 's forms on indefinite pronouns can also be possessives.
AMBIGUOUS = frozenset("""
i'd you'd he'd she'd it'd we'd they'd that'd there'd who'd what'd where'd
how'd why'd he's she's it's that's there's here's what's who's where's
how's why's this's everyone's everybody's eerybody's everything's
nothing's somebody's someone's something's
""".split())

# ASCII whitespace only, so that Python and Emacs Lisp split alike.
WS_CHARS = " \t\n\r\f\v"
WS = f"[{WS_CHARS}]"

# Context rules ported from expand-contractions.el.  A 's contraction
# that expands to "X is" becomes "X has" before a HAS trigger.  A 'd
# contraction that expands to "X had" or "X would" becomes "X had"
# before a past participle and "X would" otherwise.
HAS_TRIGGERS = frozenset("been got gotten had".split())
HAD_TRIGGERS = frozenset("""
been better become begun beaten bitten bought broken brought built caught
chosen done drawn driven drunk eaten fallen felt flown forgiven forgotten
fought found frozen given gone got gotten grown had heard held hidden kept
known left lost made meant met ridden risen said seen sent shown slept sold
spent spoken stolen stood sung swum sworn taken taught thought thrown told
torn understood woken worn written
""".split())
ED_BASE_VERBS = frozenset(
    "bleed breed embed exceed feed heed need proceed seed shed shred speed succeed wed".split())
SKIPPABLE = frozenset("""
all already also always certainly definitely ever just nearly never not now
only probably really recently still surely then
""".split())
IS_RE = re.compile(r"^(.+) is$")
HAD_WOULD_RE = re.compile(r"^(.+) (would|had)$")
ALPHA_RE = re.compile(r"^[^\W\d_]+")

ACTION_RE = re.compile(r"<(open|press)[:;]|<enter>", re.I)
CODE_RE = re.compile(
    r"<(newline ?|newlne|capitalize|insertspace|date|enter|default|"
    r"case:(lower|upper|capitalize|sentence|default|normal))>",
    re.I,
)
TEMPLATE_HINT_RE = re.compile(r"<(newline|capitalize|case:)|\\begin|@|<paste|<(?!date>|insertspace>)[a-z]+[ >]|%", re.I)
EXPAND_RE = re.compile(
    r"^(expand|fully expand|double expand|triple expand|capitalize and expand)\s"
)
COMMAND_PREFIXES = (
    "insert", "display", "citekey", "cite ", "site ", "subdex", "subsubdex",
    "project ", "limit", "limited", "let me", "lemon", "sheet ", "overleaf",
    "email", "priority", "item", "backlink", "footnote", "url ", "open ",
    "add ", "new ", "print ", "markdown", "mark down", "marked down",
    "header", "head ", "headed", "protocol", "list ", "define", "explain",
    "expression", "inline", "equation", "python", "read ", "write ",
    "show ", "return ", "unpack", "generate", "convert", "extract",
    "subsection", "sub sub", "index ", "checklist", "description item",
    "closing", "bounded", "going to", "and it ", "then at", "then it",
    "then that", "when it", "time ", "timed", "none of", "let it",
    "cap next", "default case", "lower case", "upper case",
    "sentence case", "capitalize each", "new sentence", "horizontal line",
    "copy selection", "find selection", "save ", "search", "send mail",
    "contract example", "abbreviate", "example given", "id est",
    "github ", "funding", "edit ", "bash ", "c-", "control ", "meta ",
    "value of", "how ", "what ", "do i ", "who ", "creator", "founder",
    "original developer", "originator", "benevolent", "developer of",
    "author of", "editor for", "expert", "runs ", "inset ", "begin day",
    "old begin", "start ", "today", "to be done", "to do", "ranked",
    "prioritized", "add checkbox", "anchor", "definition list",
    "nested", "navigation", "ordered list", "unordered list", "task list",
    "table ", "verbatim", "tiny note", "annot", "a note", "potential slide",
    "slide ", "section ", "transcript latex", "org mode cheat",
    "org-mode cheat", "emax commands", "confidential", "writing commitments",
    "dsw ", "cryo em index", "emacs index", "mint ", "makdown",
    "run ", "hypperef", "introduction template", "project template",
)


@dataclass
class Rule:
    """One trigger and its replacement."""

    trigger: str
    replacement: str
    tier: str
    source: str = ""
    line: int = 0


@dataclass
class RuleSet:
    """A compiled set of rules ready for matching."""

    table: dict = field(default_factory=dict)
    max_len: int = 1
    rules: list = field(default_factory=list)
    problems: list = field(default_factory=list)


def peel(token: str):
    """Split TOKEN into (lead, core, trail) punctuation parts."""
    i = 0
    while i < len(token) and token[i] in LEAD_CHARS:
        i += 1
    j = len(token)
    while j > i and token[j - 1] in TRAIL_CHARS:
        j -= 1
    return token[:i], token[i:j], token[j:]


def normalize_core(text: str) -> str:
    """Lowercase TEXT and map curly apostrophes to straight ones."""
    return text.replace("’", "'").replace("‘", "'").lower()


def normalize_trigger(trigger: str) -> str:
    """Return the hash key for TRIGGER, or the empty string."""
    parts = []
    for tok in re.split(WS + "+", trigger.strip(WS_CHARS)):
        _, core, _ = peel(tok)
        if core:
            parts.append(normalize_core(core))
    return " ".join(parts)


def classify(trigger: str, replacement: str) -> str:
    """Assign a tier to one rule."""
    key = trigger.strip().lower()
    val = replacement
    if ACTION_RE.search(val):
        return ACTION
    if "\n" in val or len(val) > 120 or val.strip().startswith("\\begin"):
        return TEMPLATE
    if key.startswith("\\") or key.startswith(COMMAND_PREFIXES):
        return COMMAND
    if TEMPLATE_HINT_RE.search(val):
        return COMMAND
    if EXPAND_RE.match(key):
        return EXPANSION
    if "'" in key and len(key.split()) == 1:
        return CONTRACTION
    return CORRECTION


def read_csv_text(text: str, source: str = ""):
    """Yield (line, trigger, replacement) from Voice-In CSV TEXT.

    Problems found while reading are yielded as (line, None, message).
    """
    reader = csv.reader(io.StringIO(text))
    prev_end = 0
    for row in reader:
        # Report the line on which the row starts, as the Emacs parser does.
        line = prev_end + 1
        prev_end = reader.line_num
        if not row or not "".join(row).strip():
            continue
        if row[0].lstrip().startswith("#"):
            continue
        # The header of an expand-contractions CSV file.
        if line == 1 and row[0].strip().lower() == "contraction":
            continue
        if len(row) < 2:
            yield line, None, f"{source}:{line}: row has one field"
            continue
        if len(row) > 2:
            yield line, None, f"{source}:{line}: row has {len(row)} fields, extra ignored"
        for trig in row[0].split("||"):
            yield line, trig, row[1]


def read_deny(path) -> set:
    """Return the set of normalized triggers listed in the deny file PATH."""
    out = set()
    if not path:
        return out
    p = Path(path).expanduser()
    if not p.exists():
        return out
    for raw in p.read_text(encoding="utf-8").splitlines():
        s = raw.split("#", 1)[0].strip() if not raw.lstrip().startswith("#") else ""
        if s:
            out.add(normalize_trigger(s))
    return out


def load(csv_paths, deny_path=None, tiers=DEFAULT_TIERS) -> RuleSet:
    """Build a RuleSet from CSV_PATHS, skipping triggers in DENY_PATH.

    Later files override earlier ones, so a Whisper supplement file can
    correct a Voice-In rule.  Within one file a duplicate trigger keeps
    the first replacement and records a problem.
    """
    rs = RuleSet()
    deny = read_deny(deny_path)
    tiers = set(tiers)
    for path in csv_paths:
        if not path:
            continue
        p = Path(path).expanduser()
        if not p.exists():
            rs.problems.append(f"missing rule file: {p}")
            continue
        seen = set()
        for line, trig, val in read_csv_text(p.read_text(encoding="utf-8"), p.name):
            if trig is None:
                rs.problems.append(val)
                continue
            key = normalize_trigger(trig)
            if not key:
                continue
            tier = classify(trig, val)
            rule = Rule(trig.strip(), val, tier, p.name, line)
            rs.rules.append(rule)
            if key in seen:
                rs.problems.append(f"{p.name}:{line}: duplicate trigger '{key}'")
                continue
            seen.add(key)
            if tier not in tiers or key in deny:
                rs.table.pop(key, None)
                continue
            # A trigger that ends in a period, such as w.r.t., swallows
            # the period that follows it in the text.
            rs.table[key] = (val.strip(), trig.strip().endswith("."))
            rs.max_len = max(rs.max_len, len(key.split()))
    return rs


def render(replacement: str, today=None) -> str:
    """Render the Voice-In codes that can appear in transcript tiers."""
    today = today or _dt.date.today().isoformat()
    out = replacement.replace("<insertspace>", " ").replace("<date>", today)
    out = re.sub(r"<newline ?>|<newlne>", "\n", out, flags=re.I)
    return CODE_RE.sub("", out)


def match_case(source: str, replacement: str) -> str:
    """Capitalize REPLACEMENT when SOURCE starts with a capital letter."""
    if source[:1].isupper() and replacement[:1].islower():
        return replacement[:1].upper() + replacement[1:]
    return replacement


def next_word(cores, peeled, j):
    """Return the first non-skippable word after token J, or None.

    Up to three words are examined.  Punctuation after a word ends the
    search, because the next clause does not decide the reading.
    """
    k = j + 1
    for _ in range(3):
        if k >= len(cores) or peeled[k - 1][2] or peeled[k][0]:
            return None
        m = ALPHA_RE.match(cores[k])
        if not m or m.group(0) != cores[k]:
            return None
        if cores[k] not in SKIPPABLE:
            return cores[k]
        k += 1
    return None


def had_word_p(word: str) -> bool:
    """Return True when "had" is the right reading of 'd before WORD."""
    return word in HAD_TRIGGERS or (
        len(word) > 3 and word.endswith("ed") and word not in ED_BASE_VERBS)


def disambiguate(key: str, rep: str, word):
    """Choose between is/has and had/would for the contraction KEY."""
    if key.endswith("'s"):
        m = IS_RE.match(rep)
        if m and word in HAS_TRIGGERS:
            return m.group(1) + " has"
    elif key.endswith("'d"):
        m = HAD_WOULD_RE.match(rep)
        if m:
            return m.group(1) + (" had" if word and had_word_p(word) else " would")
    return rep


def tokenize(text: str):
    """Split TEXT into a list of [token, following-whitespace] pairs.

    Leading whitespace is returned separately.
    """
    m = re.match(WS + "*", text)
    lead_ws = m.group(0)
    pairs = [[t, w] for t, w in re.findall(f"([^{WS_CHARS}]+)({WS}*)", text[len(lead_ws):])]
    return lead_ws, pairs


def apply(text: str, rs: RuleSet, skip_ambiguous: bool = False, today=None,
          context: bool = True):
    """Apply RS to TEXT.  Return (new_text, hits).

    With CONTEXT, 's and 'd contractions are read from the next word,
    so "I'd like" gives "I would like" and "I'd gone" gives "I had gone".
    With SKIP_AMBIGUOUS, the ambiguous contractions are left unchanged.

    Each hit is a tuple (source_text, replacement, token_index).
    The walk is single pass and longest match first.
    """
    lead_ws, pairs = tokenize(text)
    peeled = [peel(t) for t, _ in pairs]
    cores = [normalize_core(c) for _, c, _ in peeled]
    out = [lead_ws]
    hits = []
    i, n = 0, len(pairs)
    while i < n:
        matched = False
        for length in range(min(rs.max_len, n - i), 0, -1):
            j = i + length - 1
            if any(not cores[k] for k in range(i, j + 1)):
                continue
            # Interior punctuation breaks a phrase.
            if any(peeled[k][2] for k in range(i, j)):
                continue
            if any(peeled[k][0] for k in range(i + 1, j + 1)):
                continue
            key = " ".join(cores[i : j + 1])
            entry = rs.table.get(key)
            if entry is None:
                continue
            rep, eats_dot = entry
            if skip_ambiguous and key in AMBIGUOUS:
                continue
            src = " ".join(peeled[k][1] for k in range(i, j + 1))
            rendered = render(rep, today)
            if context and i == j:
                rendered = disambiguate(key, rendered, next_word(cores, peeled, j))
            new = match_case(src, rendered)
            trail = peeled[j][2]
            if eats_dot and trail.startswith("."):
                trail = trail[1:]
            out.append(peeled[i][0] + new + trail + pairs[j][1])
            hits.append((src, new, i))
            i = j + 1
            matched = True
            break
        if not matched:
            out.append(pairs[i][0] + pairs[i][1])
            i += 1
    return "".join(out), hits
