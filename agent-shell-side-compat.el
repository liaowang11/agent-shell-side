;;; agent-shell-side-compat.el --- agent-shell private API shims -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Copyright (C) 2026 Bill and contributors

;;; Commentary:

;; Every read of an `agent-shell' internal lives here, so that a change
;; upstream breaks one file instead of the whole package.
;;
;; Three things this package needs are not in `agent-shell''s public API:
;;
;; 1. Starting a shell that forks a session.  `agent-shell-start' has no
;;    `:fork-session-id'; only the private `agent-shell--start' does.
;;    `agent-shell-fork' does take that path but hardcodes the parent's
;;    config, and a side conversation needs a derived config and its own
;;    outgoing-request decorator.
;;
;; 2. Reading whether the agent advertised `session/fork'.  This one is not
;;    a convenience: when `:fork-session-id' is set and the agent cannot
;;    fork, `agent-shell--initiate-session' quietly starts a *new empty
;;    session* instead.  A side conversation that silently loses its
;;    inherited history is worse than a refusal, so the capability has to
;;    be checked before starting.
;;
;; 3. Reading the current session id, to name the fork parent.  The public
;;    surface only offers `agent-shell-copy-session-id', which pushes onto
;;    the kill ring.  `agent-shell-side' prefers the id it captured from
;;    the public `session-selected' event and falls back to this.
;;
;; One more is borrowed for the user's sake rather than out of need: the
;; viewport, so a side conversation opens, and its findings land, where a
;; viewport user actually looks.
;;
;; Each shim checks for what it needs and signals a message naming the
;; missing piece, rather than failing somewhere deeper.

;;; Code:

(require 'map)
(eval-when-compile (require 'cl-lib))

(declare-function agent-shell--start "agent-shell")
(declare-function agent-shell--insert-to-shell-buffer "agent-shell")
(declare-function agent-shell-viewport--show-buffer "agent-shell-viewport")
(declare-function agent-shell-viewport--buffer "agent-shell-viewport")

(defvar agent-shell--state)
(defvar agent-shell-prefer-viewport-interaction)

(defconst agent-shell-side-compat--upgrade-hint
  "agent-shell-side needs agent-shell 0.74 or newer"
  "Suffix for errors raised when an `agent-shell' internal is missing.")

(defun agent-shell-side-compat--state (shell-buffer)
  "Return SHELL-BUFFER's `agent-shell' state alist.

Signals when the buffer has no state, which means it is not an
`agent-shell' buffer or `agent-shell' changed where state lives."
  (unless (buffer-live-p shell-buffer)
    (error "Not a live buffer: %S" shell-buffer))
  (let ((state (buffer-local-value 'agent-shell--state shell-buffer)))
    (unless (consp state)
      (error "No agent-shell state in %s; %s"
             (buffer-name shell-buffer)
             agent-shell-side-compat--upgrade-hint))
    state))

(defun agent-shell-side-compat-supports-fork-p (shell-buffer)
  "Return non-nil when SHELL-BUFFER's agent advertised `session/fork'.

The capability is recorded at `initialize' from
`agentCapabilities.sessionCapabilities.fork'."
  (let ((state (agent-shell-side-compat--state shell-buffer)))
    (unless (assq :supports-session-fork state)
      (error "Cannot read session/fork support from agent-shell; %s"
             agent-shell-side-compat--upgrade-hint))
    (and (map-elt state :supports-session-fork) t)))

(defun agent-shell-side-compat-session-id (shell-buffer)
  "Return SHELL-BUFFER's current ACP session id, or nil before one exists."
  (map-nested-elt (agent-shell-side-compat--state shell-buffer) '(:session :id)))

(defun agent-shell-side-compat-resumed-p (shell-buffer)
  "Return non-nil when SHELL-BUFFER was started by resuming a session id.

Such a shell starts with an empty buffer while the session behind it
already holds a transcript, so an empty buffer does not mean an
unforkable session."
  (and (map-elt (agent-shell-side-compat--state shell-buffer)
                :resume-session-id)
       t))

(defun agent-shell-side-compat-client (shell-buffer)
  "Return SHELL-BUFFER's ACP client, or nil when it has none yet."
  (map-elt (agent-shell-side-compat--state shell-buffer) :client))

(cl-defun agent-shell-side-compat-start-fork (&key config
                                                   fork-session-id
                                                   outgoing-request-decorator)
  "Start a background shell forking FORK-SESSION-ID, and return its buffer.

CONFIG is an agent config alist as built by
`agent-shell-make-agent-config'.  OUTGOING-REQUEST-DECORATOR is passed
through to the ACP client.

Mirrors what `agent-shell-fork' does, but with a caller-supplied config
and decorator.

The keyword is not checked before the call: `agent-shell--start' is a
`cl-defun', and `help-function-arglist' reports every `cl-defun' as
\(&rest --cl-rest--), so there is nothing to inspect.  `cl-defun' rejects
an unknown keyword itself, and that error is re-raised here with the
version it points to."
  (unless (fboundp 'agent-shell--start)
    (error "Missing agent-shell--start; %s"
           agent-shell-side-compat--upgrade-hint))
  (condition-case err
      (agent-shell--start :config config
                          :session-strategy 'new
                          :fork-session-id fork-session-id
                          :new-session t
                          :no-focus t
                          :outgoing-request-decorator outgoing-request-decorator)
    (error
     (if (string-match-p "fork-session-id" (error-message-string err))
         (error "Rejected :fork-session-id in agent-shell--start; %s"
                agent-shell-side-compat--upgrade-hint)
       (signal (car err) (cdr err))))))

(defun agent-shell-side-compat-viewport-buffer-p (&optional buffer)
  "Return non-nil when BUFFER, or the current one, is a viewport buffer."
  (with-current-buffer (or buffer (current-buffer))
    (derived-mode-p 'agent-shell-viewport-view-mode
                    'agent-shell-viewport-edit-mode)))

(defun agent-shell-side-compat-prefer-viewport-p ()
  "Return non-nil when shells should be shown through the viewport.

Either because the user asked for it globally, or because the command
was issued from a viewport buffer.  Mirrors `agent-shell--fork-shell-buffer'."
  (or (and (boundp 'agent-shell-prefer-viewport-interaction)
           agent-shell-prefer-viewport-interaction)
      (agent-shell-side-compat-viewport-buffer-p)))

(defun agent-shell-side-compat-viewport-buffer (shell-buffer)
  "Return SHELL-BUFFER's viewport buffer when one already exists, else nil."
  (when (fboundp 'agent-shell-viewport--buffer)
    (ignore-errors
      (agent-shell-viewport--buffer :shell-buffer shell-buffer :existing-only t))))

(defun agent-shell-side-compat-show-in-viewport (shell-buffer)
  "Show SHELL-BUFFER through a viewport, as `agent-shell-fork' would."
  (unless (fboundp 'agent-shell-viewport--show-buffer)
    (error "Missing agent-shell-viewport--show-buffer; %s"
           agent-shell-side-compat--upgrade-hint))
  (agent-shell-viewport--show-buffer :shell-buffer shell-buffer))

(defun agent-shell-side-compat--compose-disposition (shell-buffer)
  "Return the disposition of SHELL-BUFFER\='s in-progress compose draft.

Nil when there is no draft to speak for.  `agent-shell-viewport--show-buffer\='
writes the disposition on every call, nil included, so appending to a
draft the user had already marked `queue\=' would silently downgrade it to
whatever `agent-shell-prompt-while-busy\=' says -- steer, by default.
Reading it first lets us hand the same answer back.

Only an edit-mode buffer with something in it counts, matching how
`agent-shell-viewport--show-buffer\=' itself decides a draft is in
progress.  An empty compose buffer keeps a stale disposition, which is
the very thing writing on every call exists to clear."
  (when (fboundp 'agent-shell-viewport--buffer)
    (when-let* ((viewport (ignore-errors
                            (agent-shell-viewport--buffer
                             :shell-buffer shell-buffer :existing-only t)))
                ((buffer-live-p viewport)))
      (with-current-buffer viewport
        (and (derived-mode-p 'agent-shell-viewport-edit-mode)
             (> (buffer-size) 0)
             (bound-and-true-p agent-shell-viewport--compose-disposition))))))

(defun agent-shell-side-compat-compose-in-viewport (shell-buffer text)
  "Open SHELL-BUFFER's viewport compose buffer with TEXT appended, to be sent.

Opens in edit mode even while the shell is busy, which is the point: the
compose buffer is the one surface a viewport user can write in while a
turn runs, and its send keys let them queue or steer what they wrote.

Carries any in-progress draft's disposition through, so appending
findings to a prompt the user had already chosen to queue does not turn
it into a steer."
  (unless (fboundp 'agent-shell-viewport--show-buffer)
    (error "Missing agent-shell-viewport--show-buffer; %s"
           agent-shell-side-compat--upgrade-hint))
  (agent-shell-viewport--show-buffer
   :shell-buffer shell-buffer
   :append text
   :edit t
   :disposition (agent-shell-side-compat--compose-disposition shell-buffer)))

(defun agent-shell-side-compat-send-to-shell (shell-buffer text)
  "Submit TEXT to SHELL-BUFFER without moving the user\='s focus.

Deliberately not `agent-shell-insert\=': that dispatches on the *current*
buffer, so calling it from a viewport compose buffer routes into
`agent-shell-viewport--show-buffer\=', which signals \"Not yet supported\"
for both `:submit\=' and `:no-focus\='.  The target here is always a side
conversation\='s shell buffer, never a viewport, so address it directly."
  (unless (fboundp 'agent-shell--insert-to-shell-buffer)
    (error "Missing agent-shell--insert-to-shell-buffer; %s"
           agent-shell-side-compat--upgrade-hint))
  (agent-shell--insert-to-shell-buffer :text text
                                       :submit t
                                       :no-focus t
                                       :shell-buffer shell-buffer))

(provide 'agent-shell-side-compat)

;;; agent-shell-side-compat.el ends here
