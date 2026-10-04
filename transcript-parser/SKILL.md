---
name: transcript-parser
description: >
  Parse a raw audio transcript into structured LaTeX with topic-based
  \subsubsection blocks, \index keys, grammar correction, contraction
  expansion, sound-description removal, and a TODO checklist.
  Use this skill when the user asks to "parse a transcript",
  "convert a transcript to LaTeX", "clean up a transcript",
  "format my transcript with index keys", or
  "extract TODO items from a transcript".
version: 0.1.0
---

# Transcript Parser Skill

Parse a raw audio transcript into a structured LaTeX fragment. The
output uses \subsubsection headings per topic, \index keys below each
heading, one sentence per line, expanded contractions, corrected
grammar, and a trailing LaTeX itemized list of TODO items rendered as
unchecked boxes.

## Input

Accept a file path to the transcript file as the argument, or accept
the transcript text directly when pasted into the conversation. When a
file path is given, read the file using the Read tool. When text is
pasted inline, process it directly.

## Processing Steps

Apply these steps in the order given.

### 1. Remove Sound Descriptions

Remove every parenthetical that describes a non-speech sound or
ambient cue. The following list is the canonical set, and any
similar parenthetical should be removed by the same rule:

- (wind blowing)
- (gunshots)
- (foot steps)
- (train rumbling)
- (guns firing)
- (coughing)
- (sighing)
- (whistling)
- (dramatic music)
- (waves crashing)
- (air whooshing)
- (car engine rumbling)
- (clearing throat)
- (music)
- (dog barking)
- (lips smacking)
- (metal clanking)
- (wind howling)
- (thunder rumbling)
- (sighs)

Apply the same removal to any other parenthetical that describes
ambient noise, a sound effect, or a non-verbal audio cue rather than
spoken content. Do not remove parentheticals that carry semantic
content the speaker actually said.

### 2. Expand English Contractions

Replace every English contraction with its full expansion. The
following list is illustrative, not exhaustive.

- do not, cannot, will not, would not, should not, could not
- is not, are not, was not, were not, has not, have not, had not
- I am, I have, I will, I would or I had (use context)
- we are, we have, we will
- they are, they have, they will
- you are, you have, you will
- he is or he has (use context)
- she is or she has (use context)
- it is or it has (use context)
- that is or that has (use context)
- there is or there has (use context)
- who is or who has (use context)
- what is or what has (use context)
- let us, here is

Resolve ambiguous contractions such as it's, he's, that's by reading
the surrounding sentence.

### 3. Correct Grammar

Fix grammatical errors throughout the transcript. Enforce
subject-verb agreement, proper tense, and correct word choice. Replace
"since" with "because" whenever "since" is used to indicate causation.
Reserve "since" for temporal contexts. Repair filler-driven run-on
sentences without changing the speaker's meaning.

### 4. Parse into Paragraphs and Topic Sections

Identify distinct topics in the transcript. Group related content
into paragraphs. Create one LaTeX \subsubsection heading for each
topic. Write one sentence per line within each paragraph. Separate
paragraphs with a single blank line.

### 5. Add Index Keys

Below each \subsubsection heading insert \index entries for the
relevant key terms and phrases. Write one \index per line, in this
format:

```latex
\subsubsection{Topic Name}
\index{keyword one}
\index{keyword two}
\index{key phrase}
```

Choose index terms that a reader would look up. Favor proper nouns,
technical terms, concepts, methods, and significant phrases the
speaker discussed.

### 6. Extract TODO Items

Identify every action item, task, or thing the speaker marked as
needing to be done. Collect them into a LaTeX itemized list at the
end of the output using this exact format. The first line of the
list must be the one shown, and the list must be closed with
\end{itemize}.

```latex
\begin{itemize}[label=\unchecked]
\item First TODO item.
\item Second TODO item.
\item Third TODO item.
\end{itemize}
```

### 7. Format the Final Output

Return the processed text as LaTeX with the following constraints.

- No preamble. Do not emit \documentclass or any \usepackage line.
- No \begin{document} or \end{document}.
- One sentence per line.
- Index keys one per line, in \index{<keyword or phrase>} form.
- The TODO list comes last.

The expected shape of the output is:

```latex
\subsubsection{First Topic}
\index{keyword}
\index{another keyword}

First sentence of first paragraph.
Second sentence of first paragraph.

First sentence of second paragraph.

\subsubsection{Second Topic}
\index{keyword}

Content sentences, one per line.

\begin{itemize}[label=\unchecked]
\item Task one.
\item Task two.
\end{itemize}
```

## Output

When the input was a file path, write the processed LaTeX to a new
file in the same directory as the input file, appending
`_parsed.tex` before the extension. For example, if the input is
`meeting_notes.txt`, write `meeting_notes_parsed.tex`. Then present
the output file path to the user.

When the input was pasted inline, return the processed LaTeX in the
chat response directly, without writing a file, unless the user
explicitly asks for a file.

## Conventions

- Do not use em-dashes.
- Do not join independent phrases with a colon.
- Prefer "because" over "since" for causation.
- Expand all English contractions, including those that appear in
  paraphrases of what the speaker said.
