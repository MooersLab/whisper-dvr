---
name: voice-in-replacements
description: Apply Blaine's Voice-In Plus text replacements to prose, expanding English contractions and fixing words that speech recognition mishears, with a deterministic script. Use when the user asks to "apply my text replacements", "apply my Voice-In rules", "expand contractions and fix dictation errors", "clean this transcript with my replacements", or "run the replacement table" on pasted text, a file, or a transcript that did not come from whisper-dvr. Run it before the transcript-parser skill when both apply.
---

# Voice-In Plus text replacements

This skill applies a table of text replacements to prose.
The table comes from Voice-In Plus, a dictation extension for Chrome.
Each rule has a trigger and a replacement.
The same algorithm runs inside the Emacs package whisper-dvr, so text cleaned here matches text cleaned there.

## Finding the scripts

Set `SKILL_DIR` to the first of these folders that contains `scripts/apply_replacements.py`.

1. The folder that holds this SKILL.md, when the skill was installed with its files.
2. `~/6112MooersLabGitHubLabRepos/whisper-dvr/skills/voice-in-replacements`, the copy in the whisper-dvr repository on Blaine's computer.

Run every command below from `SKILL_DIR`, or prefix the paths with it.
If neither folder exists, say so and ask the user to attach `voice-in-replacements.zip`, which `make skill-zip` builds in the whisper-dvr repository.
Do not fall back to editing the text by hand.

## Rules for Claude

- Always run `scripts/apply_replacements.py`.
  Never apply the rules by reading the table and editing the text yourself.
  The table holds more than a thousand active rules, and the result must match whisper-dvr exactly.
- Never change the rules, the deny list, or the tiers unless the user asks.
- Keep the original text.
  Write the result to a new file or return it in the reply.
- Use straight ASCII quotes in every command.

## Workflow

1. Find the input.
   It may be an attached file, a path, or text pasted in the conversation.
   Write pasted text to a temporary file first.
2. Run the script with the defaults.

   ```bash
   python3 scripts/apply_replacements.py INPUT.txt
   ```

   The result is written beside the input as `INPUT-replaced.txt`.
   Use `-o -` to print to standard output instead.
3. Contractions ending in 's and 'd are read from the next word, using the rules of expand-contractions.el.
   So "I'd like" becomes "I would like", "I'd gone" becomes "I had gone", and "he's been" becomes "he has been".
   Use `--no-context` to turn this off.
4. When the user also wants the transcript-parser skill, or any LLM rewrite, add `--skip-ambiguous`.
   That flag leaves contractions such as `I'd` and `it's` in place, so the later step resolves any case the next-word rule gets wrong.
5. Report in a few lines.
   Give the number of replacements, the five most frequent rules, and the count of ambiguous contractions that were expanded.
   The script prints these on standard error.
6. Offer `--dry-run` when the user wants to see the changes as a unified diff before accepting them.
7. If the user asked for it, pass the result to the transcript-parser skill.

## Options

| Option | Effect |
|--------|--------|
| `-o FILE` | Output file, or `-` for standard output |
| `--csv FILE` | Rule file.  Repeat for several files.  Later files override earlier ones |
| `--deny FILE` | Deny list of triggers that must never fire |
| `--tiers LIST` | Comma list from `contraction`, `correction`, `expansion`.  Default `contraction,correction` |
| `--skip-ambiguous` | Leave ambiguous contractions for a later LLM step |
| `--no-context` | Do not choose had/would and is/has from the next word |
| `--dry-run` | Print a diff and write nothing |
| `--log FILE` | Write every replacement as JSON |

## Where the rules come from

By default the script reads three files in order, and each later file overrides the one before.

1. `data/rules.csv` holds the transcript tiers of the Voice-In Plus export.
2. `data/contractions.csv` is the table from Blaine's expand-contractions.el package, with 248 contractions and informal forms such as gonna and kinda.
   Its header line `contraction,expansion` is skipped.
3. `data/whisper-extra.csv` holds errors that only Whisper makes.

The triggers in `data/deny.txt` are skipped.
`data/rules.csv` and the proposed deny list are made by `make skill-data` in the whisper-dvr repository.

## Tiers

Every rule is sorted into one tier.
Only the first three can be applied to prose, and only the first two are applied by default.

| Tier | Example trigger | Applied |
|------|-----------------|---------|
| contraction | can't | Yes |
| correction | settle cassin | Yes |
| expansion | expand saxs | Only with `--tiers` |
| command | insert python code | Never |
| action | open pdb | Never |
| template | begin day | Never |

Commands, actions, and templates are dictation shortcuts.
They paste templates, open web pages, or press keys, so they must never fire on a transcript.
See `references/codes.md` for the Voice-In codes and how they are handled.

## Refreshing the snapshot

After exporting a new CSV from Voice-In Plus, run the audit.

```bash
python3 scripts/audit_rules.py replacements.csv --allow data/contractions.csv \
    --deny-out data/deny.txt --rules-out data/rules.csv
```

The audit prints tier counts and data problems.
It proposes deny entries for single words that are common English, such as `may` and `riding`, and for phrases made of very common words.
It lists phrases of common words as review lines that stay active.
The word-frequency test needs the `wordfreq` package.
Review `data/deny.txt` by hand before using it.

## Tests

`tests/replacement-cases.tsv` holds the cases that both this script and the Emacs Lisp module must pass.

```bash
python3 -m pytest -q tests
```
