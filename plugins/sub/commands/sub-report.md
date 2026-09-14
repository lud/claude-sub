---
description: Push a status or result update from this sub session to the parent that started it.
argument-hint: "[<parent-nickname>]"
allowed-tools: [Bash]
---

# sub-report

Send the parent session an update on the work in this pane.

Resolved from this pane's environment:

!`"${CLAUDE_PLUGIN_ROOT}/scripts/sub-parent.sh"`

If `$ARGUMENTS` names a nickname, it wins over the block above. If the block says
`PARENT_UNKNOWN` and the user passed nothing, ask the user. Do not pick a nickname
from `ListAgents` because it looks plausible — a wrong address sends the user's
work to an unrelated session.

## Send it

One `SendMessage`, addressed to the bare nickname. Cover what changed **since your
last report**, not the whole history:

- What was done, and the current state.
- Files changed, with paths.
- Decisions the user made in this pane that diverge from the original briefing —
  the parent has no visibility into this conversation.
- What remains, or what you are blocked on.

The parent sees only this message: no transcript, no tool output, no plain text.
Make it self-contained, and report outcomes faithfully.

Then tell the user which nickname you reported to and, in a line, what you sent.
This does not end the session — carry on.
