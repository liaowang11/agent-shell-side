;;; agent-shell.el --- Test stub for agent-shell -*- lexical-binding: t; -*-

;;; Commentary:

;; Enough of `agent-shell' for the unit tests to load
;; `agent-shell-side.el'.  The tests here cover pure logic, so nothing in
;; this stub starts a process or talks to an agent.

;;; Code:

(require 'cl-lib)
(require 'map)

(defconst agent-shell-test-stub-p t
  "Non-nil when the agent-shell test stub is loaded.")

(defvar agent-shell--state nil)
(defvar agent-shell-agent-configs nil)
(defvar agent-shell-outgoing-request-decorator nil)

(define-derived-mode agent-shell-mode fundamental-mode "Agent-Shell")

(defvar agent-shell-test-subscriptions nil
  "Subscriptions recorded as (BUFFER EVENT FUNCTION TOKEN).")

(defvar agent-shell-test-unsubscribed nil
  "Tokens passed to `agent-shell-unsubscribe'.")

(defvar agent-shell-test-started nil
  "Arguments of the last `agent-shell-start' call.")

(defvar agent-shell-test-interrupted nil
  "Buffers `agent-shell-interrupt' was called in.")

(defvar agent-shell-test-status 'ready
  "Value `agent-shell-status' returns.")

(defvar agent-shell-test-inserted nil
  "Calls to `agent-shell-insert', newest first, as alists.")

(defvar agent-shell-display-action '(display-buffer-same-window))

(defvar agent-shell-prefer-viewport-interaction nil)

(define-derived-mode agent-shell-viewport-view-mode text-mode "Viewport (View)")
(define-derived-mode agent-shell-viewport-edit-mode text-mode "Viewport (Edit)")

(defvar agent-shell-test-viewport-shown nil
  "Shell buffers passed to `agent-shell-viewport--show-buffer', newest first.")

(defvar agent-shell-test-viewport-calls nil
  "Full keyword arguments of each `agent-shell-viewport--show-buffer' call.")

(cl-defun agent-shell-viewport--show-buffer (&rest args &key shell-buffer &allow-other-keys)
  "Record a viewport display instead of opening one."
  (push shell-buffer agent-shell-test-viewport-shown)
  (push args agent-shell-test-viewport-calls)
  nil)

(cl-defun agent-shell-insert (&key text submit no-focus shell-buffer)
  "Record an insertion instead of touching a shell.

Refuses when the target is busy, as the real one does
\(`agent-shell--insert-to-shell-buffer' signals \"Busy, try later\")."
  (let ((target (or shell-buffer (current-buffer))))
    (when (memq (agent-shell-status :shell-buffer target) '(busy blocked))
      (user-error "Busy, try later"))
    (push (list (cons :text text)
                (cons :submit submit)
                (cons :no-focus no-focus)
                (cons :shell-buffer target))
          agent-shell-test-inserted))
  nil)

(defun agent-shell-cwd ()
  "Return the stubbed working directory."
  default-directory)

(cl-defun agent-shell-shell-buffer (&key viewport-buffer no-error no-create)
  "Return the current buffer when it is a shell."
  (ignore viewport-buffer no-create)
  (if (derived-mode-p 'agent-shell-mode)
      (current-buffer)
    (unless no-error
      (user-error "Not in a shell"))))

(defun agent-shell-get-config (buffer)
  "Return BUFFER's agent config."
  (map-elt (buffer-local-value 'agent-shell--state buffer) :agent-config))

(cl-defun agent-shell-status (&key shell-buffer)
  "Return the stubbed status of SHELL-BUFFER, or of the current buffer.

`agent-shell-test-status' may be set buffer-locally so that a parent and
its side conversation can differ."
  (buffer-local-value 'agent-shell-test-status (or shell-buffer (current-buffer))))

(defun agent-shell-interrupt (&optional _force)
  "Record that an interrupt was requested."
  (push (current-buffer) agent-shell-test-interrupted))

(cl-defun agent-shell-subscribe-to (&key shell-buffer event on-event)
  "Record a subscription and return a token."
  (let ((token (gensym "agent-shell-test-subscription")))
    (push (list shell-buffer event on-event token) agent-shell-test-subscriptions)
    token))

(cl-defun agent-shell-unsubscribe (&key subscription)
  "Record an unsubscription."
  (push subscription agent-shell-test-unsubscribed))

(cl-defun agent-shell-start (&key config session-id outgoing-request-decorator)
  "Record a start request."
  (setq agent-shell-test-started
        (list (cons :config config)
              (cons :session-id session-id)
              (cons :outgoing-request-decorator outgoing-request-decorator)))
  (current-buffer))

(cl-defun agent-shell--start (&key config no-focus new-session session-strategy
                                   session-id fork-session-id
                                   outgoing-request-decorator)
  "Record a fork start request and return a fresh shell buffer."
  (ignore no-focus new-session session-strategy session-id)
  (setq agent-shell-test-started
        (list (cons :config config)
              (cons :fork-session-id fork-session-id)
              (cons :outgoing-request-decorator outgoing-request-decorator)))
  (let ((buffer (generate-new-buffer " *agent-shell side test child*")))
    (with-current-buffer buffer
      (agent-shell-mode)
      (setq-local agent-shell--state (list (cons :agent-config config)
                                           (cons :session nil)
                                           (cons :client 'stub-client)
                                           (cons :supports-session-fork t))))
    buffer))

(provide 'agent-shell)

;;; agent-shell.el ends here
