#!/bin/bash
# Finds bugs whose write-back from an earlier run is incomplete, and fixes them. For every bug
# in state/ado-to-github-map.json it checks:
#   - tracking issue #N: the ADO ticket has the "tracking issue created: #N" comment and
#     $MIGRATED_TAG (not $MIGRATION_TAG), and the issue is on the project board with its ADO
#     field set
#   - BLOCKED / ALREADY_FIXED: the ADO ticket has its outcome comment and $BLOCKED_TAG /
#     $ALREADY_FIXED_TAG (a missing comment is re-posted from temp/rca-<id>.md when that
#     report is still there)
# A run reports a step that failed as "issue-partial" or "ADO tag update FAILED" - this is
# what fixes those. Only missing pieces are written; anything already right is left alone.
#
# Usage: ./repair-ado.sh [--live] [ado-id ...]
# Dry run by default (reports only); --live applies the fixes. With ado-ids, checks only those.
# Exits non-zero if anything is still wrong afterwards.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
parse_common_args "$@"

ids=("${REMAINING_ARGS[@]}")
if [ ${#ids[@]} -eq 0 ]; then
  mapfile -t ids < <(jq -r 'keys[]' "$ADO_MAP_FILE")
fi
if [ ${#ids[@]} -eq 0 ]; then
  log "Nothing to check - $ADO_MAP_FILE is empty."
  exit 0
fi

has_tag() {
  local tags="$1" want="$2" tag
  local IFS=';'
  for tag in $tags; do
    [ "$(echo "$tag" | xargs)" = "$want" ] && return 0
  done
  return 1
}

# Prints every comment's text on the ticket (HTML), or fails.
ado_comments() {
  az_retry devops invoke --organization "$ADO_ORG" --area wit --resource comments \
    --route-parameters project="$ADO_PROJECT" workItemId="$1" --api-version 7.1-preview -o json \
    | jq -r '.comments[].text'
}

# Prints "ok", "missing" or "unknown: <error>" for the issue's project-board item + ADO field.
project_board_status() {
  local issue="$1" out
  if ! out=$(gh api graphql -f query='
      query($owner: String!, $repo: String!, $n: Int!) {
        repository(owner: $owner, name: $repo) { issue(number: $n) {
          projectItems(first: 20) { nodes {
            project { id }
            fieldValues(first: 50) { nodes {
              ... on ProjectV2ItemFieldTextValue { text field { ... on ProjectV2FieldCommon { id } } }
            } }
          } }
        } }
      }' -f owner="$GITHUB_ORG" -f repo="$GITHUB_REPO" -F n="$issue" 2>&1); then
    if grep -q INSUFFICIENT_SCOPES <<< "$out"; then
      echo "unknown: gh login lacks the 'project' scope (run scripts/authenticate.sh)"
    else
      echo "unknown: ${out//$'\n'/ }"
    fi
    return
  fi
  if jq -e --arg p "$BOOSTCX_DELIVERY_PROJECT_ID" --arg f "$BOOSTCX_DELIVERY_ADO_FIELD_ID" --arg v "$2" '
      [.data.repository.issue.projectItems.nodes[] | select(.project.id == $p)
       | .fieldValues.nodes[] | select(.field.id? == $f and .text == $v)] | length > 0' <<< "$out" >/dev/null; then
    echo ok
  else
    echo missing
  fi
}

broken=0 fixed=0 checked=0
for ado_id in "${ids[@]}"; do
  value=$(ado_map_get "$ado_id")
  if [ -z "$value" ]; then
    log "[$ado_id] not in $ADO_MAP_FILE - skipping"
    continue
  fi
  checked=$((checked + 1))

  case "$value" in
    BLOCKED)       want_tag="$BLOCKED_TAG";       comment_marker="More information is required before this bug can be investigated" ;;
    ALREADY_FIXED) want_tag="$ALREADY_FIXED_TAG"; comment_marker="Investigation found this bug is already fixed" ;;
    *)             want_tag="$MIGRATED_TAG";      comment_marker="tracking issue created: #$value " ;;
  esac

  if ! item=$(az_retry boards work-item show --id "$ado_id" --organization "$ADO_ORG" -o json); then
    log "[$ado_id] could not read the ADO ticket - skipping"
    broken=$((broken + 1))
    continue
  fi
  tags=$(jq -r '.fields."System.Tags" // ""' <<< "$item")
  problems=() still=()

  # Comment
  if ! comments=$(ado_comments "$ado_id"); then
    problems+=("comments unreadable"); still+=("comments unreadable")
  elif ! grep -qF "$comment_marker" <<< "$comments"; then
    problems+=("ADO comment missing")
    if [ "$LIVE" = true ]; then
      case "$value" in
        BLOCKED|ALREADY_FIXED)
          report="$TEMP_DIR/rca-$ado_id.md"
          if [ -f "$report" ]; then
            if [ "$value" = BLOCKED ]; then post_ado_blocker_comment "$ado_id" "$report"
            # The commit investigated isn't recorded for past runs.
            else post_ado_outcome_comment "$ado_id" "$report" "Investigation found this bug is already fixed - no GitHub issue was created." "$ALREADY_FIXED_TAG" ALREADY_FIXED
            fi
            [ $? -eq 1 ] && still+=("ADO comment")
          else
            still+=("ADO comment (report $report no longer exists - post it by hand)")
          fi ;;
        *)
          issue_url="https://github.com/$GITHUB_ORG/$GITHUB_REPO/issues/$value"
          az_retry boards work-item update --id "$ado_id" --organization "$ADO_ORG" \
            --discussion "RCA complete - tracking issue created: #$value ($issue_url)" >/dev/null \
            || still+=("ADO comment") ;;
      esac
    fi
  fi

  # Tag
  if ! has_tag "$tags" "$want_tag" || has_tag "$tags" "$MIGRATION_TAG"; then
    problems+=("ADO tag (has: ${tags:-none}; want $want_tag)")
    if [ "$LIVE" = true ]; then
      replace_ado_migration_tag "$ado_id" "$want_tag" || still+=("ADO tag")
    fi
  fi

  # Project board (tracking issues only)
  case "$value" in
    BLOCKED|ALREADY_FIXED) ;;
    *)
      board=$(project_board_status "$value" "$ado_id")
      case "$board" in
        ok) ;;
        missing)
          problems+=("not on project board")
          if [ "$LIVE" = true ]; then
            set_tracking_issue_project_fields "$value" "$ado_id" || still+=("project board")
          fi ;;
        *)
          problems+=("project board ${board#unknown: }"); still+=("project board (${board#unknown: })") ;;
      esac ;;
  esac

  label="$value"; [[ "$value" =~ ^[0-9]+$ ]] && label="#$value"
  if [ ${#problems[@]} -eq 0 ]; then
    log "[$ado_id] $label: ok"
    continue
  fi
  { IFS=,; problems_text="${problems[*]}"; still_text="${still[*]}"; unset IFS; }
  if [ "$LIVE" != true ]; then
    log "[$ado_id] $label: NEEDS REPAIR - $problems_text"
    broken=$((broken + 1))
  elif [ ${#still[@]} -eq 0 ]; then
    log "[$ado_id] $label: repaired - $problems_text"
    fixed=$((fixed + 1))
  else
    log "[$ado_id] $label: STILL BROKEN - $still_text (found: $problems_text)"
    broken=$((broken + 1))
  fi
done

log "Checked $checked bug(s): $fixed repaired, $broken still need attention."
if [ "$LIVE" != true ] && [ "$broken" -gt 0 ]; then
  log "This was a dry run - re-run with --live to apply the repairs."
fi
[ "$broken" -eq 0 ]
