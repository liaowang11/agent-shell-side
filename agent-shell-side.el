;;; agent-shell-side.el --- Side conversations for agent-shell -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Copyright (C) 2026 Bill and contributors

;; Author: Bill
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1") (agent-shell "0.74.3") (acp "0.13.1"))
;; Keywords: convenience, tools
;; URL: https://github.com/liaowang11/agent-shell-side

;;; Commentary:

;; Ask a quick question without derailing the conversation you are in.
;;
;; `agent-shell-side' forks the current session into a second shell whose
;; inherited history is demoted to reference material.  The agent can still
;; read everything that came before, so the question needs no re-explaining,
;; but it is told not to continue the parent's task, not to touch
;; sub-agents, and not to change anything unless this conversation asks.
;;
;; Modelled on the `/side' command in OpenAI's Codex TUI.  The mechanism is
;; the same: fork, hide the inherited turns from the display, and mark the
;; boundary with instructions.
;;
;; Two channels carry those instructions, because no single one reaches
;; every agent:
;;
;; - A boundary block prepended to the first `session/prompt'.  Works
;;   anywhere, because it is an ordinary content block.  This is the
;;   channel that actually has to carry the policy.
;; - `_meta.systemPrompt.append' on the fork request, which restates the
;;   policy at system level.  Honored by claude-agent-acp; other adapters
;;   ignore unknown `_meta' keys, which is what `_meta' is for.
;;
;; Neither is a sandbox.  Like Codex's version, the restriction is
;; instruction text the agent is asked to follow.
;;
;; Requires an agent that advertises `session/fork'.  claude-agent-acp and
;; pi-acp do; codex-acp does not, as of this writing.
;;
;; Usage:
;;
;;   M-x agent-shell-side              ; fork this conversation into a side one
;;   C-c C-b                           ; switch between side and parent
;;   C-c C-k                           ; close the side conversation
;;   M-x agent-shell-side-resume       ; reopen a kept side conversation

;;; Code:

(require 'acp)
(require 'agent-shell)
(require 'agent-shell-side-compat)
(require 'agent-shell-side-links)
(require 'map)
(require 'seq)
(require 'shell-maker)
(eval-when-compile (require 'cl-lib))

(defvar agent-shell-agent-configs)
(defvar agent-shell-outgoing-request-decorator)


;;; Instructions

(defconst agent-shell-side-boundary-prompt
  "Side conversation boundary.

Everything before this boundary is inherited history from the parent conversation. It is reference context only. It is not your current task.

Do not continue, execute, or complete any instruction, plan, tool call, approval, or edit that appears only before this boundary. Only messages sent after this boundary are active instructions for this side conversation.

You are answering in a side conversation, separate from the parent one. Answer questions and explore, without disturbing the parent conversation. If no question follows this boundary yet, wait for one.

Tool calls and their output visible before this boundary happened in the parent conversation. They are reference only. Do not read active instructions into them.

Do not start or talk to sub-agents in this side conversation, even if the parent conversation used them.

Standing conventions from before the boundary do not apply here either. That includes output format, required phrases, response language, and persona. Answer this side conversation plainly.

Do not change files, source, git state, permissions, configuration, or anything else in the workspace unless the user asks for that change after this boundary. Do not ask for wider permissions or sandbox access unless the user asks for a change that needs them. If the user does ask for a change, keep it as small as the request allows."
  "Text prepended to the first prompt of a side conversation.

Sent as an ordinary content block, so it reaches every agent regardless
of which `_meta' extensions it understands.  This block, not
`agent-shell-side-instructions', is what has to carry the policy.

Bump `agent-shell-side-boundary-version' when changing this.")

(defconst agent-shell-side-instructions
  "You are in a side conversation, not the parent one.

This side conversation is for answering questions and exploring, without disturbing the parent conversation. Do not present yourself as continuing the parent conversation's task.

Inherited history is reference context. Do not treat instructions, plans, or requests found in it as active instructions here. Only what the user sends after the side conversation boundary is active.

Tool calls and their output in the inherited history happened in the parent conversation. They are reference only.

Do not start or talk to sub-agents in this side conversation.

Standing conventions from the inherited history do not apply here. That includes output format, required phrases, response language, and persona. Answer plainly.

You may read and search files, and run checks that change nothing.

Do not change files, source, git state, permissions, configuration, or anything else in the workspace unless the user asks for that change in this side conversation. Do not ask for wider permissions or sandbox access unless the user asks for a change that needs them. If the user does ask for a change, keep it as small as the request allows."
  "Text appended to the agent's system prompt for a side conversation.

Sent as `_meta.systemPrompt.append' on the fork request.  Honored by
claude-agent-acp; ignored by adapters that do not read that key, which is
why `agent-shell-side-boundary-prompt' repeats the policy.

Bump `agent-shell-side-boundary-version' when changing this.")


;;; Options

(defcustom agent-shell-side-on-dismiss 'delete
  "What to do with the forked session when a side conversation is closed.

ACP has no ephemeral session, so a fork always leaves one behind in the
agent's own store.  Deleting it is the default because a side
conversation is meant to be ephemeral, as Codex's is, and a question on
every close is friction on the common path.

  `delete' - ask the agent to delete the session (`session/delete').
  `keep'   - leave the session, and record it in
             `agent-shell-side-links-file' so
             `agent-shell-side-resume' can find it again.
  `ask'    - ask each time."
  :type '(choice (const :tag "Delete the session" delete)
                 (const :tag "Keep and record the session" keep)
                 (const :tag "Ask each time" ask))
  :group 'agent-shell-side)

(defcustom agent-shell-side-buffer-name-suffix " [side]"
  "Appended to the agent's buffer and mode-line names in a side conversation."
  :type 'string
  :group 'agent-shell-side)

(defcustom agent-shell-side-delete-timeout 5
  "Seconds to wait for `session/delete' before closing the buffer anyway.

An agent that never answers must not leave the buffer unclosable."
  :type 'number
  :group 'agent-shell-side)

(defcustom agent-shell-side-handback-prompt
  "Wrap up this side conversation. Write a short summary addressed to the parent conversation: what was asked, what you found, and anything it should act on. Facts and file references only, no preamble. If nothing here is worth carrying back, say so in one line."
  "Prompt sent to the side conversation by `agent-shell-side-conclude'.

Its answer is what gets handed back to the parent conversation."
  :type 'string
  :group 'agent-shell-side)

(defcustom agent-shell-side-handback-header
  "Findings from a side conversation:"
  "Line introducing handed-back findings in the parent conversation."
  :type 'string
  :group 'agent-shell-side)

(defcustom agent-shell-side-handback-submit nil
  "Whether handed-back findings are sent in the parent, or left to review.

When nil, the findings are inserted at the parent's prompt and left
there for you to send, queue, or steer.  Only read when the parent is
shown as a plain shell: the viewport compose buffer has no way to submit
on insertion, and leaves sending to its own keys."
  :type 'boolean
  :group 'agent-shell-side)

(defcustom agent-shell-side-handback-timeout 180
  "Seconds to wait for the summary before giving up on a handback.

On timeout the side conversation is left open, with its findings intact."
  :type 'number
  :group 'agent-shell-side)

(defcustom agent-shell-side-report-parent-status t
  "Whether to echo a message when the parent conversation wants attention.

The status is shown in the mode line either way.  This adds an echo-area
message at the moment it changes, for when the side conversation has the
window and the parent is off screen."
  :type 'boolean
  :group 'agent-shell-side)


;;; Buffer-local state

(defvar-local agent-shell-side--is-side nil
  "Non-nil in a side conversation, for as long as the buffer lives.

Kept separate from `agent-shell-side--parent-buffer', which is cleared
when the parent goes away.  What a buffer *is* does not change when its
parent is killed, and the orphans are the ones most likely to be left
lying around, so they have to stay recognisable.")

(defvar-local agent-shell-side--created-at nil
  "In a side conversation, when it was opened.")

(defvar-local agent-shell-side--parent-buffer nil
  "In a side conversation, the shell buffer it was forked from.")

(defvar-local agent-shell-side--side-buffer nil
  "In a parent shell, the side conversation forked from it.")

(defvar-local agent-shell-side--parent-status nil
  "In a side conversation, the parent's last notable state.

One of `needs-approval', `finished', `failed', `closed', or nil.")

(defvar-local agent-shell-side--parent-subscription nil
  "In a side conversation, its subscription token on the parent buffer.")

(defvar-local agent-shell-side--session-id-cache nil
  "Session id captured from the `session-selected' event, when it arrived.")

(defvar-local agent-shell-side--handback-pending nil
  "In a side conversation, non-nil while findings wait for the parent's turn.")

(defun agent-shell-side--live-buffer (buffer)
  "Return BUFFER when it is still live, else nil."
  (and (bufferp buffer) (buffer-live-p buffer) buffer))

(defun agent-shell-side-buffer-p (&optional buffer)
  "Return non-nil when BUFFER is a side conversation.

Stays true after the parent is killed.  A side conversation that outlived
its parent is still a side conversation, and still has a forked session
to dispose of."
  (and (buffer-local-value 'agent-shell-side--is-side
                           (or buffer (current-buffer)))
       t))

(defun agent-shell-side--session-id (buffer)
  "Return BUFFER's ACP session id.

Prefers the id captured from the public `session-selected' event, and
falls back to reading `agent-shell' state for shells that were already
running when this package loaded."
  (or (buffer-local-value 'agent-shell-side--session-id-cache buffer)
      (ignore-errors (agent-shell-side-compat-session-id buffer))))


;;; Opening message

(defun agent-shell-side--quote (text)
  "Return TEXT as a markdown block quote.

Blank lines are quoted too.  An unprefixed blank line ends a block quote
in markdown, which would leave the rest of a multi-paragraph selection
reading as the user's own words rather than as quoted material."
  (mapconcat (lambda (line)
               (if (string-empty-p line) ">" (concat "> " line)))
             (split-string (string-trim text) "\n")
             "\n"))

(defun agent-shell-side--opening-message (selection question)
  "Return the first message for a side conversation, or nil for none.

SELECTION is text quoted from the parent conversation, QUESTION the
user's own words.  Either may be nil or blank."
  (let* ((selection (and selection
                         (not (string-blank-p selection))
                         (agent-shell-side--quote selection)))
         (question (and question
                        (not (string-blank-p question))
                        (string-trim question)))
         (parts (delq nil (list selection question))))
    (when parts
      (string-join parts "\n\n"))))

(defun agent-shell-side--region-text ()
  "Return the active region's text, deactivating it, or nil when there is none."
  (when (use-region-p)
    (prog1 (buffer-substring-no-properties (region-beginning) (region-end))
      (deactivate-mark))))

(defun agent-shell-side--read-opening-message ()
  "Read the message a side conversation should open with, or nil for none.

A selection in the parent conversation is carried in as a block quote, so
a question about part of an answer can point at that part.  An empty
question opens the side conversation with nothing sent."
  (let* ((selection (agent-shell-side--region-text))
         (question (read-string (if selection
                                    "Ask about the selection (empty to just quote it): "
                                  "Side conversation (empty to start blank): "))))
    (agent-shell-side--opening-message selection question)))

(defun agent-shell-side--send-when-ready (side-buffer message)
  "Send MESSAGE in SIDE-BUFFER once its session is ready.

The fork is asynchronous, so the session does not exist yet when
`agent-shell-side' returns.  `prompt-ready' is the public signal that it
does.  It is emitted for every prompt, not only the first, so the
subscription drops itself after firing."
  (let ((token nil)
        (sent nil))
    (setq token
          (agent-shell-subscribe-to
           :shell-buffer side-buffer
           :event 'prompt-ready
           :on-event
           (lambda (_event)
             (unless sent
               (setq sent t)
               (when (buffer-live-p side-buffer)
                 (agent-shell-side--unsubscribe side-buffer token)
                 (agent-shell-insert :text message
                                     :submit t
                                     :no-focus t
                                     :shell-buffer side-buffer))))))
    token))


;;; Prompt decoration

(defun agent-shell-side--content-block (text)
  "Return TEXT as an ACP text content block."
  `((type . "text")
    (text . ,text)))

(defun agent-shell-side--prepend-boundary (request)
  "Return REQUEST with the side boundary block ahead of its prompt.

REQUEST is an ACP request alist as built by
`acp-make-session-prompt-request'.  The original is left unchanged, since
`acp-send-request' hands the caller's own object to the decorator."
  (let* ((params (copy-alist (map-elt request :params)))
         (prompt (append (map-elt params 'prompt) nil)))
    (setf (alist-get 'prompt params)
          (vconcat (list (agent-shell-side--content-block
                          agent-shell-side-boundary-prompt))
                   prompt))
    (cons (cons :params params)
          (assq-delete-all :params (copy-alist request)))))

(defun agent-shell-side--make-decorator (&optional next)
  "Return a decorator prepending the boundary to the first `session/prompt'.

NEXT, when non-nil, is a decorator to run afterwards, so a user's own
`agent-shell-outgoing-request-decorator' is not displaced.  A NEXT that
returns nil is treated as \"no change\", matching how
`acp-send-request' handles it.

Only `session/prompt' consumes the boundary.  Requests such as
`session/set_mode' can precede the first prompt, and swallowing the
boundary on one of those would mean the agent never sees it."
  (let ((sent nil))
    (lambda (request)
      (let ((request (if (and (not sent)
                              (equal (map-elt request :method) "session/prompt"))
                         (progn
                           (setq sent t)
                           (agent-shell-side--prepend-boundary request))
                       request)))
        (if next
            (or (funcall next request) request)
          request)))))


;;; Derived config

(defun agent-shell-side--session-meta (parent-meta)
  "Return PARENT-META with the side instructions appended to the system prompt.

PARENT-META is an agent config's `:session-meta', sent as `_meta' with
session-creating requests.  An `append' the parent already carries is
kept ahead of the side instructions: it is the user's configuration, not
a convention of the parent conversation, and the boundary text cancels
only the latter.  Codex composes its developer instructions the same way.
Other `systemPrompt' keys are carried over untouched."
  (let* ((parent-prompt (map-elt parent-meta 'systemPrompt))
         (parent-append (map-elt parent-prompt 'append))
         (append (if (and (stringp parent-append)
                          (not (string-blank-p parent-append)))
                     (concat (string-trim-right parent-append)
                             "\n\n"
                             agent-shell-side-instructions)
                   agent-shell-side-instructions)))
    (cons (cons 'systemPrompt
                (cons (cons 'append append)
                      (assq-delete-all 'append (copy-alist parent-prompt))))
          (assq-delete-all 'systemPrompt (copy-alist parent-meta)))))

(defun agent-shell-side--config (parent-config)
  "Return an agent config for a side conversation forked from PARENT-CONFIG.

Keeps the parent's agent, client, and authentication, and changes only
what marks the shell as a side conversation: its names and its session
metadata.  PARENT-CONFIG is left unchanged."
  (let ((config (copy-alist parent-config)))
    (setf (alist-get :buffer-name config)
          (concat (or (map-elt parent-config :buffer-name) "Agent")
                  agent-shell-side-buffer-name-suffix))
    (setf (alist-get :mode-line-name config)
          (concat (or (map-elt parent-config :mode-line-name) "Agent")
                  agent-shell-side-buffer-name-suffix))
    (setf (alist-get :session-meta config)
          (agent-shell-side--session-meta (map-elt parent-config :session-meta)))
    config))

(defun agent-shell-side--config-for-identifier (identifier)
  "Return the known agent config whose `:identifier' is IDENTIFIER, or nil.

Resolves `agent-shell-agent-configs', which holds either configs or
functions returning them, and may itself be a function."
  (seq-find (lambda (config)
              (eq (map-elt config :identifier) identifier))
            (mapcar (lambda (entry)
                      (if (functionp entry) (funcall entry) entry))
                    (if (functionp agent-shell-agent-configs)
                        (funcall agent-shell-agent-configs)
                      agent-shell-agent-configs))))


;;; Parent status

(defun agent-shell-side--status-for-event (event)
  "Return the parent status EVENT implies.

Returns a status symbol, `clear' to drop the current status, or nil when
the event says nothing worth showing."
  (pcase event
    ('permission-request 'needs-approval)
    ('turn-complete 'finished)
    ('error 'failed)
    ('clean-up 'closed)
    ((or 'input-submitted 'permission-response) 'clear)
    (_ nil)))

(defun agent-shell-side--status-phrase (status)
  "Return a bare description of parent STATUS, or nil when there is none.

Says what happened without naming the parent, for places that name it
already."
  (pcase status
    ('needs-approval "needs approval")
    ('finished "finished")
    ('failed "failed")
    ('closed "closed")
    (_ nil)))

(defun agent-shell-side--status-label (status)
  "Return a one-line description of parent STATUS, or nil when there is none."
  (when-let* ((phrase (agent-shell-side--status-phrase status)))
    (concat "main " phrase)))

(defun agent-shell-side--set-parent-status (side-buffer status)
  "Record STATUS as SIDE-BUFFER's parent state and refresh its mode line."
  (when (buffer-live-p side-buffer)
    (with-current-buffer side-buffer
      (unless (eq agent-shell-side--parent-status status)
        (setq agent-shell-side--parent-status status)
        (force-mode-line-update)
        ;; Only when the side conversation is on screen.  The echo is for
        ;; the user sitting in it with the parent out of view; someone
        ;; looking at the parent already sees what happened.
        (when (and status
                   agent-shell-side-report-parent-status
                   (get-buffer-window side-buffer t)
                   (agent-shell-side--status-label status))
          (message "Side conversation: %s"
                   (agent-shell-side--status-label status)))))))

(defun agent-shell-side--watch-parent (side-buffer parent-buffer)
  "Report PARENT-BUFFER's notable state changes in SIDE-BUFFER.

Returns the subscription token."
  (agent-shell-subscribe-to
   :shell-buffer parent-buffer
   :on-event
   (lambda (event)
     (pcase (agent-shell-side--status-for-event (map-elt event :event))
       ('nil nil)
       ('clear (agent-shell-side--set-parent-status side-buffer nil))
       (status (agent-shell-side--set-parent-status side-buffer status))))))

(defun agent-shell-side--abandon-fork (side-buffer message)
  "Close SIDE-BUFFER after its fork failed to start a session.

MESSAGE is what the agent said, repeated so the reason is not guesswork."
  (let ((parent (agent-shell-side--live-buffer
                 (buffer-local-value 'agent-shell-side--parent-buffer
                                     side-buffer))))
    (when (buffer-live-p side-buffer)
      (let ((window (get-buffer-window side-buffer)))
        (kill-buffer side-buffer)
        (when (and parent (window-live-p window))
          (set-window-buffer window parent)))))
  (message (concat "agent-shell-side: the fork did not start a session%s.  "
                   "A conversation that has not taken a turn yet cannot be "
                   "forked; send a message in it first")
           (if message (format " (%s)" message) "")))

(defun agent-shell-side--watch-startup (side-buffer)
  "Record SIDE-BUFFER's session id, or close it when the fork starts none.

`session/fork' can fail while leaving the shell it was started for
behind: no session is ever selected, and the buffer takes input that goes
nowhere.  claude-agent-acp does exactly that when the parent has never
taken a turn, answering -32002 Resource not found.  A side conversation
with nothing to talk to is worse than a refusal, so it is closed and the
reason said out loud.

Only errors before a session exists mean the fork failed.  Once one is
selected, an error is an ordinary failed request and the shell keeps it."
  (let ((token nil)
        (settled nil))
    (setq token
          (agent-shell-subscribe-to
           :shell-buffer side-buffer
           :on-event
           (lambda (event)
             (unless settled
               (pcase (map-elt event :event)
                 ('session-selected
                  (setq settled t)
                  (agent-shell-side--unsubscribe side-buffer token)
                  (when-let* ((session-id (map-nested-elt event
                                                          '(:data :session-id))))
                    (when (buffer-live-p side-buffer)
                      (with-current-buffer side-buffer
                        (setq agent-shell-side--session-id-cache session-id)))))
                 ('error
                  (setq settled t)
                  (agent-shell-side--unsubscribe side-buffer token)
                  (agent-shell-side--abandon-fork
                   side-buffer (map-nested-elt event '(:data :message))))
                 (_ nil))))))
    token))


;;; Minor mode

(defun agent-shell-side--this-shell ()
  "Return the shell buffer this buffer speaks for.

A viewport buffer stands for the shell behind it, so a command run there
acts on that shell rather than on the viewport.  This is what makes
`agent-shell-side-conclude' and its siblings work from a compose buffer,
which is where a viewport user sits.

The side keys are deliberately *not* bound in a viewport buffer.
`agent-shell-viewport-edit-mode-map' already gives the same two keys to
discarding and to queueing a draft, and a minor mode would outrank both.
Taking them over would turn cancelling a draft into deleting a forked
session.  Use \[execute-extended-command] there, or bind the side
commands to keys of your own choosing.

`:no-create t' rules out the branch that would ask the user which shell
to use, so this stays safe to call from a mode-line lighter."
  (or (and (agent-shell-side-compat-viewport-buffer-p)
           (when-let* ((shell (ignore-errors
                                (agent-shell-shell-buffer
                                 :viewport-buffer (current-buffer)
                                 :no-error t :no-create t))))
             ;; Only when that shell really is one end of a side
             ;; conversation.  `agent-shell-shell-buffer' falls back to the
             ;; first shell in the project when a viewport cannot be matched
             ;; to its own shell, which a renamed shell buffer causes, and
             ;; acting on an unrelated conversation is worse than refusing.
             (and (or (agent-shell-side-buffer-p shell)
                      (buffer-local-value 'agent-shell-side--side-buffer shell))
                  shell)))
      (current-buffer)))

(defun agent-shell-side--lighter-string (role status &optional pending)
  "Return the mode-line lighter for ROLE with parent STATUS.

ROLE is `side' in a side conversation, `parent' in a shell that has one.
PENDING, in a side conversation, means findings are waiting for the
parent's turn to end.  It outranks STATUS: a parent that is mid-turn is
why the findings are waiting, so saying both would say the same thing
twice."
  (pcase role
    ('side (cond
            (pending " Side:findings waiting")
            ((agent-shell-side--status-label status)
             (concat " Side:" (agent-shell-side--status-label status)))
            (t " Side")))
    (_ " Side↩")))

(defun agent-shell-side--lighter ()
  "Return the mode-line lighter for the current buffer."
  (let ((shell (agent-shell-side--this-shell)))
    (agent-shell-side--lighter-string
     (if (agent-shell-side-buffer-p shell) 'side 'parent)
     (buffer-local-value 'agent-shell-side--parent-status shell)
     (buffer-local-value 'agent-shell-side--handback-pending shell))))

(defvar-keymap agent-shell-side-mode-map
  :doc "Keymap for `agent-shell-side-mode'."
  "C-c C-b" #'agent-shell-side-toggle
  "C-c C-k" #'agent-shell-side-dismiss
  "C-c C-q" #'agent-shell-side-conclude)

(defun agent-shell-side--key-for (command)
  "Return COMMAND's key in `agent-shell-side-mode-map', described for humans.

`where-is-internal' with FIRSTONLY returns a key vector rather than a
list of them, so the result goes straight to `key-description'."
  (if-let* ((key (where-is-internal command agent-shell-side-mode-map t)))
      (key-description key)
    (format "M-x %s" command)))

(define-minor-mode agent-shell-side-mode
  "Minor mode for a side conversation and the shell it was forked from.

Enabled automatically by `agent-shell-side' in both buffers, so the same
two keys work from either end.  Not meant to be turned on by hand."
  :lighter (:eval (agent-shell-side--lighter))
  :keymap agent-shell-side-mode-map
  :group 'agent-shell-side)


;;; Linking and teardown

(defun agent-shell-side--mark-side (side-buffer)
  "Make SIDE-BUFFER a side conversation, with or without a parent.

Everything that makes a side conversation recognisable and closable
lives here, so a resumed one gets the same lighter, keys, and listing
as a freshly forked one.  Linking to a parent is separate."
  (with-current-buffer side-buffer
    (setq agent-shell-side--is-side t)
    (setq agent-shell-side--created-at (current-time))
    (agent-shell-side-mode 1)
    (add-hook 'kill-buffer-hook #'agent-shell-side--on-side-killed nil t)))

(defun agent-shell-side--link (side-buffer parent-buffer)
  "Make SIDE-BUFFER and PARENT-BUFFER each other's counterpart."
  (with-current-buffer parent-buffer
    (setq agent-shell-side--side-buffer side-buffer)
    (agent-shell-side-mode 1)
    (add-hook 'kill-buffer-hook #'agent-shell-side--on-parent-killed nil t))
  (agent-shell-side--mark-side side-buffer)
  (with-current-buffer side-buffer
    (setq agent-shell-side--parent-buffer parent-buffer)
    (setq agent-shell-side--parent-subscription
          (agent-shell-side--watch-parent side-buffer parent-buffer))
    (agent-shell-side--watch-startup side-buffer)))

(defun agent-shell-side--unsubscribe (shell-buffer token)
  "Drop subscription TOKEN from SHELL-BUFFER, if both still exist.

`agent-shell-unsubscribe' reads the shell state of the current buffer, so
the buffer has to be current for it."
  (when (and token (buffer-live-p shell-buffer))
    (with-current-buffer shell-buffer
      (ignore-errors (agent-shell-unsubscribe :subscription token)))))

(defun agent-shell-side--unwatch-parent (side-buffer)
  "Drop SIDE-BUFFER's subscription on its parent."
  (agent-shell-side--unsubscribe
   (agent-shell-side--live-buffer
    (buffer-local-value 'agent-shell-side--parent-buffer side-buffer))
   (buffer-local-value 'agent-shell-side--parent-subscription side-buffer)))

(defun agent-shell-side--on-side-killed ()
  "Detach a side conversation buffer that is going away."
  (let ((side-buffer (current-buffer)))
    (agent-shell-side--unwatch-parent side-buffer)
    (when-let* ((parent (agent-shell-side--live-buffer
                         agent-shell-side--parent-buffer)))
      (with-current-buffer parent
        (setq agent-shell-side--side-buffer nil)
        (agent-shell-side-mode -1)))))

(defun agent-shell-side--on-parent-killed ()
  "Leave a side conversation standing on its own when its parent goes away."
  (when-let* ((side (agent-shell-side--live-buffer
                     agent-shell-side--side-buffer)))
    (agent-shell-side--unwatch-parent side)
    (with-current-buffer side
      (setq agent-shell-side--parent-buffer nil)
      (setq agent-shell-side--parent-subscription nil)
      (agent-shell-side--set-parent-status side 'closed))))


;;; Session disposal

(defun agent-shell-side--delete-session (side-buffer on-done)
  "Ask SIDE-BUFFER's agent to delete its session, then call ON-DONE.

ON-DONE runs on success, on failure, and after
`agent-shell-side-delete-timeout' seconds, so an agent that never answers
cannot leave the buffer unclosable."
  (let ((client (ignore-errors (agent-shell-side-compat-client side-buffer)))
        (session-id (agent-shell-side--session-id side-buffer))
        (settled nil))
    (if (not (and client session-id))
        (funcall on-done)
      (let ((finish (lambda (&rest _)
                      (unless settled
                        (setq settled t)
                        (funcall on-done)))))
        (condition-case err
            (progn
              (acp-send-request
               :client client
               :request (acp-make-session-delete-request :session-id session-id)
               :on-success finish
               :on-failure finish)
              (run-at-time agent-shell-side-delete-timeout nil finish))
          (error
           (message "agent-shell-side: could not delete session %s (%s)"
                    session-id (error-message-string err))
           (funcall finish)))))))

(defun agent-shell-side--record-link (side-buffer)
  "Remember SIDE-BUFFER's session as a side conversation of its parent."
  (let ((side-session-id (agent-shell-side--session-id side-buffer))
        (parent (agent-shell-side--live-buffer
                 (buffer-local-value 'agent-shell-side--parent-buffer
                                     side-buffer))))
    (if-let* ((side-session-id side-session-id)
              (parent parent)
              (parent-session-id (agent-shell-side--session-id parent)))
        (agent-shell-side-links-add
         (agent-shell-side-links-make
          :side-session-id side-session-id
          :parent-session-id parent-session-id
          :agent (map-elt (agent-shell-get-config parent) :identifier)
          :cwd (buffer-local-value 'default-directory side-buffer)))
      (message "agent-shell-side: not recording this side conversation (%s)"
               (cond ((not side-session-id) "it has no session yet")
                     ((not parent) "its parent is gone")
                     (t "its parent has no session"))))))

(defun agent-shell-side--read-disposal ()
  "Return `delete' or `keep' for the side conversation being closed."
  (pcase agent-shell-side-on-dismiss
    ('delete 'delete)
    ('keep 'keep)
    (_ (if (y-or-n-p "Delete the forked session (no keeps it for agent-shell-side-resume)? ")
           'delete
         'keep))))


;;; Commands

(defun agent-shell-side--parent-shell ()
  "Return the shell buffer a side conversation should fork from.

Signals when there is no shell, when it has not started a session, or
when it is already a side conversation."
  (let ((shell-buffer (agent-shell-shell-buffer :no-error t :no-create t)))
    (unless shell-buffer
      (user-error "No agent shell here to start a side conversation from"))
    (when (agent-shell-side-buffer-p shell-buffer)
      (user-error "Already in a side conversation"))
    (when (agent-shell-side--live-buffer
           (buffer-local-value 'agent-shell-side--side-buffer shell-buffer))
      (user-error "A side conversation is already open; %s to switch to it"
                  (agent-shell-side--key-for #'agent-shell-side-toggle)))
    shell-buffer))

(defun agent-shell-side--conversation-started-p (shell-buffer)
  "Return non-nil when SHELL-BUFFER holds a conversation that can be forked.

A session id is not enough.  `session/new' hands one out before anything
has been said, and claude-agent-acp answers `session/fork' with -32002
Resource not found while the session still has no transcript to copy.

A completed exchange in the buffer proves there is one.  So does having
been resumed by id: resuming replays nothing into the buffer, so its
history reads as empty while the session behind it is full, and forking
one works."
  (or (agent-shell-side-compat-resumed-p shell-buffer)
      (with-current-buffer shell-buffer
        (and (ignore-errors (shell-maker-history)) t))))

(defun agent-shell-side--forkable-parent ()
  "Return the shell buffer a side conversation can be forked from now.

Runs every refusal `agent-shell' has for a fork, so a caller can check
before asking the user for anything."
  (let* ((parent-buffer (agent-shell-side--parent-shell))
         (parent-config (agent-shell-get-config parent-buffer)))
    (unless (agent-shell-side--session-id parent-buffer)
      (user-error
       "This conversation has not started yet; send a message, then try again"))
    (unless (agent-shell-side--conversation-started-p parent-buffer)
      (user-error
       "This conversation has not taken a turn yet; send a message, then try again"))
    (unless (agent-shell-side-compat-supports-fork-p parent-buffer)
      (user-error "%s cannot fork sessions, so it cannot hold a side conversation"
                  (or (map-elt parent-config :mode-line-name) "This agent")))
    parent-buffer))

(defun agent-shell-side--display (buffer &optional viewport)
  "Show BUFFER the way `agent-shell' shows its own buffers.

With VIEWPORT, or when the user prefers viewport interaction, the buffer
is shown through a viewport as `agent-shell-fork' would show it.
Otherwise it honors `agent-shell-display-action' rather than picking a
window directly, so a side conversation lands where the user already
told `agent-shell' to put shells."
  (if (or viewport (agent-shell-side-compat-prefer-viewport-p))
      (agent-shell-side-compat-show-in-viewport buffer)
    (when-let* ((window (display-buffer buffer agent-shell-display-action)))
      (select-window window))))

;;;###autoload
(defun agent-shell-side (&optional message)
  "Fork this conversation into a side one and switch to it.

The side conversation inherits the parent's history as reference context
but is told not to continue its task, and not to change anything unless
asked.  Close it with `agent-shell-side-dismiss', or with
`agent-shell-side-conclude' to carry a summary back.

MESSAGE, when non-nil, is sent as soon as the forked session is ready.
Called interactively, an active region is carried in as a block quote and
a question is read in the minibuffer, so a side conversation can point at
part of an answer.  An empty question starts the conversation blank.

Requires an agent that advertises `session/fork'.

Every refusal runs before the question is asked, so a conversation that
cannot be forked costs no typing."
  (interactive (progn (agent-shell-side--forkable-parent)
                      (list (agent-shell-side--read-opening-message))))
  (let* ((parent-buffer (agent-shell-side--forkable-parent))
         (parent-session-id (agent-shell-side--session-id parent-buffer))
         (parent-config (agent-shell-get-config parent-buffer))
         (from-viewport (agent-shell-side-compat-viewport-buffer-p)))
    (let* ((default-directory (buffer-local-value 'default-directory parent-buffer))
           (side-buffer (agent-shell-side-compat-start-fork
                         :config (agent-shell-side--config parent-config)
                         :fork-session-id parent-session-id
                         :outgoing-request-decorator
                         (agent-shell-side--make-decorator
                          agent-shell-outgoing-request-decorator))))
      (agent-shell-side--link side-buffer parent-buffer)
      (when message
        (agent-shell-side--send-when-ready side-buffer message))
      (agent-shell-side--display side-buffer from-viewport)
      side-buffer)))

;;;###autoload
(defun agent-shell-side-toggle ()
  "Switch between a side conversation and the shell it was forked from."
  (interactive)
  (let* ((shell (agent-shell-side--this-shell))
         (target (or (agent-shell-side--live-buffer
                      (buffer-local-value 'agent-shell-side--parent-buffer shell))
                     (agent-shell-side--live-buffer
                      (buffer-local-value 'agent-shell-side--side-buffer shell)))))
    (unless target
      (user-error "No side conversation linked to this buffer"))
    ;; Swap in place when this buffer has a window: toggling is "show the
    ;; other end here", not "find somewhere for it".
    (if-let* ((window (get-buffer-window (current-buffer))))
        (progn (set-window-buffer window target)
               (select-window window))
      (agent-shell-side--display target))))

(defun agent-shell-side--resolve-side ()
  "Return the side conversation this buffer is one end of.

Works from the side conversation and from its parent, so the same keys
serve both, and from either one's viewport buffer, which is where a
viewport user actually is."
  (let ((shell (agent-shell-side--this-shell)))
    (or (and (agent-shell-side-buffer-p shell) shell)
        (agent-shell-side--live-buffer
         (buffer-local-value 'agent-shell-side--side-buffer shell))
        (user-error "No side conversation linked to this buffer"))))

(defun agent-shell-side--close (side-buffer &optional parent-shown)
  "Interrupt, dispose of, and close SIDE-BUFFER, restoring its parent.

Disposal follows `agent-shell-side-on-dismiss'.

PARENT-SHOWN means the caller has already put the parent in front of the
user, so this must not show it again.  The handback sets it: under
viewport interaction the findings go into the parent's compose buffer,
and re-displaying the parent shell would re-enter the viewport with
nothing to append, which flips that compose buffer to read-only view
mode and strands the findings there unsendable."
  (let* ((parent (agent-shell-side--live-buffer
                  (buffer-local-value 'agent-shell-side--parent-buffer
                                      side-buffer)))
         (disposal (agent-shell-side--read-disposal))
         (finish (lambda ()
                   (when (buffer-live-p side-buffer)
                     (let ((window (get-buffer-window side-buffer)))
                       (kill-buffer side-buffer)
                       (when (and parent (not parent-shown) (window-live-p window))
                         (set-window-buffer window parent))))
                   (when (and parent (not parent-shown)
                              (not (get-buffer-window parent)))
                     (agent-shell-side--display parent)))))
    (with-current-buffer side-buffer
      (when (memq (agent-shell-status) '(busy blocked))
        (agent-shell-interrupt t)))
    (pcase disposal
      ('keep
       (agent-shell-side--record-link side-buffer)
       (funcall finish))
      (_
       (agent-shell-side--delete-session side-buffer finish)))))

;;;###autoload
(defun agent-shell-side-dismiss ()
  "Close the side conversation and return to the shell it was forked from.

Deletes or keeps the forked session according to
`agent-shell-side-on-dismiss'.  A kept session is recorded in
`agent-shell-side-links-file' and can be reopened with
`agent-shell-side-resume'.

Discards whatever was learned.  To carry it back to the parent
conversation instead, use `agent-shell-side-conclude'."
  (interactive)
  (agent-shell-side--close (agent-shell-side--resolve-side)))


;;; Handing findings back

(defun agent-shell-side--handback-text (summary)
  "Return SUMMARY framed for the parent conversation."
  (format "%s\n\n%s" agent-shell-side-handback-header (string-trim summary)))

(defun agent-shell-side--parent-busy-p (parent-buffer)
  "Return non-nil when PARENT-BUFFER is running a turn or waiting on one."
  (memq (agent-shell-status :shell-buffer parent-buffer) '(busy blocked)))

(defun agent-shell-side--stage-in-shell (parent-buffer text)
  "Put TEXT at PARENT-BUFFER's prompt, sent only if the user asked for that."
  (agent-shell-insert :text text
                      :submit agent-shell-side-handback-submit
                      :no-focus t
                      :shell-buffer parent-buffer))

(defun agent-shell-side--stage-when-idle (side-buffer parent-buffer text on-staged)
  "Put TEXT at PARENT-BUFFER's prompt once its turn ends, then call ON-STAGED.

A busy shell cannot take text at its prompt: `shell-maker' appends
output at the end of the buffer, so anything staged there would be
swallowed by the streaming response.  The prompt is printed, and busy
cleared, before `turn-complete' is emitted, so the first event that finds
the parent idle is the moment to insert.

SIDE-BUFFER stays open meanwhile, marked as having findings pending, so
the summary cannot be lost to a parent that is killed first.  That case
is reported and leaves the side conversation as it was.

A turn that fails rather than finishing needs one extra step.  `error'
is emitted before the shell clears its busy state, and nothing is
emitted afterwards, so a handler that only tests for an idle parent
would wait for an event that never comes.  The clearing happens in the
same call, right after the event is dispatched, so the test is deferred
to the next timer tick rather than run inline."
  (let ((token nil)
        (settled nil)
        (stage nil))
    (with-current-buffer side-buffer
      (setq agent-shell-side--handback-pending t)
      (force-mode-line-update))
    (setq stage
          (lambda ()
            (unless (or settled (agent-shell-side--parent-busy-p parent-buffer))
              (setq settled t)
              (agent-shell-side--unsubscribe parent-buffer token)
              (when (buffer-live-p side-buffer)
                (with-current-buffer side-buffer
                  (setq agent-shell-side--handback-pending nil)
                  (force-mode-line-update)))
              (agent-shell-side--stage-in-shell parent-buffer text)
              (funcall on-staged))))
    (setq token
          (agent-shell-subscribe-to
           :shell-buffer parent-buffer
           :on-event
           (lambda (event)
             (unless settled
               (pcase (map-elt event :event)
                 ('clean-up
                  (setq settled t)
                  (when (buffer-live-p side-buffer)
                    (with-current-buffer side-buffer
                      (setq agent-shell-side--handback-pending nil)
                      (force-mode-line-update)))
                  (message
                   "agent-shell-side: the parent closed before taking the findings; leaving the side conversation open"))
                 ('error (run-at-time 0 nil stage))
                 (_ (funcall stage)))))))
    (message "Side conversation: %s is mid-turn; findings will be staged at its prompt when the turn ends"
             (buffer-name parent-buffer))
    token))

(defun agent-shell-side--deliver-handback (side-buffer parent-buffer text on-delivered)
  "Get TEXT to PARENT-BUFFER for the user to send, then call ON-DELIVERED.

SIDE-BUFFER is the side conversation the findings came from; it is kept
open, and marked, while they wait for a busy parent.

Where it lands follows how the user works with `agent-shell'.  With
`agent-shell-prefer-viewport-interaction', it is appended to the
parent's viewport compose buffer, opened in edit mode so this works
while the parent is mid-turn; the compose buffer's own keys then send,
queue, or steer it.  Otherwise it goes to the parent's shell prompt: at
once when the parent is idle, or as soon as its turn ends when it is
not.  Nothing here sends on the user's behalf unless
`agent-shell-side-handback-submit' asks for it.

Never the minibuffer: findings are usually long, and a minibuffer is no
place to review them."
  (cond
   ((agent-shell-side-compat-prefer-viewport-p)
    (agent-shell-side-compat-compose-in-viewport parent-buffer text)
    (funcall on-delivered t))
   ((agent-shell-side--parent-busy-p parent-buffer)
    (agent-shell-side--stage-when-idle
     side-buffer parent-buffer text (lambda () (funcall on-delivered nil))))
   (t
    (agent-shell-side--stage-in-shell parent-buffer text)
    (funcall on-delivered nil))))

(defun agent-shell-side--finish-handback (side-buffer parent-buffer summary)
  "Put SUMMARY into PARENT-BUFFER and close SIDE-BUFFER once it is there.

An empty summary or a parent that has since gone away leaves the side
conversation open: closing it would throw the conversation away and hand
the parent nothing."
  (let ((summary (string-trim (or summary ""))))
    (cond
     ((string-empty-p summary)
      (message
       "agent-shell-side: no summary came back; leaving the side conversation open"))
     ((not (buffer-live-p parent-buffer))
      (message
       "agent-shell-side: the parent is gone; leaving the side conversation open"))
     (t
      (agent-shell-side--deliver-handback
       side-buffer parent-buffer (agent-shell-side--handback-text summary)
       (lambda (parent-shown)
         (when (buffer-live-p side-buffer)
           (agent-shell-side--close side-buffer parent-shown))))))))

(defun agent-shell-side--collect-summary (side-buffer parent-buffer)
  "Gather SIDE-BUFFER's next answer and hand it to PARENT-BUFFER.

Accumulates `agent-message-chunk' text until the turn ends.  Subscribing
before the summary is sent is what makes this complete: a chunk that
arrives first would otherwise be lost from the summary."
  (let ((chunks nil)
        (token nil)
        (settled nil))
    (setq token
          (agent-shell-subscribe-to
           :shell-buffer side-buffer
           :on-event
           (lambda (event)
             (pcase (map-elt event :event)
               ('agent-message-chunk
                (when-let* ((chunk (map-nested-elt event '(:data :text-chunk))))
                  (push chunk chunks)))
               ((or 'turn-complete 'error)
                (unless settled
                  (setq settled t)
                  (agent-shell-side--unsubscribe side-buffer token)
                  (agent-shell-side--finish-handback
                   side-buffer parent-buffer
                   (string-join (nreverse chunks)))))
               (_ nil)))))
    (run-at-time
     agent-shell-side-handback-timeout nil
     (lambda ()
       (unless settled
         (setq settled t)
         (agent-shell-side--unsubscribe side-buffer token)
         (message
          "agent-shell-side: no summary after %ss; leaving the side conversation open"
          agent-shell-side-handback-timeout))))
    token))

;;;###autoload
(defun agent-shell-side-conclude ()
  "Summarise the side conversation into the parent, then close it.

Asks the side conversation for a summary addressed to the parent, waits
for it, puts it at the parent's prompt, and closes the side conversation
the way `agent-shell-side-dismiss' would.

The summary is left for review rather than sent, unless
`agent-shell-side-handback-submit' says otherwise."
  (interactive)
  (let* ((side-buffer (agent-shell-side--resolve-side))
         (parent-buffer (agent-shell-side--live-buffer
                         (buffer-local-value 'agent-shell-side--parent-buffer
                                             side-buffer))))
    (unless parent-buffer
      (user-error "This side conversation has no parent left to report to"))
    (when (memq (agent-shell-status :shell-buffer side-buffer) '(busy blocked))
      (user-error "The side conversation is still working; wait for it to finish"))
    (when (buffer-local-value 'agent-shell-side--handback-pending side-buffer)
      (user-error "Findings are already waiting for %s to finish its turn"
                  (buffer-name parent-buffer)))
    (agent-shell-side--collect-summary side-buffer parent-buffer)
    (agent-shell-insert :text agent-shell-side-handback-prompt
                        :submit t
                        :no-focus t
                        :shell-buffer side-buffer)
    (message "Side conversation: summarising for %s..." (buffer-name parent-buffer))))

;;;###autoload
(defun agent-shell-side-resume ()
  "Reopen a side conversation that was kept when it was closed.

Offers the side conversations recorded for this shell's session, or all
of them when this buffer has no session of its own.

The reopened buffer is a side conversation again, with the same keys and
lighter, but stands on its own: nothing records which buffer its parent
was, so there is nothing to toggle to or hand findings back to.  Closing
it with `keep' records it afresh.  The record it came from is consumed,
so a session is never offered twice, nor after it has been deleted."
  (interactive)
  (let* ((shell-buffer (agent-shell-shell-buffer :no-error t :no-create t))
         (session-id (and shell-buffer
                          (agent-shell-side--session-id shell-buffer)))
         (records (if session-id
                      (agent-shell-side-links-for-parent session-id)
                    (agent-shell-side-links-read))))
    (unless records
      (user-error "No kept side conversations%s"
                  (if session-id " for this conversation" "")))
    (let* ((choices (mapcar (lambda (record)
                              (cons (agent-shell-side--record-label record)
                                    record))
                            (reverse records)))
           (choice (completing-read "Resume side conversation: " choices nil t))
           (record (cdr (assoc choice choices)))
           (config (agent-shell-side--config-for-identifier
                    (map-elt record :agent))))
      (unless config
        (user-error "No known agent config for %s" (map-elt record :agent)))
      (when (agent-shell-side-links-stale-p record)
        (message
         "This side conversation started under older instructions; both texts now apply"))
      (let* ((default-directory (or (map-elt record :cwd) default-directory))
             (side-buffer (agent-shell-start
                           :config (agent-shell-side--config config)
                           :session-id (map-elt record :side-session-id))))
        (when (buffer-live-p side-buffer)
          (agent-shell-side--mark-side side-buffer)
          (agent-shell-side--forget-record-when-loaded
           side-buffer (map-elt record :side-session-id)))
        side-buffer))))

(defun agent-shell-side--forget-record-when-loaded (side-buffer session-id)
  "Drop SESSION-ID's link record once SIDE-BUFFER has really loaded it.

Dropping it when the shell is started would be too early: `session/load'
is still in flight, and an agent that rejects it would leave no record of
the session id to try again with.

`session-selected' is too early for the same reason -- it is emitted
before the load request is even sent.  `session-restored' is the one that
means the transcript came back and the shell has settled.

A rejected load is not reported as an error to watch for: `agent-shell'
answers it by saying so and quietly starting a different session, which
can itself emit `session-restored'.  So the id is checked rather than the
event trusted, and a restore of anything else leaves the record alone."
  (let ((token nil)
        (settled nil))
    (setq token
          (agent-shell-subscribe-to
           :shell-buffer side-buffer
           :event 'session-restored
           :on-event
           (lambda (_event)
             (unless settled
               (setq settled t)
               (agent-shell-side--unsubscribe side-buffer token)
               (if (equal (agent-shell-side--session-id side-buffer) session-id)
                   (agent-shell-side-links-remove session-id)
                 (message
                  "agent-shell-side: %s did not come back; keeping its record"
                  session-id))))))
    token))

(defun agent-shell-side--record-label (record)
  "Return a completion label for link RECORD."
  (format "%s  %s  %s%s"
          (map-elt record :created)
          (or (map-elt record :agent) "?")
          (abbreviate-file-name (or (map-elt record :cwd) ""))
          (if (agent-shell-side-links-stale-p record) "  (older instructions)" "")))

;;; Listing open side conversations

(defun agent-shell-side--format-age (seconds)
  "Return SECONDS as a short age in its largest whole unit."
  (let ((seconds (floor seconds)))
    (cond ((< seconds 60) (format "%ds" seconds))
          ((< seconds 3600) (format "%dm" (/ seconds 60)))
          ((< seconds 86400) (format "%dh" (/ seconds 3600)))
          (t (format "%dd" (/ seconds 86400))))))

(defun agent-shell-side--parent-session-id (side-buffer)
  "Return the session id SIDE-BUFFER was forked from, or nil.

Nil once the parent buffer is gone, which is why a scoped listing cannot
reach orphans and the unscoped one has to."
  (when-let* ((parent (agent-shell-side--live-buffer
                       (buffer-local-value 'agent-shell-side--parent-buffer
                                           side-buffer))))
    (agent-shell-side--session-id parent)))

(defun agent-shell-side--current-session-id ()
  "Return the session a listing from this buffer should be scoped to, or nil.

In a shell, its own session.  In a side conversation, the session it was
forked from, so the listing shows its siblings rather than only itself.
Nil anywhere else, which leaves the listing unscoped."
  (when-let* ((shell (agent-shell-shell-buffer :no-error t :no-create t)))
    (if (agent-shell-side-buffer-p shell)
        (agent-shell-side--parent-session-id shell)
      (agent-shell-side--session-id shell))))

(defun agent-shell-side--list-buffers (&optional parent-session-id)
  "Return the live side conversations, oldest first.

With PARENT-SESSION-ID, only the ones forked from that session.

Oldest first because the one open longest is the one most likely to have
been forgotten."
  (let ((buffers (seq-filter #'agent-shell-side-buffer-p (buffer-list))))
    (when parent-session-id
      (setq buffers
            (seq-filter (lambda (buffer)
                          (equal (agent-shell-side--parent-session-id buffer)
                                 parent-session-id))
                        buffers)))
    (sort buffers
          (lambda (a b)
            (time-less-p
             (or (buffer-local-value 'agent-shell-side--created-at a) 0)
             (or (buffer-local-value 'agent-shell-side--created-at b) 0))))))

(defun agent-shell-side--list-label (buffer)
  "Return a one-line description of side conversation BUFFER."
  (let* ((parent (agent-shell-side--live-buffer
                  (buffer-local-value 'agent-shell-side--parent-buffer buffer)))
         (created (buffer-local-value 'agent-shell-side--created-at buffer))
         (status (agent-shell-side--status-phrase
                  (buffer-local-value 'agent-shell-side--parent-status buffer))))
    (format "%s  from %s%s%s"
            (buffer-name buffer)
            (if parent (buffer-name parent) "a shell that is gone")
            (if status (format " (%s)" status) "")
            (if created
                (format "  %s ago"
                        (agent-shell-side--format-age
                         (float-time (time-subtract (current-time) created))))
              ""))))

(defun agent-shell-side--list-candidates (&optional parent-session-id)
  "Return the open side conversations as (LABEL . BUFFER) pairs.

With PARENT-SESSION-ID, only the ones forked from that session.

Labels are made unique before they are offered.  `completing-read'
answers with a string, so two side conversations sharing a buffer name
and a parent would otherwise collapse into one reachable candidate."
  (let ((seen (make-hash-table :test #'equal)))
    (mapcar (lambda (buffer)
              (let* ((label (agent-shell-side--list-label buffer))
                     (count (puthash label
                                     (1+ (gethash label seen 0))
                                     seen)))
                (cons (if (> count 1)
                          (format "%s  <%d>" label count)
                        label)
                      buffer)))
            (agent-shell-side--list-buffers parent-session-id))))

;;;###autoload
(defun agent-shell-side-list (&optional everywhere)
  "Switch to one of the side conversations that are open.

Called from a shell, offers the ones forked from that conversation.
Called from a side conversation, offers its siblings.  Anywhere else
there is no session to scope to, so it offers all of them.  With a prefix
argument, EVERYWHERE, it offers all of them regardless.

Both scopes are worth having.  Inside a conversation the question is
usually \"where did I put that question I asked\", and another project's
side conversations are noise.  Across conversations the question is what
is still open at all: a side conversation lives until it is closed, so
they collect quietly.

The unscoped listing is also the only one that reaches a side
conversation whose parent has been killed.  Nothing records which session
it came from once the parent buffer is gone, and those are the easiest
ones to forget.

Codex discards its own on navigating elsewhere.  That does not port:
Emacs users switch buffers constantly and it would throw away work
mid-thought.  So this switches, and closes nothing for you."
  (interactive "P")
  (let* ((session (unless everywhere (agent-shell-side--current-session-id)))
         (candidates (agent-shell-side--list-candidates session)))
    (unless candidates
      (user-error "%s" (if session
                           "No side conversations are open for this conversation"
                         "No side conversations are open")))
    (let* ((choice (completing-read (if session
                                        "Side conversation: "
                                      "Side conversation (all): ")
                                    candidates nil t))
           (buffer (cdr (assoc choice candidates))))
      (unless (buffer-live-p buffer)
        (user-error "That side conversation is gone"))
      (agent-shell-side--display buffer))))

;;;###autoload
(defun agent-shell-side-describe ()
  "Echo what this side conversation is, and how to leave it."
  (interactive)
  (cond
   ((agent-shell-side-buffer-p)
    (message "Side conversation of %s%s.  %s switches, %s closes"
             (if-let* ((parent (agent-shell-side--live-buffer
                                agent-shell-side--parent-buffer)))
                 (buffer-name parent)
               "a closed shell")
             (if-let* ((label (agent-shell-side--status-label
                               agent-shell-side--parent-status)))
                 (concat " (" label ")")
               "")
             (agent-shell-side--key-for #'agent-shell-side-toggle)
             (agent-shell-side--key-for #'agent-shell-side-dismiss)))
   ((agent-shell-side--live-buffer agent-shell-side--side-buffer)
    (message "Side conversation open in %s.  %s switches to it"
             (buffer-name agent-shell-side--side-buffer)
             (agent-shell-side--key-for #'agent-shell-side-toggle)))
   (t (message "No side conversation here"))))

(provide 'agent-shell-side)

;;; agent-shell-side.el ends here
