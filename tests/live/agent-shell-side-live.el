;;; agent-shell-side-live.el --- Live probes against a real agent -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Copyright (C) 2026 Bill and contributors

;;; Commentary:

;; Drives `agent-shell-side' against a real claude-agent-acp process.
;;
;; Run with `make live-check', never `make check'.  This spawns an agent,
;; spends real API tokens, and waits on model output that is not
;; deterministic, so it does not belong in a suite meant to run on every
;; edit.  Run it when the adapter or ACP version changes, and before
;; tagging a release.
;;
;; What only a live run can answer:
;;
;; - whether a fork really inherits the parent's history
;; - whether the boundary text still cancels the parent's task and its
;;   standing conventions, which is a wording-sensitive property that
;;   silently regresses when either instruction text is edited
;; - whether the handback survives real streaming and a parent that goes
;;   away mid-summary
;; - whether a kept session, resumed later, still carries the side policy
;; - what `session/fork' does while the parent's turn is in flight
;;
;; The unit suite covers everything that does not need a model.  One
;; branch stays there on purpose: `agent-shell-side--finish-handback'
;; refusing an empty summary.  That guard is about content, not timing,
;; and a live model cannot be made to reliably say nothing, so a live
;; version would only pretend to test it.
;;
;; Permissions are answered by a read-only auto-approver.  The harness
;; never approves a mutation: an unattended run must not be able to let
;; an agent edit the checkout it is running in.  A probe that needs more
;; than reading is reported as blocked rather than waited on.

;;; Code:

(require 'agent-shell)
(require 'agent-shell-anthropic)
(require 'agent-shell-side)
(require 'cl-lib)
(require 'map)
(require 'seq)
(require 'shell-maker)
(require 'subr-x)

(defvar agent-shell-side-live-timeout 120
  "Seconds to wait for one agent turn before giving up on it.")

(defvar agent-shell-side-live-startup-timeout 90
  "Seconds to wait for a shell to reach its first prompt.")

(defconst agent-shell-side-live-token "ZEBRA-4417"
  "Fact planted in the parent conversation and asked for in the fork.

Only the parent's history can supply it, so a fork that answers with it
inherited that history.  Shaped so it cannot be guessed and cannot be
confused with ordinary prose.")

(defconst agent-shell-side-live-marker "TASK-MARKER"
  "Standing convention planted in the parent conversation.

A fork that still appends it has read a cancelled formatting rule as a
persistent convention.  This is the regression that
`agent-shell-side-boundary-version' 2 exists to prevent.")

(defvar agent-shell-side-live--results nil
  "Probe outcomes, newest first, as (STATUS NAME DETAIL).

STATUS is `pass', `fail', or `info'.")


;;; Reporting

(defun agent-shell-side-live--record (status name detail)
  "Record DETAIL under NAME with STATUS, and echo it as the run goes."
  (push (list status name detail) agent-shell-side-live--results)
  (princ (format "%-5s %s\n      %s\n"
                 (upcase (symbol-name status)) name detail))
  status)

(defun agent-shell-side-live--check (name ok detail)
  "Record NAME as passed when OK, else as failed, explaining with DETAIL."
  (agent-shell-side-live--record (if ok 'pass 'fail) name detail))

(defun agent-shell-side-live--observe (name detail)
  "Record DETAIL under NAME as an observation, neither pass nor fail.

For findings a human has to read, where asserting would be pretending to
know the answer."
  (agent-shell-side-live--record 'info name detail))

(defun agent-shell-side-live--excerpt (text &optional limit)
  "Return TEXT on one line, cut to LIMIT characters, for the report."
  (let* ((text (string-trim (or text "")))
         (text (replace-regexp-in-string "[ \t\n]+" " " text))
         (limit (or limit 160)))
    (cond ((string-empty-p text) "(nothing)")
          ((<= (length text) limit) text)
          (t (concat (substring text 0 limit) "...")))))

(defun agent-shell-side-live--report ()
  "Print the run summary.  Return non-nil when every probe passed."
  (let* ((results (reverse agent-shell-side-live--results))
         (failed (seq-filter (lambda (r) (eq (car r) 'fail)) results))
         (passed (seq-filter (lambda (r) (eq (car r) 'pass)) results)))
    (princ (format "\n%s\n%d passed, %d failed, %d observations\n"
                   (make-string 60 ?-)
                   (length passed) (length failed)
                   (length (seq-filter (lambda (r) (eq (car r) 'info)) results))))
    (dolist (result failed)
      (princ (format "FAILED %s: %s\n" (nth 1 result) (nth 2 result))))
    (null failed)))


;;; Waiting

(defun agent-shell-side-live--wait (predicate timeout)
  "Run the event loop until PREDICATE holds or TIMEOUT seconds pass.

Returns non-nil when PREDICATE held.  Waits on the event loop rather than
sleeping a fixed interval, so a probe takes as long as its turn takes and
no longer."
  (let ((deadline (time-add (current-time) (seconds-to-time timeout))))
    (catch 'done
      (while (time-less-p (current-time) deadline)
        (when (funcall predicate)
          (throw 'done t))
        (accept-process-output nil 0.05))
      (funcall predicate))))

(defun agent-shell-side-live--unsubscribe (shell-buffer token)
  "Drop subscription TOKEN from SHELL-BUFFER."
  (when (and token (buffer-live-p shell-buffer))
    (with-current-buffer shell-buffer
      (ignore-errors (agent-shell-unsubscribe :subscription token)))))

(defun agent-shell-side-live--collect (shell-buffer &optional timeout)
  "Return the text of SHELL-BUFFER's next agent turn.

Subscribes before returning to the caller, so a turn that is already
streaming is still captured whole."
  (let* ((chunks nil)
         (done nil)
         (token nil))
    (setq token
          (agent-shell-subscribe-to
           :shell-buffer shell-buffer
           :on-event
           (lambda (event)
             (pcase (map-elt event :event)
               ('agent-message-chunk
                (when-let* ((chunk (map-nested-elt event '(:data :text-chunk))))
                  (push chunk chunks)))
               ((or 'turn-complete 'error)
                (setq done t))))))
    (unwind-protect
        (progn
          (agent-shell-side-live--wait
           (lambda () done) (or timeout agent-shell-side-live-timeout))
          (string-join (nreverse chunks)))
      (agent-shell-side-live--unsubscribe shell-buffer token))))

(defun agent-shell-side-live--ask (shell-buffer text &optional timeout)
  "Send TEXT to SHELL-BUFFER and return the answer."
  (let* ((chunks nil)
         (done nil)
         (token nil))
    (setq token
          (agent-shell-subscribe-to
           :shell-buffer shell-buffer
           :on-event
           (lambda (event)
             (pcase (map-elt event :event)
               ('agent-message-chunk
                (when-let* ((chunk (map-nested-elt event '(:data :text-chunk))))
                  (push chunk chunks)))
               ((or 'turn-complete 'error)
                (setq done t))))))
    (unwind-protect
        (progn
          (agent-shell-insert :text text :submit t :no-focus t
                              :shell-buffer shell-buffer)
          (agent-shell-side-live--wait
           (lambda () done) (or timeout agent-shell-side-live-timeout))
          (string-join (nreverse chunks)))
      (agent-shell-side-live--unsubscribe shell-buffer token))))

(defun agent-shell-side-live--send (shell-buffer text)
  "Send TEXT to SHELL-BUFFER without waiting for the turn to finish."
  (agent-shell-insert :text text :submit t :no-focus t
                      :shell-buffer shell-buffer))


;;; Shells

(defun agent-shell-side-live--allow-reads (permission)
  "Approve PERMISSION when it only reads, decline to handle it otherwise.

Returning nil hands the request back to the interactive dialog, which in
batch means nobody answers and the probe times out.  That is the intended
outcome: an unattended harness must never approve a change to the
checkout it is running in."
  (when-let* (((equal (map-elt (map-elt permission :tool-call) :kind) "read"))
              (choice (seq-find (lambda (option)
                                  (equal (map-elt option :kind) "allow_once"))
                                (map-elt permission :options))))
    (funcall (map-elt permission :respond) (map-elt choice :option-id))
    t))

(defun agent-shell-side-live--wait-ready (shell-buffer)
  "Wait for SHELL-BUFFER to reach its first prompt.  Return non-nil on success."
  (let ((ready nil)
        (token nil))
    (setq token
          (agent-shell-subscribe-to
           :shell-buffer shell-buffer
           :event 'prompt-ready
           :on-event (lambda (_event) (setq ready t))))
    (unwind-protect
        (agent-shell-side-live--wait
         (lambda () ready) agent-shell-side-live-startup-timeout)
      (agent-shell-side-live--unsubscribe shell-buffer token))))

(defun agent-shell-side-live--start-parent ()
  "Start a real Claude shell and return it once it is ready to prompt."
  (let ((buffer (agent-shell--start
                 :config (agent-shell-anthropic-make-claude-code-config)
                 :no-focus t
                 :new-session t
                 :session-strategy 'new)))
    (unless (agent-shell-side-live--wait-ready buffer)
      (error "Shell did not become ready within %ss"
             agent-shell-side-live-startup-timeout))
    buffer))

(defun agent-shell-side-live--fork (parent message)
  "Fork PARENT with MESSAGE and return the side buffer once it has a session.

Signals when the fork produced no working session.  A fork can fail while
still handing back a buffer: `session/fork' answers with an error, no
session is ever selected, and the shell sits there accepting input that
goes nowhere.  Asserting past that point reports the wrong thing, and can
report a pass, since \"the side conversation stayed open\" is true of a
dead one too."
  (let ((side (with-current-buffer parent (agent-shell-side message))))
    (unless (agent-shell-side-live--wait-ready side)
      (agent-shell-side-live--kill side)
      (error "The fork never reached a prompt, so its session did not start"))
    side))

(defun agent-shell-side-live--start-conversation (parent)
  "Give PARENT a completed turn, so it can be forked.

A session with no turns cannot be forked: claude-agent-acp answers
`session/fork' with -32002 Resource not found.  Codex refuses the same
case up front rather than forking into nothing."
  (agent-shell-side-live--ask
   parent
   (format "Remember this token for later: %s. Reply with just OK."
           agent-shell-side-live-token)))

(defun agent-shell-side-live--kill (&rest buffers)
  "Kill BUFFERS, shutting down the agents behind them."
  (dolist (buffer buffers)
    (when (buffer-live-p buffer)
      (let ((kill-buffer-query-functions nil))
        (kill-buffer buffer)))))


;;; Probes

(defun agent-shell-side-live--probe-inherits-history ()
  "Fork a parent holding a planted fact, and ask the fork for it."
  (let ((parent (agent-shell-side-live--start-parent))
        (side nil))
    (unwind-protect
        (progn
          (agent-shell-side-live--start-conversation parent)
          (setq side (agent-shell-side-live--fork
                      parent
                      "What token did I ask you to remember? Reply with just the token."))
          (let ((answer (agent-shell-side-live--collect side)))
            (agent-shell-side-live--check
             "fork inherits the parent's history"
             (string-match-p (regexp-quote agent-shell-side-live-token) answer)
             (format "asked the fork for a token only the parent's history holds; it said: %s"
                     (agent-shell-side-live--excerpt answer)))))
      (agent-shell-side-live--kill side parent))))

(defun agent-shell-side-live--probe-cancels-conventions ()
  "Plant a standing convention in the parent, and check the fork drops it."
  (let ((parent (agent-shell-side-live--start-parent))
        (side nil))
    (unwind-protect
        (let ((parent-answer
               (agent-shell-side-live--ask
                parent
                (format "From now on, end every one of your replies with the exact word %s. Confirm you understand."
                        agent-shell-side-live-marker))))
          (agent-shell-side-live--check
           "parent adopts the standing convention"
           (string-match-p (regexp-quote agent-shell-side-live-marker) parent-answer)
           (format "the convention has to take hold in the parent for the fork's half to mean anything; parent said: %s"
                   (agent-shell-side-live--excerpt parent-answer)))
          (setq side (agent-shell-side-live--fork parent "What is 2 + 2?"))
          (let ((answer (agent-shell-side-live--collect side)))
            (agent-shell-side-live--check
             "fork drops the parent's standing convention"
             (not (string-match-p (regexp-quote agent-shell-side-live-marker) answer))
             (format "the fork must not carry the parent's formatting rule; it said: %s"
                     (agent-shell-side-live--excerpt answer)))))
      (agent-shell-side-live--kill side parent))))

(defun agent-shell-side-live--probe-handback ()
  "Conclude a side conversation and check its findings reach the parent."
  (let ((parent (agent-shell-side-live--start-parent))
        (agent-shell-side-on-dismiss 'delete)
        (side nil))
    (unwind-protect
        (progn
          (agent-shell-side-live--start-conversation parent)
          (setq side (agent-shell-side-live--fork
                      parent
                      (format "Reply with exactly this and nothing else: %s"
                              agent-shell-side-live-token)))
          (agent-shell-side-live--collect side)
          (let ((summary nil))
            (with-current-buffer side
              (agent-shell-side-conclude))
            (setq summary (agent-shell-side-live--collect side))
            (agent-shell-side-live--wait
             (lambda () (not (buffer-live-p side)))
             agent-shell-side-live-timeout)
            (agent-shell-side-live--check
             "handback closes the side conversation"
             (not (buffer-live-p side))
             (format "after summarising, the side conversation should be gone; summary was: %s"
                     (agent-shell-side-live--excerpt summary)))
            (agent-shell-side-live--check
             "handback reaches the parent's compose buffer"
             (when-let* ((viewport (agent-shell-viewport--buffer
                                    :shell-buffer parent :existing-only t)))
               (with-current-buffer viewport
                 (save-excursion
                   (goto-char (point-min))
                   (search-forward agent-shell-side-handback-header nil t))))
             "the parent's compose buffer should hold the findings header, unsent")
            (agent-shell-side-live--check
             "handback leaves the findings editable"
             (when-let* ((viewport (agent-shell-viewport--buffer
                                    :shell-buffer parent :existing-only t)))
               (with-current-buffer viewport
                 (and (derived-mode-p 'agent-shell-viewport-edit-mode)
                      (not buffer-read-only))))
             "the findings must arrive as a draft the user can edit and send")))
      (agent-shell-side-live--kill side parent))))

(defun agent-shell-side-live--probe-handback-loses-its-parent ()
  "Kill the parent mid-summary, and check the side conversation survives.

The refusal is guarded in `agent-shell-side--finish-handback', but only
real streaming puts a kill in the window between asking for the summary
and the summary arriving."
  (let ((parent (agent-shell-side-live--start-parent))
        (agent-shell-side-on-dismiss 'delete)
        (side nil))
    (unwind-protect
        (progn
          (agent-shell-side-live--start-conversation parent)
          (setq side (agent-shell-side-live--fork parent "Reply with just OK."))
          (agent-shell-side-live--collect side)
          (with-current-buffer side
            (agent-shell-side-conclude))
          (agent-shell-side-live--kill parent)
          (agent-shell-side-live--collect side)
          (agent-shell-side-live--check
           "a handback with no parent left keeps the side conversation open"
           (buffer-live-p side)
           "closing here would discard the conversation and hand nobody the findings"))
      (agent-shell-side-live--kill side parent))))

(defun agent-shell-side-live--probe-resume ()
  "Keep a side conversation, reopen it, and check it kept its history."
  (let ((parent (agent-shell-side-live--start-parent))
        (agent-shell-side-on-dismiss 'keep)
        (agent-shell-side-links-file
         (make-temp-file "agent-shell-side-live-links" nil ".eld"))
        (side nil)
        (resumed nil))
    (unwind-protect
        (progn
          (agent-shell-side-live--start-conversation parent)
          (setq side (agent-shell-side-live--fork parent "Reply with just OK."))
          (agent-shell-side-live--collect side)
          (with-current-buffer side
            (agent-shell-side-dismiss))
          (agent-shell-side-live--wait
           (lambda () (not (buffer-live-p side))) agent-shell-side-live-timeout)
          (let ((records (agent-shell-side-links-read)))
            (agent-shell-side-live--check
             "a kept side conversation is recorded"
             (= (length records) 1)
             (format "expected one link record, found %d" (length records))))
          (agent-shell-side-live--kill parent)
          (setq resumed
                (with-temp-buffer
                  (cl-letf (((symbol-function 'completing-read)
                             (lambda (_prompt collection &rest _)
                               (car (car collection)))))
                    (agent-shell-side-resume))))
          (if (not (agent-shell-side-live--wait-ready resumed))
              (agent-shell-side-live--check
               "a resumed side conversation reaches its prompt" nil
               "the resumed shell never became ready")
            (let ((answer (agent-shell-side-live--ask
                           resumed
                           "What token were you asked to remember? Reply with just the token.")))
              (agent-shell-side-live--check
               "a resumed side conversation kept its history"
               (string-match-p (regexp-quote agent-shell-side-live-token) answer)
               (format "the resumed fork should still hold the parent's planted token; it said: %s"
                       (agent-shell-side-live--excerpt answer))))))
      (agent-shell-side-live--kill side resumed parent)
      (when (file-exists-p agent-shell-side-links-file)
        (delete-file agent-shell-side-links-file)))))

(defun agent-shell-side-live--probe-refuses-a-turnless-conversation ()
  "Refuse to fork a conversation that has said nothing, but not a resumed one.

claude-agent-acp answers `session/fork' with -32002 Resource not found
until the session has a transcript.  A resumed session has one even
though its buffer looks empty, so the refusal has to tell those apart or
it blocks a fork that works."
  (let ((parent (agent-shell-side-live--start-parent))
        (resumed nil))
    (unwind-protect
        (progn
          (agent-shell-side-live--check
           "a conversation that has said nothing is refused"
           (condition-case nil
               (progn (with-current-buffer parent (agent-shell-side "hello")) nil)
             (user-error t))
           "refused up front, rather than leaving a shell whose session never starts")
          (agent-shell-side-live--start-conversation parent)
          (let ((session (agent-shell-side--session-id parent)))
            (agent-shell-side-live--kill parent)
            (setq parent nil)
            (setq resumed (agent-shell-start
                           :config (agent-shell-anthropic-make-claude-code-config)
                           :session-id session))
            (agent-shell-side-live--wait-ready resumed))
          (agent-shell-side-live--observe
           "a resumed conversation reads as empty"
           (format "its buffer holds %d exchanges, so an empty buffer cannot mean an unforkable session"
                   (with-current-buffer resumed (length (shell-maker-history)))))
          (let ((side (agent-shell-side-live--fork
                       resumed
                       "What token were you asked to remember? Reply with just the token.")))
            (unwind-protect
                (let ((answer (agent-shell-side-live--collect side)))
                  (agent-shell-side-live--check
                   "a resumed conversation can still be forked"
                   (string-match-p (regexp-quote agent-shell-side-live-token) answer)
                   (format "the fork should inherit the resumed history; it said: %s"
                           (agent-shell-side-live--excerpt answer))))
              (agent-shell-side-live--kill side))))
      (agent-shell-side-live--kill resumed parent))))

(defun agent-shell-side-live--probe-mid-turn-fork ()
  "Fork while the parent's turn is still running.

This is the case `/side' exists for and the one never exercised.  Codex
forks the persisted transcript and marks a mid-turn cut as an interrupted
turn, so the fork reads it as abandoned rather than pending.  Whether
claude-agent-acp gives us the same is what this probe answers.

The parent's task is slow but read-only, so the harness never has to
approve a change to run it."
  (let ((parent (agent-shell-side-live--start-parent))
        (side nil))
    (unwind-protect
        (progn
          (agent-shell-side-live--start-conversation parent)
          (agent-shell-side-live--send
           parent
           "Read every .el file in this directory, one at a time, and describe each one in a sentence. Take them in alphabetical order.")
          (if (not (agent-shell-side-live--wait
                    (lambda () (memq (agent-shell-status :shell-buffer parent)
                                     '(busy blocked)))
                    30))
              (agent-shell-side-live--check
               "the parent is busy before the mid-turn fork" nil
               "the parent never started its slow task, so nothing was forked mid-turn")
            (let ((forked
                   (condition-case err
                       (agent-shell-side-live--fork
                        parent
                        "What token were you asked to remember? Reply with just the token.")
                     (error
                      (agent-shell-side-live--check
                       "forking mid-turn is allowed" nil
                       (format "the fork call failed: %s" (error-message-string err)))
                      nil))))
              (setq side forked)
              (when forked
                (agent-shell-side-live--check
                 "forking mid-turn is allowed" t
                 "session/fork returned a shell while the parent's turn was still running")
                (let ((answer (agent-shell-side-live--collect side)))
                  (agent-shell-side-live--check
                   "a mid-turn fork still inherits history"
                   (string-match-p (regexp-quote agent-shell-side-live-token) answer)
                   (format "the fork should still hold the planted token; it said: %s"
                           (agent-shell-side-live--excerpt answer))))
                (let ((answer (agent-shell-side-live--ask
                               side
                               "Are you currently in the middle of any task? Answer in one line.")))
                  (agent-shell-side-live--observe
                   "how the mid-turn fork reads the parent's unfinished turn"
                   (format "read this before deciding whether the boundary needs an interrupted-turn clause; the fork said: %s"
                           (agent-shell-side-live--excerpt answer 300))))))))
      (agent-shell-side-live--kill side parent))))


;;; Runner

(defconst agent-shell-side-live-probes
  '(agent-shell-side-live--probe-inherits-history
    agent-shell-side-live--probe-cancels-conventions
    agent-shell-side-live--probe-handback
    agent-shell-side-live--probe-handback-loses-its-parent
    agent-shell-side-live--probe-resume
    agent-shell-side-live--probe-refuses-a-turnless-conversation
    agent-shell-side-live--probe-mid-turn-fork)
  "Probes run by `agent-shell-side-live-run', in order.

Each starts and kills its own shells, so one failure cannot leave the
next probe talking to a poisoned session.")

(defun agent-shell-side-live-run ()
  "Run every live probe and print a report.

Returns non-nil when all of them passed."
  (let ((agent-shell-side-live--results nil)
        (agent-shell-permission-responder-function
         #'agent-shell-side-live--allow-reads)
        (agent-shell-side-report-parent-status nil))
    (unless (executable-find "claude-agent-acp")
      (error "claude-agent-acp is not on PATH; nothing to probe"))
    (dolist (probe agent-shell-side-live-probes)
      (princ (format "\n== %s\n" probe))
      (condition-case err
          (funcall probe)
        (error
         (agent-shell-side-live--record
          'fail (symbol-name probe)
          (format "the probe itself broke: %s" (error-message-string err))))))
    (agent-shell-side-live--report)))

(defun agent-shell-side-live-batch ()
  "Run the live probes and exit non-zero when any failed."
  (kill-emacs (if (agent-shell-side-live-run) 0 1)))

(provide 'agent-shell-side-live)

;;; agent-shell-side-live.el ends here
