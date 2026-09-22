#!/usr/bin/env bash
# What this session started and what became of it. Pre-run for /sub:prune, and
# the only place that answers "has it reported yet" — which is what decides
# whether a sub is finished work or work in progress.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

require_herdr

rows="$(sub_rows)"
if [ -z "${rows//[[:space:]]/}" ]; then
  echo "NO_SUBS"
  echo "parent_nickname: $(my_nickname)"
  exit 0
fi

echo "SUBS_OF: $(my_nickname)"
printf '%s\n' "$rows" | while IFS=$'\t' read -r name pane status nick reported task; do
  printf -- '- %s\n' "$name"
  printf '    pane:     %s\n' "$pane"
  printf '    status:   %s\n' "$status"
  printf '    address:  %s\n' "$nick"
  printf '    reported: %s\n' "$reported"
  printf '    task:     %s\n' "$task"
done
