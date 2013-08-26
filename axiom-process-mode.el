;;; axiom-process-mode.el -- a Comint-derived mode for Axiom

;; Copyright (C) 2013 Paul Onions

;; Author: Paul Onions <paul.onions@acm.org>
;; Keywords: Axiom, OpenAxiom, FriCAS

;; This file is free software, see the LICENCE file in this directory
;; for copying terms.

;;; Commentary:

;; A mode for interacting with a running Axiom process.

;;; Code:

(require 'axiom-base)
(require 'comint)

(defcustom axiom-process-buffer-name "*Axiom REPL*"
  "Axiom process buffer name.

Must begin and end with an asterisk."
  :type 'string
  :group 'axiom)

(defcustom axiom-process-program "fricas -nosman"
  "Command line to invoke the Axiom process."
  :type 'string
  :group 'axiom)

(defcustom axiom-process-prompt-regexp "^.*([[:digit:]]+) ->"
  "Regexp to recognize prompts from the Axiom process."
  :type 'regexp
  :group 'axiom)

(defcustom axiom-process-break-prompt-regexp "^0]"
  "Regexp to recognize a Lisp BREAK prompt."
  :type 'regexp
  :group 'axiom)

(defcustom axiom-process-preamble ""
  "Initial commands to push to the Axiom process."
  :type 'string
  :group 'axiom)

(defcustom axiom-process-compile-file-result-directory ""
  "Directory in which to place compilation results.

Only used when variable
`axiom-process-compile-file-use-result-directory' is non-NIL."
  :type 'string
  :group 'axiom)

(defcustom axiom-process-compile-file-use-result-directory nil
  "Non-nil to place compilation results in a central directory.

When non-nil place results in variable
`axiom-process-compile-file-result-directory', otherwise they will be
placed in the same directory as the source file."
  :type 'boolean
  :group 'axiom)

(defcustom axiom-process-compile-file-buffer-name "*Axiom Compilation*"
  "A buffer in which to echo compiler output."
  :type 'string
  :group 'axiom)

(defcustom axiom-process-query-buffer-name "*Axiom Query*"
  "Axiom process query result buffer name."
  :type 'string
  :group 'axiom)

(defvar axiom-process-mode-hook nil
  "Hook for customizing `axiom-process-mode'.")

(defvar axiom-process-mode-map
  (let ((map (copy-keymap axiom-common-keymap)))
    (set-keymap-parent map comint-mode-map)
    map)
  "Keymap for `axiom-process-mode'.")

(defvar axiom-process-schedule-cd-update nil
  "Set non-nil to schedule a default-directory synchronization update.")

(defvar axiom-process-not-running-message
  "Axiom process not running, try M-x run-axiom")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Utility macros
;;
(defmacro with-axiom-process-query-buffer (&rest body)
  "Set current-buffer to a query result buffer, with dynamic extent.

Use this instead of `with-temp-buffer' so that the buffer can be
easily examined when things go wrong.  The buffer switched to is
actually the buffer called `axiom-process-query-buffer-name', which is
cleared when the dynamic extent of this form is entered.

IMPORTANT NOTE: Unlike `with-temp-buffer', this means that nested
calls are NOT ALLOWED."
  `(with-current-buffer (get-buffer-create axiom-process-query-buffer-name)
     (fundamental-mode)
     (erase-buffer)
     ,@body))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Command utility functions
;;
(defun axiom-process-insert-command (command)
  "Send COMMAND, a string, to the running Axiom process.

The COMMAND and its output are inserted in the Axiom process buffer at
the current process-mark, which may be before the end of the buffer if
the user is part-way through editing the next command."
  (with-current-buffer axiom-process-buffer-name
    (let ((proc (get-buffer-process (current-buffer)))
          (command-text command)
          (pending-text ""))
      ;; Remove newlines from end of command string
      (while (and (> (length command-text) 0)
                  (char-equal ?\n (aref command-text (1- (length command-text)))))
        (setq command-text (substring command-text 0 (- (length command-text) 2))))
      ;; Contrary to what it says in the documentation of `comint-send-input',
      ;; calling it sends _all_ text from the process mark to the _end_ of
      ;; the buffer to the process.  So we need to temporarily remove any
      ;; text the user is currently typing at the end of the buffer before
      ;; calling `comint-send-input', then restore it afterwards.
      (when (> (point-max) (process-mark proc))
        (setq pending-text (delete-and-extract-region (process-mark proc) (point-max))))
      (goto-char (process-mark proc))
      (insert command-text)
      (comint-send-input nil t)
      (insert pending-text))))

(defun axiom-process-redirect-send-command (command output-buffer &optional display echo-cmd echo-result)
  "Send COMMAND to Axiom and put result in OUTPUT-BUFFER.

If DISPLAY is non-nil then display the result buffer.

If ECHO-CMD is non-nil then copy the command to the process buffer,
and if ECHO-RESULT is non-nil then also copy the result too."
  (with-current-buffer axiom-process-buffer-name
    (save-excursion
      (let ((proc (get-buffer-process (current-buffer))))
        (when echo-cmd
          (goto-char (process-mark proc))
          (insert-before-markers command))
        (comint-redirect-send-command command output-buffer echo-result (not display))
        (while (not comint-redirect-completed)
          (accept-process-output proc))
        (when (and echo-cmd (not echo-result))  ; get prompt back
          (axiom-process-insert-command ""))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Directory tracking -- track Axiom's notion of ``current directory''
;;
(defun axiom-process-cd-input-filter (str)
  "Detect when a command that may change the current directory.

This function to be added to the `comint-input-filter-functions'
list."
  (axiom-debug-message (format "A-P-CD-I-F -->%s<--" str))
  (when (or (string-match "^)cd" str)
            (string-match "^)read" str))
    (setq axiom-process-schedule-cd-update t))
  str)

(defun axiom-process-cd-output-filter (str)
  "Invoke synchronization of the current directory when scheduled.

This function to be added to the end of
`comint-output-filter-functions'."
  (when (and (string-match axiom-process-prompt-regexp str)
             axiom-process-schedule-cd-update)
    (setq axiom-process-schedule-cd-update nil)
    (axiom-process-force-cd-update)))

(defun axiom-process-force-cd-update (&optional no-msg)
  "Force update of variable `default-directory' by querying Axiom.

Also return the directory as a string.  If NO-MSG is non-nil then
don't display the default-directory in a message."
  (interactive)
  (let ((dirname nil))
    (with-axiom-process-query-buffer
      (axiom-process-redirect-send-command ")cd ." (current-buffer))
      (goto-char (point-min))
      (let ((dirname-start (search-forward-regexp "default directory is[[:space:]]+" nil t))
            (dirname-end (progn
                           (search-forward-regexp "[[:blank:]]*$" nil t)
                           (match-beginning 0))))
        (when (and dirname-start dirname-end)
          (setq dirname (expand-file-name (file-name-as-directory (buffer-substring dirname-start dirname-end)))))
        (axiom-debug-message (format "CD: %S %S %S" dirname-start dirname-end dirname))))
    (when dirname
      (with-current-buffer axiom-process-buffer-name
        (setq default-directory dirname)
        (unless no-msg
          (message (format "Current directory now: %s" dirname)))))
    dirname))
  
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Evaluating a region
;;
(defun axiom-process-eval-region (start end)
  "Evaluate the given region in the Axiom process."
  (interactive "r")
  (if (null (get-buffer axiom-process-buffer-name))
      (message axiom-process-not-running-message)
    (progn
      (display-buffer axiom-process-buffer-name)
      (axiom-process-insert-command (buffer-substring-no-properties start end)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Reading and compiling files
;;
(defun axiom-process-read-file (filename &optional no-display)
  "Tell the Axiom process to read FILENAME.

If NO-DISPLAY is nil then also display the Axiom process buffer."
  (interactive (list (read-file-name "Read file: " nil nil nil (file-name-nondirectory (or (buffer-file-name) "")))
                     current-prefix-arg))
  (if (not (get-buffer axiom-process-buffer-name))
      (message axiom-process-not-running-message)
    (progn
      (unless no-display
        (display-buffer axiom-process-buffer-name))
      (axiom-process-insert-command (format ")read %s" (expand-file-name filename))))))

(defun axiom-process-compile-file (filename &optional no-display)
  "Tell the Axiom process to compile FILENAME.

If NO-DISPLAY is nil then display the Axiom compilation results
buffer, otherwise do not display it."
  (interactive (list (read-file-name "Compile file: " nil nil nil (file-name-nondirectory (or (buffer-file-name) "")))
                     current-prefix-arg))
  (if (not (get-buffer axiom-process-buffer-name))
      (message axiom-process-not-running-message)
    (progn
      (unless no-display
        (display-buffer (get-buffer-create axiom-process-compile-file-buffer-name)))
      (with-current-buffer axiom-process-buffer-name
        (let ((current-dir (axiom-process-force-cd-update t))
              (result-dir (if axiom-process-compile-file-use-result-directory
                              (file-name-as-directory (expand-file-name axiom-process-compile-file-result-directory))
                            (file-name-directory (expand-file-name filename)))))
          (with-current-buffer (get-buffer-create axiom-process-compile-file-buffer-name)
            (erase-buffer)
            (axiom-process-redirect-send-command (format ")cd %s" result-dir) (current-buffer) (not no-display))
            (axiom-process-redirect-send-command (format ")compile %s" (expand-file-name filename)) (current-buffer) (not no-display))
            (axiom-process-redirect-send-command (format ")cd %s" current-dir) (current-buffer) (not no-display))))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Browsing/inspection utility functions
;;
(defun axiom-process-package-name (name-or-abbrev)
  (let ((rslt (assoc name-or-abbrev axiom-standard-package-info)))
    (if rslt
        (cdr rslt)
      name-or-abbrev)))

(defun axiom-process-domain-name (name-or-abbrev)
  (let ((rslt (assoc name-or-abbrev axiom-standard-domain-info)))
    (if rslt
        (cdr rslt)
      name-or-abbrev)))

(defun axiom-process-category-name (name-or-abbrev)
  (let ((rslt (assoc name-or-abbrev axiom-standard-category-info)))
    (if rslt
        (cdr rslt)
      name-or-abbrev)))

(defun axiom-process-constructor-type (name-or-abbrev)
  (cond ((member name-or-abbrev axiom-standard-package-names)
         (cons :package :name))
        ((member name-or-abbrev axiom-standard-package-abbreviations)
         (cons :package :abbrev))
        ((member name-or-abbrev axiom-standard-domain-names)
         (cons :domain :name))
        ((member name-or-abbrev axiom-standard-domain-abbreviations)
         (cons :domain :abbrev))
        ((member name-or-abbrev axiom-standard-category-names)
         (cons :category :name))
        ((member name-or-abbrev axiom-standard-category-abbreviations)
         (cons :category :abbrev))
        (t
         (cons :constructor :unknown))))

(defun axiom-process-constructor-buffer-name (name-or-abbrev)
  (let ((ctype (car (axiom-process-constructor-type name-or-abbrev))))
    (format "*Axiom %s: %s*"
            (capitalize (subseq (symbol-name ctype) 1))
            (cond ((eq ctype :package)
                   (axiom-process-package-name name-or-abbrev))
                  ((eq ctype :domain)
                   (axiom-process-domain-name name-or-abbrev))
                  ((eq ctype :category)
                   (axiom-process-category-name name-or-abbrev))
                  (t
                   name-or-abbrev)))))

(defun axiom-process-show-constructor (name-or-abbrev &optional force-update)
  "Show information about NAME-OR-ABBREV in a popup buffer.

Works by calling ``)show NAME-OR-ABBREV'' in the Axiom process and
capturing its output.  When called interactively completion is
performed over all standard constructor names (packages, domains and
categories) and their abbreviations.

If the buffer already exists (from a previous call) then just switch
to it, unless FORCE-UPDATE is non-nil in which case the buffer is
reconstructed with another query to the Axiom process.

Interactively, FORCE-UPDATE can be set with a prefix argument."
  (interactive (list (completing-read "Constructor: "
                                      axiom-standard-constructor-names-and-abbreviations)
                     current-prefix-arg))
  (if (not (get-buffer axiom-process-buffer-name))
      (message axiom-process-not-running-message)
    (unless (equal "" name-or-abbrev)
      (let ((bufname (axiom-process-constructor-buffer-name name-or-abbrev)))
        (if (and (get-buffer bufname) (not force-update))
            (display-buffer bufname)
          (with-current-buffer (get-buffer-create bufname)
            (setq buffer-read-only nil)
            (erase-buffer)
            (axiom-help-mode)
            (axiom-process-redirect-send-command (format ")show %s" name-or-abbrev) (current-buffer) t nil nil)
            (set-buffer-modified-p nil)
            (setq buffer-read-only t)))))))

(defun axiom-process-show-package (name-or-abbrev &optional force-update)
  "Show information about NAME-OR-ABBREV in a popup buffer.

Works by calling ``)show NAME-OR-ABBREV'' in the Axiom process and
capturing its output.  When called interactively completion is
performed over all standard package names.

If the buffer already exists (from a previous call) then just switch
to it, unless FORCE-UPDATE is non-nil in which case the buffer is
reconstructed with another query to the Axiom process.

Interactively, FORCE-UPDATE can be set with a prefix argument."
  (interactive (list (completing-read "Package: "
                                      axiom-standard-package-names-and-abbreviations)
                     current-prefix-arg))
  (axiom-process-show-constructor name-or-abbrev force-update))

(defun axiom-process-show-domain (name-or-abbrev &optional force-update)
  "Show information about NAME-OR-ABBREV in a popup buffer.

Works by calling ``)show NAME-OR-ABBREV'' in the Axiom process and
capturing its output.  When called interactively completion is
performed over all standard domain names.

If the buffer already exists (from a previous call) then just switch
to it, unless FORCE-UPDATE is non-nil in which case the buffer is
reconstructed with another query to the Axiom process.

Interactively, FORCE-UPDATE can be set with a prefix argument."
  (interactive (list (completing-read "Domain: "
                                      axiom-standard-domain-names-and-abbreviations)
                     current-prefix-arg))
  (axiom-process-show-constructor name-or-abbrev force-update))

(defun axiom-process-show-category (name-or-abbrev &optional force-update)
  "Show information about NAME-OR-ABBREV in a popup buffer.

Works by calling ``)show NAME-OR-ABBREV'' in the Axiom process and
capturing its output.  When called interactively completion is
performed over all standard category names.

If the buffer already exists (from a previous call) then just switch
to it, unless FORCE-UPDATE is non-nil in which case the buffer is
reconstructed with another query to the Axiom process.

Interactively, FORCE-UPDATE can be set with a prefix argument."
  (interactive (list (completing-read "Category: "
                                      axiom-standard-category-names-and-abbreviations)
                     current-prefix-arg))
  (axiom-process-show-constructor name-or-abbrev force-update))

(defun axiom-process-display-operation (operation-name &optional force-update)
  "Show information about OPERATION-NAME in a popup buffer.

Works by calling ``)display operation OPERATION-NAME'' in the Axiom
process and capturing its output.  When called interactively
completion is performed over all standard operation names.

If the buffer already exists (from a previous call) then just switch
to it, unless FORCE-UPDATE is non-nil in which case the buffer is
reconstructed with another query to the Axiom process.

Interactively, FORCE-UPDATE can be set with a prefix argument."
  (interactive (list (completing-read "Operation: " axiom-standard-operation-names)
                     current-prefix-arg))
  (if (not (get-buffer axiom-process-buffer-name))
      (message axiom-process-not-running-message)
    (unless (equal "" operation-name)
      (let ((bufname (format "*Axiom Operation: %s*" operation-name)))
        (if (and (get-buffer bufname) (not force-update))
            (display-buffer bufname)
          (with-current-buffer (get-buffer-create bufname)
            (setq buffer-read-only nil)
            (erase-buffer)
            (axiom-help-mode)
            (axiom-process-redirect-send-command (format ")display operation %s" operation-name) (current-buffer) t nil nil)
            (set-buffer-modified-p nil)
            (setq buffer-read-only t)))))))

(defun axiom-process-apropos-thing-at-point (name &optional is-constructor)
  "Show information about NAME in a popup buffer.

When called interactively NAME defaults to the word around point, and
completion is performed over all standard constructor and operation
names.

If NAME is a standard constructor name then call ``)show NAME'' in the
Axiom process and capture its output, otherwise assume it's an
operation name and call ``)display operation NAME'' instead.  This can
be overridden by setting IS-CONSTRUCTOR non-nil, in which case ``)show
NAME'' will always be called.  Interactively this can be done with a
prefix argument."
  (interactive (list (completing-read "Apropos: " axiom-standard-names-and-abbreviations
                                      nil nil (thing-at-point 'word))
                     current-prefix-arg))
  (if (not (get-buffer axiom-process-buffer-name))
      (message axiom-process-not-running-message)
    (unless (equal "" name)
      (cond ((or (member name axiom-standard-constructor-names-and-abbreviations) is-constructor)
             (axiom-process-show-constructor name t))
            (t
             (axiom-process-display-operation name t))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Axiom process mode -- derived from COMINT mode
;;
(defvar axiom-process-package-face  'axiom-package-name)
(defvar axiom-process-domain-face   'axiom-domain-name)
(defvar axiom-process-category-face 'axiom-category-name)

(defvar axiom-process-font-lock-keywords
  (list (cons axiom-standard-package-names-regexp          'axiom-process-package-face)
        (cons axiom-standard-package-abbreviations-regexp  'axiom-process-package-face)
        (cons axiom-standard-domain-names-regexp           'axiom-process-domain-face)
        (cons axiom-standard-domain-abbreviations-regexp   'axiom-process-domain-face)
        (cons axiom-standard-category-names-regexp         'axiom-process-category-face)
        (cons axiom-standard-category-abbreviations-regexp 'axiom-process-category-face)))

(define-derived-mode axiom-process-mode comint-mode "Axiom Process"
  "Major mode for interaction with a running Axiom process."
  :group 'axiom
  (setq comint-prompt-regexp (concat "\\(" axiom-process-prompt-regexp
                                     "\\|" axiom-process-break-prompt-regexp "\\)"))
  (add-hook 'comint-input-filter-functions (function axiom-process-cd-input-filter))
  (add-hook 'comint-output-filter-functions (function axiom-process-cd-output-filter))
  (setq font-lock-defaults (list axiom-process-font-lock-keywords))
  (setq axiom-menu-read-file-enable t)
  (setq axiom-menu-compile-file-enable t)
  (unless (equal "" axiom-process-preamble)
    (axiom-process-insert-command axiom-process-preamble))
  (setq axiom-process-schedule-cd-update t))

(defun axiom-process-start (cmd)
  "Start an Axiom process in a buffer using command line CMD.

The name of the buffer is given by variable
`axiom-process-buffer-name', and uses major mode `axiom-process-mode'.
With a prefix argument, allow CMD to be edited first (default is value
of `axiom-process-program').  If there is a process already running
then simply switch to it."
  (interactive (list (if current-prefix-arg
			 (read-string "Run Axiom: " axiom-process-program)
		       axiom-process-program)))
  (when (not (comint-check-proc axiom-process-buffer-name))
    (let ((cmdlist (split-string cmd)))
      (set-buffer (apply (function make-comint)
                         (substring axiom-process-buffer-name 1 -1)
                         (car cmdlist) nil (cdr cmdlist)))
      (axiom-process-mode)))
  (pop-to-buffer axiom-process-buffer-name))

(defalias 'run-axiom 'axiom-process-start)

(provide 'axiom-process-mode)
