;;; whisper-dvr-replacements-test.el --- Tests for whisper-dvr-replacements -*- lexical-binding: t; -*-

;;; Commentary:
;; The shared cases in skills/voice-in-replacements/tests/replacement-cases.tsv are also run by the
;; Python engine in the voice-in-replacements skill, so both
;; implementations stay in agreement.  The remaining tests cover the
;; CSV parser, the tiers, the cache, the commands, and the whisper.el
;; hook.
;;
;; Run with: make test-replacements

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'whisper-dvr-replacements)

(defconst whisper-dvr-replacements-test--dir
  (expand-file-name "skills/voice-in-replacements/tests"
                    (file-name-directory
                            (or load-file-name buffer-file-name default-directory)))
  "Directory that holds the shared fixtures.")

(defun whisper-dvr-replacements-test--path (name)
  "Return the path of the fixture NAME."
  (expand-file-name name whisper-dvr-replacements-test--dir))

(defun whisper-dvr-replacements-test--unescape (s)
  "Turn the escapes \\n and \\t in S into a newline and a tab."
  (replace-regexp-in-string
   "\\\\[nt]" (lambda (m) (if (string= m "\\n") "\n" "\t")) s t t))

(defun whisper-dvr-replacements-test--cases ()
  "Return the shared cases as lists (NAME OPTIONS INPUT EXPECTED)."
  (with-temp-buffer
    (insert-file-contents (whisper-dvr-replacements-test--path "replacement-cases.tsv"))
    (let (cases)
      (dolist (line (split-string (buffer-string) "\n"))
        (unless (or (string-empty-p line) (string-prefix-p "#" line))
          (let ((f (split-string line "\t")))
            (while (< (length f) 4) (setq f (append f (list ""))))
            (push f cases))))
      (nreverse cases))))

(defun whisper-dvr-replacements-test--run-case (options input)
  "Apply the fixture rules to INPUT under the case OPTIONS string."
  (let* ((opts (unless (member options '("" "-")) (split-string options ",")))
         (tiers '(contraction correction))
         (deny (unless (member "nodeny" opts)
                 (whisper-dvr-replacements-test--path "fixture-deny.txt"))))
    (dolist (o opts)
      (when (string-prefix-p "tiers=" o)
        (setq tiers (mapcar #'intern (split-string (substring o 6) "+")))))
    (let ((whisper-dvr-replacements-context (not (member "no-context" opts))))
     (car (whisper-dvr-replacements-apply-string
          (whisper-dvr-replacements-test--unescape input)
          (whisper-dvr-replacements-load
           (list (whisper-dvr-replacements-test--path "fixture-replacements.csv"))
           deny tiers)
          (member "skip-ambiguous" opts)
          "2026-11-01")))))

;;;; Shared cases

(ert-deftest whisper-dvr-replacements-test-shared-cases ()
  "Every case in test/replacement-cases.tsv gives the expected text."
  (dolist (c (whisper-dvr-replacements-test--cases))
    (pcase-let ((`(,name ,options ,input ,expected) c))
      (should (equal (list name (whisper-dvr-replacements-test--run-case options input))
                     (list name (whisper-dvr-replacements-test--unescape expected)))))))

;;;; CSV parsing

(ert-deftest whisper-dvr-replacements-test-csv-quotes ()
  "Quoted fields keep commas, newlines, and doubled quotes."
  (should (equal (whisper-dvr-replacements--parse-csv
                  "a,b\n\"c,d\",\"e\n\"\"f\"\"\"\ng,h")
                 '((1 "a" "b") (2 "c,d" "e\n\"f\"") (4 "g" "h")))))

(ert-deftest whisper-dvr-replacements-test-csv-crlf-and-blank ()
  "Carriage returns are dropped and blank lines are skipped."
  (should (equal (whisper-dvr-replacements--parse-csv "a,b\r\n\r\nc,d\r\n")
                 '((1 "a" "b") (3 "c" "d")))))

(ert-deftest whisper-dvr-replacements-test-read-rows-problems ()
  "Short rows and long rows are reported, and || splits a trigger."
  (let ((res (whisper-dvr-replacements--read-rows
              "# comment\nlonely\nx||y,z\na,b,c\n" "t.csv")))
    (should (equal (car res) '((3 "x" "z") (3 "y" "z") (4 "a" "b"))))
    (should (= (length (cdr res)) 2))))

(ert-deftest whisper-dvr-replacements-test-contractions-header ()
  "The header line of an expand-contractions CSV file is skipped."
  (should (equal (car (whisper-dvr-replacements--read-rows
                       "contraction,expansion\ncan't,cannot\n" "c.csv"))
                 '((2 "can't" "cannot")))))

;;;; Tiers

(ert-deftest whisper-dvr-replacements-test-classify ()
  "Rules land in the expected tiers."
  (should (eq (whisper-dvr-replacements-classify "can't" "cannot") 'contraction))
  (should (eq (whisper-dvr-replacements-classify "settle cassin" "zettelkasten") 'correction))
  (should (eq (whisper-dvr-replacements-classify "expand saxs" "small-angle") 'expansion))
  (should (eq (whisper-dvr-replacements-classify "open pdb" "<open:https://x>") 'action))
  (should (eq (whisper-dvr-replacements-classify "save writing" "<press:cmd-s>") 'action))
  (should (eq (whisper-dvr-replacements-classify "begin day" "a\nb") 'template))
  (should (eq (whisper-dvr-replacements-classify "insert note" "\\note{x}") 'command))
  (should (eq (whisper-dvr-replacements-classify "item 32" "<newline>  \\item") 'command))
  (should (eq (whisper-dvr-replacements-classify "beasley" "W. <w@x.edu>;") 'command))
  (should (eq (whisper-dvr-replacements-classify "stamp" "on <date>") 'correction)))

(ert-deftest whisper-dvr-replacements-test-missing-file ()
  "A missing rule file gives an empty table and a problem message."
  (let ((set (whisper-dvr-replacements-load '("/no/such/file.csv"))))
    (should (= (hash-table-count (whisper-dvr-replacements-set-table set)) 0))
    (should (whisper-dvr-replacements-set-problems set))))

(ert-deftest whisper-dvr-replacements-test-later-file-overrides ()
  "A later rule file overrides an earlier one."
  (let ((extra (make-temp-file "wdr-extra" nil ".csv" "emax,EMACS-OVERRIDE\n")))
    (unwind-protect
        (should (equal (car (whisper-dvr-replacements-apply-string
                             "emax"
                             (whisper-dvr-replacements-load
                              (list (whisper-dvr-replacements-test--path
                                     "fixture-replacements.csv")
                                    extra))))
                       "EMACS-OVERRIDE"))
      (delete-file extra))))

;;;; Options, cache, and commands

(defmacro whisper-dvr-replacements-test--with-options (&rest body)
  "Run BODY with the options pointed at the fixtures and a fresh cache."
  (declare (indent 0))
  `(let ((whisper-dvr-replacements-file
          (whisper-dvr-replacements-test--path "fixture-replacements.csv"))
         (whisper-dvr-replacements-extra-files nil)
         (whisper-dvr-replacements-deny-file
          (whisper-dvr-replacements-test--path "fixture-deny.txt"))
         (whisper-dvr-replacements-tiers '(contraction correction))
         (whisper-dvr-replacements-enabled t)
         (whisper-dvr-replacements-skip-ambiguous 'when-llm)
         (whisper-dvr-replacements-context t)
         (whisper-dvr-replacements-log nil)
         (whisper-dvr-replacements-log-file nil)
         (whisper-dvr-replacements--cache nil))
     ,@body))

(ert-deftest whisper-dvr-replacements-test-no-file-no-change ()
  "Without a rule file the text is returned unchanged."
  (let ((whisper-dvr-replacements-file nil)
        (whisper-dvr-replacements--cache nil))
    (should (equal (whisper-dvr-replacements-apply-string "can't") '("can't")))))

(ert-deftest whisper-dvr-replacements-test-cache-reused ()
  "The rule set is built once and reused while nothing changes."
  (whisper-dvr-replacements-test--with-options
    (let ((a (whisper-dvr-replacements-rule-set))
          (b (whisper-dvr-replacements-rule-set)))
      (should (eq a b))
      (let ((whisper-dvr-replacements-tiers '(contraction)))
        (should-not (eq a (whisper-dvr-replacements-rule-set)))))))

(ert-deftest whisper-dvr-replacements-test-apply-buffer ()
  "The buffer command rewrites the whole buffer."
  (whisper-dvr-replacements-test--with-options
    (with-temp-buffer
      (insert "I can't use emax.\nIt's late.")
      (should (= (whisper-dvr-replacements-apply-buffer) 3))
      (should (equal (buffer-string) "I cannot use Emacs.\nIt is late.")))))

(ert-deftest whisper-dvr-replacements-test-apply-region ()
  "The region command changes only the region."
  (whisper-dvr-replacements-test--with-options
    (with-temp-buffer
      (insert "can't can't can't")
      (transient-mark-mode 1)
      (set-mark 7)
      (goto-char 12)
      (activate-mark)
      (whisper-dvr-replacements-apply-region 7 12)
      (should (equal (buffer-string) "can't cannot can't")))))

(ert-deftest whisper-dvr-replacements-test-apply-region-needs-region ()
  "Calling the region command interactively without a region is an error."
  (whisper-dvr-replacements-test--with-options
    (with-temp-buffer
      (insert "can't")
      (deactivate-mark)
      (should-error (call-interactively #'whisper-dvr-replacements-apply-region)
                    :type 'user-error))))

(ert-deftest whisper-dvr-replacements-test-apply-file ()
  "The file command writes a -replaced copy and leaves the source alone."
  (whisper-dvr-replacements-test--with-options
    (let* ((src (make-temp-file "wdr-notes" nil ".txt" "we can't stop\n"))
           (out (concat (file-name-sans-extension src) "-replaced.txt")))
      (unwind-protect
          (progn
            (should (equal (whisper-dvr-replacements-apply-file src) out))
            (should (equal (with-temp-buffer (insert-file-contents out) (buffer-string))
                           "we cannot stop\n"))
            (should (equal (with-temp-buffer (insert-file-contents src) (buffer-string))
                           "we can't stop\n")))
        (delete-file src)
        (when (file-exists-p out) (delete-file out))))))

(ert-deftest whisper-dvr-replacements-test-log-buffer ()
  "A run is recorded with the raw text."
  (whisper-dvr-replacements-test--with-options
    (let ((whisper-dvr-replacements-log t))
      (when (get-buffer whisper-dvr-replacements--log-buffer)
        (kill-buffer whisper-dvr-replacements--log-buffer))
      (with-temp-buffer
        (insert "can't")
        (whisper-dvr-replacements-apply-buffer))
      (with-current-buffer whisper-dvr-replacements--log-buffer
        (should (string-match-p "can't -> cannot" (buffer-string)))
        (should (string-match-p "#\\+begin_example\ncan't" (buffer-string)))))))

;;;; Integration with whisper.el

(defvar whisper-after-transcription-hook)

(ert-deftest whisper-dvr-replacements-test-hook-applies-to-armed-file ()
  "The hook rewrites the whisper output buffer for the armed file only.
Ambiguous contractions stay when an LLM step follows."
  (whisper-dvr-replacements-test--with-options
    (let ((whisper-after-transcription-hook nil))
      (cl-letf (((symbol-function 'whisper-dvr--current-whisper-input-p)
                 (lambda (f) (equal f (expand-file-name "/dvr/a.mp3")))))
        (should (whisper-dvr-replacements--arm "/dvr/a.mp3" t))
        (should (memq #'whisper-dvr-replacements--transcript-hook
                      whisper-after-transcription-hook))
        (with-temp-buffer
          (insert "I can't say it's emax.")
          (run-hooks 'whisper-after-transcription-hook)
          (should (equal (buffer-string) "I cannot say it's Emacs.")))
        (should-not whisper-after-transcription-hook)
        (whisper-dvr-replacements--arm "/dvr/b.mp3" nil)
        (with-temp-buffer
          (insert "can't")
          (run-hooks 'whisper-after-transcription-hook)
          (should (equal (buffer-string) "can't")))))))

(ert-deftest whisper-dvr-replacements-test-arm-needs-file ()
  "Nothing is armed without a rule file or when disabled."
  (let ((whisper-after-transcription-hook nil)
        (whisper-dvr-replacements-file nil))
    (should-not (whisper-dvr-replacements--arm "/dvr/a.mp3"))
    (should-not whisper-after-transcription-hook))
  (whisper-dvr-replacements-test--with-options
    (let ((whisper-after-transcription-hook nil)
          (whisper-dvr-replacements-enabled nil))
      (should-not (whisper-dvr-replacements--arm "/dvr/a.mp3")))))

(ert-deftest whisper-dvr-replacements-test-apply-for-llm ()
  "Text for the LLM commands is replaced and keeps ambiguous forms."
  (whisper-dvr-replacements-test--with-options
    (should (equal (whisper-dvr-replacements-apply-for-llm "I'd say can't")
                   "I'd say cannot"))
    (let ((whisper-dvr-replacements-before-llm-commands nil))
      (should (equal (whisper-dvr-replacements-apply-for-llm "can't") "can't")))))

(ert-deftest whisper-dvr-replacements-test-prepare-region-for-llm ()
  "The region is rewritten before an LLM run and the new end is returned."
  (whisper-dvr-replacements-test--with-options
    (with-temp-buffer
      (insert "x can't I'd y")
      (let ((end (whisper-dvr-replacements-prepare-region-for-llm 3 12)))
        (should (equal (buffer-string) "x cannot I'd y"))
        (should (= end 13))
        (should (equal (buffer-substring 3 end) "cannot I'd"))))))

(ert-deftest whisper-dvr-replacements-test-llm-note ()
  "The LLM note appears only when replacements are active."
  (whisper-dvr-replacements-test--with-options
    (should (stringp (whisper-dvr-replacements-llm-note)))
    (let ((whisper-dvr-replacements-enabled nil))
      (should-not (whisper-dvr-replacements-llm-note)))))

(provide 'whisper-dvr-replacements-test)
;;; whisper-dvr-replacements-test.el ends here
