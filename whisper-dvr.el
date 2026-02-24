;;; whisper-dvr.el --- Transcribe MP3 files from DVR with whisper.el -*- lexical-binding: t; -*-

;; Author: Blaine Mooers
;; Keywords: multimedia, convenience
;; Package-Requires: ((emacs "27.1") (whisper "0.1"))
;; Version: 0.3.0

;;; Commentary:
;; This package provides functions to list, transcribe, and manage MP3 files
;; from a digital voice recorder using the whisper.el package.

;;; Code:

(require 'whisper)
(require 'dired)

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

(defcustom whisper-dvr-volume-mount-points '("/Volumes/SDK" "/Volumes/IC RECORDER")
  "List of mount points (volumes) to unmount when ejecting the DVR.
On macOS these are paths under /Volumes/.
On Linux these are mount points such as /media/<user>/<label>.
On Windows these are drive letters such as \"E:\" or \"F:\"."
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

;;;###autoload
(defun whisper-dvr-delete-files (&optional no-confirm)
  "Select and delete audio files from the DVR.
Allows multiple file selection using completing-read-multiple.
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
                   (format "%s %d file(s)? %s"
                           (if whisper-dvr-use-trash 
                               "Move to trash" 
                               "Permanently delete")
                           (length selected-files)
                           (mapconcat #'identity selected-files ", "))))
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
                 (format "%s %d file(s) older than %d days?\n%s"
                         (if whisper-dvr-use-trash 
                             "Move to trash" 
                             "Permanently delete")
                         (length old-files)
                         days
                         (mapconcat #'identity old-file-names "\n"))))
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
                 (format "%s %d file(s) larger than %s?\n%s"
                         (if whisper-dvr-use-trash 
                             "Move to trash" 
                             "Permanently delete")
                         (length large-files)
                         (file-size-human-readable min-size)
                         (mapconcat #'identity large-file-info "\n"))))
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
                 (format "%s %d file(s) from %s to %s?\n%s"
                         (if whisper-dvr-use-trash 
                             "Move to trash" 
                             "Permanently delete")
                         (length filtered-files)
                         (format-time-string "%Y-%m-%d" start-date)
                         (format-time-string "%Y-%m-%d" end-date)
                         (mapconcat #'identity file-info "\n"))))
        (let ((success-count 0))
          (dolist (file filtered-files)
            (when (whisper-dvr--delete-file-safely file)
              (setq success-count (1+ success-count))))
          (message "%s complete. %d of %d file(s) processed successfully."
                   (if whisper-dvr-use-trash "Move to trash" "Deletion")
                   success-count
                   (length filtered-files)))))))

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
Allows marking files with `m' and deleting marked files with `whisper-dvr-dired-delete-marked'."
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
- 'new-only: Only transcribe files not previously processed
- 'all: Transcribe all files on device
- 'modified: Transcribe files modified since last connection"
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
  :protocol - 'ssh or 'sftp
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
Currently supported: 'dropbox, 'google-drive, 'icloud"
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
- 'audio-only: Upload only audio files
- 'transcript-only: Upload only transcript files
- 'both: Upload both audio and transcripts"
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
Set to 'auto to use system language, or specify language code:
'en (English), 'es (Spanish), 'fr (French), 'de (German),
'ja (Japanese), 'zh (Chinese), 'ko (Korean)"
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

(defun whisper-dvr--poll-devices ()
  "Poll for device changes and trigger appropriate hooks."
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
  "Transcribe batch of FILES from DEVICE with progress tracking."
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
     (format "Completed: %d, Failed: %d" completed failed)
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
      (let ((name (plist-get config :name))
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
  (error "iCloud integration not yet implemented"))

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
  (let* ((token (or (getenv "DROPBOX_ACCESS_TOKEN")
                   (read-passwd "Dropbox access token: ")))
         (folder (plist-get config :folder))
         (filename (file-name-nondirectory file-path))
         (remote-path (concat folder "/" filename))
         (client (whisper-dvr--dropbox-client))
         (upload-fn (plist-get client :upload)))
    (if (funcall upload-fn file-path remote-path)
        (message "Uploaded to Dropbox: %s" filename)
      (error "Failed to upload to Dropbox"))))

(defun whisper-dvr--upload-to-google-drive (file-path config)
  "Upload FILE-PATH to Google Drive using CONFIG.
Placeholder implementation."
  (error "Google Drive upload not yet implemented"))

(defun whisper-dvr--upload-to-onedrive (file-path config)
  "Upload FILE-PATH to OneDrive using CONFIG.
Placeholder implementation."
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
  "Detect system language from environment.
Returns language symbol (en, es, fr, etc.) or 'en as fallback."
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
LANGUAGE should be a symbol: 'en, 'es, 'fr, 'de, 'ja, 'zh, 'ko, or 'auto."
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
   (whisper-dvr-tr 'ejection-failed volume-name)
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
