#!/bin/bash
# Lists open GitHub issues labeled $PLAN_APPROVED_LABEL (a human added this after reviewing
# the bcx-bug-rca-agent resolution plan posted as a comment) and writes them to
# ready-issues.json in the current directory.
#
# Usage: ./get-ready-issues.sh [--limit N]

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
parse_common_args "$@"

log "Querying $GITHUB_ORG/$GITHUB_REPO for issues labeled '$PLAN_APPROVED_LABEL'..."

issues=$(gh issue list --repo "$GITHUB_ORG/$GITHUB_REPO" --label "$PLAN_APPROVED_LABEL" --state open --json number,title,body,comments --limit "$LIMIT")

echo "$issues" > ready-issues.json
count=$(echo "$issues" | jq 'length')
log "Found $count issue(s) ready for fixing. Wrote ready-issues.json"
