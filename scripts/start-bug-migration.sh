#!/bin/bash
# Orchestrates the full migration pass: query ADO for tagged bugs -> parallel investigation
# via bcx-bug-rca-agent (one shared read-only worktree for the whole run, one agent per bug),
# each creating its own tracking GitHub issue from the resulting resolution plan.
#
# Usage: ./start-bug-migration.sh [--limit N] [--live] [--branch <name>]
# Defaults to --limit 1, dry-run (no --live), and base branch "main". Investigation itself
# always runs (it's non-destructive - a read-only worktree + an agent conversation);
# --live only gates whether the tracking issue and ADO comment-back actually get created.
# --branch applies to every bug processed in this invocation - if bugs need different base
# branches, run separately per branch/group of bugs.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
parse_common_args "$@"

ARGS=()
[ "$LIVE" = true ] && ARGS+=(--live)
ARGS+=(--branch "$BASE_BRANCH")

log "=== Phase 1: Querying ADO for tagged bugs ==="
"$SCRIPT_DIR/get-ado-bugs.sh" --limit "$LIMIT"

log "=== Phase 2: Parallel investigation (bcx-bug-rca-agent) ==="
"$SCRIPT_DIR/start-parallel-investigation.sh" "${ARGS[@]}"

log "Bug migration pass complete."
if [ "$LIVE" != true ]; then
  log "This was a dry run. Re-run with --live to actually create tracking issues and post ADO comments."
fi
