# Troubleshooting Guide

## Migration Pipeline Issues

### An agent's pane is left open after a run

`start-parallel-investigation.sh` deliberately leaves a bug's Herdr pane open instead of
guessing when something looks wrong, so you can inspect what actually happened:

- **Agent did not settle in time** - the agent never finished within `HERDR_AGENT_TIMEOUT_MS`
  (default 30 min, `configs/system.conf`). Attach with `herdr session attach default` and check
  the pane directly.
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

### A bug never gets investigated even though it's tagged `MigrateToGitHub`

Check `state/ado-to-github-map.json` - a bug already mapped to an issue number, or marked
`BLOCKED`, is skipped by `get-ado-bugs.sh` on every subsequent run. Clear its entry (and, for a
blocked bug, re-add the `MigrateToGitHub` tag in ADO - the pipeline swaps it to
`RequiresAdditionalInformation` on blocking) to have it picked up again.

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
- Verify credentials in configs/credentials.conf
- Ensure tokens have proper permissions
- Check that tokens haven't expired

### Dependency Issues
- Run scripts/install-dependencies.sh to reinstall
- Check internet connectivity
- Verify sudo privileges

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

1. Run scripts/status-check.sh to diagnose system status
2. Check logs in the logs/ directory
3. Verify configuration files in configs/
4. Re-run installation script if needed

## Log Files

Check the following log files for detailed error information:
- Installation logs in logs/install.log
- Runtime logs in logs/runtime.log
- Error logs in logs/error.log

## Support

If you continue to experience issues:
1. Check the GitHub repository issues
2. Review the documentation
3. Contact the maintainers