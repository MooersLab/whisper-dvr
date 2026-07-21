;;; whisper-dvr-test.el --- Tests for whisper-dvr.el -*- lexical-binding: t; -*-

;; Author: Blaine Mooers
;; Keywords: test

;;; Commentary:
;; ERT test suite for whisper-dvr.el providing unit and integration tests.
;; Tests cover basic transcription, file management, and advanced filtering.

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

(defvar whisper-dvr-test--deleted-files nil
  "Track files that were deleted during tests.")

(defvar whisper-dvr-test--trashed-files nil
  "Track files that were moved to trash during tests.")

(defun whisper-dvr-test--reset-state ()
  "Reset all test state variables."
  (setq whisper-dvr-test--mock-files nil
        whisper-dvr-test--mock-attrs nil
        whisper-dvr-test--whisper-run-called nil
        whisper-dvr-test--whisper-run-arg nil
        whisper-dvr-test--deleted-files nil
        whisper-dvr-test--trashed-files nil))

(defun whisper-dvr-test--make-mock-attrs (size mtime)
  "Create mock file attributes with SIZE and MTIME."
  (list nil 1 0 0 nil mtime nil size nil nil nil nil))

(defun whisper-dvr-test--days-ago (days)
  "Return a time value representing DAYS days ago."
  (time-subtract (current-time) (days-to-time days)))

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

(ert-deftest whisper-dvr-test-use-trash-default ()
  "Test that use-trash is enabled by default."
  (should (eq whisper-dvr-use-trash t)))

(ert-deftest whisper-dvr-test-old-files-threshold-default ()
  "Test that old files threshold has a sensible default."
  (should (integerp whisper-dvr-old-files-threshold))
  (should (> whisper-dvr-old-files-threshold 0)))

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

;;; ============================================================
;;; Unit Tests: File Filtering Functions
;;; ============================================================

(ert-deftest whisper-dvr-test-file-age-days ()
  "Test file age calculation in days."
  (cl-letf (((symbol-function 'file-attributes)
             (lambda (_)
               (whisper-dvr-test--make-mock-attrs 
                1024 
                (whisper-dvr-test--days-ago 5)))))
    (let ((age (whisper-dvr--file-age-days "/test/file.mp3")))
      (should (>= age 4.9))
      (should (<= age 5.1)))))

(ert-deftest whisper-dvr-test-filter-files-by-age ()
  "Test filtering files by age."
  (let ((files '("/test/old.mp3" "/test/new.mp3")))
    (cl-letf (((symbol-function 'file-attributes)
               (lambda (file)
                 (if (string-match-p "old" file)
                     (whisper-dvr-test--make-mock-attrs 
                      1024 (whisper-dvr-test--days-ago 10))
                   (whisper-dvr-test--make-mock-attrs 
                    1024 (whisper-dvr-test--days-ago 2))))))
      (let ((old-files (whisper-dvr--filter-files-by-age files 7)))
        (should (= 1 (length old-files)))
        (should (string-match-p "old" (car old-files)))))))

(ert-deftest whisper-dvr-test-filter-files-by-size ()
  "Test filtering files by size."
  (let ((files '("/test/small.mp3" "/test/large.mp3")))
    (cl-letf (((symbol-function 'file-attributes)
               (lambda (file)
                 (if (string-match-p "small" file)
                     (whisper-dvr-test--make-mock-attrs 1024 (current-time))
                   (whisper-dvr-test--make-mock-attrs 
                    (* 20 1024 1024) (current-time))))))
      (let ((large-files (whisper-dvr--filter-files-by-size 
                          files (* 10 1024 1024))))
        (should (= 1 (length large-files)))
        (should (string-match-p "large" (car large-files)))))))

(ert-deftest whisper-dvr-test-filter-files-by-date-range ()
  "Test filtering files by date range."
  (let ((files '("/test/file1.mp3" "/test/file2.mp3" "/test/file3.mp3"))
        (start-date (encode-time 0 0 0 1 1 2024))
        (end-date (encode-time 0 0 0 31 1 2024)))
    (cl-letf (((symbol-function 'file-attributes)
               (lambda (file)
                 (cond
                  ((string-match-p "file1" file)
                   (whisper-dvr-test--make-mock-attrs 
                    1024 (encode-time 0 0 0 15 1 2024)))
                  ((string-match-p "file2" file)
                   (whisper-dvr-test--make-mock-attrs 
                    1024 (encode-time 0 0 0 15 2 2024)))
                  (t (whisper-dvr-test--make-mock-attrs 
                      1024 (encode-time 0 0 0 15 12 2023)))))))
      (let ((filtered (whisper-dvr--filter-files-by-date-range 
                       files start-date end-date)))
        (should (= 1 (length filtered)))
        (should (string-match-p "file1" (car filtered)))))))

;;; ============================================================
;;; Unit Tests: Delete File Safely
;;; ============================================================

(ert-deftest whisper-dvr-test-delete-file-safely-permanent ()
  "Test permanent file deletion."
  (whisper-dvr-test--reset-state)
  (let ((whisper-dvr-use-trash nil))
    (cl-letf (((symbol-function 'delete-file)
               (lambda (file)
                 (push file whisper-dvr-test--deleted-files)))
              ((symbol-function 'message) #'ignore))
      (should (whisper-dvr--delete-file-safely "/test/file.mp3"))
      (should (= 1 (length whisper-dvr-test--deleted-files))))))

(ert-deftest whisper-dvr-test-delete-file-safely-trash ()
  "Test moving file to trash."
  (whisper-dvr-test--reset-state)
  (let ((whisper-dvr-use-trash t))
    (cl-letf (((symbol-function 'move-file-to-trash)
               (lambda (file)
                 (push file whisper-dvr-test--trashed-files)))
              ((symbol-function 'message) #'ignore))
      (should (whisper-dvr--delete-file-safely "/test/file.mp3"))
      (should (= 1 (length whisper-dvr-test--trashed-files))))))

(ert-deftest whisper-dvr-test-delete-file-safely-handles-errors ()
  "Test error handling in delete file safely."
  (let ((whisper-dvr-use-trash nil))
    (cl-letf (((symbol-function 'delete-file)
               (lambda (_file)
                 (signal 'file-error '("Permission denied"))))
              ((symbol-function 'message) #'ignore))
      (should-not (whisper-dvr--delete-file-safely "/test/file.mp3")))))

;;; ============================================================
;;; Unit Tests: whisper-dvr-delete-files with Prefix Arg
;;; ============================================================

(ert-deftest whisper-dvr-test-delete-files-with-prefix-skips-confirmation ()
  "Test that prefix argument skips confirmation."
  (whisper-dvr-test--reset-state)
  (let ((whisper-dvr-directory "/test/dvr")
        (confirmation-called nil))
    (cl-letf (((symbol-function 'directory-files)
               (lambda (&rest _) '("file.mp3")))
              ((symbol-function 'completing-read-multiple)
               (lambda (&rest _) '("file.mp3")))
              ((symbol-function 'yes-or-no-p)
               (lambda (_)
                 (setq confirmation-called t)
                 t))
              ((symbol-function 'whisper-dvr--delete-file-safely)
               (lambda (_) t))
              ((symbol-function 'message) #'ignore))
      (whisper-dvr-delete-files t)  ; Pass non-nil prefix arg
      (should-not confirmation-called))))

(ert-deftest whisper-dvr-test-delete-files-without-prefix-requires-confirmation ()
  "Test that without prefix argument confirmation is required."
  (let ((whisper-dvr-directory "/test/dvr")
        (confirmation-called nil))
    (cl-letf (((symbol-function 'directory-files)
               (lambda (&rest _) '("file.mp3")))
              ((symbol-function 'completing-read-multiple)
               (lambda (&rest _) '("file.mp3")))
              ((symbol-function 'yes-or-no-p)
               (lambda (_)
                 (setq confirmation-called t)
                 nil))
              ((symbol-function 'message) #'ignore))
      (whisper-dvr-delete-files nil)  ; Pass nil prefix arg
      (should confirmation-called))))

;;; ============================================================
;;; Unit Tests: whisper-dvr-delete-old-files
;;; ============================================================

(ert-deftest whisper-dvr-test-delete-old-files-finds-old-files ()
  "Test that delete-old-files identifies files older than threshold."
  (whisper-dvr-test--reset-state)
  (let ((whisper-dvr-directory "/test/dvr"))
    (cl-letf (((symbol-function 'file-directory-p) (lambda (_) t))
              ((symbol-function 'directory-files)
               (lambda (&rest _) '("/test/dvr/old.mp3" "/test/dvr/new.mp3")))
              ((symbol-function 'file-attributes)
               (lambda (file)
                 (if (string-match-p "old" file)
                     (whisper-dvr-test--make-mock-attrs 
                      1024 (whisper-dvr-test--days-ago 10))
                   (whisper-dvr-test--make-mock-attrs 
                    1024 (whisper-dvr-test--days-ago 2)))))
              ((symbol-function 'yes-or-no-p) (lambda (_) t))
              ((symbol-function 'whisper-dvr--delete-file-safely)
               (lambda (file)
                 (push file whisper-dvr-test--deleted-files)
                 t))
              ((symbol-function 'message) #'ignore))
      (whisper-dvr-delete-old-files 7)
      (should (= 1 (length whisper-dvr-test--deleted-files)))
      (should (string-match-p "old" (car whisper-dvr-test--deleted-files))))))

(ert-deftest whisper-dvr-test-delete-old-files-no-old-files ()
  "Test message when no old files are found."
  (let ((whisper-dvr-directory "/test/dvr")
        (message-text nil))
    (cl-letf (((symbol-function 'file-directory-p) (lambda (_) t))
              ((symbol-function 'directory-files)
               (lambda (&rest _) '("/test/dvr/new.mp3")))
              ((symbol-function 'file-attributes)
               (lambda (_)
                 (whisper-dvr-test--make-mock-attrs 
                  1024 (whisper-dvr-test--days-ago 2))))
              ((symbol-function 'message)
               (lambda (fmt &rest args)
                 (setq message-text (apply #'format fmt args)))))
      (whisper-dvr-delete-old-files 7)
      (should (string-match-p "No files older" message-text)))))

;;; ============================================================
;;; Unit Tests: whisper-dvr-delete-large-files
;;; ============================================================

(ert-deftest whisper-dvr-test-delete-large-files-finds-large-files ()
  "Test that delete-large-files identifies files above size threshold."
  (whisper-dvr-test--reset-state)
  (let ((whisper-dvr-directory "/test/dvr"))
    (cl-letf (((symbol-function 'file-directory-p) (lambda (_) t))
              ((symbol-function 'directory-files)
               (lambda (&rest _) '("/test/dvr/large.mp3" "/test/dvr/small.mp3")))
              ((symbol-function 'file-attributes)
               (lambda (file)
                 (if (string-match-p "large" file)
                     (whisper-dvr-test--make-mock-attrs 
                      (* 20 1024 1024) (current-time))
                   (whisper-dvr-test--make-mock-attrs 
                    1024 (current-time)))))
              ((symbol-function 'yes-or-no-p) (lambda (_) t))
              ((symbol-function 'whisper-dvr--delete-file-safely)
               (lambda (file)
                 (push file whisper-dvr-test--deleted-files)
                 t))
              ((symbol-function 'message) #'ignore))
      (whisper-dvr-delete-large-files (* 10 1024 1024))
      (should (= 1 (length whisper-dvr-test--deleted-files)))
      (should (string-match-p "large" (car whisper-dvr-test--deleted-files))))))

;;; ============================================================
;;; Unit Tests: whisper-dvr-delete-by-date-range
;;; ============================================================

(ert-deftest whisper-dvr-test-delete-by-date-range-filters-correctly ()
  "Test that delete-by-date-range filters files by date correctly."
  (whisper-dvr-test--reset-state)
  (let ((whisper-dvr-directory "/test/dvr")
        (start-date (encode-time 0 0 0 1 1 2024))
        (end-date (encode-time 0 0 0 31 1 2024)))
    (cl-letf (((symbol-function 'file-directory-p) (lambda (_) t))
              ((symbol-function 'directory-files)
               (lambda (&rest _) 
                 '("/test/dvr/jan.mp3" "/test/dvr/feb.mp3")))
              ((symbol-function 'file-attributes)
               (lambda (file)
                 (if (string-match-p "jan" file)
                     (whisper-dvr-test--make-mock-attrs 
                      1024 (encode-time 0 0 0 15 1 2024))
                   (whisper-dvr-test--make-mock-attrs 
                    1024 (encode-time 0 0 0 15 2 2024)))))
              ((symbol-function 'yes-or-no-p) (lambda (_) t))
              ((symbol-function 'whisper-dvr--delete-file-safely)
               (lambda (file)
                 (push file whisper-dvr-test--deleted-files)
                 t))
              ((symbol-function 'message) #'ignore))
      (whisper-dvr-delete-by-date-range start-date end-date)
      (should (= 1 (length whisper-dvr-test--deleted-files)))
      (should (string-match-p "jan" (car whisper-dvr-test--deleted-files))))))

;;; ============================================================
;;; Unit Tests: Dired Integration
;;; ============================================================

(ert-deftest whisper-dvr-test-dired-opens-directory ()
  "Test that whisper-dvr-dired opens the DVR directory."
  (let ((whisper-dvr-directory "/test/dvr")
        (opened-dir nil))
    (cl-letf (((symbol-function 'file-directory-p) (lambda (_) t))
              ((symbol-function 'dired)
               (lambda (dir)
                 (setq opened-dir dir)))
              ((symbol-function 'message) #'ignore))
      (whisper-dvr-dired)
      (should (string= "/test/dvr" opened-dir)))))

(ert-deftest whisper-dvr-test-dired-delete-marked-requires-dired-mode ()
  "Test that dired-delete-marked requires dired-mode."
  (with-temp-buffer
    (should-error (whisper-dvr-dired-delete-marked) :type 'user-error)))

;;; ============================================================
;;; Integration Tests
;;; ============================================================

(ert-deftest whisper-dvr-test-integration-trash-vs-permanent ()
  "Integration test comparing trash vs permanent deletion."
  (whisper-dvr-test--reset-state)
  (let ((whisper-dvr-directory "/test/dvr"))
    ;; Test with trash
    (let ((whisper-dvr-use-trash t))
      (cl-letf (((symbol-function 'directory-files)
                 (lambda (&rest _) '("file.mp3")))
                ((symbol-function 'completing-read-multiple)
                 (lambda (&rest _) '("file.mp3")))
                ((symbol-function 'yes-or-no-p) (lambda (_) t))
                ((symbol-function 'move-file-to-trash)
                 (lambda (file)
                   (push file whisper-dvr-test--trashed-files)))
                ((symbol-function 'message) #'ignore))
        (whisper-dvr-delete-files)
        (should (= 1 (length whisper-dvr-test--trashed-files)))))
    ;; Reset and test without trash
    (whisper-dvr-test--reset-state)
    (let ((whisper-dvr-use-trash nil))
      (cl-letf (((symbol-function 'directory-files)
                 (lambda (&rest _) '("file.mp3")))
                ((symbol-function 'completing-read-multiple)
                 (lambda (&rest _) '("file.mp3")))
                ((symbol-function 'yes-or-no-p) (lambda (_) t))
                ((symbol-function 'delete-file)
                 (lambda (file)
                   (push file whisper-dvr-test--deleted-files)))
                ((symbol-function 'message) #'ignore))
        (whisper-dvr-delete-files)
        (should (= 1 (length whisper-dvr-test--deleted-files)))))))

(ert-deftest whisper-dvr-test-integration-old-files-workflow ()
  "Integration test for complete old files deletion workflow."
  (whisper-dvr-test--reset-state)
  (let ((whisper-dvr-directory "/test/dvr")
        (whisper-dvr-use-trash t))
    (cl-letf (((symbol-function 'file-directory-p) (lambda (_) t))
              ((symbol-function 'directory-files)
               (lambda (&rest _)
                 '("/test/dvr/old1.mp3" "/test/dvr/old2.mp3" 
                   "/test/dvr/new.mp3")))
              ((symbol-function 'file-attributes)
               (lambda (file)
                 (if (string-match-p "old" file)
                     (whisper-dvr-test--make-mock-attrs 
                      1024 (whisper-dvr-test--days-ago 30))
                   (whisper-dvr-test--make-mock-attrs 
                    1024 (whisper-dvr-test--days-ago 2)))))
              ((symbol-function 'yes-or-no-p) (lambda (_) t))
              ((symbol-function 'move-file-to-trash)
               (lambda (file)
                 (push file whisper-dvr-test--trashed-files)))
              ((symbol-function 'message) #'ignore))
      (whisper-dvr-delete-old-files 7)
      (should (= 2 (length whisper-dvr-test--trashed-files)))
      (should (cl-every (lambda (f) (string-match-p "old" f))
                        whisper-dvr-test--trashed-files)))))

;;; ============================================================
;;; Edge Cases
;;; ============================================================

(ert-deftest whisper-dvr-test-edge-case-zero-days-threshold ()
  "Test handling of zero days threshold."
  (let ((whisper-dvr-directory "/test/dvr")
        (message-text nil))
    (cl-letf (((symbol-function 'file-directory-p) (lambda (_) t))
              ((symbol-function 'directory-files)
               (lambda (&rest _) '("/test/dvr/file.mp3")))
              ((symbol-function 'file-attributes)
               (lambda (_)
                 (whisper-dvr-test--make-mock-attrs 1024 (current-time))))
              ((symbol-function 'yes-or-no-p) (lambda (_) t))
              ((symbol-function 'whisper-dvr--delete-file-safely)
               (lambda (_) t))
              ((symbol-function 'message)
               (lambda (fmt &rest args)
                 (setq message-text (apply #'format fmt args)))))
      (whisper-dvr-delete-old-files 0)
      (should (string-match-p "complete" message-text)))))

(ert-deftest whisper-dvr-test-edge-case-empty-date-range ()
  "Test handling of date range with no files."
  (let ((whisper-dvr-directory "/test/dvr")
        (start-date (encode-time 0 0 0 1 6 2024))
        (end-date (encode-time 0 0 0 30 6 2024))
        (message-text nil))
    (cl-letf (((symbol-function 'file-directory-p) (lambda (_) t))
              ((symbol-function 'directory-files)
               (lambda (&rest _) '("/test/dvr/file.mp3")))
              ((symbol-function 'file-attributes)
               (lambda (_)
                 (whisper-dvr-test--make-mock-attrs 
                  1024 (encode-time 0 0 0 15 1 2024))))
              ((symbol-function 'message)
               (lambda (fmt &rest args)
                 (setq message-text (apply #'format fmt args)))))
      (whisper-dvr-delete-by-date-range start-date end-date)
      (should (string-match-p "No files found" message-text)))))

(provide 'whisper-dvr-test)
;;; whisper-dvr-test.el ends here
