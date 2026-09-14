# claude-sub

A Claude Code plugin for delegating a task to a **new interactive Claude Code
session** in a sibling [Herdr](https://herdr.dev) pane — one you can talk to
directly, unlike a subagent.

It replaces a hand-driven skill that cost five tool calls and a message round-trip
per delegation. `/sub` now costs **one** tool call and **zero** messages until the
sub actually has something to report.

## Install

```
/plugin marketplace add ~/src/claude-sub
/plugin install sub@claude-sub
```

## Commands

### `/sub [--model <model-id>] <task prompt>`

Run in the parent session. A pre-run resolves the parent's messaging nickname,
exact model id, cwd, pane geometry and a free sub name before the model thinks, so
the model makes a single Bash call that writes the briefing, splits the pane and
starts the session.

`--model` is optional; without it the sub inherits the parent's exact model id,
read from the parent's own transcript.

### `/sub-report [<parent-nickname>]`

Run in the sub's pane. Resolves the parent from the pane environment (`SUB_PARENT`,
`SUB_BRIEFING`, `SUB_NAME`, injected at split time) and sends a fresh update.

## How the parent learns things

- **That the sub started** — synchronously, in the same turn: the spawn script's
  `SUB_STARTED` output. There is no ack message, because there is nothing an ack
  would prove that the script has not already proved.
- **That the sub finished** — one cross-session message from the sub. This one does
  wake the parent, deliberately: the user may type nothing after `/sub`, and the
  sub's report is then the only thing that can advance the parent's turn.

The parent is told not to reply to that report unless it has something new to say.

## Layout

```
plugins/sub/
  commands/sub.md          /sub          — pre-run facts + one-call spawn
  commands/sub-report.md   /sub-report   — update from the sub's pane
  scripts/lib.sh           nickname, model, geometry, name allocation
  scripts/sub-facts.sh     read-only pre-run for /sub
  scripts/sub-spawn.sh     briefing + pane split + agent start
  scripts/sub-parent.sh    read-only pre-run for /sub-report
  templates/briefing.md    what the sub reads in its first turn
```

Briefings are written to `~/.claude/sub-tasks/<sub-name>.md`. The path is derived
from the sub's own agent name, so the sub can find it again after compaction.

## Requirements

`HERDR_ENV=1`, plus `herdr` and `jq` on `PATH`.

## Iterating on the plugin

`claude plugin install` copies the source into
`~/.claude/plugins/cache/claude-sub/sub/<version>/`, so edits here are not picked
up live. After changing anything:

```
claude plugin marketplace update claude-sub
claude plugin uninstall sub@claude-sub && claude plugin install sub@claude-sub
```

Commands reload on the next session.

## Known rough edge

If the cwd has never been trusted by Claude Code, the new session stops on the
folder-trust dialog and `herdr agent start` returns `agent_not_ready`. The spawn
script prints `SUB_START_FAILED` with the pane id and leaves the pane open; the
model is told to surface it to the user rather than answer the dialog for them.

## Retired

This replaces the `sub`, `sub-worker` and `sub-report` skills that used to live in
`~/.claude/skills/`. The `sub-worker` bootstrap is gone entirely — its protocol is
now rendered into each briefing by `templates/briefing.md`, so the sub needs no
skill lookup and there is no plugin-namespace ambiguity in the spawn command.
