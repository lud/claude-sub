# shellcheck shell=bash
# Shared helpers for the sub plugin. Sourced, never executed.

SUB_TASKS_DIR="${SUB_TASKS_DIR:-$HOME/.claude/sub-tasks}"
SUB_STATE_DIR="$SUB_TASKS_DIR/.state"

die() {
  printf 'sub: %s\n' "$*" >&2
  exit 1
}

require_herdr() {
  [ "${HERDR_ENV:-}" = 1 ] || die "not running inside Herdr (HERDR_ENV != 1)"
  command -v herdr >/dev/null 2>&1 || die "herdr not found in PATH"
  command -v jq >/dev/null 2>&1 || die "jq not found in PATH"
}

# The session registry file for this process, keyed by PID.
session_file() {
  local pid="${CLAUDE_PID:-$PPID}"
  local f="$HOME/.claude/sessions/$pid.json"
  if [ -f "$f" ]; then printf '%s' "$f"; return 0; fi
  local sid="${SUB_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"
  [ -n "$sid" ] || return 1
  grep -l "\"sessionId\":\"$sid\"" "$HOME"/.claude/sessions/*.json 2>/dev/null | head -1
}

# Cross-session messaging nickname of this session (the SendMessage address).
my_nickname() {
  local f
  f="$(session_file)" || return 1
  [ -n "$f" ] || return 1
  jq -r '.name // empty' "$f"
}

my_session_id() {
  if [ -n "${SUB_SESSION_ID:-}" ]; then printf '%s' "$SUB_SESSION_ID"; return 0; fi
  if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then printf '%s' "$CLAUDE_CODE_SESSION_ID"; return 0; fi
  local f
  f="$(session_file)" || return 1
  jq -r '.sessionId // empty' "$f"
}

# Exact model id of this session, read from the last assistant turn recorded in
# the transcript. Falls back to the configured default.
my_model() {
  local sid f m
  sid="$(my_session_id)" || true
  if [ -n "$sid" ]; then
    f="$(find "$HOME/.claude/projects" -maxdepth 2 -name "$sid.jsonl" 2>/dev/null | head -1)"
    if [ -n "$f" ]; then
      m="$(tac "$f" | grep -m1 -o '"model":"[^"]*"' | cut -d'"' -f4 || true)"
      if [ -n "$m" ] && [ "$m" != "<synthetic>" ]; then printf '%s' "$m"; return 0; fi
    fi
  fi
  jq -r '.model // empty' "$HOME/.claude/settings.json" 2>/dev/null
}

# right for a wide pane, down for a narrow or tall one.
split_direction() {
  local w
  w="$(herdr pane layout --pane "$HERDR_PANE_ID" 2>/dev/null \
    | jq -r --arg p "$HERDR_PANE_ID" \
        '.result.layout.panes[] | select(.pane_id == $p) | .rect.width' 2>/dev/null)"
  [ -n "$w" ] || w=0
  if [ "$w" -ge 160 ]; then printf 'right'; else printf 'down'; fi
}

agent_name_taken() { herdr agent get "$1" >/dev/null 2>&1; }

# First free sub-N, considering both live agents and leftover briefing files.
next_sub_name() {
  local i=1 name
  while [ "$i" -le 99 ]; do
    name="sub-$i"
    if ! agent_name_taken "$name" && [ ! -e "$SUB_TASKS_DIR/$name.md" ]; then
      printf '%s' "$name"; return 0
    fi
    i=$((i + 1))
  done
  printf 'sub-%s' "$$"
}
