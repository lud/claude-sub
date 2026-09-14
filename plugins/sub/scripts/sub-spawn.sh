#!/usr/bin/env bash
# Writes the briefing, splits a pane and starts the sub session. One call.
# The briefing body (task + context) is read from stdin.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

name=""
model=""
direction=""
force=0
dry=0

while [ $# -gt 0 ]; do
  case "$1" in
    --name)      name="${2:-}"; shift 2 ;;
    --model)     model="${2:-}"; shift 2 ;;
    --direction) direction="${2:-}"; shift 2 ;;
    --force)     force=1; shift ;;
    --dry-run)   dry=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_herdr

body="$(cat)"
[ -n "${body//[[:space:]]/}" ] || die "empty briefing body on stdin — nothing to delegate"

parent="$(my_nickname)"
[ -n "$parent" ] || die "could not resolve this session's messaging nickname"
[ -n "$name" ] || name="$(next_sub_name)"
case "$name" in
  [a-z]*) ;;
  *) die "sub name must match [a-z][a-z0-9_-]{0,31}: $name" ;;
esac
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

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
BODY="$body" PARENT="$parent" CWD="$PWD" SUB_NAME="$name" BRIEFING_PATH="$briefing" \
  awk '
    { line = $0
      gsub(/\{\{PARENT\}\}/,        ENVIRON["PARENT"],        line)
      gsub(/\{\{CWD\}\}/,           ENVIRON["CWD"],           line)
      gsub(/\{\{SUB_NAME\}\}/,      ENVIRON["SUB_NAME"],      line)
      gsub(/\{\{BRIEFING_PATH\}\}/, ENVIRON["BRIEFING_PATH"], line)
      if (line == "{{BODY}}") print ENVIRON["BODY"]; else print line
    }
  ' "$here/../templates/briefing.md" > "$tmp" || die "failed to render briefing"

if [ "$dry" -eq 1 ]; then
  echo "--- would write $briefing ---"
  cat "$tmp"
  echo "--- would split $direction from $HERDR_PANE_ID and start $name on $model ---"
  exit 0
fi

cp "$tmp" "$briefing" || die "failed to write $briefing"

split="$(herdr pane split --pane "$HERDR_PANE_ID" --direction "$direction" \
  --cwd "$PWD" --no-focus \
  --env "SUB_BRIEFING=$briefing" --env "SUB_PARENT=$parent" --env "SUB_NAME=$name" 2>&1)"
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

The pane exists and the briefing is written, but the session did not reach a
prompt. The usual cause is Claude Code's folder-trust dialog for a cwd the user
has never accepted. That is the user's decision — report the pane to them and do
not answer the dialog yourself. Inspect with:
  herdr agent read $name --source recent-unwrapped --lines 60
EOF
  exit 1
fi

cat <<EOF
SUB_STARTED
  sub name:  $name
  pane:      $pane
  model:     $model
  cwd:       $PWD
  briefing:  $briefing
  reports to: $parent

The sub is running and has the briefing in its first turn. It will not ack. It
sends exactly one cross-session message when it finishes, which wakes this
session. Do not poll it and do not message it unless you have something new to
say. The user can talk to it directly in pane $pane.
EOF
