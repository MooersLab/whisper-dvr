;;; whisper-dvr-test.el --- Tests for whisper-dvr.el -*- lexical-binding: t; -*-

;; Author: Blaine Mooers
;; Keywords: test

;;; Commentary:
;; ERT test suite for whisper-dvr.el providing unit and integration tests.

;;; Code:

(require 'ert)
(require 'cl-lib)

;; Load the package under test
(require 'whisper-dvr)

;;; ============================================================
;;; Test Fixtures and Helpers
;;; ============================================================

(defvar whisper-dvr-test--mock-files nil
  "Mock file list for testing.")

(defvar whisper-dvr-test--mock-attrs nil
  "Mock file attributes for testing.")

(defvar whisper-dvr-test--whisper-run-called nil
  "Track whether whisper-run was called.")

(defvar whisper-dvr-test--whisper-run-arg nil
  "Track the argument passed to whisper-run.")

(defun whisper-dvr-test--reset-state ()
  "Reset all test state variables."
  (setq whisper-dvr-test--mock-files nil
        whisper-dvr-test--mock-attrs nil
        whisper-dvr-test--whisper-run-called nil
        whisper-dvr-test--whisper-run-arg nil))

(defun whisper-dvr-test--make-mock-attrs (size mtime)
  "Create mock file attributes with SIZE and MTIME."
  (list nil 1 0 0 nil mtime nil size nil nil nil nil))

;;; ============================================================
;;; Unit Tests: Custom Variables
;;; ============================================================

(ert-deftest whisper-dvr-test-default-directory ()
  "Test that the default directory is set correctly."
  (should (stringp whisper-dvr-directory))
  (should (string-match-p "FOLDER01" whisper-dvr-directory)))

(ert-deftest whisper-dvr-test-default-extensions ()
  "Test that default file extensions include common audio formats."
  (should (listp whisper-dvr-file-extensions))
  (should (member "mp3" whisper-dvr-file-extensions))
  (should (member "wav" whisper-dvr-file-extensions))
  (should (member "m4a" whisper-dvr-file-extensions)))

;;; ============================================================
;;; Unit Tests: whisper-dvr--list-audio-files
;;; ============================================================

(ert-deftest whisper-dvr-test-list-audio-files-nonexistent-dir ()
  "Test error when directory does not exist."
  (let ((whisper-dvr-directory "/nonexistent/path/to/dvr"))
    (cl-letf (((symbol-function 'file-directory-p) (lambda (_) nil)))
      (should-error (whisper-dvr--list-audio-files) :type 'user-error))))

(ert-deftest whisper-dvr-test-list-audio-files-filters-by-extension ()
  "Test that only files with correct extensions are returned."
  (let ((whisper-dvr-directory "/test/dir")
        (whisper-dvr-file-extensions '("mp3" "wav")))
    (cl-letf (((symbol-function 'file-directory-p) (lambda (_) t))
              ((symbol-function 'directory-files)
               (lambda (_dir _full pattern)
                 ;; Simulate filtering
                 (let ((all-files '("/test/dir/recording1.mp3"
                                    "/test/dir/recording2.wav"
                                    "/test/dir/document.pdf"
                                    "/test/dir/notes.txt")))
                   (cl-remove-if-not
                    (lambda (f) (string-match-p pattern f))
                    all-files)))))
      (let ((result (whisper-dvr--list-audio-files)))
        (should (= 2 (length result)))
        (should (member "/test/dir/recording1.mp3" result))
        (should (member "/test/dir/recording2.wav" result))))))

(ert-deftest whisper-dvr-test-list-audio-files-empty-directory ()
  "Test behavior with directory containing no audio files."
  (let ((whisper-dvr-directory "/test/empty"))
    (cl-letf (((symbol-function 'file-directory-p) (lambda (_) t))
              ((symbol-function 'directory-files) (lambda (&rest _) nil)))
      (should (null (whisper-dvr--list-audio-files))))))

(ert-deftest whisper-dvr-test-list-audio-files-expands-path ()
  "Test that directory path is expanded."
  (let ((whisper-dvr-directory "~/test/dir")
        (expanded-path-used nil))
    (cl-letf (((symbol-function 'file-directory-p)
               (lambda (path)
                 (setq expanded-path-used (not (string-prefix-p "~" path)))
                 t))
              ((symbol-function 'directory-files) (lambda (&rest _) nil)))
      (whisper-dvr--list-audio-files)
      (should expanded-path-used))))

;;; ============================================================
;;; Unit Tests: whisper-dvr--format-file-entry
;;; ============================================================

(ert-deftest whisper-dvr-test-format-file-entry-basic ()
  "Test basic file entry formatting."
  (cl-letf (((symbol-function 'file-attributes)
             (lambda (_)
               (whisper-dvr-test--make-mock-attrs
                1048576  ; 1 MB
                (encode-time 0 30 14 15 6 2024)))))
    (let ((result (whisper-dvr--format-file-entry "/path/to/recording.mp3")))
      (should (stringp result))
      (should (string-match-p "recording\\.mp3" result))
      (should (string-match-p "2024-06-15" result))
      (should (string-match-p "14:30" result)))))

(ert-deftest whisper-dvr-test-format-file-entry-human-readable-size ()
  "Test that file sizes are formatted in human-readable form."
  (cl-letf (((symbol-function 'file-attributes)
             (lambda (_)
               (whisper-dvr-test--make-mock-attrs
                5242880  ; 5 MB
                (encode-time 0 0 12 1 1 2024)))))
    (let ((result (whisper-dvr--format-file-entry "/path/to/large.mp3")))
      ;; Should contain "5" and "M" for megabytes
      (should (string-match-p "5.*M" result)))))

(ert-deftest whisper-dvr-test-format-file-entry-extracts-filename ()
  "Test that only the filename (not full path) is shown."
  (cl-letf (((symbol-function 'file-attributes)
             (lambda (_)
               (whisper-dvr-test--make-mock-attrs 1024 (current-time)))))
    (let ((result (whisper-dvr--format-file-entry
                   "/very/long/path/to/file.mp3")))
      (should (string-match-p "file\\.mp3" result))
      (should-not (string-match-p "/very/long/path" result)))))

;;; ============================================================
;;; Unit Tests: whisper-dvr-set-directory
;;; ============================================================

(ert-deftest whisper-dvr-test-set-directory-updates-variable ()
  "Test that set-directory updates the custom variable."
  (let ((whisper-dvr-directory "/original/path"))
    (cl-letf (((symbol-function 'message) #'ignore))
      (whisper-dvr-set-directory "/new/path"))
    (should (string= (expand-file-name "/new/path")
                     whisper-dvr-directory))))

(ert-deftest whisper-dvr-test-set-directory-expands-path ()
  "Test that set-directory expands the path."
  (let ((whisper-dvr-directory "/original"))
    (cl-letf (((symbol-function 'message) #'ignore))
      (whisper-dvr-set-directory "~/test"))
    (should-not (string-prefix-p "~" whisper-dvr-directory))))

;;; ============================================================
;;; Unit Tests: SD card and internal memory shortcuts
;;; ============================================================

(ert-deftest whisper-dvr-test-sd-card-directory-default ()
  "Test that the SD card default names the Sony folder layout."
  (should (stringp whisper-dvr-sd-card-directory))
  (should (string-match-p "MEMORY CARD" whisper-dvr-sd-card-directory))
  (should (string-match-p "private/SONY/REC_FILE/FOLDER01"
                          whisper-dvr-sd-card-directory)))

(ert-deftest whisper-dvr-test-internal-memory-directory-default ()
  "Test that the internal memory default names the recorder folder."
  (should (stringp whisper-dvr-internal-memory-directory))
  (should (string-match-p "FOLDER01" whisper-dvr-internal-memory-directory)))

(ert-deftest whisper-dvr-test-sd-card-shortcut-sets-directory ()
  "Test that the SD card command copies the SD card path."
  (let ((whisper-dvr-directory "/original/path")
        (whisper-dvr-sd-card-directory "/Volumes/CARD/REC"))
    (cl-letf (((symbol-function 'message) #'ignore))
      (whisper-dvr-set-directory-to-sd-card))
    (should (string= (expand-file-name "/Volumes/CARD/REC")
                     whisper-dvr-directory))))

(ert-deftest whisper-dvr-test-internal-memory-shortcut-sets-directory ()
  "Test that the internal memory command copies the recorder path."
  (let ((whisper-dvr-directory "/original/path")
        (whisper-dvr-internal-memory-directory "/Volumes/IC/REC"))
    (cl-letf (((symbol-function 'message) #'ignore))
      (whisper-dvr-set-directory-to-internal-memory))
    (should (string= (expand-file-name "/Volumes/IC/REC")
                     whisper-dvr-directory))))

(ert-deftest whisper-dvr-test-sd-card-shortcut-expands-path ()
  "Test that the SD card command expands a path that starts with a tilde."
  (let ((whisper-dvr-directory "/original")
        (whisper-dvr-sd-card-directory "~/card/REC"))
    (cl-letf (((symbol-function 'message) #'ignore))
      (whisper-dvr-set-directory-to-sd-card))
    (should-not (string-prefix-p "~" whisper-dvr-directory))))

(ert-deftest whisper-dvr-test-sd-card-shortcut-without-prefix-does-not-save ()
  "Test that the plain command leaves the saved value untouched."
  (let ((whisper-dvr-directory "/original")
        (whisper-dvr-sd-card-directory "/Volumes/CARD/REC")
        (saved nil))
    (cl-letf (((symbol-function 'message) #'ignore)
              ((symbol-function 'customize-save-variable)
               (lambda (&rest _args) (setq saved t))))
      (whisper-dvr-set-directory-to-sd-card))
    (should-not saved)
    (should (string= (expand-file-name "/Volumes/CARD/REC")
                     whisper-dvr-directory))))

(ert-deftest whisper-dvr-test-sd-card-shortcut-with-prefix-saves ()
  "Test that a prefix argument routes the value through customize."
  (let ((whisper-dvr-directory "/original")
        (whisper-dvr-sd-card-directory "/Volumes/CARD/REC")
        (saved nil))
    (cl-letf (((symbol-function 'message) #'ignore)
              ((symbol-function 'customize-save-variable)
               (lambda (symbol value)
                 (setq saved (cons symbol value))
                 (set symbol value))))
      (whisper-dvr-set-directory-to-sd-card t))
    (should (eq (car saved) 'whisper-dvr-directory))
    (should (string= (cdr saved) (expand-file-name "/Volumes/CARD/REC")))))

(ert-deftest whisper-dvr-test-set-directory-to-reports-unmounted-volume ()
  "Test that an absent directory is reported as an unmounted volume."
  (let ((whisper-dvr-directory "/original")
        (reported ""))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args)
                 (setq reported (apply #'format fmt args)))))
      (whisper-dvr--set-directory-to "/Volumes/absent/REC" "SD card"))
    (should (string-match-p "not mounted" reported))))

(ert-deftest whisper-dvr-test-set-directory-to-returns-expanded-path ()
  "Test that the helper returns the expanded path it stored."
  (let ((whisper-dvr-directory "/original"))
    (cl-letf (((symbol-function 'message) #'ignore))
      (should (string= (whisper-dvr--set-directory-to "~/card" "SD card")
                       (expand-file-name "~/card"))))))

;;; ============================================================
;;; Unit Tests: device detection and notification helpers
;;; ============================================================

(ert-deftest whisper-dvr-test-volume-name-from-volumes-path ()
  "Test that a /Volumes path yields the volume label."
  (should (string= (whisper-dvr--volume-name
                    "/Volumes/MEMORY CARD/private/SONY/REC_FILE/FOLDER01")
                   "MEMORY CARD")))

(ert-deftest whisper-dvr-test-volume-name-from-plain-path ()
  "Test that a path outside /Volumes yields its last component."
  (should (string= (whisper-dvr--volume-name "/media/blaine/IC_RECORDER")
                   "IC_RECORDER")))

(ert-deftest whisper-dvr-test-invalidate-cache-entry-removes-key ()
  "Test that invalidating an entry drops it from the mount cache."
  (let ((whisper-dvr--mount-cache (make-hash-table :test 'equal)))
    (puthash "/Volumes/CARD" '(:directory "/Volumes/CARD")
             whisper-dvr--mount-cache)
    (whisper-dvr--invalidate-cache-entry "/Volumes/CARD")
    (should-not (gethash "/Volumes/CARD" whisper-dvr--mount-cache))))

(ert-deftest whisper-dvr-test-invalidate-cache-entry-tolerates-nil ()
  "Test that invalidating a nil directory is harmless."
  (let ((whisper-dvr--mount-cache (make-hash-table :test 'equal)))
    (should-not (whisper-dvr--invalidate-cache-entry nil))))

(ert-deftest whisper-dvr-test-detect-connected-devices-skips-absent-paths ()
  "Test that unmounted candidates are left out of the device list."
  (let ((whisper-dvr--mount-cache (make-hash-table :test 'equal))
        (whisper-dvr-directory "/nonexistent/dvr")
        (whisper-dvr-sd-card-directory "/nonexistent/card")
        (whisper-dvr-internal-memory-directory "/nonexistent/internal")
        (whisper-dvr-volume-mount-points '("/nonexistent/volume")))
    (should (null (whisper-dvr--detect-connected-devices)))))

(ert-deftest whisper-dvr-test-detect-connected-devices-reports-mounted-path ()
  "Test that a real directory is reported and cached."
  (let ((temp-dir (make-temp-file "whisper-dvr-test" t)))
    (unwind-protect
        (let ((whisper-dvr--mount-cache (make-hash-table :test 'equal))
              (whisper-dvr-directory temp-dir)
              (whisper-dvr-sd-card-directory "/nonexistent/card")
              (whisper-dvr-internal-memory-directory "/nonexistent/internal")
              (whisper-dvr-volume-mount-points '("/nonexistent/volume")))
          (let ((devices (whisper-dvr--detect-connected-devices)))
            (should (= 1 (length devices)))
            (should (string= (plist-get (car devices) :directory)
                             (expand-file-name temp-dir)))
            (should (gethash (expand-file-name temp-dir)
                             whisper-dvr--mount-cache))))
      (delete-directory temp-dir t))))

(ert-deftest whisper-dvr-test-detect-connected-devices-deduplicates ()
  "Test that a path listed twice is reported once."
  (let ((temp-dir (make-temp-file "whisper-dvr-test" t)))
    (unwind-protect
        (let ((whisper-dvr--mount-cache (make-hash-table :test 'equal))
              (whisper-dvr-directory temp-dir)
              (whisper-dvr-sd-card-directory temp-dir)
              (whisper-dvr-internal-memory-directory temp-dir)
              (whisper-dvr-volume-mount-points (list temp-dir)))
          (should (= 1 (length (whisper-dvr--detect-connected-devices)))))
      (delete-directory temp-dir t))))

(ert-deftest whisper-dvr-test-notify-falls-back-to-message ()
  "Test that an unsupported platform reports through the echo area."
  (let ((reported ""))
    (cl-letf (((symbol-function 'whisper-dvr--detect-os) (lambda () 'windows))
              ((symbol-function 'message)
               (lambda (fmt &rest args)
                 (setq reported (apply #'format fmt args)))))
      (whisper-dvr--notify "Title" "Body"))
    (should (string= reported "Title: Body"))))

;;; ============================================================
;;; Unit Tests: whisper-dvr-transcribe-file
;;; ============================================================

(ert-deftest whisper-dvr-test-transcribe-file-rejects-unreadable-file ()
  "Test that an absent audio file raises a user error."
  (should-error (whisper-dvr-transcribe-file "/nonexistent/audio.mp3")
                :type 'user-error))

(ert-deftest whisper-dvr-test-transcribe-file-calls-whisper-run ()
  "Test that the file is handed to whisper-run and the hook is run."
  (let ((temp-file (make-temp-file "whisper-dvr-test" nil ".mp3"))
        (run-arg nil)
        (hook-args nil))
    (unwind-protect
        (let ((whisper-dvr-transcribe-complete-hook
               (list (lambda (&rest args) (setq hook-args args)))))
          (cl-letf (((symbol-function 'whisper-run)
                     (lambda (file) (setq run-arg file))))
            (whisper-dvr-transcribe-file temp-file))
          (should (string= run-arg (expand-file-name temp-file)))
          (should (string= (car hook-args) (expand-file-name temp-file)))
          (should (string-suffix-p ".txt" (cadr hook-args))))
      (delete-file temp-file))))

;;; ============================================================
;;; Unit Tests: whisper-dvr (main function)
;;; ============================================================

(ert-deftest whisper-dvr-test-rejects-read-only-buffer ()
  "Test that read-only buffers are rejected."
  (with-temp-buffer
    (setq buffer-read-only t)
    (should-error (whisper-dvr) :type 'user-error)))

(ert-deftest whisper-dvr-test-prompts-for-non-file-buffer ()
  "Test that non-file buffers prompt for confirmation."
  (with-temp-buffer
    (let ((prompted nil))
      (cl-letf (((symbol-function 'y-or-n-p)
                 (lambda (_)
                   (setq prompted t)
                   nil)))  ; User says no
        (should-error (whisper-dvr) :type 'user-error)
        (should prompted)))))

(ert-deftest whisper-dvr-test-errors-when-no-files ()
  "Test error when no audio files are found."
  (let ((temp-file (make-temp-file "whisper-dvr-test" nil ".org")))
    (unwind-protect
        (with-current-buffer (find-file-noselect temp-file)
          (let ((whisper-dvr-directory "/test/dir"))
            (cl-letf (((symbol-function 'file-directory-p) (lambda (_) t))
                      ((symbol-function 'directory-files) (lambda (&rest _) nil)))
              (should-error (whisper-dvr) :type 'user-error)))
          (kill-buffer))
      (delete-file temp-file))))

(ert-deftest whisper-dvr-test-calls-whisper-run-with-selection ()
  "Test that whisper-run is called with the selected file."
  (whisper-dvr-test--reset-state)
  (let ((temp-file (make-temp-file "whisper-dvr-test" nil ".org")))
    (unwind-protect
        (with-current-buffer (find-file-noselect temp-file)
          (let ((whisper-dvr-directory "/test/dir")
                (test-file "/test/dir/selected.mp3"))
            (cl-letf (((symbol-function 'file-directory-p) (lambda (_) t))
                      ((symbol-function 'directory-files)
                       (lambda (&rest _) (list test-file)))
                      ((symbol-function 'file-attributes)
                       (lambda (_)
                         (whisper-dvr-test--make-mock-attrs 1024 (current-time))))
                      ((symbol-function 'completing-read)
                       (lambda (_prompt collection &rest _)
                         (caar collection)))  ; Return first entry
                      ((symbol-function 'whisper-run)
                       (lambda (file)
                         (setq whisper-dvr-test--whisper-run-called t
                               whisper-dvr-test--whisper-run-arg file)))
                      ((symbol-function 'message) #'ignore))
              (whisper-dvr)
              (should whisper-dvr-test--whisper-run-called)
              (should (string= test-file whisper-dvr-test--whisper-run-arg))))
          (kill-buffer))
      (delete-file temp-file))))

(ert-deftest whisper-dvr-test-displays-file-count-in-prompt ()
  "Test that the prompt shows the number of available files."
  (let ((temp-file (make-temp-file "whisper-dvr-test" nil ".org")))
    (unwind-protect
        (with-current-buffer (find-file-noselect temp-file)
          (let ((whisper-dvr-directory "/test/dir")
                (captured-prompt nil))
            (cl-letf (((symbol-function 'file-directory-p) (lambda (_) t))
                      ((symbol-function 'directory-files)
                       (lambda (&rest _)
                         '("/test/dir/a.mp3" "/test/dir/b.mp3" "/test/dir/c.mp3")))
                      ((symbol-function 'file-attributes)
                       (lambda (_)
                         (whisper-dvr-test--make-mock-attrs 1024 (current-time))))
                      ((symbol-function 'completing-read)
                       (lambda (prompt collection &rest _)
                         (setq captured-prompt prompt)
                         (caar collection)))
                      ((symbol-function 'whisper-run) #'ignore)
                      ((symbol-function 'message) #'ignore))
              (whisper-dvr)
              (should (string-match-p "3 available" captured-prompt))))
          (kill-buffer))
      (delete-file temp-file))))

;;; ============================================================
;;; Unit Tests: whisper-dvr-clear-all-files
;;; ============================================================

(ert-deftest whisper-dvr-test-clear-all-files-no-files ()
  "Test that clear-all-files reports nothing to do when directory is empty."
  (let ((whisper-dvr-directory "/test/empty")
        (deleted-files '())
        (last-message nil))
    (cl-letf (((symbol-function 'whisper-dvr--list-audio-files)
               (lambda () nil))
              ((symbol-function 'whisper-dvr--delete-file-safely)
               (lambda (f) (push f deleted-files) t))
              ((symbol-function 'yes-or-no-p)
               (lambda (&rest _)
                 (error "Should not prompt for an empty directory")))
              ((symbol-function 'message)
               (lambda (fmt &rest args)
                 (setq last-message (apply #'format fmt args)))))
      (whisper-dvr-clear-all-files)
      (should (null deleted-files))
      (should (string-match-p "No audio files found" last-message)))))

(ert-deftest whisper-dvr-test-clear-all-files-aborts-on-no ()
  "Test that no files are deleted when the user declines the prompt."
  (let ((whisper-dvr-directory "/test/dvr")
        (deleted-files '()))
    (cl-letf (((symbol-function 'whisper-dvr--list-audio-files)
               (lambda () '("/test/dvr/a.mp3" "/test/dvr/b.mp3")))
              ((symbol-function 'whisper-dvr--delete-file-safely)
               (lambda (f) (push f deleted-files) t))
              ((symbol-function 'yes-or-no-p) (lambda (&rest _) nil))
              ((symbol-function 'message) #'ignore))
      (whisper-dvr-clear-all-files)
      (should (null deleted-files)))))

(ert-deftest whisper-dvr-test-clear-all-files-deletes-all ()
  "Test that every listed audio file is processed when confirmed."
  (let ((whisper-dvr-directory "/test/dvr")
        (deleted-files '())
        (mock-files '("/test/dvr/a.mp3" "/test/dvr/b.wav" "/test/dvr/c.m4a")))
    (cl-letf (((symbol-function 'whisper-dvr--list-audio-files)
               (lambda () mock-files))
              ((symbol-function 'whisper-dvr--delete-file-safely)
               (lambda (f) (push f deleted-files) t))
              ((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
              ((symbol-function 'message) #'ignore))
      (whisper-dvr-clear-all-files)
      (should (= 3 (length deleted-files)))
      (should (member "/test/dvr/a.mp3" deleted-files))
      (should (member "/test/dvr/b.wav" deleted-files))
      (should (member "/test/dvr/c.m4a" deleted-files)))))

(ert-deftest whisper-dvr-test-clear-all-files-no-confirm-skips-prompt ()
  "Test that the no-confirm argument skips the yes-or-no-p prompt."
  (let ((whisper-dvr-directory "/test/dvr")
        (deleted-files '())
        (prompted nil))
    (cl-letf (((symbol-function 'whisper-dvr--list-audio-files)
               (lambda () '("/test/dvr/a.mp3" "/test/dvr/b.mp3")))
              ((symbol-function 'whisper-dvr--delete-file-safely)
               (lambda (f) (push f deleted-files) t))
              ((symbol-function 'yes-or-no-p)
               (lambda (&rest _) (setq prompted t) nil))
              ((symbol-function 'message) #'ignore))
      (whisper-dvr-clear-all-files t)
      (should-not prompted)
      (should (= 2 (length deleted-files))))))

(ert-deftest whisper-dvr-test-clear-all-files-prompt-shows-count ()
  "Test that the confirmation prompt mentions the file count and directory."
  (let ((whisper-dvr-directory "/test/dvr")
        (whisper-dvr-use-trash t)
        (captured-prompt nil))
    (cl-letf (((symbol-function 'whisper-dvr--list-audio-files)
               (lambda () '("/test/dvr/a.mp3"
                            "/test/dvr/b.mp3"
                            "/test/dvr/c.mp3"
                            "/test/dvr/d.mp3")))
              ((symbol-function 'whisper-dvr--delete-file-safely)
               (lambda (_f) t))
              ((symbol-function 'yes-or-no-p)
               (lambda (prompt) (setq captured-prompt prompt) nil))
              ((symbol-function 'message) #'ignore))
      (whisper-dvr-clear-all-files)
      (should (string-match-p "4 file" captured-prompt))
      (should (string-match-p "/test/dvr" captured-prompt))
      (should (string-match-p "Move to trash" captured-prompt)))))

(ert-deftest whisper-dvr-test-clear-all-files-prompt-respects-use-trash ()
  "Test that the prompt wording reflects `whisper-dvr-use-trash'."
  (let ((whisper-dvr-directory "/test/dvr")
        (whisper-dvr-use-trash nil)
        (captured-prompt nil))
    (cl-letf (((symbol-function 'whisper-dvr--list-audio-files)
               (lambda () '("/test/dvr/a.mp3")))
              ((symbol-function 'whisper-dvr--delete-file-safely)
               (lambda (_f) t))
              ((symbol-function 'yes-or-no-p)
               (lambda (prompt) (setq captured-prompt prompt) nil))
              ((symbol-function 'message) #'ignore))
      (whisper-dvr-clear-all-files)
      (should (string-match-p "Permanently delete" captured-prompt))
      (should-not (string-match-p "Move to trash" captured-prompt)))))

(ert-deftest whisper-dvr-test-clear-all-files-uses-trash-when-enabled ()
  "Test that move-file-to-trash is called when whisper-dvr-use-trash is t."
  (let ((whisper-dvr-directory "/test/dvr")
        (whisper-dvr-use-trash t)
        (trash-calls 0)
        (delete-calls 0))
    (cl-letf (((symbol-function 'whisper-dvr--list-audio-files)
               (lambda () '("/test/dvr/a.mp3" "/test/dvr/b.mp3")))
              ((symbol-function 'move-file-to-trash)
               (lambda (_f) (setq trash-calls (1+ trash-calls))))
              ((symbol-function 'delete-file)
               (lambda (&rest _) (setq delete-calls (1+ delete-calls))))
              ((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
              ((symbol-function 'message) #'ignore))
      (whisper-dvr-clear-all-files)
      (should (= 2 trash-calls))
      (should (= 0 delete-calls)))))

(ert-deftest whisper-dvr-test-clear-all-files-uses-delete-when-trash-disabled ()
  "Test that delete-file is called when whisper-dvr-use-trash is nil."
  (let ((whisper-dvr-directory "/test/dvr")
        (whisper-dvr-use-trash nil)
        (trash-calls 0)
        (delete-calls 0))
    (cl-letf (((symbol-function 'whisper-dvr--list-audio-files)
               (lambda () '("/test/dvr/a.mp3" "/test/dvr/b.mp3")))
              ((symbol-function 'move-file-to-trash)
               (lambda (_f) (setq trash-calls (1+ trash-calls))))
              ((symbol-function 'delete-file)
               (lambda (&rest _) (setq delete-calls (1+ delete-calls))))
              ((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
              ((symbol-function 'message) #'ignore))
      (whisper-dvr-clear-all-files)
      (should (= 0 trash-calls))
      (should (= 2 delete-calls)))))

(ert-deftest whisper-dvr-test-clear-all-files-counts-only-successes ()
  "Test that the summary message reports only successful removals."
  (let ((whisper-dvr-directory "/test/dvr")
        (call-count 0)
        (last-message nil))
    (cl-letf (((symbol-function 'whisper-dvr--list-audio-files)
               (lambda () '("/test/dvr/a.mp3"
                            "/test/dvr/b.mp3"
                            "/test/dvr/c.mp3")))
              ((symbol-function 'whisper-dvr--delete-file-safely)
               (lambda (_f)
                 (setq call-count (1+ call-count))
                 ;; Second call simulates a failure.
                 (not (= call-count 2))))
              ((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
              ((symbol-function 'message)
               (lambda (fmt &rest args)
                 (setq last-message (apply #'format fmt args)))))
      (whisper-dvr-clear-all-files t)
      (should (= 3 call-count))
      (should (string-match-p "2 of 3 file" last-message)))))

;;; ============================================================
;;; Integration Tests
;;; ============================================================

(ert-deftest whisper-dvr-test-integration-full-workflow ()
  "Integration test for complete workflow from selection to transcription."
  (whisper-dvr-test--reset-state)
  (let ((temp-file (make-temp-file "whisper-dvr-test" nil ".org")))
    (unwind-protect
        (with-current-buffer (find-file-noselect temp-file)
          (let* ((whisper-dvr-directory "/test/dvr")
                 (whisper-dvr-file-extensions '("mp3"))
                 (mock-files '("/test/dvr/meeting-2024-01-15.mp3"
                               "/test/dvr/notes-2024-01-16.mp3"))
                 (selected-file (cadr mock-files)))  ; Select second file
            (cl-letf (((symbol-function 'file-directory-p) (lambda (_) t))
                      ((symbol-function 'directory-files)
                       (lambda (_dir _full _pattern) mock-files))
                      ((symbol-function 'file-attributes)
                       (lambda (file)
                         (cond
                          ((string-match-p "2024-01-15" file)
                           (whisper-dvr-test--make-mock-attrs
                            2097152 (encode-time 0 0 10 15 1 2024)))
                          ((string-match-p "2024-01-16" file)
                           (whisper-dvr-test--make-mock-attrs
                            3145728 (encode-time 0 30 14 16 1 2024))))))
                      ((symbol-function 'completing-read)
                       (lambda (_prompt collection &rest _)
                         ;; Find and return the entry for the second file
                         (car (cl-find-if
                               (lambda (entry)
                                 (string= (cdr entry) selected-file))
                               collection))))
                      ((symbol-function 'whisper-run)
                       (lambda (file)
                         (setq whisper-dvr-test--whisper-run-called t
                               whisper-dvr-test--whisper-run-arg file)))
                      ((symbol-function 'message) #'ignore))
              (whisper-dvr)
              (should whisper-dvr-test--whisper-run-called)
              (should (string= selected-file whisper-dvr-test--whisper-run-arg))))
          (kill-buffer))
      (delete-file temp-file))))

(ert-deftest whisper-dvr-test-integration-multiple-extensions ()
  "Integration test verifying multiple file extensions are handled."
  (with-temp-buffer
    (let* ((whisper-dvr-directory "/test/dvr")
           (whisper-dvr-file-extensions '("mp3" "wav" "m4a"))
           (collected-pattern nil))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) t))
                ((symbol-function 'file-directory-p) (lambda (_) t))
                ((symbol-function 'directory-files)
                 (lambda (_dir _full pattern)
                   (setq collected-pattern pattern)
                   nil)))
        (ignore-errors (whisper-dvr))
        ;; Verify the pattern matches all expected extensions
        (should (string-match-p collected-pattern "test.mp3"))
        (should (string-match-p collected-pattern "test.wav"))
        (should (string-match-p collected-pattern "test.m4a"))
        ;; Verify it does not match other extensions
        (should-not (string-match-p collected-pattern "test.pdf"))
        (should-not (string-match-p collected-pattern "test.txt"))))))

(ert-deftest whisper-dvr-test-integration-directory-change-persists ()
  "Integration test verifying directory changes affect subsequent calls."
  (let ((original-dir whisper-dvr-directory))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'message) #'ignore))
            (whisper-dvr-set-directory "/new/dvr/path"))
          (let ((dir-checked nil))
            (cl-letf (((symbol-function 'file-directory-p)
                       (lambda (dir)
                         (setq dir-checked dir)
                         nil)))
              (ignore-errors (whisper-dvr--list-audio-files))
              (should (string= (expand-file-name "/new/dvr/path")
                               dir-checked)))))
      ;; Restore original directory
      (setq whisper-dvr-directory original-dir))))

;;; ============================================================
;;; Edge Case Tests
;;; ============================================================

(ert-deftest whisper-dvr-test-edge-case-special-characters-in-filename ()
  "Test handling of filenames with special characters."
  (cl-letf (((symbol-function 'file-attributes)
             (lambda (_)
               (whisper-dvr-test--make-mock-attrs 1024 (current-time)))))
    (let ((result (whisper-dvr--format-file-entry
                   "/path/to/meeting (2024-01-15) [draft].mp3")))
      (should (string-match-p "meeting (2024-01-15) \\[draft\\]\\.mp3" result)))))

(ert-deftest whisper-dvr-test-edge-case-very-large-file ()
  "Test formatting of very large files."
  (cl-letf (((symbol-function 'file-attributes)
             (lambda (_)
               (whisper-dvr-test--make-mock-attrs
                10737418240  ; 10 GB
                (current-time)))))
    (let ((result (whisper-dvr--format-file-entry "/path/to/huge.mp3")))
      ;; Should show size in gigabytes
      (should (string-match-p "G" result)))))

(ert-deftest whisper-dvr-test-edge-case-zero-size-file ()
  "Test formatting of zero-size files."
  (cl-letf (((symbol-function 'file-attributes)
             (lambda (_)
               (whisper-dvr-test--make-mock-attrs 0 (current-time)))))
    (let ((result (whisper-dvr--format-file-entry "/path/to/empty.mp3")))
      (should (stringp result))
      (should (string-match-p "empty\\.mp3" result)))))

;;; ============================================================
;;; Unit Tests: LLM post-processing
;;; ============================================================

;; whisper.el internals that the hook integration reads.  The Makefile
;; replaces whisper.el with a stub, so the tests define them here.
(defvar whisper--ffmpeg-input-file nil)
(defvar whisper--marker (make-marker))
(defvar whisper-insert-text-at-point t)

(defmacro whisper-dvr-test--with-llm-defaults (&rest body)
  "Run BODY with LLM settings bound to predictable test values."
  (declare (indent 0) (debug t))
  `(let ((whisper-dvr-llm-postprocess nil)
         (whisper-dvr-llm-backend 'claude-code)
         (whisper-dvr-llm-model nil)
         (whisper-dvr-llm-api-url nil)
         (whisper-dvr-llm-api-key nil)
         (whisper-dvr-llm-skill-name "transcript-parser")
         (whisper-dvr-llm-skill-file "/nonexistent/SKILL.md")
         (whisper-dvr-llm-claude-program "claude")
         (whisper-dvr-llm-claude-args '("--output-format" "text"))
         (whisper-dvr-llm-claude-embed-skill nil)
         (whisper-dvr-llm-claude-unset-env '("ANTHROPIC_API_KEY"))
         (whisper-dvr-llm-insert-method 'replace)
         (whisper-dvr-llm-timeout 30)
         (whisper-dvr-llm-temperature nil)
         (whisper-dvr-llm-after-process-hook nil)
         (whisper-dvr--llm-jobs nil)
         (whisper-dvr--llm-armed-file nil)
         (whisper-dvr--llm-captured nil)
         (inhibit-message t))
     (unwind-protect (progn ,@body)
       (whisper-dvr--llm-disarm))))

(defun whisper-dvr-test--sync-function-backend (transform)
  "Return a `function' backend that applies TRANSFORM synchronously."
  (lambda (_instructions text callback _errback)
    (funcall callback (funcall transform text))))

(defun whisper-dvr-test--wait-for-jobs (&optional seconds)
  "Wait up to SECONDS for every LLM job to finish."
  (let ((deadline (+ (float-time) (or seconds 10))))
    (while (and whisper-dvr--llm-jobs (< (float-time) deadline))
      (accept-process-output nil 0.05))))

(ert-deftest whisper-dvr-test-llm-defaults ()
  "Test that LLM post-processing is opt-in with sensible defaults."
  (should (memq (default-value 'whisper-dvr-llm-postprocess) '(nil t)))
  (should (eq (eval (car (get 'whisper-dvr-llm-postprocess 'standard-value))) nil))
  (should (eq (eval (car (get 'whisper-dvr-llm-backend 'standard-value))) 'claude-code))
  (should (eq (eval (car (get 'whisper-dvr-llm-insert-method 'standard-value))) 'replace))
  (should (equal (eval (car (get 'whisper-dvr-llm-skill-name 'standard-value)))
                 "transcript-parser")))

(ert-deftest whisper-dvr-test-llm-model-falls-back-to-backend-default ()
  "Test model resolution for each backend."
  (whisper-dvr-test--with-llm-defaults
    (let ((whisper-dvr-llm-backend 'anthropic))
      (should (equal (whisper-dvr--llm-model) "claude-sonnet-5-5"))
      (let ((whisper-dvr-llm-model "claude-opus-5-5"))
        (should (equal (whisper-dvr--llm-model) "claude-opus-5-5"))))
    (let ((whisper-dvr-llm-backend 'claude-code))
      (should-not (whisper-dvr--llm-model)))))

(ert-deftest whisper-dvr-test-llm-api-url-defaults ()
  "Test default endpoints for the HTTP backends."
  (whisper-dvr-test--with-llm-defaults
    (let ((whisper-dvr-llm-backend 'anthropic))
      (should (string-match-p "api\\.anthropic\\.com/v1/messages"
                              (whisper-dvr--llm-api-url))))
    (let ((whisper-dvr-llm-backend 'openai-compatible))
      (should (string-match-p "localhost:11434/v1/chat/completions"
                              (whisper-dvr--llm-api-url))))
    (let ((whisper-dvr-llm-api-url "http://localhost:8080/v1/chat/completions"))
      (should (string-match-p "8080" (whisper-dvr--llm-api-url))))))

(ert-deftest whisper-dvr-test-llm-api-key-sources ()
  "Test that the API key comes from a string, a function, or the environment."
  (whisper-dvr-test--with-llm-defaults
    (let ((whisper-dvr-llm-backend 'anthropic))
      (let ((whisper-dvr-llm-api-key "sk-string"))
        (should (equal (whisper-dvr--llm-api-key) "sk-string")))
      (let ((whisper-dvr-llm-api-key (lambda () "sk-func")))
        (should (equal (whisper-dvr--llm-api-key) "sk-func")))
      (let ((process-environment (cons "ANTHROPIC_API_KEY=sk-env"
                                       process-environment)))
        (should (equal (whisper-dvr--llm-api-key) "sk-env"))))))

(ert-deftest whisper-dvr-test-llm-strip-front-matter ()
  "Test removal of YAML front matter from a skill file."
  (should (equal (whisper-dvr--llm-strip-front-matter
                  "---\nname: x\ndescription: y\n---\n# Body\n")
                 "# Body\n"))
  (should (equal (whisper-dvr--llm-strip-front-matter "# No front matter\n")
                 "# No front matter\n")))

(ert-deftest whisper-dvr-test-llm-instructions-prefer-skill-file ()
  "Test that the skill file body becomes the instructions."
  (let ((file (make-temp-file "skill" nil ".md"
                              "---\nname: transcript-parser\n---\nSKILL BODY TEXT\n")))
    (unwind-protect
        (whisper-dvr-test--with-llm-defaults
          (let ((whisper-dvr-llm-skill-file file))
            (let ((text (whisper-dvr--llm-instructions)))
              (should (string-prefix-p "SKILL BODY TEXT" text))
              (should-not (string-match-p "name: transcript-parser" text))
              (should (string-match-p "no code fences" text)))))
      (delete-file file))))

(ert-deftest whisper-dvr-test-llm-instructions-fallback ()
  "Test the built-in instructions when the skill file is missing."
  (whisper-dvr-test--with-llm-defaults
    (let ((text (whisper-dvr--llm-instructions)))
      (should (string-match-p "subsubsection" text))
      (should (string-match-p "TODO Items" text)))))

(ert-deftest whisper-dvr-test-llm-clean-response-strips-fences ()
  "Test that a code fence around the whole response is removed."
  (should (equal (whisper-dvr--llm-clean-response
                  "```latex\n\\subsubsection{A}\nText.\n```\n")
                 "\\subsubsection{A}\nText."))
  (should (equal (whisper-dvr--llm-clean-response "  plain text \n")
                 "plain text")))

(ert-deftest whisper-dvr-test-llm-split-http-status ()
  "Test splitting the curl status line from the body."
  (should (equal (whisper-dvr--llm-split-http-status "{\"a\":1}\n200")
                 '(200 . "{\"a\":1}")))
  (should (equal (car (whisper-dvr--llm-split-http-status "no status")) 0)))

(ert-deftest whisper-dvr-test-llm-parse-anthropic ()
  "Test parsing a successful and a failed Anthropic response."
  (should (equal (whisper-dvr--llm-parse-anthropic
                  (concat "{\"type\":\"message\",\"content\":["
                          "{\"type\":\"text\",\"text\":\"Hello \"},"
                          "{\"type\":\"text\",\"text\":\"world\"}]}\n200"))
                 "Hello world"))
  (let ((err (should-error
              (whisper-dvr--llm-parse-anthropic
               (concat "{\"type\":\"error\",\"error\":{\"type\":\"authentication_error\","
                       "\"message\":\"invalid x-api-key\"}}\n401")))))
    (should (string-match-p "invalid x-api-key" (error-message-string err)))))

(ert-deftest whisper-dvr-test-llm-parse-openai ()
  "Test parsing a successful and a failed chat completions response."
  (should (equal (whisper-dvr--llm-parse-openai
                  (concat "{\"choices\":[{\"message\":{\"role\":\"assistant\","
                          "\"content\":\"Parsed\"}}]}\n200"))
                 "Parsed"))
  (let ((err (should-error
              (whisper-dvr--llm-parse-openai
               "{\"error\":{\"message\":\"model not found\"}}\n404"))))
    (should (string-match-p "model not found" (error-message-string err)))))

(ert-deftest whisper-dvr-test-llm-spec-claude-code ()
  "Test the command line for the Claude Code harness."
  (whisper-dvr-test--with-llm-defaults
    (let* ((whisper-dvr-llm-model "sonnet")
           (spec (whisper-dvr--llm-request-spec "raw words"))
           (cmd (plist-get spec :command)))
      (should (equal (car cmd) "claude"))
      (should (member "-p" cmd))
      (should (string-match-p "transcript-parser" (nth 2 cmd)))
      (should (equal (cadr (member "--model" cmd)) "sonnet"))
      (should (member "--output-format" cmd))
      (should-not (member "--append-system-prompt" cmd))
      (should (equal (plist-get spec :stdin) "raw words")))))

(ert-deftest whisper-dvr-test-llm-spec-claude-code-embed-skill ()
  "Test that the skill text can be embedded for the harness."
  (whisper-dvr-test--with-llm-defaults
    (let* ((whisper-dvr-llm-claude-embed-skill t)
           (cmd (plist-get (whisper-dvr--llm-request-spec "x") :command)))
      (should (member "--append-system-prompt" cmd))
      (should-not (member "--model" cmd)))))

(ert-deftest whisper-dvr-test-llm-spec-command-substitutes-model ()
  "Test the generic command backend for local models."
  (whisper-dvr-test--with-llm-defaults
    (let* ((whisper-dvr-llm-backend 'command)
           (whisper-dvr-llm-model "qwen2.5:14b")
           (whisper-dvr-llm-command '("ollama" "run" "%m"))
           (spec (whisper-dvr--llm-request-spec "raw words")))
      (should (equal (plist-get spec :command) '("ollama" "run" "qwen2.5:14b")))
      (should (string-match-p "subsubsection" (plist-get spec :stdin)))
      (should (string-match-p "<transcript>\nraw words\n</transcript>"
                              (plist-get spec :stdin))))))

(ert-deftest whisper-dvr-test-llm-spec-anthropic-keeps-key-off-command-line ()
  "Test that the Anthropic request hides the key in a private file."
  (whisper-dvr-test--with-llm-defaults
    (let* ((whisper-dvr-llm-backend 'anthropic)
           (whisper-dvr-llm-api-key "sk-secret")
           (spec (whisper-dvr--llm-request-spec "raw words"))
           (cmd (plist-get spec :command))
           (files (plist-get spec :temp-files)))
      (unwind-protect
          (progn
            (should (equal (car cmd) "curl"))
            (should-not (cl-some (lambda (a) (string-match-p "sk-secret" a)) cmd))
            (should (eq (plist-get spec :parser) #'whisper-dvr--llm-parse-anthropic))
            (let ((headers (with-temp-buffer
                             (insert-file-contents (nth 0 files)) (buffer-string)))
                  (body (whisper-dvr--llm-json-read
                         (with-temp-buffer
                           (insert-file-contents (nth 1 files)) (buffer-string)))))
              (should (string-match-p "x-api-key: sk-secret" headers))
              (should (string-match-p "anthropic-version" headers))
              (should (= (file-modes (nth 0 files)) #o600))
              (should (equal (alist-get 'model body) "claude-sonnet-5-5"))
              (should (stringp (alist-get 'system body)))
              (should-not (assq 'temperature body))
              (should (string-match-p "raw words"
                                      (alist-get 'content
                                                 (aref (alist-get 'messages body) 0))))))
        (mapc #'delete-file files)))))

(ert-deftest whisper-dvr-test-llm-spec-anthropic-requires-key ()
  "Test the error when no Anthropic key is available."
  (whisper-dvr-test--with-llm-defaults
    (let ((whisper-dvr-llm-backend 'anthropic)
          (process-environment (cons "ANTHROPIC_API_KEY" process-environment)))
      (cl-letf (((symbol-function 'auth-source-pick-first-password) #'ignore))
        (should-error (whisper-dvr--llm-request-spec "x") :type 'user-error)))))

(ert-deftest whisper-dvr-test-llm-spec-openai-compatible-local ()
  "Test a local OpenAI-compatible request without an API key."
  (whisper-dvr-test--with-llm-defaults
    (let* ((whisper-dvr-llm-backend 'openai-compatible)
           (whisper-dvr-llm-model "llama3.1:8b")
           (whisper-dvr-llm-temperature 0.2)
           (process-environment (cons "OPENAI_API_KEY" process-environment)))
      (cl-letf (((symbol-function 'auth-source-pick-first-password) #'ignore))
        (let* ((spec (whisper-dvr--llm-request-spec "raw words"))
               (files (plist-get spec :temp-files)))
          (unwind-protect
              (let ((headers (with-temp-buffer
                               (insert-file-contents (nth 0 files)) (buffer-string)))
                    (body (whisper-dvr--llm-json-read
                           (with-temp-buffer
                             (insert-file-contents (nth 1 files)) (buffer-string)))))
                (should-not (string-match-p "Authorization" headers))
                (should (equal (alist-get 'model body) "llama3.1:8b"))
                (should (= (alist-get 'temperature body) 0.2))
                (should (equal (alist-get 'role (aref (alist-get 'messages body) 0))
                               "system"))
                (should (string-match-p "localhost:11434"
                                        (car (last (plist-get spec :command))))))
            (mapc #'delete-file files)))))))

(ert-deftest whisper-dvr-test-llm-backend-problem-missing-program ()
  "Test that a missing executable is reported before transcription."
  (whisper-dvr-test--with-llm-defaults
    (let ((whisper-dvr-llm-claude-program "no-such-claude-program-xyz"))
      (should (string-match-p "Cannot find" (whisper-dvr--llm-backend-problem))))
    (let ((whisper-dvr-llm-backend 'function)
          (whisper-dvr-llm-function nil))
      (should (whisper-dvr--llm-backend-problem)))
    (let ((whisper-dvr-llm-backend 'function)
          (whisper-dvr-llm-function #'ignore))
      (should-not (whisper-dvr--llm-backend-problem)))))

(ert-deftest whisper-dvr-test-llm-arm-skips-when-backend-unavailable ()
  "Test that arming warns and leaves the hooks alone on a broken backend."
  (whisper-dvr-test--with-llm-defaults
    (let ((whisper-dvr-llm-claude-program "no-such-claude-program-xyz"))
      (cl-letf (((symbol-function 'display-warning) #'ignore))
        (should-not (whisper-dvr--llm-arm "/tmp/a.mp3"))
        (should-not (memq #'whisper-dvr--llm-after-insert
                          (default-value 'whisper-after-insert-hook)))))))

(ert-deftest whisper-dvr-test-llm-deliver-replace ()
  "Test that the processed text replaces the raw transcript."
  (whisper-dvr-test--with-llm-defaults
    (with-temp-buffer
      (insert "Before. raw text After.")
      (let ((beg (copy-marker 9 t)) (end (copy-marker 17)))
        (whisper-dvr--llm-deliver (current-buffer) beg end "raw text" "PARSED")
        (should (equal (buffer-string) "Before. PARSED After."))
        (should-not (marker-buffer beg))))))

(ert-deftest whisper-dvr-test-llm-deliver-falls-back-to-append-after-edit ()
  "Test that an edited raw transcript is never overwritten."
  (whisper-dvr-test--with-llm-defaults
    (with-temp-buffer
      (insert "raw text")
      (let ((beg (copy-marker 1 t)) (end (copy-marker 9)))
        (goto-char 5) (insert "EDIT ")
        (whisper-dvr--llm-deliver (current-buffer) beg end "raw text" "PARSED")
        (should (equal (buffer-string) "raw EDIT text\n\nPARSED"))))))

(ert-deftest whisper-dvr-test-llm-deliver-append ()
  "Test the append insert method."
  (whisper-dvr-test--with-llm-defaults
    (let ((whisper-dvr-llm-insert-method 'append))
      (with-temp-buffer
        (insert "raw text")
        (whisper-dvr--llm-deliver (current-buffer) (copy-marker 1 t)
                                  (copy-marker 9) "raw text" "PARSED")
        (should (equal (buffer-string) "raw text\n\nPARSED"))))))

(ert-deftest whisper-dvr-test-llm-deliver-buffer ()
  "Test the separate buffer insert method."
  (whisper-dvr-test--with-llm-defaults
    (let ((whisper-dvr-llm-insert-method 'buffer)
          (whisper-dvr-llm-output-buffer-name " *whisper-dvr-llm-test*"))
      (cl-letf (((symbol-function 'display-buffer) #'ignore))
        (unwind-protect
            (with-temp-buffer
              (insert "raw text")
              (whisper-dvr--llm-deliver (current-buffer) (copy-marker 1 t)
                                        (copy-marker 9) "raw text" "PARSED")
              (should (equal (buffer-string) "raw text"))
              (should (string-match-p "PARSED"
                                      (with-current-buffer
                                          whisper-dvr-llm-output-buffer-name
                                        (buffer-string)))))
          (kill-buffer whisper-dvr-llm-output-buffer-name))))))

(ert-deftest whisper-dvr-test-llm-after-process-hook-receives-bounds ()
  "Test that the hook sees the bounds of the inserted result."
  (whisper-dvr-test--with-llm-defaults
    (let* ((seen nil)
           (whisper-dvr-llm-after-process-hook
            (list (lambda (b e) (setq seen (buffer-substring b e))))))
      (with-temp-buffer
        (insert "raw text")
        (whisper-dvr--llm-deliver (current-buffer) (copy-marker 1 t)
                                  (copy-marker 9) "raw text" "PARSED")
        (should (equal seen "PARSED"))))))

(ert-deftest whisper-dvr-test-llm-process-region-command-backend ()
  "Test an end-to-end asynchronous run through a real subprocess."
  (skip-unless (executable-find "sh"))
  (whisper-dvr-test--with-llm-defaults
    (let ((whisper-dvr-llm-backend 'command)
          (whisper-dvr-llm-command
           '("sh" "-c" "sed -n '/<transcript>/,/<\\/transcript>/p' | sed '1d;$d' | tr a-z A-Z")))
      (with-temp-buffer
        (insert "Intro.\nhello world\nOutro.")
        (whisper-dvr-llm-process-region 8 19)
        (whisper-dvr-test--wait-for-jobs)
        (should (equal (buffer-string) "Intro.\nHELLO WORLD\nOutro."))))))

(ert-deftest whisper-dvr-test-llm-claude-code-unsets-api-key ()
  "Test that the harness runs without ANTHROPIC_API_KEY so the Max plan login is used."
  (skip-unless (executable-find "sh"))
  (let ((script (make-temp-file "fake-claude" nil ".sh"
                                (concat "#!/bin/sh\n"
                                        "cat >/dev/null\n"
                                        "echo \"key=${ANTHROPIC_API_KEY:-unset}\"\n"))))
    (unwind-protect
        (progn
          (set-file-modes script #o755)
          (whisper-dvr-test--with-llm-defaults
            (let ((whisper-dvr-llm-claude-program script)
                  (process-environment (cons "ANTHROPIC_API_KEY=sk-should-not-leak"
                                             process-environment))
                  (result nil))
              (should (equal (plist-get (whisper-dvr--llm-request-spec "x") :unset-env)
                             '("ANTHROPIC_API_KEY")))
              (whisper-dvr-llm-process-text "raw" (lambda (r) (setq result r)))
              (whisper-dvr-test--wait-for-jobs)
              (should (equal result "key=unset"))
              ;; With the option cleared, the key reaches the harness.
              (let ((whisper-dvr-llm-claude-unset-env nil))
                (whisper-dvr-llm-process-text "raw" (lambda (r) (setq result r)))
                (whisper-dvr-test--wait-for-jobs)
                (should (equal result "key=sk-should-not-leak"))))))
      (delete-file script))))

(ert-deftest whisper-dvr-test-llm-claude-code-fake-harness ()
  "Test the harness backend against a stand-in claude script."
  (skip-unless (executable-find "sh"))
  (let ((script (make-temp-file "fake-claude" nil ".sh"
                                (concat "#!/bin/sh\n"
                                        "cat >/dev/null\n"
                                        "printf '```latex\\n\\\\subsubsection{Topic}\\n%s\\n```\\n' \"$2\" | head -c 2000\n"))))
    (unwind-protect
        (progn
          (set-file-modes script #o755)
          (whisper-dvr-test--with-llm-defaults
            (let ((whisper-dvr-llm-claude-program script))
              (with-temp-buffer
                (insert "raw transcript")
                (whisper-dvr-llm-process-region (point-min) (point-max))
                (whisper-dvr-test--wait-for-jobs)
                (should (string-prefix-p "\\subsubsection{Topic}" (buffer-string)))
                (should (string-match-p "transcript-parser skill" (buffer-string)))
                (should-not (string-match-p "```" (buffer-string)))))))
      (delete-file script))))

(ert-deftest whisper-dvr-test-llm-failure-keeps-raw-text ()
  "Test that a failing backend leaves the raw transcript untouched."
  (skip-unless (executable-find "sh"))
  (whisper-dvr-test--with-llm-defaults
    (let ((whisper-dvr-llm-backend 'command)
          (whisper-dvr-llm-command '("sh" "-c" "cat >/dev/null; echo boom >&2; exit 3"))
          (errors nil))
      (with-temp-buffer
        (insert "raw text")
        (whisper-dvr-llm-process-text "raw text" #'ignore
                                      (lambda (msg) (push msg errors)))
        (whisper-dvr-test--wait-for-jobs)
        (should (equal (buffer-string) "raw text"))
        (should (string-match-p "code 3: boom" (car errors)))
        (should (string-match-p "exit code: 3"
                                (with-current-buffer "*whisper-dvr-llm-log*"
                                  (buffer-string))))))))

(ert-deftest whisper-dvr-test-llm-failure-reports-stdout-when-stderr-empty ()
  "Test that an error printed on stdout, as Claude Code does, is reported."
  (skip-unless (executable-find "sh"))
  (whisper-dvr-test--with-llm-defaults
    (let ((whisper-dvr-llm-backend 'command)
          (whisper-dvr-llm-command
           '("sh" "-c" "cat >/dev/null; echo 'Invalid API key. Please run /login'; exit 1"))
          (errors nil))
      (whisper-dvr-llm-process-text "raw" #'ignore (lambda (m) (push m errors)))
      (whisper-dvr-test--wait-for-jobs)
      (should (string-match-p "code 1: Invalid API key" (car errors))))))

(ert-deftest whisper-dvr-test-llm-failure-detail-truncates ()
  "Test the choice and truncation of the failure detail."
  (should (equal (whisper-dvr--llm-failure-detail "err" "out") "err"))
  (should (equal (whisper-dvr--llm-failure-detail "" " out ") "out"))
  (should (string-match-p "show-log" (whisper-dvr--llm-failure-detail "" "")))
  (should (= (length (whisper-dvr--llm-failure-detail (make-string 500 ?x) ""))
             303)))

(ert-deftest whisper-dvr-test-llm-timeout ()
  "Test that a stalled backend is abandoned after the timeout."
  (skip-unless (executable-find "sh"))
  (whisper-dvr-test--with-llm-defaults
    (let ((whisper-dvr-llm-backend 'command)
          (whisper-dvr-llm-command '("sh" "-c" "sleep 10"))
          (whisper-dvr-llm-timeout 1)
          (errors nil))
      (whisper-dvr-llm-process-text "raw" #'ignore (lambda (m) (push m errors)))
      (whisper-dvr-test--wait-for-jobs 5)
      (should (string-match-p "timed out" (car errors)))
      (should-not whisper-dvr--llm-jobs))))

(ert-deftest whisper-dvr-test-llm-cancel ()
  "Test that cancel stops running jobs and reports them."
  (skip-unless (executable-find "sh"))
  (whisper-dvr-test--with-llm-defaults
    (let ((whisper-dvr-llm-backend 'command)
          (whisper-dvr-llm-command '("sh" "-c" "sleep 10"))
          (errors nil))
      (whisper-dvr-llm-process-text "raw" #'ignore (lambda (m) (push m errors)))
      (should (= (length whisper-dvr--llm-jobs) 1))
      (whisper-dvr-llm-cancel)
      (should-not whisper-dvr--llm-jobs)
      (should (equal errors '("cancelled"))))))

(ert-deftest whisper-dvr-test-llm-whisper-hook-flow ()
  "Test capture and replacement through the whisper.el hooks."
  (whisper-dvr-test--with-llm-defaults
    (let ((whisper-dvr-llm-backend 'function)
          (whisper-dvr-llm-function
           (whisper-dvr-test--sync-function-backend
            (lambda (text) (concat "\\subsubsection{Notes}\n" (upcase text))))))
      (with-temp-buffer
        (insert "Header line.\n")
        (should (whisper-dvr--llm-arm "/tmp/rec.mp3"))
        (should (memq #'whisper-dvr--llm-capture-transcript
                      (default-value 'whisper-after-transcription-hook)))
        (setq-default whisper--ffmpeg-input-file "/tmp/rec.mp3")
        (setq whisper--marker (point-marker))
        (let ((target (current-buffer)))
          ;; Simulate the whisper output buffer.
          (with-temp-buffer
            (insert "spoken words")
            (run-hooks 'whisper-after-transcription-hook))
          ;; Simulate whisper inserting the text at the marker.
          (with-current-buffer target
            (save-excursion (goto-char whisper--marker) (insert "spoken words"))
            (run-hooks 'whisper-after-insert-hook)
            (should (equal (buffer-string)
                           "Header line.\n\\subsubsection{Notes}\nSPOKEN WORDS"))))
        (should-not (memq #'whisper-dvr--llm-after-insert
                          (default-value 'whisper-after-insert-hook)))
        (should-not whisper-dvr--llm-armed-file)))
    (setq-default whisper--ffmpeg-input-file nil)))

(ert-deftest whisper-dvr-test-llm-ignores-unrelated-transcription ()
  "Test that a stale arm does not capture a different recording."
  (whisper-dvr-test--with-llm-defaults
    (let ((whisper-dvr-llm-backend 'function)
          (whisper-dvr-llm-function (whisper-dvr-test--sync-function-backend #'upcase)))
      (whisper-dvr--llm-arm "/tmp/rec.mp3")
      (setq-default whisper--ffmpeg-input-file nil)
      (with-temp-buffer
        (insert "dictation")
        (run-hooks 'whisper-after-transcription-hook))
      (should-not whisper-dvr--llm-captured)
      (should-not whisper-dvr--llm-armed-file))))

(ert-deftest whisper-dvr-test-llm-whisper-dvr-prefix-toggles ()
  "Test that a prefix argument inverts the post-processing setting."
  (whisper-dvr-test--with-llm-defaults
    (let ((armed nil)
          (whisper-dvr-directory "/test/dir"))
      (cl-letf (((symbol-function 'whisper-dvr--list-audio-files)
                 (lambda () '("/test/dir/a.mp3")))
                ((symbol-function 'whisper-dvr--format-file-entry)
                 (lambda (f) (file-name-nondirectory f)))
                ((symbol-function 'completing-read) (lambda (&rest _) "a.mp3"))
                ((symbol-function 'buffer-file-name) (lambda (&rest _) "/x.tex"))
                ((symbol-function 'whisper-run) #'ignore)
                ((symbol-function 'whisper-dvr--llm-arm)
                 (lambda (f) (setq armed f))))
        (whisper-dvr)
        (should-not armed)
        (whisper-dvr '(4))
        (should (equal armed "/test/dir/a.mp3"))
        (setq armed nil)
        (let ((whisper-dvr-llm-postprocess t))
          (whisper-dvr)
          (should armed)
          (setq armed nil)
          (whisper-dvr '(4))
          (should-not armed))))))

(ert-deftest whisper-dvr-test-llm-process-file-writes-parsed-tex ()
  "Test that a transcript file yields a _parsed.tex file beside it."
  (whisper-dvr-test--with-llm-defaults
    (let* ((dir (make-temp-file "wdvr" t))
           (file (expand-file-name "notes.txt" dir))
           (whisper-dvr-llm-backend 'function)
           (whisper-dvr-llm-function (whisper-dvr-test--sync-function-backend #'upcase)))
      (unwind-protect
          (progn
            (with-temp-file file (insert "meeting notes"))
            (should (equal (whisper-dvr-llm-process-file file)
                           (expand-file-name "notes_parsed.tex" dir)))
            (should (equal (with-temp-buffer
                             (insert-file-contents
                              (expand-file-name "notes_parsed.tex" dir))
                             (buffer-string))
                           "MEETING NOTES\n")))
        (delete-directory dir t)))))

(ert-deftest whisper-dvr-test-llm-toggle-and-select-backend ()
  "Test the interactive toggle and backend selection commands."
  (whisper-dvr-test--with-llm-defaults
    (whisper-dvr-toggle-llm-postprocess)
    (should whisper-dvr-llm-postprocess)
    (whisper-dvr-toggle-llm-postprocess)
    (should-not whisper-dvr-llm-postprocess)
    (whisper-dvr-llm-select-backend 'openai-compatible "qwen2.5:14b")
    (should (eq whisper-dvr-llm-backend 'openai-compatible))
    (should (equal whisper-dvr-llm-model "qwen2.5:14b"))
    (whisper-dvr-llm-select-backend 'anthropic "")
    (should-not whisper-dvr-llm-model)))

(ert-deftest whisper-dvr-test-llm-wait-message-shown-while-working ()
  "Test that the wait message appears at once and again after whisper clears it."
  (skip-unless (executable-find "sh"))
  (whisper-dvr-test--with-llm-defaults
    (let ((whisper-dvr-llm-backend 'command)
          (whisper-dvr-llm-command '("sh" "-c" "cat >/dev/null; sleep 1; echo done"))
          (shown 0))
      (cl-letf* ((orig (symbol-function 'message))
                 ((symbol-function 'message)
                  (lambda (fmt &rest args)
                    (when (and fmt (string-prefix-p "Please wait, the LLM is parsing"
                                                    (apply #'format fmt args)))
                      (setq shown (1+ shown)))
                    (apply orig fmt args))))
        (whisper-dvr-llm-process-text "raw" #'ignore)
        (should (= shown 1))
        (whisper-dvr-test--wait-for-jobs)
        (should (= shown 2))))))

(ert-deftest whisper-dvr-test-llm-wait-message-not-repeated-after-finish ()
  "Test that a fast backend does not leave a stale wait message."
  (whisper-dvr-test--with-llm-defaults
    (let ((whisper-dvr-llm-backend 'function)
          (whisper-dvr-llm-function (whisper-dvr-test--sync-function-backend #'upcase))
          (shown 0))
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args)
                   (when (and fmt (string-prefix-p "Please wait"
                                                   (apply #'format fmt args)))
                     (setq shown (1+ shown))))))
        (whisper-dvr-llm-process-text "raw" #'ignore)
        (sleep-for 0.7)
        (should (= shown 1))))))

(ert-deftest whisper-dvr-test-llm-wait-message-can-be-disabled ()
  "Test that a nil wait message shows nothing."
  (whisper-dvr-test--with-llm-defaults
    (let ((whisper-dvr-llm-wait-message nil)
          (whisper-dvr-llm-backend 'function)
          (whisper-dvr-llm-function (whisper-dvr-test--sync-function-backend #'upcase))
          (shown 0))
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args)
                   (when (and fmt (string-prefix-p "Please wait"
                                                   (apply #'format fmt args)))
                     (setq shown (1+ shown))))))
        (whisper-dvr-llm-process-text "raw" #'ignore)
        (sleep-for 0.7)
        (should (= shown 0))))))

(ert-deftest whisper-dvr-test-llm-rejects-empty-transcript ()
  "Test that blank text is refused before any process starts."
  (whisper-dvr-test--with-llm-defaults
    (should-error (whisper-dvr-llm-process-text "  \n" #'ignore) :type 'user-error)))

(provide 'whisper-dvr-test)
;;; whisper-dvr-test.el ends here
