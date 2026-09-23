#!/bin/bash
# Main entry point. This system is scoped to ADO -> GitHub issue creation only: query ADO for
# tagged bugs, investigate each via bcx-bug-rca-agent, and create a tracking GitHub issue from
# the resulting resolution plan (or comment back on ADO if the agent hit a blocker). It does
# not implement fixes or open PRs - a human takes it from the tracking issue onward.
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
"$SCRIPT_DIR/start-bug-migration.sh" --limit "$LIMIT" "${ARGS[@]}"
echo "Bug Management System process completed!"
