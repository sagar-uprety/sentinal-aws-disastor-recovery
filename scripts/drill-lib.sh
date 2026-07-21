#!/usr/bin/env bash

DRILL_LOG="${DRILL_LOG:-./drill-events.log}"

log_event() {
  printf '%s\t%s\n' "$1" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$DRILL_LOG"
}

record_event_at() {
  printf '%s\t%s\n' "$1" "$2" >>"$DRILL_LOG"
}

current_event_ts() {
  awk -F'\t' -v event="$1" '
    $1 == "drill_started" { found = 1; value = "" }
    found && $1 == event { value = $2 }
    END { print value }
  ' "$DRILL_LOG" 2>/dev/null
}

require_current_event() {
  local timestamp
  timestamp="$(current_event_ts "$1")"
  if [ -z "$timestamp" ]; then
    echo "ERROR: current drill has no $1 event in $DRILL_LOG." >&2
    exit 1
  fi
}

to_epoch() {
  local clean="${1%Z}"
  clean="${clean%+00:00}"
  clean="${clean%%.*}"
  date -u -j -f "%Y-%m-%dT%H:%M:%S" "$clean" +%s 2>/dev/null || date -u -d "${clean}Z" +%s
}
