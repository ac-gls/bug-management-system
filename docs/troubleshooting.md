# Troubleshooting Guide

## Migration Pipeline Issues

### Reading progress during a run

The main terminal (the one you ran `start-bug-migration.sh`/`start-parallel-investigation.sh`
from) shows a live-updating table of every bug's status while investigation runs, refreshed
every couple of seconds. Each bug's own detailed output - agent prompts, dry-run previews,
blocker comments - goes to `temp/log-<ado-id>.txt` instead, since that's too much content for
a status table and would otherwise interleave unreadably across concurrent bugs. A bug's status
line always tells you when to check its log file, and the run's final summary re-lists any bug
that isn't a cleanly created issue.

### An agent's pane is left open after a run

`start-parallel-investigation.sh` deliberately leaves a bug's Herdr pane open instead of
guessing when something looks wrong, so you can inspect what actually happened. Check that
bug's `temp/log-<ado-id>.txt` first - it has the same detail that used to print straight to the
terminal:

- **Agent did not settle in time** - the agent never finished within `HERDR_AGENT_TIMEOUT_MS`
  (default 30 min, `configs/system.conf`). Attach with `herdr session attach default` and check
  the pane directly.
  - If the pane shows a bare shell prompt with `claude` typed but never actually run, that's
    Herdr's `agent start` reporting success before the launching Enter really registered
    (confirmed live under load - every bug in one run hit this identically).
    `herdr_start_claude` (`scripts/lib/herdr.sh`) now waits for the real `Claude Code v...`
    banner and retries with a bare Enter before declaring the agent started; if you still see
    this, the pane may need more retries than the current cap (5) or the machine is more
    starved than before - reduce `MAX_PARALLEL_INVESTIGATIONS` further.
- **Agent settled but never wrote `RESOLUTION-PLAN-<ado-id>.md`** - the pipeline will not create
  a tracking issue from unverified content. Check `temp/rca-<ado-id>-raw-capture.log` for the
  agent's raw output.
- **Report file exists but is suspiciously small (<200 bytes)** - same reasoning; a real
  resolution plan or blocker report is always substantial.

In all three cases nothing is created in GitHub/ADO for that bug - re-run once the underlying
issue (timeout, agent confusion, missing repo access) is understood.

### A GitHub issue's title is wrong or its ADO ticket ID doesn't match

`create_tracking_issue` uses the ADO bug's own title (from `get-ado-bugs.sh`'s query) for the
issue title (`Fix: <title>`) - it does not parse this out of the agent's report. If it's wrong,
check the ADO ticket's `System.Title` field, not the report content.

### A bug never gets investigated even though it has a migration or rerun tag

The query requires the configured intake state, `ADO_NEW_STATE` (currently `Triaged`), and
either `MigrateToGitHub` or `ReRunRequested` (configurable via `RERUN_REQUESTED_TAG`). A bug
already mapped to an issue number, or marked `BLOCKED` / `ALREADY_FIXED` in
`state/ado-to-github-map.json`, is skipped for ordinary migration.

To investigate it again, add `ReRunRequested` and return it to the intake state. This bypasses
the existing map; no manual clearing is needed. Run migration with `--live` when ready.
`--limit` still means a count of bugs, not a per-ID selector.

With an existing numeric GitHub issue link, a new plan saves the previous issue body as a
comment, updates its title/body, and reopens it if closed. Without a linked issue, it creates
one. A blocked or already-fixed rerun posts the ADO outcome but does not automatically close
or reopen the old GitHub issue. Its link is retained in `state/ado-rerun-state.json` for future
reruns, even when the map now holds `BLOCKED` or `ALREADY_FIXED`.

On completion, the request, migration, and previous outcome tags are replaced by the latest
outcome tag; unrelated tags are preserved. Failed investigations keep the request tag and
return to the intake state. The rerun ledger records pending/completed requests and linked
issues; `state/ado-outcome-history.json` records outcome transitions. Dry runs do not write
remote data or any of these state files (including the map).

Manual map clearing and re-adding the migration tag is a last-resort reset, not the rerun
workflow: it can create duplicate GitHub issues instead of updating the existing one.

### A bug fails with "report missing: ..."

The agent's report lacked one or more `REQUIRED_REPORT_SECTIONS` headings, so no issue was
created - an incomplete plan can't be implemented from later. The report is kept at
`temp/rca-<ado-id>.md` and the pane is left open. The ADO ticket is set back to
`ADO_NEW_STATE` (currently `Triaged`) automatically, retaining any rerun request tag so the
next run retries it - or adjust `REQUIRED_REPORT_SECTIONS` in
`configs/system.local.conf` if the required set is wrong.

### A bug shows `issue-partial`, or "ADO tag update FAILED"

The tracking issue was created or updated (or the blocker/already-fixed comment was posted),
but a follow-up step -
the ADO comment, the ADO tag swap, adding the issue to the project board, or setting its issue
fields (ADO Linked Tickets, Priority, Severity, ...) - failed; the bug's
log names which and why. Nothing is lost: run

```bash
./scripts/repair-ado.sh            # reports what's missing for every processed bug
./scripts/repair-ado.sh --live     # fixes it (only the missing pieces)
./scripts/repair-ado.sh --live 145658   # or just specific bugs
```

It checks mapped bugs against ADO and GitHub, skipping queued or in-progress rerun requests
so repair does not consume their request tags or restore stale outcomes. Completed partial
reruns can be repaired, including recovering a failed map write from the recorded completion
outcome. Check `state/ado-rerun-state.json` if a bug is intentionally skipped.
The project-board check needs the gh login's `project` scope (`./scripts/authenticate.sh`
adds it). Issue fields are only filled where empty - a value someone set by hand is never
overwritten.

### A failed bug is still `Active` in ADO

Failed and unfinished bugs are returned to `ADO_NEW_STATE` (currently `Triaged`)
automatically, with any rerun request tag retained. If that write itself fails, the bug's
status reports the reset failure and its log has a WARNING - set it to the configured intake
state by hand to have it retried.

### Leftover worktree under `$APP_WORKTREE_DIR`

`start-parallel-investigation.sh` uses one shared, read-only worktree (`rca-shared-<branch>`)
for the whole run and removes it once every bug has finished. A worktree left behind means a
prior run crashed before cleanup - `./scripts/test-bug-migration.sh` flags this. It's safe to
delete manually (`git -C <APP_REPO_DIR> worktree remove --force <path>`) or let the next run's
`ensure_shared_readonly_worktree` reuse and refresh it automatically.

### `git worktree add` silently fails for some bugs

This was a real, confirmed failure mode when worktree creation happened per-bug and
concurrently - see `scripts/lib/common.sh`'s `ensure_worktree` comment. It no longer applies to
investigation (which shares one worktree, created once), but can still happen if a fix
worktree were ever added back for a future phase - `git worktree add` mutates shared metadata
under `$APP_REPO_DIR/.git/worktrees` and must be serialized (already handled via `flock` in
`common.sh`).

## Common Issues

### Authentication Errors
- Run `./install.sh --check` to see which login failed, then `./scripts/authenticate.sh`
- If using `configs/credentials.conf`, check the tokens haven't expired and have the right
  scopes (GitHub: repo, read:org, project; ADO: Work Items read & write)

### Dependency Issues
- Re-run `./install.sh` - it installs only what's missing
- Check internet connectivity and sudo privileges
- `herdr`/`claude` "not found": open a new terminal (or `source ~/.bashrc`) so `~/.local/bin`
  is on `PATH`

### WSL Issues
- Ensure WSL2 is properly installed
- Restart WSL: wsl --shutdown
- Check Ubuntu distribution: wsl -l -v

### GitHub CLI Issues
- Re-authenticate: gh auth login
- Check token permissions
- Verify repository access

### Azure DevOps Issues
- Verify personal access token
- Check organization and project names
- Confirm API access permissions

## Debugging Steps

1. Run `./install.sh --check` to diagnose the installation
2. Check the per-bug log for the failing bug: `temp/log-<ado-id>.txt`
3. Verify settings in `configs/system.conf` (and `configs/system.local.conf` if you have one)
4. Re-run `./install.sh` if needed

## Log Files

- `temp/log-<ado-id>.txt` - full log of one bug's investigation
- `temp/rca-<ado-id>.md` - the report the agent wrote
- `temp/rca-<ado-id>-raw-capture.log` - pane output captured when an agent produced no report

## Support

If you continue to experience issues:
1. Check the GitHub repository issues
2. Review the documentation
3. Contact the maintainers