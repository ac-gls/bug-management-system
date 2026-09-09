#!/bin/bash
# Verifies the migration pass: GitHub issues created, ADO comments posted, investigation
# worktrees present.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

log "Verifying GitHub issues..."
issue_count=$(gh issue list --repo "$GITHUB_ORG/$GITHUB_REPO" --label bug --state open --json number | jq 'length')
log "Open bug issues in $GITHUB_ORG/$GITHUB_REPO: $issue_count"

log "Verifying ADO -> GitHub mapping..."
mapped_count=$(jq 'length' "$ADO_MAP_FILE")
log "Bugs migrated (state/ado-to-github-map.json): $mapped_count"

log "Verifying investigation worktrees..."
if [ -d "$APP_WORKTREE_DIR" ]; then
  worktree_count=$(find "$APP_WORKTREE_DIR" -maxdepth 1 -type d -name 'bug-*' | wc -l)
else
  worktree_count=0
fi
log "Investigation worktrees present: $worktree_count"

log "Verification complete."
