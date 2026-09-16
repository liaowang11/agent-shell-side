;;; shell-maker.el --- Test stub for shell-maker -*- lexical-binding: t; -*-

;;; Commentary:

;; Enough of `shell-maker' for `agent-shell-side.el' to load: the buffer
;; history, and the buffer name shell-maker keeps for itself.  That name
;; is how shell-maker finds the shell again -- a renamed buffer whose
;; name was not set through here is lost to it -- so renaming is stubbed
;; exactly as the real one does it.

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

(defvar-local shell-maker--buffer-name-override nil
  "The name shell-maker looks the shell buffer up by.")

(defun shell-maker-set-buffer-name (buffer new-name)
  "Rename BUFFER to NEW-NAME, keeping shell-maker's own name in step.

A faithful copy of the real one: the rename and the override always
happen together, which is the whole reason the function exists."
  (with-current-buffer buffer
    (when (string-empty-p new-name)
      (user-error "Name shouldn't be empty"))
    (rename-buffer new-name t)
    (setq shell-maker--buffer-name-override (buffer-name (current-buffer)))))

(provide 'shell-maker)

;;; shell-maker.el ends here
