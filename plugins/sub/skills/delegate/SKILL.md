---
name: delegate
description: "Hand a piece of work to a new interactive Claude Code session in a sibling Herdr pane — one the user can talk to directly, unlike a subagent. Use when the user invokes /sub:delegate, asks you to spawn, delegate to, or hand something off to a sub, or tells you to split work across sub-sessions; and when a task is large enough that the user will want to steer part of it in its own pane while you carry on here. This is the path for a task that leans on the current conversation, because you write that context into the sub's briefing. Not for ordinary background work — the Agent tool covers that. Requires HERDR_ENV=1."
---

# delegate

Start a sub-session whose briefing you write. The user reaches this as
`/sub:delegate <task>`; you also load it on your own initiative when asked to hand
work off.

A sub is a full interactive Claude Code session in a sibling pane. Unlike a
subagent it has its own transcript, its own permissions and its own human: the
user can sit in its pane and steer it. It reports back here by cross-session
message when it finishes.

## When this, and when /sub:spawn

`/sub:spawn` costs no turn at all: a hook does the spawn and the task text becomes
the briefing verbatim. That is the right door for a task that stands on its own —
"bump the deps and run the suite".

This skill costs one turn and spends it writing the briefing. That is the right
door whenever the task leans on this conversation — "tidy the parser module" means
nothing to a session that has never seen it. The context goes into the briefing
file, so the sub reads it up front and still has it after a compaction.

If the user typed `/sub:spawn` for a task that clearly needed context, the sub is
already running and knows only its one line. Do not spawn a second one: the relay
gives you its `address`, so send it what it is missing with `SendMessage`.

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
- Spawning several at once is fine and is the point — one call each, in one
  message so they run concurrently. Give each one a slice that does not need the
  others' output; they cannot see each other.

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

The call returns as soon as the pane exists and the briefing is written —
`SUB_STARTING`. The new session's boot is deliberately not waited on, so that
output is proof the pane and briefing are real, not that the session reached a
prompt. Its outcome and its messaging address arrive here through the relay on
your next turn, and it reports by message when it finishes.

Tell the user which subs you started and in which panes. Then carry on with your
own work, or stop.

Do not poll `ListAgents`, do not send "are you done?", and do not run `herdr agent
wait`. There is no ack.

When a report arrives: read it, act on it, and reply only if you have something
new to say. Its nickname is in the wrapper's `from-name`, and that bare nickname
is the `to:` for `SendMessage` from then on.

Anything you send a sub goes through `SendMessage`, never a shell command line: it
quotes files and this conversation, so it will contain backticks, `$(...)` and
quotes that a shell would execute instead of deliver. `SendMessage` takes the text
as a parameter and has no shell to escape.

## When it fails

`FAILED TO START` from the relay means no agent ever appeared in the pane, and the
user gets a herdr notification at the moment it happens. Same for a sub reported
as waiting at a dialog — folder trust for a cwd they never accepted, or a
permission request. Both are their decision: tell them which pane is waiting, do
not answer it for them, and do not spawn a replacement.

A sub reported as started but never seen at an idle prompt is neither of those.
It is running, most likely already working on its briefing. Take it as started.
