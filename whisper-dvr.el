;;; whisper-dvr.el --- Transcribe MP3 files from DVR with whisper.el -*- lexical-binding: t; -*-

;; Author: Blaine Mooers
;; Keywords: multimedia, convenience
;; Package-Requires: ((emacs "27.1") (whisper "0.1"))

;;; Commentary:
;; This package provides a function to list and transcribe MP3 files
;; from a digital voice recorder using the whisper.el package.

;;; Code:

(require 'whisper)

(defgroup whisper-dvr nil
  "Settings for DVR transcription with whisper.el."
  :group 'multimedia
  :prefix "whisper-dvr-")

(defcustom whisper-dvr-directory "/Volumes/IC RECORDER/REC_FILE/FOLDER01"
  "Directory path containing MP3 files from the digital voice recorder.
This path should point to the folder where your DVR stores recordings."
  :type 'directory
  :group 'whisper-dvr)

(defcustom whisper-dvr-file-extensions '("mp3" "wav" "m4a")
  "List of audio file extensions to include when listing files."
  :type '(repeat string)
  :group 'whisper-dvr)

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

;;;###autoload
(defun whisper-dvr ()
  "List MP3 files from DVR and transcribe selected file with whisper.el.
The transcription is inserted at point in the current buffer.
The current buffer must be writable for this function to proceed."
  (interactive)
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
      ;; Call whisper-file with the selected file
      (whisper-run selected-file))))

;;;###autoload
(defun whisper-dvr-set-directory (dir)
  "Set the DVR directory to DIR interactively."
  (interactive "DSet DVR directory: ")
  (setq whisper-dvr-directory (expand-file-name dir))
  (message "DVR directory set to: %s" whisper-dvr-directory))

(provide 'whisper-dvr)
;;; whisper-dvr.el ends here
