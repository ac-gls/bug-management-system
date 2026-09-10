#!/bin/bash
# Live status table for the terminal the orchestrator script itself runs in - the main herdr
# space/pane, as opposed to the individual per-bug herdr panes each investigate_one agent runs
# in. Without this, every concurrent background job's `log` lines interleave onto that same
# main terminal and become unreadable past 2-3 bugs running at once. Instead, each job reports
# its own progress into a small per-bug status file and has its own `log` output redirected to
# a per-bug log file, so the main terminal shows one clean, continuously-redrawn table while
# full detail for any bug stays available in its log file for follow-up.
#
# Usage (see start-parallel-investigation.sh):
#   for id in "${ids[@]}"; do set_bug_status "$id" queued; done
#   job_one "$id" ... > "$TEMP_DIR/log-$id.txt" 2>&1 &   # job_one calls set_bug_status as it goes
#   run_status_ui "${ids[@]}"                             # blocks in the main pane until every
#                                                          # id reaches a terminal status

# Args: <id> <status> [detail]
set_bug_status() {
  local id="$1" status="$2" detail="${3:-}"
  echo "${status}|${detail}" > "$TEMP_DIR/status-$id.status"
}

get_bug_status() {
  cat "$TEMP_DIR/status-$1.status" 2>/dev/null || echo "queued|"
}

# A status this bug will not move on from without a new run - the UI loop stops waiting on it.
is_terminal_status() {
  case "$1" in
    issue-created|dry-run|blocked|failed) return 0 ;;
    *) return 1 ;;
  esac
}

render_status_table() {
  local ids=("$@") id line status detail
  if [ -t 1 ]; then
    printf '\033[H\033[2J'
  fi
  printf '%-10s %-14s %s\n' "ADO ID" "STATUS" "DETAIL"
  printf '%-10s %-14s %s\n' "------" "------" "------"
  for id in "${ids[@]}"; do
    line=$(get_bug_status "$id")
    status="${line%%|*}"
    detail="${line#*|}"
    printf '%-10s %-14s %s\n' "$id" "$status" "$detail"
  done
}

# Blocks in the foreground, redrawing the table every 2s, until every id has reached a
# terminal status (see is_terminal_status). Safe to call even if jobs have already finished by
# the time this runs. Not a substitute for the caller's own `wait` on the job PIDs - this only
# watches self-reported status files, so still `wait` afterward to collect real exit codes.
run_status_ui() {
  local ids=("$@") id line status all_done
  while true; do
    render_status_table "${ids[@]}"
    all_done=true
    for id in "${ids[@]}"; do
      line=$(get_bug_status "$id")
      status="${line%%|*}"
      is_terminal_status "$status" || all_done=false
    done
    [ "$all_done" = true ] && break
    sleep 2
  done
}
