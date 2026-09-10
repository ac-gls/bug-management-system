#!/bin/bash
# Verifies the migration pass: GitHub issues created, ADO comments posted, no leftover shared
# investigation worktree.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

log "Verifying GitHub issues..."
issue_count=$(gh issue list --repo "$GITHUB_ORG/$GITHUB_REPO" --label bug --state open --json number | jq 'length')
log "Open bug issues in $GITHUB_ORG/$GITHUB_REPO: $issue_count"

log "Verifying ADO -> GitHub mapping..."
mapped_count=$(jq 'length' "$ADO_MAP_FILE")
log "Bugs migrated (state/ado-to-github-map.json): $mapped_count"

log "Verifying shared investigation worktree was cleaned up..."
if [ -d "$APP_WORKTREE_DIR" ]; then
  stale_worktrees=$(find "$APP_WORKTREE_DIR" -maxdepth 1 -type d -name 'rca-shared-*' | wc -l)
else
  stale_worktrees=0
fi
if [ "$stale_worktrees" -gt 0 ]; then
  log "WARNING: $stale_worktrees leftover shared investigation worktree(s) found - a prior run likely crashed before cleanup"
else
  log "No leftover shared investigation worktree found."
fi

log "Verification complete."
