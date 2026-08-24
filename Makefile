EMACS ?= emacs

# load-prefer-newer everywhere: `make compile` leaves .elc files behind, and
# without it a later `make test` silently runs the stale compiled copy
# instead of the source being edited.
BATCH = $(EMACS) -Q --batch --eval '(setq load-prefer-newer t)'

.PHONY: compile test check clean

compile:
	$(BATCH) -L . -L tests/support \
		-f batch-byte-compile \
		agent-shell-side-compat.el \
		agent-shell-side-links.el \
		agent-shell-side.el

test:
	$(BATCH) -L . -L tests/support -L tests \
		-l tests/agent-shell-side-tests.el \
		-f ert-run-tests-batch-and-exit

check: compile test

clean:
	rm -f *.elc tests/*.elc tests/support/*.elc
