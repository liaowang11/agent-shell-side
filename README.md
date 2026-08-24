# agent-shell-side

Ask a quick question without derailing the conversation you are in.

`M-x agent-shell-side` forks the current [agent-shell](https://github.com/xenodium/agent-shell)
session into a second shell whose inherited history is demoted to reference
material. The agent can still read everything that came before, so the question
needs no re-explaining, but it is told not to continue the parent's task, not to
touch sub-agents, and not to change anything unless this conversation asks.

Modelled on the `/side` command in OpenAI's Codex TUI.

## Install

Needs `agent-shell` 0.74.3 or newer and `acp` 0.13.1 or newer.

```elisp
(use-package agent-shell-side
  :after agent-shell
  :bind (:map agent-shell-mode-map
         ("C-c C-b" . agent-shell-side)))
```

Once a side conversation exists, `agent-shell-side-mode` turns on in both
buffers and binds its own keys, so the binding above is only needed to start
one.

## Commands

| Command | Key (in linked buffers) | What it does |
| --- | --- | --- |
| `agent-shell-side` | | Fork this conversation into a side one and switch to it |
| `agent-shell-side-toggle` | `C-c C-b` | Switch between the side conversation and its parent |
| `agent-shell-side-conclude` | `C-c C-q` | Summarise the side conversation into the parent, then close it |
| `agent-shell-side-dismiss` | `C-c C-k` | Close the side conversation, discarding what it learned |
| `agent-shell-side-resume` | | Reopen a side conversation that was kept |
| `agent-shell-side-list` | | Switch to one of the side conversations that are open |
| `agent-shell-side-describe` | | Echo what this buffer is and how to leave it |

### Asking about part of an answer

Select the passage in the parent conversation, then run `agent-shell-side`. The
selection is carried in as a markdown block quote and you are asked for your
question, so the side conversation opens pointing at exactly the part you meant.
An empty question opens it blank.

### Carrying findings back

`agent-shell-side-conclude` (`C-c C-q`) asks the side conversation for a summary
addressed to the parent, waits for it, puts it at the parent's prompt, and closes
the side conversation. The summary is left for you to review rather than sent,
because the parent may be mid-turn and dropping an unread block into a working
conversation is the disruption a side conversation exists to avoid. Set
`agent-shell-side-handback-submit` to send it instead.

If the summary comes back empty, or the parent is gone, the side conversation is
left open rather than closed on nothing. Customize
`agent-shell-side-handback-prompt` to change what is asked for.

While you are in the side conversation, the parent keeps running. When it
finishes, fails, or asks for approval, the side conversation's mode line says so
(` Side:main needs approval`) and echoes it once. Set
`agent-shell-side-report-parent-status` to nil for the mode line only.

### Keeping track of what is open

A side conversation lives until you close it, so they collect quietly.
`agent-shell-side-list` offers the ones still open for completion, each labelled
with what it was forked from, how its parent is doing, and how long it has been
sitting there. Picking one switches to it.

It covers every side conversation in this Emacs, across parents and projects,
because that is the scope the problem has. The ones whose parent is already
gone are the easiest to forget, and they are listed too.

Nothing is closed for you. Codex discards its side thread when you navigate to
a third thread; that does not port to Emacs, where switching buffers is
constant and auto-discard would throw away work mid-thought. An idle reaper
would do the same on a timer. So this reports and leaves the decision to you.

## How the restriction works

Two channels carry the side instructions, because no single one reaches every
agent:

1. A **boundary block** prepended to the first `session/prompt`. An ordinary
   content block, so it works with any agent. This is the channel that actually
   carries the policy.
2. **`_meta.systemPrompt.append`** on the fork request, restating the policy at
   system level. Honored by claude-agent-acp; other adapters ignore unknown
   `_meta` keys, which is what `_meta` is for.

Neither is a sandbox. Like Codex's version, the restriction is instruction text
the agent is asked to follow. The full text is in
`agent-shell-side-boundary-prompt` and `agent-shell-side-instructions`.

Both texts cancel the parent's *standing conventions* as well as its task. That
clause is not decoration: against a live claude-agent-acp, a boundary without it
left the fork still obeying an "end every reply with X" rule set in the parent.
The model correctly declined to continue the parent's task, but read a formatting
rule as a persistent convention rather than an instruction the boundary had
cancelled. With the clause, the same probe came back clean.

The inherited turns are hidden from the display, not from the model:
`session/fork` does not replay history, so the side buffer starts empty while
the agent keeps the whole transcript.

## Agent support

Requires an agent that advertises the ACP `session/fork` capability.

| Adapter | `session/fork` | `session/delete` | `_meta.systemPrompt` |
| --- | --- | --- | --- |
| claude-agent-acp | yes | yes | yes |
| pi-acp | yes | yes | no |
| codex-acp | no | yes | no |

An agent without `session/fork` is refused with a message naming it. This
refusal is not cosmetic: when a fork is requested from an agent that cannot do
it, `agent-shell` quietly starts a *new, empty* session instead, and a side
conversation that silently lost its inherited history is worse than an error.

## What happens to the forked session

ACP has no ephemeral session, so a fork always leaves one behind in the agent's
own store. `agent-shell-side-on-dismiss` decides what to do when you close one:

- `delete` — ask the agent to drop it (`session/delete`).
- `keep` — leave it, and record it in `agent-shell-side-links-file` so
  `agent-shell-side-resume` can find it again.
- `ask` (the default) — ask each time.

A kept session is recorded as which fork belonged to which parent, with the
agent identifier and working directory. The identifier matters: resuming
rebuilds the side config from it so the side instructions are re-sent. Agents
read `_meta.systemPrompt` again on resume and would otherwise drop the side
policy.

Records also carry a boundary version. A record written under older instruction
text is still resumable, but says so, since both texts then apply to that
conversation.

## agent-shell internals

Three things this package needs are not in `agent-shell`'s public API: starting
a shell that forks a session with a caller-supplied config, reading whether the
agent advertised `session/fork`, and reading the current session id. All three
live in `agent-shell-side-compat.el` so an upstream change breaks one file. Each
shim checks what it needs and names the missing piece rather than failing deeper
in.

Everything else uses public API: `agent-shell-start`, `agent-shell-get-config`,
`agent-shell-shell-buffer`, `agent-shell-subscribe-to`, `agent-shell-status`,
`agent-shell-interrupt`, and `agent-shell-agent-configs`.

## What has been tested live

Against claude-agent-acp 0.70, end to end:

- `session/fork` returns a new session id, and the fork answers a question that
  only the parent's history could answer, so history is inherited
- the boundary block arrives as a second content block on the first prompt
- the fork describes itself as a side conversation and declines to continue the
  parent's task
- a standing formatting instruction from the parent does *not* leak (it did
  before the standing-conventions clause; see above)
- `session/delete` succeeds

`make live-check` covers the rest, and passes 10 of 10 against
claude-agent-acp 0.70:

- the handback summarises, reaches the parent's prompt staged rather than sent,
  and closes the side conversation
- a handback whose parent is killed mid-summary leaves the side conversation
  open rather than discarding it
- a kept session resumes and still answers from the parent's history
- **forking mid-turn works.** Asked while the parent was in the middle of a
  slow task, the fork answered "this side conversation has no task in progress;
  the .el file review belongs to the parent conversation". It inherits the
  history and does not adopt the unfinished turn, so no extra instruction text
  is needed for it.

One limit the live run found: **a conversation that has not taken a turn cannot
be forked.** claude-agent-acp answers `session/fork` with `-32002 Resource not
found`, because there is no transcript to fork yet. Having a session id is not
enough. The fork is now closed with an explanation when this happens, rather
than leaving a shell whose input goes nowhere. Codex refuses the same case up
front.

## Development

```sh
make check        # byte compile, then run the unit tests
make live-check   # drive a real agent (see below)
```

Unit tests run against stubs in `tests/support`, so no agent process is
started.

`make live-check` is separate on purpose. It starts a real claude-agent-acp,
spends real API tokens, and waits on model output that is not deterministic, so
it has no place in a suite you run on every edit. Run it when the adapter or
ACP version changes, and before tagging a release. It expects the real stack
next door:

```sh
make live-check AGENT_SHELL_DIR=... ACP_DIR=... SHELL_MAKER_DIR=...
```

The probes cover history inheritance, the standing-conventions clause, the
handback (including a parent killed mid-summary), resuming a kept session, and
forking while the parent's turn is in flight. Permissions are answered by a
read-only auto-approver, so an unattended run cannot let the agent change the
checkout it is running in; a probe needing more is left to time out rather than
approved.

## License

GPL-3.0-or-later.
