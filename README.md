# claude-sub

A Claude Code plugin for delegating a task to a **new interactive Claude Code
session** in a sibling [Herdr](https://herdr.dev) pane — one you can talk to
directly, unlike a subagent.

It replaces a hand-driven skill that cost five tool calls and a message
round-trip per delegation. `/sub:spawn` now costs the parent **no model turn at
all**: a `UserPromptExpansion` hook intercepts the command, does the whole spawn,
and blocks the expansion. The sub is already reading its briefing before the
parent would have finished reading its instructions.

There are two doors, and which one you want is decided by one question: does the
task make sense to a session that has never seen this conversation?

## Install

```
claude plugin marketplace add ~/src/claude-sub
claude plugin install sub@claude-sub
```

## The two ways a sub gets started

| | who starts it | parent turns | the sub's briefing |
|---|---|---|---|
| `/sub:spawn <task>` | the user | **0** | the task text, verbatim |
| `/sub:delegate <task>` | the user, or the parent on its own initiative | 1 | written by the parent |

Both funnel through `scripts/spawn.sh`, which is the only place a sub is ever
created, and both return as soon as the pane exists.

### `/sub:spawn [--model <id>] [--name <id>] <task>`

The hook spawns and blocks. The task text is the briefing, verbatim, and that is
all the sub will ever know. The parent never runs — it finds out on its next turn,
from the relay. The right door for work that stands on its own: "bump the deps and
run the suite".

The spawn returns in ~85ms. Waiting for the new session to reach a prompt is
another 4.4–12.5s of Claude Code boot, and nothing in the turn reads that result,
so it is handed to a detached finisher and the prompt comes straight back. The
relay reports the outcome, including a failure.

### `/sub:delegate <task>` — the `delegate` skill

One turn, spent writing the briefing. The right door whenever the task leans on
the conversation: "tidy the parser module" means nothing to a session that has
never seen it.

The same skill is how the *parent* spawns subs on its own initiative — the hook
can only fire on something the user types, so without it the model would have no
route at all. Either way it spawns one sub per Bash call, and the model writes the
whole briefing up front.

Because the context lands in the briefing **file**, the sub reads it before its
first move and still has it after a compaction.

A sub started by `/sub:spawn` is not stranded if it turns out to need context: the
relay hands the parent its messaging address, so the parent can fill it in with
`SendMessage` rather than spawning a second one.

## How the parent learns things

- **That a sub started** — on its next turn, from the `UserPromptSubmit` relay,
  which drains one note per sub and then forgets them. Not a wake-up, not a
  message: a chunk of context added to a turn that was going to happen anyway.
  The note carries the sub's messaging address, so the parent can reach it.
- **That a sub finished** — one cross-session message from the sub. This one does
  wake the parent, deliberately: the user may type nothing after `/sub:spawn`, and
  the sub's report is then the only thing that can advance the parent's turn.

Subs open their report by naming themselves and their task, because a parent that
spent zero turns spawning them has no memory of doing so.

- **That a sub is waiting at a dialog** — through the relay, plus a herdr
  notification at the moment it happens, since a folder-trust or permission dialog
  is the user's to answer and waiting for their next prompt to mention it is too
  late. The sub is running; it just has not read its briefing yet.
- **That a sub failed to start** — the same two ways, and only when no agent ever
  appeared in the pane at all. `herdr agent start` saying `agent_not_ready` is not
  that: it reports whether the pane is at an idle prompt, and a sub that went
  straight to work on its queued briefing is not at one either. The pane is asked
  directly before anything is called a failure.

There is no ack. The pane and the briefing are proven before the prompt comes
back, and the boot that follows reports itself, so an ack would prove nothing that
is not already proven — it would just be a wake-up and two wasted turns.

## Layering

Every automatic path degrades to a working manual one:

- Hook cannot run (older CLI, hooks disabled by policy) → the command expands, its
  pre-run reports `NO_SPAWN`, and the body spawns the sub through the same script.
- Detached finisher dies before recording an outcome → the spawn record stays in
  `.state/` and the relay reports it as unconfirmed once it is three minutes old,
  rather than holding it forever or claiming a session that is not there.
- `herdr agent start` never sees an idle prompt → the pane decides. A live agent
  there is a running sub, reported as started with the readiness left unconfirmed;
  only an empty pane is a failure. The name the start never registered is applied
  to the pane agent afterwards, so `/sub:report` and `herdr agent read` still
  resolve it.
- Relay and finisher write `.state/` concurrently → the relay claims the file by
  rename, and records are merged by name with outcomes sorted last, so an
  in-flight record restored after an outcome already landed cannot mask it.
- Relay never fires → the parent still learns everything from the sub's report.
- `herdr` or `jq` missing, or `HERDR_ENV != 1` → the spawn refuses with a reason
  rather than half-starting something.

## Layout

```
plugins/sub/
  commands/spawn.md        /sub:spawn  — the no-hook fallback only
  commands/report.md       /sub:report — update from the sub's pane
  skills/delegate/         /sub:delegate — the briefing-writing path
  hooks/hooks.json         UserPromptExpansion (zero-turn) + UserPromptSubmit (relay)
  scripts/spawn.sh         the only place a sub is created
  scripts/finish-spawn.sh  the boot wait, run inline or detached
  scripts/spawn-hook.sh    zero-turn entry point
  scripts/relay.sh         next-turn notice, drained once
  scripts/last-spawn.sh    pre-run for the fallback, and a double-spawn guard
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
- `herdr agent start` has no no-wait mode — `--timeout` only caps the wait — and
  what it waits for is an idle prompt ready for input. Measured between 4.4s and
  12.5s across runs on one machine — Claude Code's boot is variable, which is the
  case for never waiting on it. Every other herdr call is 2-4ms.
- A start that does not reach that prompt returns `agent_not_ready` and registers
  no name: `herdr agent get <name>` then answers `agent_not_found` for a session
  that is running. A sub is started with `@briefing` already queued, so going
  straight to work looks exactly like never coming up — observed on 2026-09-15,
  twice, on subs that went on to complete their task and report.
- `herdr agent get <pane-id>` answers for the agent in a pane whether or not it
  ever took a name, with `agent_status` and `agent_session.value`. That is what
  separates a running sub from an empty pane, and `herdr agent rename <pane-id>
  <name>` gives the name back afterwards.
- `agent_status` is `blocked` while the session sits at a dialog, which is the one
  case where the user has to act.
- The expansion hook cannot be marked `async`: an async hook is fire-and-forget,
  so its `decision` is not read, and the block is what buys the zero turn. The
  asynchrony therefore lives one level down: `spawn.sh` detaches the boot.
- A backgrounded child that inherits the hook's stdout keeps the pipe open and the
  hook still blocks. `setsid` plus `>/dev/null 2>&1 </dev/null` is what actually
  releases it.

## Context never travels through a shell

A briefing quotes this conversation and the repository, so it will contain
backticks, `$(...)`, quotes and backslashes. It reaches the sub by two routes and
neither is a shell command line:

- **At spawn**, as the heredoc on stdin to `spawn.sh`, which reads it whole and
  writes it to a file. A quoted heredoc expands nothing.
- **Afterwards**, as `SendMessage`, which takes the text as a parameter.

This is why the sub's own messaging nickname is resolved and recorded: a session's
nickname is `.name` in its registry file, found from the herdr agent's session id
(`herdr agent get <name>` → `.agent_session.value`). Without it the parent would
have no address for a sub that has not yet written to it, and the only remaining
channel would be `herdr agent prompt <name> "<text>"` — a shell command line built
out of repository text. The relay carries that address to the parent, and the
command and the skill both say to use `SendMessage` and nothing else.

## Testing

```
test/run.sh
```

74 assertions over argument parsing, name validation, template rendering, path
resolution, relay record merging and how a start that never reports ready is
classified. Nothing spawns a pane: every case runs
`--dry-run` against a fixture config directory, or the finisher against a `herdr`
stub on `PATH`, so the suite touches neither the real `~/.claude` nor herdr.

The suite unsets `SUB_TASKS_DIR` and the session-id variables before it starts. A
session that exports them — anything started by `/sub:spawn` — would otherwise
have them win over the fixture and point every case at the real config directory.

To attribute a slow spawn where it actually runs, set `SUB_PROFILE=1` in the shell
before launching Claude Code; phase timings land in `sub-tasks/.state/profile.log`.

## Iterating

`claude plugin install` copies the source into
`~/.claude/plugins/cache/claude-sub/sub/<version>/`, so edits here are not live:

```
claude plugin marketplace update claude-sub
claude plugin uninstall sub@claude-sub && claude plugin install sub@claude-sub
```

Commands and hooks reload on the next session.

## Known rough edges

If the cwd has never been trusted by Claude Code, the new session stops on the
folder-trust dialog. The pane reads back as `blocked`, and every path is told to
surface it to the user rather than answer the dialog for them: a herdr
notification at the time, and the relay on the next turn. A pane where no agent
ever appeared is the failure case, and only then does anything say
`SUB_START_FAILED`.

A sub started by `/sub:spawn` has only its one line of task text. That is the
design, not an oversight — but it does mean a task phrased against the
conversation produces a sub that will guess. `/sub:delegate` is the door for
those, and the block message says so.

## Retired

This replaces the `sub`, `sub-worker` and `sub-report` skills that used to live in
`~/.claude/skills/` (backed up under `~/.claude/backups/`). The `sub-worker`
bootstrap is gone entirely — its protocol is rendered into each briefing by
`templates/briefing.md`, so the sub needs no skill lookup and the spawn command
carries no plugin-namespace ambiguity.
