;;; acp.el --- Test stub for acp -*- lexical-binding: t; -*-

;;; Commentary:

;; Enough of `acp' for `agent-shell-side.el' to load.  Requests are
;; recorded rather than sent.

;;; Code:

(require 'cl-lib)

(defconst acp-test-stub-p t
  "Non-nil when the acp test stub is loaded.")

(defvar acp-package-version "0.13.1")

(defvar acp-test-sent-requests nil
  "Requests passed to `acp-send-request', newest first.")

(defvar acp-test-request-outcome nil
  "How the stub resolves a request: nil, `success', `failure', or `error'.")

(cl-defun acp-make-session-delete-request (&key session-id)
  "Return a `session/delete' request for SESSION-ID."
  (unless session-id
    (error ":session-id is required"))
  `((:method . "session/delete")
    (:params . ((sessionId . ,session-id)))))

(cl-defun acp-send-request (&key client request buffer on-success on-failure sync)
  "Record REQUEST and resolve it per `acp-test-request-outcome'."
  (ignore client buffer sync)
  (push request acp-test-sent-requests)
  (pcase acp-test-request-outcome
    ('success (when on-success (funcall on-success nil)))
    ('failure (when on-failure (funcall on-failure nil)))
    ('error (error "Stubbed ACP transport failure"))
    (_ nil)))

(provide 'acp)

;;; acp.el ends here
