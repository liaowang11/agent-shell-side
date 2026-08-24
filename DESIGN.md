# Design: open work for agent-shell-side

Status as of 2026-08-24. The package works: two commits, `make check` green
(byte-compile plus 57 ERT tests against stubs). One end-to-end run against a
real claude-agent-acp 0.70 verified the core mechanism (fork, boundary block,
task and convention refusal, `session/delete`).

Four questions remained open after that. This document records the decision
for each. Items 1, 3, and 4 are agreed. Item 2 was revised after reading
Codex's own implementation.

## 1. Live-testing handback and resume

Decision: build a repeatable live test file, kept out of `make check`.

`agent-shell-side-conclude` (handback) and `agent-shell-side-resume` were
coded against stubs but never run against a real agent. The earlier one-off
probes lived in `/tmp` and are gone with the machine state.

- Promote the probe logic into `tests/live/agent-shell-side-live.el`.
- Run it only through a new `make live-check` target. Never from
  `make check` or CI: it spawns a real claude-agent-acp process, spends real
  API tokens, and waits on non-deterministic model output.
- Document in the README when to run it: on an adapter bump, on an ACP
  version bump, and before tagging a release.

One continuous scenario against claude-agent-acp, the only adapter with full
feature support:

1. Fork with a planted fact. Start a real parent, put a fact only in its
   history, fork, ask about the fact, assert the answer uses it. This
   re-verifies what the one-off probe showed once.
2. Handback. Call `agent-shell-side-conclude`. Assert the summary flows
   through the real event path (`agent-message-chunk` then `turn-complete`
   in `agent-shell-side--collect-summary`), lands in the parent prefixed by
   `agent-shell-side-handback-header`, and the side buffer closes per
   `agent-shell-side-on-dismiss`. Also drive both refusal branches in
   `agent-shell-side--finish-handback`: an empty summary, and a parent
   killed before the summary lands. Neither has met real chunk timing.
3. Resume. Dismiss with `keep`, capture the link record, kill both buffers,
   call `agent-shell-side-resume`, assert the resumed session still answers
   from the planted fact. This tests the load-bearing claim in
   agent-shell-side-links.el's commentary: the adapter re-reads
   `_meta.systemPrompt` on resume, so the side policy survives.
4. The mid-turn fork probe from item 2 runs in this same file.

Assertions subscribe through `agent-shell-subscribe-to` with a hard timeout
(60 seconds), never sleep-polling. Each assertion reports pass or fail to a
report buffer so one run reads at a glance.

## 2. Forking while the parent's turn is in flight

Decision: do not add a busy guard. Probe claude-agent-acp's mid-turn
behavior; if the inherited partial turn reads as pending work, fix it in the
boundary text, not with a refusal.

This is the primary use case: ask a quick question while the main agent is
busy. It has never been exercised.

Two facts ground the decision.

First, process isolation. `agent-shell--start` (agent-shell.el:4715) creates
each shell's own ACP client, which spawns a fresh agent subprocess
(agent-shell.el:487). A side conversation is a separate OS process with its
own JSON-RPC connection. The fork request cannot queue behind the parent's
in-flight prompt at the transport layer. Any mid-turn risk is in the agent's
own session store, shared between the two processes on disk.

Second, Codex forks mid-turn on purpose. Read from the Codex source at
commit 2df67054 (2026-08-24):

- `/side` blocks only when no main thread exists or a side conversation is
  already open (`side_start_block_message`,
  codex-rs/tui/src/app/side.rs:610-618). Parent-busy is not checked.
- The fork reads the parent's persisted rollout file, Codex's on-disk
  transcript, appended as the turn streams
  (codex-rs/core/src/thread_manager.rs:1188). It does not read live
  in-memory state.
- The side fork uses `ForkSnapshot::Interrupted`
  (codex-rs/app-server/src/request_processors/thread_processor.rs:4792).
  Its contract: fork the current persisted history as if the source thread
  had been interrupted now; if the snapshot ends mid-turn, append the same
  `<turn_aborted>` marker a real interrupt produces. The fork's model sees
  the unfinished turn as aborted, not as a task to finish. The TUI
  suppresses its "turn was interrupted" notice inside side conversations
  (app/side.rs:266) because that marker is expected there.

So the desired semantics are known, not guessed: never refuse on busy, fork
captures history up to now, and the partial turn must read as aborted.

The remaining unknown is adapter-specific. Codex solved this inside its own
core. Our fork goes through claude-agent-acp, which wraps Claude Code's
session files. Whether it snapshots cleanly mid-turn, and whether the
partial turn reads as aborted, is untested.

Probe (in the live test file from item 1): drive a real parent through a
slow multi-step tool-using task. While `agent-shell-status` on the parent
reports busy, call `agent-shell-side`. Record whether the fork errors,
hangs, or succeeds; if it succeeds, whether the inherited history stops at
the last completed turn or includes partial progress; and whether the fork
tries to complete the unfinished turn.

Responses, in order of preference:

1. Probe clean: no code change. Delete the "not yet exercised" caveat from
   the README.
2. Fork succeeds but the fork treats the partial turn as pending work: add a
   clause to `agent-shell-side-boundary-prompt` stating that an unfinished
   turn in the inherited history was interrupted and must not be completed.
   Bump `agent-shell-side-boundary-version`. This is the Codex-faithful
   fix; we cannot inject a `<turn_aborted>` marker into another agent's
   history, so instruction text is our only channel. Estimated size: a few
   lines of text plus the version bump.
3. Fork errors or hangs mid-turn: add a busy/blocked `user-error` guard next
   to the existing checks in `agent-shell-side--parent-shell`
   (agent-shell-side.el:607), telling the user to wait or interrupt. One
   line. Last resort only, because it removes the feature's main use case.

Do not add the clause from response 2 preemptively. The boundary already
forbids continuing any pre-boundary instruction, plan, or tool call; add the
explicit interrupted-turn wording only if the probe shows it is needed.

## 3. Side-buffer accumulation

Decision: ambient visibility, no automatic cleanup.

Codex discards the side thread when the user navigates to any third thread.
That does not port: Emacs users switch buffers constantly, and auto-discard
would destroy side conversations mid-thought. But without it, side buffers
pile up with nothing reminding the user.

Rejected: an idle reaper that kills stale side buffers. It contradicts a
stance already in this codebase. `agent-shell-side--finish-handback` refuses
to close a side conversation on an empty or failed handback precisely to
avoid silently losing work. A reaper would lose work on a schedule instead
of on a failure, which is worse.

Adopted: one new command, `agent-shell-side-list`, backed by a
`tabulated-list-mode` buffer enumerating every live buffer where
`agent-shell-side-buffer-p` is non-nil, showing its parent, the parent's
status, and its age. Unbound by default, documented in the README,
discoverable via `M-x`. This matches how `list-buffers` and `ibuffer` work
in stock Emacs: the user sees what is open and decides what is done.
Estimated size: roughly 60-80 lines plus tests.

## 4. Nesting (a side conversation of a side conversation)

Decision: keep the one-hop limit for now.

`agent-shell-side--parent-shell` (agent-shell-side.el:615-616) refuses to
fork from inside a side conversation. This matches Codex.

The link record schema already supports chains with no change: a record's
`:parent-session-id` could itself be another record's `:side-session-id`,
and `agent-shell-side-links-for-parent` filters on that field alone. So
nothing needs restructuring to keep the option open.

Do not build it now. Handback, resume, and mid-turn forking are all still
unverified live. Nesting multiplies exactly that untested surface: boundary
instruction composition across N hops, N link records, N accumulating
buffers. Prove the one-hop case first.

If real usage later shows the need, the likely change is not a nesting
concept but deleting the one-hop guard. The boundary prompt is already
hop-agnostic: "everything before this boundary is inherited history ...
reference context only" holds regardless of how many forks produced that
history.

## Order of work

1. Item 1's live test file, including the item 2 probe. It is the
   instrument everything else depends on.
2. Item 2's response, chosen by the probe result.
3. Item 3's `agent-shell-side-list`, independent of the others.
4. Item 4: nothing.
