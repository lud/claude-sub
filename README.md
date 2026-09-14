# claude-sub

A Claude Code plugin for delegating a task to a **new interactive Claude Code
session** in a sibling [Herdr](https://herdr.dev) pane — one you can talk to
directly, unlike a subagent.

It replaces a hand-driven skill that cost five tool calls and a message
round-trip per delegation. `/sub:spawn` now costs the parent **no model turn at
all**: a `UserPromptExpansion` hook intercepts the command, does the whole spawn,
and blocks the expansion. The sub is already reading its briefing before the
parent would have finished reading its instructions.

## Install

```
claude plugin marketplace add ~/src/claude-sub
claude plugin install sub@claude-sub
```

## The three ways a sub gets started

| | who starts it | parent turns |
|---|---|---|
| `/sub:spawn <task>` | the user | **0** |
| `/sub:spawn --brief <task>` | the user | 1, spent entirely on briefing the sub |
| the `delegate` skill | the parent, on its own initiative | 1 |

All three funnel through `scripts/spawn.sh`, which is the only place a sub is ever
created.

### `/sub:spawn [--brief] [--model <id>] [--name <id>] <task>`

Without `--brief`: the hook spawns and blocks. The task text is the briefing,
verbatim. The parent never runs — it finds out on its next turn, from the relay.

With `--brief`: the sub **still starts immediately**, and the only difference is
that the expansion is let through, so the parent gets one turn whose whole job is
to send the sub the context this conversation holds and a one-line prompt could
not carry. The sub's briefing carries a notice telling it exactly that, so it
orients itself but holds off on committing to an approach until the message lands.

Use `--brief` whenever the task leans on the conversation — "tidy the parser
module" means nothing to a session that has never seen it.

### The `delegate` skill

The hook can only fire on something the *user* types, so it would have taken away
the parent's ability to spawn subs on its own. The skill restores it: the parent
loads it when asked to hand work off, and spawns one sub per Bash call — which is
also the path that produces the richest briefing, since the model writes the whole
thing up front.

## How the parent learns things

- **That a sub started** — on its next turn, from the `UserPromptSubmit` relay,
  which drains one note per sub and then forgets them. Not a wake-up, not a
  message: a chunk of context added to a turn that was going to happen anyway.
- **That a sub finished** — one cross-session message from the sub. This one does
  wake the parent, deliberately: the user may type nothing after `/sub:spawn`, and
  the sub's report is then the only thing that can advance the parent's turn.

Subs open their report by naming themselves and their task, because a parent that
spent zero turns spawning them has no memory of doing so.

There is no ack. The spawn is synchronous and its result is known before anything
else happens, so an ack would prove nothing that is not already proven — it would
just be a wake-up and two wasted turns.

## Layering

Every automatic path degrades to a working manual one:

- Hook cannot run (older CLI, hooks disabled by policy) → the command expands, its
  pre-run reports `NO_SPAWN`, and the body spawns the sub through the same script.
- Relay never fires → the parent still learns everything from the sub's report.
- `herdr` or `jq` missing, or `HERDR_ENV != 1` → the spawn refuses with a reason
  rather than half-starting something.

## Layout

```
plugins/sub/
  commands/spawn.md        /sub:spawn  — the --brief turn, and the no-hook fallback
  commands/report.md       /sub:report — update from the sub's pane
  skills/delegate/         parent-initiated spawning
  hooks/hooks.json         UserPromptExpansion (zero-turn) + UserPromptSubmit (relay)
  scripts/spawn.sh         the only place a sub is created
  scripts/spawn-hook.sh    zero-turn entry point
  scripts/relay.sh         next-turn notice, drained once
  scripts/last-spawn.sh    pre-run for the --brief turn
  scripts/parent.sh        pre-run for /sub:report
  scripts/lib.sh           nickname, model, geometry, name allocation
  templates/briefing.md    what the sub reads in its first turn
```

Briefings are written to `$CLAUDE_CONFIG_DIR/sub-tasks/<sub-name>.md`, named after
the sub's own agent name so it can find its briefing again after compaction.
Pending relay notices live in `sub-tasks/.state/<parent-session-id>.jsonl`. Both
directories are created on first use.

`CLAUDE_CONFIG_DIR` is honoured everywhere, falling back to `~/.claude`: the
nickname registry, the transcript the model id is read from, `settings.json`, and
the plugin's own state all follow it. It is also forwarded into the sub's pane
explicitly — the pane is launched by the herdr server rather than by the parent
session, so nothing of the parent's environment reaches it otherwise, and a sub
reading a different config dir than the parent wrote to would not find its own
nickname. Set `SUB_TASKS_DIR` to move just the plugin's files elsewhere.

## Facts this relies on

Probed on 2026-09-14, Claude Code 2.1.270 — re-check if a version bump breaks it:

- `UserPromptExpansion` fires for slash commands with `command_name` (namespaced,
  e.g. `sub:spawn`), `command_args`, `cwd` and `session_id`, and its matcher is a
  regex over the command name.
- It runs **before** the command body's `!` pre-runs, which is what lets the
  `--brief` turn read the spawn the hook just performed.
- `{"decision":"block","reason":…}` on stdout with exit 0 stops the expansion and
  shows the reason to the user; the model gets no turn. Exit 2 also blocks, with
  stderr as the reason.
- Hooks inherit the session's environment, including `HERDR_PANE_ID`.
- A session's messaging nickname is `.name` in `<config-dir>/sessions/<pid>.json`,
  and `$CLAUDE_PID` identifies the file — so the parent's address is readable from
  a script, with no `ListAgents` call.
- The session's exact model id is the last `"model"` recorded in its transcript at
  `<config-dir>/projects/*/<session-id>.jsonl`.
- `CLAUDE_CONFIG_DIR` must be set in the shell (project `settings.json` `env` no
  longer sets it), so hooks inherit it from the session that triggered them.

## Iterating

`claude plugin install` copies the source into
`~/.claude/plugins/cache/claude-sub/sub/<version>/`, so edits here are not live:

```
claude plugin marketplace update claude-sub
claude plugin uninstall sub@claude-sub && claude plugin install sub@claude-sub
```

Commands and hooks reload on the next session.

## Known rough edge

If the cwd has never been trusted by Claude Code, the new session stops on the
folder-trust dialog and `herdr agent start` returns `agent_not_ready`. The spawn
prints `SUB_START_FAILED` with the pane id and leaves the pane open; every path is
told to surface it to the user rather than answer the dialog for them.

## Retired

This replaces the `sub`, `sub-worker` and `sub-report` skills that used to live in
`~/.claude/skills/` (backed up under `~/.claude/backups/`). The `sub-worker`
bootstrap is gone entirely — its protocol is rendered into each briefing by
`templates/briefing.md`, so the sub needs no skill lookup and the spawn command
carries no plugin-namespace ambiguity.
