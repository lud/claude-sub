#!/usr/bin/env bash
# Writes the briefing, splits a pane, starts the sub session, records the spawn
# for the parent's relay. The briefing body (task + context) comes from stdin.
#
# This is the one place a sub is ever created. The zero-turn hook, the /sub:spawn
# fallback body and the delegate skill all funnel through here.
#
# Everything here is milliseconds except `herdr agent start`, which blocks for as
# long as Claude Code takes to boot — measured between 4.4s and 12.5s on the same
# machine. That call lives in finish-spawn.sh and is detached by default: no
# caller needs its result, because the briefing is complete before the pane is
# split and the relay reports a start that went wrong. --wait runs it inline.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

name=""; model=""; effort=""; direction=""; command=""; force=0; dry=0; origin="skill"; detach=1

# Every value-taking option is checked before the shift: `shift 2` on a lone
# trailing flag fails, leaves the arguments untouched, and spins forever.
need_value() { [ "$2" -ge 2 ] || die "$1 requires a value"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --name)      need_value --name "$#";      name="$2"; shift 2 ;;
    --model)     need_value --model "$#";     model="$2"; shift 2 ;;
    --direction) need_value --direction "$#"; direction="$2"; shift 2 ;;
    --origin)    need_value --origin "$#";    origin="$2"; shift 2 ;;
    --command)   need_value --command "$#";   command="$2"; shift 2 ;;
    --wait)      detach=0; shift ;;
    --force)     force=1; shift ;;
    --dry-run)   dry=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done

prof "spawn: parsed arguments"
require_herdr

body="$(cat)"
# A slash command is the sub's first prompt, so Claude Code expands it exactly as
# if the user had typed it — skills marked disable-model-invocation included. The
# briefing then rides in the system prompt instead, and its task names the command.
if [ -n "$command" ]; then
  case "$command" in /?*) ;; *) die "--command must start with /: $command" ;; esac
  intro="Your first message runs the slash command \`$command\`. Its instructions are the task."
  if [ -n "${body//[[:space:]]/}" ]; then body="$intro

$body"
  else body="$intro"; fi
fi
[ -n "${body//[[:space:]]/}" ] || die "empty briefing body — nothing to delegate"

parent="$(my_nickname)"
[ -n "$parent" ] || die "could not resolve this session's messaging nickname"
[ -n "$name" ] || name="$(next_sub_name)"
valid_sub_name "$name" || die "sub name must match [a-z][a-z0-9_-]{0,31}: $name"
# `--model sonnet:high` also sets the effort; `--model :high` keeps the inherited
# model. Only a known level splits, since Bedrock ids end in a `:0` of their own.
case "${model##*:}" in
  low|medium|high|xhigh|max)
    if [ "$model" != "${model##*:}" ]; then effort="${model##*:}"; model="${model%:*}"; fi ;;
esac
[ -n "$model" ] || model="$(my_model)"
[ -n "$model" ] || die "could not resolve a model id; pass --model"
[ -n "$direction" ] || direction=right
prof "spawn: resolved nickname, name, model, direction"

mkdir -p "$SUB_TASKS_DIR"
briefing="$SUB_TASKS_DIR/$name.md"
if [ -e "$briefing" ] && [ "$force" -ne 1 ]; then
  die "briefing already exists: $briefing (pick another --name, or pass --force)"
fi
if agent_name_taken "$name" && [ "$force" -ne 1 ]; then
  die "agent name already live: $name (pick another --name)"
fi

tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
# Literal substitution: awk's gsub would read `&` in a replacement as the matched
# text, so a cwd like /tmp/a&b would render as /tmp/a{{CWD}}b.
BODY="$body" PARENT="$parent" CWD="$PWD" SUB_NAME="$name" BRIEFING_PATH="$briefing" \
  awk '
    function subst(s, key, val,   out, i) {
      out = ""
      while ((i = index(s, key)) > 0) {
        out = out substr(s, 1, i - 1) val
        s = substr(s, i + length(key))
      }
      return out s
    }
    { line = $0
      line = subst(line, "{{PARENT}}",        ENVIRON["PARENT"])
      line = subst(line, "{{CWD}}",           ENVIRON["CWD"])
      line = subst(line, "{{SUB_NAME}}",      ENVIRON["SUB_NAME"])
      line = subst(line, "{{BRIEFING_PATH}}", ENVIRON["BRIEFING_PATH"])
      if (line == "{{BODY}}") { print ENVIRON["BODY"]; next }
      print line
    }
  ' "$here/../templates/briefing.md" > "$tmp" || die "failed to render briefing"

if [ "$dry" -eq 1 ]; then
  echo "--- would write $briefing ---"; cat "$tmp"
  echo "--- would split $direction from ${HERDR_PANE_ID:-?} and start $name on $model${effort:+ at $effort effort} ---"
  if [ -n "$command" ]; then echo "--- would start it with the briefing as system prompt and $command as first prompt ---"
  else echo "--- would start it with the briefing as first prompt ---"; fi
  if [ "$detach" -eq 1 ]; then echo "--- would detach the start and return immediately ---"
  else echo "--- would wait for the start inline ---"; fi
  exit 0
fi

cp "$tmp" "$briefing" || die "failed to write $briefing"
prof "spawn: briefing written"

# The pane is launched by the herdr server, not by this session, so nothing of
# ours reaches it except what is passed here. CLAUDE_CONFIG_DIR is forwarded when
# set: without it the sub would read a different registry than the parent wrote to.
split_env=(--env "SUB_BRIEFING=$briefing" --env "SUB_PARENT=$parent" --env "SUB_NAME=$name")
[ -n "${CLAUDE_CONFIG_DIR:-}" ] && split_env+=(--env "CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR")
[ -n "${SUB_TASKS_DIR:-}" ] && split_env+=(--env "SUB_TASKS_DIR=$SUB_TASKS_DIR")

split="$(herdr pane split --pane "$HERDR_PANE_ID" --direction "$direction" \
  --cwd "$PWD" --no-focus "${split_env[@]}" 2>&1)"
pane="$(printf '%s' "$split" | jq -r '.result.pane.pane_id // empty' 2>/dev/null)"
[ -n "$pane" ] || die "pane split failed: $split"
prof "spawn: pane split"

# Recorded before the sub has booted, not after: the relay announces a hook spawn
# on the parent's very next turn, which can be the sub's own report. The finisher
# amends it by name only when the start goes wrong.
state_recorded=no
sid="$(my_session_id)"
task_line="$(printf '%s' "$body" | tr '\n' ' ' | cut -c1-200)"
if record_state "$sid" "$(jq -nc --arg n "$name" --arg p "$pane" --arg m "$model" \
      --arg e "$effort" --arg c "$PWD" --arg b "$briefing" --arg t "$task_line" --arg o "$origin" \
      --argjson ts "$(date +%s)" \
      '{name:$n,pane:$p,model:$m,effort:(if $e == "" then null else $e end),cwd:$c,briefing:$b,task:$t,origin:$o,
        status:"starting",ts:$ts}')"; then
  state_recorded=yes
fi

finish_env=(
  "SUB_F_NAME=$name" "SUB_F_PANE=$pane" "SUB_F_MODEL=$model"
  "SUB_F_EFFORT=$effort"
  "SUB_F_BRIEFING=$briefing" "SUB_F_SID=$sid" "SUB_F_PARENT=$parent"
  "SUB_F_COMMAND=$command"
)
[ -n "${SUB_PROFILE:-}" ] && finish_env+=("SUB_PROFILE=$SUB_PROFILE")
[ -n "${SUB_PROF_T0:-}" ] && finish_env+=("SUB_PROF_T0=$SUB_PROF_T0")

if [ "$detach" -eq 1 ]; then
  # setsid puts the finisher in its own session so it survives the caller's process
  # group being torn down, and the three redirections are what actually release the
  # caller: a child holding the inherited stdout keeps the hook's pipe open, and
  # whoever is reading it blocks until the child exits regardless of this `&`.
  env "${finish_env[@]}" SUB_F_DETACHED=1 \
    setsid bash "$here/finish-spawn.sh" >/dev/null 2>&1 </dev/null &
  disown 2>/dev/null || true
  prof "spawn: finisher detached"
  cat <<EOF
SUB_STARTING
  sub name:   $name
  pane:       $pane
  model:      $model
  effort:     ${effort:-default}
  cwd:        $PWD
  briefing:   $briefing
  reports to: $parent
  state recorded: $state_recorded

The pane is open and the briefing is written. The session is still booting. If
it fails to start or stops at a dialog, the relay says so on a later turn;
otherwise it reports by message when it is done.
EOF
  exit 0
fi

out="$(env "${finish_env[@]}" SUB_F_DETACHED=0 bash "$here/finish-spawn.sh" 2>&1)"
rc=$?
printf '%s\n' "$out"
[ $rc -eq 0 ] && echo "  state recorded: $state_recorded"
prof "spawn: finisher returned inline"
exit $rc
