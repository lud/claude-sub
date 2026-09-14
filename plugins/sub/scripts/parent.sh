#!/usr/bin/env bash
# Resolves the parent session this sub reports to. Read-only.
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

briefing="${SUB_BRIEFING:-}"
parent="${SUB_PARENT:-}"

# The pane environment is authoritative. Fall back to the briefing named after
# this pane's registered agent — never to a plausible-looking nickname from a
# listing, which is how a user's work reaches an unrelated session.
if [ -z "$briefing" ] && [ -n "${SUB_NAME:-}" ]; then
  briefing="$SUB_TASKS_DIR/$SUB_NAME.md"
fi
if [ -z "$parent" ] && [ -n "$briefing" ] && [ -f "$briefing" ]; then
  parent="$(sed -n 's/^Parent session nickname: //p' "$briefing" | head -1)"
fi

if [ -z "$parent" ]; then
  echo "PARENT_UNKNOWN"
  echo "This session was not started by /sub:spawn, or the pane environment was lost."
  echo "Ask the user for the parent nickname. Do not guess one from a listing."
  exit 0
fi

echo "parent_nickname: $parent"
echo "briefing:        ${briefing:-unknown}"
if [ -n "$briefing" ] && [ -f "$briefing" ]; then
  echo "briefing_task:   $(sed -n '/^## Task/,$p' "$briefing" | sed -n '2,6p' | tr '\n' ' ' | cut -c1-300)"
fi
exit 0
