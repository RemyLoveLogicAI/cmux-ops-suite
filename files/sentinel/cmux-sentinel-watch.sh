#!/bin/bash
# cmux-sentinel-watch.sh — launchd wrapper for cmux-sentinel-setup.sh.
# Runs the cheap no-layout pass every interval; only when it actually CREATED
# sentinels (i.e. they were missing after a cmux restart/window close) does it
# re-run the full pass so the new meters get parked below the list and ⌘9
# re-anchored. When nothing was created the layout pass never runs, so manual
# workspace ordering is never fought.
set -uo pipefail
OUT="$("$HOME/bin/cmux-sentinel-setup.sh" --no-layout 2>&1)"
RC=$?
printf '%s\n' "$OUT"
[ $RC -ne 0 ] && exit $RC
if printf '%s\n' "$OUT" | grep -q "created '"; then
  echo "--- sentinels were missing; running layout pass ---"
  "$HOME/bin/cmux-sentinel-setup.sh"
fi
exit 0
