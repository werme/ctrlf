;;; ctrlf.el --- Emacs finally learns how to ctrl+F -*- lexical-binding: t -*-

;; Copyright (C) 2019 Radon Rosborough

;; Author: Radon Rosborough <radon.neon@gmail.com>
;; Created: 23 Dec 2019
;; Homepage: https://github.com/raxod502/ctrlf
;; Keywords: extensions
;; Package-Requires: ((emacs "25.1"))
;; Version: 0

;;; Commentary:

;; Please see https://github.com/raxod502/ctrlf for more
;; information.

;;; Code:

;; To see the outline of this file, run M-x outline-minor-mode and
;; then press C-c @ C-t. To also show the top-level functions and
;; variable declarations in each section, run M-x occur with the
;; following query: ^;;;;* \|^(

(require 'cl-lib)
(require 'map)
(require 'subr-x)
(require 'thingatpt)

(defgroup ctrlf nil
  "More streamlined replacement for Isearch, Swiper, etc."
  :group 'convenience
  :prefix "ctrlf-"
  :link '(url-link "https://github.com/raxod502/ctrlf"))

(defcustom ctrlf-highlight-current-line t
  "Whether highlight current line or not."
  :type 'boolean)

(defcustom ctrlf-auto-recenter nil
  "Non-nil means to always keep the current match vertically centered."
  :type 'boolean)

(defcustom ctrlf-style-alist
  '((literal      . (:prompt "literal"  :translator regexp-quote))
    (regexp       . (:prompt "regexp"   :translator identity))
    (fuzzy        . (:prompt "fuzzy"    :translator ctrlf--fuzzy-translate))
    (fuzzy-regexp . (:prompt "fuzzy re"
                             :translator ctrlf--fuzzy-regexp-translate)))
  "The displayed name and regexp translator for CTRLF search styles.
The key is the symbol of the search style, the value is a list composed of the
displayed name and the regexp translator."
  :type '(alist
          :key-type symbol
          :value-type (list (const :prompt) string
                            (const :translator) function)))

(defcustom ctrlf-mode-bindings
  '(([remap isearch-forward        ] . ctrlf-forward)
    ([remap isearch-backward       ] . ctrlf-backward)
    ([remap isearch-forward-regexp ] . ctrlf-forward-regexp)
    ([remap isearch-backward-regexp] . ctrlf-backward-regexp))
  "Keybindings enabled in `ctrlf-mode'. This is not a keymap.
Rather it is an alist that is converted into a keymap just before
`ctrlf-mode' is (re-)enabled. The keys are strings or raw key
events and the values are command symbols."
  :type '(alist
          :key-type sexp
          :value-type function))

(defcustom ctrlf-minibuffer-bindings
  '(([remap abort-recursive-edit]     . ctrlf-cancel)
    ;; This is bound in `minibuffer-local-map' by loading `delsel', so
    ;; we have to account for it too.
    ([remap minibuffer-keyboard-quit]       . ctrlf-cancel)
    ;; Use `minibuffer-beginning-of-buffer' for Emacs >=27 and
    ;; `beginning-of-buffer' for Emacs <=26.
    ([remap minibuffer-beginning-of-buffer] . ctrlf-first-match)
    ([remap beginning-of-buffer]            . ctrlf-first-match)
    ([remap end-of-buffer]                  . ctrlf-last-match)
    ([remap recenter]                       . ctrlf-recenter)
    ("C-s"       . ctrlf-next-match-or-previous-history-element)
    ("TAB"       . ctrlf-next-match-or-previous-history-element)
    ("C-r"       . ctrlf-previous-match-or-previous-history-element)
    ("S-TAB"     . ctrlf-previous-match-or-previous-history-element)
    ("<backtab>" . ctrlf-previous-match-or-previous-history-element))
  "Keybindings enabled in minibuffer during search. This is not a keymap.
Rather it is an alist that is converted into a keymap just before
entering the minibuffer. The keys are strings or raw key events
and the values are command symbols. The keymap so constructed
inherits from `minibuffer-local-map'."
  :type '(alist
          :key-type sexp
          :value-type function))

(defface ctrlf-highlight-active
  '((t :inherit isearch))
  "Face used to highlight current match.")

(defface ctrlf-highlight-passive
  '((t :inherit lazy-highlight))
  "Face used to highlight other matches in the buffer.")

(defface ctrlf-highlight-line
  '((t :inherit highlight))
  "Face used to highlight current line.")

(defvar ctrlf-search-history nil
  "History of searches that were not canceled.")

(defvar ctrlf--active-p nil
  "Non-nil means we're currently performing a search.
This is dynamically bound by CTRLF commands.")

(defvar ctrlf--backward-p nil
  "Non-nil means we are currently searching backward.
Nil means we are currently searching forward.")

(defvar ctrlf--style nil
  "Current search style.")

(defvar ctrlf--last-input nil
  "Previous user input, or nil if none yet.")

(defvar ctrlf--starting-point nil
  "Value of point from when search was started.")

(defvar ctrlf--current-starting-point nil
  "Value of point from which to search.")

(defvar ctrlf--minibuffer nil
  "The minibuffer being used for search.")

(defvar ctrlf--persistent-overlays nil
  "List of persistent overlays used by CTRLF.")

(defvar ctrlf--transient-overlays nil
  "List of transient overlays used by CTRLF.")

(defvar ctrlf--match-bounds nil
  "Cons cell of current match beginning and end, or nil if no match.")

(defvar ctrlf--final-window-start nil
  "Original buffer's `window-start' just before exiting minibuffer.
For some reason this gets trashed when exiting the minibuffer, so
we restore it to keep the scroll position consistent.

I have literally no idea why this is needed.")

(defun ctrlf--copy-properties (s1 s2)
  "Return a copy of S1 with properties from S2 added.
Assume that S2 has the same properties throughout."
  (apply #'propertize s1 (text-properties-at 0 s2)))

(defun ctrlf--fuzzy-split (str)
  "Split STR into a list of substrs.
STR is splitted by spaces. A single space is substituted by
\".*\", while N consecutive spaces are substituted by N-1
spaces."
  (let* ((last-is-empty t)
         ;; By `split-string', N spaces will become N-1 empty strings, but at
         ;; the beginning/end of the string, they become N empty strings. We'll
         ;; deal with this later.
         (splits (split-string str " "))
         (substrs nil))
    (dolist (split splits)
      (cond
       ((string-empty-p split)
        (setq last-is-empty t)
        (push " " substrs))
       (t
        (if last-is-empty
            (push split substrs)
          (push ".*" substrs)
          (push split substrs))
        (setq last-is-empty nil))))
    ;; When there's only one space at the beginning of `substrs', this means a
    ;; ".*". It's not pushed into `substrs' since there's nothing more comes
    ;; from `splits' to let that happen. So we substitute it with ".*". When
    ;; there are more than one spaces, we should remove one due to the
    ;; `split-string' problem mentioned above.
    (when (string= (car substrs) " ")
      (if (string= (nth 1 substrs) " ")
          (pop substrs)
        (setcar substrs ".*")))
    (setq substrs (nreverse substrs))
    ;; We should also do the same thing to the other end of `substrs'.
    (when (string= (car substrs) " ")
      (if (string= (nth 1 substrs) " ")
          (pop substrs)
        (setcar substrs ".*")))
    substrs))

(defun ctrlf--fuzzy-translate (str)
  "Translate the literal input STR to a fuzzy regexp.
A single space character is translated into \".*\", while N
spaces (N >= 2) are translated in to N-1 spaces. The groups
divided by \".*\" are quoted."
  (let ((substr-replace
         (lambda (substr)
           (if (string= ".*" substr)
               substr
             (regexp-quote substr)))))
    (apply #'concat
           (cl-map 'list
                   substr-replace
                   (ctrlf--fuzzy-split str)))))

(defun ctrlf--fuzzy-regexp-translate (str)
  "Translate the user inputted regexp STR to a fuzzy regexp.
A single space character is translated into \".*\", while N
spaces (N >= 2) are translated in to N-1 spaces."
  (apply #'concat (ctrlf--fuzzy-split str)))

(defun ctrlf--finalize ()
  "Perform cleanup that has to happen after the minibuffer is exited."
  (remove-hook 'post-command-hook #'ctrlf--finalize)
  (unless (= (point) ctrlf--starting-point)
    (push-mark ctrlf--starting-point))
  (set-window-start nil ctrlf--final-window-start))

(defun ctrlf--minibuffer-exit-hook ()
  "Clean up CTRLF from minibuffer and self-destruct this hook."
  (setq ctrlf--final-window-start (window-start (minibuffer-selected-window)))
  (ctrlf--clear-transient-overlays)
  (ctrlf--clear-persistent-overlays)
  (remove-hook
   'post-command-hook #'ctrlf--minibuffer-post-command-hook 'local)
  (remove-hook 'minibuffer-exit-hook #'ctrlf--minibuffer-exit-hook 'local)
  (add-hook 'post-command-hook #'ctrlf--finalize))

(defvar ctrlf--persist-messages t
  "Whether `ctrlf--message' will show persistent messages.
If non-nil, then messages will persist until the next
recomputation of CTRLF's overlays. Persistent messages will be
shown to the left of transient messages.")

(defun ctrlf--message (format &rest args)
  "Display a transient message in the minibuffer.
FORMAT and ARGS are as in `message'. This function behaves
exactly the same as `message' in Emacs 27 and later, and it acts
as a backport for Emacs 26 and earlier where signaling a message
while the minibuffer is active causes an absolutely horrendous
mess."
  (with-current-buffer ctrlf--minibuffer
    (let ((ol (make-overlay (point-max) (point-max))))
      (if ctrlf--persist-messages
          (push ol ctrlf--persistent-overlays)
        (push ol ctrlf--transient-overlays))
      ;; Some of this is borrowed from `minibuffer-message'.
      (let ((string (apply #'format (concat " [" format "]") args)))
        (put-text-property 0 (length string) 'face 'minibuffer-prompt string)
        (put-text-property 0 1 'cursor t string)
        (overlay-put ol 'after-string string)
        (when ctrlf--persist-messages
          (overlay-put ol 'priority 1))))))

(cl-defun ctrlf--search
    (query &key
           (style :unset) (backward :unset) (forward :unset)
           wraparound bound)
  "Single-buffer text search primitive. Search for QUERY.
STYLE controls the search style. If it's unset, use the value of
`ctrlf--style'. BACKWARD controls whether to do a forward
search (nil) or a backward search (non-nil), else check
`ctrlf--backward-p'. LITERAL and FORWARD do the same but the
meaning of their arguments are inverted. WRAPAROUND means keep
searching at the beginning (or end, respectively) of the buffer,
rather than stopping. BOUND, if non-nil, is a limit for the
search as in `search-forward' and friend. Providing BOUND
automatically disables WRAPAROUND. If the search succeeds, move
point to the end (for forward searches) or beginning (for
backward searches) of the match. If the search fails, return nil,
but still move point."
  (let* ((style (cond
                 ((not (eq style :unset))
                  style)
                 (t
                  ctrlf--style)))
         (backward (cond
                    ((not (eq backward :unset))
                     backward)
                    ((not (eq forward :unset))
                     (not forward))
                    (t
                     ctrlf--backward-p)))
         (wraparound (and wraparound (not bound)))
         (func (if backward
                   #'re-search-backward
                 #'re-search-forward))
         (query (funcall
                 (plist-get (alist-get style ctrlf-style-alist) :translator)
                 query)))
    (or (funcall func query bound 'noerror)
        (when wraparound
          (goto-char
           (if backward
               (point-max)
             (point-min)))
          (funcall func query bound 'noerror)))))

(defun ctrlf--prompt ()
  "Return the prompt to use in the minibuffer."
  (concat
   "CTRLF "
   (if ctrlf--backward-p "↑" "↓")
   " "
   (plist-get (alist-get ctrlf--style ctrlf-style-alist) :prompt)
   ": "))

(defun ctrlf--clear-transient-overlays ()
  "Delete the transient overlays created by CTRLF."
  (while ctrlf--transient-overlays
    (delete-overlay (pop ctrlf--transient-overlays))))

(defun ctrlf--clear-persistent-overlays ()
  "Delete the persistent overlays created by CTRLF."
  (while ctrlf--persistent-overlays
    (delete-overlay (pop ctrlf--persistent-overlays))))

(defun ctrlf--minibuffer-post-command-hook ()
  "Deal with updated user input."
  (save-excursion
    (let* ((old-prompt (field-string (point-min)))
           (new-prompt (ctrlf--copy-properties (ctrlf--prompt) old-prompt))
           (inhibit-read-only t))
      (goto-char (point-min))
      (delete-region (point) (field-end (point)))
      (insert new-prompt)))
  (when (< (point) (field-end (point-min)))
    (goto-char (field-end (point-min))))
  (ctrlf--clear-transient-overlays)
  (cl-block nil
    (let* ((input (field-string (point-max)))
           (translator (plist-get
                        (alist-get ctrlf--style ctrlf-style-alist)
                        :translator))
           (regexp (funcall translator input)))
      (condition-case e
          (when (string-match-p regexp "")
            ;; Let's just rule out zero-length matches entirely,
            ;; they're not interesting and they make the
            ;; implementation more complicated and slower.
            (cl-return))
        (invalid-regexp
         (ctrlf--message "Invalid regexp: %s" (cadr e))
         (cl-return)))
      (unless (equal input ctrlf--last-input)
        (setq ctrlf--last-input input)
        (with-current-buffer (window-buffer (minibuffer-selected-window))
          (let ((prev-point (point)))
            (goto-char ctrlf--current-starting-point)
            (if (ctrlf--search input :wraparound t)
                (progn
                  (goto-char (match-beginning 0))
                  (setq ctrlf--match-bounds
                        (cons (match-beginning 0)
                              (match-end 0))))
              (goto-char prev-point)
              (setq ctrlf--match-bounds nil)))
          (set-window-point (minibuffer-selected-window) (point))
          ;; Force redisplay to make sure the window bounds are
          ;; computed correctly, which we need to determine which
          ;; parts of the buffer to passively highlight. But make sure
          ;; that we do redisplay before clearing any overlays, so
          ;; that all the overlay modifications happen between
          ;; redisplays. Otherwise the user can see a partial set of
          ;; overlays for a split second.
          (when ctrlf-auto-recenter
            (ctrlf-recenter))
          (redisplay)
          (ctrlf--clear-persistent-overlays)
          (when ctrlf--match-bounds
            (let ((cur-point (point))
                  (num-matches 0)
                  (cur-index nil))
              (save-excursion
                (goto-char (point-min))
                (while (ctrlf--search input :forward t)
                  (cl-incf num-matches)
                  (when (and (null cur-index)
                             (>= (point) cur-point))
                    (setq cur-index num-matches))))
              (with-current-buffer ctrlf--minibuffer
                (when cur-index
                  (let ((ctrlf--persist-messages t))
                    (ctrlf--message
                     "%d/%d" cur-index num-matches))))))
          (when ctrlf--match-bounds
            (let ((ol (make-overlay
                       (car ctrlf--match-bounds) (cdr ctrlf--match-bounds))))
              (push ol ctrlf--persistent-overlays)
              (overlay-put ol 'face 'ctrlf-highlight-active))
            (when ctrlf-highlight-current-line
              (let ((ol (make-overlay
                         (save-excursion
                           (goto-char (car ctrlf--match-bounds))
                           (line-beginning-position))
                         (save-excursion
                           (goto-char (cdr ctrlf--match-bounds))
                           (1+ (line-end-position))))))
                (push ol ctrlf--persistent-overlays)
                (overlay-put ol 'face 'ctrlf-highlight-line))))
          (let ((start (window-start (minibuffer-selected-window)))
                (end (window-end (minibuffer-selected-window))))
            (save-excursion
              (goto-char start)
              (while (ctrlf--search input :forward t :bound end)
                (when (or (null ctrlf--match-bounds)
                          (<= (match-end 0)
                              (car ctrlf--match-bounds))
                          (>= (match-beginning 0)
                              (cdr ctrlf--match-bounds)))
                  (let ((ol (make-overlay
                             (match-beginning 0) (match-end 0))))
                    (push ol ctrlf--persistent-overlays)
                    (overlay-put ol 'face 'ctrlf-highlight-passive)))))))))))

(defun ctrlf--start ()
  "Start CTRLF session assuming config vars are set up already."
  (let ((keymap (make-sparse-keymap)))
    (set-keymap-parent keymap minibuffer-local-map)
    (map-apply
     (lambda (key cmd)
       (when (stringp key)
         (setq key (kbd key)))
       (define-key keymap key cmd))
     ctrlf-minibuffer-bindings)
    (setq ctrlf--starting-point (point))
    (setq ctrlf--current-starting-point (point))
    (setq ctrlf--last-input nil)
    (minibuffer-with-setup-hook
        (lambda ()
          (setq ctrlf--minibuffer (current-buffer))
          (add-hook
           'minibuffer-exit-hook #'ctrlf--minibuffer-exit-hook nil 'local)
          (add-hook 'post-command-hook #'ctrlf--minibuffer-post-command-hook
                    nil 'local))
      (let ((ctrlf--active-p t)
            (cursor-in-non-selected-windows nil))
        (read-from-minibuffer
         (ctrlf--prompt) nil keymap nil 'ctrlf-search-history
         (thing-at-point 'symbol t))))))

(defun ctrlf-forward ()
  "Search forward for literal string."
  (interactive)
  (when ctrlf--active-p
    (user-error "Already in the middle of a CTRLF search"))
  (setq ctrlf--backward-p nil)
  (setq ctrlf--style 'literal)
  (ctrlf--start))

(defun ctrlf-backward ()
  "Search backward for literal string."
  (interactive)
  (when ctrlf--active-p
    (user-error "Already in the middle of a CTRLF search"))
  (setq ctrlf--backward-p t)
  (setq ctrlf--style 'literal)
  (ctrlf--start))

(defun ctrlf-forward-regexp ()
  "Search forward for regexp."
  (interactive)
  (when ctrlf--active-p
    (user-error "Already in the middle of a CTRLF search"))
  (setq ctrlf--backward-p nil)
  (setq ctrlf--style 'regexp)
  (ctrlf--start))

(defun ctrlf-backward-regexp ()
  "Search backward for regexp."
  (interactive)
  (when ctrlf--active-p
    (user-error "Already in the middle of a CTRLF search"))
  (setq ctrlf--backward-p t)
  (setq ctrlf--style 'regexp)
  (ctrlf--start))

(defun ctrlf-forward-fuzzy ()
  "Search forward for literal string in the fuzzy style."
  (interactive)
  (when ctrlf--active-p
    (user-error "Already in the middle of a CTRLF search"))
  (setq ctrlf--backward-p nil)
  (setq ctrlf--style 'fuzzy)
  (ctrlf--start))

(defun ctrlf-backward-fuzzy ()
  "Search backward for literal string in the fuzzy style."
  (interactive)
  (when ctrlf--active-p
    (user-error "Already in the middle of a CTRLF search"))
  (setq ctrlf--backward-p t)
  (setq ctrlf--style 'fuzzy)
  (ctrlf--start))

(defun ctrlf-forward-fuzzy-regexp ()
  "Search forward for regexp in the fuzzy-regexp style."
  (interactive)
  (when ctrlf--active-p
    (user-error "Already in the middle of a CTRLF search"))
  (setq ctrlf--backward-p nil)
  (setq ctrlf--style 'fuzzy-regexp)
  (ctrlf--start))

(defun ctrlf-backward-fuzzy-regexp ()
  "Search backward for regexp in the fuzzy-regexp style."
  (interactive)
  (when ctrlf--active-p
    (user-error "Already in the middle of a CTRLF search"))
  (setq ctrlf--backward-p t)
  (setq ctrlf--style 'fuzzy-regexp)
  (ctrlf--start))

(defun ctrlf-recenter ()
  "Display current match in the center of the window."
  (interactive)
  (with-selected-window
      (minibuffer-selected-window)
    (recenter)))

(defun ctrlf-next-match ()
  "Move to next match, if there is one. Wrap around if necessary."
  (interactive)
  (when ctrlf--match-bounds
    ;; Move past current match.
    (setq ctrlf--current-starting-point (cdr ctrlf--match-bounds)))
  ;; Next search should go forward.
  (setq ctrlf--backward-p nil)
  ;; Force recalculation of search.
  (setq ctrlf--last-input nil))

(defun ctrlf-previous-match ()
  "Move to previous match, if there is one. Wrap around if necessary."
  (interactive)
  (when ctrlf--match-bounds
    ;; Move before current match.
    (setq ctrlf--current-starting-point (car ctrlf--match-bounds)))
  ;; Next search should go backward.
  (setq ctrlf--backward-p t)
  ;; Force recalculation of search.
  (setq ctrlf--last-input nil))

(defun ctrlf-next-match-or-previous-history-element ()
  "Move to next match or re-start last search.
Re-start the last search if there is currently no input, and move
to next match otherwise. In either case, the resulting search
direction is forwards."
  (interactive)
  (if (string-empty-p (field-string (point-max)))
      (progn
        (setq ctrlf--backward-p nil)
        (previous-history-element 1))
    (ctrlf-next-match)))

(defun ctrlf-previous-match-or-previous-history-element ()
  "Move to previous match or re-start last search.
Re-start the last search if there is currently no input, and move
to previous match otherwise. In either case, the resulting search
direction is backwards."
  (interactive)
  (if (string-empty-p (field-string (point-max)))
      (progn
        (setq ctrlf--backward-p t)
        (previous-history-element 1))
    (ctrlf-previous-match)))

(defun ctrlf-first-match ()
  "Move to first match, if there is one."
  (interactive)
  (when ctrlf--match-bounds
    (setq ctrlf--current-starting-point
          (with-current-buffer
              (window-buffer (minibuffer-selected-window))
            (point-min))))
  ;; Next search should go forward.
  (setq ctrlf--backward-p nil)
  ;; Force recalculation of search.
  (setq ctrlf--last-input nil))

(defun ctrlf-last-match ()
  "Move to last match, if there is one."
  (interactive)
  (when ctrlf--match-bounds
    (setq ctrlf--current-starting-point
          (with-current-buffer
              (window-buffer (minibuffer-selected-window))
            (point-max))))
  ;; Next search should go backward.
  (setq ctrlf--backward-p t)
  ;; Force recalculation of search.
  (setq ctrlf--last-input nil))

(defun ctrlf-cancel ()
  "Exit search, returning point to original position."
  (interactive)
  (ctrlf--clear-transient-overlays)
  (ctrlf--clear-persistent-overlays)
  (set-window-point (minibuffer-selected-window) ctrlf--starting-point)
  (abort-recursive-edit))

(defvar ctrlf--keymap (make-sparse-keymap)
  "Keymap for `ctrlf-mode'. Populated when mode is enabled.
See `ctrlf-mode-bindings'.")

(define-minor-mode ctrlf-mode
  "Minor mode to use CTRLF in place of Isearch.
See `ctrlf-mode-bindings' to customize."
  :global t
  :keymap ctrlf--keymap
  (when ctrlf-mode
    (ctrlf-mode -1)
    (setq ctrlf-mode t)
    ;; Hack to clear out keymap. Presumably there's a `clear-keymap'
    ;; function lying around somewhere...?
    (setcdr ctrlf--keymap nil)
    (map-apply
     (lambda (key cmd)
       (when (stringp key)
         (setq key (kbd key)))
       (define-key ctrlf--keymap key cmd))
     ctrlf-mode-bindings)))

;;;; Closing remarks

(provide 'ctrlf)

;; Local Variables:
;; indent-tabs-mode: nil
;; outline-regexp: ";;;;* "
;; End:

;;; ctrlf.el ends here
