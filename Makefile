EMACS ?= emacs

# load-prefer-newer everywhere: `make compile` leaves .elc files behind, and
# without it a later `make test` silently runs the stale compiled copy
# instead of the source being edited.
BATCH = $(EMACS) -Q --batch --eval '(setq load-prefer-newer t)'

# Where the live probes find the real stack.  Override to point at
# another checkout: make live-check AGENT_SHELL_DIR=...
AGENT_SHELL_DIR ?= $(HOME)/Repositories/forks/agent-shell
ACP_DIR ?= $(HOME)/Repositories/forks/acp
SHELL_MAKER_DIR ?= $(HOME)/Repositories/forks/shell-maker

.PHONY: compile test check live-check clean

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

# Deliberately not part of `check': this starts a real agent, spends real
# API tokens, and waits on model output that is not deterministic.  Run it
# when the adapter or ACP version changes, and before tagging a release.
live-check:
	$(BATCH) -L . -L tests/live \
		-L $(AGENT_SHELL_DIR) -L $(ACP_DIR) -L $(SHELL_MAKER_DIR) \
		-l agent-shell-side-live \
		-f agent-shell-side-live-batch

clean:
	rm -f *.elc tests/*.elc tests/support/*.elc tests/live/*.elc
