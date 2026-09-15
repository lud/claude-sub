# shellcheck shell=bash
# Shared helpers for the sub plugin. Sourced, never executed.

# Everything this plugin reads about a session — the nickname registry, the
# transcript, the settings — lives in Claude Code's config dir, which is
# CLAUDE_CONFIG_DIR when the user set one in their shell.
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SUB_TASKS_DIR="${SUB_TASKS_DIR:-$CLAUDE_DIR/sub-tasks}"
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
  local f="$CLAUDE_DIR/sessions/$pid.json"
  if [ -f "$f" ]; then printf '%s' "$f"; return 0; fi
  local sid="${SUB_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"
  [ -n "$sid" ] || return 1
  grep -l "\"sessionId\":\"$sid\"" "$CLAUDE_DIR"/sessions/*.json 2>/dev/null | head -1
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
    f="$(find "$CLAUDE_DIR/projects" -maxdepth 2 -name "$sid.jsonl" 2>/dev/null | head -1)"
    if [ -n "$f" ]; then
      m="$(tac "$f" | grep -m1 -o '"model":"[^"]*"' | cut -d'"' -f4 || true)"
      if [ -n "$m" ] && [ "$m" != "<synthetic>" ]; then printf '%s' "$m"; return 0; fi
    fi
  fi
  jq -r '.model // empty' "$CLAUDE_DIR/settings.json" 2>/dev/null
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

# What herdr sees in a pane, whatever the start concluded. `agent get` takes a
# pane id as a target and answers for an agent that never took a name, which is
# the only way to tell a session that never came up from one that came up and
# went straight to work — `agent start` reports both as `agent_not_ready`.
pane_agent() { # pane_agent <pane-id>
  herdr agent get "$1" 2>/dev/null | jq -c '.result.agent // empty' 2>/dev/null
}

# The documented contract, enforced: [a-z][a-z0-9_-]{0,31}. A loose check here
# reaches the filesystem as a briefing path and herdr as a pane, so anything
# with a dot, a slash or a space must be refused before either happens.
valid_sub_name() {
  local n="$1"
  [ -n "$n" ] && [ "${#n}" -le 32 ] || return 1
  case "$n" in [a-z]*) ;; *) return 1 ;; esac
  [ -z "$(printf '%s' "$n" | tr -d 'a-z0-9_-')" ]
}

# The Claude messaging nickname of an agent we started, resolved through its
# herdr agent session id. This is what lets the parent address a sub with
# SendMessage before the sub has ever written to it — so conversation text never
# has to travel through a shell command line.
agent_nickname() {
  local asid f
  asid="$(herdr agent get "$1" 2>/dev/null \
    | jq -r '.result.agent.agent_session.value // empty' 2>/dev/null)"
  [ -n "$asid" ] || return 1
  f="$(grep -l "\"sessionId\":\"$asid\"" "$CLAUDE_DIR"/sessions/*.json 2>/dev/null | head -1)"
  [ -n "$f" ] || return 1
  jq -r '.name // empty' "$f"
}

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

# How the two writers' records are folded back into one per sub.
#
# A sub's record arrives in two pieces: the spawn writes what it knows, the
# detached finisher appends the outcome. Merging them in file order is wrong,
# because the relay can restore a claimed `starting` record *after* the finisher
# has already appended its outcome to the fresh file — a window of a few
# milliseconds that lines up with exactly when someone types after a spawn. The
# stale record would then win, and the sub would be reported as never confirmed
# while it was in fact running. Sorting outcomes last makes the merge independent
# of how the lines landed.
SUB_MERGE_BY_NAME='group_by(.name) | map(sort_by(.status == "starting" | not) | add)'

# Append one record to this session's relay state. Records accumulate per sub —
# the spawn writes what it knows, the finisher writes the outcome later — and the
# relay merges them by name, so a later line carries only the fields it changes.
record_state() { # record_state <session-id> <json-object>
  local sid="$1" json="$2"
  [ -n "$sid" ] || return 1
  [ -n "$json" ] || return 1
  mkdir -p "$SUB_STATE_DIR" 2>/dev/null || return 1
  printf '%s\n' "$json" >> "$SUB_STATE_DIR/$sid.jsonl" 2>/dev/null
}

# Phase timings, written only when SUB_PROFILE=1. The spawn's cost is dominated by
# one blocking call and the rest is noise, so attributing a slow spawn needs the
# boundaries recorded where it actually ran rather than re-measured from a shell.
prof() { # prof <phase-label>
  [ "${SUB_PROFILE:-}" = 1 ] || return 0
  local now
  now="$(date +%s.%N)"
  : "${SUB_PROF_T0:=$now}"
  mkdir -p "$SUB_STATE_DIR" 2>/dev/null || return 0
  awk -v t="$now" -v z="$SUB_PROF_T0" -v l="$1" -v p="$$" \
    'BEGIN { printf "%s pid=%s %8.3fs  %s\n", strftime("%H:%M:%S"), p, t - z, l }' \
    >> "$SUB_STATE_DIR/profile.log" 2>/dev/null
  export SUB_PROF_T0="$SUB_PROF_T0"
}
