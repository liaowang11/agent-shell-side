;;; agent-shell-side-links.el --- Parent/side session links -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Copyright (C) 2026 Bill and contributors

;;; Commentary:

;; Remembers which forked session belongs to which parent.
;;
;; ACP has no ephemeral session: `session/fork' always leaves a session
;; behind in the agent's own store.  When a side conversation is dismissed
;; with `keep' rather than `delete', the fork survives but nothing records
;; that it was a side conversation of anything.  This file is that record.
;;
;; Each record is one side session:
;;
;;   ((:side-session-id . "…")
;;    (:parent-session-id . "…")
;;    (:agent . claude-code)      ; config identifier, to rebuild the config
;;    (:cwd . "/path/to/project/")
;;    (:created . "2026-08-24T14:03:00+0800")
;;    (:boundary-version . 1))    ; which boundary text the session started with
;;
;; The agent identifier and boundary version are what make resuming
;; correct rather than approximate.  Resuming rebuilds the side config from
;; the identifier, so the side instructions are re-sent (agents read
;; `_meta.systemPrompt' again on resume, and would otherwise drop the side
;; policy).  The boundary version says whether the session was created
;; under the current instruction text.
;;
;; The store is a printed alist, read with `read' and written with `prin1',
;; the same shape `recentf' and `savehist' use.  Add and remove rewrite the
;; whole file, so two Emacs instances racing can lose a record but cannot
;; corrupt the store.

;;; Code:

(require 'map)
(require 'seq)
(eval-when-compile (require 'cl-lib))

(defgroup agent-shell-side nil
  "Side conversations for `agent-shell'."
  :group 'tools
  :prefix "agent-shell-side-")

(defcustom agent-shell-side-links-file
  (locate-user-emacs-file "agent-shell-side-links.eld")
  "File recording which side session belongs to which parent session.

Only written for side conversations dismissed with `keep'.  See
`agent-shell-side-on-dismiss'."
  :type 'file
  :group 'agent-shell-side)

(defconst agent-shell-side-boundary-version 2
  "Revision of the side boundary and instruction text.

Revision 2 added the clause about standing conventions.  Without it a
live claude-agent-acp fork kept obeying a \"end every reply with X\"
instruction from the parent conversation: the model correctly declined to
continue the parent's *task*, but read a formatting rule as a persistent
convention rather than an instruction the boundary had cancelled.

Bumped whenever `agent-shell-side-boundary-prompt' or
`agent-shell-side-instructions' changes in a way that matters to a
resumed session.  Records written under an older revision are reported by
`agent-shell-side-links-stale-p'.")

(cl-defun agent-shell-side-links-make (&key side-session-id
                                            parent-session-id
                                            agent
                                            cwd
                                            created
                                            boundary-version)
  "Return a link record.

SIDE-SESSION-ID and PARENT-SESSION-ID are ACP session ids.  AGENT is the
`:identifier' of the agent config the shell was started with.  CWD is the
directory the side conversation ran in.  CREATED defaults to now, and
BOUNDARY-VERSION to `agent-shell-side-boundary-version'."
  (unless side-session-id
    (error ":side-session-id is required"))
  (unless parent-session-id
    (error ":parent-session-id is required"))
  (list (cons :side-session-id side-session-id)
        (cons :parent-session-id parent-session-id)
        (cons :agent agent)
        (cons :cwd cwd)
        (cons :created (or created (format-time-string "%FT%T%z")))
        (cons :boundary-version (or boundary-version
                                    agent-shell-side-boundary-version))))

(defun agent-shell-side-links-read ()
  "Return all link records, oldest first.

A missing, empty, unreadable, or wrong-shaped store reads as no records:
a corrupt file should cost the side history, not every command in the
package.  Only a file with content that fails to parse is reported, since
an empty file is what an interrupted write leaves behind and says nothing
is wrong."
  (when (file-readable-p agent-shell-side-links-file)
    (let ((records (condition-case err
                       (with-temp-buffer
                         (insert-file-contents agent-shell-side-links-file)
                         (goto-char (point-min))
                         (unless (looking-at-p "\\(?:[[:space:]]\\|;.*$\\)*\\'")
                           (read (current-buffer))))
                     (error
                      (message "agent-shell-side: ignoring unreadable %s (%s)"
                               agent-shell-side-links-file
                               (error-message-string err))
                      nil))))
      (when (and (listp records)
                 (seq-every-p #'consp records))
        records))))

(defun agent-shell-side-links--write (records)
  "Write RECORDS to `agent-shell-side-links-file'."
  (make-directory (file-name-directory agent-shell-side-links-file) t)
  (with-temp-file agent-shell-side-links-file
    (insert ";; agent-shell-side session links.  Written by Emacs, do not edit.\n")
    (let ((print-length nil)
          (print-level nil))
      (prin1 records (current-buffer)))
    (insert "\n")))

(defun agent-shell-side-links-add (record)
  "Store RECORD, replacing any earlier record for the same side session."
  (let ((side-session-id (map-elt record :side-session-id)))
    (agent-shell-side-links--write
     (append (seq-remove (lambda (existing)
                           (equal (map-elt existing :side-session-id)
                                  side-session-id))
                         (agent-shell-side-links-read))
             (list record))))
  record)

(defun agent-shell-side-links-remove (side-session-id)
  "Forget the record for SIDE-SESSION-ID."
  (agent-shell-side-links--write
   (seq-remove (lambda (record)
                 (equal (map-elt record :side-session-id) side-session-id))
               (agent-shell-side-links-read))))

(defun agent-shell-side-links-for-parent (parent-session-id)
  "Return the records whose parent is PARENT-SESSION-ID."
  (seq-filter (lambda (record)
                (equal (map-elt record :parent-session-id) parent-session-id))
              (agent-shell-side-links-read)))

(defun agent-shell-side-links-stale-p (record)
  "Return non-nil when RECORD predates the current boundary text.

A stale record can still be resumed.  It means the session was created
under different side instructions, so the two texts now coexist in that
conversation."
  (not (equal (map-elt record :boundary-version)
              agent-shell-side-boundary-version)))

(provide 'agent-shell-side-links)

;;; agent-shell-side-links.el ends here
