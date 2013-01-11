;;; full-ag.el --- a front-end for ag
;;; -*- lexical-binding: t -*-
;;
;; Copyright (C) 2009-2011 Nikolaj Schumacher
;;
;; Author: Nikolaj Schumacher <bugs * nschum de>
;; Version: 0.2.3
;; Keywords: tools, matching
;; URL: http://nschum.de/src/emacs/full-ag/
;; Compatibility: GNU Emacs 22.x, GNU Emacs 23.x, GNU Emacs 24.x
;;
;; This file is NOT part of GNU Emacs.
;;
;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License
;; as published by the Free Software Foundation; either version 2
;; of the License, or (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.
;;
;;; Commentary:
;;
;; ag is a tool like grep, aimed at programmers with large trees of
;; heterogeneous source code.
;; It is available at <http://betterthangrep.com/>.
;;
;; Add the following to your .emacs:
;;
;; (add-to-list 'load-path "/path/to/full-ag")
;; (autoload 'ag-same "full-ag" nil t)
;; (autoload 'ag "full-ag" nil t)
;; (autoload 'ag-find-same-file "full-ag" nil t)
;; (autoload 'ag-find-file "full-ag" nil t)
;;
;; Run `ag' to search for all files and `ag-same' to search for files of the
;; same type as the current buffer.
;;
;; `next-error' and `previous-error' can be used to jump to the matches.
;;
;; `ag-find-file' and `ag-find-same-file' use ag to list the files in the
;; current project.  It's a convenient, though slow, way of finding files.
;;
;;; Change Log:
;;
;;    Added `ag-next-file` and `ag-previous-file`.
;;
;; 2011-12-16 (0.2.3)
;;    Added `ag-again' (bound to "g" in search buffers).
;;    Added default value for search.
;;
;; 2010-11-17 (0.2.2)
;;    Made changes for ag 1.92.
;;    Made `ag-guess-project-root' Windows friendly.
;;
;; 2009-04-13 (0.2.1)
;;    Added `ag-next-match' and `ag-previous-match'.
;;    Fixed mouse clicking and let it move next-error position.
;;
;; 2009-04-06 (0.2)
;;    Added 'unless-guessed value for `ag-prompt-for-directory'.
;;    Added `ag-list-files', `ag-find-file' and `ag-find-same-file'.
;;    Fixed regexp toggling.
;;
;; 2009-04-05 (0.1)
;;    Initial release.
;;
;;; Code:

(eval-when-compile (require 'cl))
(require 'compile)

(add-to-list 'debug-ignored-errors
             "^Moved \\(back before fir\\|past la\\)st match$")
(add-to-list 'debug-ignored-errors "^File .* not found$")

(defgroup full-ag nil
  "A front-end for ag."
  :group 'tools
  :group 'matching)

(defcustom ag-executable (executable-find "ag")
  "*The location of the ag executable."
  :group 'full-ag
  :type 'file)

(defcustom ag-arguments nil
  "*The arguments to use when running ag."
  :group 'full-ag
  :type '(repeat (string)))

(defcustom ag-mode-type-alist nil
  "*Matches major modes to searched file types.
This overrides values in `ag-mode-default-type-alist'.  The car in each
list element is a major mode, the rest are strings representing values of
the --type argument used by `ag-same'."
  :group 'full-ag
  :type '(repeat (cons (symbol :tag "Major mode")
                       (repeat (string :tag "ag type")))))

(defcustom ag-mode-extension-alist nil
  "*Matches major modes to searched file extensions.
This overrides values in `ag-mode-default-extension-alist'.  The car in
each list element is a major mode, the rest is a list of file extensions
that that should be searched in addition to the type defined in
`ag-mode-type-alist' by `ag-same'."
  :group 'full-ag
  :type '(repeat (cons (symbol :tag "Major mode")
                       (repeat :tag "File extensions"
                               (string :tag "extension")))))

(defcustom ag-ignore-case 'smart
  "*Determines whether `ag' ignores the search case.
Special value 'smart enables ag option \"smart-case\"."
  :group 'full-ag
  :type '(choice (const :tag "Case sensitive" nil)
                 (const :tag "Smart" 'smart)
                 (const :tag "Ignore case" t)))

(defcustom ag-search-regexp t
  "*Determines whether `ag' should default to regular expression search.
Giving a prefix arg to `ag' toggles this option."
  :group 'full-ag
  :type '(choice (const :tag "Literal" nil)
                 (const :tag "Regular expression" t)))

(defcustom ag-display-buffer t
  "*Determines whether `ag' should display the result buffer.
Special value 'after means display the buffer only after a successful search."
  :group 'full-ag
  :type '(choice (const :tag "Don't display" nil)
                 (const :tag "Display immediately" t)
                 (const :tag "Display when done" 'after)))

(defcustom ag-context 2
  "*The number of context lines for `ag'"
  :group 'full-ag
  :type 'integer)

(defcustom ag-heading t
  "*Determines whether `ag' results should be grouped by file."
  :group 'full-ag
  :type '(choice (const :tag "No heading" nil)
                 (const :tag "Heading" t)))

(defcustom ag-use-environment t
  "*Determines whether `ag' should use access .agrc and AG_OPTIONS."
  :group 'full-ag
  :type '(choice (const :tag "Ignore environment" nil)
                 (const :tag "Use environment" t)))

(defcustom ag-root-directory-functions '(ag-guess-project-root)
  "*A list of functions used to find the ag base directory.
These functions are called until one returns a directory.  If successful,
`ag' is run from that directory instead of `default-directory'.  The
directory is verified by the user depending on `ag-promtp-for-directory'."
  :group 'full-ag
  :type '(repeat function))

(defcustom ag-project-root-file-patterns
  '(".project\\'" ".xcodeproj\\'" ".sln\\'" "\\`Project.ede\\'"
    "\\`.git\\'" "\\`.bzr\\'" "\\`_darcs\\'" "\\`.hg\\'")
  "A list of project file patterns for `ag-guess-project-root'.
Each element is a regular expression.  If a file matching either element is
found in a directory, that directory is assumed to be the project root by
`ag-guess-project-root'."
  :group 'full-ag
  :type '(repeat (string :tag "Regular expression")))

(defcustom ag-prompt-for-directory nil
  "*Determines whether `ag' asks the user for the root directory.
If this is 'unless-guessed, the value determined by
`ag-root-directory-functions' is used without confirmation.  If it is
nil, the directory is never confirmed."
  :group 'full-ag
  :type '(choice (const :tag "Don't prompt" nil)
                 (const :tag "Don't Prompt when guessed " unless-guessed)
                 (const :tag "Prompt" t)))

;;; faces ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defface ag-separator
  '((default (:foreground "gray50")))
  "*Face for the group separator \"--\" in `ag' output."
  :group 'full-ag)

(defface ag-file
  '((((background dark)) (:foreground "green1"))
    (((background light)) (:foreground "green4")))
  "*Face for file names in `ag' output."
  :group 'full-ag)

(defface ag-line
  '((((background dark)) (:foreground "LightGoldenrod"))
    (((background dark)) (:foreground "DarkGoldenrod")))
  "*Face for line numbers in `ag' output."
  :group 'full-ag)

(defface ag-match
  '((default (:foreground "black"))
    (((background dark)) (:background "yellow"))
    (((background light)) (:background "yellow")))
  "*Face for matched text in `ag' output."
  :group 'full-ag)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defconst ag-mode-default-type-alist
  ;; Some of these names are guessed.  More should be constantly added.
  '((actionscript-mode "actionscript")
    (LaTeX-mode "tex")
    (TeX-mode "tex")
    (asm-mode "asm")
    (batch-file-mode "batch")
    (c++-mode "cpp")
    (c-mode "cc")
    (cfmx-mode "cfmx")
    (cperl-mode "perl")
    (csharp-mode "csharp")
    (css-mode "css")
    (emacs-lisp-mode "elisp")
    (erlang-mode "erlang")
    (espresso-mode "js")
    (f90-mode "fortran")
    (fortran-mode "fortran")
    (haskell-mode "haskell")
    (hexl-mode "binary")
    (html-mode "html")
    (java-mode "java")
    (javascript-mode "js")
    (jde-mode "java")
    (js2-mode "js")
    (jsp-mode "jsp")
    (latex-mode "tex")
    (lisp-mode "lisp")
    (lua-mode "lua")
    (makefile-mode "make")
    (mason-mode "mason")
    (nxml-mode "xml")
    (objc-mode "objc" "objcpp")
    (ocaml-mode "ocaml")
    (parrot-mode "parrot")
    (perl-mode "perl")
    (php-mode "php")
    (plone-mode "plone")
    (python-mode "python")
    (ruby-mode "ruby")
    (scheme-mode "scheme")
    (shell-script-mode "shell")
    (smalltalk-mode "smalltalk")
    (sql-mode "sql")
    (tcl-mode "tcl")
    (tex-mode "tex")
    (text-mode "text")
    (tt-mode "tt")
    (vb-mode "vb")
    (vim-mode "vim")
    (xml-mode "xml")
    (yaml-mode "yaml"))
  "Default values for `ag-mode-type-alist', which see.")

(defconst ag-mode-default-extension-alist
  '((d-mode "d"))
  "Default values for `ag-mode-extension-alist', which see.")

(defun ag-create-type (extensions)
  (list "--type-set"
        (concat "full-ag-custom-type=" (mapconcat 'identity extensions ","))
        "--type" "full-ag-custom-type"))

(defun ag-type-for-major-mode (mode)
  "Return the --type and --type-set arguments for major mode MODE."
  (let ((types (cdr (or (assoc mode ag-mode-type-alist)
                        (assoc mode ag-mode-default-type-alist))))
        (ext (cdr (or (assoc mode ag-mode-extension-alist)
                      (assoc mode ag-mode-default-extension-alist))))
        result)
    (dolist (type types)
      (push type result)
      (push "--type" result))
    (if ext
        (if types
            `("--type-add" ,(concat (car types)
                                    "=" (mapconcat 'identity ext ","))
              . ,result)
          (ag-create-type ext))
      result)))

;;; root ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun ag-guess-project-root ()
  "A function to guess the project root directory.
This can be used in `ag-root-directory-functions'."
  (catch 'root
    (let ((dir (expand-file-name (if buffer-file-name
                                     (file-name-directory buffer-file-name)
                                   default-directory)))
          (prev-dir nil)
          (pattern (mapconcat 'identity ag-project-root-file-patterns "\\|")))
      (while (not (equal dir prev-dir))
        (when (directory-files dir nil pattern t)
          (throw 'root dir))
        (setq prev-dir dir
              dir (file-name-directory (directory-file-name dir)))))))

;;; process ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defvar ag-buffer-name "*ag*")
(defvar ag-process nil)

(defvar ag-buffer--rerun-args nil)

(defun ag-count-matches ()
  "Count the matches printed by `ag' in the current buffer."
  (let ((c 0)
        (beg (point-min)))
    (setq beg (next-single-char-property-change beg 'ag-match))
    (while (< beg (point-max))
      (when (get-text-property beg 'ag-match)
        (incf c))
      (setq beg (next-single-char-property-change beg 'ag-match)))
    c))

(defun ag-sentinel (proc result)
  (when (eq (process-status proc) 'exit)
    (with-current-buffer (process-buffer proc)
      (let ((c (ag-count-matches)))
        (if (> c 0)
            (when (eq ag-display-buffer 'after)
              (display-buffer (current-buffer)))
;;          (kill-buffer (current-buffer))
          )
        (message "Ag finished with %d match%s" c (if (eq c 1) "" "es"))))))

(defun ag-filter (proc output)
  (let ((buffer (process-buffer proc))
        (inhibit-read-only t)
        beg)
    (if (buffer-live-p buffer)
      (with-current-buffer buffer
        (save-excursion
          (goto-char (setq beg (point-max)))
          (insert output)
          ;; Error properties are done by font-lock.
          (font-lock-fontify-region beg (point-max))))
      (ag-abort))))

(defun ag-abort ()
  "Abort the running `ag' process."
  (interactive)
  (when (processp ag-process)
    (delete-process ag-process)))

(defun ag-option (name enabled)
  (format "--%s%s" (if enabled "" "no") name))

(defun ag-arguments-from-options (regexp)
  (let ((arguments (list "--color"
                         (ag-option "smart-case" (eq ag-ignore-case 'smart))
                         (ag-option "heading" ag-heading))))
    (unless ag-ignore-case
      (push "-i" arguments))
    (unless regexp
      (push "--literal" arguments))
    (when (and ag-context (/= ag-context 0))
      (push (format "--context=%d" ag-context) arguments))
    arguments))

(defun ag-run (directory regexp &rest arguments)
  "Run ag in DIRECTORY with ARGUMENTS."
  (ag-abort)
  (setq directory
        (if directory
            (file-name-as-directory (expand-file-name directory))
          default-directory))
  (setq arguments (append ag-arguments
                          (nconc (ag-arguments-from-options regexp)
                                 arguments)))
  ;(message arguments)
  (let ((buffer (get-buffer-create ag-buffer-name))
        (inhibit-read-only t)
        (default-directory directory)
        (rerun-args (cons directory (cons regexp arguments))))
    (setq next-error-last-buffer buffer
          ag-buffer--rerun-args rerun-args)
    (with-current-buffer buffer
      (erase-buffer)
      (ag-mode)
      (setq buffer-read-only t
            default-directory directory)
      (set (make-local-variable 'ag-buffer--rerun-args) rerun-args)
      (font-lock-fontify-buffer)
      (when (eq ag-display-buffer t)
        (display-buffer (current-buffer))))
    (setq ag-process
          (apply 'start-process "ag" buffer ag-executable arguments))
    (set-process-sentinel ag-process 'ag-sentinel)
    (set-process-query-on-exit-flag ag-process nil)
    (set-process-filter ag-process 'ag-filter)))

(defun ag-version-string ()
  "Return the ag version string."
  (with-temp-buffer
    (call-process ag-executable nil t nil "--version")
    (goto-char (point-min))
    (re-search-forward " +")
    (buffer-substring (point) (point-at-eol))))

(defun ag-list-files (directory &rest arguments)
  (with-temp-buffer
    (let ((default-directory directory))
      (when (eq 0 (apply 'call-process ag-executable nil t nil "-f" "--print0"
                         arguments))
        (goto-char (point-min))
        (let ((beg (point-min))
              files)
          (while (re-search-forward "\0" nil t)
            (push (buffer-substring beg (match-beginning 0)) files)
            (setq beg (match-end 0)))
          files)))))

;;; commands ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defvar ag-directory-history nil
  "Directories recently searched with `ag'.")
(defvar ag-literal-history nil
  "Strings recently searched for with `ag'.")
(defvar ag-regexp-history nil
  "Regular expressions recently searched for with `ag'.")

(defun ag--read (regexp)
  (let ((default (ag--default-for-read))
        (type (if regexp "pattern" "literal"))
        (history-var (if regexp 'ag-regexp-history 'ag-literal-history)))
    (read-string (if default
                     (format "ag %s search (default %s): " type default)
                   (format "ag %s search: " type))
                 (ag--initial-contents-for-read)
                 history-var
                 default)))

(defun ag--initial-contents-for-read ()
  (when (ag--use-region-p)
    (buffer-substring-no-properties (region-beginning) (region-end))))

(defun ag--default-for-read ()
  (unless (ag--use-region-p)
    (thing-at-point 'symbol)))

(defun ag--use-region-p ()
  (or (and (fboundp 'use-region-p) (use-region-p))
      (and transient-mark-mode mark-active
           (> (region-end) (region-beginning)))))

(defun ag-read-dir ()
  (let ((dir (run-hook-with-args-until-success 'ag-root-directory-functions)))
    (if ag-prompt-for-directory
        (if (and dir (eq ag-prompt-for-directory 'unless-guessed))
            dir
          (read-directory-name "Directory: " dir dir t))
      (or dir
          (and buffer-file-name (file-name-directory buffer-file-name))
          default-directory))))

(defun ag-xor (a b)
  (if a (not b) b))

(defun ag-interactive ()
  "Return the (interactive) arguments for `ag' and `ag-same'"
  (let ((regexp (ag-xor current-prefix-arg ag-search-regexp)))
    (list (ag--read regexp)
          regexp
          (ag-read-dir))))

(defun ag-type ()
  (or (ag-type-for-major-mode major-mode)
      (when buffer-file-name
        (ag-create-type (list (file-name-extension buffer-file-name))))))

;;;###autoload
(defun ag-same (pattern &optional regexp directory)
  "Run ag with --type matching the current `major-mode'.
The types of files searched are determined by `ag-mode-type-alist' and
`ag-mode-extension-alist'.  If no type is configured the buffer's file
extension is used for the search.
PATTERN is interpreted as a regular expression, iff REGEXP is non-nil.  If
called interactively, the value of REGEXP is determined by `ag-search-regexp'.
A prefix arg toggles that value.
DIRECTORY is the root directory.  If called interactively, it is determined by
`ag-project-root-file-patterns'.  The user is only prompted, if
`ag-prompt-for-directory' is set."
  (interactive (ag-interactive))
  (let ((type (ag-type)))
    (if type
        (apply 'ag-run directory regexp (append type (list pattern)))
      (ag pattern regexp directory))))

;;;###autoload
(defun ag (pattern &optional regexp directory)
  "Run ag.
PATTERN is interpreted as a regular expression, iff REGEXP is non-nil.  If
called interactively, the value of REGEXP is determined by `ag-search-regexp'.
A prefix arg toggles that value.
DIRECTORY is the root directory.  If called interactively, it is determined by
`ag-project-root-file-patterns'.  The user is only prompted, if
`ag-prompt-for-directory' is set."
  (interactive (ag-interactive))
  (ag-run directory regexp pattern))

(defun ag-read-file (prompt choices)
  (if ido-mode
      (ido-completing-read prompt choices nil t)
    (require 'iswitchb)
    (with-no-warnings
      (let ((iswitchb-make-buflist-hook
             `(lambda () (setq iswitchb-temp-buflist ',choices))))
        (iswitchb-read-buffer prompt nil t)))))

;;;###autoload
(defun ag-find-same-file (&optional directory)
  "Prompt to find a file found by ag in DIRECTORY."
  (interactive (list (ag-read-dir)))
  (find-file (expand-file-name
              (ag-read-file "Find file: "
                             (apply 'ag-list-files directory (ag-type)))
              directory)))

;;;###autoload
(defun ag-find-file (&optional directory)
  "Prompt to find a file found by ag in DIRECTORY."
  (interactive (list (ag-read-dir)))
  (find-file (expand-file-name (ag-read-file "Find file: "
                                              (ag-list-files directory))
                               directory)))

;;; run again ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun ag-again ()
  "Run the last ag search in the same directory."
  (interactive)
  (if ag-buffer--rerun-args
      (let ((ag-buffer-name (ag--again-buffer-name)))
        (apply 'ag-run ag-buffer--rerun-args))
    (call-interactively 'ag)))

(defun ag--again-buffer-name ()
  (if (local-variable-p 'ag-buffer--rerun-args)
      (buffer-name)
    ag-buffer-name))

;;; text utilities ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun ag-visible-distance (beg end)
  "Determine the number of visible characters between BEG and END."
  (let ((offset 0)
        next)
    ;; Subtract invisible text
    (when (get-text-property beg 'invisible)
      (setq beg (next-single-property-change beg 'invisible)))
    (while (and beg (< beg end))
      (if (setq next (next-single-property-change beg 'invisible))
          (setq offset (+ offset (- (min next end) beg))
                beg (next-single-property-change next 'invisible))
        (setq beg nil)))
    offset))

(defun ag-previous-property-value (property pos)
  "Find the value of PROPERTY at or somewhere before POS."
  (or (get-text-property pos property)
      (when (setq pos (previous-single-property-change pos property))
        (get-text-property (1- pos) property))))

(defun ag-property-beg (pos property)
  "Move to the first char of consecutive sequence with PROPERTY set."
  (when (get-text-property pos property)
    (if (or (eq pos (point-min))
            (not (get-text-property (1- pos) property)))
        pos
      (previous-single-property-change pos property))))

(defun ag-property-end (pos property)
  "Move to the last char of consecutive sequence with PROPERTY set."
  (when (get-text-property pos property)
    (if (or (eq pos (point-max))
            (not (get-text-property (1+ pos) property)))
        pos
      (next-single-property-change pos property))))

;;; next-error ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defvar ag-error-pos nil)
(make-variable-buffer-local 'ag-error-pos)

(defun ag-next-marker (pos arg marker marker-name)
  (setq arg (* 2 arg))
  (unless (get-text-property pos marker)
    (setq arg (1- arg)))
  (assert (> arg 0))
  (dotimes (i arg)
    (setq pos (next-single-property-change pos marker))
    (unless pos
      (error (format "Moved past last %s" marker-name))))
  (goto-char pos)
  pos)

(defun ag-previous-marker (pos arg marker marker-name)
  (assert (> arg 0))
  (dotimes (i (* 2 arg))
    (setq pos (previous-single-property-change pos marker))
    (unless pos
      (error (format "Moved back before first %s" marker-name))))
  (goto-char pos)
  pos)

(defun ag-next-match (pos arg)
  "Move to the next match in the *ag* buffer."
  (interactive "d\np")
  (ag-next-marker pos arg 'ag-match "match"))

(defun ag-previous-match (pos arg)
  "Move to the previous match in the *ag* buffer."
  (interactive "d\np")
  (ag-previous-marker pos arg 'ag-match "match"))

(defun ag-next-file (pos arg)
  "Move to the next file in the *ag* buffer."
  (interactive "d\np")
  ;; Workaround for problem at the begining of the buffer.
  (when (bobp) (incf arg))
  (ag-next-marker pos arg 'ag-file "file"))

(defun ag-previous-file (pos arg)
  "Move to the previous file in the *ag* buffer."
  (interactive "d\np")
  (ag-previous-marker pos arg 'ag-file "file"))

(defun ag-next-error-function (arg reset)
  (when (or reset (null ag-error-pos))
    (setq ag-error-pos (point-min)))
  (ag-find-match (if (<= arg 0)
                      (ag-previous-match ag-error-pos (- arg))
                    (ag-next-match ag-error-pos arg))))

(defun ag-create-marker (pos end &optional force)
  (let ((file (ag-previous-property-value 'ag-file pos))
        (line (ag-previous-property-value 'ag-line pos))
        (offset (ag-visible-distance
                 (or (previous-single-property-change pos 'ag-line) 0)
                 pos))
        buffer)
    (if force
        (or (and file
                 line
                 (file-exists-p file)
                 (setq buffer (find-file-noselect file)))
            (error "File <%s> not found" file))
      (and file
           line
           (setq buffer (find-buffer-visiting file))))
    (when buffer
      (with-current-buffer buffer
        (save-excursion
          (ag--move-to-line (string-to-number line))
          (copy-marker (+ (point) offset -1)))))))

(defun ag--move-to-line (line)
  (save-restriction
    (widen)
    (goto-char (point-min))
    (forward-line (1- line))))

(defun ag-find-match (pos)
  "Jump to the match at POS."
  (interactive (list (let ((posn (event-start last-input-event)))
                       (set-buffer (window-buffer (posn-window posn)))
                       (posn-point posn))))
  (when (setq pos (ag-property-beg pos 'ag-match))
    (let ((marker (get-text-property pos 'ag-marker))
          (msg (copy-marker pos))
          (msg-end (ag-property-end pos 'ag-match))
          (compilation-context-lines ag-context)
          (inhibit-read-only t)
          (end (make-marker)))
      (setq ag-error-pos pos)

      (let ((bol (save-excursion (goto-char pos) (point-at-bol))))
        (if overlay-arrow-position
            (move-marker overlay-arrow-position bol)
          (setq overlay-arrow-position (copy-marker bol))))

      (unless (and marker (marker-buffer marker))
        (setq marker (ag-create-marker msg msg-end t))
        (add-text-properties msg msg-end (list 'ag-marker marker)))
      (set-marker end (+ marker (ag-visible-distance msg msg-end))
                  (marker-buffer marker))
      (compilation-goto-locus msg marker end)
      (set-marker msg nil)
      (set-marker end nil))))

;;; ag-mode ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defvar ag-mode-map
  (let ((keymap (make-sparse-keymap)))
    (define-key keymap [mouse-2] 'ag-find-match)
    (define-key keymap "\C-m" 'ag-find-match)
    (define-key keymap "n" 'ag-next-match)
    (define-key keymap "p" 'ag-previous-match)
    (define-key keymap "\M-n" 'ag-next-file)
    (define-key keymap "\M-p" 'ag-previous-file)
    (define-key keymap "g" 'ag-again)
    (define-key keymap "r" 'ag-again)
    keymap))

(defconst ag-font-lock-regexp-color-fg-begin "\\(\33\\[1;..?m\\)")
(defconst ag-font-lock-regexp-color-bg-begin "\\(\33\\[30;..m\\)")
(defconst ag-font-lock-regexp-color-end "\\(\33\\[0m\\)")

(defconst ag-font-lock-regexp-line
  (concat "\\(" ag-font-lock-regexp-color-fg-begin "?\\)"
          "\\([0-9]+\\)"
          "\\(" ag-font-lock-regexp-color-end "?\\)"
          "[:-]")
  "Matches the line output from ag (with or without color).
Color is used starting ag 1.94.")

(defvar ag-font-lock-keywords
  `(("^--" . 'ag-separator)
    ;; file and line
    (,(concat "^" ag-font-lock-regexp-color-fg-begin
              "\\(.*?\\)" ag-font-lock-regexp-color-end
              "[:-]" ag-font-lock-regexp-line)
     (1 '(face nil invisible t))
     (2 `(face ag-file ag-file ,(match-string-no-properties 2)))
     (3 '(face nil invisible t))
     (4 '(face nil invisible t))
     (6 `(face ag-line ag-line ,(match-string-no-properties 6)))
     (7 '(face nil invisible t) nil optional))
    ;; lines
    (,(concat "^" ag-font-lock-regexp-line)
     (1 '(face nil invisible t))
     (3 `(face ag-line ag-line ,(match-string-no-properties 3)))
     (5 '(face nil invisible t) nil optional))
    ;; file
    (,(concat "^" ag-font-lock-regexp-color-fg-begin
              "\\(.*?\\)" ag-font-lock-regexp-color-end "$")
     (1 '(face nil invisible t))
     (2 `(face ag-file ag-file ,(match-string-no-properties 2)))
     (3 '(face nil invisible t)))
    ;; matches
    (,(concat ag-font-lock-regexp-color-bg-begin
              "\\(.*?\\)"
              ag-font-lock-regexp-color-end)
     (1 '(face nil invisible t))
     (0 `(face ag-match
          ag-marker ,(ag-create-marker (match-beginning 2) (match-end 2))
          ag-match t
          mouse-face highlight
          follow-link t))
     (3 '(face nil invisible t)))
    ;; noise
    ("\\(\33\\[\\(0m\\|K\\)\\)"
     (0 '(face nil invisible t)))))

(define-derived-mode ag-mode nil "ag"
  "Major mode for ag output."
  font-lock-defaults
  (setq font-lock-defaults
        (list ag-font-lock-keywords t))
  (set (make-local-variable 'font-lock-extra-managed-props)
       '(mouse-face follow-link ag-line ag-file ag-marker ag-match))
  (make-local-variable 'overlay-arrow-position)
  (set (make-local-variable 'overlay-arrow-string) "")

  (font-lock-fontify-buffer)
  (use-local-map ag-mode-map)

  (setq next-error-function 'ag-next-error-function
        ag-error-pos nil))

(provide 'full-ag)
;;; full-ag.el ends here
