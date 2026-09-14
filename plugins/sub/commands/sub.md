---
description: Delegate a task to a new interactive Claude Code session in a sibling Herdr pane.
argument-hint: "[--model <model-id>] <task prompt>"
allowed-tools: [Bash]
---

# sub

Start a **full interactive Claude Code session** in a sibling Herdr pane and hand
it the task below. Unlike a subagent, the user can talk to it directly in its pane;
it reports back here by cross-session message when it is done.

Session facts, already resolved — do not look any of this up again:

!`"${CLAUDE_PLUGIN_ROOT}/scripts/sub-facts.sh"`

If that block says `PRECONDITION_FAILED`, tell the user and stop.

## What to do

Make **exactly one** tool call: a single Bash call that spawns the sub. The script
writes the briefing, splits the pane and starts the session in one shot.

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/sub-spawn.sh" --name <name> [--model <model-id>] <<'BRIEF'
<task prompt, verbatim>

<context the sub cannot discover on its own>
BRIEF
```

- `--name` — use `suggested_name` from the facts block unless a task-descriptive
  name is clearly better. Must match `[a-z][a-z0-9_-]{0,31}`.
- `--model` — pass it **only** if `$ARGUMENTS` contains `--model <model-id>`; strip
  that pair from the prompt text. Otherwise omit it and the script reuses this
  session's exact model.
- Everything else in `$ARGUMENTS` is the task prompt. Reproduce it verbatim at the
  top of the heredoc. Do not rewrite or summarise it.
- Below the prompt, add the context the sub cannot discover on its own: what the
  user already decided, files already inspected, constraints from this
  conversation, premises it must not re-litigate. The sub starts with an empty
  context — anything you leave out it will rediscover or get wrong. Skip this only
  when the prompt is genuinely self-contained.

Do not call `ListAgents`, do not run `herdr pane split` or `herdr agent start`
yourself, and do not write the briefing file with `Write`. The script does all of
it, and doing it by hand is what this command exists to avoid.

## Then stop

Report the sub's name and pane to the user in one line, and that they can talk to
it directly there. Then **stop**.

Do not poll `ListAgents`, do not send the sub "are you done?", and do not run
`herdr agent wait`. There is no ack — the script's `SUB_STARTED` output is the
proof that the chain works. The sub sends exactly one message when it finishes,
and that arrives on its own as a `<cross-session-message>` that wakes this session.

When it does arrive: read it, act on it, and reply only if you have something new
to say. An acknowledgement message is a wasted turn on both sides.

## Talking to the sub afterwards

Its message carries its nickname in the wrapper's `from-name`. Use that bare
nickname as `to:` for `SendMessage` — that is the channel in both directions.

`herdr agent prompt <name> "<text>"` is a fallback only; it types into the pane and
can collide with the user typing there. Control commands
(`herdr agent read|get|focus <name>`) stay valid for inspecting the pane.

## The task

$ARGUMENTS
