#!/bin/bash
# Queries Azure DevOps for open Bug work items tagged $MIGRATION_TAG, excludes bugs already
# migrated (tracked in state/ado-to-github-map.json), and writes the result to ado-bugs.json
# in the current directory.
#
# Usage: ./get-ado-bugs.sh [--limit N]

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
parse_common_args "$@"

WIQL="SELECT [System.Id],[System.Title],[System.Description],[System.Tags],[System.State] FROM WorkItems WHERE [System.WorkItemType]='Bug' AND [System.Tags] CONTAINS '$MIGRATION_TAG' AND [System.State] NOT IN ('Closed','Resolved','Done')"

log "Querying ADO ($ADO_ORG / $ADO_PROJECT) for bugs tagged '$MIGRATION_TAG'..."

query_result=$(az boards query --organization "$ADO_ORG" --project "$ADO_PROJECT" --wiql "$WIQL" -o json 2>&1)
if [ $? -ne 0 ]; then
  log "az boards query failed:"
  echo "$query_result" >&2
  exit 1
fi

ids=$(echo "$query_result" | jq -r '.[].id')
if [ -z "$ids" ]; then
  log "No bugs found tagged '$MIGRATION_TAG'."
  echo "[]" > ado-bugs.json
  exit 0
fi

total_found=$(echo "$ids" | wc -w)
log "Found $total_found bug(s) tagged '$MIGRATION_TAG' total (before limit/already-tracked filtering)"

bugs_json="[]"
count=0
already_tracked=0
for id in $ids; do
  existing=$(ado_map_get "$id")
  if [ -n "$existing" ]; then
    already_tracked=$((already_tracked + 1))
    if [ "$existing" = "BLOCKED" ]; then
      log "Bug $id previously hit a blocker (needs more info) - skipping until state/ado-to-github-map.json is cleared for it"
    else
      log "Bug $id already migrated -> GitHub issue #$existing, skipping"
    fi
    continue
  fi

  item=$(az boards work-item show --id "$id" --organization "$ADO_ORG" -o json)
  # This org's Bug work items don't populate System.Description - the real content lives in
  # Microsoft.VSTS.TCM.ReproSteps plus custom fields. _links.html.href isn't present on this
  # API response shape either, so the human-facing URL is constructed directly.
  entry=$(echo "$item" | jq -c --arg org "$ADO_ORG" --arg project "$ADO_PROJECT" '{
    id: (.id | tostring),
    title: .fields."System.Title",
    description: (.fields."System.Description" // .fields."Microsoft.VSTS.TCM.ReproSteps" // ""),
    expected_results: (.fields."Custom.ExpectedResults" // ""),
    actual_results: (.fields."Custom.ActualResults" // ""),
    tenant_name: (.fields."Custom.TenantName" // ""),
    priority: (.fields."Microsoft.VSTS.Common.Priority" // 2),
    tags: (.fields."System.Tags" // ""),
    state: .fields."System.State",
    url: ($org + "/" + ($project | @uri) + "/_workitems/edit/" + (.id | tostring))
  }')
  bugs_json=$(echo "$bugs_json" | jq --argjson e "$entry" '. + [$e]')
  count=$((count + 1))
  if [ "$count" -ge "$LIMIT" ]; then
    break
  fi
done

echo "$bugs_json" > ado-bugs.json
remaining_new=$((total_found - already_tracked - count))
log "Including $count of $total_found bug(s) this run (limit=$LIMIT; $already_tracked already tracked). Wrote ado-bugs.json"
if [ "$remaining_new" -gt 0 ]; then
  log "$remaining_new new bug(s) left for a future run - pass --limit N to process more at once."
fi
