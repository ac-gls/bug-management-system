#!/bin/bash
# Main orchestration script. Runs a migration pass, then a fixing pass over whatever is
# already labeled plan-approved (typically nothing yet, right after a fresh migration -
# that label is added by a human after reviewing the RCA report on each issue).
#
# Usage: ./run-full-process.sh [--limit N] [--live] [--branch <name>]
# --branch applies to every bug processed in this invocation (default "main") - if bugs need
# different base branches, run separately per branch/group of bugs.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
parse_common_args "$@"

ARGS=()
[ "$LIVE" = true ] && ARGS+=(--live)
ARGS+=(--branch "$BASE_BRANCH")

echo "Starting Bug Management System..."

echo "Phase 1: Bug Migration"
"$SCRIPT_DIR/start-bug-migration.sh" --limit "$LIMIT" "${ARGS[@]}"

echo "Phase 2: Bug Fixing"
"$SCRIPT_DIR/get-ready-issues.sh" --limit "$LIMIT"
"$SCRIPT_DIR/start-bug-fixing.sh" "${ARGS[@]}"
"$SCRIPT_DIR/new-pull-request.sh" "${ARGS[@]}"
"$SCRIPT_DIR/verify-bug-fixes.sh"

echo "Bug Management System process completed!"
