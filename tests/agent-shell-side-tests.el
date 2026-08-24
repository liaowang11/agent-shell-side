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

(provide 'agent-shell-side-tests)

;;; agent-shell-side-tests.el ends here
