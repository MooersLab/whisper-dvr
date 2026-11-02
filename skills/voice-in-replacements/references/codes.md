# Voice-In Plus codes

Voice-In Plus lets a replacement carry codes in angle brackets.
The meanings below were inferred from how the codes are used in the rule file.

| Code | Meaning in Voice-In | Handling on prose |
|------|---------------------|-------------------|
| `<newline>` | Insert a line break | Rule becomes a command or template and is never applied |
| `<capitalize>` | Capitalize the next word | Rule becomes a command and is never applied |
| `<case:lower>`, `<case:upper>`, `<case:capitalize>`, `<case:sentence>` | Change case until reset | Rule becomes a command and is never applied |
| `<default>`, `<case:default>` | End a case change | Removed |
| `<open:URL>` | Open a web page | Rule becomes an action and is never applied |
| `<press:KEY>`, `<enter>` | Press a key | Rule becomes an action and is never applied |
| `<date>` | Insert today's date | Replaced by the date in ISO format |
| `<insertspace>` | Insert a space | Replaced by one space |

Angle-bracket text that is not in this table, such as `<Paste code here>` or an HTML tag, is literal text.
A rule that contains it is classed as a command.

Typos found in the rule file, such as `<newline >`, `<newlne>`, `<Capitalize>`, `<open;`, and `<case:normal>`, are recognized so that their rules are classified correctly.

## Matching

- Matching ignores case and treats curly and straight apostrophes alike.
- The longest trigger that starts at a word wins.
- Punctuation at the edges of words is kept, and punctuation inside a phrase blocks the match.
- A trigger that ends in a period, such as `w.r.t.`, swallows the period that follows it.
- A replacement is capitalized when the matched text started with a capital, so `It's` becomes `It is`.
- Output is never rescanned, so one replacement cannot trigger another.
- Whitespace, including newlines and tabs, is kept as it was.
