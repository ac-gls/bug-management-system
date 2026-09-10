#!/bin/bash
# Shared helpers sourced by every pipeline script.
# Usage: source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR_SELF="$(cd "$LIB_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SCRIPTS_DIR_SELF/.." && pwd)"

source "$REPO_ROOT/configs/system.conf"
source "$REPO_ROOT/configs/credentials.conf"

mkdir -p "$LOG_DIR" "$TEMP_DIR" "$STATE_DIR"

LIVE=false
LIMIT=1
BASE_BRANCH="main"

# Parses --live, --limit N, and --branch <name> from a script's "$@"; leaves remaining args
# in REMAINING_ARGS. --branch overrides the default base ("main") that investigation/fix
# worktrees are created from and that new-pull-request.sh opens PRs against - applies to
# every bug processed in this invocation. Bugs needing different base branches must be run
# in separate invocations grouped by branch.
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

# Clones APP_REPO_DIR if missing, otherwise fetches latest.
ensure_app_clone() {
  # Without this, a plain `git clone` over https hangs indefinitely (no error, no prompt) on
  # any repo requiring auth, because WSL's native git has no credential helper configured -
  # `gh auth login`/`gh auth setup-git` only wire up whichever git the `gh` binary itself
  # shells out to, which on this machine is a wrapper around Windows' gh.exe, not WSL's git.
  if [ "$(git config --global --get credential.https://github.com.helper 2>/dev/null)" != "!gh auth git-credential" ]; then
    git config --global credential."https://github.com".helper "!gh auth git-credential"
  fi

  if [ ! -d "$APP_REPO_DIR/.git" ]; then
    log "Cloning $APP_REPO_URL -> $APP_REPO_DIR"
    git clone "$APP_REPO_URL" "$APP_REPO_DIR"
  else
    log "Fetching latest in $APP_REPO_DIR"
    git -C "$APP_REPO_DIR" fetch origin
  fi
  mkdir -p "$APP_WORKTREE_DIR"
  ensure_required_agents_installed
}

# bcx-reporting-platform is the source of truth for bcx-bug-rca-agent and bcx-bug-coder-agent
# (this pipeline just orchestrates worktrees/panes and asks a claude agent to run them by
# name) - both already exist there under .claude/agents/ and are committed to origin/main, so
# this is normally a no-op. It's a defensive fallback for a checkout that predates them (an
# older branch, a fork, APP_REPO_URL pointed elsewhere) using this repo's vendored copies in
# agents/, so a missing agent fails loudly here instead of confusingly deep inside a herdr
# pane. Never overwrites a file already present - a repo-side edit to the agent always wins.
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

# Creates (or reuses) a git worktree for a bug/issue off origin/main.
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

ADO_MAP_FILE="$STATE_DIR/ado-to-github-map.json"
[ -f "$ADO_MAP_FILE" ] || echo '{}' > "$ADO_MAP_FILE"

ado_map_get() {
  jq -r --arg id "$1" '.[$id] // empty' "$ADO_MAP_FILE"
}

ado_map_set() {
  local id="$1" issue="$2" tmp
  tmp=$(mktemp)
  jq --arg id "$id" --arg issue "$issue" '.[$id] = $issue' "$ADO_MAP_FILE" > "$tmp" && mv "$tmp" "$ADO_MAP_FILE"
}

# Marks the ADO ticket Active at the start of investigation (confirmed valid transition for
# this project's Bug workflow: New -> Active via Microsoft.VSTS.Actions.StartWork).
set_ado_active() {
  local ado_id="$1"
  if [ "$LIVE" != true ]; then
    log "DRY RUN (pass --live to actually do this): az boards work-item update --id $ado_id --state Active"
    return 0
  fi
  az boards work-item update --id "$ado_id" --organization "$ADO_ORG" --state "Active" >/dev/null
}

# Swaps $MIGRATION_TAG for <new_tag> on the ADO ticket, preserving every other tag untouched.
# ADO's System.Tags field has no dedicated add/remove API via `az boards` - only a full-value
# --fields override - so this reads the current tag string, splits on the confirmed "; "
# separator (verified live: e.g. "CORE; MigrateToGitHub"), drops $MIGRATION_TAG, appends
# <new_tag>, and writes the whole field back.
replace_ado_migration_tag() {
  local ado_id="$1" new_tag="$2"
  if [ "$LIVE" != true ]; then
    log "DRY RUN (pass --live to actually do this): az boards work-item update --id $ado_id --fields 'System.Tags=...; $new_tag' (removing $MIGRATION_TAG)"
    return 0
  fi
  local current_tags joined tag
  current_tags=$(az boards work-item show --id "$ado_id" --organization "$ADO_ORG" -o json | jq -r '.fields."System.Tags" // ""')
  joined=""
  local IFS=';'
  for tag in $current_tags; do
    tag=$(echo "$tag" | xargs)
    [ -z "$tag" ] && continue
    [ "$tag" = "$MIGRATION_TAG" ] && continue
    if [ -z "$joined" ]; then joined="$tag"; else joined="$joined; $tag"; fi
  done
  if [ -z "$joined" ]; then joined="$new_tag"; else joined="$joined; $new_tag"; fi
  az boards work-item update --id "$ado_id" --organization "$ADO_ORG" --fields "System.Tags=$joined" >/dev/null
}

# Posts a comment on the ADO ticket saying more information is required, using the
# BLOCKER FOUND content bcx-bug-rca-agent wrote instead of a resolution plan. No GitHub issue
# is created for this bug. Swaps its ADO tag from $MIGRATION_TAG to RequiresAdditionalInformation
# (so it naturally drops out of future WIQL queries filtered on $MIGRATION_TAG) and also marks
# it "BLOCKED" in state/ado-to-github-map.json as a redundant safety net in case the tag write
# itself fails. Clear both the tag and the state entry once the ticket has enough information
# to retry.
# Args: <ado-id> <report-file>
post_ado_blocker_comment() {
  local ado_id="$1" report_file="$2"
  local blocker_detail
  blocker_detail=$(cat "$report_file")

  if [ "$LIVE" != true ]; then
    log "DRY RUN (pass --live to actually do this): az boards work-item update --id $ado_id --discussion '<blocker detail>'"
    echo "----- blocker comment preview for ADO-#$ado_id -----"
    echo "$blocker_detail"
    echo "------------------------------------------------------"
    return 0
  fi

  az boards work-item update --id "$ado_id" --organization "$ADO_ORG" \
    --discussion "More information is required before this bug can be investigated further.

$blocker_detail" >/dev/null

  replace_ado_migration_tag "$ado_id" "RequiresAdditionalInformation"
  ado_map_set "$ado_id" "BLOCKED"
}

# Creates the GitHub tracking issue FROM a completed RCA report (its body IS the resolution
# plan, not a copy of the ADO ticket) - matches bcx-bug-rca-agent's own Step 4 convention
# (title "Fix: <title>", body = the report). Records the ADO id -> issue mapping, comments
# back on the ADO ticket, and swaps its tag from $MIGRATION_TAG to MigratedToGitHub. Respects
# --live/dry-run: prints a preview and returns without creating anything real when not --live.
# Args: <ado-id> <bug-title> <ado-url> <report-file>
# Prints the new issue number on success (live only).
create_tracking_issue() {
  local ado_id="$1" title="$2" ado_url="$3" report_file="$4"
  local issue_title="Fix: $title"
  local body
  body=$(cat "$report_file")
  body="${body}

---
ADO-#${ado_id}
${ado_url}"

  if [ "$LIVE" != true ]; then
    log "DRY RUN (pass --live to actually do this): gh issue create --repo $GITHUB_ORG/$GITHUB_REPO --title '$issue_title' --type Bug --label bug"
    echo "----- tracking issue body preview for ADO-#$ado_id -----"
    echo "$body"
    echo "----------------------------------------------------------"
    return 0
  fi

  local issue_url issue_number
  issue_url=$(gh issue create --repo "$GITHUB_ORG/$GITHUB_REPO" --title "$issue_title" --body "$body" --label bug --type Bug)
  issue_number=$(echo "$issue_url" | grep -oE '[0-9]+$')
  if [ -z "$issue_number" ]; then
    echo "create_tracking_issue: failed to parse issue number from: $issue_url" >&2
    return 1
  fi

  ado_map_set "$ado_id" "$issue_number"
  az boards work-item update --id "$ado_id" --organization "$ADO_ORG" \
    --discussion "RCA complete - tracking issue created: #$issue_number ($issue_url)" >/dev/null
  replace_ado_migration_tag "$ado_id" "MigratedToGitHub"

  set_tracking_issue_project_fields "$issue_number" "$ado_id"

  echo "$issue_number"
}

# Adds the tracking issue to the "boostCX Delivery" org project and sets its ADO Linked
# Tickets field (bare ADO work item id, e.g. "145237"). Best-effort - logs and continues past
# a GraphQL error rather than failing the whole tracking-issue creation over a projects-board
# field.
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
  if [ -n "$item_id" ] && [[ "$item_id" != *error* ]]; then
    gh api graphql -f query='
      mutation($project: ID!, $item: ID!, $field: ID!, $value: String!) {
        updateProjectV2ItemFieldValue(input: {projectId: $project, itemId: $item, fieldId: $field, value: {text: $value}}) { projectV2Item { id } }
      }' -f project="$BOOSTCX_DELIVERY_PROJECT_ID" -f item="$item_id" \
      -f field="$BOOSTCX_DELIVERY_ADO_FIELD_ID" -f value="${ado_id}" >/dev/null 2>&1
  else
    echo "set_tracking_issue_project_fields: failed to add issue #$issue_number to boostCX Delivery project: $item_id" >&2
  fi
}
