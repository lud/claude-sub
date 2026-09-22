#!/usr/bin/env bash
# Close subs this session started and no longer needs: exit the session, close
# its pane, drop its briefing.
#
# What makes a sub disposable is that it has already reported. Until then its
# work is unfinished and only the sub knows how much of it is in its pane, so a
# sub that has not reported is left alone unless the user names it and --force
# says so. The same goes for one that is working or sitting at a dialog: it has
# been given something new since it reported, and that something is not ours.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

dry=0; force=0; pick_reported=0; names=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)  dry=1; shift ;;
    --force)    force=1; shift ;;
    --reported) pick_reported=1; shift ;;
    -*)         die "unknown argument: $1" ;;
    *)          names+=("$1"); shift ;;
  esac
done

require_herdr
rows="$(sub_rows)"
[ -n "${rows//[[:space:]]/}" ] || { echo "NO_SUBS"; exit 0; }

if [ "$pick_reported" -eq 1 ]; then
  while IFS=$'\t' read -r name _ status _ reported _; do
    [ -n "$name" ] || continue
    if [ "$reported" = yes ] || [ "$status" = gone ]; then names+=("$name"); fi
  done <<< "$rows"
fi
[ "${#names[@]}" -gt 0 ] || { echo "NOTHING_TO_PRUNE"; exit 0; }

row_for() { printf '%s\n' "$rows" | awk -F'\t' -v n="$1" '$1 == n { print; exit }'; }

closed=0; skipped=0
for name in "${names[@]}"; do
  row="$(row_for "$name")"
  if [ -z "$row" ]; then
    printf 'SKIPPED %s — not a sub of this session\n' "$name"; skipped=$((skipped+1)); continue
  fi
  IFS=$'\t' read -r _ pane status nick reported _ <<< "$row"

  if [ "$status" != gone ]; then
    if [ "$reported" != yes ] && [ "$force" -ne 1 ]; then
      printf 'SKIPPED %s — has not reported yet; its work is still in flight\n' "$name"
      skipped=$((skipped+1)); continue
    fi
    if [ "$status" != idle ] && [ "$force" -ne 1 ]; then
      printf 'SKIPPED %s — %s, so it has been given something since it reported\n' "$name" "$status"
      skipped=$((skipped+1)); continue
    fi
  fi

  briefing="$SUB_TASKS_DIR/$name.md"
  if [ "$dry" -eq 1 ]; then
    printf 'WOULD CLOSE %s — pane %s, status %s, address %s\n' "$name" "$pane" "$status" "$nick"
    closed=$((closed+1)); continue
  fi

  if [ "$status" = gone ]; then
    rm -f "$briefing"
    printf 'CLEARED %s — no session left, briefing removed\n' "$name"
    closed=$((closed+1)); continue
  fi

  # /exit first, so the session writes its own ending rather than being hung up
  # on. Closing the pane is what actually reclaims it either way.
  exited=yes
  herdr agent prompt "$name" "/exit" --wait --until done --timeout 15000 >/dev/null 2>&1 \
    || exited=no
  [ -z "$(pane_agent "$pane")" ] || exited=no
  herdr pane close "$pane" >/dev/null 2>&1 || true
  rm -f "$briefing"
  if [ "$exited" = yes ]; then
    printf 'CLOSED %s — exited, pane %s closed\n' "$name" "$pane"
  else
    printf 'CLOSED %s — pane %s closed, but it never confirmed the exit\n' "$name" "$pane"
  fi
  closed=$((closed+1))
done

printf '\n%s closed, %s left alone\n' "$closed" "$skipped"
