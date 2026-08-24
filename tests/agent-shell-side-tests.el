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

(ert-deftest agent-shell-side-test-session-meta-replaces-existing-system-prompt ()
  "A parent that already set a system prompt does not end up with two."
  (let* ((parent '((systemPrompt . ((append . "parent text")))))
         (meta (agent-shell-side--session-meta parent)))
    (should (equal (seq-count (lambda (entry) (eq (car entry) 'systemPrompt)) meta) 1))
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
         (agent-shell-side-report-parent-status nil))
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
      (cl-letf (((symbol-function 'message)
                 (lambda (format &rest args)
                   (push (apply #'format format args) messages))))
        (funcall handler '((:event . permission-request)))
        (funcall handler '((:event . permission-request))))
      (should (equal messages '("Side conversation: main needs approval"))))))

(ert-deftest agent-shell-side-test-session-id-from-public-event ()
  "The side session id is taken from the public `session-selected' event."
  (agent-shell-side-tests--with-parent
    (let* ((side (with-current-buffer parent
                   (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
                     (agent-shell-side))))
           (handler (nth 2 (seq-find (lambda (subscription)
                                       (eq (nth 1 subscription) 'session-selected))
                                     agent-shell-test-subscriptions))))
      (should handler)
      (funcall handler '((:event . session-selected)
                         (:data . ((:session-id . "side-1")))))
      (should (equal (agent-shell-side--session-id side) "side-1")))))

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
  "The summarised turn is inserted into the parent, and the side closes."
  (agent-shell-side-tests--with-parent
    (let* ((side (agent-shell-side-tests--start-side parent))
           (agent-shell-side-on-dismiss 'delete)
           (agent-shell-test-inserted nil))
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
      (let ((handback (seq-find (lambda (insertion)
                                  (eq (map-elt insertion :shell-buffer) parent))
                                agent-shell-test-inserted)))
        (should handback)
        (should (string-suffix-p "it pulls tokio-util" (map-elt handback :text)))
        (should-not (map-elt handback :submit)))
      (should-not (buffer-live-p side)))))

(ert-deftest agent-shell-side-test-conclude-can-submit-in-parent ()
  "With `agent-shell-side-handback-submit', the findings are sent, not staged."
  (agent-shell-side-tests--with-parent
    (let* ((side (agent-shell-side-tests--start-side parent))
           (agent-shell-side-on-dismiss 'delete)
           (agent-shell-side-handback-submit t)
           (agent-shell-test-inserted nil))
      (agent-shell-side-tests--silently
        (with-current-buffer side
          (agent-shell-side-conclude)))
      (let ((handler (nth 2 (seq-find (lambda (subscription)
                                        (and (eq (nth 0 subscription) side)
                                             (null (nth 1 subscription))))
                                      agent-shell-test-subscriptions))))
        (funcall handler '((:event . agent-message-chunk)
                           (:data . ((:text-chunk . "done")))))
        (cl-letf (((symbol-function 'agent-shell-side--display) #'ignore))
          (funcall handler '((:event . turn-complete)
                             (:data . ((:stop-reason . "end_turn")))))))
      (should (map-elt (seq-find (lambda (insertion)
                                   (eq (map-elt insertion :shell-buffer) parent))
                                 agent-shell-test-inserted)
                       :submit)))))

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

(ert-deftest agent-shell-side-test-list-entries-describe-the-parent ()
  "An entry names its parent and reports the parent's state."
  (agent-shell-side-tests--with-parent
    (let ((side (agent-shell-side-tests--start-side parent)))
      (agent-shell-side--set-parent-status side 'needs-approval)
      (let ((columns (cadr (assq side (agent-shell-side--list-entries)))))
        (should (equal (aref columns 0) (buffer-name side)))
        (should (equal (aref columns 1) (buffer-name parent)))
        (should (equal (aref columns 2) "needs approval"))))))

(ert-deftest agent-shell-side-test-list-entries-mark-a-gone-parent ()
  "An entry says so when the parent buffer is gone."
  (agent-shell-side-tests--with-parent
    (let ((side (agent-shell-side-tests--start-side parent)))
      (let ((kill-buffer-query-functions nil))
        (kill-buffer parent))
      (let ((columns (cadr (assq side (agent-shell-side--list-entries)))))
        (should (equal (aref columns 1) "(gone)"))
        (should (equal (aref columns 2) "closed"))))))

(ert-deftest agent-shell-side-test-list-refuses-when-there-are-none ()
  "With nothing open, listing says so rather than showing an empty table."
  (agent-shell-side-tests--with-parent
    (should-error (agent-shell-side-list) :type 'user-error)))

(ert-deftest agent-shell-side-test-list-shows-a-table ()
  "Listing puts every open side conversation in the list buffer."
  (agent-shell-side-tests--with-parent
    (let ((side (agent-shell-side-tests--start-side parent)))
      (unwind-protect
          (save-window-excursion
            (agent-shell-side-list)
            (should (eq major-mode 'agent-shell-side-list-mode))
            (should (assq side tabulated-list-entries)))
        (when-let* ((buffer (get-buffer agent-shell-side-list-buffer-name)))
          (kill-buffer buffer))))))

(ert-deftest agent-shell-side-test-list-visits-the-side-conversation ()
  "Selecting a row switches to that side conversation."
  (agent-shell-side-tests--with-parent
    (let ((side (agent-shell-side-tests--start-side parent)))
      (unwind-protect
          (save-window-excursion
            (agent-shell-side-list)
            (goto-char (point-min))
            (agent-shell-side-list-visit)
            (should (eq (current-buffer) side)))
        (when-let* ((buffer (get-buffer agent-shell-side-list-buffer-name)))
          (kill-buffer buffer))))))

(provide 'agent-shell-side-tests)

;;; agent-shell-side-tests.el ends here
