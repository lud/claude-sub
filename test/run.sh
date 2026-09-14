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

# A config directory the tests own, so nothing reads or writes the real one.
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/sessions" "$fixture/projects/p"
cat > "$fixture/sessions/4242.json" <<JSON
{"pid":4242,"sessionId":"test-session","name":"test-parent","cwd":"/tmp"}
JSON
printf '{"model":"test-model"}\n' > "$fixture/settings.json"

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
case "$out" in *'{{CWD}}'*|*'{{PARENT}}'*|*'{{BODY}}'*|*'{{AMENDMENT}}'*)
  bad "no unreplaced placeholder remains" "found a {{...}} in the rendered briefing" ;;
  *) ok "no unreplaced placeholder remains" ;;
esac
out="$(printf 'task with & and \\ and "quotes" and `backticks`\n' | run bash "$spawn" --dry-run --name sub-body)"
check "body metacharacters survive" 'task with & and \ and "quotes" and `backticks`' "$out"
check "amendment absent by default" "## Protocol" "$out"
check "amendment present with --expect-context" "Context is still coming" \
  "$(printf 'task\n' | run bash "$spawn" --dry-run --name sub-amend --expect-context)"

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

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
