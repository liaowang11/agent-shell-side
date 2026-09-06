# Design: open work for agent-shell-side

Status as of 2026-09-06. `make check` is green (99 ERT tests against stubs)
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

Fixed in three places.

`agent-shell-side--conversation-started-p` refuses up front, as Codex
does (keyed there off its own error text, "includeTurns is unavailable
before first user message", codex-rs/tui/src/app/side.rs:620-629). I had
first written this off, on a note that `shell-maker-history` is
unreliable at prompt boundaries. Bill pushed back, and measuring settled
it: a fresh shell reads 0 exchanges while already holding a session id, a
shell with one turn reads 1. The note was about a harder question, which
prompt is at point, not whether the history is empty at all.

Measuring also found the trap in the obvious version of the guard. A
resumed shell reads 0 exchanges too, because resuming replays nothing
into the buffer, yet forking one demonstrably works and inherits the
history. So the guard passes a shell that was resumed by id, read through
`agent-shell-side-compat-resumed-p`. Keying only on the buffer would have
refused a fork that works.

`agent-shell-side--watch-startup` stays as the backstop, closing the fork
and repeating the agent's error when a session never gets selected. The
guard covers the cause we know; this covers the rest.

The harness routes every fork through `agent-shell-side-live--fork`,
which fails loudly when a fork never reaches a prompt, so a dead fork can
no longer be reported as a pass, and a probe covers both halves of the
refusal.

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

## 5. Review of 2026-09-06

A read of the package against agent-shell 0.75.2, Codex at 2df67054,
Claude Code's `/btw`, and ChatGPT's branch feature. Six decisions, all
Bill's, and what each changed.

1. **Handback into a busy parent.** `agent-shell-insert` refuses while a
   turn runs, so the summary was lost with an opaque subscriber error, and
   the README promised the opposite. Decision: never send on the user's
   behalf and never use the minibuffer, since a conclusion is long; insert
   it where the user writes and let them send, queue, or steer. With
   `agent-shell-prefer-viewport-interaction` that is the parent's compose
   buffer, opened with `:edit t` so a busy parent still takes it. Otherwise
   it is the shell prompt, which a busy shell cannot take:
   `shell-maker--output-filter` inserts at `point-max`, so staged text
   would be swallowed by the streaming response, which is why upstream
   refuses. The parent prints its prompt and clears busy in
   `shell-maker-finish-output` before emitting `turn-complete`, so the
   findings wait for the first parent event that finds it idle, then land
   at the prompt. The side conversation stays open, marked pending, until
   then; a parent that closes first leaves it as it was.

   A first cut queued through `agent-shell--prompt-queue-read` with the
   summary prefilled in the minibuffer. Bill rejected it: the conclusion is
   normally large, and the minibuffer is no place to review it.
2. **A resumed side conversation was not one.** `agent-shell-side-resume`
   never set the marker, so the buffer had no keys, no lighter, no place
   in the listing, and could nest. Decision: mark it a side with no parent,
   the shape an orphan already has. Marking is now `--mark-side`, shared
   with `--link`.
3. **Kept records were never removed.** `agent-shell-side-links-remove`
   had no callers. Decision: consume the record on resume. That is the one
   point the package knows it was used, and a later `keep` records it
   afresh.
4. **The parent's `systemPrompt.append` was dropped.** Decision: keep it
   ahead of the side text, as Codex keeps its developer instructions. Not
   a boundary-version bump: the side text is unchanged, and a stale mark
   would claim two side policies apply when they do not.
5. **Default disposal.** `ask` put a y-or-n-p on every close. Decision:
   `delete`, matching Codex's ephemeral thread; `keep` is one customize
   away.
6. **Viewport.** `agent-shell--fork-shell-buffer` honours
   `agent-shell-prefer-viewport-interaction` and a viewport origin; this
   package always showed a raw shell. Decision: mirror it for display
   only. The handback still lands in the parent's shell buffer.

Without a decision: preconditions now run before the question is read,
as Codex's `side_start_block_message` does; the parent-status echo needs
the side buffer on screen; the dismiss prompt no longer names a `/side`
command Emacs does not have; the test stub's `agent-shell-insert` refuses
a busy target as the real one does, which is what had hidden item 1.

Deferred, deliberately: a fork-at-point variant (`agent-shell-fork-at-point`
exists upstream) and a `/btw`-style no-tools single-turn question. Both are
new features, not fixes.

## 6. Review of PR #1, 2026-09-06

The review of the section 5 work found five defects, three of them
introduced by that work and two in the paths it touched. All are fixed
on the same branch.

A second review of those fixes found that two of them were themselves
wrong, one dangerously so. Both are recorded in place below rather than
as a separate list, since what matters is the fix that stands. The
lesson worth keeping: every wrong fix here came from assuming an
upstream event meant what its name suggested, instead of reading where
it is emitted.

1. **Closing the side made the viewport handback unsendable.** The close
   path re-displays the parent when it has no window, which under
   viewport interaction is the normal state. That re-entered
   `agent-shell-viewport--show-buffer` with nothing to append, taking the
   branch that flips the compose buffer to read-only view mode. The
   findings landed and were immediately stranded. The draft is not
   snapshotted on that transition; the only snapshot write in that file
   guards history-ring navigation. Fix: `--close` takes a `parent-shown`
   argument, set by the handback when delivery already put the parent in
   front of the user.

   The first test for this passed against the unfixed code twice over:
   once because the parent still owned a window in the test, and once
   because the shared conclude helper stubbed `--display` out entirely.
   Both are now explicit in the test.

2. **The side commands were unreachable from a viewport.** The mode was
   enabled on the shell buffer only, and viewport users sit in the
   viewport buffer. Fix: `--this-shell` resolves a viewport buffer to its
   shell, and every command, plus the lighter, reads through it.

   The first attempt also mirrored the minor mode onto the viewport
   buffer, to bind the keys there. That was wrong, and worse than the bug
   it fixed. `agent-shell-viewport-edit-mode-map` already binds `C-c C-k`
   to discard the draft and `C-c C-q` to queue it, and a minor-mode map
   outranks a major-mode one, so mirroring turned cancelling a draft into
   deleting a forked session. It also did not survive: the mode is not
   `permanent-local`, and the viewport changes major mode in place on
   every send, so the keys vanished after the first one anyway. The mode
   is now never enabled in a viewport buffer, and the README says to use
   `M-x` or bind the commands yourself.

   `--this-shell` also guards its result. `agent-shell-shell-buffer` falls
   back to the first shell in the project when a viewport cannot be
   matched to its own shell, which a renamed shell buffer causes, so the
   resolved shell is accepted only when it really is one end of a side
   conversation.

3. **An errored parent turn stranded the findings forever.** `error` is
   emitted before the shell clears its busy state, which upstream states
   in a comment at `agent-shell.el:7442`, and nothing follows it. The
   idle test therefore never fired and `conclude` refused from then on.
   Fix: on `error`, defer the test to the next timer tick, since the
   clearing happens in the same call right after the event is dispatched.

4. **The README described a mode-line marker that did not exist.** The
   pending flag was read only by the `conclude` guard. Fixed by building
   it: the lighter now reads " Side:findings waiting", and pending
   outranks parent status, which would otherwise say the same thing twice.

5. **Resume dropped the record before the session was known to load.**
   `session/load` is still in flight at that point, so an agent that
   rejected it left a shell talking to nothing and no record to retry
   from.

   The first attempt keyed off `session-selected` and kept the record on
   `error`. Both halves were wrong. `session-selected` is emitted *before*
   the load request is sent (`agent-shell.el:8146`), so it dropped the
   record just as early as before. And a rejected load never emits
   `error`: its `:on-failure` (`agent-shell.el:8827`) says "Couldn't
   resume session. Starting a new one." and falls back to loading a
   different one, so the `error` branch was dead code for the case it was
   written for.

   The signal that actually means the transcript came back is
   `session-restored`, emitted once the shell has settled
   (`agent-shell.el:8768`). Because the failure path can itself restore a
   *different* session, the record is dropped only when the shell's
   session id matches the record's.

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
