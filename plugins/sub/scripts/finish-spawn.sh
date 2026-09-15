#!/usr/bin/env bash
# The slow half of a spawn: wait for the sub to reach an interactive prompt,
# resolve its messaging nickname, and record the outcome for the parent's relay.
#
# `herdr agent start` blocks for as long as Claude Code takes to boot — measured
# between 4.4s and 12.5s, and there is no no-wait mode; --timeout only caps it.
# That is the entire cost of a spawn, so this half is split out to be detached by
# default, and run inline only when a caller passes --wait.
#
# Inputs arrive as SUB_F_* environment variables rather than positionals: detached
# or not, the same script runs, and a misplaced argument would silently start a
# sub under the wrong name.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

name="${SUB_F_NAME:?}"
pane="${SUB_F_PANE:?}"
model="${SUB_F_MODEL:?}"
briefing="${SUB_F_BRIEFING:?}"
sid="${SUB_F_SID:-}"
detached="${SUB_F_DETACHED:-0}"
parent="${SUB_F_PARENT:-}"

prof "finish: start"
start="$(herdr agent start "$name" --kind claude --pane "$pane" --timeout 90000 \
  -- --model "$model" "@$briefing" 2>&1)"
prof "finish: herdr agent start returned"

if ! printf '%s' "$start" | jq -e '.result' >/dev/null 2>&1; then
  record_state "$sid" "$(jq -nc --arg n "$name" --arg e "$start" \
    '{name:$n,status:"failed",error:$e}')"

  # Detached, nothing is reading this script's stdout, so the failure would sit in
  # the state file until the parent's next turn. The user is the one who has to act
  # on a folder-trust dialog, so tell them now rather than whenever they next type.
  if [ "$detached" -eq 1 ]; then
    herdr notification show "sub: $name failed to start" \
      --body "Pane $pane is open but the session never reached a prompt. Usually the folder-trust dialog for this directory." \
      --sound request >/dev/null 2>&1 || true
  fi

  cat <<MSG
SUB_START_FAILED
  sub name:  $name
  pane:      $pane
  model:     $model
  briefing:  $briefing
  herdr said: $start

The pane exists and the briefing is written, but the session never reached a
prompt. The usual cause is Claude Code's folder-trust dialog for a cwd that has
never been accepted — that is the user's decision to make, not the model's.
Inspect with: herdr agent read $name --source recent-unwrapped --lines 60
MSG
  exit 1
fi

# Best effort: the sub's own messaging nickname, so the parent can address it with
# SendMessage before the sub has written to it. Never fatal — the sub's first
# report carries the nickname regardless.
nickname="$(agent_nickname "$name" 2>/dev/null)" || nickname=""
prof "finish: nickname resolved"

record_state "$sid" "$(jq -nc --arg n "$name" --arg k "$nickname" \
  '{name:$n,status:"started",nickname:(if $k == "" then null else $k end)}')"
prof "finish: state recorded"

cat <<MSG
SUB_STARTED
  sub name:   $name
  nickname:   ${nickname:-unresolved}
  pane:       $pane
  model:      $model
  cwd:        $PWD
  briefing:   $briefing
  reports to: $parent
MSG
