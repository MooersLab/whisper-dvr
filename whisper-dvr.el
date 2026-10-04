;;; whisper-dvr.el --- Transcribe MP3 files from DVR with whisper.el -*- lexical-binding: t; -*-

;; Author: Blaine Mooers <blaine-mooers@ou.edu>
;; Maintainer: Blaine Mooers <blaine-mooers@ou.edu>
;; URL: https://github.com/MooersLab/whisper-dvr
;; Keywords: multimedia, convenience
;; Package-Requires: ((emacs "27.1") (whisper "0.1"))
;; Version: 0.6.0

;;; Commentary:
;; This package provides functions to list, transcribe, and manage MP3 files
;; from a digital voice recorder using the whisper.el package.
;;
;; Version 0.6.0 adds optional LLM post-processing.  When
;; `whisper-dvr-llm-postprocess' is non-nil, the raw transcript that
;; whisper.el inserts is sent in the background to an LLM that applies
;; the transcript-parser skill.  The structured LaTeX that comes back
;; replaces the raw text in the current buffer.  The LLM may be Claude
;; Code (a harness), the Anthropic API, a local model behind an
;; OpenAI-compatible server such as Ollama, any shell command, or an
;; Emacs Lisp function.  See the `whisper-dvr-llm' customization group.

;;; Code:

(require 'whisper)
(require 'dired)
(require 'cl-lib)
(require 'subr-x)
(require 'json)
(require 'url-parse)
(require 'auth-source)

;; Functions and variables that live in optional or lazily loaded
;; libraries.  These declarations keep the byte compiler quiet without
;; pulling the libraries in when whisper-dvr is loaded.
(declare-function org-read-date "org")
(declare-function notifications-notify "notifications")
(declare-function request "request")
(declare-function request-response-status-code "request")
(declare-function request-response-data "request")
(defvar tramp-ssh-controlmaster-options)
(defvar whisper--marker)

(defgroup whisper-dvr nil
  "Settings for DVR transcription with whisper.el."
  :group 'multimedia
  :prefix "whisper-dvr-")

(defcustom whisper-dvr-directory "/Volumes/IC RECORDER/REC_FILE/FOLDER01"
  "Directory path containing MP3 files from the digital voice recorder.
This path should point to the folder where your DVR stores recordings."
  :type 'directory
  :group 'whisper-dvr)

(defcustom whisper-dvr-sd-card-directory
  "/Volumes/MEMORY CARD/private/SONY/REC_FILE/FOLDER01"
  "Directory path holding the recordings on the removable SD card.
Sony recorders write to \"private/SONY/REC_FILE/FOLDER01\" on the card.
The card mounts under /Volumes/ on macOS, under /media/<user>/ on most
Linux systems, and under a drive letter such as \"E:/\" on Windows, so
edit the leading component of this path to suit the platform.
`whisper-dvr-set-directory-to-sd-card' copies this value into
`whisper-dvr-directory'."
  :type 'directory
  :group 'whisper-dvr)

(defcustom whisper-dvr-internal-memory-directory
  "/Volumes/IC RECORDER/REC_FILE/FOLDER01"
  "Directory path holding the recordings in the built-in memory.
This value is the companion of `whisper-dvr-sd-card-directory' and
supplies the target for `whisper-dvr-set-directory-to-internal-memory'."
  :type 'directory
  :group 'whisper-dvr)

(defcustom whisper-dvr-file-extensions '("mp3" "wav" "m4a")
  "List of audio file extensions to include when listing files."
  :type '(repeat string)
  :group 'whisper-dvr)

(defcustom whisper-dvr-base-directory
  (expand-file-name "whisper-dvr" user-emacs-directory)
  "Local directory that receives recordings copied from elsewhere.
Files pulled from a mobile sync service or from a cloud provider land
here before they are transcribed."
  :type 'directory
  :group 'whisper-dvr)

(defcustom whisper-dvr-recording-regexp
  "\\.\\(?:mp3\\|wav\\|m4a\\|flac\\|ogg\\)\\'"
  "Regexp matching the recordings that automatic transcription collects.
`whisper-dvr--get-files-for-transcription' hands this regexp to
`directory-files-recursively', which matches it against file names
rather than against whole paths."
  :type 'regexp
  :group 'whisper-dvr)

(defcustom whisper-dvr-use-trash t
  "If non-nil, move deleted files to trash instead of permanent deletion.
When nil, files are permanently deleted without recovery option."
  :type 'boolean
  :group 'whisper-dvr)

(defcustom whisper-dvr-old-files-threshold 7
  "Default number of days for considering files as old.
Used by `whisper-dvr-delete-old-files' to determine which files to delete."
  :type 'integer
  :group 'whisper-dvr)

(defcustom whisper-dvr-large-file-threshold (* 10 1024 1024)
  "File size threshold in bytes for considering files as large.
Default is 10MB. Used when filtering files by size."
  :type 'integer
  :group 'whisper-dvr)

(defcustom whisper-dvr-volume-mount-points
  '("/Volumes/SDK" "/Volumes/IC RECORDER" "/Volumes/MEMORY CARD")
  "List of mount points (volumes) to unmount when ejecting the DVR.
On macOS these are paths under /Volumes/.
On Linux these are mount points such as /media/<user>/<label>.
On Windows these are drive letters such as \"E:\" or \"F:\"."
  :type '(repeat string)
  :group 'whisper-dvr)

;;; LLM post-processing settings

(defgroup whisper-dvr-llm nil
  "Optional post-processing of transcripts with a large language model.
The raw whisper transcript is sent to an LLM that applies the
transcript-parser skill and returns structured LaTeX."
  :group 'whisper-dvr
  :prefix "whisper-dvr-llm-")

(defcustom whisper-dvr-llm-postprocess nil
  "If non-nil, send each new transcript to an LLM for post-processing.
The raw transcript is inserted first, exactly as whisper.el produces it.
The LLM then runs in the background, and its result replaces or follows
the raw text according to `whisper-dvr-llm-insert-method'.  A prefix
argument to `whisper-dvr' inverts this setting for a single run.  Use
`whisper-dvr-toggle-llm-postprocess' to flip it interactively."
  :type 'boolean
  :group 'whisper-dvr-llm)

(defcustom whisper-dvr-llm-backend 'claude-code
  "The LLM or harness that runs the transcript-parser skill.
The value is one of these symbols.

  `claude-code'        Claude Code in print mode (claude -p).  The
                       harness loads the skill named by
                       `whisper-dvr-llm-skill-name' from its own skills
                       directory.
  `anthropic'          The Anthropic Messages API, called with curl.
  `openai-compatible'  Any server that offers an OpenAI style chat
                       completions endpoint.  Ollama, the llama.cpp
                       server, LM Studio, vLLM, and OpenAI all qualify,
                       so this choice covers local models.
  `command'            Any shell command that reads the prompt on
                       standard input and writes the answer on standard
                       output.  See `whisper-dvr-llm-command'.
  `function'           An Emacs Lisp function.  See
                       `whisper-dvr-llm-function'.

Every backend except `claude-code' receives the skill text from
`whisper-dvr-llm-skill-file' as its instructions."
  :type '(choice (const :tag "Claude Code CLI (harness)" claude-code)
                 (const :tag "Anthropic Messages API" anthropic)
                 (const :tag "OpenAI-compatible server (Ollama, llama.cpp, LM Studio, vLLM)"
                        openai-compatible)
                 (const :tag "Shell command reading stdin" command)
                 (const :tag "Emacs Lisp function" function))
  :group 'whisper-dvr-llm)

(defcustom whisper-dvr-llm-model nil
  "Name of the model that runs the skill, or nil for the backend default.
For `claude-code' a nil value lets the CLI choose its configured model,
and a string such as \"sonnet\" or \"opus\" is passed with --model.  For
`anthropic' and `openai-compatible' a nil value falls back to the entry
in `whisper-dvr-llm-default-models'.  For `command' the value replaces
every \"%m\" in `whisper-dvr-llm-command'."
  :type '(choice (const :tag "Backend default" nil)
                 (string :tag "Model name"))
  :group 'whisper-dvr-llm)

(defcustom whisper-dvr-llm-default-models
  '((anthropic . "claude-sonnet-5-5")
    (openai-compatible . "llama3.1"))
  "Alist mapping a backend symbol to the model it uses by default.
`whisper-dvr-llm-model' overrides these values when it is non-nil."
  :type '(alist :key-type symbol :value-type string)
  :group 'whisper-dvr-llm)

(defcustom whisper-dvr-llm-api-url nil
  "Endpoint URL for the HTTP backends, or nil for the default.
The default for `anthropic' is https://api.anthropic.com/v1/messages.
The default for `openai-compatible' is the Ollama endpoint
http://localhost:11434/v1/chat/completions.  The llama.cpp server
usually listens on http://localhost:8080/v1/chat/completions, and LM
Studio on http://localhost:1234/v1/chat/completions."
  :type '(choice (const :tag "Backend default" nil)
                 (string :tag "URL"))
  :group 'whisper-dvr-llm)

(defcustom whisper-dvr-llm-api-key nil
  "API key for the HTTP backends.
The value may be a string, a function of no arguments that returns a
string, or nil.  When nil the key comes from the ANTHROPIC_API_KEY or
OPENAI_API_KEY environment variable and then from `auth-source' for the
host of the endpoint URL.  Local servers usually need no key, and the
request then omits the authorization header."
  :type '(choice (const :tag "Environment or auth-source" nil)
                 (string :tag "Key")
                 (function :tag "Function returning the key"))
  :group 'whisper-dvr-llm)

(defcustom whisper-dvr-llm-skill-name "transcript-parser"
  "Name of the skill that processes the transcript.
The `claude-code' backend asks the harness to run the skill with this
name."
  :type 'string
  :group 'whisper-dvr-llm)

(defcustom whisper-dvr-llm-skill-file
  "~/.claude/skills/transcript-parser/SKILL.md"
  "Path to the SKILL.md file that holds the skill instructions.
Backends other than `claude-code' send the body of this file, minus its
YAML front matter, as the system prompt.  When the file is missing,
`whisper-dvr-llm-default-instructions' is used instead."
  :type 'file
  :group 'whisper-dvr-llm)

(defcustom whisper-dvr-llm-default-instructions
  "You convert a raw audio transcript into a structured LaTeX fragment.
Apply these steps in order.
1. Remove every parenthetical that describes a non-speech sound, such as (coughing), (music), or (wind blowing).  Keep parentheticals that hold spoken content.
2. Expand every English contraction, for example do not, cannot, it is.  Resolve ambiguous forms such as it's from context.
3. Correct grammar, subject-verb agreement, tense, and word choice without changing the meaning.  Use because instead of since when the meaning is causal, and keep since for time.  Repair filler-driven run-on sentences.
4. Group the content by topic.  Give each topic a \\subsubsection heading.  Write one sentence per line and separate paragraphs with one blank line.
5. Below each \\subsubsection heading write \\index entries for the key terms, one per line, in the form \\index{term}.
6. Collect every action item the speaker mentioned into a list at the very end, introduced by the line % TODO Items, in the form
\\begin{itemize}[label=\\unchecked]
\\item Task.
\\end{itemize}
Do not emit a preamble, \\documentclass, \\usepackage, \\begin{document}, or \\end{document}.  Do not use em-dashes, and do not join independent clauses with a colon."
  "Instructions used when `whisper-dvr-llm-skill-file' cannot be read.
This text is a condensed copy of the transcript-parser skill."
  :type 'string
  :group 'whisper-dvr-llm)

(defcustom whisper-dvr-llm-claude-program "claude"
  "Name or path of the Claude Code executable for the `claude-code' backend.
Emacs started from the macOS Dock may not inherit the shell PATH, so a
full path such as \"~/.local/bin/claude\" may be needed."
  :type 'string
  :group 'whisper-dvr-llm)

(defcustom whisper-dvr-llm-claude-prompt
  "Use the %s skill to process the raw transcript that arrives on standard input.  Treat the transcript as pasted inline text.  Do not write any files.  Return only the processed LaTeX fragment, with no commentary and no code fences."
  "Prompt passed to claude -p by the `claude-code' backend.
A \"%s\" in the string is replaced by `whisper-dvr-llm-skill-name'."
  :type 'string
  :group 'whisper-dvr-llm)

(defcustom whisper-dvr-llm-claude-args
  '("--output-format" "text" "--allowedTools" "Skill")
  "Extra command line arguments for the `claude-code' backend.
These follow the prompt and the optional --model argument."
  :type '(repeat string)
  :group 'whisper-dvr-llm)

(defcustom whisper-dvr-llm-claude-unset-env '("ANTHROPIC_API_KEY")
  "Environment variables removed before the `claude-code' backend runs.
Claude Code bills an API key whenever ANTHROPIC_API_KEY is set in its
environment, even when you are logged in with a Pro or Max
subscription.  An Emacs that sets this variable for other packages
would then fail with \"Credit balance is too low\".  Removing the
variable makes Claude Code use the subscription login from
claude /login.  Set this option to nil to bill the API key instead."
  :type '(repeat string)
  :group 'whisper-dvr-llm)

(defcustom whisper-dvr-llm-claude-embed-skill nil
  "If non-nil, the `claude-code' backend also embeds the skill text.
The body of `whisper-dvr-llm-skill-file' is then passed with
--append-system-prompt.  Turn this on when the harness on this machine
does not have the skill installed."
  :type 'boolean
  :group 'whisper-dvr-llm)

(defcustom whisper-dvr-llm-command '("ollama" "run" "%m")
  "Command line for the `command' backend, as a list of strings.
The command receives the skill instructions followed by the transcript
on standard input and must print the processed text on standard output.
Every \"%m\" is replaced by `whisper-dvr-llm-model'.  Examples are
\(\"ollama\" \"run\" \"%m\"), (\"llm\" \"-m\" \"%m\"), and
\(\"gemini\" \"-m\" \"%m\")."
  :type '(repeat string)
  :group 'whisper-dvr-llm)

(defcustom whisper-dvr-llm-function nil
  "Function for the `function' backend.
The function is called with four arguments, INSTRUCTIONS, TRANSCRIPT,
CALLBACK, and ERRBACK.  It must eventually call CALLBACK with the
processed text as a string, or ERRBACK with an error message.  The call
may be asynchronous.  This hook makes it easy to route the request
through gptel or ellama."
  :type '(choice (const :tag "None" nil) function)
  :group 'whisper-dvr-llm)

(defcustom whisper-dvr-llm-insert-method 'replace
  "Where the processed transcript goes when the LLM returns.
The value is one of these symbols.

  `replace'  Replace the raw transcript in the buffer with the result.
  `append'   Keep the raw transcript and insert the result after it.
  `buffer'   Show the result in the buffer named by
             `whisper-dvr-llm-output-buffer-name'.
When the raw transcript was edited while the LLM was working, `replace'
falls back to `append' so that no edits are lost."
  :type '(choice (const :tag "Replace raw transcript" replace)
                 (const :tag "Insert after raw transcript" append)
                 (const :tag "Separate buffer" buffer))
  :group 'whisper-dvr-llm)

(defcustom whisper-dvr-llm-output-buffer-name "*whisper-dvr-llm*"
  "Name of the buffer that receives results for the `buffer' method."
  :type 'string
  :group 'whisper-dvr-llm)

(defcustom whisper-dvr-llm-timeout 900
  "Seconds to wait for the LLM before the request is abandoned."
  :type 'integer
  :group 'whisper-dvr-llm)

(defcustom whisper-dvr-llm-max-tokens 16000
  "Maximum number of output tokens requested from the HTTP backends."
  :type 'integer
  :group 'whisper-dvr-llm)

(defcustom whisper-dvr-llm-temperature nil
  "Sampling temperature for the HTTP backends, or nil for the server default."
  :type '(choice (const :tag "Server default" nil) number)
  :group 'whisper-dvr-llm)

(defcustom whisper-dvr-llm-curl-program "curl"
  "Name or path of the curl executable used by the HTTP backends."
  :type 'string
  :group 'whisper-dvr-llm)

(defcustom whisper-dvr-llm-wait-message
  "Please wait, the LLM is parsing the transcript. This step can take several minutes."
  "Message shown in the echo area while the LLM works on a transcript.
The message is shown when the request starts and again a moment later,
because whisper.el clears the echo area when it finishes inserting the
raw transcript.  Set this option to nil to show no message."
  :type '(choice (const :tag "No message" nil) string)
  :group 'whisper-dvr-llm)

(defcustom whisper-dvr-llm-after-process-hook nil
  "Hook run after a processed transcript has been inserted.
Each function receives two arguments, the start and the end positions of
the inserted text, and runs with the receiving buffer current."
  :type 'hook
  :group 'whisper-dvr-llm)

(defun whisper-dvr--list-audio-files ()
  "Return a list of audio files in `whisper-dvr-directory'.
Files are filtered by extensions in `whisper-dvr-file-extensions'."
  (let ((dir (expand-file-name whisper-dvr-directory)))
    (unless (file-directory-p dir)
      (user-error "DVR directory does not exist: %s" dir))
    (let ((pattern (concat "\\."
                           (regexp-opt whisper-dvr-file-extensions)
                           "\\'")))
      (directory-files dir t pattern))))

(defun whisper-dvr--format-file-entry (filepath)
  "Format FILEPATH for display in the completion list.
Shows filename, size, and modification time."
  (let* ((attrs (file-attributes filepath))
         (size (file-size-human-readable (file-attribute-size attrs)))
         (mtime (format-time-string "%Y-%m-%d %H:%M"
                                    (file-attribute-modification-time attrs)))
         (name (file-name-nondirectory filepath)))
    (format "%-40s  %8s  %s" name size mtime)))

(defun whisper-dvr--file-age-days (filepath)
  "Return the age of FILEPATH in days since last modification."
  (let* ((attrs (file-attributes filepath))
         (mtime (file-attribute-modification-time attrs))
         (now (current-time))
         (age-seconds (float-time (time-subtract now mtime))))
    (/ age-seconds 86400.0)))  ; Convert seconds to days

(defun whisper-dvr--filter-files-by-age (files days)
  "Filter FILES to only include those older than DAYS.
Returns a list of file paths."
  (cl-remove-if-not
   (lambda (file)
     (> (whisper-dvr--file-age-days file) days))
   files))

(defun whisper-dvr--filter-files-by-size (files min-size &optional max-size)
  "Filter FILES by size.
MIN-SIZE is the minimum file size in bytes.
MAX-SIZE is the optional maximum file size in bytes.
Returns a list of file paths."
  (cl-remove-if-not
   (lambda (file)
     (let ((size (file-attribute-size (file-attributes file))))
       (and (>= size min-size)
            (or (null max-size) (<= size max-size)))))
   files))

(defun whisper-dvr--filter-files-by-date-range (files start-date end-date)
  "Filter FILES to only include those modified between START-DATE and END-DATE.
Dates should be time values as returned by `encode-time'."
  (cl-remove-if-not
   (lambda (file)
     (let ((mtime (file-attribute-modification-time
                   (file-attributes file))))
       (and (time-less-p start-date mtime)
            (time-less-p mtime end-date))))
   files))

(defun whisper-dvr--delete-file-safely (file)
  "Delete FILE, using trash if `whisper-dvr-use-trash' is non-nil.
Returns t on success, nil on failure.
Displays appropriate message on success or error."
  (condition-case err
      (progn
        (if whisper-dvr-use-trash
            (move-file-to-trash file)
          (delete-file file))
        (message "%s: %s"
                 (if whisper-dvr-use-trash "Moved to trash" "Deleted")
                 (file-name-nondirectory file))
        t)
    (error
     (message "Error %s %s: %s"
              (if whisper-dvr-use-trash "moving to trash" "deleting")
              (file-name-nondirectory file)
              (error-message-string err))
     nil)))

;;;###autoload
(defun whisper-dvr (&optional toggle-llm)
  "List MP3 files from DVR and transcribe selected file with whisper.el.
The transcription is inserted at point in the current buffer.
The current buffer must be writable for this function to proceed.

When `whisper-dvr-llm-postprocess' is non-nil, the raw transcript is
then sent to the LLM chosen by `whisper-dvr-llm-backend', and the
processed LaTeX replaces it.  A prefix argument TOGGLE-LLM inverts
`whisper-dvr-llm-postprocess' for this run only."
  (interactive "P")
  ;; Check if current buffer is writable
  (when buffer-read-only
    (user-error "Current buffer is read-only; cannot insert transcription"))
  (when (not (buffer-file-name))
    (unless (y-or-n-p "Current buffer is not visiting a file. Continue anyway? ")
      (user-error "Aborted")))
  ;; Get list of audio files
  (let* ((files (whisper-dvr--list-audio-files))
         (file-alist (mapcar (lambda (f)
                               (cons (whisper-dvr--format-file-entry f) f))
                             files)))
    (unless files
      (user-error "No audio files found in %s" whisper-dvr-directory))
    ;; Present selection with completion
    (let* ((selection (completing-read
                       (format "Select audio file (%d available): " (length files))
                       file-alist
                       nil t))
           (selected-file (cdr (assoc selection file-alist))))
      (message "Transcribing %s with whisper..."
               (file-name-nondirectory selected-file))
      (when (if toggle-llm
                (not whisper-dvr-llm-postprocess)
              whisper-dvr-llm-postprocess)
        (whisper-dvr--llm-arm selected-file))
      ;; Call whisper-run with the selected file
      (whisper-run selected-file))))

;;;###autoload
(defun whisper-dvr-transcribe-file (file)
  "Transcribe FILE with whisper.el and return its expanded path.
This is the non-interactive entry point that the batch and the
automatic paths call.  `whisper-dvr-transcribe-complete-hook' runs with
the audio path and the expected transcript path once `whisper-run'
returns.  An interactive call also applies LLM post-processing when
`whisper-dvr-llm-postprocess' is non-nil."
  (interactive "fAudio file to transcribe: ")
  (let ((path (expand-file-name file)))
    (unless (file-readable-p path)
      (user-error "Cannot read audio file: %s" path))
    (when (and whisper-dvr-llm-postprocess
               (called-interactively-p 'interactive))
      (whisper-dvr--llm-arm path))
    (whisper-run path)
    (run-hook-with-args 'whisper-dvr-transcribe-complete-hook
                        path
                        (concat (file-name-sans-extension path) ".txt"))
    path))

;;;###autoload
(defun whisper-dvr-set-directory (dir)
  "Set the DVR directory to DIR interactively."
  (interactive "DSet DVR directory: ")
  (setq whisper-dvr-directory (expand-file-name dir))
  (message "DVR directory set to: %s" whisper-dvr-directory))

(defun whisper-dvr--set-directory-to (dir label &optional save)
  "Point `whisper-dvr-directory' at DIR and report the change.
DIR is expanded before it is stored.  LABEL names the source of the
recordings in the message that is displayed, for example \"SD card\".
When SAVE is non-nil, the value is written with `customize-save-variable'
so that it outlives the current session.  The value is stored even when
DIR is absent, because the card or the recorder is often still
unmounted when the location is chosen; the message then reports that
the volume is not mounted.  Return the expanded path."
  (let ((path (expand-file-name dir)))
    (if save
        (customize-save-variable 'whisper-dvr-directory path)
      (setq whisper-dvr-directory path))
    (message "DVR directory reset to the %s: %s%s%s"
             label
             path
             (if save " (saved)" "")
             (if (file-directory-p path) "" " [volume not mounted]"))
    path))

;;;###autoload
(defun whisper-dvr-set-directory-to-sd-card (&optional save)
  "Reset the DVR directory to the recorder's SD card.
The path is taken from `whisper-dvr-sd-card-directory'.  With a prefix
argument, SAVE is non-nil and the value is stored with
`customize-save-variable' so that the SD card stays the default in later
sessions.  The value is set even when the card is not mounted, so the
command can be run before the recorder is plugged in."
  (interactive "P")
  (whisper-dvr--set-directory-to whisper-dvr-sd-card-directory
                                 "SD card"
                                 save))

;;;###autoload
(defun whisper-dvr-set-directory-to-internal-memory (&optional save)
  "Reset the DVR directory to the recorder's built-in memory.
The path is taken from `whisper-dvr-internal-memory-directory'.  With a
prefix argument, SAVE is non-nil and the value is stored with
`customize-save-variable'.  This command is the counterpart of
`whisper-dvr-set-directory-to-sd-card'."
  (interactive "P")
  (whisper-dvr--set-directory-to whisper-dvr-internal-memory-directory
                                 "internal memory"
                                 save))

;;;###autoload
(defun whisper-dvr-delete-files (&optional no-confirm)
  "Select and delete audio files from the DVR.
Several files can be chosen at once through `completing-read-multiple'.
With prefix argument NO-CONFIRM, skip the confirmation prompt.
Prompts for confirmation before deletion unless NO-CONFIRM is non-nil."
  (interactive "P")
  (unless (boundp 'whisper-dvr-directory)
    (error "Variable whisper-dvr-directory is not defined"))
  (let* ((dvr-dir whisper-dvr-directory)
         (audio-extensions '("wav" "mp3" "m4a" "flac" "ogg"))
         (audio-files (directory-files
                       dvr-dir
                       nil
                       (concat "\\."
                               (regexp-opt audio-extensions)
                               "$")))
         (selected-files (completing-read-multiple
                          "Select files to delete (comma-separated): "
                          audio-files
                          nil t)))
    (if (null selected-files)
        (message "No files selected for deletion")
      (let ((full-paths (mapcar (lambda (f)
                                  (expand-file-name f dvr-dir))
                                selected-files)))
        (when (or no-confirm
                  (yes-or-no-p
                   (format "%s\n%s %d file(s)?"
                           (mapconcat #'identity selected-files ", ")
                           (if whisper-dvr-use-trash
                               "Move to trash"
                             "Permanently delete")
                           (length selected-files))))
          (let ((success-count 0))
            (dolist (file full-paths)
              (when (whisper-dvr--delete-file-safely file)
                (setq success-count (1+ success-count))))
            (message "%s complete. %d of %d file(s) processed successfully."
                     (if whisper-dvr-use-trash "Move to trash" "Deletion")
                     success-count
                     (length selected-files))))))))

;;;###autoload
(defun whisper-dvr-delete-old-files (days &optional no-confirm)
  "Delete audio files from DVR that are older than DAYS days.
Interactively prompts for the number of days.
With prefix argument NO-CONFIRM, skip the confirmation prompt.
Files are moved to trash if `whisper-dvr-use-trash' is non-nil."
  (interactive
   (list (read-number
          (format "Delete files older than how many days? (default %d): "
                  whisper-dvr-old-files-threshold)
          whisper-dvr-old-files-threshold)
         current-prefix-arg))
  (let* ((all-files (whisper-dvr--list-audio-files))
         (old-files (whisper-dvr--filter-files-by-age all-files days))
         (old-file-names (mapcar #'file-name-nondirectory old-files)))
    (if (null old-files)
        (message "No files older than %d days found" days)
      (when (or no-confirm
                (yes-or-no-p
                 (format "%s\n%s %d file(s) older than %d days?"
                         (mapconcat #'identity old-file-names "\n")
                         (if whisper-dvr-use-trash
                             "Move to trash"
                           "Permanently delete")
                         (length old-files)
                         days)))
        (let ((success-count 0))
          (dolist (file old-files)
            (when (whisper-dvr--delete-file-safely file)
              (setq success-count (1+ success-count))))
          (message "%s complete. %d of %d file(s) processed successfully."
                   (if whisper-dvr-use-trash "Move to trash" "Deletion")
                   success-count
                   (length old-files)))))))

;;;###autoload
(defun whisper-dvr-delete-large-files (min-size &optional no-confirm)
  "Delete audio files from DVR larger than MIN-SIZE bytes.
Interactively prompts for the minimum file size in MB.
With prefix argument NO-CONFIRM, skip the confirmation prompt.
Files are moved to trash if `whisper-dvr-use-trash' is non-nil."
  (interactive
   (list (* (read-number "Delete files larger than (MB): " 10)
            1024 1024)
         current-prefix-arg))
  (let* ((all-files (whisper-dvr--list-audio-files))
         (large-files (whisper-dvr--filter-files-by-size all-files min-size))
         (large-file-info (mapcar
                           (lambda (f)
                             (format "%s (%s)"
                                     (file-name-nondirectory f)
                                     (file-size-human-readable
                                      (file-attribute-size
                                       (file-attributes f)))))
                           large-files)))
    (if (null large-files)
        (message "No files larger than %s found"
                 (file-size-human-readable min-size))
      (when (or no-confirm
                (yes-or-no-p
                 (format "%s\n%s %d file(s) larger than %s?"
                         (mapconcat #'identity large-file-info "\n")
                         (if whisper-dvr-use-trash
                             "Move to trash"
                           "Permanently delete")
                         (length large-files)
                         (file-size-human-readable min-size))))
        (let ((success-count 0))
          (dolist (file large-files)
            (when (whisper-dvr--delete-file-safely file)
              (setq success-count (1+ success-count))))
          (message "%s complete. %d of %d file(s) processed successfully."
                   (if whisper-dvr-use-trash "Move to trash" "Deletion")
                   success-count
                   (length large-files)))))))

;;;###autoload
(defun whisper-dvr-delete-by-date-range (start-date end-date &optional no-confirm)
  "Delete audio files from DVR modified between START-DATE and END-DATE.
Dates are prompted for interactively in YYYY-MM-DD format.
With prefix argument NO-CONFIRM, skip the confirmation prompt.
Files are moved to trash if `whisper-dvr-use-trash' is non-nil."
  (interactive
   (list (org-read-date nil t nil "Start date (YYYY-MM-DD): ")
         (org-read-date nil t nil "End date (YYYY-MM-DD): ")
         current-prefix-arg))
  (let* ((all-files (whisper-dvr--list-audio-files))
         (filtered-files (whisper-dvr--filter-files-by-date-range
                          all-files start-date end-date))
         (file-info (mapcar
                     (lambda (f)
                       (format "%s (%s)"
                               (file-name-nondirectory f)
                               (format-time-string
                                "%Y-%m-%d"
                                (file-attribute-modification-time
                                 (file-attributes f)))))
                     filtered-files)))
    (if (null filtered-files)
        (message "No files found between %s and %s"
                 (format-time-string "%Y-%m-%d" start-date)
                 (format-time-string "%Y-%m-%d" end-date))
      (when (or no-confirm
                (yes-or-no-p
                 (format "%s\n%s %d file(s) from %s to %s?"
                         (mapconcat #'identity file-info "\n")
                         (if whisper-dvr-use-trash
                             "Move to trash"
                           "Permanently delete")
                         (length filtered-files)
                         (format-time-string "%Y-%m-%d" start-date)
                         (format-time-string "%Y-%m-%d" end-date))))
        (let ((success-count 0))
          (dolist (file filtered-files)
            (when (whisper-dvr--delete-file-safely file)
              (setq success-count (1+ success-count))))
          (message "%s complete. %d of %d file(s) processed successfully."
                   (if whisper-dvr-use-trash "Move to trash" "Deletion")
                   success-count
                   (length filtered-files)))))))

;;;###autoload
(defun whisper-dvr-clear-all-files (&optional no-confirm)
  "Clear all audio files from the DVR.
Removes every audio file at the top level of `whisper-dvr-directory'.
Audio files are identified by the extensions in
`whisper-dvr-file-extensions'. Only files at the top level are
considered, so subdirectories are not descended into.

Files are moved to trash if `whisper-dvr-use-trash' is non-nil,
otherwise they are deleted permanently. With prefix argument
NO-CONFIRM, skip the confirmation prompt."
  (interactive "P")
  (let* ((all-files (whisper-dvr--list-audio-files))
         (file-names (mapcar #'file-name-nondirectory all-files)))
    (if (null all-files)
        (message "No audio files found in %s" whisper-dvr-directory)
      (when (or no-confirm
                (yes-or-no-p
                 (format "%s\n%s all %d file(s) in %s?"
                         (mapconcat #'identity file-names "\n")
                         (if whisper-dvr-use-trash
                             "Move to trash"
                           "Permanently delete")
                         (length all-files)
                         whisper-dvr-directory)))
        (let ((success-count 0))
          (dolist (file all-files)
            (when (whisper-dvr--delete-file-safely file)
              (setq success-count (1+ success-count))))
          (message "%s complete. %d of %d file(s) processed successfully."
                   (if whisper-dvr-use-trash "Move to trash" "Deletion")
                   success-count
                   (length all-files)))))))

;;; Volume unmounting / safe eject

(defun whisper-dvr--detect-os ()
  "Detect the current operating system.
Returns one of the symbols `darwin', `windows', or `linux'."
  (cond
   ((eq system-type 'darwin) 'darwin)
   ((memq system-type '(windows-nt cygwin ms-dos)) 'windows)
   (t 'linux)))

(defun whisper-dvr--unmount-volume-darwin (mount-point)
  "Unmount MOUNT-POINT on macOS using diskutil.
Returns a cons cell (SUCCESS . MESSAGE)."
  (if (not (file-directory-p mount-point))
      (cons t (format "%s is not mounted (skipped)" mount-point))
    (let ((output (shell-command-to-string
                   (format "diskutil unmount %s 2>&1"
                           (shell-quote-argument mount-point)))))
      (if (string-match-p "Unmount\\|unmounted\\|ejected" output)
          (cons t (format "Unmounted %s" mount-point))
        (cons nil (format "Failed to unmount %s: %s"
                          mount-point (string-trim output)))))))

(defun whisper-dvr--unmount-volume-linux (mount-point)
  "Unmount MOUNT-POINT on Linux using udisksctl or umount.
Returns a cons cell (SUCCESS . MESSAGE)."
  (if (not (file-directory-p mount-point))
      (cons t (format "%s is not mounted (skipped)" mount-point))
    (let* ((use-udisksctl (executable-find "udisksctl"))
           (cmd (if use-udisksctl
                    (format "udisksctl unmount -p $(findmnt -n -o SOURCE %s) 2>&1"
                            (shell-quote-argument mount-point))
                  (format "umount %s 2>&1"
                          (shell-quote-argument mount-point))))
           (output (shell-command-to-string cmd)))
      (if (or (string-match-p "Unmounted\\|unmounted\\|success" output)
              (string= "" (string-trim output)))
          (cons t (format "Unmounted %s" mount-point))
        (cons nil (format "Failed to unmount %s: %s"
                          mount-point (string-trim output)))))))

(defun whisper-dvr--unmount-volume-windows (drive-letter)
  "Unmount DRIVE-LETTER on Windows using PowerShell.
DRIVE-LETTER should be a string like \"E:\" or \"F:\".
Returns a cons cell (SUCCESS . MESSAGE)."
  (let* ((letter (replace-regexp-in-string "[:\\\\]" "" drive-letter))
         (ps-cmd (format
                  "powershell -NoProfile -Command \
\"$vol = Get-Volume -DriveLetter '%s' -ErrorAction SilentlyContinue; \
if ($vol) { \
  $disk = Get-Partition -DriveLetter '%s' | Get-Disk; \
  Write-Output ('Disk ' + $disk.Number); \
  $eject = New-Object -ComObject Shell.Application; \
  $eject.Namespace(17).ParseName('%s:\\').InvokeVerb('Eject'); \
  Start-Sleep -Seconds 2; \
  $vol2 = Get-Volume -DriveLetter '%s' -ErrorAction SilentlyContinue; \
  if (-not $vol2) { Write-Output 'Unmounted' } \
  else { Write-Output 'FailedToUnmount' } \
} else { Write-Output 'NotMounted' }\""
                  letter letter letter letter))
         (output (shell-command-to-string ps-cmd)))
    (cond
     ((string-match-p "Unmounted" output)
      (cons t (format "Ejected %s:\\" letter)))
     ((string-match-p "NotMounted" output)
      (cons t (format "%s:\\ is not mounted (skipped)" letter)))
     (t
      (cons nil (format "Failed to eject %s:\\: %s"
                        letter (string-trim output)))))))

(defun whisper-dvr--unmount-volume (mount-point)
  "Unmount MOUNT-POINT using the appropriate OS-specific method.
Returns a cons cell (SUCCESS . MESSAGE)."
  (let ((os (whisper-dvr--detect-os)))
    (cl-case os
      (darwin  (whisper-dvr--unmount-volume-darwin mount-point))
      (windows (whisper-dvr--unmount-volume-windows mount-point))
      (linux   (whisper-dvr--unmount-volume-linux mount-point))
      (t       (cons nil (format "Unsupported OS: %s" system-type))))))

;;;###autoload
(defun whisper-dvr-eject ()
  "Unmount all DVR volumes listed in `whisper-dvr-volume-mount-points'.
After unmounting, the DVR hardware can be safely removed.
Works on macOS (diskutil), Linux (udisksctl/umount), and
Windows (PowerShell/Shell.Application eject)."
  (interactive)
  (let ((volumes whisper-dvr-volume-mount-points)
        (success-count 0)
        (fail-count 0)
        (messages '()))
    (if (null volumes)
        (user-error "No volumes configured in `whisper-dvr-volume-mount-points'")
      (dolist (vol volumes)
        (let ((result (whisper-dvr--unmount-volume vol)))
          (push (cdr result) messages)
          (if (car result)
              (setq success-count (1+ success-count))
            (setq fail-count (1+ fail-count)))))
      (let ((summary (format "Eject complete: %d succeeded, %d failed.\n%s"
                             success-count fail-count
                             (mapconcat #'identity (nreverse messages) "\n"))))
        (if (zerop fail-count)
            (message "DVR unmounted. Now safe to remove.\n%s" summary)
          (display-warning 'whisper-dvr summary :warning))))))

;;;###autoload
(defun whisper-dvr-dired ()
  "Open the DVR directory in Dired for visual file management.
Mark files with \\[dired-mark], then delete the marked files with
`whisper-dvr-dired-delete-marked'."
  (interactive)
  (let ((dir (expand-file-name whisper-dvr-directory)))
    (unless (file-directory-p dir)
      (user-error "DVR directory does not exist: %s" dir))
    (dired dir)
    (message "Mark files with 'm', then use 'C-c C-d' to delete marked files")))

;;;###autoload
(defun whisper-dvr-dired-delete-marked (&optional no-confirm)
  "Delete marked files in the current Dired buffer.
With prefix argument NO-CONFIRM, skip the confirmation prompt.
Files are moved to trash if `whisper-dvr-use-trash' is non-nil.
This function should be called from a Dired buffer."
  (interactive "P")
  (unless (derived-mode-p 'dired-mode)
    (user-error "This command must be run from a Dired buffer"))
  (let ((marked-files (dired-get-marked-files)))
    (if (null marked-files)
        (message "No files marked for deletion")
      (when (or no-confirm
                (yes-or-no-p
                 (format "%s %d marked file(s)?"
                         (if whisper-dvr-use-trash
                             "Move to trash"
                             "Permanently delete")
                         (length marked-files))))
        (let ((success-count 0))
          (dolist (file marked-files)
            (when (whisper-dvr--delete-file-safely file)
              (setq success-count (1+ success-count))))
          (message "%s complete. %d of %d file(s) processed successfully."
                   (if whisper-dvr-use-trash "Move to trash" "Deletion")
                   success-count
                   (length marked-files))
          (revert-buffer))))))

;; Define key binding for dired-mode
(with-eval-after-load 'dired
  (define-key dired-mode-map (kbd "C-c C-d") #'whisper-dvr-dired-delete-marked))
;;; Advanced feature configuration

(defgroup whisper-dvr-advanced nil
  "Advanced DVR management features."
  :group 'whisper-dvr)

;;; Persistent Cache
(defcustom whisper-dvr-persistent-cache-file
  (expand-file-name "whisper-dvr-cache.el" user-emacs-directory)
  "File path for persistent mount cache storage.
Cache is saved between Emacs sessions for faster startup."
  :type 'file
  :group 'whisper-dvr-advanced)

(defcustom whisper-dvr-enable-persistent-cache t
  "If non-nil, save and restore cache between Emacs sessions."
  :type 'boolean
  :group 'whisper-dvr-advanced)

(defcustom whisper-dvr-cache-auto-save t
  "If non-nil, automatically save cache periodically and on exit."
  :type 'boolean
  :group 'whisper-dvr-advanced)

(defcustom whisper-dvr-cache-save-interval 600
  "Interval in seconds for automatic cache saves.
Only used when `whisper-dvr-cache-auto-save' is non-nil."
  :type 'integer
  :group 'whisper-dvr-advanced)

;;; Background Monitoring
(defcustom whisper-dvr-enable-background-monitoring nil
  "If non-nil, monitor for device insertion and removal events.
Uses platform-specific mechanisms to detect device changes.
Note: This feature may consume system resources."
  :type 'boolean
  :group 'whisper-dvr-advanced)

(defcustom whisper-dvr-monitoring-interval 5
  "Interval in seconds for polling device status.
Lower values provide faster detection but use more resources."
  :type 'integer
  :group 'whisper-dvr-advanced)

(defcustom whisper-dvr-device-connect-hook nil
  "Hook run when a DVR device is detected.
Functions receive device info plist as argument."
  :type 'hook
  :group 'whisper-dvr-advanced)

(defcustom whisper-dvr-device-disconnect-hook nil
  "Hook run when a DVR device is removed.
Functions receive device info plist as argument."
  :type 'hook
  :group 'whisper-dvr-advanced)

;;; Auto-Transcription
(defcustom whisper-dvr-auto-transcribe-on-connect nil
  "If non-nil, automatically transcribe new files when device connects.
Requires `whisper-dvr-enable-background-monitoring' to be enabled."
  :type 'boolean
  :group 'whisper-dvr-advanced)

(defcustom whisper-dvr-auto-transcribe-filter 'new-only
  "Filter for auto-transcription.
The value is one of three symbols.
- new-only, transcribe only the files that were not processed before
- all, transcribe every file on the device
- modified, transcribe the files changed since the last connection"
  :type '(choice (const :tag "New files only" new-only)
                 (const :tag "All files" all)
                 (const :tag "Modified files" modified))
  :group 'whisper-dvr-advanced)

(defcustom whisper-dvr-auto-transcribe-delay 2
  "Delay in seconds before starting auto-transcription.
Allows device to stabilize after connection."
  :type 'integer
  :group 'whisper-dvr-advanced)

(defcustom whisper-dvr-transcription-history-file
  (expand-file-name "whisper-dvr-history.el" user-emacs-directory)
  "File path for transcription history storage."
  :type 'file
  :group 'whisper-dvr-advanced)

;;; Remote DVRs
(defcustom whisper-dvr-remote-devices nil
  "List of remote DVR device configurations.
Each element is a plist with keys:
  :name - Device name
  :protocol - the symbol ssh or the symbol sftp
  :host - Remote hostname or IP
  :port - SSH/SFTP port (default 22)
  :user - Username for authentication
  :path - Remote directory path
  :identity-file - Optional SSH key path
  :password - Optional password (not recommended)"
  :type '(repeat (plist :options ((:name string)
                                  (:protocol symbol)
                                  (:host string)
                                  (:port integer)
                                  (:user string)
                                  (:path string)
                                  (:identity-file file)
                                  (:password string))))
  :group 'whisper-dvr-advanced)

(defcustom whisper-dvr-remote-cache-locally t
  "If non-nil, cache remote files locally before transcription.
Improves performance for remote devices."
  :type 'boolean
  :group 'whisper-dvr-advanced)

(defcustom whisper-dvr-remote-cache-directory
  (expand-file-name "whisper-dvr-remote-cache/" temporary-file-directory)
  "Directory for caching remote DVR files."
  :type 'directory
  :group 'whisper-dvr-advanced)

;;; Mobile Integration
(defcustom whisper-dvr-mobile-sync-enabled nil
  "If non-nil, enable synchronization with mobile DVR apps."
  :type 'boolean
  :group 'whisper-dvr-advanced)

(defcustom whisper-dvr-mobile-sync-service 'dropbox
  "Mobile sync service to use.
The supported values are the symbols dropbox, google-drive, and icloud."
  :type '(choice (const :tag "Dropbox" dropbox)
                 (const :tag "Google Drive" google-drive)
                 (const :tag "iCloud" icloud))
  :group 'whisper-dvr-advanced)

(defcustom whisper-dvr-mobile-sync-folder "/Apps/VoiceRecorder"
  "Folder path in mobile sync service for DVR files."
  :type 'string
  :group 'whisper-dvr-advanced)

(defcustom whisper-dvr-mobile-sync-interval 300
  "Interval in seconds for checking mobile sync folder.
Set to nil to disable automatic checking."
  :type '(choice integer (const :tag "Manual only" nil))
  :group 'whisper-dvr-advanced)

;;; Cloud Storage
(defcustom whisper-dvr-cloud-upload-enabled nil
  "If non-nil, enable automatic cloud storage uploads."
  :type 'boolean
  :group 'whisper-dvr-advanced)

(defcustom whisper-dvr-cloud-providers
  '((dropbox :enabled t :folder "/DVR-Transcripts")
    (google-drive :enabled nil :folder "DVR Transcripts")
    (onedrive :enabled nil :folder "Documents/DVR")
    (s3 :enabled nil :bucket "my-dvr-transcripts" :region "us-east-1"))
  "Cloud storage provider configurations.
Each element is a list: (PROVIDER :key value ...)
Common keys: :enabled, :folder/:bucket, :region (S3 only)"
  :type '(repeat (list symbol (plist)))
  :group 'whisper-dvr-advanced)

(defcustom whisper-dvr-cloud-upload-format 'both
  "Format for cloud uploads.
The value is one of three symbols.
- audio-only, upload the audio files alone
- transcript-only, upload the transcript files alone
- both, upload the audio files and the transcripts"
  :type '(choice (const :tag "Audio only" audio-only)
                 (const :tag "Transcript only" transcript-only)
                 (const :tag "Both" both))
  :group 'whisper-dvr-advanced)

(defcustom whisper-dvr-cloud-upload-on-transcribe t
  "If non-nil, upload to cloud immediately after transcription."
  :type 'boolean
  :group 'whisper-dvr-advanced)

;;; Internationalization
(defcustom whisper-dvr-language 'auto
  "Interface language for whisper-dvr.
The value auto follows the system language.  The other accepted values
are en (English), es (Spanish), fr (French), de (German),
ja (Japanese), zh (Chinese), and ko (Korean)."
  :type '(choice (const :tag "Auto-detect" auto)
                 (const :tag "English" en)
                 (const :tag "Spanish" es)
                 (const :tag "French" fr)
                 (const :tag "German" de)
                 (const :tag "Japanese" ja)
                 (const :tag "Chinese" zh)
                 (const :tag "Korean" ko))
  :group 'whisper-dvr-advanced)

;;; Internal state
(defvar whisper-dvr--monitoring-timer nil
  "Timer for background device monitoring.")

(defvar whisper-dvr--cache-save-timer nil
  "Timer for automatic cache saves.")

(defvar whisper-dvr--connected-devices (make-hash-table :test 'equal)
  "Hash table tracking currently connected devices.")

(defvar whisper-dvr--mount-cache (make-hash-table :test 'equal)
  "Hash table caching the mount state of each DVR directory.
Keys are expanded directory paths and values are the device plists
returned by `whisper-dvr--detect-connected-devices'.")

(defvar whisper-dvr--last-cache-clear nil
  "Time at which `whisper-dvr--mount-cache' was last refreshed.")

(defvar whisper-dvr--transcription-history (make-hash-table :test 'equal)
  "Hash table tracking transcribed files to avoid re-processing.")

(defvar whisper-dvr--current-language nil
  "Currently active language for interface strings.")

(defvar whisper-dvr--remote-connections (make-hash-table :test 'equal)
  "Hash table tracking active remote connections.")


;;; Persistent cache system

(defun whisper-dvr--serialize-cache ()
  "Serialize mount cache to saveable format.
Returns a list suitable for writing to file."
  (let ((serialized '()))
    (maphash
     (lambda (key value)
       (push (cons key value) serialized))
     whisper-dvr--mount-cache)
    serialized))

(defun whisper-dvr--deserialize-cache (data)
  "Restore mount cache from DATA.
DATA should be output from `whisper-dvr--serialize-cache'."
  (clrhash whisper-dvr--mount-cache)
  (dolist (entry data)
    (puthash (car entry) (cdr entry) whisper-dvr--mount-cache))
  (setq whisper-dvr--last-cache-clear (current-time)))

(defun whisper-dvr-save-cache ()
  "Save mount cache to persistent storage."
  (interactive)
  (when whisper-dvr-enable-persistent-cache
    (condition-case err
        (let ((cache-data (whisper-dvr--serialize-cache))
              (history-data (whisper-dvr--serialize-history)))
          (with-temp-file whisper-dvr-persistent-cache-file
            (prin1 (list :version 1
                        :timestamp (current-time)
                        :cache cache-data
                        :history history-data)
                   (current-buffer)))
          (message "Whisper-DVR: Cache saved (%d entries)"
                   (hash-table-count whisper-dvr--mount-cache)))
      (error
       (message "Failed to save whisper-dvr cache: %s"
                (error-message-string err))))))

(defun whisper-dvr-load-cache ()
  "Load mount cache from persistent storage."
  (interactive)
  (when (and whisper-dvr-enable-persistent-cache
             (file-exists-p whisper-dvr-persistent-cache-file))
    (condition-case err
        (with-temp-buffer
          (insert-file-contents whisper-dvr-persistent-cache-file)
          (goto-char (point-min))
          (let ((data (read (current-buffer))))
            (when (and (listp data)
                      (eq (plist-get data :version) 1))
              (whisper-dvr--deserialize-cache (plist-get data :cache))
              (whisper-dvr--deserialize-history (plist-get data :history))
              (message "Whisper-DVR: Cache loaded (%d entries)"
                       (hash-table-count whisper-dvr--mount-cache)))))
      (error
       (message "Failed to load whisper-dvr cache: %s"
                (error-message-string err))))))

(defun whisper-dvr--setup-cache-autosave ()
  "Setup automatic cache saving."
  (when whisper-dvr-cache-auto-save
    ;; Cancel existing timer
    (when whisper-dvr--cache-save-timer
      (cancel-timer whisper-dvr--cache-save-timer))
    ;; Setup periodic save
    (setq whisper-dvr--cache-save-timer
          (run-with-timer whisper-dvr-cache-save-interval
                         whisper-dvr-cache-save-interval
                         #'whisper-dvr-save-cache))
    ;; Save on Emacs exit
    (add-hook 'kill-emacs-hook #'whisper-dvr-save-cache)))

;; Load cache on startup
(add-hook 'after-init-hook #'whisper-dvr-load-cache)
(add-hook 'whisper-dvr-mode-hook #'whisper-dvr--setup-cache-autosave)

  ;;; Background device monitoring

(defun whisper-dvr--notify (title body &optional urgency)
  "Show a desktop notification carrying TITLE and BODY.
URGENCY is one of the symbols low, normal, or critical, and it defaults
to normal.  The D-Bus interface is used where it is available,
AppleScript is used on macOS, and the echo area is the fallback."
  (let ((urgency (or urgency 'normal)))
    (cond
     ((and (eq (whisper-dvr--detect-os) 'linux)
           (require 'notifications nil t))
      (notifications-notify :title title :body body :urgency urgency))
     ((eq (whisper-dvr--detect-os) 'darwin)
      (call-process "osascript" nil 0 nil
                    "-e"
                    (format "display notification %S with title %S"
                            body title)))
     (t
      (message "%s: %s" title body)))))

(defun whisper-dvr--volume-name (directory)
  "Return a readable volume name for DIRECTORY.
On macOS the volume is the first component under /Volumes/.  Elsewhere
the last component of DIRECTORY is used."
  (let* ((dir (directory-file-name (expand-file-name directory)))
         (parts (split-string dir "/" t)))
    (if (and (string-prefix-p "/Volumes/" dir) (cdr parts))
        (nth 1 parts)
      (or (car (last parts)) dir))))

(defun whisper-dvr--invalidate-cache-entry (directory)
  "Drop the cached mount state recorded for DIRECTORY.
DIRECTORY is expanded before the lookup, so it may be given in any form
that `expand-file-name' accepts."
  (when directory
    (remhash (expand-file-name directory) whisper-dvr--mount-cache)))

(defun whisper-dvr--detect-connected-devices ()
  "Return the DVR directories that are mounted at this moment.
Each element is a plist carrying :directory, :volume-name, and
:last-seen.  The candidates are `whisper-dvr-directory',
`whisper-dvr-sd-card-directory',
`whisper-dvr-internal-memory-directory', and every entry in
`whisper-dvr-volume-mount-points'.  Every mounted candidate is recorded
in `whisper-dvr--mount-cache'."
  (let ((candidates (delete-dups
                     (mapcar #'expand-file-name
                             (append
                              (list whisper-dvr-directory
                                    whisper-dvr-sd-card-directory
                                    whisper-dvr-internal-memory-directory)
                              whisper-dvr-volume-mount-points))))
        (devices '()))
    (dolist (dir candidates)
      (when (file-directory-p dir)
        (let ((device (list :directory dir
                            :volume-name (whisper-dvr--volume-name dir)
                            :last-seen (current-time))))
          (puthash dir device whisper-dvr--mount-cache)
          (push device devices))))
    (setq whisper-dvr--last-cache-clear (current-time))
    (nreverse devices)))

(defun whisper-dvr--poll-devices ()
  "Poll for device arrivals and departures, then run the matching hooks."
  (when whisper-dvr-enable-background-monitoring
    (let ((current-devices (whisper-dvr--detect-connected-devices))
          (previous-keys (hash-table-keys whisper-dvr--connected-devices))
          (current-keys '()))

      ;; Check for newly connected devices
      (dolist (device current-devices)
        (let ((key (plist-get device :directory)))
          (push key current-keys)
          (unless (gethash key whisper-dvr--connected-devices)
            ;; New device detected
            (puthash key device whisper-dvr--connected-devices)
            (whisper-dvr--handle-device-connect device))))

      ;; Check for disconnected devices
      (dolist (key previous-keys)
        (unless (member key current-keys)
          ;; Device removed
          (let ((device (gethash key whisper-dvr--connected-devices)))
            (remhash key whisper-dvr--connected-devices)
            (whisper-dvr--handle-device-disconnect device)))))))

(defun whisper-dvr--handle-device-connect (device)
  "Handle connection of DEVICE."
  (let ((name (plist-get device :volume-name)))
    (message "DVR device connected: %s" name)
    (whisper-dvr--notify "DVR Connected"
                        (format "Device '%s' is now available" name)
                        'normal)
    (run-hook-with-args 'whisper-dvr-device-connect-hook device)

    ;; Trigger auto-transcription if enabled
    (when whisper-dvr-auto-transcribe-on-connect
      (run-with-timer whisper-dvr-auto-transcribe-delay nil
                     #'whisper-dvr--auto-transcribe-device device))))

(defun whisper-dvr--handle-device-disconnect (device)
  "Handle disconnection of DEVICE."
  (let ((name (plist-get device :volume-name)))
    (message "DVR device disconnected: %s" name)
    (whisper-dvr--notify "DVR Disconnected"
                        (format "Device '%s' was removed" name)
                        'normal)
    (run-hook-with-args 'whisper-dvr-device-disconnect-hook device)

    ;; Invalidate cache
    (whisper-dvr--invalidate-cache-entry (plist-get device :directory))))

(defun whisper-dvr-start-monitoring ()
  "Start background device monitoring."
  (interactive)
  (when whisper-dvr-enable-background-monitoring
    (unless whisper-dvr--monitoring-timer
      ;; Initial device scan
      (dolist (device (whisper-dvr--detect-connected-devices))
        (puthash (plist-get device :directory) device
                whisper-dvr--connected-devices))
      ;; Start polling timer
      (setq whisper-dvr--monitoring-timer
            (run-with-timer 0 whisper-dvr-monitoring-interval
                          #'whisper-dvr--poll-devices))
      (message "Whisper-DVR: Background monitoring started"))))

(defun whisper-dvr-stop-monitoring ()
  "Stop background device monitoring."
  (interactive)
  (when whisper-dvr--monitoring-timer
    (cancel-timer whisper-dvr--monitoring-timer)
    (setq whisper-dvr--monitoring-timer nil)
    (message "Whisper-DVR: Background monitoring stopped")))

(defun whisper-dvr-toggle-monitoring ()
  "Toggle background device monitoring."
  (interactive)
  (if whisper-dvr--monitoring-timer
      (whisper-dvr-stop-monitoring)
    (whisper-dvr-start-monitoring)))

;; Auto-start monitoring if configured
(when whisper-dvr-enable-background-monitoring
(add-hook 'after-init-hook #'whisper-dvr-start-monitoring))


;;; Automatic transcription system

(defun whisper-dvr--serialize-history ()
  "Serialize transcription history to saveable format."
  (let ((serialized '()))
    (maphash
     (lambda (key value)
       (push (cons key value) serialized))
     whisper-dvr--transcription-history)
    serialized))

(defun whisper-dvr--deserialize-history (data)
  "Restore transcription history from DATA."
  (clrhash whisper-dvr--transcription-history)
  (dolist (entry data)
    (puthash (car entry) (cdr entry) whisper-dvr--transcription-history)))

(defun whisper-dvr--mark-transcribed (file-path)
  "Mark FILE-PATH as transcribed in history."
  (puthash file-path
           (list :timestamp (current-time)
                 :size (file-attribute-size (file-attributes file-path)))
           whisper-dvr--transcription-history))

(defun whisper-dvr--is-transcribed-p (file-path)
  "Check if FILE-PATH has been transcribed.
Returns non-nil if file is in history and unchanged."
  (let ((history (gethash file-path whisper-dvr--transcription-history)))
    (when history
      (let ((recorded-size (plist-get history :size))
            (current-size (file-attribute-size (file-attributes file-path))))
        (= recorded-size current-size)))))

(defun whisper-dvr--get-files-for-transcription (device)
  "Get list of files from DEVICE that should be transcribed.
Filters based on `whisper-dvr-auto-transcribe-filter'."
  (let* ((directory (plist-get device :directory))
         (all-files (directory-files-recursively
                    directory
                    whisper-dvr-recording-regexp)))
    (cl-case whisper-dvr-auto-transcribe-filter
      (new-only
       (cl-remove-if #'whisper-dvr--is-transcribed-p all-files))
      (modified
       (let ((last-connect (plist-get
                           (gethash directory whisper-dvr--connected-devices)
                           :last-seen)))
         (cl-remove-if
          (lambda (file)
            (and (whisper-dvr--is-transcribed-p file)
                 (time-less-p (file-attribute-modification-time
                             (file-attributes file))
                            last-connect)))
          all-files)))
      (all all-files)
      (t '()))))

(defun whisper-dvr--auto-transcribe-device (device)
  "Automatically transcribe files from DEVICE."
  (let ((files (whisper-dvr--get-files-for-transcription device))
        (name (plist-get device :volume-name)))
    (if (null files)
        (message "No new files to transcribe on %s" name)
      (message "Auto-transcribing %d file(s) from %s..." (length files) name)
      (whisper-dvr--notify "Auto-Transcription Started"
                          (format "Processing %d file(s) from %s"
                                  (length files) name)
                          'normal)
      (whisper-dvr--transcribe-batch files device))))

(defun whisper-dvr--transcribe-batch (files device)
  "Transcribe the batch of FILES taken from DEVICE, reporting progress."
  (let ((total (length files))
        (completed 0)
        (failed 0))
    (dolist (file files)
      (condition-case err
          (progn
            (whisper-dvr-transcribe-file file)
            (whisper-dvr--mark-transcribed file)
            (setq completed (1+ completed))
            (message "Transcribed %d/%d: %s" completed total
                    (file-name-nondirectory file)))
        (error
         (setq failed (1+ failed))
         (message "Failed to transcribe %s: %s"
                 (file-name-nondirectory file)
                 (error-message-string err)))))

    ;; Final notification
    (whisper-dvr--notify
     "Auto-Transcription Complete"
     (format "%s: completed %d, failed %d"
             (or (plist-get device :volume-name) "DVR")
             completed failed)
     (if (zerop failed) 'normal 'critical))

    ;; Save history
    (whisper-dvr-save-cache)))

(defun whisper-dvr-manual-transcribe-new ()
  "Manually trigger transcription of new files on all connected devices."
  (interactive)
  (let ((devices (whisper-dvr--detect-connected-devices)))
    (if (null devices)
        (message "No DVR devices connected")
      (dolist (device devices)
        (whisper-dvr--auto-transcribe-device device)))))

(defun whisper-dvr-clear-transcription-history ()
  "Clear transcription history.
All files will be considered new on next auto-transcription."
  (interactive)
  (when (yes-or-no-p "Clear all transcription history? ")
    (clrhash whisper-dvr--transcription-history)
    (whisper-dvr-save-cache)
    (message "Transcription history cleared")))


;;; Remote DVR access via SSH/SFTP

(require 'tramp)

(defun whisper-dvr--build-tramp-path (remote-config)
  "Build TRAMP path from REMOTE-CONFIG plist."
  (let ((protocol (plist-get remote-config :protocol))
        (user (plist-get remote-config :user))
        (host (plist-get remote-config :host))
        (port (or (plist-get remote-config :port) 22))
        (path (plist-get remote-config :path)))
    (format "/%s:%s@%s#%d:%s"
            (if (eq protocol 'ssh) "ssh" "sftp")
            user host port path)))

(defun whisper-dvr--connect-remote (remote-config)
  "Establish connection to remote DVR described by REMOTE-CONFIG.
Returns connection info plist or nil on failure."
  (condition-case err
      (let* ((name (plist-get remote-config :name))
             (tramp-path (whisper-dvr--build-tramp-path remote-config))
             (identity-file (plist-get remote-config :identity-file)))

        ;; Set TRAMP identity file if provided
        (when identity-file
          (add-to-list 'tramp-ssh-controlmaster-options
                      (format "-i %s" identity-file)))

        ;; Test connection
        (if (file-accessible-directory-p tramp-path)
            (progn
              (message "Connected to remote DVR: %s" name)
              (list :name name
                    :path tramp-path
                    :config remote-config
                    :connected-at (current-time)))
          (error "Cannot access remote directory")))
    (error
     (message "Failed to connect to remote DVR %s: %s"
             (plist-get remote-config :name)
             (error-message-string err))
     nil)))

(defun whisper-dvr-connect-remote (remote-name)
  "Connect to remote DVR by REMOTE-NAME.
REMOTE-NAME should match :name in `whisper-dvr-remote-devices'."
  (interactive
   (list (completing-read "Connect to remote DVR: "
                         (mapcar (lambda (cfg) (plist-get cfg :name))
                                whisper-dvr-remote-devices)
                         nil t)))
  (let ((config (cl-find-if
                (lambda (cfg) (string= (plist-get cfg :name) remote-name))
                whisper-dvr-remote-devices)))
    (if config
        (let ((connection (whisper-dvr--connect-remote config)))
          (when connection
            (puthash remote-name connection whisper-dvr--remote-connections)
            (whisper-dvr--notify "Remote DVR Connected"
                                (format "Connected to %s" remote-name)
                                'normal)))
        (user-error "Remote DVR '%s' not found in configuration" remote-name))))

(defun whisper-dvr-disconnect-remote (remote-name)
  "Disconnect from remote DVR REMOTE-NAME."
  (interactive
   (list (completing-read "Disconnect remote DVR: "
                         (hash-table-keys whisper-dvr--remote-connections)
                         nil t)))
  (when (gethash remote-name whisper-dvr--remote-connections)
    (remhash remote-name whisper-dvr--remote-connections)
    (message "Disconnected from remote DVR: %s" remote-name)))

(defun whisper-dvr-list-remote-devices ()
  "List configured and connected remote DVRs."
  (interactive)
  (with-output-to-temp-buffer "*DVR Remote Devices*"
    (princ "Remote DVR Devices:\n")
    (princ (make-string 60 ?=))
    (princ "\n\nConfigured:\n")
    (dolist (config whisper-dvr-remote-devices)
      (let* ((name (plist-get config :name))
             (host (plist-get config :host))
             (connected (gethash name whisper-dvr--remote-connections)))
        (princ (format "  %s - %s@%s [%s]\n"
                      name
                      (plist-get config :user)
                      host
                      (if connected "CONNECTED" "disconnected")))))
    (princ "\n")))

(defun whisper-dvr--cache-remote-file (remote-path)
  "Cache REMOTE-PATH locally and return local path."
  (when whisper-dvr-remote-cache-locally
    (unless (file-exists-p whisper-dvr-remote-cache-directory)
      (make-directory whisper-dvr-remote-cache-directory t))
    (let* ((filename (file-name-nondirectory remote-path))
           (local-path (expand-file-name filename
                                        whisper-dvr-remote-cache-directory)))
      (unless (and (file-exists-p local-path)
                   (= (file-attribute-size (file-attributes remote-path))
                      (file-attribute-size (file-attributes local-path))))
        (message "Caching remote file: %s" filename)
        (copy-file remote-path local-path t))
      local-path)))

(defun whisper-dvr-transcribe-remote (remote-name file-path)
  "Transcribe FILE-PATH from remote DVR REMOTE-NAME."
  (interactive
   (let ((remote (completing-read "Remote DVR: "
                                 (hash-table-keys whisper-dvr--remote-connections)
                                 nil t)))
     (list remote
           (read-file-name "Remote file: "
                          (plist-get
                           (gethash remote whisper-dvr--remote-connections)
                           :path)))))
  (let* ((connection (gethash remote-name whisper-dvr--remote-connections))
         (full-path (if (file-name-absolute-p file-path)
                       file-path
                     (expand-file-name file-path
                                      (plist-get connection :path))))
         (local-path (whisper-dvr--cache-remote-file full-path)))
    (whisper-dvr-transcribe-file local-path)))


;;; Mobile DVR app integration

(defun whisper-dvr--get-cloud-api-client (service)
  "Get API client for cloud SERVICE.
Returns functions plist with :list-files, :download, :upload."
  (cl-case service
    (dropbox (whisper-dvr--dropbox-client))
    (google-drive (whisper-dvr--google-drive-client))
    (icloud (whisper-dvr--icloud-client))
    (t (error "Unsupported mobile sync service: %s" service))))

(defun whisper-dvr--dropbox-client ()
  "Create Dropbox API client.
Requires `request' package and Dropbox access token."
  (require 'request)
  (let ((token (or (getenv "DROPBOX_ACCESS_TOKEN")
                   (read-passwd "Dropbox access token: "))))
    (list
     :list-files
     (lambda (folder)
       (whisper-dvr--dropbox-list-files token folder))
     :download
     (lambda (path local-path)
       (whisper-dvr--dropbox-download token path local-path))
     :upload
     (lambda (local-path remote-path)
       (whisper-dvr--dropbox-upload token local-path remote-path)))))

(defun whisper-dvr--dropbox-list-files (token folder)
  "List files in Dropbox FOLDER using TOKEN."
  (let ((response
         (request
          "https://api.dropboxapi.com/2/files/list_folder"
          :type "POST"
          :headers `(("Authorization" . ,(format "Bearer %s" token))
                    ("Content-Type" . "application/json"))
          :data (json-encode `((path . ,folder)))
          :parser 'json-read
          :sync t)))
    (when (= 200 (request-response-status-code response))
      (let* ((data (request-response-data response))
             (entries (cdr (assoc 'entries data))))
        (mapcar
         (lambda (entry)
           (list :name (cdr (assoc 'name entry))
                 :path (cdr (assoc 'path_display entry))
                 :size (cdr (assoc 'size entry))
                 :modified (cdr (assoc 'client_modified entry))))
         entries)))))

(defun whisper-dvr--dropbox-download (token remote-path local-path)
  "Download file from Dropbox REMOTE-PATH to LOCAL-PATH using TOKEN."
  (let ((response
         (request
          "https://content.dropboxapi.com/2/files/download"
          :type "POST"
          :headers `(("Authorization" . ,(format "Bearer %s" token))
                    ("Dropbox-API-Arg" . ,(json-encode `((path . ,remote-path)))))
          :parser 'buffer-string
          :sync t)))
    (when (= 200 (request-response-status-code response))
      (with-temp-file local-path
        (insert (request-response-data response)))
      local-path)))

(defun whisper-dvr--dropbox-upload (token local-path remote-path)
  "Upload LOCAL-PATH to Dropbox REMOTE-PATH using TOKEN."
  (with-temp-buffer
    (insert-file-contents-literally local-path)
    (let ((response
           (request
            "https://content.dropboxapi.com/2/files/upload"
            :type "POST"
            :headers `(("Authorization" . ,(format "Bearer %s" token))
                      ("Dropbox-API-Arg" . ,(json-encode
                                            `((path . ,remote-path)
                                              (mode . "overwrite"))))
                      ("Content-Type" . "application/octet-stream"))
            :data (buffer-string)
            :sync t)))
      (= 200 (request-response-status-code response)))))

(defun whisper-dvr--google-drive-client ()
  "Create Google Drive API client.
Placeholder - requires OAuth2 implementation."
  (error "Google Drive integration not yet implemented"))

(defun whisper-dvr--icloud-client ()
  "Create iCloud API client.
Placeholder - requires iCloud authentication."
  (error "Integration with iCloud is not yet implemented"))

(defun whisper-dvr-sync-mobile ()
  "Synchronize with mobile DVR app via cloud service."
  (interactive)
  (unless whisper-dvr-mobile-sync-enabled
    (user-error "Mobile sync is not enabled"))

  (let* ((client (whisper-dvr--get-cloud-api-client
                 whisper-dvr-mobile-sync-service))
         (list-fn (plist-get client :list-files))
         (download-fn (plist-get client :download))
         (files (funcall list-fn whisper-dvr-mobile-sync-folder)))

    (if (null files)
        (message "No new files in mobile sync folder")
      (message "Found %d file(s) in mobile sync folder" (length files))
      (dolist (file files)
        (let* ((remote-path (plist-get file :path))
               (filename (plist-get file :name))
               (local-path (expand-file-name filename whisper-dvr-base-directory)))
          (unless (whisper-dvr--is-transcribed-p local-path)
            (message "Downloading: %s" filename)
            (funcall download-fn remote-path local-path)
            (whisper-dvr-transcribe-file local-path)
            (whisper-dvr--mark-transcribed local-path)))))))

(defun whisper-dvr--setup-mobile-sync-timer ()
  "Setup automatic mobile sync polling."
  (when (and whisper-dvr-mobile-sync-enabled
             whisper-dvr-mobile-sync-interval)
    (run-with-timer whisper-dvr-mobile-sync-interval
                   whisper-dvr-mobile-sync-interval
                   #'whisper-dvr-sync-mobile)))

(add-hook 'after-init-hook #'whisper-dvr--setup-mobile-sync-timer)


;;; Cloud storage upload system

(defun whisper-dvr--get-enabled-cloud-providers ()
  "Return list of enabled cloud providers."
  (cl-remove-if-not
   (lambda (provider)
     (plist-get (cadr provider) :enabled))
   whisper-dvr-cloud-providers))

(defun whisper-dvr--upload-to-cloud (file-path provider-config)
  "Upload FILE-PATH to cloud using PROVIDER-CONFIG."
  (let ((provider (car provider-config))
        (config (cadr provider-config)))
    (cl-case provider
      (dropbox
       (whisper-dvr--upload-to-dropbox file-path config))
      (google-drive
       (whisper-dvr--upload-to-google-drive file-path config))
      (onedrive
       (whisper-dvr--upload-to-onedrive file-path config))
      (s3
       (whisper-dvr--upload-to-s3 file-path config))
      (t
       (error "Unsupported cloud provider: %s" provider)))))

(defun whisper-dvr--upload-to-dropbox (file-path config)
  "Upload FILE-PATH to Dropbox using CONFIG."
  (let* ((folder (plist-get config :folder))
         (filename (file-name-nondirectory file-path))
         (remote-path (concat folder "/" filename))
         (client (whisper-dvr--dropbox-client))
         (upload-fn (plist-get client :upload)))
    (if (funcall upload-fn file-path remote-path)
        (message "Uploaded to Dropbox: %s" filename)
      (error "Failed to upload to Dropbox"))))

(defun whisper-dvr--upload-to-google-drive (_file-path _config)
  "Upload a file to Google Drive.
This is a placeholder that signals an error, because the Google Drive
backend is not written yet.  The arguments are accepted so that the
signature matches the other upload backends."
  (error "Google Drive upload not yet implemented"))

(defun whisper-dvr--upload-to-onedrive (_file-path _config)
  "Upload a file to OneDrive.
This is a placeholder that signals an error, because the OneDrive
backend is not written yet.  The arguments are accepted so that the
signature matches the other upload backends."
  (error "OneDrive upload not yet implemented"))

(defun whisper-dvr--upload-to-s3 (file-path config)
  "Upload FILE-PATH to AWS S3 using CONFIG."
  (let ((bucket (plist-get config :bucket))
        (region (plist-get config :region))
        (key (file-name-nondirectory file-path)))
    ;; Requires aws-cli or s3.el
    (let ((result (shell-command-to-string
                  (format "aws s3 cp %s s3://%s/%s --region %s"
                          (shell-quote-argument file-path)
                          bucket key region))))
      (if (string-match-p "upload:" result)
          (message "Uploaded to S3: %s" key)
        (error "Failed to upload to S3: %s" result)))))

(defun whisper-dvr-upload-to-cloud (file-path &optional providers)
  "Upload FILE-PATH to cloud storage PROVIDERS.
If PROVIDERS is nil, upload to all enabled providers."
  (interactive
   (list (read-file-name "File to upload: "
                        whisper-dvr-base-directory
                        nil t)))
  (unless whisper-dvr-cloud-upload-enabled
    (user-error "Cloud upload is not enabled"))

  (let ((providers (or providers (whisper-dvr--get-enabled-cloud-providers))))
    (if (null providers)
        (message "No cloud providers enabled")
      (dolist (provider providers)
        (condition-case err
            (progn
              (whisper-dvr--upload-to-cloud file-path provider)
              (message "Upload complete: %s" (car provider)))
          (error
           (message "Upload failed to %s: %s"
                   (car provider)
                   (error-message-string err))))))))

(defun whisper-dvr--maybe-upload-to-cloud (audio-file transcript-file)
  "Upload files to cloud if configured after transcription.
AUDIO-FILE is the source recording, TRANSCRIPT-FILE is the output."
  (when (and whisper-dvr-cloud-upload-enabled
             whisper-dvr-cloud-upload-on-transcribe)
    (let ((files-to-upload
           (cl-case whisper-dvr-cloud-upload-format
             (audio-only (list audio-file))
             (transcript-only (list transcript-file))
             (both (list audio-file transcript-file)))))
      (dolist (file files-to-upload)
        (whisper-dvr-upload-to-cloud file)))))

;; Hook into transcription completion
(add-hook 'whisper-dvr-transcribe-complete-hook
          (lambda (audio-file transcript-file)
            (whisper-dvr--maybe-upload-to-cloud audio-file transcript-file)))


;;; Internationalization (i18n) support

(defvar whisper-dvr--translations
  '((en . ((device-connected . "DVR device connected: %s")
           (device-disconnected . "DVR device disconnected: %s")
           (ejection-success . "Successfully ejected DVR device: %s")
           (ejection-failed . "Failed to eject DVR device: %s")
           (transcription-started . "Auto-transcription started")
           (transcription-complete . "Transcription complete: %d succeeded, %d failed")
           (files-in-use . "Files in use on %s. Force eject anyway?")
           (no-devices . "No DVR devices detected")
           (cache-loaded . "Cache loaded (%d entries)")
           (monitoring-started . "Background monitoring started")
           (monitoring-stopped . "Background monitoring stopped")))

    (es . ((device-connected . "Dispositivo DVR conectado: %s")
           (device-disconnected . "Dispositivo DVR desconectado: %s")
           (ejection-success . "Dispositivo DVR expulsado correctamente: %s")
           (ejection-failed . "Error al expulsar dispositivo DVR: %s")
           (transcription-started . "Transcripción automática iniciada")
           (transcription-complete . "Transcripción completa: %d exitosas, %d fallidas")
           (files-in-use . "Archivos en uso en %s. ¿Expulsar de todos modos?")
           (no-devices . "No se detectaron dispositivos DVR")
           (cache-loaded . "Caché cargada (%d entradas)")
           (monitoring-started . "Monitoreo en segundo plano iniciado")
           (monitoring-stopped . "Monitoreo en segundo plano detenido")))

    (fr . ((device-connected . "Périphérique DVR connecté: %s")
           (device-disconnected . "Périphérique DVR déconnecté: %s")
           (ejection-success . "Périphérique DVR éjecté avec succès: %s")
           (ejection-failed . "Échec de l'éjection du périphérique DVR: %s")
           (transcription-started . "Transcription automatique démarrée")
           (transcription-complete . "Transcription terminée: %d réussies, %d échouées")
           (files-in-use . "Fichiers en cours d'utilisation sur %s. Éjecter quand même?")
           (no-devices . "Aucun périphérique DVR détecté")
           (cache-loaded . "Cache chargé (%d entrées)")
           (monitoring-started . "Surveillance en arrière-plan démarrée")
           (monitoring-stopped . "Surveillance en arrière-plan arrêtée")))

    (de . ((device-connected . "DVR-Gerät verbunden: %s")
           (device-disconnected . "DVR-Gerät getrennt: %s")
           (ejection-success . "DVR-Gerät erfolgreich ausgeworfen: %s")
           (ejection-failed . "Fehler beim Auswerfen des DVR-Geräts: %s")
           (transcription-started . "Automatische Transkription gestartet")
           (transcription-complete . "Transkription abgeschlossen: %d erfolgreich, %d fehlgeschlagen")
           (files-in-use . "Dateien auf %s werden verwendet. Trotzdem auswerfen?")
           (no-devices . "Keine DVR-Geräte erkannt")
           (cache-loaded . "Cache geladen (%d Einträge)")
           (monitoring-started . "Hintergrundüberwachung gestartet")
           (monitoring-stopped . "Hintergrundüberwachung gestoppt")))

    (ja . ((device-connected . "DVRデバイスが接続されました: %s")
           (device-disconnected . "DVRデバイスが切断されました: %s")
           (ejection-success . "DVRデバイスの取り出しに成功しました: %s")
           (ejection-failed . "DVRデバイスの取り出しに失敗しました: %s")
           (transcription-started . "自動文字起こしを開始しました")
           (transcription-complete . "文字起こし完了: %d成功、%d失敗")
           (files-in-use . "%sでファイルが使用中です。強制的に取り出しますか?")
           (no-devices . "DVRデバイスが検出されませんでした")
           (cache-loaded . "キャッシュを読み込みました(%dエントリ)")
           (monitoring-started . "バックグラウンド監視を開始しました")
           (monitoring-stopped . "バックグラウンド監視を停止しました")))

    (zh . ((device-connected . "DVR设备已连接: %s")
           (device-disconnected . "DVR设备已断开: %s")
           (ejection-success . "成功弹出DVR设备: %s")
           (ejection-failed . "弹出DVR设备失败: %s")
           (transcription-started . "自动转录已开始")
           (transcription-complete . "转录完成: %d成功，%d失败")
           (files-in-use . "%s上的文件正在使用中。仍要弹出吗?")
           (no-devices . "未检测到DVR设备")
           (cache-loaded . "缓存已加载(%d条目)")
           (monitoring-started . "后台监控已启动")
           (monitoring-stopped . "后台监控已停止")))

    (ko . ((device-connected . "DVR 장치가 연결되었습니다: %s")
           (device-disconnected . "DVR 장치가 연결 해제되었습니다: %s")
           (ejection-success . "DVR 장치를 성공적으로 꺼냈습니다: %s")
           (ejection-failed . "DVR 장치를 꺼내는 데 실패했습니다: %s")
           (transcription-started . "자동 전사가 시작되었습니다")
           (transcription-complete . "전사 완료: %d성공, %d실패")
           (files-in-use . "%s에서 파일이 사용 중입니다. 강제로 꺼내시겠습니까?")
           (no-devices . "DVR 장치가 감지되지 않았습니다")
           (cache-loaded . "캐시 로드됨(%d항목)")
           (monitoring-started . "백그라운드 모니터링이 시작되었습니다")
           (monitoring-stopped . "백그라운드 모니터링이 중지되었습니다"))))
  "Translation strings for whisper-dvr interface.")

(defun whisper-dvr--detect-system-language ()
  "Detect the system language from the environment.
Return a language symbol such as en, es, or fr.  The symbol en is the
fallback."
  (let ((lang-env (or (getenv "LANG") (getenv "LANGUAGE") "en_US.UTF-8")))
    (cond
     ((string-match-p "^es" lang-env) 'es)
     ((string-match-p "^fr" lang-env) 'fr)
     ((string-match-p "^de" lang-env) 'de)
     ((string-match-p "^ja" lang-env) 'ja)
     ((string-match-p "^zh" lang-env) 'zh)
     ((string-match-p "^ko" lang-env) 'ko)
     (t 'en))))

(defun whisper-dvr--get-language ()
  "Get current language setting.
Returns language symbol for use with translations."
  (or whisper-dvr--current-language
      (setq whisper-dvr--current-language
            (if (eq whisper-dvr-language 'auto)
                (whisper-dvr--detect-system-language)
              whisper-dvr-language))))

(defun whisper-dvr-tr (key &rest args)
  "Translate KEY to current language and format with ARGS.
KEY is a symbol identifying the string to translate."
  (let* ((lang (whisper-dvr--get-language))
         (translations (cdr (assoc lang whisper-dvr--translations)))
         (string (or (cdr (assoc key translations))
                    (cdr (assoc key (cdr (assoc 'en whisper-dvr--translations))))
                    (symbol-name key))))
    (apply #'format string args)))

(defun whisper-dvr-set-language (language)
  "Set interface language to LANGUAGE.
LANGUAGE should be one of the symbols en, es, fr, de, ja, zh, ko, or
auto."
  (interactive
   (list (intern (completing-read "Select language: "
                                  '("auto" "en" "es" "fr" "de" "ja" "zh" "ko")
                                  nil t))))
  (setq whisper-dvr-language language)
  (setq whisper-dvr--current-language
        (if (eq language 'auto)
            (whisper-dvr--detect-system-language)
          language))
  (message (whisper-dvr-tr 'language-changed)))

;; Add language-changed translation
(dolist (lang-data whisper-dvr--translations)
  (let ((lang (car lang-data))
        (translations (cdr lang-data)))
    (push (cons 'language-changed
               (cl-case lang
                 (en "Language changed to %s")
                 (es "Idioma cambiado a %s")
                 (fr "Langue changée en %s")
                 (de "Sprache geändert zu %s")
                 (ja "言語を%sに変更しました")
                 (zh "语言已更改为%s")
                 (ko "언어가 %s(으)로 변경되었습니다")))
          translations)
    (setcdr lang-data translations)))


;;; LLM post-processing of transcripts
;;
;; The flow resembles a relay race.  whisper.el carries the audio to a
;; raw transcript and inserts it at point.  whisper-dvr then takes the
;; baton, hands the raw text to the configured LLM in a background
;; process, and swaps the raw text for the processed LaTeX when the
;; LLM finishes.  Emacs stays responsive the whole time.

(cl-defstruct (whisper-dvr--llm-job
               (:constructor whisper-dvr--llm-job-create)
               (:copier nil))
  "State of one running LLM request."
  process timer stdout stderr temp-files parser callback errback done)

(defvar whisper-dvr--llm-jobs nil
  "List of `whisper-dvr--llm-job' records that are still running.")

(defvar whisper-dvr--llm-armed-file nil
  "Audio file whose transcript is waiting for LLM post-processing.")

(defvar whisper-dvr--llm-captured nil
  "Cons of (START-MARKER . RAW-TEXT) captured from the whisper output.")

;;;; Small helpers

(defun whisper-dvr--llm-program (program)
  "Return PROGRAM, expanded when it names a file path."
  (if (string-match-p "[/~]" program)
      (expand-file-name program)
    program))

(defun whisper-dvr--llm-executable-p (program)
  "Return non-nil when PROGRAM can be run."
  (let ((prog (whisper-dvr--llm-program program)))
    (if (file-name-absolute-p prog)
        (and (file-executable-p prog) (not (file-directory-p prog)))
      (executable-find prog))))

(defun whisper-dvr--llm-model ()
  "Return the model name for the current backend, or nil."
  (or whisper-dvr-llm-model
      (alist-get whisper-dvr-llm-backend whisper-dvr-llm-default-models)))

(defun whisper-dvr--llm-api-url ()
  "Return the endpoint URL for the current HTTP backend."
  (or whisper-dvr-llm-api-url
      (pcase whisper-dvr-llm-backend
        ('anthropic "https://api.anthropic.com/v1/messages")
        (_ "http://localhost:11434/v1/chat/completions"))))

(defun whisper-dvr--llm-api-key ()
  "Return the API key for the current HTTP backend, or nil."
  (cond
   ((functionp whisper-dvr-llm-api-key) (funcall whisper-dvr-llm-api-key))
   ((stringp whisper-dvr-llm-api-key) whisper-dvr-llm-api-key)
   (t
    (or (getenv (if (eq whisper-dvr-llm-backend 'anthropic)
                    "ANTHROPIC_API_KEY"
                  "OPENAI_API_KEY"))
        (let ((host (url-host (url-generic-parse-url (whisper-dvr--llm-api-url)))))
          (when (and host (not (string-empty-p host)))
            (auth-source-pick-first-password :host host)))))))

(defun whisper-dvr--llm-strip-front-matter (text)
  "Return TEXT without a leading YAML front matter block."
  (if (string-match "\\`[ \t\n]*---[ \t]*\n\\(?:.*\n\\)*?---[ \t]*\n" text)
      (substring text (match-end 0))
    text))

(defun whisper-dvr--llm-instructions ()
  "Return the skill instructions sent to non-harness backends.
The body of `whisper-dvr-llm-skill-file' is preferred.  The text of
`whisper-dvr-llm-default-instructions' is the fallback."
  (let* ((file (and whisper-dvr-llm-skill-file
                    (expand-file-name whisper-dvr-llm-skill-file)))
         (body (if (and file (file-readable-p file))
                   (with-temp-buffer
                     (insert-file-contents file)
                     (whisper-dvr--llm-strip-front-matter (buffer-string)))
                 whisper-dvr-llm-default-instructions)))
    (concat (string-trim body)
            "\n\nThe transcript is supplied inline in the user message."
            "  Return only the processed LaTeX fragment,"
            " with no commentary and no code fences.")))

(defun whisper-dvr--llm-user-message (transcript)
  "Wrap TRANSCRIPT in the user message sent to the HTTP backends."
  (concat "Process the following raw transcript.\n\n<transcript>\n"
          (string-trim transcript)
          "\n</transcript>\n"))

(defun whisper-dvr--llm-clean-response (text)
  "Trim TEXT and remove a Markdown code fence that wraps all of it."
  (let ((s (string-trim text)))
    (when (string-match "\\````[a-zA-Z]*[ \t]*\n\\(\\(?:.\\|\n\\)*?\\)\n?```\\'" s)
      (setq s (string-trim (match-string 1 s))))
    s))

(defun whisper-dvr--llm-write-temp (content suffix)
  "Write CONTENT to a private temporary file ending in SUFFIX.
Return the file name."
  (let ((file (with-file-modes #o600
                (make-temp-file "whisper-dvr-llm-" nil suffix))))
    (let ((coding-system-for-write 'utf-8-unix))
      (write-region content nil file nil 'silent))
    file))

(defun whisper-dvr--llm-split-http-status (output)
  "Split curl OUTPUT into (STATUS . BODY).
The curl call appends the HTTP status code on a final line."
  (if (string-match "\n?\\([0-9]\\{3\\}\\)[ \t\n]*\\'" output)
      (cons (string-to-number (match-string 1 output))
            (substring output 0 (match-beginning 0)))
    (cons 0 output)))

(defun whisper-dvr--llm-json-read (body)
  "Parse the JSON string BODY into nested alists."
  (let ((json-object-type 'alist)
        (json-array-type 'vector)
        (json-key-type 'symbol))
    (json-read-from-string body)))

(defun whisper-dvr--llm-error-message (data)
  "Extract an error message from the parsed JSON DATA, or return nil."
  (let ((err (and (listp data) (alist-get 'error data))))
    (cond ((stringp err) err)
          ((listp err) (alist-get 'message err)))))

;;;; Response parsers

(defun whisper-dvr--llm-parse-anthropic (output)
  "Return the text from the Anthropic Messages API OUTPUT.
Signal an error when the request failed."
  (pcase-let* ((`(,status . ,body) (whisper-dvr--llm-split-http-status output))
               (data (condition-case nil
                         (whisper-dvr--llm-json-read body)
                       (error nil))))
    (when (or (null data) (>= status 400) (equal (alist-get 'type data) "error"))
      (error "Anthropic API error (HTTP %d): %s" status
             (or (whisper-dvr--llm-error-message data) (string-trim body))))
    (mapconcat (lambda (block) (or (alist-get 'text block) ""))
               (cl-remove-if-not (lambda (block)
                                   (equal (alist-get 'type block) "text"))
                                 (append (alist-get 'content data) nil))
               "")))

(defun whisper-dvr--llm-parse-openai (output)
  "Return the text from the OpenAI-style chat completions OUTPUT.
Signal an error when the request failed."
  (pcase-let* ((`(,status . ,body) (whisper-dvr--llm-split-http-status output))
               (data (condition-case nil
                         (whisper-dvr--llm-json-read body)
                       (error nil))))
    (when (or (null data) (>= status 400) (alist-get 'error data))
      (error "LLM server error (HTTP %d): %s" status
             (or (whisper-dvr--llm-error-message data) (string-trim body))))
    (let* ((choices (alist-get 'choices data))
           (first (and (vectorp choices) (> (length choices) 0) (aref choices 0)))
           (content (alist-get 'content (alist-get 'message first))))
      (unless (stringp content)
        (error "LLM server returned no message content"))
      content)))

;;;; Request specifications

(defun whisper-dvr--llm-curl-command (url headers body)
  "Return a spec plist for a curl POST of BODY to URL with HEADERS.
HEADERS is a list of header strings.  BODY is a JSON string.  Both go
through private temporary files so that the API key never appears on
the process command line."
  (let ((header-file (whisper-dvr--llm-write-temp
                      (concat (mapconcat #'identity headers "\n") "\n") ".txt"))
        (body-file (whisper-dvr--llm-write-temp body ".json")))
    (list :command (list (whisper-dvr--llm-program whisper-dvr-llm-curl-program)
                         "-sS" "-X" "POST"
                         "--max-time" (number-to-string whisper-dvr-llm-timeout)
                         "-H" (concat "@" header-file)
                         "--data-binary" (concat "@" body-file)
                         "-w" "\n%{http_code}"
                         url)
          :temp-files (list header-file body-file))))

(defun whisper-dvr--llm-request-spec (transcript)
  "Return the process spec that sends TRANSCRIPT to the current backend.
The spec is a plist with the keys :command, :stdin, :parser,
:temp-files, and :unset-env."
  (pcase whisper-dvr-llm-backend
    ('claude-code
     (list :command (append (list (whisper-dvr--llm-program
                                   whisper-dvr-llm-claude-program)
                                  "-p" (format whisper-dvr-llm-claude-prompt
                                               whisper-dvr-llm-skill-name))
                            (when whisper-dvr-llm-model
                              (list "--model" whisper-dvr-llm-model))
                            (when whisper-dvr-llm-claude-embed-skill
                              (list "--append-system-prompt"
                                    (whisper-dvr--llm-instructions)))
                            whisper-dvr-llm-claude-args)
           :stdin transcript
           :unset-env whisper-dvr-llm-claude-unset-env
           :parser #'identity))
    ('command
     (let ((model (or (whisper-dvr--llm-model) "")))
       (list :command (let ((cmd (mapcar (lambda (arg)
                                           (replace-regexp-in-string
                                            "%m" model arg t t))
                                         whisper-dvr-llm-command)))
                        (cons (whisper-dvr--llm-program (car cmd)) (cdr cmd)))
             :stdin (concat (whisper-dvr--llm-instructions) "\n\n"
                            (whisper-dvr--llm-user-message transcript))
             :parser #'identity)))
    ('anthropic
     (let ((key (whisper-dvr--llm-api-key)))
       (unless key
         (user-error "No Anthropic API key; set `whisper-dvr-llm-api-key' or ANTHROPIC_API_KEY"))
       (append
        (whisper-dvr--llm-curl-command
         (whisper-dvr--llm-api-url)
         (list "content-type: application/json"
               "anthropic-version: 2023-06-01"
               (concat "x-api-key: " key))
         (json-encode
          `((model . ,(whisper-dvr--llm-model))
            (max_tokens . ,whisper-dvr-llm-max-tokens)
            ,@(when whisper-dvr-llm-temperature
                `((temperature . ,whisper-dvr-llm-temperature)))
            (system . ,(whisper-dvr--llm-instructions))
            (messages . [((role . "user")
                          (content . ,(whisper-dvr--llm-user-message
                                       transcript)))]))))
        (list :parser #'whisper-dvr--llm-parse-anthropic))))
    ('openai-compatible
     (let ((key (whisper-dvr--llm-api-key))
           (model (whisper-dvr--llm-model)))
       (unless model
         (user-error "Set `whisper-dvr-llm-model' to the name of a model on the server"))
       (append
        (whisper-dvr--llm-curl-command
         (whisper-dvr--llm-api-url)
         (append (list "Content-Type: application/json")
                 (when key (list (concat "Authorization: Bearer " key))))
         (json-encode
          `((model . ,model)
            (max_tokens . ,whisper-dvr-llm-max-tokens)
            ,@(when whisper-dvr-llm-temperature
                `((temperature . ,whisper-dvr-llm-temperature)))
            (stream . :json-false)
            (messages . [((role . "system")
                          (content . ,(whisper-dvr--llm-instructions)))
                         ((role . "user")
                          (content . ,(whisper-dvr--llm-user-message
                                       transcript)))]))))
        (list :parser #'whisper-dvr--llm-parse-openai))))
    (other (user-error "Unknown `whisper-dvr-llm-backend': %S" other))))

(defun whisper-dvr--llm-backend-problem ()
  "Return a string that describes why the backend cannot run, or nil."
  (pcase whisper-dvr-llm-backend
    ('claude-code
     (unless (whisper-dvr--llm-executable-p whisper-dvr-llm-claude-program)
       (format "Cannot find the Claude Code program `%s'"
               whisper-dvr-llm-claude-program)))
    ('command
     (let ((prog (car whisper-dvr-llm-command)))
       (unless (and prog (whisper-dvr--llm-executable-p prog))
         (format "Cannot find the command `%s'" prog))))
    ((or 'anthropic 'openai-compatible)
     (cond ((not (whisper-dvr--llm-executable-p whisper-dvr-llm-curl-program))
            (format "Cannot find `%s'" whisper-dvr-llm-curl-program))
           ((and (eq whisper-dvr-llm-backend 'anthropic)
                 (not (whisper-dvr--llm-api-key)))
            "No Anthropic API key is available")
           ((not (whisper-dvr--llm-model))
            "No model is configured")))
    ('function
     (unless (functionp whisper-dvr-llm-function)
       "`whisper-dvr-llm-function' is not a function"))
    (other (format "Unknown backend %S" other))))

;;;; Process management

(defun whisper-dvr--llm-finish (job ok payload)
  "Finish JOB exactly once and report the outcome.
The callback of JOB receives PAYLOAD when OK is non-nil, and the errback
receives it otherwise.  PAYLOAD is the processed text or the error message."
  (unless (whisper-dvr--llm-job-done job)
    (setf (whisper-dvr--llm-job-done job) t)
    ;; The done flag is set first, so the sentinel that fires when the
    ;; process is deleted here ignores this job.
    (let ((proc (whisper-dvr--llm-job-process job)))
      (when (process-live-p proc) (delete-process proc)))
    (setq whisper-dvr--llm-jobs (delq job whisper-dvr--llm-jobs))
    (when (whisper-dvr--llm-job-timer job)
      (cancel-timer (whisper-dvr--llm-job-timer job)))
    (dolist (file (whisper-dvr--llm-job-temp-files job))
      (ignore-errors (delete-file file)))
    (dolist (buf (list (whisper-dvr--llm-job-stdout job)
                       (whisper-dvr--llm-job-stderr job)))
      (when (buffer-live-p buf) (kill-buffer buf)))
    (if ok
        (funcall (whisper-dvr--llm-job-callback job) payload)
      (funcall (whisper-dvr--llm-job-errback job) payload))))

(defun whisper-dvr--llm-sentinel (job)
  "Return a process sentinel that completes JOB."
  (lambda (proc _event)
    (when (and (memq (process-status proc) '(exit signal))
               (not (whisper-dvr--llm-job-done job)))
      (let* ((code (process-exit-status proc))
             (out (with-current-buffer (whisper-dvr--llm-job-stdout job)
                    (buffer-string)))
             (err (let ((buf (whisper-dvr--llm-job-stderr job)))
                    (if (buffer-live-p buf)
                        (with-current-buffer buf (string-trim (buffer-string)))
                      ""))))
        (whisper-dvr--llm-log proc code err out)
        (if (and (eq (process-status proc) 'exit) (zerop code))
            (condition-case e
                (let ((text (whisper-dvr--llm-clean-response
                             (funcall (whisper-dvr--llm-job-parser job) out))))
                  (if (string-empty-p text)
                      (whisper-dvr--llm-finish job nil "the LLM returned empty text")
                    (whisper-dvr--llm-finish job t text)))
              (error (whisper-dvr--llm-finish job nil (error-message-string e))))
          (whisper-dvr--llm-finish
           job nil
           (format "%s exited with code %d: %s"
                   (car (process-command proc)) code
                   (whisper-dvr--llm-failure-detail err out))))))))

(defun whisper-dvr--llm-failure-detail (err out)
  "Return the most useful explanation from stderr ERR and stdout OUT.
Claude Code in print mode writes many of its own errors, such as an
expired login, to standard output, so OUT is consulted when ERR is
empty."
  (let ((detail (string-trim (if (string-empty-p err) out err))))
    (cond ((string-empty-p detail)
           "no output; see M-x whisper-dvr-llm-show-log")
          ((> (length detail) 300)
           (concat (substring detail 0 300) "..."))
          (t detail))))

(defconst whisper-dvr--llm-log-buffer-name "*whisper-dvr-llm-log*"
  "Name of the buffer that records each LLM process run.")

(defun whisper-dvr--llm-log (proc code err out)
  "Record the command of PROC, exit CODE, stderr ERR, and stdout OUT.
Long arguments are shortened, and the API key never appears because it
travels in a temporary header file."
  (with-current-buffer (get-buffer-create whisper-dvr--llm-log-buffer-name)
    (let ((inhibit-read-only t)
          (clip (lambda (s n)
                  (if (> (length s) n)
                      (concat (substring s 0 n)
                              (format "... [%d more chars]" (- (length s) n)))
                    s))))
      (goto-char (point-max))
      (insert (format-time-string "==== %Y-%m-%d %H:%M:%S ====\n")
              "directory: " default-directory "\n"
              "command: "
              (mapconcat (lambda (arg)
                           (shell-quote-argument (funcall clip arg 200)))
                         (process-command proc) " ")
              "\n"
              (format "exit code: %d\n" code)
              "--- stderr ---\n" (funcall clip err 4000) "\n"
              "--- stdout ---\n" (funcall clip out 4000) "\n\n")
      ;; Keep the log from growing without bound.
      (when (> (buffer-size) 200000)
        (delete-region (point-min) (- (point-max) 100000))))))

;;;###autoload
(defun whisper-dvr-llm-show-log ()
  "Display the log of the LLM processes started so far."
  (interactive)
  (display-buffer (get-buffer-create whisper-dvr--llm-log-buffer-name)))

;;;###autoload
(defun whisper-dvr-llm-test-backend ()
  "Send a short sample transcript to the configured backend.
The result, or the error, is reported in the echo area and in the
buffer named by `whisper-dvr-llm-output-buffer-name'.  Use this command
to check a new backend before transcribing a long recording."
  (interactive)
  (when-let* ((problem (whisper-dvr--llm-backend-problem)))
    (user-error "%s" problem))
  (whisper-dvr-llm-process-text
   (concat "Okay so this is a test of the recorder. "
           "I don't think the buffer setup is done yet, "
           "so I need to email Bob about the crystallization screens tomorrow.")
   (lambda (result)
     (whisper-dvr--llm-show-in-buffer result)
     (message "whisper-dvr: backend %s works" whisper-dvr-llm-backend))
   (lambda (msg)
     (whisper-dvr-llm-show-log)
     (message "whisper-dvr: backend %s failed: %s" whisper-dvr-llm-backend msg))))

(defun whisper-dvr--llm-start-process (spec callback errback)
  "Start the process described by SPEC and return its job.
CALLBACK receives the processed text.  ERRBACK receives an error
message.  SPEC is a plist from `whisper-dvr--llm-request-spec'."
  (let ((command (plist-get spec :command)))
    (unless (whisper-dvr--llm-executable-p (car command))
      (dolist (file (plist-get spec :temp-files))
        (ignore-errors (delete-file file)))
      (user-error "Cannot find `%s'" (car command))))
  (let* ((command (plist-get spec :command))
         (stdout (generate-new-buffer " *whisper-dvr-llm-stdout*"))
         (stderr (generate-new-buffer " *whisper-dvr-llm-stderr*"))
         (job (whisper-dvr--llm-job-create
               :stdout stdout :stderr stderr
               :temp-files (plist-get spec :temp-files)
               :parser (or (plist-get spec :parser) #'identity)
               :callback callback :errback errback)))
    (let* ((process-environment
            ;; A bare NAME without "=" unsets that variable for the child.
            (append (plist-get spec :unset-env) process-environment))
           (proc (make-process :name "whisper-dvr-llm"
                              :buffer stdout
                              :stderr stderr
                              :command command
                              :coding 'utf-8-unix
                              :connection-type 'pipe
                              :noquery t
                              :sentinel #'ignore)))
      (setf (whisper-dvr--llm-job-process job) proc)
      ;; The stderr pipe would otherwise log its own status lines.
      (when-let* ((errproc (get-buffer-process stderr)))
        (set-process-sentinel errproc #'ignore))
      (set-process-sentinel proc (whisper-dvr--llm-sentinel job))
      (setf (whisper-dvr--llm-job-timer job)
            (run-with-timer whisper-dvr-llm-timeout nil
                            (lambda ()
                              (whisper-dvr--llm-finish
                               job nil
                               (format "timed out after %d seconds"
                                       whisper-dvr-llm-timeout)))))
      (push job whisper-dvr--llm-jobs)
      (when-let* ((input (plist-get spec :stdin)))
        (process-send-string proc input))
      (process-send-eof proc)
      job)))

(defun whisper-dvr-llm-process-text (text callback &optional errback)
  "Send TEXT to the configured LLM backend in the background.
CALLBACK is called with the processed text.  ERRBACK, when given, is
called with an error message, otherwise the error is shown with
`message'.  The return value is the job record, or nil for the
`function' backend."
  (when (string-blank-p text)
    (user-error "There is no transcript text to process"))
  (let* ((finished nil)
         (user-callback callback)
         (user-errback (or errback
                           (lambda (msg)
                             (message "whisper-dvr: LLM post-processing failed: %s"
                                      msg))))
         (callback (lambda (result)
                     (setq finished t)
                     (funcall user-callback result)))
         (errback (lambda (msg)
                    (setq finished t)
                    (funcall user-errback msg))))
    (whisper-dvr--llm-show-wait-message)
    ;; whisper.el calls (message nil) right after its insert hook runs,
    ;; which would erase the notice, so show it again a moment later.
    (when whisper-dvr-llm-wait-message
      (run-at-time 0.5 nil (lambda ()
                             (unless finished
                               (whisper-dvr--llm-show-wait-message)))))
    (if (eq whisper-dvr-llm-backend 'function)
        (progn
          (unless (functionp whisper-dvr-llm-function)
            (user-error "`whisper-dvr-llm-function' is not a function"))
          (funcall whisper-dvr-llm-function
                   (whisper-dvr--llm-instructions) text
                   (lambda (result)
                     (funcall callback (whisper-dvr--llm-clean-response result)))
                   errback)
          nil)
      (whisper-dvr--llm-start-process
       (whisper-dvr--llm-request-spec text) callback errback))))

;;;; Delivering the result

(defun whisper-dvr--llm-show-wait-message ()
  "Show `whisper-dvr-llm-wait-message' in the echo area, if it is set."
  (when whisper-dvr-llm-wait-message
    (message "%s" whisper-dvr-llm-wait-message)))

(defun whisper-dvr--llm-show-in-buffer (text)
  "Insert TEXT into the LLM output buffer and display it.
Return the buffer."
  (let ((buf (get-buffer-create whisper-dvr-llm-output-buffer-name)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (unless (bobp) (insert "\n\n"))
        (let ((start (point)))
          (insert text "\n")
          (when (and (fboundp 'latex-mode) (not (derived-mode-p 'tex-mode)))
            (latex-mode))
          (run-hook-with-args 'whisper-dvr-llm-after-process-hook start (point)))))
    (display-buffer buf)
    buf))

(defun whisper-dvr--llm-deliver (buffer beg end raw result)
  "Place RESULT in BUFFER according to `whisper-dvr-llm-insert-method'.
BEG and END are markers around the RAW transcript in BUFFER.  The
markers are released afterwards."
  (unwind-protect
      (let ((method whisper-dvr-llm-insert-method))
        (if (or (eq method 'buffer)
                (not (buffer-live-p buffer))
                (with-current-buffer buffer buffer-read-only))
            (whisper-dvr--llm-show-in-buffer result)
          (with-current-buffer buffer
            (when (and (eq method 'replace)
                       (not (string= raw (buffer-substring-no-properties beg end))))
              (message "whisper-dvr: raw transcript was edited; inserting result after it")
              (setq method 'append))
            (save-excursion
              (let (start)
                (if (eq method 'replace)
                    (progn
                      (goto-char beg)
                      (delete-region beg end)
                      (setq start (point)))
                  (goto-char end)
                  (insert "\n\n")
                  (setq start (point)))
                (insert result)
                (run-hook-with-args 'whisper-dvr-llm-after-process-hook
                                    start (point)))))
          (message "whisper-dvr: transcript post-processed in %s"
                   (buffer-name buffer))))
    (set-marker beg nil)
    (set-marker end nil)))

(defun whisper-dvr--llm-process-region-async (buffer beg end)
  "Post-process the text between BEG and END in BUFFER in the background.
BEG and END are positions or markers."
  (with-current-buffer buffer
    (let* ((raw (buffer-substring-no-properties beg end))
           (mbeg (copy-marker beg t))
           (mend (copy-marker end nil)))
      (condition-case err
          (whisper-dvr-llm-process-text
           raw
           (lambda (result)
             (whisper-dvr--llm-deliver buffer mbeg mend raw result))
           (lambda (msg)
             (set-marker mbeg nil)
             (set-marker mend nil)
             (message "whisper-dvr: LLM post-processing failed, raw transcript kept: %s"
                      msg)))
        (error
         (set-marker mbeg nil)
         (set-marker mend nil)
         (signal (car err) (cdr err)))))))

;;;; Integration with whisper.el

(defun whisper-dvr--llm-arm (audio-file)
  "Prepare LLM post-processing for the transcript of AUDIO-FILE.
Return non-nil when post-processing was armed.  When the backend cannot
run, warn and return nil so that the plain transcription proceeds."
  (let ((problem (whisper-dvr--llm-backend-problem)))
    (if problem
        (progn
          (display-warning 'whisper-dvr
                           (format "LLM post-processing skipped: %s" problem))
          nil)
      (setq whisper-dvr--llm-armed-file (expand-file-name audio-file)
            whisper-dvr--llm-captured nil)
      (add-hook 'whisper-after-transcription-hook
                #'whisper-dvr--llm-capture-transcript 90)
      (add-hook 'whisper-after-insert-hook #'whisper-dvr--llm-after-insert)
      t)))

(defun whisper-dvr--llm-disarm ()
  "Remove the whisper.el hooks and clear the armed state."
  (remove-hook 'whisper-after-transcription-hook
               #'whisper-dvr--llm-capture-transcript)
  (remove-hook 'whisper-after-insert-hook #'whisper-dvr--llm-after-insert)
  (setq whisper-dvr--llm-armed-file nil
        whisper-dvr--llm-captured nil))

(defun whisper-dvr--llm-armed-for-current-run-p ()
  "Return non-nil when the running whisper job is the armed one.
This check keeps an abandoned arm from capturing an unrelated dictation."
  (and whisper-dvr--llm-armed-file
       (boundp 'whisper--ffmpeg-input-file)
       (stringp (default-value 'whisper--ffmpeg-input-file))
       (string= (expand-file-name (default-value 'whisper--ffmpeg-input-file))
                whisper-dvr--llm-armed-file)))

(defun whisper-dvr--llm-capture-transcript ()
  "Record the finished raw transcript and its insertion point.
This function runs from `whisper-after-transcription-hook' in the
whisper output buffer."
  (if (not (whisper-dvr--llm-armed-for-current-run-p))
      (whisper-dvr--llm-disarm)
    (setq whisper-dvr--llm-captured
          (cons (and (boundp 'whisper--marker)
                     (markerp whisper--marker)
                     (marker-buffer whisper--marker)
                     (copy-marker whisper--marker))
                (buffer-substring-no-properties (point-min) (point-max))))))

(defun whisper-dvr--llm-after-insert ()
  "Start LLM post-processing of the transcript whisper.el just inserted.
This function runs from `whisper-after-insert-hook' in the buffer that
received the text."
  (let ((captured whisper-dvr--llm-captured))
    (whisper-dvr--llm-disarm)
    (when captured
      (condition-case err
          (whisper-dvr--llm-dispatch-captured captured)
        (error
         (message "whisper-dvr: LLM post-processing not started: %s"
                  (error-message-string err)))))))

(defun whisper-dvr--llm-dispatch-captured (captured)
  "Start post-processing for CAPTURED, a cons of (START . RAW).
The current buffer is the one that received the raw transcript."
  (let* ((start (car captured))
         (raw (cdr captured))
         (len (length raw)))
    (unwind-protect
        (cond
         ;; Text inserted at point, the usual case.
         ((and start
               (eq (marker-buffer start) (current-buffer))
               (<= (+ start len) (point-max))
               (string= raw (buffer-substring-no-properties
                             start (+ start len))))
          (whisper-dvr--llm-process-region-async
           (current-buffer) (marker-position start) (+ start len)))
         ;; Text sent to a separate transcription buffer.
         ((and (boundp 'whisper-insert-text-at-point)
               (not (symbol-value 'whisper-insert-text-at-point)))
          (whisper-dvr--llm-process-region-async
           (current-buffer) (point-min) (point-max)))
         ;; The inserted text cannot be located, so show the result apart.
         (t
          (whisper-dvr-llm-process-text raw #'whisper-dvr--llm-show-in-buffer)))
      (when (markerp start) (set-marker start nil)))))

;;;; Commands

;;;###autoload
(defun whisper-dvr-llm-process-region (beg end)
  "Post-process the transcript between BEG and END with the LLM.
Without an active region the whole buffer is processed.  The result
is placed according to `whisper-dvr-llm-insert-method'."
  (interactive
   (if (use-region-p)
       (list (region-beginning) (region-end))
     (list (point-min) (point-max))))
  (whisper-dvr--llm-process-region-async (current-buffer) beg end))

;;;###autoload
(defun whisper-dvr-llm-process-file (file &optional open)
  "Post-process the transcript in FILE and write FILE_parsed.tex beside it.
For example notes.txt yields notes_parsed.tex, which matches the
convention of the transcript-parser skill.  With prefix argument OPEN,
visit the new file when it is ready."
  (interactive "fTranscript file: \nP")
  (let* ((path (expand-file-name file))
         (out (whisper-dvr-llm-parsed-file-name path))
         (text (with-temp-buffer
                 (insert-file-contents path)
                 (buffer-string))))
    (whisper-dvr-llm-process-text
     text
     (lambda (result)
       (let ((coding-system-for-write 'utf-8-unix))
         (write-region (concat result "\n") nil out nil 'silent))
       (message "whisper-dvr: wrote %s" out)
       (when open (find-file out))))
    out))

(defun whisper-dvr-llm-parsed-file-name (file)
  "Return the name of the parsed LaTeX file that corresponds to FILE."
  (concat (file-name-sans-extension file) "_parsed.tex"))

;;;###autoload
(defun whisper-dvr-toggle-llm-postprocess ()
  "Toggle LLM post-processing of new transcripts."
  (interactive)
  (setq whisper-dvr-llm-postprocess (not whisper-dvr-llm-postprocess))
  (message "whisper-dvr LLM post-processing %s (backend %s)"
           (if whisper-dvr-llm-postprocess "enabled" "disabled")
           whisper-dvr-llm-backend))

;;;###autoload
(defun whisper-dvr-llm-select-backend (backend &optional model)
  "Set the LLM BACKEND and, optionally, the MODEL for this session.
An empty model name keeps the backend default."
  (interactive
   (let* ((choice (intern (completing-read
                           "LLM backend: "
                           '("claude-code" "anthropic" "openai-compatible"
                             "command" "function")
                           nil t nil nil (symbol-name whisper-dvr-llm-backend))))
          (model (read-string "Model (empty for the default): "
                              nil nil whisper-dvr-llm-model)))
     (list choice model)))
  (setq whisper-dvr-llm-backend backend
        whisper-dvr-llm-model (and model (not (string-empty-p model)) model))
  (message "whisper-dvr LLM backend is %s, model %s"
           backend (or (whisper-dvr--llm-model) "default")))

;;;###autoload
(defun whisper-dvr-llm-cancel ()
  "Cancel every running LLM post-processing request.
The raw transcripts stay in place."
  (interactive)
  (let ((count (length whisper-dvr--llm-jobs)))
    (dolist (job (copy-sequence whisper-dvr--llm-jobs))
      (whisper-dvr--llm-finish job nil "cancelled"))
    (whisper-dvr--llm-disarm)
    (message "whisper-dvr: cancelled %d LLM request(s)" count)))


;;; Integration with existing whisper-dvr functions

;; Update notification calls to use translations
(defun whisper-dvr--notify-success (volume-name)
  "Show success notification for ejecting VOLUME-NAME."
  (whisper-dvr--notify
   (whisper-dvr-tr 'ejection-success-title)
   (whisper-dvr-tr 'ejection-success volume-name)
   'normal))

(defun whisper-dvr--notify-failure (volume-name reason)
  "Show failure notification for VOLUME-NAME with REASON."
  (whisper-dvr--notify
   (whisper-dvr-tr 'ejection-failed-title)
   (format "%s\n%s" (whisper-dvr-tr 'ejection-failed volume-name) reason)
   'critical))

;; Add more translation keys
(dolist (lang-data whisper-dvr--translations)
  (let ((lang (car lang-data))
        (translations (cdr lang-data)))
    (setq translations
          (append translations
                  (cl-case lang
                    (en '((ejection-success-title . "DVR Ejected")
                          (ejection-failed-title . "Ejection Failed")
                          (upload-success . "Upload successful: %s")
                          (upload-failed . "Upload failed: %s")
                          (remote-connected . "Connected to remote DVR: %s")
                          (remote-failed . "Failed to connect: %s")
                          (sync-complete . "Mobile sync complete: %d files")
                          (language-set . "Language set to: %s")))
                    (es '((ejection-success-title . "DVR Expulsado")
                          (ejection-failed-title . "Expulsión Fallida")
                          (upload-success . "Subida exitosa: %s")
                          (upload-failed . "Subida fallida: %s")
                          (remote-connected . "Conectado a DVR remoto: %s")
                          (remote-failed . "Falló la conexión: %s")
                          (sync-complete . "Sincronización móvil completa: %d archivos")
                          (language-set . "Idioma establecido a: %s")))
                    ;; Add other languages similarly...
                    )))
    (setcdr lang-data translations)))

;; Hook for transcription completion to trigger uploads
(defvar whisper-dvr-transcribe-complete-hook nil
  "Hook run after successful transcription.
Functions receive (audio-file transcript-file) as arguments.")

;; Define mode for advanced features
(define-minor-mode whisper-dvr-mode
  "Minor mode for whisper-dvr with advanced features."
  :lighter " DVR"
  :global t
  (if whisper-dvr-mode
      (progn
        (whisper-dvr-load-cache)
        (when whisper-dvr-enable-background-monitoring
          (whisper-dvr-start-monitoring))
        (whisper-dvr--setup-cache-autosave))
    (whisper-dvr-stop-monitoring)
    (when whisper-dvr--cache-save-timer
      (cancel-timer whisper-dvr--cache-save-timer)
      (setq whisper-dvr--cache-save-timer nil))
    (whisper-dvr-save-cache)))


(provide 'whisper-dvr)
;;; whisper-dvr.el ends here
