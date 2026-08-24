EMACS ?= emacs

.PHONY: compile test check clean

compile:
	$(EMACS) -Q --batch -L . -L tests/support \
		-f batch-byte-compile \
		agent-shell-side-compat.el \
		agent-shell-side-links.el \
		agent-shell-side.el

test:
	$(EMACS) -Q --batch -L . -L tests/support -L tests \
		-l tests/agent-shell-side-tests.el \
		-f ert-run-tests-batch-and-exit

check: compile test

clean:
	rm -f *.elc tests/*.elc tests/support/*.elc
