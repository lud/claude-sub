#!/usr/bin/env bash
# /sub:spawn without a model turn.
#
# A UserPromptExpansion hook intercepts the command by its namespaced name, this
# script does the whole spawn, and `decision: "block"` stops the expansion: no
# command body loads, no model runs, and the report reaches the user as the block
# reason. The sub is running before the parent would otherwise have finished
# reading its instructions.
#
# `--brief` is the escape hatch back to the model. The sub still starts here and
# now — the only difference is that the expansion is allowed through, so the
# parent gets one turn whose whole job is to send the sub the context this
# conversation holds and the one-line prompt could not carry. The sub is told to
# expect it.
#
# Layering: if this hook cannot run (older CLI without the event, hooks disabled
# by policy), the command expands normally and its body spawns the sub through
# the same script — so every path starts exactly one sub.
#
# stdout must carry only the JSON object; exit 0 is what makes it count.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

payload="$(cat)"
args="$(printf '%s' "$payload" | jq -r '.command_args // ""' 2>/dev/null)"
cwd="$(printf '%s' "$payload" | jq -r '.cwd // ""' 2>/dev/null)"
sid="$(printf '%s' "$payload" | jq -r '.session_id // ""' 2>/dev/null)"

block() { jq -nc --arg r "$1" '{decision:"block",reason:$r}'; exit 0; }

# Parse the leading flags off the front of the argument string, so the task text
# that becomes the briefing survives verbatim — quoting, punctuation and all.
brief=0; name=""; model=""
rest="$args"
while :; do
  case "$rest" in
    "--brief "*) brief=1; rest="${rest#--brief }" ;;
    "--brief")   brief=1; rest="" ;;
    "--model "*) rest="${rest#--model }"; model="${rest%% *}"
                 rest="${rest#"$model"}"; rest="${rest# }" ;;
    "--name "*)  rest="${rest#--name }";  name="${rest%% *}"
                 rest="${rest#"$name"}";  rest="${rest# }" ;;
    *) break ;;
  esac
done
task="$rest"

if [ -z "${task//[[:space:]]/}" ]; then
  block "sub: nothing to delegate.

  /sub:spawn [--brief] [--model <id>] [--name <id>] <task>

The task text becomes the sub's briefing verbatim. Add --brief when the task only
makes sense with context from this conversation: the sub still starts immediately,
and this session gets one turn to send it that context."
fi

[ -n "$cwd" ] && cd "$cwd" 2>/dev/null

set -- --origin hook
[ -n "$name" ]  && set -- "$@" --name "$name"
[ -n "$model" ] && set -- "$@" --model "$model"
[ "$brief" -eq 1 ] && set -- "$@" --expect-context

out="$(printf '%s\n' "$task" | SUB_SESSION_ID="$sid" bash "$here/spawn.sh" "$@" 2>&1)"
rc=$?

if [ $rc -ne 0 ]; then
  # Nothing to enrich and nothing to hand the model: the user has to act.
  block "$out"
fi

sub_name="$(printf '%s' "$out" | sed -n 's/^  sub name: *//p' | head -1)"
pane="$(printf '%s' "$out" | sed -n 's/^  pane: *//p' | head -1)"
model_used="$(printf '%s' "$out" | sed -n 's/^  model: *//p' | head -1)"

if [ "$brief" -eq 1 ]; then
  # Let the expansion through. The command body picks the spawn up from the state
  # file and spends its turn briefing the sub.
  exit 0
fi

block "$sub_name is running in pane $pane on $model_used.

Briefing: the task text, verbatim. It reports back here by message when it is
done; you can talk to it directly in its pane meanwhile.

If it needed context from this conversation, re-run with --brief."
