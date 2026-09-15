#!/usr/bin/env bash
# /sub:spawn without a model turn.
#
# A UserPromptExpansion hook intercepts the command by its namespaced name, this
# script does the whole spawn, and `decision: "block"` stops the expansion: no
# command body loads, no model runs, and the report reaches the user as the block
# reason. The sub is running before the parent would otherwise have finished
# reading its instructions.
#
# This hook always blocks, so the spawn is always free. The task text is the whole
# briefing — a sub started here knows nothing of the conversation. When the task
# only makes sense with that context, /sub:delegate is the door: it spends a turn
# writing the context into the briefing itself, where it survives compaction.
#
# The block is what buys the zero turn, so the hook cannot be marked async — an
# async hook is fire-and-forget and its decision is never read. The asynchrony
# lives one level down instead: spawn.sh detaches Claude Code's boot and returns
# as soon as the pane exists, and the relay reports the outcome on the next turn.
#
# Layering: if this hook cannot run (older CLI without the event, hooks disabled
# by policy), the command expands normally and its body spawns the sub through the
# same script — so every path starts exactly one sub.
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

# --brief used to start the sub here and let the expansion through so the model
# could send it context afterwards. /sub:delegate does the same job in one piece
# and writes the context into the briefing file, so nothing is spawned here: a sub
# started now would be the wrong one, and killing it would be the user's problem.
if [ "$brief" -eq 1 ]; then
  block "sub: --brief is now /sub:delegate.

  /sub:delegate ${task:-<task>}

Nothing was started. /sub:delegate spends one turn writing this conversation's
context into the briefing itself, so the sub reads it up front and still has it
after a compaction."
fi

if [ -z "${task//[[:space:]]/}" ]; then
  block "sub: nothing to delegate.

  /sub:spawn [--model <id>] [--name <id>] <task>

The task text becomes the sub's briefing verbatim, and that is all the sub knows.
When the task leans on this conversation, use /sub:delegate instead."
fi

# Spawning from a directory other than the one the user invoked from would put
# the sub in the wrong repository, so a failure here is fatal, not ignorable.
if [ -n "$cwd" ] && ! cd "$cwd" 2>/dev/null; then
  block "sub: cannot enter the invocation directory: $cwd"
fi

set -- --origin hook
[ -n "$name" ]  && set -- "$@" --name "$name"
[ -n "$model" ] && set -- "$@" --model "$model"

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

# A pane and a briefing, not yet a running session: the boot is deliberately not
# waited on. Say only what is known — if it never reaches a prompt, a herdr
# notification fires at that moment and the relay repeats it on the next turn.
block "$sub_name is starting in pane $pane on $model_used.

Briefing: the task text, verbatim — it has none of this conversation. It reports
back here by message when it is done, and you can talk to it in its pane now.

To fill it in from here, ask me to brief $sub_name."
