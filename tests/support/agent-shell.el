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

(defvar-local agent-shell-viewport--compose-disposition nil
  "Stub of the compose buffer's send disposition.")
(put 'agent-shell-viewport--compose-disposition 'permanent-local t)

(defvar-local agent-shell-test-viewport-shell nil
  "In a stub viewport buffer, the shell buffer it stands for.")
(put 'agent-shell-test-viewport-shell 'permanent-local t)

(cl-defun agent-shell-viewport--buffer (&key shell-buffer existing-only)
  "Return the stub viewport buffer for SHELL-BUFFER, if one exists."
  (ignore existing-only)
  (seq-find (lambda (buffer)
              (eq (buffer-local-value 'agent-shell-test-viewport-shell buffer)
                  shell-buffer))
            (buffer-list)))

(cl-defun agent-shell-viewport--show-buffer (&rest args
                                             &key shell-buffer submit no-focus
                                             disposition
                                             &allow-other-keys)
  "Record a viewport display, creating the stub viewport buffer on demand.

Refuses SUBMIT and NO-FOCUS exactly as the real one does, so a caller
that reaches a viewport when it meant to reach a shell fails here too."
  (when submit
    (error "Not yet supported"))
  (when no-focus
    (error "Not yet supported"))
  (push shell-buffer agent-shell-test-viewport-shown)
  (push args agent-shell-test-viewport-calls)
  (let ((buffer (or (agent-shell-viewport--buffer :shell-buffer shell-buffer)
                    (let ((buffer (generate-new-buffer
                                   " *agent-shell side test viewport*")))
                      (with-current-buffer buffer
                        (agent-shell-viewport-edit-mode)
                        (setq-local agent-shell-test-viewport-shell shell-buffer))
                      buffer))))
    ;; Written on every call, nil included, as the real one is.
    (with-current-buffer buffer
      (setq-local agent-shell-viewport--compose-disposition disposition))
    buffer))

(cl-defun agent-shell--insert-to-shell-buffer (&key text submit no-focus shell-buffer)
  "Record an insertion instead of touching a shell.

Refuses when the target is busy, as the real one does."
  (let ((target (or shell-buffer (current-buffer))))
    (when (memq (agent-shell-status :shell-buffer target) '(busy blocked))
      (user-error "Busy, try later"))
    (push (list (cons :text text)
                (cons :submit submit)
                (cons :no-focus no-focus)
                (cons :shell-buffer target))
          agent-shell-test-inserted))
  nil)

(cl-defun agent-shell-insert (&key text submit no-focus shell-buffer)
  "Dispatch on the current buffer, as the real one does.

From a viewport buffer it routes to `agent-shell-viewport--show-buffer',
which signals for `:submit' and `:no-focus'.  Anything that must reach a
shell buffer regardless of where the command was run has to say so."
  (if (and (not (derived-mode-p 'agent-shell-mode))
           (or agent-shell-prefer-viewport-interaction
               (derived-mode-p 'agent-shell-viewport-edit-mode)
               (derived-mode-p 'agent-shell-viewport-view-mode)))
      (agent-shell-viewport--show-buffer :append text :submit submit
                                         :no-focus no-focus
                                         :shell-buffer shell-buffer)
    (agent-shell--insert-to-shell-buffer :text text :submit submit
                                         :no-focus no-focus
                                         :shell-buffer shell-buffer)))

(defun agent-shell-cwd ()
  "Return the stubbed working directory."
  default-directory)

(cl-defun agent-shell-shell-buffer (&key viewport-buffer no-error no-create)
  "Return the shell buffer for VIEWPORT-BUFFER, or for the current buffer.

Resolves a viewport buffer to the shell it stands for, as the real one
does, so a command run from a viewport reaches the right shell."
  (ignore no-create)
  (let ((buffer (or viewport-buffer (current-buffer))))
    (cond
     ((buffer-local-value 'agent-shell-test-viewport-shell buffer))
     ((with-current-buffer buffer (derived-mode-p 'agent-shell-mode)) buffer)
     (no-error nil)
     (t (user-error "Not in a shell")))))

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
