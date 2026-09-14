#!/usr/bin/env bash
# Pre-run for the /sub:spawn command body on the --brief path: reports the sub the
# expansion hook just started, so the model's one turn goes entirely into briefing
# it rather than into rediscovering what it is.
#
# Prints NO_SPAWN when the hook did not run (older CLI, hooks disabled). The
# command body then does the spawn itself through the same script.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

sid="$(my_session_id)"
state="$SUB_STATE_DIR/${sid:-nope}.jsonl"
if [ ! -s "$state" ]; then
  echo "NO_SPAWN"
  echo "parent_nickname: $(my_nickname)"
  echo "parent_model:    $(my_model)"
  echo "suggested_name:  $(next_sub_name)"
  echo "working_dir:     $PWD"
  exit 0
fi

# The last line is this invocation's sub. Leave the file alone: the relay owns it,
# and it is what tells this session about the sub on a later turn if this turn
# does not finish the job.
tail -1 "$state" | jq -r '
  "sub_name:    \(.name)",
  "pane:        \(.pane)",
  "model:       \(.model)",
  "cwd:         \(.cwd)",
  "briefing:    \(.briefing)",
  "task_given:  \(.task)",
  "awaiting_context: \(.expect_context)"
'
echo "parent_nickname: $(my_nickname)"
