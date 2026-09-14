---
description: Delegate a task to a new interactive Claude Code session in a sibling Herdr pane.
argument-hint: "[--brief] [--model <id>] [--name <id>] <task>"
allowed-tools: [Bash, SendMessage]
---

# sub:spawn

You are reading this because the invocation carried `--brief`, or because the
expansion hook could not run. Either way the sub is the point, not this text.

State of the spawn the hook just performed:

!`"${CLAUDE_PLUGIN_ROOT}/scripts/last-spawn.sh"`

## If that block names a sub

It is already running, and it has been told that you are composing context for it
and to hold off on committing to an approach until your message lands. It is
waiting on you right now.

Send it **one** `SendMessage`, addressed to the `sub_nickname` in the block above.

Use `SendMessage` and nothing else. Never pass this context through a shell
command line — not `herdr agent prompt`, not `echo`, not a heredoc into any
command. The context you are about to send quotes files and this conversation, so
it will contain backticks, `$(...)`, quotes and backslashes, all of which a shell
would execute rather than deliver. `SendMessage` takes the text as a parameter, so
there is no shell to escape. If `sub_nickname` says `unresolved`, say so and stop
rather than reaching for a shell.

Put in it what the one-line task could not carry and the sub cannot discover on
its own:

- What the user already decided, and what is therefore not up for re-litigation.
- Files, functions and paths already identified in this conversation.
- Constraints, conventions and gotchas that came up here.
- What "done" looks like, and anything explicitly out of scope.
- Any premise in the one-line task that is incomplete or misleading.

Be specific and concrete. The sub starts with an empty context: anything you leave
out it will rediscover at cost, or get wrong. Do not pad it with restatements of
the task — it has that.

Then tell the user, in one line, which sub you briefed and what you sent. Then
**stop**. Do not poll it, do not ask whether it is done, do not run `herdr agent
wait`. It reports back here by cross-session message when it finishes.

## If that block says NO_SPAWN

The hook did not run, so nothing has started yet and you must do the spawn
yourself. One Bash call:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/spawn.sh" --name <suggested_name> [--model <id>] <<'BRIEF'
<the task from $ARGUMENTS, verbatim, with --brief and --model stripped>

<the context described above>
BRIEF
```

The script writes the briefing, splits the pane and starts the session. Do not
call `ListAgents`, do not run `herdr pane split` or `herdr agent start` by hand,
and do not write the briefing with `Write` — that is the whole cost this command
exists to remove. Report the sub's name and pane to the user, then stop.

## When the sub's report arrives

Read it, act on it, and reply only if you have something new to say. An
acknowledgement is a wasted turn on both sides. Its message carries its nickname
in the wrapper's `from-name`, which is the same address as `sub_nickname`.

## Invocation

$ARGUMENTS
