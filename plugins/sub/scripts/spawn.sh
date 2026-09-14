#!/usr/bin/env bash
# Writes the briefing, splits a pane, starts the sub session, records the spawn
# for the parent's relay. The briefing body (task + context) comes from stdin.
#
# This is the one place a sub is ever created. The zero-turn hook, the /sub:spawn
# command and the delegate skill all funnel through here.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

name=""; model=""; direction=""; force=0; dry=0; expect_context=0; origin="skill"

# Every value-taking option is checked before the shift: `shift 2` on a lone
# trailing flag fails, leaves the arguments untouched, and spins forever.
need_value() { [ "$2" -ge 2 ] || die "$1 requires a value"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --name)           need_value --name "$#";      name="$2"; shift 2 ;;
    --model)          need_value --model "$#";     model="$2"; shift 2 ;;
    --direction)      need_value --direction "$#"; direction="$2"; shift 2 ;;
    --origin)         need_value --origin "$#";    origin="$2"; shift 2 ;;
    --expect-context) expect_context=1; shift ;;
    --force)          force=1; shift ;;
    --dry-run)        dry=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_herdr

body="$(cat)"
[ -n "${body//[[:space:]]/}" ] || die "empty briefing body — nothing to delegate"

parent="$(my_nickname)"
[ -n "$parent" ] || die "could not resolve this session's messaging nickname"
[ -n "$name" ] || name="$(next_sub_name)"
valid_sub_name "$name" || die "sub name must match [a-z][a-z0-9_-]{0,31}: $name"
[ -n "$model" ] || model="$(my_model)"
[ -n "$model" ] || die "could not resolve a model id; pass --model"
[ -n "$direction" ] || direction="$(split_direction)"

mkdir -p "$SUB_TASKS_DIR"
briefing="$SUB_TASKS_DIR/$name.md"
if [ -e "$briefing" ] && [ "$force" -ne 1 ]; then
  die "briefing already exists: $briefing (pick another --name, or pass --force)"
fi
if agent_name_taken "$name" && [ "$force" -ne 1 ]; then
  die "agent name already live: $name (pick another --name)"
fi

# The amendment notice only makes sense while the parent still owes context.
amendment=""
if [ "$expect_context" -eq 1 ]; then
  amendment="> **Context is still coming.** \`$parent\` started you from a one-line
> instruction and is composing the rest right now. It will arrive within a minute
> as a cross-session message. Get oriented — read what you need to read — but do
> not commit to an approach or start editing until it lands. If it contradicts
> anything below, it wins."
fi

tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
# Literal substitution: awk's gsub would read `&` in a replacement as the matched
# text, so a cwd like /tmp/a&b would render as /tmp/a{{CWD}}b.
BODY="$body" PARENT="$parent" CWD="$PWD" SUB_NAME="$name" BRIEFING_PATH="$briefing" \
AMENDMENT="$amendment" \
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
      if (line == "{{AMENDMENT}}") {
        if (ENVIRON["AMENDMENT"] != "") print ENVIRON["AMENDMENT"] "\n"
        next
      }
      print line
    }
  ' "$here/../templates/briefing.md" > "$tmp" || die "failed to render briefing"

if [ "$dry" -eq 1 ]; then
  echo "--- would write $briefing ---"; cat "$tmp"
  echo "--- would split $direction from ${HERDR_PANE_ID:-?} and start $name on $model ---"
  exit 0
fi

cp "$tmp" "$briefing" || die "failed to write $briefing"

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

start="$(herdr agent start "$name" --kind claude --pane "$pane" --timeout 90000 \
  -- --model "$model" "@$briefing" 2>&1)"
if ! printf '%s' "$start" | jq -e '.result' >/dev/null 2>&1; then
  cat <<EOF
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
EOF
  exit 1
fi

# Record the spawn so the parent learns about it on its next turn, whatever wakes
# it. One line per sub; the relay drains the file. The result is reported rather
# than assumed: on the --brief path the hook reads this state back, and a silent
# failure there would look like "no spawn happened" and start a second session.
state_recorded=no
sid="$(my_session_id)"
if [ -n "$sid" ] && mkdir -p "$SUB_STATE_DIR" 2>/dev/null; then
  task_line="$(printf '%s' "$body" | tr '\n' ' ' | cut -c1-200)"
  if jq -nc --arg n "$name" --arg p "$pane" --arg m "$model" --arg c "$PWD" \
           --arg b "$briefing" --arg t "$task_line" --arg o "$origin" \
           --argjson e "$expect_context" \
           '{name:$n,pane:$p,model:$m,cwd:$c,briefing:$b,task:$t,origin:$o,expect_context:($e==1)}' \
       >> "$SUB_STATE_DIR/$sid.jsonl" 2>/dev/null; then
    state_recorded=yes
  fi
fi

# Best effort: the sub's own messaging nickname, so the parent can address it with
# SendMessage before the sub has written to it. Never fatal — the sub's first
# report carries the nickname regardless.
nickname="$(agent_nickname "$name" 2>/dev/null)" || nickname=""

cat <<EOF
SUB_STARTED
  sub name:   $name
  nickname:   ${nickname:-unresolved}
  pane:       $pane
  model:      $model
  cwd:        $PWD
  briefing:   $briefing
  reports to: $parent
  awaiting context: $([ "$expect_context" -eq 1 ] && echo yes || echo no)
  state recorded: $state_recorded
EOF
