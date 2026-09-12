# Design: open work for agent-shell-side

Status as of 2026-09-06. `make check` is green (107 ERT tests against stubs).
`make live-check` last passed 10 of 10 against a real claude-agent-acp 0.70,
before the handback moved to a compose buffer; its probes were updated to
match but have not been re-run against an agent since.

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

It took three rounds to get there. A review of the fixes found two of
them wrong, one dangerously so; a review of *those* found the
replacement for item 5 wrong again. Each wrong version is recorded in
place below rather than as a separate list, since what matters is the
fix that stands and why the obvious alternatives do not.

One lesson runs through all of them: every wrong fix came from trusting
an upstream event to mean what its name suggests. `session-selected`
does not mean a session was loaded. `session-restored` does not mean a
session came back. The only reliable move is to read the emission site
and what runs either side of it.

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
   pending flag was read only by the `conclude` guard. It was built --
   the lighter grew a " Side:findings waiting" arm -- and then removed
   again with the rest of the wait-for-idle machinery once the handback
   became a compose buffer. Nothing is ever pending now, so there is
   nothing for a marker to say.

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

   The second attempt keyed off `session-restored`, which was wrong in
   the opposite direction. That event does not mean "the session came
   back"; it means a buffered transcript was replayed, and the buffering
   only happens when `agent-shell-session-restore-verbosity` asks for one
   (`agent-shell.el:8789`, guarded by `--has-pending-restore-p`).

   Its default is `minimal`, which for this package's primary agent means
   nothing is ever buffered and the event never fires. Note the condition
   rather than just the default, because it is narrower than it looks:
   `agent-shell--effective-restore-verbosity` (`agent-shell.el:8566`)
   promotes `minimal` to `first-last` for an agent that can load a session
   but not resume one, and `session-restored` does fire for those.
   claude-agent-acp advertises `resume`, so it is in the group where the
   event never arrives. Worse than the original bug: the
   next resume would offer a session already deleted, and agent-shell
   answers a rejected load by quietly loading a different one, which this
   package would then mark as the side conversation. The user would
   silently get the wrong conversation.

   What holds is `prompt-ready`. It is emitted when the init pipeline
   finishes (`agent-shell.el:2561`) on every path -- a load that worked,
   a load that failed and fell back, a plain new session -- and always
   after the session id is written into the shell's state
   (`agent-shell.el:8810`, before `--finalize-session-init`). Since a
   rejected load is never surfaced as an error, the id is compared rather
   than the event trusted: a shell that came back as anything else keeps
   its record.

   The test for this was wrong too, in a way worth naming. It set the
   package's own session-id cache, which only the fork path ever fills; a
   resumed shell reads its id from agent-shell's state. The test was
   passing against a source the real path never uses.

## 7. Where it is shown, and one handback path

Two changes from using the thing, 2026-09-06.

### Beside the parent, not instead of it

The package had no display option of its own: it reused
`agent-shell-display-action`, whose default is
`display-buffer-same-window`, so a side conversation took over the
parent's window and toggling swapped them. That is Codex's behaviour
because a terminal has one pane. Emacs does not, and the whole appeal of
a side conversation is reading it next to what it forked from.

`agent-shell-side-display-action` now defaults to a window on the right.
Kept separate from `agent-shell-display-action` deliberately: pointing
that one at a side window would move every shell, not just these.

Three things had to move with it, all found by pointing a side-window
action at the old code rather than by reading it:

- **Closing put the parent into the side window.** The close path handed
  the side's window to the parent, giving `((PARENT right) (PARENT nil))`
  -- the parent displayed twice, once in a strip meant for something
  else. A side window is scenery for what it holds, so it is now deleted
  with the conversation.
- **Toggling duplicated the side.** With both visible it gave
  `((SIDE nil) (SIDE right))`, the parent nowhere. Toggle now selects the
  other window when both are on screen. When they are not, it displays
  through the action, which reproduces the old swap exactly when that
  action is `display-buffer-same-window` -- so the old behaviour is still
  one setting away and needs no special case.
- **`delete-other-windows` signals** while a side window is selected
  ("Cannot make side window the only window"). That is why the test
  helper deletes side windows before calling it.

The parent is displayed through `agent-shell-display-action`, not the
side action. It is an ordinary shell.

Under viewport interaction the action is not consulted at all. The
viewport owns its layout, and a compose buffer wedged into a side window
is not an improvement.

### One handback path

The handback had two shapes. Under viewport interaction the findings went
straight into the parent's compose buffer, which takes text mid-turn.
Otherwise they went to the shell prompt, which does not, so a busy parent
meant holding the findings, a pending flag, a mode-line marker, a
deferred re-check to work around `error` arriving before the busy flag
clears, and the side conversation closing itself at whatever moment the
parent's turn happened to end.

All of that is gone. The findings always go to a compose buffer.

The argument for it is not just that it is less code. That setting
decides where the *user's own prompts* go; it has no business deciding
what happens to findings, and letting it do so gave the two settings
visibly different commands for the same task. The compose buffer is also
strictly better than waiting: it takes the text immediately, mid-turn,
and hands back the three answers that matter from its own keys -- send,
queue behind the running turn, or steer into it. Waiting could only ever
offer the first, and only later.

Removed with it: `agent-shell-side-handback-submit`, which had become a
setting that could not do anything, since sending is now the compose
buffer's business rather than ours.

Review of that change found four more, three of them real:

- **`conclude` signalled from a compose buffer.** `agent-shell-insert`
  dispatches on the *current* buffer, not the target: from a viewport it
  routes into `agent-shell-viewport--show-buffer`, whose first two lines
  reject `:submit` and `:no-focus` with "Not yet supported". So asking
  the side conversation for its summary failed exactly where the compose
  buffer had just become the routine place to stand. The subscription and
  its 180s timer were already installed, so the user saw nothing for
  three minutes and then "no summary after 180s". Both call sites now go
  through `agent-shell-side-compat-send-to-shell`, which addresses the
  shell buffer directly. The stub had hidden this by not dispatching at
  all; making it faithful also failed an existing viewport test that had
  been passing vacuously.
- **The handback downgraded a queued draft to a steer.**
  `agent-shell-viewport--show-buffer` writes the compose disposition on
  every call, nil included, by design. Appending findings to a prompt the
  user had marked `queue` reset it, so `C-c C-c` fell through to
  `agent-shell-prompt-while-busy`, whose default is `steer` -- their
  queued follow-up would have been injected into the running turn.
  The disposition of an in-progress draft is now read first and handed
  back.
- **The new side-window arm in `--close` was dead.**
  `display-buffer-in-side-window` dedicates the window, so `kill-buffer`
  has already deleted it via `replace-buffer-in-windows`. Verified: the
  predicate was never called, and its test passed anyway because Emacs
  did the work. The arm and `agent-shell-side--side-window-p` are gone;
  the test stays, since it asserts the outcome.
- Not a defect: the compose buffer is selected when the summary lands,
  which the old `:no-focus` path never did. That is the point of the
  change, but it is a visible difference for every user, so the README
  now says so.

The recurring lesson holds, in a third form. It was not enough to read
what an upstream function does; this one dispatches on ambient state, so
the same call means different things depending on where the user is
standing.

## 8. On screen means the shell or its viewport, 2026-09-12

Two reports from using section 7 under viewport interaction: the side
opened beside the parent's window rather than at the frame's edge, and
toggling left the parent showing twice. Both had one cause. Every
"is it on screen" question asked after the shell buffer, and under
viewport interaction the shell buffer is never on screen; its viewport
is. So toggle found nothing and re-displayed, close found nothing and
re-displayed, and the side action was skipped outright on that path.

1. **One notion of "on screen".** `--window` returns the window showing a
   shell buffer or its existing viewport. Toggle selects it when it
   exists. Close selects the parent's window when it exists instead of
   re-showing the parent, which under viewport interaction re-entered the
   viewport show with nothing to append, the path section 6 item 1
   identified as flipping a compose buffer to view mode. The
   fork-teardown path shares the helper.

2. **Ordinary windows are settled, not just side windows.** Section 7
   relied on `display-buffer-in-side-window` dedicating the window so
   `kill-buffer` deletes it. Any other action leaves the window standing,
   and handing it to a parent already on screen shows the parent twice.
   `--kill-and-hand-back` deletes the window when the parent is visible
   and deletable, and gives it to the parent otherwise. "Parent visible"
   is decided before the kill: afterwards the window shows some previous
   buffer, which under same-window display is the parent itself.

3. **The side action applies to the viewport too.** Section 7 said the
   viewport owns its layout. In practice that meant a viewport user had
   no package-level say in where a side lands, since the viewport show
   ends in `agent-shell--display-buffer`, which reads
   `agent-shell-display-action`. That is a user option, so binding it to
   the side action around the show is legitimate and needs no new
   internals. The parent's viewport is still shown through the ordinary
   action.

4. **A condition for `display-buffer-alist`.** The package cannot and
   should not win over a user's `display-buffer-alist`; that is the
   Emacs contract, and users who route buffers through a popup manager
   are exactly the ones who hit the first report. What the package owes
   them is a way to name side conversations in a rule.
   `agent-shell-side-buffer-p` now takes a buffer or name and recognizes
   a side conversation's viewport. The viewport is matched exactly, by
   asking each side conversation for its own viewport, not through
   `agent-shell-shell-buffer`, whose fallback to the first shell in the
   project would make an unrelated viewport pass for a side one.

Not done here, listed for the next change: a hook run before a side or
parent is displayed, for layouts that live in perspectives or tabs, and
a way for resume to rebuild the right config when several share an
identifier.

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
