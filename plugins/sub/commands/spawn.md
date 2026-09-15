---
description: Delegate a task to a new interactive Claude Code session in a sibling Herdr pane.
argument-hint: "[--model <id>] [--name <id>] <task>"
allowed-tools: [Bash]
---

# sub:spawn

The expansion hook normally does this whole command and blocks, costing no model
turn. If you are reading this, the hook did not run — older CLI, or hooks disabled
by policy — so nothing has started and the spawn is yours to do.

State of play:

!`"${CLAUDE_PLUGIN_ROOT}/scripts/last-spawn.sh"`

## If that block says NO_SPAWN

Do the spawn. One Bash call:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/spawn.sh" --name <suggested_name> [--model <id>] <<'BRIEF'
<the task from $ARGUMENTS, verbatim, with --model and --name stripped>

<context from this conversation that the task text does not carry>
BRIEF
```

You are spending a turn either way, so use it: the heredoc is the sub's whole
briefing and it starts with an empty context. Add what it cannot discover — files
and paths already identified here, what the user already decided, constraints and
gotchas that came up, what "done" looks like, what is out of scope. Anything you
leave out it will rediscover at cost, or get wrong. Do not pad it with
restatements of the task.

The script writes the briefing, splits the pane and starts the session. Do not
call `ListAgents`, do not run `herdr pane split` or `herdr agent start` by hand,
and do not write the briefing with `Write` — that is the whole cost this command
exists to remove.

The call returns as soon as the pane exists; the session boots on its own and its
outcome reaches you through the relay. Report the sub's name and pane to the user,
then stop. Do not poll it, do not ask whether it is done, do not run `herdr agent
wait`.

## If that block names a sub

The hook ran after all and already started it. Say so and stop — do not spawn a
second session for the same task.

## When its report arrives

Read it, act on it, and reply only if you have something new to say. An
acknowledgement is a wasted turn on both sides. Its nickname is in the wrapper's
`from-name`, and that bare nickname is the `to:` for `SendMessage` from then on.

## Invocation

$ARGUMENTS
