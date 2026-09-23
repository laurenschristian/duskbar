#!/bin/sh
# Fails when the installed DuskBar breaks its resource budget.
# SAMPLES x 10 s of CPU sampling (default 30 = 5 min).
set -e
APP=/Applications/DuskBar.app
SAMPLES=${SAMPLES:-30}
MAX_FOOTPRINT_KB=25600
MAX_BUNDLE_KB=700
MAX_CPU=0.1
MAX_WAKEUPS_PER_MIN=3

pgrep -x DuskBar >/dev/null || { open "$APP"; sleep 60; }
pid=$(pgrep -x DuskBar)
fail=0

footprint_kb=$(footprint -p "$pid" | awk '/phys_footprint:/ { v = $2; if ($3 == "MB") v *= 1024; if ($3 == "GB") v *= 1048576; print int(v); exit }')
bundle_kb=$(du -sk "$APP" | cut -f1)
# First top sample has no delta, so drop it.
stats=$(top -l $((SAMPLES + 1)) -s 10 -pid "$pid" -stats cpu,idlew | awk 'NF == 2 && $1 ~ /^[0-9.]+$/' | tail -n "$SAMPLES")
cpu=$(echo "$stats" | awk '{ s += $1 } END { printf "%.2f", s / NR }')
wakeups=$(echo "$stats" | awk '{ s += $2 } END { printf "%.1f", s / NR * 6 }')

check() {
  if awk "BEGIN { exit !($2 <= $3) }"; then echo "ok    $1: $2 (max $3)"; else echo "FAIL  $1: $2 (max $3)"; fail=1; fi
}
check "footprint KB" "$footprint_kb" "$MAX_FOOTPRINT_KB"
check "bundle KB" "$bundle_kb" "$MAX_BUNDLE_KB"
check "avg CPU %" "$cpu" "$MAX_CPU"
check "idle wakeups/min" "$wakeups" "$MAX_WAKEUPS_PER_MIN"
exit $fail
