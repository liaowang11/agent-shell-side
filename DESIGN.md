# Design: open work for agent-shell-side

Status as of 2026-08-25. `make check` is green (76 ERT tests against stubs)
and `make live-check` passes 10 of 10 against a real claude-agent-acp 0.70.

Four questions were open when this was written. This document records the
decision for each, and what changed once they were built and run. Items 1
and 3 are built. Item 2 is answered and needed no code, though running it
found a separate bug that did. Item 4 stays deliberately unbuilt.

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
   `agent-shell-side-on-dismiss`. Also drive the refusal in
   `agent-shell-side--finish-handback` for a parent killed before the
   summary lands, which only real streaming can put in that window.

   Revised while building: the other refusal branch, an empty summary,
   stays a unit test. It is about content, not timing, and a live model
   cannot be made to reliably say nothing, so a live version would assert
   against a fake rather than the guard.
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

Decision: no code change. Answered by the live run, 2026-08-25.

Codex forks mid-turn on purpose. Read from the Codex source at commit
2df67054:

- `/side` blocks only when no main thread exists or a side conversation
  is already open (`side_start_block_message`,
  codex-rs/tui/src/app/side.rs:610-618). Parent-busy is not checked.
- The fork reads the parent's persisted rollout file, appended as the
  turn streams (codex-rs/core/src/thread_manager.rs:1188).
- The side fork uses `ForkSnapshot::Interrupted`
  (codex-rs/app-server/src/request_processors/thread_processor.rs:4792):
  if the snapshot ends mid-turn, append the same `<turn_aborted>` marker
  a real interrupt produces, so the fork reads the unfinished turn as
  abandoned rather than pending.

claude-agent-acp gives us the same behaviour without any help. The live
probe forked while the parent was working through a slow read-only task.
The fork returned a working session, inherited the planted token, and
when asked whether it was in the middle of anything, said: "this side
conversation has no task in progress; the .el file review belongs to the
parent conversation."

So the boundary needs no interrupted-turn clause, and there is no busy
guard to add. Also note the process shape that made this safe: each shell
creates its own ACP client and agent subprocess (agent-shell.el:4715 and
:487), so a fork never queues behind the parent's in-flight prompt.

### What the live run did find

A conversation that has never taken a turn cannot be forked.
claude-agent-acp answers `session/fork` with `-32002 Resource not found`:
a session id exists from `session/new`, but there is no transcript to
fork yet.

`agent-shell-side` did not notice. It created the shell, the fork errored,
no session was ever selected, and the buffer sat there taking input that
went nowhere. Two live probes forked a freshly started parent and failed
this way, and one of them passed anyway, because "the side conversation
stayed open" is true of a dead one too.

Fixed in two places. `agent-shell-side--watch-startup` closes the fork and
says why when an error arrives before any session is selected, which
covers this cause and any other. The harness now routes every fork
through `agent-shell-side-live--fork`, which fails loudly when the fork
never reaches a prompt, so a dead fork can no longer be reported as a
pass.

Codex refuses the same case up front, keyed off its own error text
("includeTurns is unavailable before first user message",
codex-rs/tui/src/app/side.rs:620-629). A pre-flight refusal would be
better UX than closing after the fact. It needs a reliable way to ask
"has this conversation taken a turn", which `agent-shell` does not
expose; `shell-maker-history` scrapes the buffer and is unreliable at
prompt boundaries. Left as a follow-up.

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

Adopted: one new command, `agent-shell-side-list`, offering the open side
conversations through `completing-read`, each labelled with its parent,
the parent's state, and its age. Unbound by default, documented in the
README, discoverable via `M-x`.

Revised while building: this started as a `tabulated-list-mode` buffer.
Bill asked for completion instead, which is also what
`agent-shell-side-resume` already uses, so the package now picks the same
way everywhere. Labels are de-duplicated before being offered, since
`completing-read` answers with a string and two side conversations
sharing a name and a parent would collapse into one reachable candidate.

Scope, also on Bill's ask, is both: from a shell it offers that
conversation's own side ones, from a side conversation its siblings, and
anywhere else, or with a prefix argument, all of them. The unscoped
listing is the only one that reaches a side conversation whose parent was
killed, since nothing records which session an orphan came from.

## 4. Nesting (a side conversation of a side conversation)

Decision: keep the one-hop limit for now.

`agent-shell-side--parent-shell` (agent-shell-side.el:615-616) refuses to
fork from inside a side conversation. This matches Codex.

The link record schema already supports chains with no change: a record's
`:parent-session-id` could itself be another record's `:side-session-id`,
and `agent-shell-side-links-for-parent` filters on that field alone. So
nothing needs restructuring to keep the option open.

Do not build it now. Nesting multiplies the surface that took a live run to
pin down: boundary instruction composition across N hops, N link records, N
accumulating buffers. The one-hop case is only now proven, and the live run
found a fork failure mode nobody had predicted, so prove this shape in real
use before adding another.

If real usage later shows the need, the likely change is not a nesting
concept but deleting the one-hop guard. The boundary prompt is already
hop-agnostic: "everything before this boundary is inherited history ...
reference context only" holds regardless of how many forks produced that
history.

## Order of work

1. Item 1's live test file, including the item 2 probe. It is the
   instrument everything else depends on. Built: `tests/live/`, run by
   `make live-check`. Byte-compiles clean and loads against the real
   stack. Not yet run against an agent, so no probe result exists yet.
2. Item 2: answered by the live run. Forking mid-turn is safe and needs
   no code. The run also found the turn-less fork bug, now fixed.
3. Item 3's `agent-shell-side-list`, independent of the others. Built.
   Writing it surfaced three latent bugs sharing one cause:
   `agent-shell-side-buffer-p` read the parent link, which is cleared
   when the parent is killed, so an orphaned side conversation stopped
   counting as one. It could not be dismissed, wore the parent's mode
   line lighter, and could have nested. A buffer-local marker set at link
   time and never cleared fixed all three.
4. Item 4: nothing.
