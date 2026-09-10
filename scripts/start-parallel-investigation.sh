#!/bin/bash
# For each bug in ado-bugs.json not already tracked (state/ado-to-github-map.json), starts a
# real `claude` agent in its own herdr pane and asks it to run this repo's own
# bcx-bug-rca-agent directly against the ADO ticket - no GitHub issue exists yet at this
# point. The agent explicitly stops after producing a resolution plan; it never writes code
# (see agents/bcx-bug-rca-agent.md) or commits anything.
#
# Because nothing is written back to the checkout, every bug investigated in this run shares
# ONE read-only worktree (detached HEAD on origin/<base> - see ensure_shared_readonly_worktree
# in scripts/lib/common.sh) instead of each getting its own. It exists only to isolate this
# run's code snapshot from whatever else is happening in $APP_REPO_DIR (a concurrent fixing
# pass, your own separate work in another app) - it is removed once every bug in this run has
# finished investigating, not kept around between runs. Each bug still gets its own herdr
# pane/agent process; they just all read the same directory.
#
# The ADO ticket's State is set to Active as soon as investigation starts (confirmed valid
# transition: New -> Active via Microsoft.VSTS.Actions.StartWork).
#
# Exactly one of two things happens as the deterministic final step, never both and never
# neither:
#   - A real resolution plan was produced -> the tracking GitHub issue is created FROM that
#     report (title "Fix: <title>", body = the resolution plan itself, matching
#     bcx-bug-rca-agent's own Step 4 convention) rather than pre-creating a plain issue that
#     just replicates the ADO ticket's raw description. The ADO ticket's tag is swapped from
#     MigrateToGitHub to MigratedToGitHub.
#   - The agent hit its own Step 0 "BLOCKER FOUND" case (not enough information to
#     investigate) -> no GitHub issue is created; instead a comment is posted on the ADO
#     ticket stating more information is required, with the specific blocker detail, and its
#     tag is swapped from MigrateToGitHub to RequiresAdditionalInformation. The bug is also
#     recorded in state/ado-to-github-map.json (as "BLOCKED") as a redundant safety net in
#     case the tag write itself fails - clear both once the ticket has enough information to
#     retry (re-adding the MigrateToGitHub tag).
#
# Either tag swap naturally excludes the bug from future MigrateToGitHub-tagged WIQL queries,
# on top of the existing state-file-based skip check in get-ado-bugs.sh.
#
# Parallelism: herdr's `agent prompt` only reliably delivers the submitting Enter keystroke
# when called with --wait (confirmed empirically - without it, the prompt text is typed into
# the input box but never submitted, despite herdr's own docs claiming atomic submission
# either way). So each bug's full pipeline (pane -> agent -> prompt --wait -> capture -> create
# tracking issue) runs as one backgrounded bash job; a final `wait` blocks until all bugs have
# investigated concurrently, and only then is the shared worktree removed.
#
# Report files are named RESOLUTION-PLAN-<ado-id>.md, not a fixed name, since every bug writes
# into the same shared directory - a fixed name would let concurrent bugs clobber each other's
# report (this is also why the agent is told to skip its own Step 3.5 knowledge-saving here:
# nothing written to this worktree persists past the run, and concurrent bugs writing the same
# memory-bank files would race).
#
# Usage: ./start-parallel-investigation.sh [--live] [--branch <name>]
# --branch (default "main") is the origin branch the shared investigation worktree is checked
# out from - applies to every bug in ado-bugs.json for this run.
# Investigation itself always runs (it's non-destructive - a read-only worktree + an agent
# conversation). --live only gates whether the tracking issue + ADO comment-back actually get
# created; without it, the resolution plan is printed for review instead.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/herdr.sh"
parse_common_args "$@"

if [ ! -f ado-bugs.json ]; then
  log "ado-bugs.json not found - run get-ado-bugs.sh first"
  exit 1
fi

ensure_app_clone

count=$(jq 'length' ado-bugs.json)
if [ "$count" -eq 0 ]; then
  log "No bugs to investigate."
  exit 0
fi

safe_base="${BASE_BRANCH//\//-}"
shared_worktree_path=$(ensure_shared_readonly_worktree "rca-shared-$safe_base")
if [ -z "$shared_worktree_path" ]; then
  log "Failed to create shared investigation worktree, aborting"
  exit 1
fi

log "Investigating $count bug(s) against shared worktree $shared_worktree_path (origin/$BASE_BRANCH)..."

# Runs the full pipeline for one bug. Meant to be invoked as a backgrounded job so multiple
# bugs investigate concurrently. Reads from the shared worktree passed in - never creates or
# removes a worktree of its own.
investigate_one() {
  local ado_id="$1" title="$2" ado_url="$3" worktree_path="$4"
  local name="rca-$ado_id"

  set_ado_active "$ado_id"

  local ws pane
  read -r ws pane <<< "$(herdr_open_pane "$worktree_path" "$name")"
  if [ -z "$pane" ]; then
    log "[$ado_id] Failed to open pane, skipping"
    return 1
  fi

  if ! herdr_start_claude "$name" "$pane"; then
    log "[$ado_id] Failed to start claude agent, skipping"
    herdr_close_workspace "$ws"
    return 1
  fi

  local report_filename="RESOLUTION-PLAN-$ado_id.md"
  # Clear any stale file from a previous crashed run before prompting - the shared worktree
  # can be reused across runs, and a leftover file must never be mistaken for this run's
  # output.
  rm -f "$worktree_path/$report_filename"

  local prompt="Use the bcx-bug-rca-agent to investigate ADO ticket $ado_id (organization $ADO_ORG, project \"$ADO_PROJECT\") in $GITHUB_ORG/$GITHUB_REPO. There is no GitHub issue for this bug yet. Produce your resolution plan and stop - do not create a tracking issue and do not proceed to implementation; the tracking issue will be created from your report separately. This worktree is shared read-only across every bug investigated in this run and will be deleted once they all finish - do not modify, create, or commit any file except $report_filename, and skip your own Step 3.5 (Banyan Memory Bank knowledge saving) entirely since nothing written here persists. Write the complete report as clean, well-formatted Markdown to a file named $report_filename in the current directory - proper headings, code fences for file paths/snippets, no terminal chrome or box-drawing characters, nothing that isn't meant to appear as the body of a GitHub issue. Start the file with a single top-level heading. When the file is written, reply in chat with just a one-line confirmation - do not repeat the report content in chat. If your own Step 0 Bug Clarity Check fails and you cannot proceed, write that same $report_filename file starting with the exact line 'BLOCKER FOUND' (all caps, nothing before it) followed by the Type/Issue/Detail/Recommendation from your blocker report - do not fabricate a resolution plan when the check fails."

  log "[$ado_id] Prompting agent $name..."
  if ! herdr_prompt_and_wait "$name" "$prompt" "$HERDR_AGENT_TIMEOUT_MS"; then
    log "[$ado_id] Agent did not settle in time - leaving pane open for manual inspection (workspace $ws)"
    return 1
  fi

  local report_file="$TEMP_DIR/rca-$ado_id.md"
  if [ ! -f "$worktree_path/$report_filename" ]; then
    # Do NOT fall back to raw pane capture and create a tracking issue from it - a stalled or
    # short-circuited agent conversation can "settle" without ever producing real content
    # (confirmed in practice: this exact fallback once produced 6 live GitHub issues whose
    # entire body was the bare shell prompt). Missing report file means something went wrong
    # even though herdr_prompt_and_wait reported completion; leave the pane open for a human
    # to actually look at rather than guessing.
    log "[$ado_id] Agent settled but did not write $report_filename - not creating a tracking issue from unverified content. Leaving pane open for manual inspection (workspace $ws)."
    herdr_capture "$name" 500 > "$TEMP_DIR/rca-$ado_id-raw-capture.log"
    return 1
  fi
  cp "$worktree_path/$report_filename" "$report_file"
  rm -f "$worktree_path/$report_filename"

  # A real resolution plan or BLOCKER FOUND report is always substantial (headings, several
  # paragraphs); a near-empty file is just as suspicious as a missing one.
  if [ "$(wc -c < "$report_file")" -lt 200 ]; then
    log "[$ado_id] $report_filename exists but is suspiciously small ($(wc -c < "$report_file") bytes) - not creating a tracking issue from it. Leaving pane open for manual inspection (workspace $ws)."
    return 1
  fi

  herdr_close_workspace "$ws"

  if head -n 1 "$report_file" | grep -q "^BLOCKER FOUND"; then
    log "[$ado_id] Agent hit a blocker - no tracking issue will be created"
    post_ado_blocker_comment "$ado_id" "$report_file"
    return 0
  fi

  local issue_number
  issue_number=$(create_tracking_issue "$ado_id" "$title" "$ado_url" "$report_file")
  if [ "$LIVE" = true ]; then
    log "[$ado_id] Tracking issue created: #$issue_number"
  fi
}

pids=()
jq -c '.[]' ado-bugs.json | while read -r bug; do
  ado_id=$(echo "$bug" | jq -r '.id')
  title=$(echo "$bug" | jq -r '.title')
  url=$(echo "$bug" | jq -r '.url')
  echo "$ado_id"$'\t'"$title"$'\t'"$url"
done > "$TEMP_DIR/investigation-targets.tsv"

while IFS=$'\t' read -r ado_id title url; do
  investigate_one "$ado_id" "$title" "$url" "$shared_worktree_path" &
  pids+=($!)
done < "$TEMP_DIR/investigation-targets.tsv"

failures=0
for pid in "${pids[@]}"; do
  wait "$pid" || failures=$((failures + 1))
done

log "Investigation pass complete ($failures failure(s)) - removing shared worktree $shared_worktree_path"
remove_worktree "$shared_worktree_path"
