;;; whisper-dvr-replacements.el --- Voice-In Plus text replacements for whisper-dvr -*- lexical-binding: t; -*-

;; Author: Blaine Mooers <blaine-mooers@ou.edu>
;; Maintainer: Blaine Mooers <blaine-mooers@ou.edu>
;; URL: https://github.com/MooersLab/whisper-dvr
;; Keywords: multimedia, convenience, wp
;; Package-Requires: ((emacs "27.1"))
;; Version: 0.8.0

;;; Commentary:
;; This library applies a table of text replacements to prose.  The
;; table is the two-column CSV that Voice-In Plus exports, with the
;; trigger in the first column and the replacement in the second.
;;
;; A Voice-In table mixes three kinds of rules.  Some fix words that
;; speech recognition mishears, some expand contractions, and many are
;; dictation commands that paste templates, open web pages, or press
;; keys.  Only the first two kinds are safe on a transcript, because a
;; recording contains whatever was said, not deliberate commands.  So
;; every rule is sorted into a tier, and only the tiers named in
;; `whisper-dvr-replacements-tiers' are applied.  A deny list removes
;; individual triggers that are ordinary English words, such as
;; "may" or "riding".
;;
;; The matcher walks the text one word at a time and tries the
;; longest trigger first, like reading with a phrase book open.  It
;; never rescans its own output, so one replacement cannot trigger
;; another.  Whitespace and surrounding punctuation are kept.
;;
;; whisper-dvr calls this library between whisper.el and the LLM.
;; The same rules can be applied to any text with the commands
;; `whisper-dvr-replacements-apply-region',
;; `whisper-dvr-replacements-apply-buffer', and
;; `whisper-dvr-replacements-apply-file'.
;;
;; The algorithm matches scripts/replacements_engine.py in the
;; voice-in-replacements Claude skill.  Both implementations pass the
;; cases in skills/voice-in-replacements/tests/replacement-cases.tsv.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(declare-function whisper-dvr--current-whisper-input-p "whisper-dvr" (file))

;;;; Customization

(defgroup whisper-dvr-replacements nil
  "Voice-In Plus text replacements applied to transcripts."
  :group 'whisper-dvr
  :prefix "whisper-dvr-replacements-")

(defcustom whisper-dvr-replacements-enabled t
  "If non-nil, apply text replacements to new DVR transcripts.
Nothing happens until `whisper-dvr-replacements-file' names a rule file."
  :type 'boolean
  :group 'whisper-dvr-replacements)

(defcustom whisper-dvr-replacements-file nil
  "Path to the two-column CSV exported from Voice-In Plus, or nil.
Each row holds a trigger and its replacement.  Lines whose first field
starts with # are comments."
  :type '(choice (const :tag "None" nil) file)
  :group 'whisper-dvr-replacements)

(defcustom whisper-dvr-replacements-extra-files nil
  "Further rule files read after `whisper-dvr-replacements-file'.
A later file overrides an earlier one.  A good order is the
contractions.csv table from expand-contractions.el, which fixes several
Voice-In contraction rules, followed by a file of errors that only
Whisper makes."
  :type '(repeat file)
  :group 'whisper-dvr-replacements)

(defcustom whisper-dvr-replacements-deny-file nil
  "File of triggers that must never fire, one per line, or nil.
Text after # on a line is a comment."
  :type '(choice (const :tag "None" nil) file)
  :group 'whisper-dvr-replacements)

(defcustom whisper-dvr-replacements-tiers '(contraction correction)
  "Tiers of rules that are applied.
`contraction' expands contractions such as can't.  `correction' fixes
misheard words and proper nouns.  `expansion' expands spoken
abbreviations whose trigger starts with a cue word such as \"expand\".
Command, action, and template rules are never applied to prose."
  :type '(set (const contraction) (const correction) (const expansion))
  :group 'whisper-dvr-replacements)

(defcustom whisper-dvr-replacements-skip-ambiguous 'when-llm
  "Whether to leave ambiguous contractions such as I'd and it's alone.
These can mean had or would, is or has, and some are possessives.
The value `when-llm' leaves them for the LLM when post-processing runs
and expands them otherwise.  t always leaves them, nil never does."
  :type '(choice (const :tag "Leave them when the LLM runs" when-llm)
                 (const :tag "Always leave them" t)
                 (const :tag "Always expand them" nil))
  :group 'whisper-dvr-replacements)

(defcustom whisper-dvr-replacements-context t
  "If non-nil, read contractions ending in \='s and \='d from the next word.
These rules come from expand-contractions.el.  A \='s contraction that
expands to \"X is\" becomes \"X has\" before a word in
`whisper-dvr-replacements-has-triggers'.  A \='d contraction becomes
\"X had\" before a past participle and \"X would\" otherwise, so
\"I'd like\" gives \"I would like\" and \"I'd gone\" gives \"I had gone\"."
  :type 'boolean
  :group 'whisper-dvr-replacements)

(defcustom whisper-dvr-replacements-has-triggers
  '("been" "got" "gotten" "had")
  "Words after a \='s contraction that select \"has\" instead of \"is\"."
  :type '(repeat string)
  :group 'whisper-dvr-replacements)

(defcustom whisper-dvr-replacements-had-triggers
  '("been" "better" "become" "begun" "beaten" "bitten" "bought" "broken"
    "brought" "built" "caught" "chosen" "done" "drawn" "driven" "drunk"
    "eaten" "fallen" "felt" "flown" "forgiven" "forgotten" "fought"
    "found" "frozen" "given" "gone" "got" "gotten" "grown" "had" "heard"
    "held" "hidden" "kept" "known" "left" "lost" "made" "meant" "met"
    "ridden" "risen" "said" "seen" "sent" "shown" "slept" "sold" "spent"
    "spoken" "stolen" "stood" "sung" "swum" "sworn" "taken" "taught"
    "thought" "thrown" "told" "torn" "understood" "woken" "worn"
    "written")
  "Words after a \='d contraction that select \"had\" instead of \"would\".
Regular past participles ending in -ed also select \"had\" unless they
are listed in `whisper-dvr-replacements-ed-base-verbs'."
  :type '(repeat string)
  :group 'whisper-dvr-replacements)

(defcustom whisper-dvr-replacements-ed-base-verbs
  '("bleed" "breed" "embed" "exceed" "feed" "heed" "need" "proceed"
    "seed" "shed" "shred" "speed" "succeed" "wed")
  "Base verbs that end in -ed and therefore do not signal \"had\"."
  :type '(repeat string)
  :group 'whisper-dvr-replacements)

(defcustom whisper-dvr-replacements-skippable-words
  '("all" "already" "also" "always" "certainly" "definitely" "ever"
    "just" "nearly" "never" "not" "now" "only" "probably" "really"
    "recently" "still" "surely" "then")
  "Adverbs skipped when looking for the word that resolves a contraction.
In \"I'd never seen\" the word \"never\" is skipped and \"seen\" selects
\"had\"."
  :type '(repeat string)
  :group 'whisper-dvr-replacements)

(defcustom whisper-dvr-replacements-log t
  "If non-nil, record each run in the buffer *whisper-dvr-replacements*.
The record holds the raw text and every replacement made."
  :type 'boolean
  :group 'whisper-dvr-replacements)

(defcustom whisper-dvr-replacements-log-file nil
  "File that each run is appended to, or nil for no file."
  :type '(choice (const :tag "None" nil) file)
  :group 'whisper-dvr-replacements)

(defcustom whisper-dvr-replacements-date-format "%Y-%m-%d"
  "Format of the date that the <date> code inserts."
  :type 'string
  :group 'whisper-dvr-replacements)

(defcustom whisper-dvr-replacements-before-llm-commands t
  "If non-nil, the LLM region and file commands apply replacements first.
This covers `whisper-dvr-llm-process-region' and
`whisper-dvr-llm-process-file'."
  :type 'boolean
  :group 'whisper-dvr-replacements)

(defcustom whisper-dvr-replacements-llm-note
  "The transcript has already passed through a table of text replacements.  Keep expanded contractions expanded.  Keep LaTeX fragments such as \\emph{...} and $...$ exactly as written.  Any contraction such as I'd or it's that is still present was left for you to resolve from context."
  "Sentence added to the LLM instructions when replacements are active."
  :type 'string
  :group 'whisper-dvr-replacements)

;;;; Constants shared with the Python engine

(defconst whisper-dvr-replacements--lead-chars
  (string-to-list "([{\"“‘")
  "Characters peeled from the front of a word before matching.
The straight apostrophe is absent so that triggers such as \\='cause match.")

(defconst whisper-dvr-replacements--trail-chars
  (string-to-list ".,;:!?)]}\"'”’…")
  "Characters peeled from the end of a word before matching.")

(defconst whisper-dvr-replacements--ws " \t\n\r\f\v"
  "Whitespace characters that separate words.")

(defconst whisper-dvr-replacements--ambiguous
  '("i'd" "you'd" "he'd" "she'd" "it'd" "we'd" "they'd" "that'd" "there'd"
    "who'd" "what'd" "where'd" "how'd" "why'd" "he's" "she's" "it's"
    "that's" "there's" "here's" "what's" "who's" "where's" "how's" "why's"
    "this's" "everyone's" "everybody's" "eerybody's" "everything's"
    "nothing's" "somebody's" "someone's" "something's")
  "Contractions whose meaning depends on context.")

(defconst whisper-dvr-replacements--command-prefixes
  '("insert" "display" "citekey" "cite " "site " "subdex" "subsubdex"
    "project " "limit" "limited" "let me" "lemon" "sheet " "overleaf"
    "email" "priority" "item" "backlink" "footnote" "url " "open "
    "add " "new " "print " "markdown" "mark down" "marked down" "header"
    "head " "headed" "protocol" "list " "define" "explain" "expression"
    "inline" "equation" "python" "read " "write " "show " "return "
    "unpack" "generate" "convert" "extract" "subsection" "sub sub"
    "index " "checklist" "description item" "closing" "bounded"
    "going to" "and it " "then at" "then it" "then that" "when it"
    "time " "timed" "none of" "let it" "cap next" "default case"
    "lower case" "upper case" "sentence case" "capitalize each"
    "new sentence" "horizontal line" "copy selection" "find selection"
    "save " "search" "send mail" "contract example" "abbreviate"
    "example given" "id est" "github " "funding" "edit " "bash " "c-"
    "control " "meta " "value of" "how " "what " "do i " "who "
    "creator" "founder" "original developer" "originator" "benevolent"
    "developer of" "author of" "editor for" "expert" "runs " "inset "
    "begin day" "old begin" "start " "today" "to be done" "to do"
    "ranked" "prioritized" "add checkbox" "anchor" "definition list"
    "nested" "navigation" "ordered list" "unordered list" "task list"
    "table " "verbatim" "tiny note" "annot" "a note" "potential slide"
    "slide " "section " "transcript latex" "org mode cheat"
    "org-mode cheat" "emax commands" "confidential"
    "writing commitments" "dsw " "cryo em index" "emacs index" "mint "
    "makdown" "run " "hypperef" "introduction template"
    "project template")
  "Trigger prefixes that mark dictation commands.")

(defconst whisper-dvr-replacements--code-regexp
  (concat "<\\(newline ?\\|newlne\\|capitalize\\|insertspace\\|date\\|enter\\|"
          "default\\|case:\\(lower\\|upper\\|capitalize\\|sentence\\|default\\|normal\\)\\)>")
  "Voice-In codes that are removed after rendering.")

;;;; Rule sets

(cl-defstruct (whisper-dvr-replacements-set
               (:constructor whisper-dvr-replacements--make-set)
               (:copier nil))
  "A compiled table of replacements."
  (table (make-hash-table :test #'equal))
  (max-len 1)
  rules
  problems)

(defvar whisper-dvr-replacements--cache nil
  "Cons of (SIGNATURE . SET) for the rule set built from the options.")

;;;; Reading CSV files

(defun whisper-dvr-replacements--parse-csv (text)
  "Parse TEXT as RFC 4180 CSV.
Return a list of (LINE . FIELDS), where LINE is the line on which the
row starts.  Quoted fields may hold commas, newlines, and doubled
quotes."
  (let ((i 0) (n (length text)) (line 1) (row-line 1)
        (chars nil) (fields nil) (in-quotes nil) (rows nil))
    (cl-flet ((end-field ()
                (push (apply #'string (nreverse chars)) fields)
                (setq chars nil))
              (end-row ()
                (unless (and (= (length fields) 1) (string-empty-p (car fields)))
                  (push (cons row-line (nreverse fields)) rows))
                (setq fields nil)))
      (while (< i n)
        (let ((c (aref text i)))
          (cond
           (in-quotes
            (cond
             ((and (eq c ?\") (< (1+ i) n) (eq (aref text (1+ i)) ?\"))
              (push ?\" chars)
              (setq i (1+ i)))
             ((eq c ?\") (setq in-quotes nil))
             (t (when (eq c ?\n) (setq line (1+ line)))
                (push c chars))))
           ((eq c ?\") (setq in-quotes t))
           ((eq c ?,) (end-field))
           ((eq c ?\r) nil)
           ((eq c ?\n)
            (end-field)
            (end-row)
            (setq line (1+ line) row-line line))
           (t (push c chars))))
        (setq i (1+ i)))
      (when (or chars fields)
        (end-field)
        (end-row)))
    (nreverse rows)))

(defun whisper-dvr-replacements--read-rows (text source)
  "Return (ROWS . PROBLEMS) from the Voice-In CSV TEXT.
Each row is a list (LINE TRIGGER REPLACEMENT).  SOURCE names the file
in problem messages.  A trigger that lists alternatives separated by
|| becomes one row per alternative."
  (let (rows problems)
    (dolist (row (whisper-dvr-replacements--parse-csv text))
      (let ((line (car row)) (fields (cdr row)))
        (cond
         ((string-empty-p (string-trim (mapconcat #'identity fields ""))) nil)
         ((string-prefix-p "#" (string-trim-left (car fields))) nil)
         ;; The header of an expand-contractions CSV file.
         ((and (= line 1) (string= (downcase (string-trim (car fields))) "contraction"))
          nil)
         ((< (length fields) 2)
          (push (format "%s:%d: row has one field" source line) problems))
         (t
          (when (> (length fields) 2)
            (push (format "%s:%d: row has %d fields, extra ignored"
                          source line (length fields))
                  problems))
          (dolist (trig (split-string (car fields) "||"))
            (push (list line trig (cadr fields)) rows))))))
    (cons (nreverse rows) (nreverse problems))))

;;;; Words and triggers

(defun whisper-dvr-replacements--peel (token)
  "Split TOKEN into a list (LEAD CORE TRAIL) of punctuation and word."
  (let ((i 0) (j (length token)))
    (while (and (< i j) (memq (aref token i) whisper-dvr-replacements--lead-chars))
      (setq i (1+ i)))
    (while (and (> j i) (memq (aref token (1- j)) whisper-dvr-replacements--trail-chars))
      (setq j (1- j)))
    (list (substring token 0 i) (substring token i j) (substring token j))))

(defun whisper-dvr-replacements--normalize-core (text)
  "Lowercase TEXT and map curly apostrophes to straight ones."
  (downcase (replace-regexp-in-string "[‘’]" "'" text t t)))

(defun whisper-dvr-replacements--normalize-trigger (trigger)
  "Return the table key for TRIGGER, or the empty string."
  (let (parts)
    (dolist (tok (split-string trigger
                               (concat "[" whisper-dvr-replacements--ws "]+") t))
      (let ((core (nth 1 (whisper-dvr-replacements--peel tok))))
        (unless (string-empty-p core)
          (push (whisper-dvr-replacements--normalize-core core) parts))))
    (mapconcat #'identity (nreverse parts) " ")))

(defun whisper-dvr-replacements--template-hint-p (value)
  "Return non-nil when VALUE carries formatting codes or markup."
  (let ((case-fold-search t))
    (or (string-match-p "<\\(newline\\|capitalize\\|case:\\)\\|\\\\begin\\|@\\|<paste\\|%"
                        value)
        (let ((start 0) found)
          (while (and (not found)
                      (string-match "<\\([a-z]+\\)\\([ >]\\)" value start))
            (unless (and (member (downcase (match-string 1 value))
                                 '("date" "insertspace"))
                         (equal (match-string 2 value) ">"))
              (setq found t))
            (setq start (1+ (match-beginning 0))))
          found))))

(defun whisper-dvr-replacements-classify (trigger replacement)
  "Return the tier symbol of the rule TRIGGER to REPLACEMENT."
  (let ((key (downcase (string-trim trigger)))
        (case-fold-search t))
    (cond
     ((string-match-p "<\\(open\\|press\\)[:;]\\|<enter>" replacement) 'action)
     ((or (string-match-p "\n" replacement)
          (> (length replacement) 120)
          (string-prefix-p "\\begin" (string-trim replacement)))
      'template)
     ((or (string-prefix-p "\\" key)
          (cl-some (lambda (p) (string-prefix-p p key))
                   whisper-dvr-replacements--command-prefixes))
      'command)
     ((whisper-dvr-replacements--template-hint-p replacement) 'command)
     ((string-match-p (concat "\\`\\(expand\\|fully expand\\|double expand\\|"
                              "triple expand\\|capitalize and expand\\)"
                              "[" whisper-dvr-replacements--ws "]")
                      key)
      'expansion)
     ((and (string-match-p "'" key)
           (not (string-match-p (concat "[" whisper-dvr-replacements--ws "]") key)))
      'contraction)
     (t 'correction))))

;;;; Loading

(defun whisper-dvr-replacements--read-deny (file)
  "Return a hash table of the normalized triggers listed in FILE."
  (let ((deny (make-hash-table :test #'equal)))
    (when (and file (file-readable-p (expand-file-name file)))
      (with-temp-buffer
        (insert-file-contents (expand-file-name file))
        (dolist (raw (split-string (buffer-string) "\n"))
          (unless (string-prefix-p "#" (string-trim-left raw))
            (let ((s (string-trim (car (split-string raw "#")))))
              (unless (string-empty-p s)
                (puthash (whisper-dvr-replacements--normalize-trigger s) t deny)))))))
    deny))

(defun whisper-dvr-replacements-load (files &optional deny-file tiers)
  "Build a rule set from the CSV FILES, skipping triggers in DENY-FILE.
TIERS is a list of tier symbols and defaults to contraction and
correction.  Later files override earlier ones.  Within one file a
repeated trigger keeps its first replacement."
  (let* ((set (whisper-dvr-replacements--make-set))
         (table (whisper-dvr-replacements-set-table set))
         (deny (whisper-dvr-replacements--read-deny deny-file))
         (tiers (or tiers '(contraction correction)))
         rules problems)
    (dolist (file files)
      (when file
        (let ((path (expand-file-name file)))
          (if (not (file-readable-p path))
              (push (format "missing rule file: %s" path) problems)
            (let* ((name (file-name-nondirectory path))
                   (parsed (whisper-dvr-replacements--read-rows
                            (with-temp-buffer
                              (insert-file-contents path)
                              (buffer-string))
                            name))
                   (seen (make-hash-table :test #'equal)))
              (setq problems (append (reverse (cdr parsed)) problems))
              (dolist (row (car parsed))
                (pcase-let* ((`(,line ,trig ,val) row)
                             (key (whisper-dvr-replacements--normalize-trigger trig)))
                  (unless (string-empty-p key)
                    (let ((tier (whisper-dvr-replacements-classify trig val)))
                      (push (list (string-trim trig) val tier name line) rules)
                      (cond
                       ((gethash key seen)
                        (push (format "%s:%d: duplicate trigger '%s'" name line key)
                              problems))
                       (t
                        (puthash key t seen)
                        (if (or (not (memq tier tiers)) (gethash key deny))
                            (remhash key table)
                          (puthash key (cons (string-trim val)
                                             (string-suffix-p "." (string-trim trig)))
                                   table)
                          (setf (whisper-dvr-replacements-set-max-len set)
                                (max (whisper-dvr-replacements-set-max-len set)
                                     (length (split-string key " "))))))))))))))))
    (setf (whisper-dvr-replacements-set-rules set) (nreverse rules)
          (whisper-dvr-replacements-set-problems set) (nreverse problems))
    set))

(defun whisper-dvr-replacements--files ()
  "Return the rule files named by the options."
  (delq nil (cons whisper-dvr-replacements-file
                  (copy-sequence whisper-dvr-replacements-extra-files))))

(defun whisper-dvr-replacements--signature ()
  "Return a signature of the rule files and options for the cache."
  (list (mapcar (lambda (f)
                  (let ((path (expand-file-name f)))
                    (cons path (file-attribute-modification-time
                                (file-attributes path)))))
                (append (whisper-dvr-replacements--files)
                        (and whisper-dvr-replacements-deny-file
                             (list whisper-dvr-replacements-deny-file))))
        whisper-dvr-replacements-tiers))

(defun whisper-dvr-replacements-rule-set ()
  "Return the rule set built from the options, or nil without a rule file.
The set is cached and rebuilt when a file or an option changes."
  (when whisper-dvr-replacements-file
    (let ((sig (whisper-dvr-replacements--signature)))
      (unless (equal sig (car whisper-dvr-replacements--cache))
        (setq whisper-dvr-replacements--cache
              (cons sig (whisper-dvr-replacements-load
                         (whisper-dvr-replacements--files)
                         whisper-dvr-replacements-deny-file
                         whisper-dvr-replacements-tiers))))
      (cdr whisper-dvr-replacements--cache))))

;;;; Matching

(defun whisper-dvr-replacements--render (replacement &optional today)
  "Render the Voice-In codes in REPLACEMENT.
TODAY is the date string for <date> and defaults to the current date."
  (let ((case-fold-search t)
        (s replacement))
    (setq s (replace-regexp-in-string "<insertspace>" " " s t t))
    (setq s (replace-regexp-in-string
             "<date>"
             (or today (format-time-string whisper-dvr-replacements-date-format))
             s t t))
    (setq s (replace-regexp-in-string "<newline ?>\\|<newlne>" "\n" s t t))
    (replace-regexp-in-string whisper-dvr-replacements--code-regexp "" s t t)))

(defun whisper-dvr-replacements--upper-p (c)
  "Return non-nil when the character C is an uppercase letter."
  (and (/= c (downcase c)) (= c (upcase c))))

(defun whisper-dvr-replacements--lower-p (c)
  "Return non-nil when the character C is a lowercase letter."
  (and (/= c (upcase c)) (= c (downcase c))))

(defun whisper-dvr-replacements--match-case (source replacement)
  "Capitalize REPLACEMENT if the first letter of SOURCE is a capital."
  (if (and (> (length source) 0) (> (length replacement) 0)
           (whisper-dvr-replacements--upper-p (aref source 0))
           (whisper-dvr-replacements--lower-p (aref replacement 0)))
      (concat (upcase (substring replacement 0 1)) (substring replacement 1))
    replacement))

(defun whisper-dvr-replacements--next-word (cores peeled j)
  "Return the first non-skippable word after word J, or nil.
CORES and PEELED are the vectors built by the matcher.  Up to three
words are examined, and punctuation between words ends the search."
  (let ((k (1+ j)) (tries 0) (n (length cores)) word)
    (while (and (< tries 3) (< k n)
                (string-empty-p (nth 2 (aref peeled (1- k))))
                (string-empty-p (nth 0 (aref peeled k)))
                (string-match-p "\\`[[:alpha:]]+\\'" (aref cores k)))
      (if (member (aref cores k) whisper-dvr-replacements-skippable-words)
          (setq k (1+ k) tries (1+ tries))
        (setq word (aref cores k) tries 3)))
    word))

(defun whisper-dvr-replacements--had-word-p (word)
  "Return non-nil when \"had\" is the right reading of \='d before WORD."
  (or (member word whisper-dvr-replacements-had-triggers)
      (and (> (length word) 3)
           (string-suffix-p "ed" word)
           (not (member word whisper-dvr-replacements-ed-base-verbs)))))

(defun whisper-dvr-replacements--disambiguate (key rep word)
  "Choose between is or has and had or would for the contraction KEY.
REP is the rendered replacement and WORD the word that follows, or nil."
  (let ((case-fold-search nil))
    (cond
     ((and (string-suffix-p "'s" key)
           (string-match "\\`\\(.+\\) is\\'" rep))
      (if (member word whisper-dvr-replacements-has-triggers)
          (concat (match-string 1 rep) " has")
        rep))
     ((and (string-suffix-p "'d" key)
           (string-match "\\`\\(.+\\) \\(?:would\\|had\\)\\'" rep))
      (concat (match-string 1 rep)
              (if (and word (whisper-dvr-replacements--had-word-p word))
                  " had"
                " would")))
     (t rep))))

(defun whisper-dvr-replacements--tokenize (text)
  "Return (LEAD-WS . PAIRS) for TEXT.
PAIRS is a vector of (WORD . FOLLOWING-WHITESPACE) conses."
  (let* ((ws whisper-dvr-replacements--ws)
         (lead (progn (string-match (concat "\\`[" ws "]*") text)
                      (match-string 0 text)))
         (pos (length lead))
         (re (concat "\\([^" ws "]+\\)\\([" ws "]*\\)"))
         pairs)
    (while (and (< pos (length text)) (string-match re text pos))
      (push (cons (match-string 1 text) (match-string 2 text)) pairs)
      (setq pos (match-end 0)))
    (cons lead (vconcat (nreverse pairs)))))

(defun whisper-dvr-replacements-apply-string (text &optional set skip-ambiguous today)
  "Apply the rule SET to TEXT and return (NEW-TEXT . HITS).
SET defaults to `whisper-dvr-replacements-rule-set'.  With
SKIP-AMBIGUOUS, contractions such as I'd are left unchanged.  TODAY is
the date string for <date>.  When `whisper-dvr-replacements-context'
is non-nil, \='s and \='d contractions are read from the next word.
Each hit is a list (SOURCE REPLACEMENT
WORD-INDEX).  Without a rule set TEXT is returned unchanged."
  (let ((set (or set (whisper-dvr-replacements-rule-set))))
    (if (not set)
        (cons text nil)
      (let* ((table (whisper-dvr-replacements-set-table set))
             (max-len (whisper-dvr-replacements-set-max-len set))
             (tok (whisper-dvr-replacements--tokenize text))
             (pairs (cdr tok))
             (n (length pairs))
             (peeled (vconcat (mapcar (lambda (p) (whisper-dvr-replacements--peel (car p)))
                                      pairs)))
             (cores (vconcat (mapcar (lambda (p)
                                       (whisper-dvr-replacements--normalize-core (nth 1 p)))
                                     peeled)))
             (out (list (car tok)))
             (hits nil)
             (i 0))
        (while (< i n)
          (let ((len (min max-len (- n i)))
                (matched nil))
            (while (and (> len 0) (not matched))
              (let* ((j (+ i len -1))
                     (ok (and (cl-loop for k from i to j
                                       always (not (string-empty-p (aref cores k))))
                              (cl-loop for k from i below j
                                       always (string-empty-p (nth 2 (aref peeled k))))
                              (cl-loop for k from (1+ i) to j
                                       always (string-empty-p (nth 0 (aref peeled k))))))
                     (key (and ok (mapconcat #'identity
                                             (cl-loop for k from i to j
                                                      collect (aref cores k))
                                             " ")))
                     (entry (and key (gethash key table))))
                (if (or (not entry)
                        (and skip-ambiguous
                             (member key whisper-dvr-replacements--ambiguous)))
                    (setq len (1- len))
                  (let* ((src (mapconcat #'identity
                                         (cl-loop for k from i to j
                                                  collect (nth 1 (aref peeled k)))
                                         " "))
                         (rendered (whisper-dvr-replacements--render (car entry) today))
                         (new (whisper-dvr-replacements--match-case
                               src
                               (if (and whisper-dvr-replacements-context (= i j))
                                   (whisper-dvr-replacements--disambiguate
                                    key rendered
                                    (whisper-dvr-replacements--next-word cores peeled j))
                                 rendered)))
                         (trail (nth 2 (aref peeled j))))
                    (when (and (cdr entry) (string-prefix-p "." trail))
                      (setq trail (substring trail 1)))
                    (push (concat (nth 0 (aref peeled i)) new trail (cdr (aref pairs j)))
                          out)
                    (push (list src new i) hits)
                    (setq i (1+ j) matched t)))))
            (unless matched
              (push (concat (car (aref pairs i)) (cdr (aref pairs i))) out)
              (setq i (1+ i)))))
        (cons (apply #'concat (nreverse out)) (nreverse hits))))))

;;;; Logging

(defconst whisper-dvr-replacements--log-buffer "*whisper-dvr-replacements*"
  "Name of the buffer that records replacement runs.")

(defun whisper-dvr-replacements--log (label raw hits)
  "Record a run on RAW with HITS under the heading LABEL."
  (when (or whisper-dvr-replacements-log whisper-dvr-replacements-log-file)
    (let ((entry
           (with-temp-buffer
             (insert (format "* %s  %s  (%d replacements)\n"
                             (format-time-string "%Y-%m-%d %H:%M") label (length hits)))
             (dolist (h hits)
               (insert (format "- %s -> %s\n" (nth 0 h)
                               (replace-regexp-in-string "\n" "\\\\n" (nth 1 h)))))
             (insert "** Raw text\n#+begin_example\n" raw
                     (if (string-suffix-p "\n" raw) "" "\n")
                     "#+end_example\n")
             (buffer-string))))
      (when whisper-dvr-replacements-log
        (with-current-buffer (get-buffer-create whisper-dvr-replacements--log-buffer)
          (goto-char (point-max))
          (insert entry)))
      (when whisper-dvr-replacements-log-file
        (let ((coding-system-for-write 'utf-8-unix))
          (write-region entry nil (expand-file-name whisper-dvr-replacements-log-file)
                        t 'silent))))))

;;;; Commands

(defun whisper-dvr-replacements--require-set ()
  "Return the current rule set or signal a user error."
  (or (whisper-dvr-replacements-rule-set)
      (user-error "Set `whisper-dvr-replacements-file' to your Voice-In CSV first")))

(defun whisper-dvr-replacements--replace-text (beg end label)
  "Apply the rules to the text between BEG and END in the current buffer.
LABEL names the run in the log.  Return the number of replacements."
  (let* ((set (whisper-dvr-replacements--require-set))
         (raw (buffer-substring-no-properties beg end))
         (res (whisper-dvr-replacements-apply-string
               raw set (eq whisper-dvr-replacements-skip-ambiguous t))))
    (unless (equal raw (car res))
      (save-excursion
        (goto-char beg)
        (delete-region beg end)
        (insert (car res))))
    (whisper-dvr-replacements--log label raw (cdr res))
    (length (cdr res))))

;;;###autoload
(defun whisper-dvr-replacements-apply-region (beg end)
  "Apply the text replacements to the region between BEG and END.
The text may come from anywhere, not only from a DVR transcript.  The
change is a single undo step."
  (interactive
   (if (use-region-p)
       (list (region-beginning) (region-end))
     (user-error "No active region; use `whisper-dvr-replacements-apply-buffer'")))
  (barf-if-buffer-read-only)
  (let ((n (whisper-dvr-replacements--replace-text
            beg end (format "region of %s" (buffer-name)))))
    (deactivate-mark)
    (message "whisper-dvr: %d replacement%s made" n (if (= n 1) "" "s"))
    n))

;;;###autoload
(defun whisper-dvr-replacements-apply-buffer ()
  "Apply the text replacements to the whole current buffer.
When the buffer is narrowed, only the accessible part is changed."
  (interactive)
  (barf-if-buffer-read-only)
  (let ((n (whisper-dvr-replacements--replace-text
            (point-min) (point-max) (format "buffer %s" (buffer-name)))))
    (message "whisper-dvr: %d replacement%s made" n (if (= n 1) "" "s"))
    n))

;;;###autoload
(defun whisper-dvr-replacements-apply-file (file &optional output)
  "Apply the text replacements to FILE and write the result to OUTPUT.
OUTPUT defaults to FILE with -replaced added before the extension, so
notes.txt yields notes-replaced.txt.  FILE itself is never changed.
Return the output file name."
  (interactive "fApply replacements to file: ")
  (let* ((path (expand-file-name file))
         (out (or output
                  (concat (file-name-sans-extension path) "-replaced"
                          (let ((ext (file-name-extension path)))
                            (if ext (concat "." ext) "")))))
         (raw (with-temp-buffer (insert-file-contents path) (buffer-string)))
         (res (whisper-dvr-replacements-apply-string
               raw (whisper-dvr-replacements--require-set)
               (eq whisper-dvr-replacements-skip-ambiguous t))))
    (let ((coding-system-for-write 'utf-8-unix))
      (write-region (car res) nil out nil 'silent))
    (whisper-dvr-replacements--log (format "file %s" path) raw (cdr res))
    (message "whisper-dvr: %d replacements, wrote %s" (length (cdr res)) out)
    out))

;;;###autoload
(defun whisper-dvr-replacements-reload ()
  "Discard the cached rule set so that the next use rereads the files."
  (interactive)
  (setq whisper-dvr-replacements--cache nil)
  (let ((set (whisper-dvr-replacements-rule-set)))
    (message "whisper-dvr: %d replacement rules active"
             (if set (hash-table-count (whisper-dvr-replacements-set-table set)) 0))))

;;;###autoload
(defun whisper-dvr-replacements-show-log ()
  "Display the record of past replacement passes."
  (interactive)
  (display-buffer (get-buffer-create whisper-dvr-replacements--log-buffer)))

;;;###autoload
(defun whisper-dvr-replacements-audit ()
  "Show tier counts, active rule count, and data problems in a buffer.
Use the voice-in-replacements skill script audit_rules.py to propose
deny-list entries from word frequencies."
  (interactive)
  (let* ((set (whisper-dvr-replacements--require-set))
         (counts (make-hash-table)))
    (dolist (r (whisper-dvr-replacements-set-rules set))
      (cl-incf (gethash (nth 2 r) counts 0)))
    (with-current-buffer (get-buffer-create "*whisper-dvr-replacements-audit*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "#+TITLE: Text replacement audit\n\n* Tiers\n")
        (dolist (tier '(contraction correction expansion command action template))
          (insert (format "- %-12s %5d%s\n" tier (gethash tier counts 0)
                          (if (memq tier whisper-dvr-replacements-tiers) "  (applied)" ""))))
        (insert (format "\nActive rules after the deny list: %d\n"
                        (hash-table-count (whisper-dvr-replacements-set-table set))))
        (insert "\n* Data problems\n")
        (dolist (p (whisper-dvr-replacements-set-problems set))
          (insert "- " p "\n")))
      (when (fboundp 'org-mode) (org-mode))
      (goto-char (point-min))
      (display-buffer (current-buffer)))))

;;;; Integration with whisper-dvr and whisper.el

(defvar whisper-dvr-replacements--armed-file nil
  "Audio file whose transcript receives the replacements.")

(defvar whisper-dvr-replacements--armed-llm nil
  "Non-nil when LLM post-processing follows the armed transcription.")

(defun whisper-dvr-replacements-llm-note ()
  "Return the note for the LLM instructions, or nil when inactive."
  (and whisper-dvr-replacements-enabled
       whisper-dvr-replacements-file
       (not (string-empty-p whisper-dvr-replacements-llm-note))
       whisper-dvr-replacements-llm-note))

(defun whisper-dvr-replacements--skip-ambiguous-p (llm)
  "Return non-nil when ambiguous contractions should stay.
LLM is non-nil when an LLM step follows."
  (pcase whisper-dvr-replacements-skip-ambiguous
    ('when-llm (and llm t))
    (v v)))

(defun whisper-dvr-replacements--disarm ()
  "Remove the transcription hook and clear the armed state."
  (remove-hook 'whisper-after-transcription-hook
               #'whisper-dvr-replacements--transcript-hook)
  (setq whisper-dvr-replacements--armed-file nil
        whisper-dvr-replacements--armed-llm nil))

(defun whisper-dvr-replacements--arm (audio-file &optional llm-armed)
  "Apply replacements to the coming transcript of AUDIO-FILE.
LLM-ARMED is non-nil when LLM post-processing follows.  The hook runs
at depth 50, before the LLM capture hook at depth 90, so the inserted
text and the text sent to the LLM are the same.  Return non-nil when
armed."
  (whisper-dvr-replacements--disarm)
  (when (and whisper-dvr-replacements-enabled whisper-dvr-replacements-file)
    (setq whisper-dvr-replacements--armed-file (expand-file-name audio-file)
          whisper-dvr-replacements--armed-llm llm-armed)
    (add-hook 'whisper-after-transcription-hook
              #'whisper-dvr-replacements--transcript-hook 50)
    t))

(defun whisper-dvr-replacements--transcript-hook ()
  "Apply the replacements to the whisper output buffer.
This function runs from `whisper-after-transcription-hook'.  A run for
some other file is left alone."
  (let ((file whisper-dvr-replacements--armed-file)
        (llm whisper-dvr-replacements--armed-llm))
    (whisper-dvr-replacements--disarm)
    (when (and file
               (fboundp 'whisper-dvr--current-whisper-input-p)
               (whisper-dvr--current-whisper-input-p file))
      (condition-case err
          (let* ((raw (buffer-substring-no-properties (point-min) (point-max)))
                 (res (whisper-dvr-replacements-apply-string
                       raw nil (whisper-dvr-replacements--skip-ambiguous-p llm))))
            (unless (equal raw (car res))
              (let ((inhibit-read-only t))
                (delete-region (point-min) (point-max))
                (insert (car res))))
            (whisper-dvr-replacements--log
             (format "transcript of %s" (file-name-nondirectory file))
             raw (cdr res)))
        (error
         (message "whisper-dvr: text replacements skipped: %s"
                  (error-message-string err)))))))

(defun whisper-dvr-replacements-apply-for-llm (text)
  "Return TEXT after replacements, for the LLM region and file commands.
Ambiguous contractions are left for the LLM when
`whisper-dvr-replacements-skip-ambiguous' is `when-llm'."
  (if (and whisper-dvr-replacements-before-llm-commands
           whisper-dvr-replacements-enabled
           whisper-dvr-replacements-file)
      (let ((res (whisper-dvr-replacements-apply-string
                  text nil (whisper-dvr-replacements--skip-ambiguous-p t))))
        (whisper-dvr-replacements--log "text sent to the LLM" text (cdr res))
        (car res))
    text))

(defun whisper-dvr-replacements-prepare-region-for-llm (beg end)
  "Apply the replacements between BEG and END before an LLM run.
Return the new end position.  The buffer is left alone when the option
`whisper-dvr-replacements-before-llm-commands' is nil, when no rule
file is set, or when the buffer is read-only."
  (if (and whisper-dvr-replacements-before-llm-commands
           whisper-dvr-replacements-enabled
           whisper-dvr-replacements-file
           (not buffer-read-only))
      (let* ((mend (copy-marker end t))
             (raw (buffer-substring-no-properties beg end))
             (res (whisper-dvr-replacements-apply-string
                   raw nil (whisper-dvr-replacements--skip-ambiguous-p t))))
        (unless (equal raw (car res))
          (save-excursion
            (goto-char beg)
            (delete-region beg end)
            (insert (car res))))
        (whisper-dvr-replacements--log "region sent to the LLM" raw (cdr res))
        (prog1 (marker-position mend) (set-marker mend nil)))
    end))

(provide 'whisper-dvr-replacements)
;;; whisper-dvr-replacements.el ends here
