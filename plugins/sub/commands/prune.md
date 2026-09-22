---
description: Close the subs this session started that have already reported back.
argument-hint: "[<sub-name>...]"
allowed-tools: [Bash]
---

# sub:prune

Reclaim the panes of subs that are finished with. What this session started, and
what became of it:

!`"${CLAUDE_PLUGIN_ROOT}/scripts/subs.sh"`

## What gets closed

Having reported is what makes a sub disposable, and it is the only thing this
session can actually know: a sub that has not reported still has work in its pane,
and a sub that has reported may still be useful to the user — but that is the
user's call, and they made it by typing this command. So lean to closing.

With no `$ARGUMENTS`, close everything above that reported, and clear the
briefings of any listed as `gone`. One Bash call:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/prune.sh" --reported
```

When `$ARGUMENTS` names subs, close exactly those and leave the rest:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/prune.sh" <name> <name>
```

The script refuses a sub that has not reported, and one that is working or
blocked rather than idle — it has been given something since. Both refusals are
reasons to tell the user, not to work around. `--force` overrides them, and is for
one case only: the user named that sub and meant it.

Each sub is exited with `/exit` before its pane is closed, and its briefing file
is removed. Do not do any of that by hand: no `herdr pane close`, no farewell
`SendMessage` — a closed session has nobody left to read it.

## Afterwards

Say what was closed and what was left alone, with the script's reason for each.
Do not re-spawn anything to replace what you closed.

## Invocation

$ARGUMENTS
