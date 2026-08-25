;;; shell-maker.el --- Test stub for shell-maker -*- lexical-binding: t; -*-

;;; Commentary:

;; Enough of `shell-maker' for `agent-shell-side.el' to load.  Only the
;; buffer history is stubbed, since that is all the package reads.

;;; Code:

(defconst shell-maker-test-stub-p t
  "Non-nil when the shell-maker test stub is loaded.")

(defvar agent-shell-test-history '(("hello" . "hi there"))
  "Value `shell-maker-history' returns.

Non-empty by default: most tests fork a conversation that has already
taken a turn, which is the only kind that can be forked.")

(defun shell-maker-history ()
  "Return the stubbed buffer history."
  agent-shell-test-history)

(provide 'shell-maker)

;;; shell-maker.el ends here
