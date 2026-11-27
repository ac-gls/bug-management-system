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

# True only if <path> is itself the top level of a git checkout - a plain `git -C` check
# alone would also pass for any directory nested inside some other repo.
is_worktree_root() {
  local top
  [ -e "$1/.git" ] || return 1
  top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || return 1
  [ "$(realpath "$top")" = "$(realpath "$1")" ]
}

# Moves any RESOLUTION-PLAN-<id>.md files out of <dir> into $TEMP_DIR as
# late-RESOLUTION-PLAN-<id>-<timestamp>.md, so a human can review them.
salvage_late_reports() {
  local dir="$1" f dest
  for f in "$dir"/RESOLUTION-PLAN-*.md; do
    [ -f "$f" ] || continue
    dest="$TEMP_DIR/late-$(basename "$f" .md)-$(date +%Y%m%d%H%M%S).md"
    mv "$f" "$dest"
    log "Found a report written after its run finished: saved to $dest (not turned into an issue - review it manually)" >&2
  done
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
    # Any report there was written after its run stopped watching (e.g. an agent left open
    # for inspection that resumed after a usage-limit pause). Save it so the work isn't lost;
    # it is never turned into an issue automatically.
    salvage_late_reports "$path"
  fi
  if [ -d "$path" ] && ! is_worktree_root "$path"; then
    # Not a worktree, even though the directory exists. Confirmed in practice: the run removed
    # the worktree, then a still-running agent wrote its report into the deleted path, which
    # brought it back as a plain directory. `git -C` on it then searches the parent
    # directories and fails with "not a git repository".
    echo "ensure_shared_readonly_worktree: $path exists but is not a git worktree - removing it and creating a fresh one" >&2
    rm -rf "$path"
    git -C "$APP_REPO_DIR" worktree prune >&2
  fi
  if [ -d "$path" ]; then
    # Left by an earlier run (crashed, or kept for open panes) - re-point it at the latest
    # fetched commit rather than trusting whatever it happened to be checked out at.
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

# Exact, case-insensitive tag membership (ADO tag queries are case-insensitive too).
has_tag() {
  jq -ne --arg tags "$1" --arg want "$2" '
    $tags | split(";") | any(.[]; (gsub("^\\s+|\\s+$"; "") | ascii_downcase) == ($want | ascii_downcase))' >/dev/null
}

# A rerun request is collected from the intake state or the re-opened state.
is_rerun_intake_state() {
  [ "$1" = "$ADO_NEW_STATE" ] || { [ -n "${ADO_REOPENED_STATE:-}" ] && [ "$1" = "$ADO_REOPENED_STATE" ]; }
}

ADO_MAP_FILE="$STATE_DIR/ado-to-github-map.json"
ADO_RERUN_FILE="$STATE_DIR/ado-rerun-state.json"
ADO_HISTORY_FILE="$STATE_DIR/ado-outcome-history.json"

ado_rerun_get() {
  [ -f "$ADO_RERUN_FILE" ] || { echo '{}'; return; }
  jq -c --arg id "$1" '.[$id] // {}' "$ADO_RERUN_FILE"
}

# Retain the linked issue even if a later investigation ends BLOCKED/ALREADY_FIXED.
ado_linked_issue() {
  local value
  value=$(ado_map_get "$1") || return 1
  if [[ "$value" =~ ^[0-9]+$ ]]; then printf '%s\n' "$value"; return; fi
  ado_rerun_get "$1" | jq -r '.issue // empty'
}

_ado_rerun_set_unlocked() {
  local id="$1" status="$2" issue="$3" outcome="${4:-$3}" tmp source_file="$ADO_RERUN_FILE"
  [ -f "$source_file" ] || source_file=/dev/stdin
  tmp=$(mktemp "$STATE_DIR/rerun.XXXXXX")
  jq --arg id "$id" --arg status "$status" --arg issue "$issue" --arg outcome "$outcome" \
    '.[$id] = {status: $status, issue: $issue, outcome: $outcome}' "$source_file" <<< '{}' > "$tmp" \
    && mv "$tmp" "$ADO_RERUN_FILE"
}
ado_rerun_set() { with_lock ado-map _ado_rerun_set_unlocked "$@"; }

# Used by collection AND standalone live investigation of a dry-run collection file.
prepare_ado_rerun() {
  [ "$LIVE" = true ] || return 0
  local issue
  issue=$(ado_linked_issue "$1") || return 1
  ado_rerun_set "$1" pending "$issue"
}

ado_rerun_complete() {
  local record issue
  record=$(ado_rerun_get "$1") || return 1
  [ -n "$(jq -r '.status // empty' <<< "$record")" ] || return 0
  issue=$(ado_linked_issue "$1") || return 1
  ado_rerun_set "$1" completed "$issue" "${2:-$issue}"
}

ado_map_get() {
  [ -f "$ADO_MAP_FILE" ] || return 0
  jq -r --arg id "$1" '.[$id] // empty' "$ADO_MAP_FILE"
}

# Locked: parallel jobs finishing together would otherwise each read the map, add their own
# entry and write it back - the last write silently dropping the others' entries.
_ado_map_set_unlocked() {
  local id="$1" issue="$2" tmp history_tmp previous source_file="$ADO_HISTORY_FILE"
  previous=$(ado_map_get "$id") || return 1
  [ -f "$source_file" ] || source_file=/dev/stdin
  history_tmp=$(mktemp "$STATE_DIR/history.XXXXXX")
  jq --arg id "$id" --arg previous "$previous" --arg outcome "$issue" \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.[$id] = ((.[$id] // []) + [{at: $at, previous: $previous, outcome: $outcome}])' \
    "$source_file" <<< '{}' > "$history_tmp" && mv "$history_tmp" "$ADO_HISTORY_FILE" || return 1
  source_file="$ADO_MAP_FILE"
  [ -f "$source_file" ] || source_file=/dev/stdin
  tmp=$(mktemp "$STATE_DIR/map.XXXXXX")
  jq --arg id "$id" --arg issue "$issue" '.[$id] = $issue' "$source_file" <<< '{}' > "$tmp" && mv "$tmp" "$ADO_MAP_FILE"
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

# Replaces request and stale outcome tags with <new_tag>, preserving unrelated tags.
# Completion consumes ReRunRequested; failed investigations leave it in place for retry.
replace_ado_migration_tag() {
  local ado_id="$1" new_tag="$2"
  if [ "$LIVE" != true ]; then
    log "DRY RUN (pass --live to actually do this): replace request/outcome tags on $ado_id with $new_tag"
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
    tag=$(jq -nr --arg tag "$tag" '$tag | gsub("^\\s+|\\s+$"; "")')
    [ -z "$tag" ] && continue
    if has_tag "$tag" "$MIGRATION_TAG" || has_tag "$tag" "$RERUN_REQUESTED_TAG" \
      || has_tag "$tag" "$MIGRATED_TAG" || has_tag "$tag" "$BLOCKED_TAG" \
      || has_tag "$tag" "$ALREADY_FIXED_TAG" || has_tag "$tag" "$new_tag"; then continue; fi
    if [ -z "$joined" ]; then joined="$tag"; else joined="$joined; $tag"; fi
  done
  if [ -z "$joined" ]; then joined="$new_tag"; else joined="$joined; $new_tag"; fi
  unset IFS
  local result
  result=$(ado_set_tags "$ado_id" "$joined") || return 1
  if ! has_tag "$result" "$new_tag" || has_tag "$result" "$MIGRATION_TAG" || has_tag "$result" "$RERUN_REQUESTED_TAG"; then
    echo "replace_ado_migration_tag: $ado_id tags are '$result' after update - expected $new_tag without request tags" >&2
    return 1
  fi
  local outcome_tag
  for outcome_tag in "$MIGRATED_TAG" "$BLOCKED_TAG" "$ALREADY_FIXED_TAG"; do
    if [ "$outcome_tag" != "$new_tag" ] && has_tag "$result" "$outcome_tag"; then
      echo "replace_ado_migration_tag: $ado_id still has stale outcome tag $outcome_tag" >&2
      return 1
    fi
  done
}

# Outcomes where the agent's report replaces a resolution plan, so no GitHub issue is created:
# the report is posted as an ADO comment under <intro>, the ticket's tag is swapped from
# $MIGRATION_TAG to <tag> (so it naturally drops out of future WIQL queries filtered on
# $MIGRATION_TAG), and it's recorded as <map-value> in state/ado-to-github-map.json as a
# redundant safety net in case the tag write itself fails. Request a rerun via the explicit
# $RERUN_REQUESTED_TAG in $ADO_NEW_STATE, without clearing the map.
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

  # Preserve the old GitHub link before replacing the latest outcome with a sentinel.
  # A failed ledger write is retryable: leave the request and old map intact.
  ado_rerun_complete "$ado_id" "$map_value" || return 1
  ado_map_set "$ado_id" "$map_value" || return 3
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
# Args: <ado-id> <bug-title> <ado-url> <report-file> <investigated-commit> [rerun: true|false]
# Reruns reuse the retained issue link, archive its old body in a comment, and reopen it.
# Prints the issue number (live only). Returns 0 when fully done, 3 for a saved result needing
# repair (ADO comment/tag, project board, issue fields or map), and 1 for a retryable failure.
# A rerun can update GitHub before a later step fails; its saved link prevents duplicates.
create_tracking_issue() {
  local ado_id="$1" title="$2" ado_url="$3" report_file="$4" commit="$5" rerun="${6:-false}"
  local issue_title="${GITHUB_ISSUE_TITLE_PREFIX}${title}"
  local body linked_issue=""
  if [ "$rerun" = true ]; then
    linked_issue=$(ado_linked_issue "$ado_id") || return 1
  elif [ "$LIVE" = true ] && [ "$(ado_rerun_get "$ado_id")" != '{}' ]; then
    # A manual normal-migration reset can retain an older completion ledger. Invalidate its
    # authority BEFORE creating another issue, so failed completion writes cannot restore it.
    prepare_ado_rerun "$ado_id" || return 1
  fi
  if ! body=$(render_tracking_issue_body "$report_file" "$ado_id" "$ado_url" "$title" "$commit"); then
    echo "create_tracking_issue: could not read template $TRACKING_ISSUE_TEMPLATE" >&2
    return 1
  fi

  # stdout is reserved for the issue number (callers capture it) - the dry-run preview goes to
  # stderr so it reaches the bug's log instead of vanishing into that capture.
  if [ "$LIVE" != true ]; then
    {
      if [ -n "$linked_issue" ]; then
        log "DRY RUN: preserve prior report, update and reopen GitHub issue #$linked_issue"
      else
        log "DRY RUN (pass --live to actually do this): gh issue create --repo $GITHUB_ORG/$GITHUB_REPO --title '$issue_title' --type $GITHUB_ISSUE_TYPE --label $GITHUB_ISSUE_LABEL"
      fi
      echo "----- tracking issue body preview for ADO-#$ado_id -----"
      echo "$body"
      echo "----------------------------------------------------------"
    } >&2
    return 0
  fi

  local issue_url issue_number action=created previous
  if [ -n "$linked_issue" ]; then
    issue_number="$linked_issue"
    # Never create a replacement if the linked issue is inaccessible. Retry safely instead.
    previous=$(gh issue view "$issue_number" --repo "$GITHUB_ORG/$GITHUB_REPO" --json body,state,url) || return 1
    issue_url=$(jq -r '.url' <<< "$previous")
    if [ "$(jq -r '.body // ""' <<< "$previous")" != "$body" ]; then
      gh issue comment "$issue_number" --repo "$GITHUB_ORG/$GITHUB_REPO" \
        --body "Previous RCA / resolution plan before ADO-#$ado_id rerun:

$(jq -r '.body // ""' <<< "$previous")" >/dev/null || return 1
    fi
    gh issue edit "$issue_number" --repo "$GITHUB_ORG/$GITHUB_REPO" --title "$issue_title" --body "$body" >/dev/null || return 1
    if [ "$(jq -r '.state' <<< "$previous")" = CLOSED ]; then
      gh issue reopen "$issue_number" --repo "$GITHUB_ORG/$GITHUB_REPO" >/dev/null || return 1
    fi
    action="updated after rerun"
  else
    issue_url=$(gh issue create --repo "$GITHUB_ORG/$GITHUB_REPO" --title "$issue_title" --body "$body" --label "$GITHUB_ISSUE_LABEL" --type "$GITHUB_ISSUE_TYPE") || return 1
    issue_number=$(echo "$issue_url" | grep -oE '[0-9]+$')
    if [ -z "$issue_number" ]; then
      echo "create_tracking_issue: failed to parse issue number from: $issue_url" >&2
      return 1
    fi
  fi

  # Persist the link before replacing a sentinel outcome or attempting ADO write-back.
  local failed=()
  ado_map_set "$ado_id" "$issue_number" || failed+=("outcome map")
  if { [ "$rerun" = true ] || [ "$(ado_rerun_get "$ado_id")" != '{}' ]; } \
    && ! ado_rerun_set "$ado_id" completed "$issue_number"; then
    echo "create_tracking_issue: issue #$issue_number updated/created but completion state could not be saved; request retained for retry" >&2
    # With the issue mapped, an explicit rerun cannot create a duplicate. Do not consume tags.
    if [ "$rerun" != true ]; then
      echo "create_tracking_issue: add $RERUN_REQUESTED_TAG in $ADO_NEW_STATE to retry this manually reset migration safely" >&2
    fi
    if [ ${#failed[@]} -eq 0 ]; then return 1; fi
    echo "create_tracking_issue: outcome map also failed - record issue #$issue_number manually before retrying" >&2
    echo "$issue_number"
    return 3
  fi
  az_retry boards work-item update --id "$ado_id" --organization "$ADO_ORG" \
    --discussion "RCA complete - tracking issue $action: #$issue_number ($issue_url)" >/dev/null \
    || failed+=("ADO comment")
  replace_ado_migration_tag "$ado_id" "$MIGRATED_TAG" || failed+=("ADO tag")
  add_tracking_issue_to_project "$issue_number" || failed+=("project board")
  set_tracking_issue_fields "$issue_number" "$ado_id" || failed+=("issue fields")

  echo "$issue_number"
  if [ ${#failed[@]} -gt 0 ]; then
    local IFS=,
    echo "create_tracking_issue: issue #$issue_number $action, but these follow-up steps failed: ${failed[*]} - run scripts/repair-ado.sh --live" >&2
    return 3
  fi
}

# Adds the tracking issue to the "boostCX Delivery" org project (a no-op when it's already
# there). Returns non-zero on failure (logged); create_tracking_issue reports that as a partial
# success rather than failing the whole issue.
# Args: <issue-number>
add_tracking_issue_to_project() {
  local issue_number="$1"
  local content_id
  content_id=$(gh issue view "$issue_number" --repo "$GITHUB_ORG/$GITHUB_REPO" --json id -q .id)
  if [ -z "$content_id" ]; then
    echo "add_tracking_issue_to_project: could not resolve node id for issue #$issue_number" >&2
    return 1
  fi

  local item_id
  item_id=$(gh api graphql -f query='
    mutation($project: ID!, $content: ID!) {
      addProjectV2ItemById(input: {projectId: $project, contentId: $content}) { item { id } }
    }' -f project="$BOOSTCX_DELIVERY_PROJECT_ID" -f content="$content_id" \
    -q '.data.addProjectV2ItemById.item.id' 2>&1)
  if [ -z "$item_id" ] || [[ "$item_id" == *error* ]]; then
    echo "add_tracking_issue_to_project: failed to add issue #$issue_number to boostCX Delivery project: $item_id" >&2
    return 1
  fi
}

# The org-level GitHub Issue Field values a tracking issue gets from its ADO bug, printed as a
# JSON array of {name, kind, value} (kind: text|number|date|option; options are matched by
# name). Only what the ticket actually has is included:
#   ADO Linked Tickets <- work item id, bare (e.g. "145237"), as existing issues use it
#   Priority           <- Microsoft.VSTS.Common.Priority, via ISSUE_FIELD_PRIORITY_MAP
#   Severity           <- Microsoft.VSTS.Common.Severity ("3 - Medium" -> "Medium")
#   Requested By       <- Custom.BugReportedBy (e.g. "Internal - QA"), else the ticket's creator
#   Start date         <- Microsoft.VSTS.Scheduling.StartDate
#   Target date        <- Microsoft.VSTS.Scheduling.TargetDate
#   Effort - Estimate  <- Microsoft.VSTS.Scheduling.OriginalEstimate (hours), when above 0
#   Effort - Actual    <- Microsoft.VSTS.Scheduling.CompletedWork, when above 0
#   Workstream         <- ISSUE_FIELD_WORKSTREAM
# Args: <work-item-json> (as `az boards work-item show` prints it)
ado_issue_field_values() {
  jq -c --arg prio_map "${ISSUE_FIELD_PRIORITY_MAP:-}" --arg workstream "${ISSUE_FIELD_WORKSTREAM:-}" '
    def field(n; k; v): if (v // "") != "" then {name: n, kind: k, value: v} else empty end;
    .fields as $f
    | ($prio_map | split(" ") | map(select(contains("=")) | split("=") | {key: .[0], value: .[1]}) | from_entries) as $prio
    | ($f."System.CreatedBy" | if type == "object" then .displayName else . end) as $creator
    | [ field("ADO Linked Tickets"; "text"; .id | tostring),
        field("Priority"; "option"; $prio[$f."Microsoft.VSTS.Common.Priority" // "" | tostring]),
        field("Severity"; "option"; $f."Microsoft.VSTS.Common.Severity" // "" | sub("^[0-9]+ *- *"; "")),
        field("Requested By"; "text"; $f."Custom.BugReportedBy" // $creator),
        field("Start date"; "date"; ($f."Microsoft.VSTS.Scheduling.StartDate" // "")[0:10]),
        field("Target date"; "date"; ($f."Microsoft.VSTS.Scheduling.TargetDate" // "")[0:10]),
        field("Effort - Estimate"; "number"; $f."Microsoft.VSTS.Scheduling.OriginalEstimate" | select(. != null and . > 0)),
        field("Effort - Actual"; "number"; $f."Microsoft.VSTS.Scheduling.CompletedWork" | select(. != null and . > 0)),
        field("Workstream"; "option"; $workstream) ]' <<< "$1"
}

# Works out which of the ADO bug's Issue Field values (ado_issue_field_values) the issue is
# still missing. Fields already set on the issue are left out, so a value someone changed by
# hand is never overwritten. Prints {issueId, inputs, names, skipped} - inputs ready for
# setIssueFieldValue, names of the fields they set, and values skipped because the org has no
# such field or option - or fails.
# Args: <issue-number> <work-item-json>
pending_issue_fields() {
  local issue_number="$1" item="$2" wanted catalog issue
  wanted=$(ado_issue_field_values "$item") || return 1
  if ! catalog=$(gh api graphql -f query='
      query($org: String!) { organization(login: $org) { issueFields(first: 100) { nodes {
        __typename
        ... on IssueFieldText { id name }
        ... on IssueFieldNumber { id name }
        ... on IssueFieldDate { id name }
        ... on IssueFieldSingleSelect { id name options { id name } }
      } } } }' -f org="$GITHUB_ORG" -q '.data.organization.issueFields.nodes' 2>&1); then
    echo "pending_issue_fields: could not list $GITHUB_ORG's issue fields: $catalog" >&2
    return 1
  fi
  if ! issue=$(gh api graphql -f query='
      query($owner: String!, $repo: String!, $n: Int!) { repository(owner: $owner, name: $repo) { issue(number: $n) {
        id
        issueFieldValues(first: 50) { nodes {
          ... on IssueFieldTextValue { field { ... on IssueFieldCommon { name } } }
          ... on IssueFieldNumberValue { field { ... on IssueFieldCommon { name } } }
          ... on IssueFieldDateValue { field { ... on IssueFieldCommon { name } } }
          ... on IssueFieldSingleSelectValue { field { ... on IssueFieldCommon { name } } }
          ... on IssueFieldMultiSelectValue { field { ... on IssueFieldCommon { name } } }
        } }
      } } }' -f owner="$GITHUB_ORG" -f repo="$GITHUB_REPO" -F n="$issue_number" -q '.data.repository.issue' 2>&1); then
    echo "pending_issue_fields: could not read issue #$issue_number's fields: $issue" >&2
    return 1
  fi
  jq -n -c --argjson wanted "$wanted" --argjson catalog "$catalog" --argjson issue "$issue" '
    [$issue.issueFieldValues.nodes[] | .field.name? // empty] as $set
    | [ $wanted[] | select(.name as $n | $set | any(.[]; . == $n) | not)
        | . as $w | ($catalog | map(select(.name == $w.name)) | first) as $field
        | if $field == null then {skip: "\($w.name) (no such org field)"}
          elif $w.kind == "option" then
            (($field.options // []) | map(select(.name == $w.value)) | first) as $o
            | if $o == null then {skip: "\($w.name)=\($w.value) (no such option)"}
              else {name: $w.name, input: {fieldId: $field.id, singleSelectOptionId: $o.id}} end
          elif $w.kind == "number" then {name: $w.name, input: {fieldId: $field.id, numberValue: $w.value}}
          elif $w.kind == "date" then {name: $w.name, input: {fieldId: $field.id, dateValue: $w.value}}
          else {name: $w.name, input: {fieldId: $field.id, textValue: $w.value}} end ] as $r
    | {issueId: $issue.id, inputs: [$r[] | .input // empty], names: [$r[] | .name // empty],
       skipped: [$r[] | .skip // empty]}'
}

# Sets <input-json-array> on the issue in one setIssueFieldValue call, or fails.
# Args: <issue-node-id> <input-json-array>
_set_issue_field_values() {
  jq -n -c --arg id "$1" --argjson inputs "$2" '{
    query: "mutation($input: SetIssueFieldValueInput!) { setIssueFieldValue(input: $input) { clientMutationId } }",
    variables: {input: {issueId: $id, issueFields: $inputs}}}' | gh api graphql --input - 2>&1 >/dev/null
}

# Fills the tracking issue's org-level Issue Fields from its ADO bug (ado_issue_field_values),
# setting only fields the issue doesn't have yet. Values with no matching org field/option are
# logged and skipped. If the batched update is rejected, each field is retried on its own so
# one bad value can't keep the rest (ADO Linked Tickets above all) from being set. Returns
# non-zero when any field couldn't be set (logged); create_tracking_issue reports that as a
# partial success.
# Args: <issue-number> <ado-id> [<work-item-json>] - the ADO ticket is fetched when not given
set_tracking_issue_fields() {
  local issue_number="$1" ado_id="$2" item="${3:-}" pending out input failed=()
  if [ -z "$item" ]; then
    item=$(az_retry boards work-item show --id "$ado_id" --organization "$ADO_ORG" -o json) || return 1
  fi
  pending=$(pending_issue_fields "$issue_number" "$item") || return 1
  if [ "$(jq '.skipped | length' <<< "$pending")" -gt 0 ]; then
    echo "set_tracking_issue_fields: issue #$issue_number - skipped $(jq -r '.skipped | join(", ")' <<< "$pending")" >&2
  fi
  [ "$(jq '.inputs | length' <<< "$pending")" -eq 0 ] && return 0

  local issue_id count i
  issue_id=$(jq -r '.issueId' <<< "$pending")
  out=$(_set_issue_field_values "$issue_id" "$(jq -c '.inputs' <<< "$pending")") && return 0
  count=$(jq '.inputs | length' <<< "$pending")
  for ((i = 0; i < count; i++)); do
    input=$(jq -c --argjson i "$i" '[.inputs[$i]]' <<< "$pending")
    _set_issue_field_values "$issue_id" "$input" >/dev/null \
      || failed+=("$(jq -r --argjson i "$i" '.names[$i]' <<< "$pending")")
  done
  if [ ${#failed[@]} -gt 0 ]; then
    local IFS=,
    echo "set_tracking_issue_fields: issue #$issue_number - could not set ${failed[*]}: $out" >&2
    return 1
  fi
}
