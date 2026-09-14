---
name: delegate
description: "Hand a piece of work to a new interactive Claude Code session in a sibling Herdr pane — one the user can talk to directly, unlike a subagent. Use when the user asks you to spawn, delegate to, or hand something off to a sub, or tells you to split work across sub-sessions; and when a task is large enough that the user will want to steer part of it in its own pane while you carry on here. Not for ordinary background work — the Agent tool covers that. Requires HERDR_ENV=1."
---

# delegate

This is how **you** start a sub-session on your own initiative. (The user's own
route is `/sub:spawn`, which starts one without costing you a turn at all — if the
user typed that, you are not in this skill.)

A sub is a full interactive Claude Code session in a sibling pane. Unlike a
subagent it has its own transcript, its own permissions and its own human: the
user can sit in its pane and steer it. It reports back here by cross-session
message when it finishes.

## Spawning

One Bash call per sub. The script resolves this session's nickname and model,
writes the briefing, splits a pane and starts the session:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/spawn.sh" --name <name> [--model <id>] <<'BRIEF'
<the task>

<the context>
BRIEF
```

- `--name` — `[a-z][a-z0-9_-]{0,31}`, unique among live agents. Task-descriptive
  beats `sub-1` when you are running several: `sub-parser`, `sub-migration`.
- `--model` — omit it and the sub inherits this session's exact model id. Pass it
  only when the user asked for a different one, or when the work is clearly
  cheaper than this conversation.
- Spawning several at once is fine and is the point — one call each. Give each one
  a slice that does not need the others' output; they cannot see each other.

Do not call `ListAgents`, do not run `herdr pane split` or `herdr agent start`,
and do not write the briefing file yourself. The script is the only supported way
a sub gets created, and it records the spawn so nothing is lost if this
conversation is compacted.

## The briefing is the whole job

The sub starts with an empty context. Everything this conversation knows and the
briefing omits, it will rediscover at cost or get wrong. Put in:

- The task, concretely — what to change, and what "done" looks like.
- What the user already decided, and what is therefore settled.
- Files, functions and paths already identified here, with their paths.
- Constraints, conventions and gotchas that came up in this conversation.
- What is explicitly out of scope, so it does not widen the work.

Do not hedge the task into vagueness, and do not pad the briefing with
restatements. Write it the way you would brief a competent colleague who just
walked in.

## After spawning

Tell the user which subs you started and in which panes. Then carry on with your
own work, or stop.

Do not poll `ListAgents`, do not send "are you done?", and do not run `herdr agent
wait`. There is no ack — the script's `SUB_STARTED` output is the proof the chain
worked. Each sub sends exactly one message when it finishes, which wakes this
session on its own.

When a report arrives: read it, act on it, and reply only if you have something
new to say. Its nickname is in the wrapper's `from-name`, and that bare nickname
is the `to:` for `SendMessage` from then on. Before the sub's first message you
have no nickname for it — use `herdr agent prompt <name> "<text>"` if you must
reach it earlier.

## When it fails

`SUB_START_FAILED` with `agent_not_ready` almost always means Claude Code's
folder-trust dialog for a cwd the user has never accepted. That is the user's
decision. Tell them which pane is waiting; do not answer it for them.
