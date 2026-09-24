#!/bin/bash
# Queries Azure DevOps for $ADO_NEW_STATE-state $ADO_WORK_ITEM_TYPE work items tagged $MIGRATION_TAG,
# excludes bugs already migrated (tracked in state/ado-to-github-map.json), and writes the result
# to $ADO_BUGS_FILE. Each collected bug's ADO State is set to $ADO_ACTIVE_STATE,
# which also drops it out of this query on future runs. Dry-run unless --live is passed.
#
# Usage: ./get-ado-bugs.sh [--limit N] [--live]

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
parse_common_args "$@"

WIQL="SELECT [System.Id],[System.Title],[System.Description],[System.Tags],[System.State] FROM WorkItems WHERE [System.WorkItemType]='$ADO_WORK_ITEM_TYPE' AND [System.Tags] CONTAINS '$MIGRATION_TAG' AND [System.State] = '$ADO_NEW_STATE'"

# Never leave a previous run's results behind - if anything below fails, there must be no
# $ADO_BUGS_FILE for start-parallel-investigation.sh to pick up.
rm -f "$ADO_BUGS_FILE"

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
  echo "[]" > "$ADO_BUGS_FILE"
  exit 0
fi

total_found=$(echo "$ids" | wc -w)
log "Found $total_found bug(s) tagged '$MIGRATION_TAG' total (before limit/already-tracked filtering)"

bugs_json="[]"
count=0
already_tracked=0

# Bugs set Active below only reach start-parallel-investigation.sh via $ADO_BUGS_FILE. If this
# script dies before writing it (error, Ctrl-C), return them to $ADO_NEW_STATE rather than
# leaving them Active and never collected again.
collected_ids=()
bugs_file_written=false
return_collected_on_abort() {
  [ "$bugs_file_written" = true ] && return
  local id
  for id in "${collected_ids[@]}"; do return_ado_to_new "$id"; done
}
trap return_collected_on_abort EXIT
trap 'exit 130' INT TERM
for id in $ids; do
  existing=$(ado_map_get "$id")
  if [ -n "$existing" ]; then
    already_tracked=$((already_tracked + 1))
    if [ "$existing" = "BLOCKED" ]; then
      log "Bug $id previously hit a blocker (needs more info) - skipping until state/ado-to-github-map.json is cleared for it"
    elif [ "$existing" = "ALREADY_FIXED" ]; then
      log "Bug $id was found already fixed - skipping until state/ado-to-github-map.json is cleared for it"
    else
      log "Bug $id already migrated -> GitHub issue #$existing, skipping"
    fi
    continue
  fi

  if ! item=$(az boards work-item show --id "$id" --organization "$ADO_ORG" -o json); then
    # Skip rather than abort: bugs already collected this run have been set Active and must
    # still reach $ADO_BUGS_FILE. This one is left $ADO_NEW_STATE, so the next run picks it up.
    log "Bug $id: failed to fetch work item - skipping (left in $ADO_NEW_STATE for a future run)"
    continue
  fi
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
  if set_ado_active "$id"; then
    collected_ids+=("$id")
  else
    log "Bug $id: failed to set ADO state to $ADO_ACTIVE_STATE (continuing)"
  fi
  if [ "$count" -ge "$LIMIT" ]; then
    break
  fi
done

echo "$bugs_json" > "$ADO_BUGS_FILE" && bugs_file_written=true
remaining_new=$((total_found - already_tracked - count))
log "Including $count of $total_found bug(s) this run (limit=$LIMIT; $already_tracked already tracked). Wrote $ADO_BUGS_FILE"
if [ "$remaining_new" -gt 0 ]; then
  log "$remaining_new new bug(s) left for a future run - pass --limit N to process more at once."
fi
