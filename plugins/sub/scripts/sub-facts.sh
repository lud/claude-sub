#!/usr/bin/env bash
# Pre-computes everything /sub needs, so the model spends zero tool calls
# discovering it. Read-only: creates nothing, starts nothing.
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

if [ "${HERDR_ENV:-}" != 1 ]; then
  echo "PRECONDITION_FAILED: not running inside Herdr (HERDR_ENV != 1)"
  exit 0
fi
for bin in herdr jq; do
  command -v "$bin" >/dev/null 2>&1 || { echo "PRECONDITION_FAILED: $bin not in PATH"; exit 0; }
done

nickname="$(my_nickname)"
model="$(my_model)"
name="$(next_sub_name)"
dir="$(split_direction)"

echo "parent_nickname: ${nickname:-UNKNOWN}"
echo "parent_model:    ${model:-UNKNOWN}"
echo "working_dir:     $PWD"
echo "suggested_name:  $name"
echo "split_direction: $dir"
echo "briefing_path:   $SUB_TASKS_DIR/$name.md"
live="$(herdr agent list 2>/dev/null | jq -r '[.result.agents[]?.pane_id] | join(", ")' 2>/dev/null)"
echo "live_agent_panes: ${live:-none}"
