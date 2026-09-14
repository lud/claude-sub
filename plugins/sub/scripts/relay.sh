#!/usr/bin/env bash
# The model-facing half of the zero-turn spawn.
#
# A sub started by the hook costs the parent no turn, which also means the parent
# never learns it exists. This hook closes that: on the parent's next turn —
# whatever wakes it, a user prompt or the sub's own report — it injects one note
# per sub started since the last injection, then forgets them.
#
# It runs on every prompt in every project, so the fast path is one stat call: no
# state file for this session, exit silent. The file is consumed before anything
# is printed, so a crash below cannot repeat a notice.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

payload="$(cat)"
sid="$(printf '%s' "$payload" | jq -r '.session_id // ""' 2>/dev/null)"
[ -n "$sid" ] || exit 0

state="$SUB_STATE_DIR/$sid.jsonl"
[ -s "$state" ] || exit 0

pending="$(cat "$state")"
rm -f "$state"
[ -n "${pending//[[:space:]]/}" ] || exit 0

lines="$(printf '%s\n' "$pending" | jq -r '
  "- \(.name) — pane \(.pane), model \(.model), cwd \(.cwd)\n  task: \(.task)" +
  (if .expect_context then "\n  It was told you are still composing context for it and is waiting for that message before it commits to an approach. Send it now." else "" end)
' 2>/dev/null)"
[ -n "$lines" ] || exit 0

count="$(printf '%s\n' "$pending" | grep -c . )"
noun="sub-session is"; [ "$count" -gt 1 ] && noun="sub-sessions are"

ctx="$(cat <<EOF
$count $noun running in a sibling pane, started with /sub:spawn. You spent no
turn on that, so this is the first you hear of it:

$lines

Each one has its briefing and reports back here by cross-session message when it
finishes. Do not poll them, do not ask whether they are done, and do not re-spawn
them. Mention them to the user only if it is relevant to what they just asked.
EOF
)"

jq -nc --arg c "$ctx" \
  '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:$c}}'
exit 0
