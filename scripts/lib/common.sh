#!/bin/bash
# Shared helpers sourced by every pipeline script.
# Usage: source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR_SELF="$(cd "$LIB_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SCRIPTS_DIR_SELF/.." && pwd)"

source "$REPO_ROOT/configs/system.conf"
# Optional - only needed when tokens are used instead of interactive gh/az logins.
if [ -f "$REPO_ROOT/configs/credentials.conf" ]; then source "$REPO_ROOT/configs/credentials.conf"; fi

mkdir -p "$LOG_DIR" "$TEMP_DIR" "$STATE_DIR"

LIVE=false
LIMIT="$DEFAULT_LIMIT"
BASE_BRANCH="$DEFAULT_BASE_BRANCH"

# Parses --live, --limit N, and --branch <name> from a script's "$@"; leaves remaining args
# in REMAINING_ARGS. --branch overrides the default base ($DEFAULT_BASE_BRANCH) that the shared investigation
# worktree is checked out from - applies to every bug processed in this invocation. Bugs
# needing different base branches must be run in separate invocations grouped by branch.
parse_common_args() {
  REMAINING_ARGS=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --live) LIVE=true; shift ;;
      --limit) LIMIT="$2"; shift 2 ;;
      --branch) BASE_BRANCH="$2"; shift 2 ;;
      *) REMAINING_ARGS+=("$1"); shift ;;
    esac
  done
}

log() { echo "[$(date -u +%H:%M:%S 2>/dev/null || echo '--:--:--')] $*"; }

dry_run_note() {
  if [ "$LIVE" != true ]; then
    log "DRY RUN (pass --live to actually do this): $*"
    return 0
  fi
  return 1
}

# Verifies ADO and GitHub are both reachable and authenticated before anything else runs.
# Without this, an expired login or network blip made get-ado-bugs.sh fail its query while
# the rest of the pipeline carried on against a stale $ADO_BUGS_FILE from an earlier run -
# investigating (and marking Active) bugs that no longer matched the search criteria.
check_connections() {
  local ok=true out
  log "Checking Azure DevOps connection ($ADO_ORG / $ADO_PROJECT)..."
  if ! out=$(az devops project show --project "$ADO_PROJECT" --organization "$ADO_ORG" -o none 2>&1); then
    log "Azure DevOps connection check failed:"
    echo "$out" >&2
    ok=false
  fi
  log "Checking GitHub connection ($GITHUB_ORG/$GITHUB_REPO)..."
  if ! out=$(gh repo view "$GITHUB_ORG/$GITHUB_REPO" --json name 2>&1); then
    log "GitHub connection check failed:"
    echo "$out" >&2
    ok=false
  fi
  if [ "$ok" != true ]; then
    log "Connection check failed - run scripts/authenticate.sh (or fix connectivity) and retry."
    return 1
  fi
  log "Connections OK."
}

# Clones APP_REPO_DIR if missing, otherwise fetches latest.
ensure_app_clone() {
  # Without this, a plain `git clone` over https hangs indefinitely (no error, no prompt) on
  # any repo requiring auth, because WSL's native git has no credential helper configured -
  # `gh auth login`/`gh auth setup-git` only wire up whichever git the `gh` binary itself
  # shells out to, which on this machine is a wrapper around Windows' gh.exe, not WSL's git.
  if [ "$(git config --global --get credential.https://github.com.helper 2>/dev/null)" != "!gh auth git-credential" ]; then
    git config --global credential."https://github.com".helper "!gh auth git-credential"
  fi

  # Fail rather than carry on: investigating a missing or stale checkout would produce plans
  # against the wrong code.
  if [ ! -d "$APP_REPO_DIR/.git" ]; then
    log "Cloning $APP_REPO_URL -> $APP_REPO_DIR"
    git clone "$APP_REPO_URL" "$APP_REPO_DIR" || return 1
  else
    log "Fetching latest in $APP_REPO_DIR"
    git -C "$APP_REPO_DIR" fetch origin || return 1
  fi
  mkdir -p "$APP_WORKTREE_DIR"
  ensure_required_agents_installed
}

# The app repo is the source of truth for $RCA_AGENT_NAME (this pipeline just
# orchestrates worktrees/panes and asks a claude agent to run it by name) - it already exists
# there under .claude/agents/ and is committed to origin/main, so this is normally a no-op.
# It's a defensive fallback for a checkout that predates it (an older branch, a fork,
# APP_REPO_URL pointed elsewhere) using this repo's vendored copy in agents/, so a missing
# agent fails loudly here instead of confusingly deep inside a herdr pane. Never overwrites a
# file already present - a repo-side edit to the agent always wins.
ensure_required_agents_installed() {
  local dest_dir="$APP_REPO_DIR/.claude/agents" src name
  mkdir -p "$dest_dir"
  for src in "$REPO_ROOT"/agents/*.md; do
    name="$(basename "$src")"
    if [ ! -f "$dest_dir/$name" ]; then
      log "Installing missing required agent $name into $dest_dir"
      cp "$src" "$dest_dir/$name"
    fi
  done
}

# Creates (or reuses) a git worktree for a bug/issue off origin/<base>.
# Args: <worktree-name> <branch-name>
# `git worktree add` mutates shared metadata under $APP_REPO_DIR/.git/worktrees - running it
# concurrently for multiple bugs (the whole point of this pipeline) corrupts that metadata:
# some calls silently fail while others succeed, and the caller has no way to tell from git's
# own exit status alone. Confirmed in practice: with --limit 3, two of three worktrees never
# got created, and herdr opened those panes at $HOME instead - both agents then wrote to the
# same ~/RESOLUTION-PLAN.md and clobbered each other's reports.
# Fix: serialize `git worktree add` with flock, and verify the directory actually exists
# afterward instead of trusting git's exit code or blindly echoing the intended path.
WORKTREE_LOCK_FILE="$STATE_DIR/worktree.lock"

ensure_worktree() {
  local name="$1" branch="$2" base="${3:-$BASE_BRANCH}"
  local path="$APP_WORKTREE_DIR/$name"
  if [ -d "$path" ]; then
    echo "$path"
    return 0
  fi
  (
    flock -x 200
    if [ ! -d "$path" ]; then
      git -C "$APP_REPO_DIR" worktree add -b "$branch" "$path" "origin/$base" >&2
    fi
  ) 200>"$WORKTREE_LOCK_FILE"
  if [ ! -d "$path" ]; then
    echo "ensure_worktree: $path does not exist after git worktree add - see stderr above" >&2
    return 1
  fi
  echo "$path"
}

remove_worktree() {
  local path="$1"
  git -C "$APP_REPO_DIR" worktree remove --force "$path" 2>/dev/null || true
}

# Creates (or reuses) ONE shared, read-only worktree checked out directly on origin/<base> in
# a detached HEAD - no new branch, since nothing is ever committed here. Used by
# start-parallel-investigation.sh: bcx-bug-rca-agent never writes code (see
# agents/bcx-bug-rca-agent.md), so every bug investigated in one run can safely read the same
# checkout concurrently instead of each getting its own worktree. It exists only to isolate
# this run's code snapshot from whatever else is happening in $APP_REPO_DIR (e.g. a concurrent
# fixing pass) - the caller must remove_worktree it once every investigation in the run has
# finished; it is not meant to persist between runs.
# Args: <name> [base branch, default $BASE_BRANCH]
ensure_shared_readonly_worktree() {
  local name="$1" base="${2:-$BASE_BRANCH}"
  local path="$APP_WORKTREE_DIR/$name"
  if [ -d "$path" ]; then
    # Leftover from an earlier crashed run - re-point it at the latest fetched commit rather
    # than trusting whatever it happened to be checked out at.
    git -C "$path" checkout --detach "origin/$base" >&2 || return 1
    echo "$path"
    return 0
  fi
  (
    flock -x 200
    if [ ! -d "$path" ]; then
      git -C "$APP_REPO_DIR" worktree add --detach "$path" "origin/$base" >&2
    fi
  ) 200>"$WORKTREE_LOCK_FILE"
  if [ ! -d "$path" ]; then
    echo "ensure_shared_readonly_worktree: $path does not exist after git worktree add - see stderr above" >&2
    return 1
  fi
  echo "$path"
}

# Runs a command holding an exclusive lock on $STATE_DIR/<name>.lock, so the parallel
# investigation jobs never run it concurrently.
# Args: <lock-name> <command...>
with_lock() {
  local name="$1"; shift
  ( flock -x 200; "$@" ) 200>"$STATE_DIR/$name.lock"
}

# Runs an `az` command serialized across parallel jobs and retried, printing its stdout.
# Concurrent az invocations share one ~/.azure token cache and config, and fail when they race
# on it - the likely reason tickets from parallel runs silently missed their comment and tag
# update. On final failure, az's error goes to stderr (the bug's log) and this returns non-zero.
# Args: <az arguments...>
az_retry() {
  local attempt out err rc
  err=$(mktemp)
  for attempt in 1 2 3; do
    out=$(with_lock az az "$@" 2>"$err") && { rm -f "$err"; printf '%s' "$out"; return 0; }
    rc=$?
    [ "$attempt" -lt 3 ] && sleep $((attempt * 3))
  done
  echo "az $1 $2 failed after 3 attempts (exit $rc): $(cat "$err")" >&2
  rm -f "$err"
  return 1
}

ADO_MAP_FILE="$STATE_DIR/ado-to-github-map.json"
[ -f "$ADO_MAP_FILE" ] || echo '{}' > "$ADO_MAP_FILE"

ado_map_get() {
  jq -r --arg id "$1" '.[$id] // empty' "$ADO_MAP_FILE"
}

# Locked: parallel jobs finishing together would otherwise each read the map, add their own
# entry and write it back - the last write silently dropping the others' entries.
_ado_map_set_unlocked() {
  local id="$1" issue="$2" tmp
  tmp=$(mktemp)
  jq --arg id "$id" --arg issue "$issue" '.[$id] = $issue' "$ADO_MAP_FILE" > "$tmp" && mv "$tmp" "$ADO_MAP_FILE"
}
ado_map_set() { with_lock ado-map _ado_map_set_unlocked "$@"; }

# Sets the ADO ticket's State. Dry-run unless --live.
# Args: <ado-id> <state>
set_ado_state() {
  local ado_id="$1" state="$2"
  if [ "$LIVE" != true ]; then
    log "DRY RUN (pass --live to actually do this): az boards work-item update --id $ado_id --state $state"
    return 0
  fi
  az_retry boards work-item update --id "$ado_id" --organization "$ADO_ORG" --state "$state" >/dev/null
}

# Marks the ADO ticket $ADO_ACTIVE_STATE when get-ado-bugs.sh collects it (confirmed valid
# transition for this project's Bug workflow: New -> Active via Microsoft.VSTS.Actions.StartWork).
set_ado_active() { set_ado_state "$1" "$ADO_ACTIVE_STATE"; }

# Returns a collected bug that did not finish to $ADO_NEW_STATE, so the next run picks it up
# again - only $ADO_NEW_STATE bugs are collected, so without this a failed bug would sit in
# $ADO_ACTIVE_STATE forever, never retried. (Active -> New is a valid transition in this
# project's Bug workflow - confirmed against the work item type's transitions.)
# Args: <ado-id>
return_ado_to_new() {
  local ado_id="$1"
  if set_ado_state "$ado_id" "$ADO_NEW_STATE"; then
    log "[$ado_id] ADO state set back to $ADO_NEW_STATE so the next run retries it"
  else
    log "[$ado_id] WARNING: failed to set ADO state back to $ADO_NEW_STATE - set it by hand to have it retried"
    return 1
  fi
}

# Prints a curl config line authenticating to the ADO REST API, or fails. A PAT is preferred
# (AZURE_DEVOPS_EXT_PAT, as az devops itself uses, then ADO_PAT from credentials.conf), else an
# access token from an `az login` session. Printed as curl config (read with `curl -K -`) so
# the secret never appears on a command line / in the process list.
ado_rest_auth() {
  local pat="${AZURE_DEVOPS_EXT_PAT:-${ADO_PAT:-}}" token
  if [ -n "$pat" ]; then
    printf 'user = ":%s"\n' "$pat"
    return 0
  fi
  # 499b84ac-... is Azure DevOps' fixed application id.
  if token=$(az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 --query accessToken -o tsv 2>/dev/null) && [ -n "$token" ]; then
    printf 'header = "Authorization: Bearer %s"\n' "$token"
    return 0
  fi
  echo "ado_rest_auth: no ADO credential for REST calls - set ADO_PAT in configs/credentials.conf or run az login" >&2
  return 1
}

# Replaces the ticket's whole tag list with <tags> ("a; b; c") and prints the tags ADO now
# reports. This can't go through `az boards work-item update --fields System.Tags=...`: that
# sends a JSON-patch "add", which ADO treats as adding tags - it never removes any (confirmed
# live: MigrateToGitHub survived every swap, leaving tickets with both tags). And
# `az devops invoke` can't send the JSON-patch list a "replace" needs, so this calls the REST
# API directly.
# Args: <ado-id> <tags>
ado_set_tags() {
  local ado_id="$1" tags="$2" patch resp auth code attempt
  patch=$(mktemp) resp=$(mktemp)
  jq -n --arg v "$tags" '[{op: "replace", path: "/fields/System.Tags", value: $v}]' > "$patch"
  for attempt in 1 2 3; do
    if auth=$(ado_rest_auth); then
      code=$(printf '%s\n' "$auth" | curl -sS -K - -o "$resp" -w '%{http_code}' -X PATCH \
        -H "Content-Type: application/json-patch+json" --data @"$patch" \
        "$ADO_ORG/_apis/wit/workitems/$ado_id?api-version=7.1") || code=000
      if [ "$code" = 200 ]; then
        jq -r '.fields."System.Tags" // ""' "$resp"
        rm -f "$patch" "$resp"
        return 0
      fi
    else
      code=noauth
    fi
    [ "$attempt" -lt 3 ] && sleep $((attempt * 3))
  done
  echo "ado_set_tags: setting tags on $ado_id failed (HTTP $code): $(jq -r '.message // empty' "$resp" 2>/dev/null)" >&2
  rm -f "$patch" "$resp"
  return 1
}

# Swaps $MIGRATION_TAG for <new_tag> on the ADO ticket, preserving every other tag untouched.
# Reads the current tag string, splits on the confirmed "; " separator (verified live: e.g.
# "CORE; MigrateToGitHub"), drops $MIGRATION_TAG, appends <new_tag>, replaces the whole field
# (ado_set_tags), and verifies the result - fails unless ADO now reports <new_tag> and not
# $MIGRATION_TAG.
replace_ado_migration_tag() {
  local ado_id="$1" new_tag="$2"
  if [ "$LIVE" != true ]; then
    log "DRY RUN (pass --live to actually do this): replace tags on $ado_id: remove $MIGRATION_TAG, add $new_tag"
    return 0
  fi
  local current_tags joined tag item
  # Must not continue on a failed read: an empty tag list here would overwrite every other tag
  # on the ticket with just <new_tag>.
  item=$(az_retry boards work-item show --id "$ado_id" --organization "$ADO_ORG" -o json) || return 1
  current_tags=$(jq -r '.fields."System.Tags" // ""' <<< "$item") || return 1
  joined=""
  local IFS=';'
  for tag in $current_tags; do
    tag=$(echo "$tag" | xargs)
    [ -z "$tag" ] && continue
    [ "$tag" = "$MIGRATION_TAG" ] && continue
    [ "$tag" = "$new_tag" ] && continue
    if [ -z "$joined" ]; then joined="$tag"; else joined="$joined; $tag"; fi
  done
  if [ -z "$joined" ]; then joined="$new_tag"; else joined="$joined; $new_tag"; fi
  unset IFS
  local result
  result=$(ado_set_tags "$ado_id" "$joined") || return 1
  if ! grep -qE "(^|; )${new_tag}(;|$)" <<< "$result" || grep -qE "(^|; )${MIGRATION_TAG}(;|$)" <<< "$result"; then
    echo "replace_ado_migration_tag: $ado_id tags are '$result' after update - expected $new_tag without $MIGRATION_TAG" >&2
    return 1
  fi
}

# Outcomes where the agent's report replaces a resolution plan, so no GitHub issue is created:
# the report is posted as an ADO comment under <intro>, the ticket's tag is swapped from
# $MIGRATION_TAG to <tag> (so it naturally drops out of future WIQL queries filtered on
# $MIGRATION_TAG), and it's recorded as <map-value> in state/ado-to-github-map.json as a
# redundant safety net in case the tag write itself fails. Clear both to have it retried.
# Returns 0 when fully done, 1 when the comment couldn't be posted (nothing recorded), and 3
# when the comment was posted but the tag update failed (recorded; scripts/repair-ado.sh
# re-applies the tag).
# Args: <ado-id> <report-file> <intro> <tag> <map-value>
post_ado_outcome_comment() {
  local ado_id="$1" report_file="$2" intro="$3" tag="$4" map_value="$5"
  local detail
  detail=$(cat "$report_file")

  if [ "$LIVE" != true ]; then
    log "DRY RUN (pass --live to actually do this): az boards work-item update --id $ado_id --discussion '<report>' and tag $tag"
    echo "----- ADO comment preview for ADO-#$ado_id -----"
    echo "$intro"
    echo
    echo "$detail"
    echo "-------------------------------------------------"
    return 0
  fi

  # The comment is the whole point of this outcome - if it can't be posted, report failure so
  # the caller returns the bug to New and it's retried, rather than recording it as done.
  az_retry boards work-item update --id "$ado_id" --organization "$ADO_ORG" \
    --discussion "$intro

$detail" >/dev/null || return 1

  ado_map_set "$ado_id" "$map_value"
  if ! replace_ado_migration_tag "$ado_id" "$tag"; then
    echo "post_ado_outcome_comment: comment posted but tag update to $tag failed - run scripts/repair-ado.sh --live" >&2
    return 3
  fi
}

# The agent hit its own Step 0 "BLOCKER FOUND" case - not enough information to investigate.
# Args: <ado-id> <report-file>
post_ado_blocker_comment() {
  post_ado_outcome_comment "$1" "$2" \
    "More information is required before this bug can be investigated further." \
    "$BLOCKED_TAG" "BLOCKED"
}

# The agent found the bug already fixed in the investigated code - nothing to implement.
# Args: <ado-id> <report-file> <investigated-commit>
post_ado_already_fixed_comment() {
  post_ado_outcome_comment "$1" "$2" \
    "Investigation found this bug is already fixed in origin/$BASE_BRANCH @ $3 - no GitHub issue was created." \
    "$ALREADY_FIXED_TAG" "ALREADY_FIXED"
}

# Prints each of REQUIRED_REPORT_SECTIONS that <report-file> has no Markdown heading for, one
# per line (nothing when complete). Headings match case-insensitively at any level.
# Args: <report-file>
report_missing_sections() {
  local report_file="$1" section
  for section in "${REQUIRED_REPORT_SECTIONS[@]}"; do
    grep -qiE "^#{1,6}[[:space:]]+(\*\*)?${section}" "$report_file" || echo "$section"
  done
}

# Fills TRACKING_ISSUE_TEMPLATE's placeholders and prints the issue body.
# Args: <report-file> <ado-id> <ado-url> <ado-title> <commit>
render_tracking_issue_body() {
  local report_file="$1" ado_id="$2" ado_url="$3" ado_title="$4" commit="$5"
  local body report
  body=$(cat "$TRACKING_ISSUE_TEMPLATE") || return 1
  report=$(cat "$report_file")
  # bash 5.2+ treats '&' in a ${var//pattern/replacement} replacement as "the matched text",
  # which would corrupt any report containing '&&' or '&' - turn that off.
  shopt -u patsub_replacement 2>/dev/null || true
  body="${body//\{\{ADO_ID\}\}/$ado_id}"
  body="${body//\{\{ADO_URL\}\}/$ado_url}"
  body="${body//\{\{ADO_TITLE\}\}/$ado_title}"
  body="${body//\{\{BASE_BRANCH\}\}/$BASE_BRANCH}"
  body="${body//\{\{COMMIT\}\}/$commit}"
  # Last, so placeholder-like text inside the report itself is left untouched.
  body="${body//\{\{REPORT\}\}/$report}"
  printf '%s\n' "$body"
}

# Creates the GitHub tracking issue FROM a completed RCA report (its body IS the root cause
# analysis and resolution plan, not a copy of the ADO ticket), rendered through
# TRACKING_ISSUE_TEMPLATE, titled "$GITHUB_ISSUE_TITLE_PREFIX<title>". Records the ADO id ->
# issue mapping, comments back on the ADO ticket, and swaps its tag from $MIGRATION_TAG to
# $MIGRATED_TAG. Respects --live/dry-run: prints a preview and returns without creating
# anything real when not --live.
# Args: <ado-id> <bug-title> <ado-url> <report-file> <investigated-commit>
# Prints the new issue number (live only). Returns 0 when fully done, 3 when the issue was
# created but a follow-up step (ADO comment, ADO tag, project board) failed - the failures are
# logged and scripts/repair-ado.sh fixes them - and 1 when no issue was created.
create_tracking_issue() {
  local ado_id="$1" title="$2" ado_url="$3" report_file="$4" commit="$5"
  local issue_title="${GITHUB_ISSUE_TITLE_PREFIX}${title}"
  local body
  if ! body=$(render_tracking_issue_body "$report_file" "$ado_id" "$ado_url" "$title" "$commit"); then
    echo "create_tracking_issue: could not read template $TRACKING_ISSUE_TEMPLATE" >&2
    return 1
  fi

  # stdout is reserved for the issue number (callers capture it) - the dry-run preview goes to
  # stderr so it reaches the bug's log instead of vanishing into that capture.
  if [ "$LIVE" != true ]; then
    {
      log "DRY RUN (pass --live to actually do this): gh issue create --repo $GITHUB_ORG/$GITHUB_REPO --title '$issue_title' --type $GITHUB_ISSUE_TYPE --label $GITHUB_ISSUE_LABEL"
      echo "----- tracking issue body preview for ADO-#$ado_id -----"
      echo "$body"
      echo "----------------------------------------------------------"
    } >&2
    return 0
  fi

  local issue_url issue_number
  issue_url=$(gh issue create --repo "$GITHUB_ORG/$GITHUB_REPO" --title "$issue_title" --body "$body" --label "$GITHUB_ISSUE_LABEL" --type "$GITHUB_ISSUE_TYPE")
  issue_number=$(echo "$issue_url" | grep -oE '[0-9]+$')
  if [ -z "$issue_number" ]; then
    echo "create_tracking_issue: failed to parse issue number from: $issue_url" >&2
    return 1
  fi

  # The issue exists from here on - record it first, so a failure below can never lead to a
  # duplicate issue being created on a later run.
  ado_map_set "$ado_id" "$issue_number"

  local failed=()
  az_retry boards work-item update --id "$ado_id" --organization "$ADO_ORG" \
    --discussion "RCA complete - tracking issue created: #$issue_number ($issue_url)" >/dev/null \
    || failed+=("ADO comment")
  replace_ado_migration_tag "$ado_id" "$MIGRATED_TAG" || failed+=("ADO tag")
  set_tracking_issue_project_fields "$issue_number" "$ado_id" || failed+=("project board")

  echo "$issue_number"
  if [ ${#failed[@]} -gt 0 ]; then
    local IFS=,
    echo "create_tracking_issue: issue #$issue_number created, but these follow-up steps failed: ${failed[*]} - run scripts/repair-ado.sh --live" >&2
    return 3
  fi
}

# Adds the tracking issue to the "boostCX Delivery" org project and sets its ADO Linked
# Tickets field (bare ADO work item id, e.g. "145237"). Returns non-zero on failure (logged);
# create_tracking_issue reports that as a partial success rather than failing the whole issue.
set_tracking_issue_project_fields() {
  local issue_number="$1" ado_id="$2"
  local content_id
  content_id=$(gh issue view "$issue_number" --repo "$GITHUB_ORG/$GITHUB_REPO" --json id -q .id)
  if [ -z "$content_id" ]; then
    echo "set_tracking_issue_project_fields: could not resolve node id for issue #$issue_number" >&2
    return 1
  fi

  local item_id
  item_id=$(gh api graphql -f query='
    mutation($project: ID!, $content: ID!) {
      addProjectV2ItemById(input: {projectId: $project, contentId: $content}) { item { id } }
    }' -f project="$BOOSTCX_DELIVERY_PROJECT_ID" -f content="$content_id" \
    -q '.data.addProjectV2ItemById.item.id' 2>&1)
  if [ -z "$item_id" ] || [[ "$item_id" == *error* ]]; then
    echo "set_tracking_issue_project_fields: failed to add issue #$issue_number to boostCX Delivery project: $item_id" >&2
    return 1
  fi
  local out
  if ! out=$(gh api graphql -f query='
      mutation($project: ID!, $item: ID!, $field: ID!, $value: String!) {
        updateProjectV2ItemFieldValue(input: {projectId: $project, itemId: $item, fieldId: $field, value: {text: $value}}) { projectV2Item { id } }
      }' -f project="$BOOSTCX_DELIVERY_PROJECT_ID" -f item="$item_id" \
      -f field="$BOOSTCX_DELIVERY_ADO_FIELD_ID" -f value="${ado_id}" 2>&1); then
    echo "set_tracking_issue_project_fields: added issue #$issue_number to the project but failed to set its ADO field: $out" >&2
    return 1
  fi
}
