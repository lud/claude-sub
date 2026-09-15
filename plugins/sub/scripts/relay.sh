#!/usr/bin/env bash
# The model-facing half of the zero-turn spawn.
#
# A sub started by the hook costs the parent no turn, which also means the parent
# never learns it exists. This hook closes that: on the parent's next turn —
# whatever wakes it, a user prompt or the sub's own report — it injects one note
# per sub resolved since the last injection, then forgets them.
#
# Since the start is detached, a sub arrives here in two pieces: the spawn records
# what it knows, the finisher amends it with the outcome. Records are merged by
# name, and a sub whose start has not landed yet is left in the file for a later
# turn rather than reported half-known.
#
# It runs on every prompt in every project, so the fast path is one stat call: no
# state file for this session, exit silent.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

# A start that never recorded an outcome — finisher killed, machine slept — must
# not pin its record in the file forever. Past this many seconds it is reported
# with whatever is known.
STALE_AFTER=180

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

merged="$(jq -s --argjson now "$(date +%s)" --argjson stale "$STALE_AFTER" \
  "$SUB_MERGE_BY_NAME"' | map(. + {resolved: (.status != "starting" or ((($now - (.ts // 0)) > $stale)))})' \
  "$claim" 2>/dev/null)"

if [ -z "$merged" ]; then
  # Unparseable state is not worth losing a spawn over: put it back untouched.
  cat "$claim" >> "$state" 2>/dev/null
  exit 0
fi

# Anything still booting goes back, so the next turn reports it complete.
printf '%s' "$merged" | jq -c '.[] | select(.resolved | not) | del(.resolved)' \
  >> "$state" 2>/dev/null
[ -s "$state" ] || rm -f "$state" 2>/dev/null

report="$(printf '%s' "$merged" | jq -r '.[] | select(.resolved)' 2>/dev/null)"
[ -n "${report//[[:space:]]/}" ] || exit 0

lines="$(printf '%s' "$report" | jq -sr '.[] |
  if .status == "failed" then
    "- \(.name) — FAILED TO START in pane \(.pane // "?")\n  task: \(.task // "?")\n  No agent ever appeared in the pane, which is still open. Usually the folder-trust dialog for \(.cwd // "its directory"). Tell the user — do not answer it for them, and do not re-spawn."
  else
    "- \(.name) — pane \(.pane // "?"), model \(.model // "?"), cwd \(.cwd // "?")" +
    (if .nickname then "\n  address: \(.nickname)" else "" end) +
    "\n  task: \(.task // "?")" +
    (if .status == "blocked" then
       "\n  It is running, but waiting at a dialog in its pane — folder trust, or a permission request — so it has not started the task yet. Tell the user which pane to answer; do not answer it for them, and do not re-spawn."
     elif .status == "starting" then
       "\n  Its start was never confirmed. Check the pane before assuming it is working."
     elif .ready == false then
       "\n  herdr never saw it reach an idle prompt, which is what a session already working on its briefing looks like. It is alive — do not report it as failed."
     else "" end)
  end
' 2>/dev/null)"
[ -n "$lines" ] || exit 0

count="$(printf '%s' "$report" | jq -s 'length' 2>/dev/null)"
noun="sub-session is"; [ "${count:-1}" -gt 1 ] && noun="sub-sessions are"

# Quoted heredoc plus explicit substitution, not an interpolating one: this block
# is prose about shells and addresses, and a backtick or a $(...) landing in it
# would be run rather than printed.
ctx="$(cat <<'CTX'
__COUNT__ __NOUN__ running in a sibling pane, started with /sub:spawn. You spent
no turn on that, so this is the first you hear of it:

__LINES__

Each one has its briefing and reports back here by cross-session message when it
finishes. Do not poll them, do not ask whether they are done, and do not re-spawn
them. Mention them to the user only if it is relevant to what they just asked.

Its task text was the whole briefing, so it has none of this conversation. If the
user asks you to fill one in, the `address` above is a SendMessage nickname that
works now.
CTX
)"
ctx="${ctx//__COUNT__/$count}"
ctx="${ctx//__NOUN__/$noun}"
ctx="${ctx//__LINES__/$lines}"

jq -nc --arg c "$ctx" \
  '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:$c}}'
exit 0
