#!/bin/bash
# For each issue in ready-issues.json, checks the verification result written by
# start-bug-fixing.sh (state/fix-<issue>.result). Opens a draft PR only if verification
# passed; otherwise posts the failure log as an issue comment instead. Mechanical - no AI
# agent involved, just gh calls, so no herdr needed here.
#
# Usage: ./new-pull-request.sh [--live] [--branch <name>]
# --branch must match whatever was passed to get-ready-issues.sh/start-bug-fixing.sh for
# these same issues (default "main") - it's not persisted anywhere, so passing a different
# value here than was used to create the fix branch will open the PR against the wrong base.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
parse_common_args "$@"

if [ ! -f ready-issues.json ]; then
  log "ready-issues.json not found - run get-ready-issues.sh first"
  exit 1
fi

jq -r '.[] | "\(.number)\t\(.title)"' ready-issues.json | while IFS=$'\t' read -r issue_number title; do
  result_file="$STATE_DIR/fix-$issue_number.result"
  if [ ! -f "$result_file" ]; then
    log "No verification result for issue #$issue_number - run start-bug-fixing.sh first, skipping"
    continue
  fi

  result=$(cat "$result_file")

  if [ "$result" != "PASS" ]; then
    reason="${result#FAIL }"
    log "Issue #$issue_number failed verification ($reason) - commenting instead of opening a PR"
    if dry_run_note "gh issue comment $issue_number --body 'Automated fix failed verification: $reason'"; then
      continue
    fi
    log_excerpt=$(tail -c 3000 "$TEMP_DIR/verify-$issue_number-"*.log 2>/dev/null)
    gh issue comment "$issue_number" --repo "$GITHUB_ORG/$GITHUB_REPO" --body "Automated fix failed verification (**$reason**). No PR was opened.

\`\`\`
${log_excerpt}
\`\`\`" >/dev/null
    continue
  fi

  if dry_run_note "gh pr create --repo $GITHUB_ORG/$GITHUB_REPO --draft --base $BASE_BRANCH --head fix/$issue_number --title 'Fix: $title'"; then
    continue
  fi

  ado_ref=""
  ado_id=$(grep -oE 'ADO-#[0-9]+' <<< "$(gh issue view "$issue_number" --repo "$GITHUB_ORG/$GITHUB_REPO" --json body -q .body)" | head -1)
  [ -n "$ado_id" ] && ado_ref=$'\n\n'"$ado_id"

  pr_url=$(gh pr create --repo "$GITHUB_ORG/$GITHUB_REPO" --draft --base "$BASE_BRANCH" --head "fix/$issue_number" \
    --title "Fix: $title" --body "Closes #$issue_number${ado_ref}")
  log "Opened draft PR for issue #$issue_number: $pr_url"
done
