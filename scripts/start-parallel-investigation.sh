#!/bin/bash
# For each bug in $ADO_BUGS_FILE not already tracked (state/ado-to-github-map.json), starts a
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
# The ADO ticket's State is already $ADO_ACTIVE_STATE by this point - get-ado-bugs.sh sets it when the
# bug is collected.
#
# Exactly one of three things happens as the deterministic final step (or the bug fails and
# its pane is left open for inspection):
#   - A real resolution plan was produced, containing every REQUIRED_REPORT_SECTIONS heading ->
#     the tracking GitHub issue is created FROM that report (title
#     "$GITHUB_ISSUE_TITLE_PREFIX<title>", body = the report rendered through
#     TRACKING_ISSUE_TEMPLATE, which adds the investigated commit and the ADO link) rather
#     than pre-creating a plain issue that just replicates the ADO ticket's raw description. The ADO ticket's tag is swapped from
#     $MIGRATION_TAG to $MIGRATED_TAG.
#   - The agent hit its own Step 0 "BLOCKER FOUND" case (not enough information to
#     investigate) -> no GitHub issue is created; instead a comment is posted on the ADO
#     ticket stating more information is required, with the specific blocker detail, and its
#     tag is swapped from $MIGRATION_TAG to $BLOCKED_TAG. The bug is also
#     recorded in state/ado-to-github-map.json (as "BLOCKED") as a redundant safety net in
#     case the tag write itself fails - clear both once the ticket has enough information to
#     retry (re-adding the $MIGRATION_TAG tag).
#   - The agent found the bug already fixed in the investigated code ("ALREADY FIXED" report)
#     -> no GitHub issue is created; its evidence is posted as an ADO comment, the tag is
#     swapped from $MIGRATION_TAG to $ALREADY_FIXED_TAG, and it's recorded as "ALREADY_FIXED"
#     in state/ado-to-github-map.json.
#
# Each tag swap naturally excludes the bug from future $MIGRATION_TAG-tagged WIQL queries,
# on top of the existing state-file-based skip check in get-ado-bugs.sh.
#
# Parallelism: herdr's `agent prompt` only reliably delivers the submitting Enter keystroke
# when called with --wait (confirmed empirically - without it, the prompt text is typed into
# the input box but never submitted, despite herdr's own docs claiming atomic submission
# either way). So each bug's full pipeline (pane -> agent -> prompt --wait -> capture -> create
# tracking issue) runs as one backgrounded bash job; a final `wait` blocks until all bugs have
# investigated concurrently, and only then is the shared worktree removed.
#
# At most $MAX_PARALLEL_INVESTIGATIONS (configs/system.conf) of these jobs run at once, not
# every bug's job simultaneously - confirmed live that firing 9 at once starves every pane
# badly enough that herdr's submitting Enter (and its own recovery retries) never register,
# so every bug times out having typed its prompt but never submitted it.
#
# Report files are named RESOLUTION-PLAN-<ado-id>.md, not a fixed name, since every bug writes
# into the same shared directory - a fixed name would let concurrent bugs clobber each other's
# report (this is also why the agent is told to skip its own Step 3.5 knowledge-saving here:
# nothing written to this worktree persists past the run, and concurrent bugs writing the same
# memory-bank files would race).
#
# UI: each job's `log` output is redirected to its own $TEMP_DIR/log-<ado-id>.txt instead of
# the main terminal - with several bugs running at once, interleaved raw log lines from every
# concurrent job were unreadable. The main terminal (the "main" herdr space this script itself
# runs in, as opposed to each bug's own herdr pane) instead shows a live, continuously-redrawn
# status table (see scripts/lib/ui.sh) until every bug reaches a terminal status.
#
# Usage: ./start-parallel-investigation.sh [--live] [--branch <name>]
# --branch (default $DEFAULT_BASE_BRANCH) is the origin branch the shared investigation worktree is checked
# out from - applies to every bug in $ADO_BUGS_FILE for this run.
# Investigation itself always runs (it's non-destructive - a read-only worktree + an agent
# conversation). --live only gates whether the tracking issue + ADO comment-back actually get
# created; without it, the resolution plan is printed for review instead.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/herdr.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/ui.sh"
parse_common_args "$@"

if [ ! -f "$ADO_BUGS_FILE" ]; then
  log "$ADO_BUGS_FILE not found - run get-ado-bugs.sh first"
  exit 1
fi

count=$(jq 'length' "$ADO_BUGS_FILE")
if [ "$count" -eq 0 ]; then
  log "No bugs to investigate."
  exit 0
fi

# Every bug in $ADO_BUGS_FILE was set $ADO_ACTIVE_STATE when collected, and only
# $ADO_NEW_STATE bugs are collected - so any bug that doesn't finish must go back to
# $ADO_NEW_STATE or it's never retried. Failures inside a bug's job do that themselves
# (fail_bug); this catches everything else - the run aborting before or during investigation
# (clone/worktree failure, Ctrl-C, a crash) - by returning every bug that hasn't reached a
# final status.
mapfile -t run_ado_ids < <(jq -r '.[].id' "$ADO_BUGS_FILE")
# Status files persist in $TEMP_DIR between runs - clear this run's, or an abort would read a
# previous run's final status and skip returning the bug.
for ado_id in "${run_ado_ids[@]}"; do rm -f "$TEMP_DIR/status-$ado_id.status"; done

return_unfinished_bugs() {
  local ado_id
  for ado_id in "${run_ado_ids[@]}"; do
    case "$(get_bug_status "$ado_id")" in
      issue-created\|*|blocked\|*|already-fixed\|*|dry-run\|*|failed\|*) ;;  # finished, or fail_bug already returned it
      *) log "[$ado_id] Run ended before this bug finished"; return_ado_to_new "$ado_id" ;;
    esac
  done
}
trap return_unfinished_bugs EXIT
trap 'exit 130' INT TERM

if ! ensure_app_clone; then
  log "Could not clone/fetch $APP_REPO_URL - aborting"
  exit 1
fi

safe_base="${BASE_BRANCH//\//-}"
shared_worktree_path=$(ensure_shared_readonly_worktree "rca-shared-$safe_base")
if [ -z "$shared_worktree_path" ]; then
  log "Failed to create shared investigation worktree, aborting"
  exit 1
fi

# Recorded in every tracking issue - the plan's file paths and line numbers refer to this commit.
investigated_commit=$(git -C "$shared_worktree_path" rev-parse --short HEAD)

# The prompt names the required headings from config, so the check below and the prompt can
# never drift apart.
required_sections_list=$(printf '"%s", ' "${REQUIRED_REPORT_SECTIONS[@]}")
required_sections_list="${required_sections_list%, }"

log "Investigating $count bug(s) against shared worktree $shared_worktree_path (origin/$BASE_BRANCH @ $investigated_commit)..."

# Marks a bug failed and returns its ADO ticket to $ADO_NEW_STATE so the next run retries it.
# Args: <ado-id> <detail>
fail_bug() {
  local ado_id="$1" detail="$2"
  return_ado_to_new "$ado_id" || detail="$detail; could not reset ADO to $ADO_NEW_STATE"
  set_bug_status "$ado_id" failed "$detail"
}

# Runs the full pipeline for one bug. Meant to be invoked as a backgrounded job so multiple
# bugs investigate concurrently. Reads from the shared worktree passed in - never creates or
# removes a worktree of its own.
investigate_one() {
  local ado_id="$1" title="$2" ado_url="$3" worktree_path="$4" commit="$5"
  local name="rca-$ado_id"

  set_bug_status "$ado_id" starting "opening pane"

  local ws pane
  read -r ws pane <<< "$(herdr_open_pane "$worktree_path" "$name")"
  if [ -z "$pane" ]; then
    log "[$ado_id] Failed to open pane, skipping"
    fail_bug "$ado_id" "pane-open, see log-$ado_id.txt"
    return 1
  fi

  set_bug_status "$ado_id" starting "starting agent"
  if ! herdr_start_claude "$name" "$pane"; then
    log "[$ado_id] Failed to start claude agent, skipping"
    herdr_close_workspace "$ws"
    fail_bug "$ado_id" "agent-start, see log-$ado_id.txt"
    return 1
  fi

  local report_filename="RESOLUTION-PLAN-$ado_id.md"
  # Clear any stale file from a previous crashed run before prompting - the shared worktree
  # can be reused across runs, and a leftover file must never be mistaken for this run's
  # output.
  rm -f "$worktree_path/$report_filename"

  local prompt="Use the $RCA_AGENT_NAME to investigate ADO ticket $ado_id (organization $ADO_ORG, project \"$ADO_PROJECT\") in $GITHUB_ORG/$GITHUB_REPO. There is no GitHub issue for this bug yet. Produce your resolution plan and stop - do not create a tracking issue and do not proceed to implementation; the tracking issue will be created from your report separately. This worktree is shared read-only across every bug investigated in this run and will be deleted once they all finish - do not modify, create, or commit any file except $report_filename, and skip your own Step 3.5 (Banyan Memory Bank knowledge saving) entirely since nothing written here persists. Write the complete report as clean, well-formatted Markdown to a file named $report_filename in the current directory - proper headings, code fences for file paths/snippets, no terminal chrome or box-drawing characters, nothing that isn't meant to appear as the body of a GitHub issue. Start the file with a single top-level heading, then use Markdown headings with exactly these names, in this order: $required_sections_list (your Step 3 Resolution Plan subsections go under the Resolution Plan heading). The file becomes a GitHub issue that a separate process will later implement from without re-investigating, so it must stand on its own: leave out the Bug Issue subsection (no issue exists yet), the Knowledge Saved and Reviewer Checklist sections, and any hand-off or next-step instructions - document only the analysis and the plan. When the file is written, reply in chat with just a one-line confirmation - do not repeat the report content in chat. If your own Step 0 Bug Clarity Check fails and you cannot proceed, write that same $report_filename file starting with the exact line 'BLOCKER FOUND' (all caps, nothing before it) followed by the Type/Issue/Detail/Recommendation from your blocker report - do not fabricate a resolution plan when the check fails. If instead you find the bug is already fixed in this checkout, write that same $report_filename file starting with the exact line 'ALREADY FIXED' (all caps, nothing before it) followed by the evidence: the commit(s) and code that fixed it, how you verified the fix is present, and any residual observations - do not write a resolution plan for a bug that is already fixed."

  log "[$ado_id] Prompting agent $name..."
  set_bug_status "$ado_id" investigating "agent running"
  if ! herdr_prompt_and_wait "$name" "$prompt" "$HERDR_AGENT_TIMEOUT_MS"; then
    log "[$ado_id] Agent did not settle in time - leaving pane open for manual inspection (workspace $ws)"
    fail_bug "$ado_id" "timeout, pane left open (workspace $ws)"
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
    fail_bug "$ado_id" "no report file, pane left open (workspace $ws)"
    return 1
  fi
  cp "$worktree_path/$report_filename" "$report_file"
  rm -f "$worktree_path/$report_filename"

  # A real resolution plan, BLOCKER FOUND or ALREADY FIXED report is always substantial (headings, several
  # paragraphs); a near-empty file is just as suspicious as a missing one.
  if [ "$(wc -c < "$report_file")" -lt "$MIN_REPORT_BYTES" ]; then
    log "[$ado_id] $report_filename exists but is suspiciously small ($(wc -c < "$report_file") bytes) - not creating a tracking issue from it. Leaving pane open for manual inspection (workspace $ws)."
    fail_bug "$ado_id" "report too small, pane left open (workspace $ws)"
    return 1
  fi

  local outcome=plan first_line
  first_line=$(head -n 1 "$report_file")
  case "$first_line" in
    "BLOCKER FOUND"*) outcome=blocker ;;
    "ALREADY FIXED"*) outcome=already-fixed ;;
  esac

  # A plan missing a required section isn't usable as a hand-off to a later resolution
  # process, so it's a failed investigation, not an issue. (Blocker and already-fixed reports
  # have their own format and are exempt.)
  if [ "$outcome" = plan ]; then
    local missing
    missing=$(report_missing_sections "$report_file" | paste -sd, - | sed 's/,/, /g')
    if [ -n "$missing" ]; then
      log "[$ado_id] $report_filename is missing required section(s): $missing - not creating a tracking issue. Report kept at $report_file; leaving pane open for manual inspection (workspace $ws)."
      fail_bug "$ado_id" "report missing: $missing"
      return 1
    fi
  fi

  herdr_close_workspace "$ws"

  if [ "$outcome" = blocker ]; then
    log "[$ado_id] Agent hit a blocker - no tracking issue will be created"
    post_ado_blocker_comment "$ado_id" "$report_file"
    set_bug_status "$ado_id" blocked "needs more info"
    return 0
  fi
  if [ "$outcome" = already-fixed ]; then
    log "[$ado_id] Agent found the bug already fixed - no tracking issue will be created"
    post_ado_already_fixed_comment "$ado_id" "$report_file" "$commit"
    set_bug_status "$ado_id" already-fixed "commented on ADO"
    return 0
  fi

  local issue_number
  if ! issue_number=$(create_tracking_issue "$ado_id" "$title" "$ado_url" "$report_file" "$commit"); then
    log "[$ado_id] Creating the tracking issue failed - see above. Report kept at $report_file"
    fail_bug "$ado_id" "issue creation failed, see log-$ado_id.txt"
    return 1
  fi
  if [ "$LIVE" = true ]; then
    log "[$ado_id] Tracking issue created: #$issue_number"
    set_bug_status "$ado_id" issue-created "#$issue_number"
  else
    set_bug_status "$ado_id" dry-run "preview in log-$ado_id.txt"
  fi
}

jq -c '.[]' "$ADO_BUGS_FILE" | while read -r bug; do
  ado_id=$(echo "$bug" | jq -r '.id')
  title=$(echo "$bug" | jq -r '.title')
  url=$(echo "$bug" | jq -r '.url')
  echo "$ado_id"$'\t'"$title"$'\t'"$url"
done > "$TEMP_DIR/investigation-targets.tsv"

pids=()
ado_ids=()
max_parallel="$MAX_PARALLEL_INVESTIGATIONS"
while IFS=$'\t' read -r ado_id title url; do
  set_bug_status "$ado_id" queued
  # Cap how many of these run at once (see the Parallelism note above) - block here until a
  # slot frees up rather than firing every bug's job the instant it's read off the queue.
  while [ "$(jobs -rp | wc -l)" -ge "$max_parallel" ]; do
    wait -n
  done
  # Each job's own `log` output goes to its own file instead of the main terminal - with
  # several bugs running at once, interleaved raw log lines were unreadable. Full detail for
  # any bug stays in $TEMP_DIR/log-<id>.txt; the main terminal (the "main" herdr space this
  # script itself runs in) shows the live status table below instead.
  investigate_one "$ado_id" "$title" "$url" "$shared_worktree_path" "$investigated_commit" > "$TEMP_DIR/log-$ado_id.txt" 2>&1 &
  pids+=($!)
  ado_ids+=("$ado_id")
done < "$TEMP_DIR/investigation-targets.tsv"

run_status_ui "${ado_ids[@]}"

failures=0
for pid in "${pids[@]}"; do
  wait "$pid" || failures=$((failures + 1))
done

log "Investigation pass complete ($failures failure(s))"
for ado_id in "${ado_ids[@]}"; do
  status_line=$(get_bug_status "$ado_id")
  case "${status_line%%|*}" in
    # A live-created issue is fully reviewable on GitHub - nothing further to point at here.
    # Everything else (dry-run preview, blocker, failure) has its real content only in the
    # per-bug log, not the status table, so always point at it.
    issue-created) ;;
    *) log "[$ado_id] $status_line - see $TEMP_DIR/log-$ado_id.txt" ;;
  esac
done

log "Removing shared worktree $shared_worktree_path"
remove_worktree "$shared_worktree_path"
