;;; agent-shell-side-tests.el --- Tests for agent-shell-side -*- lexical-binding: t; -*-

;;; Commentary:

;; Unit tests for the pure parts of agent-shell-side: prompt decoration,
;; session metadata merging, config derivation, parent-status labels, and
;; the link store.  Nothing here talks to a live agent.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'map)
(require 'agent-shell-side)
(require 'agent-shell-side-links)

;;; Content blocks and boundary injection

(ert-deftest agent-shell-side-test-content-block ()
  "A text block carries the ACP text shape."
  (let ((block (agent-shell-side--content-block "hello")))
    (should (equal (map-elt block 'type) "text"))
    (should (equal (map-elt block 'text) "hello"))))

(ert-deftest agent-shell-side-test-prepend-boundary-adds-block-first ()
  "The boundary block lands ahead of the user's own blocks."
  (let* ((request `((:method . "session/prompt")
                    (:params . ((sessionId . "s1")
                                (prompt . [((type . "text") (text . "why?"))])))))
         (decorated (agent-shell-side--prepend-boundary request))
         (prompt (map-nested-elt decorated '(:params prompt))))
    (should (equal (length prompt) 2))
    (should (equal (map-elt (aref prompt 0) 'text)
                   agent-shell-side-boundary-prompt))
    (should (equal (map-elt (aref prompt 1) 'text) "why?"))))

(ert-deftest agent-shell-side-test-prepend-boundary-keeps-other-params ()
  "Decoration leaves the rest of the request alone."
  (let* ((request `((:method . "session/prompt")
                    (:params . ((sessionId . "s1")
                                (prompt . [((type . "text") (text . "why?"))])))))
         (decorated (agent-shell-side--prepend-boundary request)))
    (should (equal (map-elt decorated :method) "session/prompt"))
    (should (equal (map-nested-elt decorated '(:params sessionId)) "s1"))))

(ert-deftest agent-shell-side-test-prepend-boundary-does-not-mutate-input ()
  "The caller's request object survives decoration unchanged."
  (let* ((prompt (vector '((type . "text") (text . "why?"))))
         (request `((:method . "session/prompt")
                    (:params . ((sessionId . "s1")
                                (prompt . ,prompt))))))
    (agent-shell-side--prepend-boundary request)
    (should (equal (length (map-nested-elt request '(:params prompt))) 1))))

(ert-deftest agent-shell-side-test-boundary-cancels-standing-conventions ()
  "Both instruction channels cancel the parent's standing conventions.

Against a live claude-agent-acp, a boundary without this clause left the
fork still obeying a \"end every reply with X\" rule from the parent: the
model declined to continue the parent's task but read a formatting rule
as a convention rather than a cancelled instruction."
  (dolist (text (list agent-shell-side-boundary-prompt
                      agent-shell-side-instructions))
    (should (string-match-p "[Ss]tanding conventions" text))
    (should (string-match-p "output format" text))
    (should (string-match-p "persona" text))))

;;; Decorator

(ert-deftest agent-shell-side-test-decorator-only-first-prompt ()
  "Only the first `session/prompt' carries the boundary."
  (let ((decorator (agent-shell-side--make-decorator))
        (request `((:method . "session/prompt")
                   (:params . ((sessionId . "s1")
                               (prompt . [((type . "text") (text . "q"))]))))))
    (should (equal (length (map-nested-elt (funcall decorator request)
                                           '(:params prompt)))
                   2))
    (should (equal (length (map-nested-elt (funcall decorator request)
                                           '(:params prompt)))
                   1))))

(ert-deftest agent-shell-side-test-decorator-ignores-other-methods ()
  "Requests that are not prompts pass through untouched.

A `session/set_mode' sent before the first prompt must not consume the
one-shot boundary, or the boundary never reaches the agent."
  (let* ((decorator (agent-shell-side--make-decorator))
         (set-mode '((:method . "session/set_mode")
                     (:params . ((sessionId . "s1") (modeId . "default")))))
         (prompt '((:method . "session/prompt")
                   (:params . ((sessionId . "s1")
                               (prompt . [((type . "text") (text . "q"))]))))))
    (should (equal (funcall decorator set-mode) set-mode))
    (should (equal (length (map-nested-elt (funcall decorator prompt)
                                           '(:params prompt)))
                   2))))

(ert-deftest agent-shell-side-test-decorator-chains-to-next ()
  "A user-supplied decorator still runs after ours."
  (let* ((seen nil)
         (next (lambda (request) (push (map-elt request :method) seen) request))
         (decorator (agent-shell-side--make-decorator next))
         (request '((:method . "session/prompt")
                    (:params . ((sessionId . "s1")
                                (prompt . [((type . "text") (text . "q"))]))))))
    (funcall decorator request)
    (should (equal seen '("session/prompt")))))

(ert-deftest agent-shell-side-test-decorator-survives-next-returning-nil ()
  "A chained decorator returning nil must not drop the request.

`acp-send-request' logs and falls back to the original request when a
decorator returns nil, so returning nil here would silently lose our
boundary block as well."
  (let* ((decorator (agent-shell-side--make-decorator (lambda (_request) nil)))
         (request '((:method . "session/prompt")
                    (:params . ((sessionId . "s1")
                                (prompt . [((type . "text") (text . "q"))])))))
         (result (funcall decorator request)))
    (should result)
    (should (equal (length (map-nested-elt result '(:params prompt))) 2))))

;;; Session metadata

(ert-deftest agent-shell-side-test-session-meta-appends-system-prompt ()
  "Side instructions ride `_meta.systemPrompt.append'."
  (let ((meta (agent-shell-side--session-meta nil)))
    (should (equal (map-nested-elt meta '(systemPrompt append))
                   agent-shell-side-instructions))))

(ert-deftest agent-shell-side-test-session-meta-preserves-agent-meta ()
  "An agent's own metadata survives the merge."
  (let* ((parent '((claudeCode . ((options . ((thinking . ((type . "adaptive")))))))))
         (meta (agent-shell-side--session-meta parent)))
    (should (equal (map-nested-elt meta '(claudeCode options thinking type))
                   "adaptive"))
    (should (equal (map-nested-elt meta '(systemPrompt append))
                   agent-shell-side-instructions))))

(ert-deftest agent-shell-side-test-session-meta-does-not-mutate-parent ()
  "The parent config's metadata is left alone."
  (let* ((parent (list (cons 'claudeCode '((options . nil))))))
    (agent-shell-side--session-meta parent)
    (should-not (assq 'systemPrompt parent))))

(ert-deftest agent-shell-side-test-session-meta-keeps-parent-append ()
  "A parent's own system-prompt append survives ahead of the side text.

That append is the user's configuration, not a convention of the parent
conversation, so a side conversation keeps it.  Codex does the same
with its existing developer instructions."
  (let* ((parent '((systemPrompt . ((append . "House rules.")))))
         (meta (agent-shell-side--session-meta parent)))
    (should (equal (seq-count (lambda (entry) (eq (car entry) 'systemPrompt)) meta) 1))
    (should (equal (map-nested-elt meta '(systemPrompt append))
                   (concat "House rules.\n\n" agent-shell-side-instructions)))))

(ert-deftest agent-shell-side-test-session-meta-keeps-other-system-prompt-keys ()
  "Keys of the parent's systemPrompt other than append are carried over."
  (let* ((parent '((systemPrompt . ((mode . "strict")))))
         (meta (agent-shell-side--session-meta parent)))
    (should (equal (map-nested-elt meta '(systemPrompt mode)) "strict"))
    (should (equal (map-nested-elt meta '(systemPrompt append))
                   agent-shell-side-instructions))))

;;; Derived config

(ert-deftest agent-shell-side-test-config-marks-buffer-name ()
  "The side shell announces itself in its buffer and mode-line names."
  (let* ((parent '((:identifier . claude-code)
                   (:buffer-name . "Claude")
                   (:mode-line-name . "Claude")))
         (config (agent-shell-side--config parent)))
    (should (equal (map-elt config :buffer-name) "Claude [side]"))
    (should (equal (map-elt config :mode-line-name) "Claude [side]"))
    (should (equal (map-elt config :identifier) 'claude-code))))

(ert-deftest agent-shell-side-test-config-does-not-mutate-parent ()
  "Deriving a side config leaves the parent config untouched."
  (let ((parent (list (cons :identifier 'claude-code)
                      (cons :buffer-name "Claude")
                      (cons :mode-line-name "Claude")
                      (cons :session-meta nil))))
    (agent-shell-side--config parent)
    (should (equal (map-elt parent :buffer-name) "Claude"))
    (should-not (map-elt parent :session-meta))))

;;; Parent status

(ert-deftest agent-shell-side-test-status-for-event ()
  "Parent events map onto the statuses worth interrupting for."
  (should (eq (agent-shell-side--status-for-event 'permission-request) 'needs-approval))
  (should (eq (agent-shell-side--status-for-event 'turn-complete) 'finished))
  (should (eq (agent-shell-side--status-for-event 'error) 'failed))
  (should (eq (agent-shell-side--status-for-event 'clean-up) 'closed))
  (should (eq (agent-shell-side--status-for-event 'input-submitted) 'clear))
  (should-not (agent-shell-side--status-for-event 'agent-message-chunk)))

(ert-deftest agent-shell-side-test-status-label ()
  "Statuses read as plain English naming the parent."
  (should (equal (agent-shell-side--status-label 'needs-approval) "main needs approval"))
  (should (equal (agent-shell-side--status-label 'finished) "main finished"))
  (should-not (agent-shell-side--status-label nil)))

(ert-deftest agent-shell-side-test-lighter ()
  "The mode line shows the side role and any parent status."
  (should (equal (agent-shell-side--lighter-string 'side nil) " Side"))
  (should (equal (agent-shell-side--lighter-string 'side 'needs-approval)
                 " Side:main needs approval"))
  (should (equal (agent-shell-side--lighter-string 'parent nil) " Side↩")))

;;; Link store

(defmacro agent-shell-side-tests--with-links-file (&rest body)
  "Evaluate BODY with the link store pointed at a throwaway file."
  (declare (indent 0))
  `(let* ((file (make-temp-file "agent-shell-side-links" nil ".eld"))
          (agent-shell-side-links-file file))
     (unwind-protect
         (progn ,@body)
       (delete-file file))))

(ert-deftest agent-shell-side-test-links-round-trip ()
  "A written record reads back intact."
  (agent-shell-side-tests--with-links-file
    (agent-shell-side-links-add
     (agent-shell-side-links-make :side-session-id "side-1"
                                  :parent-session-id "parent-1"
                                  :agent 'claude-code
                                  :cwd "/tmp/project/"))
    (let ((records (agent-shell-side-links-read)))
      (should (equal (length records) 1))
      (should (equal (map-elt (car records) :side-session-id) "side-1"))
      (should (equal (map-elt (car records) :parent-session-id) "parent-1"))
      (should (equal (map-elt (car records) :agent) 'claude-code))
      (should (equal (map-elt (car records) :boundary-version)
                     agent-shell-side-boundary-version))
      (should (map-elt (car records) :created)))))

(ert-deftest agent-shell-side-test-links-add-replaces-same-session ()
  "Re-adding a side session updates rather than duplicates it."
  (agent-shell-side-tests--with-links-file
    (agent-shell-side-links-add
     (agent-shell-side-links-make :side-session-id "side-1"
                                  :parent-session-id "parent-1"
                                  :agent 'claude-code
                                  :cwd "/tmp/a/"))
    (agent-shell-side-links-add
     (agent-shell-side-links-make :side-session-id "side-1"
                                  :parent-session-id "parent-1"
                                  :agent 'claude-code
                                  :cwd "/tmp/b/"))
    (let ((records (agent-shell-side-links-read)))
      (should (equal (length records) 1))
      (should (equal (map-elt (car records) :cwd) "/tmp/b/")))))

(ert-deftest agent-shell-side-test-links-remove ()
  "Removing a record leaves its siblings behind."
  (agent-shell-side-tests--with-links-file
    (agent-shell-side-links-add
     (agent-shell-side-links-make :side-session-id "side-1"
                                  :parent-session-id "parent-1"
                                  :agent 'claude-code :cwd "/tmp/"))
    (agent-shell-side-links-add
     (agent-shell-side-links-make :side-session-id "side-2"
                                  :parent-session-id "parent-1"
                                  :agent 'claude-code :cwd "/tmp/"))
    (agent-shell-side-links-remove "side-1")
    (let ((records (agent-shell-side-links-read)))
      (should (equal (length records) 1))
      (should (equal (map-elt (car records) :side-session-id) "side-2")))))

(ert-deftest agent-shell-side-test-links-for-parent ()
  "Lookup returns only the records belonging to that parent."
  (agent-shell-side-tests--with-links-file
    (agent-shell-side-links-add
     (agent-shell-side-links-make :side-session-id "side-1"
                                  :parent-session-id "parent-1"
                                  :agent 'claude-code :cwd "/tmp/"))
    (agent-shell-side-links-add
     (agent-shell-side-links-make :side-session-id "side-2"
                                  :parent-session-id "parent-2"
                                  :agent 'claude-code :cwd "/tmp/"))
    (let ((records (agent-shell-side-links-for-parent "parent-1")))
      (should (equal (length records) 1))
      (should (equal (map-elt (car records) :side-session-id) "side-1")))))

(ert-deftest agent-shell-side-test-links-missing-file-is-empty ()
  "An absent store reads as no records rather than an error."
  (let ((agent-shell-side-links-file
         (expand-file-name "definitely-absent.eld" temporary-file-directory)))
    (when (file-exists-p agent-shell-side-links-file)
      (delete-file agent-shell-side-links-file))
    (should-not (agent-shell-side-links-read))))

(ert-deftest agent-shell-side-test-links-empty-file-is-quietly-empty ()
  "An empty store reads as no records without warning.

`make-temp-file' and an interrupted write both leave an empty file, and
neither means the store is damaged."
  (agent-shell-side-tests--with-links-file
    (let ((messages nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (format &rest args)
                   (push (apply #'format format args) messages))))
        (should-not (agent-shell-side-links-read)))
      (should-not messages))))

(ert-deftest agent-shell-side-test-links-garbage-file-is-empty ()
  "A corrupt store reads as no records, and says so once."
  (agent-shell-side-tests--with-links-file
    (with-temp-file agent-shell-side-links-file
      (insert "((((( not elisp"))
    (let ((messages nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (format &rest args)
                   (push (apply #'format format args) messages))))
        (should-not (agent-shell-side-links-read)))
      (should (equal (length messages) 1))
      (should (string-match-p "ignoring unreadable" (car messages))))))

(ert-deftest agent-shell-side-test-links-non-list-file-is-empty ()
  "A readable but wrong-shaped store reads as no records."
  (agent-shell-side-tests--with-links-file
    (with-temp-file agent-shell-side-links-file
      (insert "\"just a string\""))
    (should-not (agent-shell-side-links-read))))

(ert-deftest agent-shell-side-test-links-stale-boundary-version ()
  "Records written by an older boundary text are flagged, not hidden."
  (agent-shell-side-tests--with-links-file
    (agent-shell-side-links-add
     (agent-shell-side-links-make :side-session-id "side-1"
                                  :parent-session-id "parent-1"
                                  :agent 'claude-code :cwd "/tmp/"
                                  :boundary-version 0))
    (let ((record (car (agent-shell-side-links-for-parent "parent-1"))))
      (should (agent-shell-side-links-stale-p record)))))

;;; Buffer wiring

(defmacro agent-shell-side-tests--with-parent (&rest body)
  "Evaluate BODY in a stub parent shell buffer bound to `parent'.

The buffer looks like a started session on an agent that can fork."
  (declare (indent 0))
  `(let ((parent (generate-new-buffer " *agent-shell side test parent*"))
         (agent-shell-test-history '(("hello" . "hi there")))
         (agent-shell-test-subscriptions nil)
         (agent-shell-test-unsubscribed nil)
         (agent-shell-test-started nil)
         (agent-shell-test-interrupted nil)
         (agent-shell-test-status 'ready)
         (acp-test-sent-requests nil)
         (acp-test-request-outcome 'success)
         ;; Off by default so the suite's output stays readable.  The
         ;; echoing itself is asserted by
         ;; `agent-shell-side-test-parent-status-is-echoed'.
         (agent-shell-side-report-parent-status nil)
         ;; Windows are the subject of a handful of tests and noise in the
         ;; rest, so the default side window is opted into rather than out
         ;; of.  Left as the real default, every test that forks would
         ;; leave a side window standing for the next one.
         (agent-shell-side-display-action '(display-buffer-same-window)))
     (unwind-protect
         (progn
           (with-current-buffer parent
             (agent-shell-mode)
             (setq-local agent-shell--state
                         (list (cons :agent-config
                                     (list (cons :identifier 'claude-code)
                                           (cons :buffer-name "Claude")
                                           (cons :mode-line-name "Claude")
                                           (cons :session-meta nil)))
                               (cons :session (list (cons :id "parent-1")))
                               (cons :client 'stub-client)
                               (cons :supports-session-fork t))))
           ,@body)
       (dolist (buffer (buffer-list))
         (when (string-prefix-p " *agent-shell side test" (buffer-name buffer))
           (let ((kill-buffer-query-functions nil))
             (kill-buffer buffer)))))))

(ert-deftest agent-shell-side-test-start-links-both-buffers ()
  "Starting a side conversation links parent and child both ways."
  (agent-shell-side-tests--with-parent
    (let ((side (with-current-buffer parent
                  (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
                    (agent-shell-side)))))
      (should (agent-shell-side-buffer-p side))
      (should (eq (buffer-local-value 'agent-shell-side--parent-buffer side)
                  parent))
      (should (eq (buffer-local-value 'agent-shell-side--side-buffer parent)
                  side))
      (should (buffer-local-value 'agent-shell-side-mode side))
      (should (buffer-local-value 'agent-shell-side-mode parent)))))

(ert-deftest agent-shell-side-test-start-forks-parent-session ()
  "The fork names the parent's session and carries a decorator."
  (agent-shell-side-tests--with-parent
    (with-current-buffer parent
      (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
        (agent-shell-side)))
    (should (equal (map-elt agent-shell-test-started :fork-session-id) "parent-1"))
    (should (functionp (map-elt agent-shell-test-started
                                :outgoing-request-decorator)))
    (should (equal (map-nested-elt agent-shell-test-started
                                   '(:config :buffer-name))
                   "Claude [side]"))))

(ert-deftest agent-shell-side-test-start-requires-a-session ()
  "A conversation that has not started yet cannot be forked."
  (agent-shell-side-tests--with-parent
    (with-current-buffer parent
      (setf (alist-get :session agent-shell--state) nil)
      (should-error (agent-shell-side) :type 'user-error))))

(ert-deftest agent-shell-side-test-start-requires-a-taken-turn ()
  "A conversation that has said nothing yet is refused before forking.

Having a session id is not enough.  `session/new' hands one out before
anything is said, and claude-agent-acp answers `session/fork' with -32002
Resource not found until there is a transcript to copy."
  (agent-shell-side-tests--with-parent
    (let ((agent-shell-test-history nil))
      (with-current-buffer parent
        (should-error (agent-shell-side) :type 'user-error))
      (should-not agent-shell-test-started))))

(ert-deftest agent-shell-side-test-start-allows-a-resumed-conversation ()
  "A resumed conversation forks even though its buffer is empty.

Resuming replays nothing into the buffer, so its history reads as empty
while the session behind it is full.  Verified live: forking a resumed
shell inherits the parent's history and answers from it."
  (agent-shell-side-tests--with-parent
    (let ((agent-shell-test-history nil))
      (with-current-buffer parent
        (setf (alist-get :resume-session-id agent-shell--state) "parent-1")
        (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
          (should (agent-shell-side))))
      (should agent-shell-test-started))))

(ert-deftest agent-shell-side-test-start-requires-fork-capability ()
  "An agent without `session/fork' is refused rather than silently emptied.

`agent-shell--initiate-session' starts a *new* session when the fork
capability is missing, which would drop the inherited history without
saying so."
  (agent-shell-side-tests--with-parent
    (with-current-buffer parent
      (setf (alist-get :supports-session-fork agent-shell--state) nil)
      (should-error (agent-shell-side) :type 'user-error))
    (should-not agent-shell-test-started)))

(ert-deftest agent-shell-side-test-start-refuses-second-side ()
  "One side conversation per parent."
  (agent-shell-side-tests--with-parent
    (with-current-buffer parent
      (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
        (agent-shell-side)
        (should-error (agent-shell-side) :type 'user-error)))))

(ert-deftest agent-shell-side-test-start-refuses-nesting ()
  "A side conversation cannot itself spawn one."
  (agent-shell-side-tests--with-parent
    (let ((side (with-current-buffer parent
                  (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
                    (agent-shell-side)))))
      (with-current-buffer side
        (should-error (agent-shell-side) :type 'user-error)))))

(ert-deftest agent-shell-side-test-killing-side-unsubscribes-parent ()
  "A closed side conversation stops listening to its parent."
  (agent-shell-side-tests--with-parent
    (let* ((side (with-current-buffer parent
                   (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
                     (agent-shell-side))))
           (token (buffer-local-value 'agent-shell-side--parent-subscription side)))
      (let ((kill-buffer-query-functions nil))
        (kill-buffer side))
      (should (memq token agent-shell-test-unsubscribed))
      (should-not (buffer-local-value 'agent-shell-side--side-buffer parent))
      (should-not (buffer-local-value 'agent-shell-side-mode parent)))))

(ert-deftest agent-shell-side-test-killing-parent-detaches-side ()
  "A side conversation outlives its parent, marked closed."
  (agent-shell-side-tests--with-parent
    (let ((side (with-current-buffer parent
                  (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
                    (agent-shell-side)))))
      (let ((kill-buffer-query-functions nil))
        (kill-buffer parent))
      (should (buffer-live-p side))
      (should-not (buffer-local-value 'agent-shell-side--parent-buffer side))
      (should (eq (buffer-local-value 'agent-shell-side--parent-status side)
                  'closed)))))

(ert-deftest agent-shell-side-test-parent-status-tracks-events ()
  "Parent events reach the side conversation's mode line."
  (agent-shell-side-tests--with-parent
    (let* ((side (with-current-buffer parent
                   (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
                     (agent-shell-side))))
           (handler (nth 2 (seq-find (lambda (subscription)
                                       (and (eq (nth 0 subscription) parent)
                                            (null (nth 1 subscription))))
                                     agent-shell-test-subscriptions))))
      (should handler)
      (funcall handler '((:event . permission-request)))
      (should (eq (buffer-local-value 'agent-shell-side--parent-status side)
                  'needs-approval))
      (funcall handler '((:event . input-submitted)))
      (should-not (buffer-local-value 'agent-shell-side--parent-status side)))))

(ert-deftest agent-shell-side-test-parent-status-is-echoed ()
  "A parent that wants attention is echoed, once, when the option is on.

The mode line alone is easy to miss when the parent is off screen."
  (agent-shell-side-tests--with-parent
    (let* ((agent-shell-side-report-parent-status t)
           (messages nil)
           (side (with-current-buffer parent
                   (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
                     (agent-shell-side))))
           (handler (nth 2 (seq-find (lambda (subscription)
                                       (and (eq (nth 0 subscription) parent)
                                            (null (nth 1 subscription))))
                                     agent-shell-test-subscriptions))))
      (ignore side)
      (set-window-buffer (selected-window) side)
      (cl-letf (((symbol-function 'message)
                 (lambda (format &rest args)
                   (push (apply #'format format args) messages))))
        (funcall handler '((:event . permission-request)))
        (funcall handler '((:event . permission-request))))
      (should (equal messages '("Side conversation: main needs approval"))))))

(ert-deftest agent-shell-side-test-parent-status-echo-needs-the-side-on-screen ()
  "No echo when the side conversation is not visible.

The echo is for the user sitting in the side conversation with the parent
off screen.  Someone looking at the parent already sees what happened,
and a message about it is noise."
  (agent-shell-side-tests--with-parent
    (let* ((agent-shell-side-report-parent-status t)
           (messages nil)
           (side (agent-shell-side-tests--open-side parent))
           (handler (nth 2 (seq-find (lambda (subscription)
                                       (and (eq (nth 0 subscription) parent)
                                            (null (nth 1 subscription))))
                                     agent-shell-test-subscriptions))))
      (set-window-buffer (selected-window) parent)
      (cl-letf (((symbol-function 'message)
                 (lambda (format &rest args)
                   (push (apply #'format format args) messages))))
        (funcall handler '((:event . permission-request))))
      (should-not messages)
      (should (eq (buffer-local-value 'agent-shell-side--parent-status side)
                  'needs-approval)))))

(defun agent-shell-side-tests--handler (buffer event)
  "Return the handler subscribed to EVENT on BUFFER, or nil."
  (nth 2 (seq-find (lambda (subscription)
                     (and (eq (nth 0 subscription) buffer)
                          (eq (nth 1 subscription) event)))
                   agent-shell-test-subscriptions)))

(defun agent-shell-side-tests--open-side (parent)
  "Start a side conversation from PARENT without touching its session id."
  (with-current-buffer parent
    (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
      (agent-shell-side))))

(ert-deftest agent-shell-side-test-session-id-from-public-event ()
  "The side session id is taken from the public `session-selected' event."
  (agent-shell-side-tests--with-parent
    (let* ((side (agent-shell-side-tests--open-side parent))
           (handler (agent-shell-side-tests--handler side nil)))
      (should handler)
      (funcall handler '((:event . session-selected)
                         (:data . ((:session-id . "side-1")))))
      (should (equal (agent-shell-side--session-id side) "side-1")))))

(ert-deftest agent-shell-side-test-fork-that-starts-no-session-is-torn-down ()
  "A fork that never gets a session is closed rather than left behind.

`session/fork' can fail while the shell started for it stays: no session
is ever selected, and the buffer takes input that goes nowhere.  Against
claude-agent-acp this is what forking a conversation that has never taken
a turn does, answering -32002."
  (agent-shell-side-tests--with-parent
    (let* ((side (agent-shell-side-tests--open-side parent))
           (handler (agent-shell-side-tests--handler side nil)))
      (should handler)
      (should (seq-find
               (lambda (line) (string-match-p "did not start a session" line))
               (agent-shell-side-tests--silently
                 (funcall handler
                          '((:event . error)
                            (:data . ((:code . -32002)
                                      (:message . "Resource not found: x"))))))))
      (should-not (buffer-live-p side))
      (should-not (buffer-local-value 'agent-shell-side--side-buffer parent)))))

(ert-deftest agent-shell-side-test-error-after-a-session-keeps-the-side ()
  "Once the session exists, an error is an ordinary failure, not a dead fork."
  (agent-shell-side-tests--with-parent
    (let* ((side (agent-shell-side-tests--open-side parent))
           (handler (agent-shell-side-tests--handler side nil)))
      (funcall handler '((:event . session-selected)
                         (:data . ((:session-id . "side-1")))))
      (agent-shell-side-tests--silently
        (funcall handler '((:event . error)
                           (:data . ((:message . "boom"))))))
      (should (buffer-live-p side)))))

;;; Dismissal

(defun agent-shell-side-tests--start-side (parent)
  "Start a side conversation from PARENT with a known session id."
  (let ((side (with-current-buffer parent
                (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
                  (agent-shell-side)))))
    (with-current-buffer side
      (setq agent-shell-side--session-id-cache "side-1"))
    side))

(ert-deftest agent-shell-side-test-dismiss-delete-sends-session-delete ()
  "Dismissing with `delete' asks the agent to drop the forked session."
  (agent-shell-side-tests--with-parent
    (let ((side (agent-shell-side-tests--start-side parent))
          (agent-shell-side-on-dismiss 'delete))
      (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
        (with-current-buffer side
          (agent-shell-side-dismiss)))
      (should-not (buffer-live-p side))
      (should (equal (map-elt (car acp-test-sent-requests) :method)
                     "session/delete"))
      (should (equal (map-nested-elt (car acp-test-sent-requests)
                                     '(:params sessionId))
                     "side-1")))))

(ert-deftest agent-shell-side-test-dismiss-keep-records-a-link ()
  "Dismissing with `keep' records the fork instead of deleting it."
  (agent-shell-side-tests--with-links-file
    (agent-shell-side-tests--with-parent
      (let ((side (agent-shell-side-tests--start-side parent))
            (agent-shell-side-on-dismiss 'keep))
        (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
          (with-current-buffer side
            (agent-shell-side-dismiss)))
        (should-not (buffer-live-p side))
        (should-not acp-test-sent-requests)
        (let ((record (car (agent-shell-side-links-for-parent "parent-1"))))
          (should record)
          (should (equal (map-elt record :side-session-id) "side-1"))
          (should (eq (map-elt record :agent) 'claude-code)))))))

(ert-deftest agent-shell-side-test-dismiss-interrupts-a-busy-turn ()
  "A side conversation still working is interrupted before it closes."
  (agent-shell-side-tests--with-parent
    (let ((side (agent-shell-side-tests--start-side parent))
          (agent-shell-side-on-dismiss 'delete)
          (agent-shell-test-status 'busy))
      (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
        (with-current-buffer side
          (agent-shell-side-dismiss)))
      (should (memq side agent-shell-test-interrupted)))))

(ert-deftest agent-shell-side-test-dismiss-closes-even-when-delete-fails ()
  "A transport failure on `session/delete' still closes the buffer."
  (agent-shell-side-tests--with-parent
    (let ((side (agent-shell-side-tests--start-side parent))
          (agent-shell-side-on-dismiss 'delete)
          (acp-test-request-outcome 'error))
      (cl-letf (((symbol-function 'pop-to-buffer) #'ignore)
                ((symbol-function 'message) #'ignore))
        (with-current-buffer side
          (agent-shell-side-dismiss)))
      (should-not (buffer-live-p side)))))

(ert-deftest agent-shell-side-test-dismiss-from-parent ()
  "Dismissing works from the parent buffer too."
  (agent-shell-side-tests--with-parent
    (let ((side (agent-shell-side-tests--start-side parent))
          (agent-shell-side-on-dismiss 'delete))
      (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
        (with-current-buffer parent
          (agent-shell-side-dismiss)))
      (should-not (buffer-live-p side)))))

(ert-deftest agent-shell-side-test-toggle-requires-a-link ()
  "Toggling in an unrelated shell says so rather than doing nothing."
  (agent-shell-side-tests--with-parent
    (with-current-buffer parent
      (should-error (agent-shell-side-toggle) :type 'user-error))))

;;; Opening message

(ert-deftest agent-shell-side-test-quote ()
  "A quoted selection is a markdown block quote."
  (should (equal (agent-shell-side--quote "one\ntwo") "> one\n> two"))
  (should (equal (agent-shell-side--quote "  padded  ") "> padded")))

(ert-deftest agent-shell-side-test-quote-keeps-blank-lines-quoted ()
  "Blank lines inside a selection stay inside the quote.

An unprefixed blank line ends a markdown block quote, which would leave
the rest of the selection reading as the user's own words."
  (should (equal (agent-shell-side--quote "one\n\ntwo") "> one\n>\n> two")))

(ert-deftest agent-shell-side-test-opening-message ()
  "The opening message pairs any quoted selection with the question."
  (should (equal (agent-shell-side--opening-message "sel" "why?")
                 "> sel\n\nwhy?"))
  (should (equal (agent-shell-side--opening-message nil "why?") "why?"))
  (should (equal (agent-shell-side--opening-message "sel" nil) "> sel"))
  (should-not (agent-shell-side--opening-message nil nil))
  (should-not (agent-shell-side--opening-message "   " "  ")))

(ert-deftest agent-shell-side-test-start-sends-opening-message-when-ready ()
  "An opening message is sent once the forked shell is ready, not before.

The fork is asynchronous, so submitting at once would race session
creation."
  (agent-shell-side-tests--with-parent
    (let* ((agent-shell-test-inserted nil)
           (side (with-current-buffer parent
                   (cl-letf (((symbol-function 'agent-shell-side--display) #'ignore))
                     (agent-shell-side "why?"))))
           (handler (nth 2 (seq-find (lambda (subscription)
                                       (eq (nth 1 subscription) 'prompt-ready))
                                     agent-shell-test-subscriptions))))
      (should handler)
      (should-not agent-shell-test-inserted)
      (funcall handler '((:event . prompt-ready)))
      (let ((insertion (car agent-shell-test-inserted)))
        (should (equal (map-elt insertion :text) "why?"))
        (should (map-elt insertion :submit))
        (should (eq (map-elt insertion :shell-buffer) side))))))

(ert-deftest agent-shell-side-test-opening-message-sent-once ()
  "A later prompt does not resend the opening message.

`prompt-ready' is emitted per prompt, so an unguarded handler would
resend the question after every turn."
  (agent-shell-side-tests--with-parent
    (let* ((agent-shell-test-inserted nil)
           (_side (with-current-buffer parent
                    (cl-letf (((symbol-function 'agent-shell-side--display) #'ignore))
                      (agent-shell-side "why?"))))
           (handler (nth 2 (seq-find (lambda (subscription)
                                       (eq (nth 1 subscription) 'prompt-ready))
                                     agent-shell-test-subscriptions))))
      (funcall handler '((:event . prompt-ready)))
      (funcall handler '((:event . prompt-ready)))
      (should (equal (length agent-shell-test-inserted) 1)))))

(ert-deftest agent-shell-side-test-start-without-message-sends-nothing ()
  "Starting empty leaves the side conversation waiting for input."
  (agent-shell-side-tests--with-parent
    (let ((agent-shell-test-inserted nil))
      (with-current-buffer parent
        (cl-letf (((symbol-function 'agent-shell-side--display) #'ignore))
          (agent-shell-side)))
      (when-let* ((handler (nth 2 (seq-find
                                   (lambda (subscription)
                                     (eq (nth 1 subscription) 'prompt-ready))
                                   agent-shell-test-subscriptions))))
        (funcall handler '((:event . prompt-ready))))
      (should-not agent-shell-test-inserted))))

(defmacro agent-shell-side-tests--silently (&rest body)
  "Evaluate BODY collecting `message' output instead of printing it.

Returns the messages, newest first, so a test can assert on them without
the suite's own output carrying them."
  (declare (indent 0))
  `(let ((agent-shell-side-tests--messages nil))
     (cl-letf (((symbol-function 'message)
                (lambda (format &rest args)
                  (push (apply #'format format args)
                        agent-shell-side-tests--messages))))
       ,@body)
     agent-shell-side-tests--messages))

(defvar agent-shell-side-tests--messages nil
  "Messages captured by `agent-shell-side-tests--silently'.")

;;; Handback

(ert-deftest agent-shell-side-test-handback-text ()
  "Findings arrive in the parent under a header naming where they came from."
  (let ((agent-shell-side-handback-header "Findings from a side conversation:"))
    (should (equal (agent-shell-side--handback-text "  it pulls tokio-util  ")
                   "Findings from a side conversation:\n\nit pulls tokio-util"))))

(ert-deftest agent-shell-side-test-conclude-asks-for-a-summary ()
  "Concluding sends the summary request into the side conversation."
  (agent-shell-side-tests--with-parent
    (let ((side (agent-shell-side-tests--start-side parent))
          (agent-shell-test-inserted nil))
      (agent-shell-side-tests--silently
        (with-current-buffer side
          (agent-shell-side-conclude)))
      (let ((insertion (car agent-shell-test-inserted)))
        (should (eq (map-elt insertion :shell-buffer) side))
        (should (map-elt insertion :submit))
        (should (equal (map-elt insertion :text)
                       agent-shell-side-handback-prompt))))))

(ert-deftest agent-shell-side-test-conclude-hands-findings-to-parent ()
  "The summary reaches the parent as an editable draft, and the side closes."
  (agent-shell-side-tests--with-parent
    (let* ((side (agent-shell-side-tests--start-side parent))
           (agent-shell-side-on-dismiss 'delete)
           (agent-shell-test-inserted nil)
           (agent-shell-test-viewport-calls nil))
      (agent-shell-side-tests--silently
        (with-current-buffer side
          (agent-shell-side-conclude)))
      (let ((handler (nth 2 (seq-find (lambda (subscription)
                                        (and (eq (nth 0 subscription) side)
                                             (null (nth 1 subscription))))
                                      agent-shell-test-subscriptions))))
        (should handler)
        (funcall handler '((:event . agent-message-chunk)
                           (:data . ((:text-chunk . "it pulls ")))))
        (funcall handler '((:event . agent-message-chunk)
                           (:data . ((:text-chunk . "tokio-util")))))
        (cl-letf (((symbol-function 'agent-shell-side--display) #'ignore))
          (funcall handler '((:event . turn-complete)
                             (:data . ((:stop-reason . "end_turn")))))))
      (let ((call (car agent-shell-test-viewport-calls)))
        (should call)
        (should (eq (plist-get call :shell-buffer) parent))
        (should (string-suffix-p "it pulls tokio-util" (plist-get call :append)))
        ;; Ready to type in, and never sent for the user.
        (should (plist-get call :edit))
        (should-not (plist-get call :submit)))
      ;; Nothing is pushed at the parent's prompt any more.
      (should-not (agent-shell-side-tests--inserted-into parent))
      (should-not (buffer-live-p side)))))

(ert-deftest agent-shell-side-test-conclude-keeps-side-open-when-empty ()
  "A turn that produced no text leaves the side conversation open.

Closing on an empty summary would throw away the conversation and hand
the parent nothing."
  (agent-shell-side-tests--with-parent
    (let* ((side (agent-shell-side-tests--start-side parent))
           (agent-shell-test-inserted nil))
      (agent-shell-side-tests--silently
        (with-current-buffer side
          (agent-shell-side-conclude)))
      (let ((handler (nth 2 (seq-find (lambda (subscription)
                                        (and (eq (nth 0 subscription) side)
                                             (null (nth 1 subscription))))
                                      agent-shell-test-subscriptions))))
        (should (seq-find
                 (lambda (line) (string-match-p "no summary came back" line))
                 (agent-shell-side-tests--silently
                   (funcall handler '((:event . turn-complete)
                                      (:data . ((:stop-reason . "end_turn")))))))))
      (should (buffer-live-p side))
      (should-not (seq-find (lambda (insertion)
                              (eq (map-elt insertion :shell-buffer) parent))
                            agent-shell-test-inserted)))))

(ert-deftest agent-shell-side-test-conclude-refuses-while-busy ()
  "A side conversation mid-turn is not asked to summarise on top of it."
  (agent-shell-side-tests--with-parent
    (let ((side (agent-shell-side-tests--start-side parent))
          (agent-shell-test-status 'busy))
      (agent-shell-side-tests--silently
        (with-current-buffer side
          (should-error (agent-shell-side-conclude) :type 'user-error))))))

(ert-deftest agent-shell-side-test-conclude-refuses-without-parent ()
  "With no parent to hand findings to, concluding is refused."
  (agent-shell-side-tests--with-parent
    (let ((side (agent-shell-side-tests--start-side parent)))
      (let ((kill-buffer-query-functions nil))
        (kill-buffer parent))
      (agent-shell-side-tests--silently
        (with-current-buffer side
          (should-error (agent-shell-side-conclude) :type 'user-error)))
      (should (buffer-live-p side)))))

;;; Listing open side conversations

(ert-deftest agent-shell-side-test-buffer-p-survives-a-closed-parent ()
  "A side conversation is still one after its parent is killed.

The parent link is cleared when the parent goes away.  A predicate
reading only that link would stop recognising the buffer, and every
command keyed off it would then refuse to act on exactly the
conversations most likely to be left lying around."
  (agent-shell-side-tests--with-parent
    (let ((side (agent-shell-side-tests--start-side parent)))
      (let ((kill-buffer-query-functions nil))
        (kill-buffer parent))
      (should (agent-shell-side-buffer-p side)))))

(ert-deftest agent-shell-side-test-dismiss-works-without-a-parent ()
  "An orphaned side conversation can still be closed by its own command."
  (agent-shell-side-tests--with-parent
    (let ((side (agent-shell-side-tests--start-side parent))
          (agent-shell-side-on-dismiss 'delete))
      (let ((kill-buffer-query-functions nil))
        (kill-buffer parent))
      (agent-shell-side-tests--silently
        (with-current-buffer side
          (agent-shell-side-dismiss)))
      (should-not (buffer-live-p side)))))

(ert-deftest agent-shell-side-test-orphan-keeps-the-side-lighter ()
  "An orphaned side conversation does not advertise itself as a parent."
  (agent-shell-side-tests--with-parent
    (let ((side (agent-shell-side-tests--start-side parent)))
      (let ((kill-buffer-query-functions nil))
        (kill-buffer parent))
      (with-current-buffer side
        (should (string-prefix-p " Side:" (agent-shell-side--lighter)))))))

(ert-deftest agent-shell-side-test-format-age ()
  "Ages read in the largest unit that still says something."
  (should (equal (agent-shell-side--format-age 0) "0s"))
  (should (equal (agent-shell-side--format-age 45) "45s"))
  (should (equal (agent-shell-side--format-age 60) "1m"))
  (should (equal (agent-shell-side--format-age (* 90 60)) "1h"))
  (should (equal (agent-shell-side--format-age (* 50 60 60)) "2d")))

(ert-deftest agent-shell-side-test-list-buffers-finds-side-conversations ()
  "Listing finds side conversations and skips their parents."
  (agent-shell-side-tests--with-parent
    (let ((side (agent-shell-side-tests--start-side parent)))
      (should (memq side (agent-shell-side--list-buffers)))
      (should-not (memq parent (agent-shell-side--list-buffers))))))

(ert-deftest agent-shell-side-test-list-buffers-keeps-orphans ()
  "An orphaned side conversation is still listed.

It is the one nothing else points at any more, so leaving it out would
hide the buffers most in need of attention."
  (agent-shell-side-tests--with-parent
    (let ((side (agent-shell-side-tests--start-side parent)))
      (let ((kill-buffer-query-functions nil))
        (kill-buffer parent))
      (should (memq side (agent-shell-side--list-buffers))))))

(ert-deftest agent-shell-side-test-list-label-describes-the-parent ()
  "A candidate names its parent and reports the parent's state."
  (agent-shell-side-tests--with-parent
    (let ((side (agent-shell-side-tests--start-side parent)))
      (agent-shell-side--set-parent-status side 'needs-approval)
      (let ((label (agent-shell-side--list-label side)))
        (should (string-match-p (regexp-quote (buffer-name side)) label))
        (should (string-match-p (regexp-quote (buffer-name parent)) label))
        (should (string-match-p "needs approval" label))))))

(ert-deftest agent-shell-side-test-list-label-marks-a-gone-parent ()
  "A candidate says so when the parent buffer is gone."
  (agent-shell-side-tests--with-parent
    (let ((side (agent-shell-side-tests--start-side parent)))
      (let ((kill-buffer-query-functions nil))
        (kill-buffer parent))
      (let ((label (agent-shell-side--list-label side)))
        (should (string-match-p "gone" label))
        (should (string-match-p "closed" label))))))

(ert-deftest agent-shell-side-test-list-labels-stay-unique ()
  "Two side conversations with the same name are still separable.

`completing-read' returns a string, so candidates that collapse to one
label would make the second one unreachable."
  (agent-shell-side-tests--with-parent
    (let ((first (agent-shell-side-tests--start-side parent))
          (second (generate-new-buffer " *agent-shell side test twin*")))
      (with-current-buffer second
        (agent-shell-mode)
        (setq agent-shell-side--is-side t)
        (setq agent-shell-side--created-at (current-time))
        (rename-buffer (buffer-name first) t))
      (let ((candidates (agent-shell-side--list-candidates)))
        (should (equal (length candidates) 2))
        (should (equal (length (seq-uniq (mapcar #'car candidates))) 2))))))

(defun agent-shell-side-tests--make-parent (session-id)
  "Return another stub parent shell whose session is SESSION-ID."
  (let ((buffer (generate-new-buffer " *agent-shell side test parent alt*")))
    (with-current-buffer buffer
      (agent-shell-mode)
      (setq-local agent-shell--state
                  (list (cons :agent-config
                              (list (cons :identifier 'claude-code)
                                    (cons :buffer-name "Claude")
                                    (cons :mode-line-name "Claude")
                                    (cons :session-meta nil)))
                        (cons :session (list (cons :id session-id)))
                        (cons :client 'stub-client)
                        (cons :supports-session-fork t))))
    buffer))

(ert-deftest agent-shell-side-test-list-scopes-to-the-current-session ()
  "From a shell, the listing covers that conversation's own side ones."
  (agent-shell-side-tests--with-parent
    (let* ((mine (agent-shell-side-tests--start-side parent))
           (other-parent (agent-shell-side-tests--make-parent "parent-2"))
           (theirs (agent-shell-side-tests--start-side other-parent))
           (buffers (with-current-buffer parent
                      (agent-shell-side--list-buffers
                       (agent-shell-side--current-session-id)))))
      (should (memq mine buffers))
      (should-not (memq theirs buffers)))))

(ert-deftest agent-shell-side-test-list-can-cover-every-session ()
  "Asked for everything, the listing crosses conversations."
  (agent-shell-side-tests--with-parent
    (let* ((mine (agent-shell-side-tests--start-side parent))
           (other-parent (agent-shell-side-tests--make-parent "parent-2"))
           (theirs (agent-shell-side-tests--start-side other-parent))
           (buffers (agent-shell-side--list-buffers)))
      (should (memq mine buffers))
      (should (memq theirs buffers)))))

(ert-deftest agent-shell-side-test-list-from-a-side-scopes-to-its-parent ()
  "Inside a side conversation, the scope is the conversation it came from."
  (agent-shell-side-tests--with-parent
    (let* ((mine (agent-shell-side-tests--start-side parent))
           (other-parent (agent-shell-side-tests--make-parent "parent-2"))
           (theirs (agent-shell-side-tests--start-side other-parent))
           (buffers (with-current-buffer mine
                      (agent-shell-side--list-buffers
                       (agent-shell-side--current-session-id)))))
      (should (memq mine buffers))
      (should-not (memq theirs buffers)))))

(ert-deftest agent-shell-side-test-list-outside-a-shell-covers-everything ()
  "Away from any shell there is no session to scope to, so nothing is hidden."
  (agent-shell-side-tests--with-parent
    (let ((side (agent-shell-side-tests--start-side parent)))
      (with-temp-buffer
        (should-not (agent-shell-side--current-session-id))
        (should (memq side (agent-shell-side--list-buffers
                            (agent-shell-side--current-session-id))))))))

(ert-deftest agent-shell-side-test-list-scoped-refuses-when-session-has-none ()
  "A conversation with no side ones says so, without offering another's."
  (agent-shell-side-tests--with-parent
    (let ((other-parent (agent-shell-side-tests--make-parent "parent-2")))
      (agent-shell-side-tests--start-side other-parent)
      (with-current-buffer parent
        (should-error (agent-shell-side-list) :type 'user-error)))))

(ert-deftest agent-shell-side-test-list-refuses-when-there-are-none ()
  "With nothing open, listing says so rather than prompting on an empty set."
  (agent-shell-side-tests--with-parent
    (should-error (agent-shell-side-list) :type 'user-error)))

(ert-deftest agent-shell-side-test-list-switches-to-the-choice ()
  "Picking a candidate switches to that side conversation."
  (agent-shell-side-tests--with-parent
    (let ((side (agent-shell-side-tests--start-side parent)))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt collection &rest _)
                   (car (car collection)))))
        (save-window-excursion
          (agent-shell-side-list)
          (should (eq (current-buffer) side)))))))

(ert-deftest agent-shell-side-test-list-skips-a-buffer-killed-while-choosing ()
  "A side conversation killed during the prompt is refused, not switched to."
  (agent-shell-side-tests--with-parent
    (let ((side (agent-shell-side-tests--start-side parent)))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt collection &rest _)
                   (let ((kill-buffer-query-functions nil))
                     (kill-buffer side))
                   (car (car collection)))))
        (should-error (agent-shell-side-list) :type 'user-error)))))

;;; Review fixes, 2026-09-06

(ert-deftest agent-shell-side-test-on-dismiss-defaults-to-delete ()
  "Closing a side conversation drops its session unless asked otherwise.

Codex side threads are ephemeral, and a question on every close is the
friction that makes people stop using the feature.  Keeping is one
customize away."
  (should (eq (default-value 'agent-shell-side-on-dismiss) 'delete)))

(ert-deftest agent-shell-side-test-start-checks-before-asking ()
  "Preconditions are checked before the question is read.

Typing a question and then being told the agent cannot fork wastes the
typing.  Codex checks first and restores the composer on failure."
  (agent-shell-side-tests--with-parent
    (with-current-buffer parent
      (setf (alist-get :supports-session-fork agent-shell--state) nil)
      (cl-letf (((symbol-function 'read-string)
                 (lambda (&rest _) (ert-fail "asked for a question first"))))
        (should-error (call-interactively #'agent-shell-side)
                      :type 'user-error)))))

(defun agent-shell-side-tests--conclude-with-summary (side text &optional real-display)
  "Run `agent-shell-side-conclude' in SIDE and stream TEXT back as its summary.

Display is stubbed out by default, so a test that only cares about where
the findings went is not at the mercy of window layout.  REAL-DISPLAY
keeps the real one, for the tests that are about display itself."
  (agent-shell-side-tests--silently
    (with-current-buffer side
      (agent-shell-side-conclude)))
  (let ((handler (nth 2 (seq-find (lambda (subscription)
                                    (and (eq (nth 0 subscription) side)
                                         (null (nth 1 subscription))))
                                  agent-shell-test-subscriptions))))
    (funcall handler `((:event . agent-message-chunk)
                       (:data . ((:text-chunk . ,text)))))
    (cl-letf (((symbol-function 'agent-shell-side--display)
               (if real-display
                   (symbol-function 'agent-shell-side--display)
                 #'ignore)))
      (agent-shell-side-tests--silently
        (funcall handler '((:event . turn-complete)
                           (:data . ((:stop-reason . "end_turn")))))))))

(defun agent-shell-side-tests--any-handler (buffer)
  "Return the handler subscribed to all of BUFFER's events."
  (nth 2 (seq-find (lambda (subscription)
                     (and (eq (nth 0 subscription) buffer)
                          (null (nth 1 subscription))))
                   agent-shell-test-subscriptions)))

(defun agent-shell-side-tests--ready-handler (buffer)
  "Return the handler subscribed to BUFFER's `prompt-ready' event."
  (nth 2 (seq-find (lambda (subscription)
                     (and (eq (nth 0 subscription) buffer)
                          (eq (nth 1 subscription) 'prompt-ready)))
                   agent-shell-test-subscriptions)))

(defun agent-shell-side-tests--settle-resumed (buffer session-id)
  "Finish BUFFER's resume as agent-shell would, landing on SESSION-ID.

Writes the id into the shell state rather than the package's own cache:
the cache is filled by the fork path only, so a resumed shell reads its
id from the state, and a test that set the cache would be testing a
source the real path never uses."
  (with-current-buffer buffer
    (setq-local agent-shell--state (list (cons :session (list (cons :id session-id))))))
  (funcall (agent-shell-side-tests--ready-handler buffer) '((:event . prompt-ready))))

(defun agent-shell-side-tests--viewport-for (shell)
  "Return the stub viewport buffer standing for SHELL."
  (agent-shell-viewport--buffer :shell-buffer shell))

(defun agent-shell-side-tests--inserted-into (buffer)
  "Return the recorded insertions aimed at BUFFER."
  (seq-filter (lambda (insertion) (eq (map-elt insertion :shell-buffer) buffer))
              agent-shell-test-inserted))

(defun agent-shell-side-tests--parent-handlers (parent)
  "Return every handler subscribed to all of PARENT's events."
  (mapcar (lambda (subscription) (nth 2 subscription))
          (seq-filter (lambda (subscription)
                        (and (eq (nth 0 subscription) parent)
                             (null (nth 1 subscription))))
                      agent-shell-test-subscriptions)))

(ert-deftest agent-shell-side-test-conclude-composes-in-the-viewport ()
  "With viewport interaction preferred, findings go to the compose buffer.

Opened in edit mode so a busy parent still takes them; the compose
buffer's own keys send, queue, or steer.  Nothing touches the shell
prompt and nothing is submitted."
  (agent-shell-side-tests--with-parent
    (let* ((side (agent-shell-side-tests--start-side parent))
           (agent-shell-side-on-dismiss 'delete)
           (agent-shell-prefer-viewport-interaction t)
           (agent-shell-test-inserted nil)
           (agent-shell-test-viewport-calls nil))
      (with-current-buffer parent
        (setq-local agent-shell-test-status 'busy))
      (agent-shell-side-tests--conclude-with-summary side "it pulls tokio-util")
      (should-not (seq-find (lambda (insertion)
                              (eq (map-elt insertion :shell-buffer) parent))
                            agent-shell-test-inserted))
      (let ((call (car agent-shell-test-viewport-calls)))
        (should call)
        (should (eq (plist-get call :shell-buffer) parent))
        (should (plist-get call :edit))
        (should-not (plist-get call :submit))
        (should (string-suffix-p "it pulls tokio-util" (plist-get call :append))))
      (should-not (buffer-live-p side)))))

(defmacro agent-shell-side-tests--with-resumable-record (&rest body)
  "Evaluate BODY with one kept record and a config that can resume it."
  (declare (indent 0))
  `(agent-shell-side-tests--with-links-file
     (let ((agent-shell-agent-configs
            (list (list (cons :identifier 'claude-code)
                        (cons :buffer-name "Claude")
                        (cons :mode-line-name "Claude"))))
           (agent-shell-test-started nil))
       (agent-shell-side-links-add
        (agent-shell-side-links-make :side-session-id "side-9"
                                     :parent-session-id "parent-9"
                                     :agent 'claude-code
                                     :cwd temporary-file-directory))
       (with-temp-buffer
         (cl-letf (((symbol-function 'completing-read)
                    (lambda (_prompt collection &rest _)
                      (car (car collection)))))
           ,@body)))))

(ert-deftest agent-shell-side-test-resume-marks-the-buffer-as-a-side ()
  "A resumed side conversation is recognised as one.

Without the mark it has no lighter, no keys, does not appear in
`agent-shell-side-list', and would let `agent-shell-side' nest."
  (agent-shell-side-tests--with-resumable-record
    (agent-shell-side-tests--silently (agent-shell-side-resume))
    (let ((resumed (current-buffer)))
      (should (agent-shell-side-buffer-p resumed))
      (should (buffer-local-value 'agent-shell-side-mode resumed))
      (should (buffer-local-value 'agent-shell-side--created-at resumed))
      (should-not (buffer-local-value 'agent-shell-side--parent-buffer resumed))
      (should (equal (map-elt agent-shell-test-started :session-id) "side-9")))))

(ert-deftest agent-shell-side-test-resume-drops-the-record-once-loaded ()
  "Resuming consumes the kept record, but only once the session loads.

The session is live again and will be recorded afresh if kept on its
next close.  Leaving the record would offer the same session twice, and
keep offering it after it is deleted."
  (agent-shell-side-tests--with-resumable-record
    (agent-shell-side-tests--silently (agent-shell-side-resume))
    (let ((resumed (current-buffer)))
      ;; `session-selected' is emitted before the load is even sent, and
      ;; `session-restored' only fires when a transcript was buffered for
      ;; replay, which the default verbosity never asks for.  Neither can
      ;; be the signal.
      (should (agent-shell-side-links-read))
      (agent-shell-side-tests--settle-resumed resumed "side-9")
      (should-not (agent-shell-side-links-read)))))

(ert-deftest agent-shell-side-test-resume-keeps-the-record-when-load-fails ()
  "A resume the agent rejects keeps its record.

A rejected load is not reported as an error to watch for: agent-shell
says so and quietly starts a different session, and that shell reaches
its prompt like any other.  So the id is what decides, and a shell that
came back as anything else must leave the record alone."
  (agent-shell-side-tests--with-resumable-record
    (agent-shell-side-tests--silently (agent-shell-side-resume))
    (let ((resumed (current-buffer)))
      (agent-shell-side-tests--silently
        (agent-shell-side-tests--settle-resumed resumed "some-other-session"))
      (should (agent-shell-side-links-read)))))

(ert-deftest agent-shell-side-test-resume-refuses-nesting ()
  "A resumed side conversation cannot fork another.

The stub's `agent-shell-start' hands back the current buffer, so the
parent shell that resumes its side becomes that side here."
  (agent-shell-side-tests--with-resumable-record
    (agent-shell-mode)
    (setq-local agent-shell--state (list (cons :session (list (cons :id "parent-9")))
                                         (cons :supports-session-fork t)))
    (agent-shell-side-tests--silently (agent-shell-side-resume))
    (should-error (agent-shell-side) :type 'user-error)))

(ert-deftest agent-shell-side-test-display-prefers-the-viewport ()
  "With viewport interaction preferred, the side opens in a viewport.

Mirrors `agent-shell--fork-shell-buffer', so a viewport user is not
dropped into a raw shell buffer they never otherwise see."
  (agent-shell-side-tests--with-parent
    (let ((agent-shell-prefer-viewport-interaction t)
          (agent-shell-test-viewport-shown nil))
      (let ((side (with-current-buffer parent (agent-shell-side))))
        (should (equal agent-shell-test-viewport-shown (list side)))))))

(ert-deftest agent-shell-side-test-display-from-a-viewport-uses-the-viewport ()
  "Started from a viewport buffer, the side opens in a viewport too."
  (agent-shell-side-tests--with-parent
    (let ((agent-shell-test-viewport-shown nil))
      (with-temp-buffer
        (agent-shell-viewport-view-mode)
        (cl-letf (((symbol-function 'agent-shell-shell-buffer)
                   (lambda (&rest _) parent)))
          (let ((side (agent-shell-side)))
            (should (equal agent-shell-test-viewport-shown (list side)))))))))

(ert-deftest agent-shell-side-test-display-without-viewport-uses-a-window ()
  "Otherwise the side is shown as a plain shell buffer."
  (agent-shell-side-tests--with-parent
    (let ((agent-shell-test-viewport-shown nil))
      (let ((side (with-current-buffer parent (agent-shell-side))))
        (should-not agent-shell-test-viewport-shown)
        (should (get-buffer-window side))))))

;;; Review of PR #1, 2026-09-06

(ert-deftest agent-shell-side-test-conclude-viewport-does-not-redisplay-parent ()
  "Closing after a viewport handback leaves the compose buffer alone.

Re-displaying the parent shell would re-enter the viewport with nothing
to append, and that path flips the compose buffer to read-only view
mode, stranding the findings there unsendable."
  (agent-shell-side-tests--with-parent
    (let* ((side (agent-shell-side-tests--start-side parent))
           (agent-shell-side-on-dismiss 'delete)
           (agent-shell-prefer-viewport-interaction t)
           (agent-shell-test-viewport-calls nil)
           (agent-shell-test-viewport-shown nil))
      (with-current-buffer parent
        (setq-local agent-shell-test-status 'busy))
      ;; The state viewport use actually puts the shells in: the user is
      ;; looking at a compose buffer, so neither shell buffer owns a
      ;; window.  Closing then has no window to hand back and falls
      ;; through to displaying the parent, which is the bug.
      (set-window-buffer (selected-window)
                         (get-buffer-create " *agent-shell side test elsewhere*"))
      (should-not (get-buffer-window parent))
      (should-not (get-buffer-window side))
      (agent-shell-side-tests--conclude-with-summary side "it pulls tokio-util" t)
      (should-not (buffer-live-p side))
      ;; Exactly one viewport call: the one carrying the findings.
      (should (equal (length agent-shell-test-viewport-calls) 1))
      (let ((call (car agent-shell-test-viewport-calls)))
        (should (eq (plist-get call :shell-buffer) parent))
        (should (plist-get call :edit))
        (should (string-suffix-p "it pulls tokio-util" (plist-get call :append)))))))

(ert-deftest agent-shell-side-test-dismiss-still-restores-the-parent ()
  "An ordinary dismiss, with no handback, still brings the parent back.

Asserts the outcome rather than the route: the parent takes over the
window the side had, and only falls back to being displayed afresh when
it had none."
  (agent-shell-side-tests--with-parent
    (let ((side (agent-shell-side-tests--start-side parent))
          (agent-shell-side-on-dismiss 'delete))
      (agent-shell-side-tests--silently
        (with-current-buffer side
          (agent-shell-side-dismiss)))
      (should-not (buffer-live-p side))
      (should (get-buffer-window parent)))))

(ert-deftest agent-shell-side-test-viewport-buffer-keeps-its-own-keys ()
  "The side mode is never turned on in a viewport buffer.

`agent-shell-viewport-edit-mode-map' binds C-c C-k to discard the draft
and C-c C-q to queue it.  A minor mode outranks a major-mode map, so
turning this one on there would make cancelling a draft delete a forked
session.  The commands still reach the shell, by name."
  (agent-shell-side-tests--with-parent
    (let* ((agent-shell-prefer-viewport-interaction t)
           (side (with-current-buffer parent (agent-shell-side)))
           (viewport (agent-shell-side-tests--viewport-for side)))
      (should viewport)
      (should-not (buffer-local-value 'agent-shell-side-mode viewport))
      (with-current-buffer viewport
        (should (eq (agent-shell-side--resolve-side) side))))))

(ert-deftest agent-shell-side-test-describe-works-from-a-viewport ()
  "Describing a side conversation works from its viewport compose buffer.

It also names a way in that really works there: the keys are not bound in
a viewport, so it must say the command name instead."
  (agent-shell-side-tests--with-parent
    (let* ((agent-shell-prefer-viewport-interaction t)
           (side (with-current-buffer parent (agent-shell-side)))
           (viewport (agent-shell-side-tests--viewport-for side))
           (said (with-current-buffer viewport
                   (car (agent-shell-side-tests--silently
                          (agent-shell-side-describe))))))
      (should (string-prefix-p "Side conversation of " said))
      (should (string-match-p "M-x agent-shell-side-toggle" said))
      (should-not (string-match-p "C-c C-b" said)))))

(ert-deftest agent-shell-side-test-describe-names-keys-in-the-shell ()
  "In the shell itself, where the keys are bound, it names the keys."
  (agent-shell-side-tests--with-parent
    (let* ((side (agent-shell-side-tests--start-side parent))
           (said (with-current-buffer side
                   (car (agent-shell-side-tests--silently
                          (agent-shell-side-describe))))))
      (should (string-match-p "C-c C-b" said)))))

(ert-deftest agent-shell-side-test-viewport-of-an-unrelated-shell-is-refused ()
  "A viewport whose shell is no side conversation resolves to nothing.

`agent-shell-shell-buffer' falls back to the first shell in the project
when a viewport cannot be matched to its own shell, and acting on an
unrelated conversation is worse than refusing."
  (agent-shell-side-tests--with-parent
    (let ((stranger (generate-new-buffer " *agent-shell side test stranger*"))
          (viewport (generate-new-buffer " *agent-shell side test viewport*")))
      (with-current-buffer stranger (agent-shell-mode))
      (with-current-buffer viewport
        (agent-shell-viewport-edit-mode)
        (setq-local agent-shell-test-viewport-shell stranger)
        (should (eq (agent-shell-side--this-shell) viewport))
        (should-error (agent-shell-side--resolve-side) :type 'user-error)))))

(ert-deftest agent-shell-side-test-conclude-from-the-viewport-buffer ()
  "Concluding works when run from the side's viewport buffer."
  (agent-shell-side-tests--with-parent
    (let* ((agent-shell-prefer-viewport-interaction t)
           (side (with-current-buffer parent (agent-shell-side)))
           (viewport (agent-shell-side-tests--viewport-for side))
           (agent-shell-test-inserted nil))
      (with-current-buffer side
        (setq agent-shell-side--session-id-cache "side-1"))
      (agent-shell-side-tests--silently
        (with-current-buffer viewport
          (agent-shell-side-conclude)))
      (should (seq-find (lambda (insertion)
                          (eq (map-elt insertion :shell-buffer) side))
                        agent-shell-test-inserted)))))


;;; Where a side conversation is shown, 2026-09-06

(defun agent-shell-side-tests--reset-windows ()
  "Return the frame to a single ordinary window.

Side windows are deleted first: `delete-other-windows' refuses to make
one the only window, so a leftover would break the next test."
  (dolist (window (window-list))
    (when (window-parameter window 'window-side)
      (ignore-errors (delete-window window))))
  (ignore-errors (delete-other-windows)))

(defconst agent-shell-side-tests--side-action
  '((display-buffer-in-side-window) (side . right) (window-width . 0.4))
  "The side-window action these tests exercise.

Spelled out rather than read from the option: `agent-shell-side-tests--with-parent'
binds that option dynamically, and `default-value' on a dynamically bound
variable returns the binding, not the shipped default.  That the shipped
default matches this is asserted separately, by
`agent-shell-side-test-ships-a-side-window-default'.")

(defmacro agent-shell-side-tests--with-windows (&rest body)
  "Evaluate BODY with a side-window action and a clean frame after."
  (declare (indent 0))
  `(let ((agent-shell-side-display-action agent-shell-side-tests--side-action)
         (agent-shell-display-action '(display-buffer-same-window)))
     (unwind-protect (progn ,@body)
       (agent-shell-side-tests--reset-windows))))

(ert-deftest agent-shell-side-test-ships-a-side-window-default ()
  "The option ships pointing at a window on the right."
  (should (equal (eval (car (get 'agent-shell-side-display-action 'standard-value)) t)
                 agent-shell-side-tests--side-action)))

(defun agent-shell-side-tests--side-windows ()
  "Return the frame's side windows."
  (seq-filter (lambda (window) (window-parameter window 'window-side))
              (window-list)))

(ert-deftest agent-shell-side-test-opens-beside-the-parent ()
  "By default a side conversation opens in a window of its own, on the right.

The parent stays visible.  That is the whole reason to have a separate
display action: a terminal has one pane and must swap, and Emacs need not."
  (agent-shell-side-tests--with-parent
    (agent-shell-side-tests--with-windows
      (agent-shell-side-tests--reset-windows)
      (set-window-buffer (selected-window) parent)
      (let ((side (with-current-buffer parent (agent-shell-side))))
        (should (get-buffer-window side))
        (should (eq (window-parameter (get-buffer-window side) 'window-side)
                    'right))
        ;; The point of the exercise: both are on screen.
        (should (get-buffer-window parent))))))

(ert-deftest agent-shell-side-test-closing-deletes-the-side-window ()
  "The side window goes away with the side conversation.

Handing it to the parent instead would leave the parent showing twice,
once in a strip meant for something else."
  (agent-shell-side-tests--with-parent
    (agent-shell-side-tests--with-windows
      (agent-shell-side-tests--reset-windows)
      (set-window-buffer (selected-window) parent)
      (let ((side (with-current-buffer parent (agent-shell-side)))
            (agent-shell-side-on-dismiss 'delete))
        (with-current-buffer side
          (setq agent-shell-side--session-id-cache "side-1"))
        (should (agent-shell-side-tests--side-windows))
        (agent-shell-side-tests--silently
          (with-current-buffer side (agent-shell-side-dismiss)))
        (should-not (agent-shell-side-tests--side-windows))
        (should (get-buffer-window parent))
        (should (equal (length (get-buffer-window-list parent)) 1))))))

(ert-deftest agent-shell-side-test-toggle-selects-when-both-are-visible ()
  "With both on screen, toggling moves point rather than rearranging windows.

Swapping would put the side conversation in two windows at once and the
parent in none."
  (agent-shell-side-tests--with-parent
    (agent-shell-side-tests--with-windows
      (agent-shell-side-tests--reset-windows)
      (set-window-buffer (selected-window) parent)
      (let ((side (with-current-buffer parent (agent-shell-side))))
        (select-window (get-buffer-window parent))
        (with-current-buffer parent (agent-shell-side-toggle))
        (should (eq (window-buffer (selected-window)) side))
        (should (equal (length (get-buffer-window-list side)) 1))
        (should (get-buffer-window parent))
        ;; And back again.
        (with-current-buffer side (agent-shell-side-toggle))
        (should (eq (window-buffer (selected-window)) parent))))))

(ert-deftest agent-shell-side-test-same-window-action-still-swaps ()
  "Setting the action to the old value restores the old behaviour.

`display-buffer-same-window' means displaying in the selected window,
which is what the swap was, so toggling needs no special case for it."
  (agent-shell-side-tests--with-parent
    (let ((agent-shell-side-display-action '(display-buffer-same-window)))
      (unwind-protect
          (progn
            (agent-shell-side-tests--reset-windows)
            (set-window-buffer (selected-window) parent)
            (let ((side (with-current-buffer parent (agent-shell-side))))
              (should (equal (length (window-list)) 1))
              (should (eq (window-buffer (selected-window)) side))
              (with-current-buffer side (agent-shell-side-toggle))
              (should (equal (length (window-list)) 1))
              (should (eq (window-buffer (selected-window)) parent))))
        (agent-shell-side-tests--reset-windows)))))

(ert-deftest agent-shell-side-test-parent-is-not-shown-with-the-side-action ()
  "The parent is an ordinary shell and is displayed like one.

Using the side action for it would file the parent away in the strip
meant for the side conversation."
  (agent-shell-side-tests--with-parent
    (agent-shell-side-tests--with-windows
      (agent-shell-side-tests--reset-windows)
      (set-window-buffer (selected-window) parent)
      (let ((side (with-current-buffer parent (agent-shell-side)))
            (agent-shell-side-on-dismiss 'delete)
            (elsewhere (get-buffer-create " *agent-shell side test elsewhere*")))
        (with-current-buffer side
          (setq agent-shell-side--session-id-cache "side-1"))
        ;; Take the parent off screen, so closing has to display it afresh.
        (set-window-buffer (get-buffer-window parent) elsewhere)
        (should-not (get-buffer-window parent))
        (agent-shell-side-tests--silently
          (with-current-buffer side (agent-shell-side-dismiss)))
        (should (get-buffer-window parent))
        (should-not (window-parameter (get-buffer-window parent) 'window-side))))))

;;; One handback path, whatever the viewport setting

(ert-deftest agent-shell-side-test-conclude-composes-without-viewport-interaction ()
  "Findings go to a compose buffer even with viewport interaction off.

The setting decides where the user's own prompts go; it has no business
deciding what happens to findings.  A busy parent is the case that used
to differ, so that is the one asserted here."
  (agent-shell-side-tests--with-parent
    (let* ((side (agent-shell-side-tests--start-side parent))
           (agent-shell-side-on-dismiss 'delete)
           (agent-shell-prefer-viewport-interaction nil)
           (agent-shell-test-inserted nil)
           (agent-shell-test-viewport-calls nil))
      (with-current-buffer parent
        (setq-local agent-shell-test-status 'busy))
      (agent-shell-side-tests--conclude-with-summary side "it pulls tokio-util")
      (let ((call (car agent-shell-test-viewport-calls)))
        (should call)
        (should (eq (plist-get call :shell-buffer) parent))
        (should (plist-get call :edit))
        (should (string-suffix-p "it pulls tokio-util" (plist-get call :append))))
      ;; No waiting, no pending state, and nothing at the shell prompt.
      (should-not (agent-shell-side-tests--inserted-into parent))
      (should-not (buffer-live-p side)))))

(ert-deftest agent-shell-side-test-conclude-is-the-same-either-way ()
  "The two viewport settings produce the same delivery."
  (let ((seen nil))
    (dolist (preference '(nil t))
      (agent-shell-side-tests--with-parent
        (let* ((side (agent-shell-side-tests--start-side parent))
               (agent-shell-side-on-dismiss 'delete)
               (agent-shell-prefer-viewport-interaction preference)
               (agent-shell-test-viewport-calls nil))
          (with-current-buffer parent
            (setq-local agent-shell-test-status 'busy))
          (agent-shell-side-tests--conclude-with-summary side "findings")
          (push (let ((call (car agent-shell-test-viewport-calls)))
                  (list (plist-get call :edit)
                        (plist-get call :submit)
                        (plist-get call :append)))
                seen))))
    (should (equal (car seen) (cadr seen)))
    (should (car (car seen)))))

(ert-deftest agent-shell-side-test-conclude-runs-from-a-compose-buffer ()
  "Concluding works from the parent's compose buffer, not just the shell.

`agent-shell-insert' dispatches on the *current* buffer, so from a
viewport it routes into `agent-shell-viewport--show-buffer', which
signals \"Not yet supported\" for `:submit'.  The summary request must
address the side conversation's shell buffer directly."
  (agent-shell-side-tests--with-parent
    (let* ((side (agent-shell-side-tests--start-side parent))
           (agent-shell-test-inserted nil)
           (viewport (generate-new-buffer " *agent-shell side test compose*")))
      (unwind-protect
          (with-current-buffer viewport
            (agent-shell-viewport-edit-mode)
            (setq-local agent-shell-test-viewport-shell parent)
            (setq-local agent-shell-side--side-buffer side)
            (agent-shell-side-tests--silently
              (agent-shell-side-conclude))
            (should (agent-shell-side-tests--inserted-into side)))
        (kill-buffer viewport)))))

(ert-deftest agent-shell-side-test-handback-keeps-a-queued-draft-queued ()
  "Appending findings must not downgrade a queued draft into a steer.

`agent-shell-viewport--show-buffer' writes the disposition on every
call, nil included, so passing none would drop the user's `queue' and
let `agent-shell-prompt-while-busy' steer their prompt into the running
turn instead."
  (agent-shell-side-tests--with-parent
    (let* ((side (agent-shell-side-tests--start-side parent))
           (agent-shell-side-on-dismiss 'delete)
           (agent-shell-test-viewport-calls nil)
           (viewport (generate-new-buffer " *agent-shell side test compose*")))
      (unwind-protect
          (progn
            (with-current-buffer viewport
              (agent-shell-viewport-edit-mode)
              (setq-local agent-shell-test-viewport-shell parent)
              (insert "a follow-up I drafted")
              (setq-local agent-shell-viewport--compose-disposition 'queue))
            (agent-shell-side-tests--conclude-with-summary side "it pulls tokio-util")
            (should (eq (plist-get (car agent-shell-test-viewport-calls) :disposition)
                        'queue)))
        (kill-buffer viewport)))))

(ert-deftest agent-shell-side-test-handback-does-not-inherit-a-stale-disposition ()
  "An empty compose buffer's leftover disposition is not carried forward.

The disposition belongs to a draft.  With no draft in progress there is
nothing to honour, and reusing the last one would apply one command's
choice to a different prompt."
  (agent-shell-side-tests--with-parent
    (let* ((side (agent-shell-side-tests--start-side parent))
           (agent-shell-side-on-dismiss 'delete)
           (agent-shell-test-viewport-calls nil)
           (viewport (generate-new-buffer " *agent-shell side test compose*")))
      (unwind-protect
          (progn
            (with-current-buffer viewport
              (agent-shell-viewport-edit-mode)
              (setq-local agent-shell-test-viewport-shell parent)
              (setq-local agent-shell-viewport--compose-disposition 'steer))
            (agent-shell-side-tests--conclude-with-summary side "it pulls tokio-util")
            (should-not (plist-get (car agent-shell-test-viewport-calls) :disposition)))
        (kill-buffer viewport)))))

(provide 'agent-shell-side-tests)
;;; agent-shell-side-tests.el ends here
