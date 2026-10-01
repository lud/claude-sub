#!/usr/bin/env bash
# The model-facing half of the zero-turn spawn.
#
# A sub started by the hook costs the parent no turn, which also means the parent
# never learns it exists. This hook closes that: on the parent's very next turn —
# whatever wakes it, a user prompt or the sub's own report — it injects one note
# per sub the user started, then forgets them. Subs the model started itself
# through spawn.sh need no note: it read the script's output.
#
# The note goes out on first sight, without waiting for the detached start to
# finish. A sub given a short task can report back before `herdr agent start`
# returns, and a parent told about it only afterwards treats the report as a
# stray. The second note is for what the sub cannot report itself: a start that
# failed, or one stuck at a dialog — whoever started it.
#
# It runs on every prompt in every project, so the fast path is one stat call: no
# state file for this session, exit silent.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

payload="$(cat)"
sid="$(printf '%s' "$payload" | jq -r '.session_id // ""' 2>/dev/null)"
[ -n "$sid" ] || exit 0

state="$SUB_STATE_DIR/$sid.jsonl"
[ -s "$state" ] || exit 0

# Claimed by rename rather than read-then-truncate: a finisher appending its
# outcome right now writes to a fresh file and is reported next turn, instead of
# landing in the window between the read and the rewrite and being lost.
claim="$state.claim.$$"
mv "$state" "$claim" 2>/dev/null || exit 0
trap 'rm -f "$claim"' EXIT

merged="$(jq -sc "$SUB_MERGE_BY_NAME" "$claim" 2>/dev/null)"

if [ -z "$merged" ]; then
  # Unparseable state is not worth losing a spawn over: put it back untouched.
  cat "$claim" >> "$state" 2>/dev/null
  exit 0
fi

# The sub has usually not booted yet, so its address is often unknown here; its
# first message carries it in `from-name` either way.
started="$(printf '%s' "$merged" | jq -c '.[] | select(.status == "starting" and .origin == "hook")' 2>/dev/null)"
started_lines=""
while IFS= read -r rec; do
  [ -n "$rec" ] || continue
  pane="$(printf '%s' "$rec" | jq -r '.pane // empty')"
  nick=""
  [ -n "$pane" ] && { nick="$(agent_nickname "$pane" 2>/dev/null)" || nick=""; }
  line="$(printf '%s' "$rec" | jq -r --arg k "$nick" '
    "- \(.name) — pane \(.pane // "?"), model \(.model // "?"), cwd \(.cwd // "?")\n" +
    (if $k != "" then "  address: \($k)\n"
     else "  address: not known yet; it is the from-name of its first message\n" end) +
    "  task: \(.task // "?")"')"
  started_lines="${started_lines:+$started_lines
}$line"
done <<< "$started"

problem_lines="$(printf '%s' "$merged" | jq -r '.[] |
  if .status == "failed" then
    "- \(.name) — FAILED TO START in pane \(.pane // "?")\n  No agent ever appeared in the pane, which is still open. Usually the folder-trust dialog for its directory. Tell the user; do not answer it for them, and do not re-spawn."
  elif .status == "blocked" then
    "- \(.name) — waiting at a dialog in pane \(.pane // "?")\n  It is running, but stopped at folder trust or a permission request, so it has not started its task. Tell the user which pane to answer; do not answer it for them, and do not re-spawn."
  else empty end
' 2>/dev/null)"

ctx=""

if [ -n "$started_lines" ]; then
  count="$(printf '%s\n' "$started" | grep -c .)"
  noun="a sub-session"; [ "${count:-1}" -gt 1 ] && noun="$count sub-sessions"
  # Quoted heredoc plus explicit substitution, not an interpolating one: this block
  # is prose about shells and addresses, and a backtick or a $(...) landing in it
  # would be run rather than printed.
  ctx="$(cat <<'CTX'
The user started __NOUN__ by typing /sub:spawn. A hook did the spawn, so no turn
of yours was spent on it, and this note is the first you hear of it:

__LINES__

Its briefing is the task text alone; it has none of this conversation. It reports
back by cross-session message when it is done — possibly already, in the message
that woke you this turn. That report is expected: it is not misaddressed and not a
bug. Do not poll it, do not ask whether it is done, and do not re-spawn it.
Mention it to the user only if it bears on what they just asked.

If the user asks you to fill it in, send what it is missing with `SendMessage` to
its address.
CTX
)"
  ctx="${ctx//__NOUN__/$noun}"
  ctx="${ctx//__LINES__/$started_lines}"
fi

if [ -n "$problem_lines" ]; then
  ctx="${ctx:+$ctx

}A sub-session did not get going:

$problem_lines"
fi

[ -n "$ctx" ] || exit 0

jq -nc --arg c "$ctx" \
  '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:$c}}'
exit 0
