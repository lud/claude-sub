#!/usr/bin/env bash
# Unit tests for the parts of the plugin that are pure logic: argument parsing,
# name validation, template rendering and path resolution. Nothing here spawns a
# pane — every spawn runs with --dry-run against a fixture config directory.
#
#   test/run.sh
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
spawn="$root/plugins/sub/scripts/spawn.sh"
hook="$root/plugins/sub/scripts/spawn-hook.sh"

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; }
check() { # check <name> <expected-substring> <actual>
  case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "expected [$2] in: $(printf '%s' "$3" | head -3 | tr '\n' '|')" ;; esac
}
# check with an empty needle matches anything, so absence needs its own assertion.
empty() { # empty <name> <actual>
  if [ -n "${2//[[:space:]]/}" ]; then bad "$1" "expected nothing, got: $(printf '%s' "$2" | head -2 | tr '\n' '|')"
  else ok "$1"; fi
}

# A config directory the tests own, so nothing reads or writes the real one.
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/sessions" "$fixture/projects/p"
cat > "$fixture/sessions/4242.json" <<JSON
{"pid":4242,"sessionId":"test-session","name":"test-parent","cwd":"/tmp"}
JSON
printf '{"model":"test-model"}\n' > "$fixture/settings.json"

# A session that runs this suite may export the very variables the fixture is
# meant to control — SUB_TASKS_DIR above all — and an inherited one wins over
# CLAUDE_CONFIG_DIR, pointing every case at the real config directory. Drop them
# here so children see only what a case sets on purpose.
unset SUB_TASKS_DIR SUB_SESSION_ID CLAUDE_CODE_SESSION_ID SUB_PROFILE SUB_PROF_T0

# CLAUDE_PID points the registry lookup at the fixture session.
run() { CLAUDE_CONFIG_DIR="$fixture" CLAUDE_PID=4242 HERDR_ENV=1 "$@" 2>&1; }

echo "argument parsing"
for f in --name --model --direction --origin; do
  out="$(printf 'task\n' | run timeout 5 bash "$spawn" $f)"; rc=$?
  if [ $rc -eq 124 ]; then bad "$f with no value terminates" "hung"
  else check "$f with no value is an error" "requires a value" "$out"; fi
done
check "unknown argument is an error" "unknown argument" \
  "$(printf 'task\n' | run bash "$spawn" --nope)"
check "empty body is an error" "nothing to delegate" \
  "$(printf '   \n' | run bash "$spawn" --dry-run --name sub-x)"

echo "name validation"
for n in sub-1 sub_ok a good-name; do
  check "accepts $n" "would write" "$(printf 'task\n' | run bash "$spawn" --dry-run --name "$n")"
done
for n in 'sub.foo' 'a b' 'a/../escape' 'Sub' '1sub' 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'; do
  check "rejects $n" "must match" "$(printf 'task\n' | run bash "$spawn" --dry-run --name "$n")"
done

echo "template rendering"
weird="$fixture/a&b\\c"
mkdir -p "$weird"
out="$(cd "$weird" && printf 'task\n' | run bash "$spawn" --dry-run --name sub-meta)"
check "cwd with & and backslash survives" "Working directory: $weird" "$out"
case "$out" in *'{{CWD}}'*|*'{{PARENT}}'*|*'{{BODY}}'*)
  bad "no unreplaced placeholder remains" "found a {{...}} in the rendered briefing" ;;
  *) ok "no unreplaced placeholder remains" ;;
esac
out="$(printf 'task with & and \\ and "quotes" and `backticks`\n' | run bash "$spawn" --dry-run --name sub-body)"
check "body metacharacters survive" 'task with & and \ and "quotes" and `backticks`' "$out"
check "briefing carries the protocol" "## Protocol" "$out"

echo "path resolution"
check "briefing lands under CLAUDE_CONFIG_DIR" "$fixture/sub-tasks/sub-p.md" \
  "$(printf 'task\n' | run bash "$spawn" --dry-run --name sub-p)"
check "SUB_TASKS_DIR overrides it" "$fixture/elsewhere/sub-p.md" \
  "$(printf 'task\n' | SUB_TASKS_DIR="$fixture/elsewhere" run bash "$spawn" --dry-run --name sub-p)"
check "nickname comes from the registry" "Parent session nickname: test-parent" \
  "$(printf 'task\n' | run bash "$spawn" --dry-run --name sub-n)"
check "model falls back to settings" "on test-model" \
  "$(printf 'task\n' | run bash "$spawn" --dry-run --name sub-m)"

echo "hook argument handling"
payload() { jq -nc --arg a "$1" --arg c "${2:-/tmp}" \
  '{session_id:"test-session",cwd:$c,command_name:"sub:spawn",command_args:$a}'; }
check "empty task blocks with usage" "nothing to delegate" \
  "$(payload '' | run bash "$hook")"
check "unreachable cwd blocks" "cannot enter the invocation directory" \
  "$(payload 'do a thing' "$fixture/does-not-exist" | run bash "$hook")"
out="$(payload '--name sub.bad do a thing' | run bash "$hook")"
check "bad name blocks before any pane" "must match" "$out"
out="$(payload '--brief tidy the parser module' | run bash "$hook")"
check "--brief points at /sub:delegate" "/sub:delegate tidy the parser module" "$out"
check "--brief starts nothing" "Nothing was started" "$out"

echo "detached spawning"
check "the start is detached by default" "would detach the start" \
  "$(printf 'task\n' | run bash "$spawn" --dry-run --name sub-d)"
check "--wait opts back into the inline start" "would wait for the start inline" \
  "$(printf 'task\n' | run bash "$spawn" --dry-run --wait --name sub-s)"
check "--expect-context is gone" "unknown argument" \
  "$(printf 'task\n' | run bash "$spawn" --dry-run --expect-context --name sub-x)"

echo "relay record merging"
relay="$root/plugins/sub/scripts/relay.sh"
state="$fixture/sub-tasks/.state"
mkdir -p "$state"
rpay='{"session_id":"test-session"}'
# <name> <status-json...> -> writes a spawn record plus whatever follows
seed() { : >| "$state/test-session.jsonl"; for l in "$@"; do printf '%s\n' "$l" >> "$state/test-session.jsonl"; done; }
spawned() { jq -nc --arg n "$1" --argjson ts "${2:-$(date +%s)}" \
  '{name:$n,pane:"w1:p2",model:"m",cwd:"/tmp",briefing:"/b.md",task:"do the thing",origin:"hook",status:"starting",ts:$ts}'; }

seed "$(spawned sub-a)" '{"name":"sub-a","status":"started","nickname":"claude-x-1a"}'
out="$(printf '%s' "$rpay" | run bash "$relay")"
check "outcome merges onto the spawn record" "pane w1:p2" "$out"
check "merged record carries the address" "claude-x-1a" "$out"
check "merged record carries the task" "do the thing" "$out"
empty "resolved record is drained" "$(cat "$state/test-session.jsonl" 2>/dev/null)"

seed "$(spawned sub-b)" '{"name":"sub-b","status":"failed","error":"agent_not_ready"}'
out="$(printf '%s' "$rpay" | run bash "$relay")"
check "failure is reported, not swallowed" "FAILED TO START" "$out"
check "failure names the pane to look at" "w1:p2" "$out"

seed "$(spawned sub-c)"
empty "in-flight spawn is not reported yet" "$(printf '%s' "$rpay" | run bash "$relay")"
check "in-flight spawn is put back for the next turn" "sub-c" \
  "$(cat "$state/test-session.jsonl" 2>/dev/null)"

seed "$(spawned sub-e "$(( $(date +%s) - 600 ))")"
out="$(printf '%s' "$rpay" | run bash "$relay")"
check "a start that never landed is reported once stale" "never confirmed" "$out"

# The relay claims the state file by rename, so a finisher that appends its
# outcome in that window lands BEFORE the claimed "starting" record is restored.
# Merging in file order would let the stale record win and report a running sub as
# never confirmed, so the raced order has to resolve exactly like the natural one.
seed '{"name":"sub-r","status":"started","nickname":"claude-r-1"}' "$(spawned sub-r)"
out="$(printf '%s' "$rpay" | run bash "$relay")"
check "outcome wins when it lands before the restored record" "address: claude-r-1" "$out"
check "raced record is not held back" "pane w1:p2" "$out"
empty "raced record is drained" "$(cat "$state/test-session.jsonl" 2>/dev/null)"

seed '{"name":"sub-q","status":"failed","error":"agent_not_ready"}' "$(spawned sub-q)"
check "raced failure is still reported as a failure" "FAILED TO START" \
  "$(printf '%s' "$rpay" | run bash "$relay")"

seed "$(spawned sub-f)" '{"name":"sub-f","status":"started","nickname":"n1"}' \
     "$(spawned sub-g)" '{"name":"sub-g","status":"started","nickname":"n2"}'
out="$(printf '%s' "$rpay" | run bash "$relay")"
check "two subs are counted as plural" "2 sub-sessions are running" "$out"
# The context block is prose about backticks and addresses; an interpolating
# heredoc would run it instead of printing it.
check "guidance text survives shell expansion" 'the `address` above is a SendMessage nickname' "$out"
case "$out" in *"command not found"*|*"commande introuvable"*)
  bad "no shell expansion artifacts in the context" "found a command-not-found in the output" ;;
  *) ok "no shell expansion artifacts in the context" ;;
esac

echo "fallback pre-run"
lastspawn="$root/plugins/sub/scripts/last-spawn.sh"
lrun() { CLAUDE_CONFIG_DIR="$fixture" CLAUDE_PID=4242 HERDR_ENV=1 \
         SUB_TASKS_DIR="$fixture/sub-tasks" SUB_SESSION_ID=test-session "$@" 2>&1; }
seed "$(spawned sub-h)" '{"name":"sub-h","status":"started","nickname":"claude-h-9"}'
out="$(lrun bash "$lastspawn")"
check "pre-run survives the raced order too" "sub_nickname: claude-h-9" \
  "$(seed '{"name":"sub-h","status":"started","nickname":"claude-h-9"}' "$(spawned sub-h)"; lrun bash "$lastspawn")"
seed "$(spawned sub-h)" '{"name":"sub-h","status":"started","nickname":"claude-h-9"}'
out="$(lrun bash "$lastspawn")"
check "pre-run merges past the outcome record" "pane:        w1:p2" "$out"
check "pre-run reports the task, not null" "task_given:  do the thing" "$out"
check "pre-run takes the address from the outcome" "sub_nickname: claude-h-9" "$out"
: >| "$state/test-session.jsonl"
check "no spawn recorded reports NO_SPAWN" "NO_SPAWN" "$(lrun bash "$lastspawn")"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
