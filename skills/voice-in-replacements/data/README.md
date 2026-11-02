# Rule data

Only this README and `contractions.csv` are tracked by git.
The other files are personal, because the Voice-In export holds names and e-mail addresses.

| File | Content |
|------|---------|
| `replacements.csv` | The full Voice-In Plus export.  whisper-dvr reads this file and classifies every rule itself |
| `contractions.csv` | The table from expand-contractions.el, 248 contractions.  Loaded after the export, so it wins |
| `rules.csv` | The contraction, correction, and expansion rules only, written by `make skill-data`.  The skill reads this file |
| `deny.txt` | Triggers that must never fire.  Lines starting with `#R ` are review entries that stay active |
| `whisper-extra.csv` | Errors that only Whisper makes, in the same two-column format.  Loaded last |

After each new export, run this from the top of the repository.

```bash
make skill-data
```

It rewrites `rules.csv` and writes `deny-proposed.txt`.
Compare that file with your edited `deny.txt` before replacing it.
