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

(provide 'whisper-dvr-test)
;;; whisper-dvr-test.el ends here
