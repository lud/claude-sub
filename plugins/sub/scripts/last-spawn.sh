#!/usr/bin/env bash
# Pre-run for the /sub:spawn command body. That body only runs when the expansion
# hook did not (older CLI, hooks disabled), so the usual answer here is NO_SPAWN
# and the body does the spawn itself through the same script.
#
# It still reports a spawn already recorded for this session: if the hook did run
# after all, the body must not start a second session for the same task.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

sid="$(my_session_id)"
state="$SUB_STATE_DIR/${sid:-nope}.jsonl"

# A spawn reaches the state file in two records — what the spawn knew, then the
# outcome — so the newest one is an amendment carrying only a name and a status.
# Take the most recent record that describes a pane and merge its name's records.
last=""
if [ -s "$state" ]; then
  last="$(jq -sc "$SUB_MERGE_BY_NAME"'
    | map(select(.pane != null)) | (sort_by(.ts // 0) | last) // empty
  ' "$state" 2>/dev/null)"
fi

if [ -z "$last" ]; then
  echo "NO_SPAWN"
  echo "parent_nickname: $(my_nickname)"
  echo "parent_model:    $(my_model)"
  echo "suggested_name:  $(next_sub_name)"
  echo "working_dir:     $PWD"
  exit 0
fi

# Leave the file alone: the relay owns it, and it is what tells this session about
# the sub on a later turn if this turn does not finish the job.
printf '%s' "$last" | jq -r '
  "sub_name:    \(.name)",
  "pane:        \(.pane)",
  "model:       \(.model)",
  "cwd:         \(.cwd)",
  "briefing:    \(.briefing)",
  "task_given:  \(.task)"
'
# The sub's own messaging address, so the briefing message can go through
# SendMessage rather than through a shell command line. The finisher records it,
# but fall back to resolving it here in case this runs before that landed.
nickname="$(printf '%s' "$last" | jq -r '.nickname // empty')"
if [ -z "$nickname" ]; then
  sub_name="$(printf '%s' "$last" | jq -r '.name // empty')"
  nickname="$(agent_nickname "$sub_name" 2>/dev/null)" || nickname=""
fi
echo "sub_nickname: ${nickname:-unresolved}"
echo "parent_nickname: $(my_nickname)"
