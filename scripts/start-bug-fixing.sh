#!/bin/bash
# For each issue in ready-issues.json, opens a dedicated git worktree + herdr pane, starts a
# real `claude` agent, and asks it to run this repo's bcx-bug-coder-agent to implement the
# already-approved resolution plan (the RCA comment thread on the issue). The coder agent
# itself never opens a PR (by design) - it just implements + comments. After it finishes,
# this script independently verifies the fix by actually running the repo's real build/test
# commands against the worktree, rather than trusting the agent's self-report. Result
# (pass/fail) is written to state/fix-<issue>.result for new-pull-request.sh to consume.
#
# Parallelism: each issue's full pipeline runs as one backgrounded bash job; a final `wait`
# blocks until all issues have been worked concurrently. See start-parallel-investigation.sh
# for why this must go through herdr_prompt_and_wait (--wait) rather than a fire-and-forget
# prompt - without --wait, herdr never delivers the submitting Enter keystroke.
#
# Usage: ./start-bug-fixing.sh [--branch <name>]
# --branch (default "main") must match whatever get-ready-issues.sh's issues were migrated
# with - it's the base the fix worktree/branch is created from, and must match what
# new-pull-request.sh is later given too.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/herdr.sh"
parse_common_args "$@"

if [ ! -f ready-issues.json ]; then
  log "ready-issues.json not found - run get-ready-issues.sh first"
  exit 1
fi

ensure_app_clone

count=$(jq 'length' ready-issues.json)
if [ "$count" -eq 0 ]; then
  log "No issues labeled '$PLAN_APPROVED_LABEL' - nothing to fix."
  exit 0
fi

log "Fixing $count issue(s)..."
jq -r '.[].number' ready-issues.json > "$TEMP_DIR/fixing-targets.txt"

fix_one() {
  local issue_number="$1"
  local name="fix-$issue_number"
  local branch="fix/$issue_number"
  local worktree_path
  worktree_path=$(ensure_worktree "issue-$issue_number" "$branch")
  local result_file="$STATE_DIR/fix-$issue_number.result"
  if [ -z "$worktree_path" ]; then
    log "[#$issue_number] Failed to create worktree, skipping"
    echo "FAIL worktree-create" > "$result_file"
    return 1
  fi

  local ws pane
  read -r ws pane <<< "$(herdr_open_pane "$worktree_path" "$name")"
  if [ -z "$pane" ]; then
    log "[#$issue_number] Failed to open pane, skipping"
    echo "FAIL pane-open" > "$result_file"
    return 1
  fi

  if ! herdr_start_claude "$name" "$pane"; then
    log "[#$issue_number] Failed to start claude agent, skipping"
    herdr_close_workspace "$ws"
    echo "FAIL agent-start" > "$result_file"
    return 1
  fi

  local prompt="Use the bcx-bug-coder-agent to implement the approved resolution plan for GitHub issue #$issue_number in $GITHUB_ORG/$GITHUB_REPO (see the issue comments for the plan from bcx-bug-rca-agent). Commit your changes when done."

  log "[#$issue_number] Prompting agent $name..."
  if ! herdr_prompt_and_wait "$name" "$prompt" "$HERDR_AGENT_TIMEOUT_MS"; then
    log "[#$issue_number] Agent did not settle in time - leaving pane open for manual inspection (workspace $ws)"
    echo "FAIL agent-timeout" > "$result_file"
    return 1
  fi

  herdr_capture "$name" 200 > "$TEMP_DIR/fix-$issue_number.log"
  herdr_close_workspace "$ws"

  log "[#$issue_number] Verifying: dotnet build..."
  local build_log="$TEMP_DIR/verify-$issue_number-build.log"
  if ! dotnet build "$worktree_path/src/web/Bcx6.Web.sln" > "$build_log" 2>&1; then
    log "[#$issue_number] Build FAILED - see $build_log"
    echo "FAIL build" > "$result_file"
    return 1
  fi

  log "[#$issue_number] Verifying: dotnet test..."
  local test_log="$TEMP_DIR/verify-$issue_number-test.log"
  if ! dotnet test "$worktree_path/tests/BCX6.Api.Tests/" > "$test_log" 2>&1; then
    log "[#$issue_number] Tests FAILED - see $test_log"
    echo "FAIL test" > "$result_file"
    return 1
  fi

  local changed_files
  changed_files=$(git -C "$worktree_path" diff --name-only origin/main...HEAD)
  if echo "$changed_files" | grep -q "^src/web/BCX.MVC/"; then
    log "[#$issue_number] Frontend files changed - running vitest..."
    local frontend_log="$TEMP_DIR/verify-$issue_number-frontend.log"
    if ! (cd "$worktree_path/src/web/BCX.MVC" && npm test -- --run > "$frontend_log" 2>&1); then
      log "[#$issue_number] Frontend tests FAILED - see $frontend_log"
      echo "FAIL frontend-test" > "$result_file"
      return 1
    fi
  fi

  log "[#$issue_number] Verified OK"
  echo "PASS" > "$result_file"
}

pids=()
while read -r issue_number; do
  fix_one "$issue_number" &
  pids+=($!)
done < "$TEMP_DIR/fixing-targets.txt"

failures=0
for pid in "${pids[@]}"; do
  wait "$pid" || failures=$((failures + 1))
done

log "Bug fixing pass complete ($failures failure(s))."
