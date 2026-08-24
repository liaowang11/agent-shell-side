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
| `agent-shell-side-dismiss` | `C-c C-k` | Close the side conversation and return to the parent |
| `agent-shell-side-resume` | | Reopen a side conversation that was kept |
| `agent-shell-side-describe` | | Echo what this buffer is and how to leave it |

While you are in the side conversation, the parent keeps running. When it
finishes, fails, or asks for approval, the side conversation's mode line says so
(` Side:main needs approval`) and echoes it once. Set
`agent-shell-side-report-parent-status` to nil for the mode line only.

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

## Development

```sh
make check   # byte compile, then run the tests
make test
```

Tests run against stubs in `tests/support`, so no agent process is started.

## License

GPL-3.0-or-later.
