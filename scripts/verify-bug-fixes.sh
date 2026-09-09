#!/bin/bash
# Verifies the fixing pass: PRs opened, verification results recorded.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

log "Verifying pull requests..."
pr_count=$(gh pr list --repo "$GITHUB_ORG/$GITHUB_REPO" --state open --json number | jq 'length')
log "Open PRs in $GITHUB_ORG/$GITHUB_REPO: $pr_count"

log "Verifying fix results..."
pass_count=$(grep -lE '^PASS$' "$STATE_DIR"/fix-*.result 2>/dev/null | wc -l)
fail_count=$(grep -lE '^FAIL' "$STATE_DIR"/fix-*.result 2>/dev/null | wc -l)
log "Fix verification results: $pass_count passed, $fail_count failed"

log "Verification complete."
