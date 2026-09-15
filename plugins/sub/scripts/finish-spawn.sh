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

ready=true
blocked=no

if ! printf '%s' "$start" | jq -e '.result' >/dev/null 2>&1; then
  # `agent start` answers one question: is the pane at an idle prompt, ready for
  # input. A sub is started with its briefing already queued, so it can go
  # straight to work and never show that prompt — and then the call comes back
  # `agent_not_ready` about a session that is very much alive. Whether a sub
  # exists is a different question, and only the pane can answer it.
  agent=""
  probe_until=$(( $(date +%s) + ${SUB_PROBE_SECONDS:-10} ))
  while :; do
    agent="$(pane_agent "$pane")"
    [ -n "$agent" ] && break
    [ "$(date +%s)" -lt "$probe_until" ] || break
    sleep 2
  done
  prof "finish: pane probed"

  if [ -z "$agent" ]; then
    record_state "$sid" "$(jq -nc --arg n "$name" --arg e "$start" \
      '{name:$n,status:"failed",error:$e}')"

    # Detached, nothing is reading this script's stdout, so the failure would sit in
    # the state file until the parent's next turn. The user is the one who has to act
    # on a folder-trust dialog, so tell them now rather than whenever they next type.
    if [ "$detached" -eq 1 ]; then
      herdr notification show "sub: $name failed to start" \
        --body "Pane $pane is open but no agent ever appeared in it. Usually the folder-trust dialog for this directory." \
        --sound request >/dev/null 2>&1 || true
    fi

    cat <<MSG
SUB_START_FAILED
  sub name:  $name
  pane:      $pane
  model:     $model
  briefing:  $briefing
  herdr said: $start

The pane exists and the briefing is written, but no agent ever appeared in it.
The usual cause is Claude Code's folder-trust dialog for a cwd that has never been
accepted — that is the user's decision to make, not the model's.
Inspect with: herdr agent read $pane --source recent-unwrapped --lines 60
MSG
    exit 1
  fi

  ready=false
  [ "$(printf '%s' "$agent" | jq -r '.agent_status // empty')" = "blocked" ] && blocked=yes

  # A start that never reported ready never registered the name either, and the
  # name is what `/sub:report`, `herdr agent read` and the next allocation look up.
  if [ "$(printf '%s' "$agent" | jq -r '.name // empty')" != "$name" ]; then
    herdr agent rename "$pane" "$name" >/dev/null 2>&1 || true
  fi
fi

# Best effort: the sub's own messaging nickname, so the parent can address it with
# SendMessage before the sub has written to it. Resolved through the pane rather
# than the name, which a start that never reported ready may not have registered.
# Never fatal — the sub's first report carries the nickname regardless.
nickname="$(agent_nickname "$pane" 2>/dev/null)" || nickname=""
prof "finish: nickname resolved"

record_state "$sid" "$(jq -nc --arg n "$name" --arg k "$nickname" \
  --argjson r "$ready" --arg b "$blocked" \
  '{name:$n,status:(if $b == "yes" then "blocked" else "started" end),
    ready:$r,nickname:(if $k == "" then null else $k end)}')"
prof "finish: state recorded"

# A sub waiting at a dialog is running, but it has not read its briefing yet and
# only the user can let it through. Same reasoning as a failed start: waiting for
# their next prompt to mention it is too late.
if [ "$blocked" = yes ] && [ "$detached" -eq 1 ]; then
  herdr notification show "sub: $name is waiting at a dialog" \
    --body "Pane $pane is running but blocked on a prompt — folder trust, or a permission request. It starts the task once you answer." \
    --sound request >/dev/null 2>&1 || true
fi

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

if [ "$blocked" = yes ]; then
  cat <<MSG

It is waiting at a dialog in its pane — folder trust, or a permission request —
so it has not started the task yet. Tell the user which pane to answer; do not
answer it for them, and do not spawn a second sub.
MSG
elif [ "$ready" = false ]; then
  cat <<MSG

herdr never saw it reach an idle prompt (it said: $start). The session is there
and is most likely already working on the briefing, which is exactly what an
unready prompt looks like. Nothing to do; it reports when it is done.
MSG
fi
