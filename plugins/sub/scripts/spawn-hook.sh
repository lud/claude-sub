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

# Spawning from a directory other than the one the user invoked from would put
# the sub in the wrong repository, so a failure here is fatal, not ignorable.
if [ -n "$cwd" ] && ! cd "$cwd" 2>/dev/null; then
  block "sub: cannot enter the invocation directory: $cwd"
fi

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

field() { printf '%s' "$out" | sed -n "s/^  $1: *//p" | head -1; }
sub_name="$(field 'sub name')"
pane="$(field 'pane')"
model_used="$(field 'model')"
recorded="$(field 'state recorded')"

if [ "$brief" -eq 1 ]; then
  # The command body reads the spawn back out of the state file. If that file was
  # never written it would read NO_SPAWN and start a second session for the same
  # task, so an unrecorded spawn is reported to the user here instead.
  if [ "$recorded" = yes ]; then exit 0; fi
  block "$sub_name is running in pane $pane on $model_used, but its spawn could not
be recorded, so this session cannot be handed the context step automatically.

The sub was told to expect a briefing message and is waiting for one. Send it the
context yourself, or tell this session to brief $sub_name."
fi

block "$sub_name is running in pane $pane on $model_used.

Briefing: the task text, verbatim. It reports back here by message when it is
done; you can talk to it directly in its pane meanwhile.

If it needed context from this conversation, re-run with --brief."
