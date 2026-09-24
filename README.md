# Bug Management System

Automates the bridge from Azure DevOps bugs to GitHub tracking issues, using
[Herdr](https://herdr.dev) to run real, parallel Claude Code agents per bug. Scope is
deliberately narrow: **ADO -> investigated, reviewable GitHub issue.** It does not implement
fixes, open PRs, or touch code beyond reading it for investigation. It does **not**
re-implement root-cause analysis itself either - it delegates that to the target application
repo's own purpose-built subagent (`bcx-bug-rca-agent` in `bcx-reporting-platform/.claude/agents/`),
which already encodes that repo's architecture rules and learned-fix history. This repo's job
is the plumbing: querying ADO, fanning investigation agents out via Herdr, and creating the
tracking issue (or commenting back on ADO) from what they find.

## How it fits together

1. **Migration** (`start-bug-migration.sh`): finds ADO bugs tagged `MigrateToGitHub`, checks out
   one shared, read-only worktree for the whole run (detached HEAD on `origin/<branch>` - the
   RCA agent never writes code, so every bug in the run can safely read the same checkout
   concurrently instead of each getting its own), then opens one live `claude` agent per bug
   against it and asks it to run `bcx-bug-rca-agent` directly against the ADO ticket - no
   GitHub issue exists yet. The agent stops after producing a resolution plan; it never writes
   code. The shared worktree is removed once every bug in the run has finished investigating -
   it only exists to isolate this run's code snapshot from whatever else is happening in the
   app repo (your own separate work in another app). Exactly one of three things happens as
   the deterministic final step (otherwise the bug fails and its pane is left open):
   - A complete plan was produced -> the **tracking GitHub issue is created from that report**
     (title `Fix: <bug title>`), rendered through `templates/tracking-issue.md`, which adds the
     commit that was investigated and the `ADO-#<id>` link. The report must contain every
     heading in `REQUIRED_REPORT_SECTIONS` (Root Cause Analysis, Resolution Plan, Root Cause
     Summary, Defect Location, Proposed Fix, Files to Modify, Tenant Safety, Regression Risk) -
     one that doesn't is treated as a failed investigation, not turned into an issue. The ADO
     ticket gets a comment linking to it.
   - The agent hit its own Step 0 "BLOCKER FOUND" case (not enough information to
     investigate) -> **no GitHub issue is created**; instead a comment is posted on the ADO
     ticket saying more information is required, with the specific blocker detail. The bug is
     marked `BLOCKED` in `state/ado-to-github-map.json` so it isn't re-investigated and
     re-commented on every future run - clear that entry once the ticket has enough
     information to retry.
   - The agent found the bug **already fixed** in the investigated code -> **no GitHub issue
     is created**; its evidence (which commit fixed it, how it verified that) is posted as an
     ADO comment, the tag becomes `AlreadyFixed`, and the bug is marked `ALREADY_FIXED` in the
     state file.
2. **The tracking issue is the end of this system.** It *is* the RCA and resolution plan, not
   an ADO copy (the bug itself stays in ADO), written to stand on its own so a separate
   resolution process can implement from it without re-investigating. Implementing,
   approving or assigning fixes is out of this repo's scope.

Everything defaults to a **dry run** (`--limit 1`, no `--live`) so you can review exactly what
would be created before anything touches real ADO tickets or GitHub issues.

The shared investigation worktree is based on `main` by default - pass `--branch <name>` to
target a different base for bugs that live on a different branch (it's a detached checkout of
that branch; nothing is ever committed to it). It applies to every bug processed in that
invocation and isn't persisted anywhere.

## Directories
- `agents/` - vendored copy of `bcx-bug-rca-agent.md`. `bcx-reporting-platform/.claude/agents/`
  is the source of truth for it; `ensure_app_clone` in `scripts/lib/common.sh` installs the
  vendored copy into the cloned app repo only if it's missing there (older branch, fork, etc.)
  - a defensive fallback, not a fork of the real thing.
- `scripts/` - automation scripts (`scripts/lib/` has shared helpers: `common.sh` for
  config/state/worktrees, `herdr.sh` for driving Claude Code agents through Herdr panes)
- `configs/` - `system.conf` (every setting), plus optional gitignored `system.local.conf`
  (per-machine overrides) and `credentials.conf` (tokens)
- `docs/` - user guide, process summary, migration process, troubleshooting, and a from-scratch
  setup walkthrough (see Documentation below)
- `state/` - `ado-to-github-map.json` (which ADO bugs have a GitHub issue, or are `BLOCKED` /
  `ALREADY_FIXED`)
- `templates/` - `tracking-issue.md`, the body of every tracking issue (`TRACKING_ISSUE_TEMPLATE`)
- `logs/`, `temp/` - runtime output
- `win-scripts/` - `install.bat` / `run.bat`, for launching from Windows via WSL

## Install

```bash
git clone https://github.com/ac-gls/bug-management-system.git ~/source/repos/bug-management-system
cd ~/source/repos/bug-management-system
./install.sh              # installs gh, az (+ azure-devops), jq, herdr, Claude Code; logs you in
./install.sh --configure  # change settings (org, repo, ADO project, paths, parallelism, ...)
./install.sh --check      # verify an installation - changes nothing
```

Runs on any Ubuntu (or Debian) release, WSL2 included - on Windows, `win-scripts\install.bat`
does the same. Safe to re-run. Full walkthrough: [Setup Guide](docs/setup-guide.md).

Each run also needs a Herdr server: start `herdr` in a separate terminal first - the agents run
in its panes (`herdr agent start` needs an existing interactive pane, which the scripts create
via `herdr workspace create`).

## Configuration

`configs/system.conf` holds every setting, with boostCX defaults that work as-is: GitHub
org/repo and issue label/type, ADO org/project/work-item type and states, migration tags, the
target app repo location, the RCA agent name, parallelism, timeouts and project-board IDs.
Paths are derived from wherever the repo is cloned.

For per-machine changes, run `./install.sh --configure` (or edit `configs/system.local.conf`
by hand - gitignored, sourced after `system.conf`) instead of editing the tracked file.

`configs/credentials.conf` is optional (gitignored, copy from `credentials.conf.example`) -
`GITHUB_TOKEN` / `ADO_PAT` are only needed to use tokens instead of the interactive logins.

## Usage

```bash
# One bug at a time, dry run (default) - review before going live
./scripts/start-bug-migration.sh
./scripts/run-full-process.sh

# Actually create issues/comments
./scripts/start-bug-migration.sh --live
./scripts/run-full-process.sh --limit 5 --live
```

Individual steps (each script's header comment documents its exact behavior): `get-ado-bugs.sh`,
`start-parallel-investigation.sh` (creates the tracking issue itself, via
`create_tracking_issue()` in `scripts/lib/common.sh`), `test-bug-migration.sh` (verifies issues
were created and the shared worktree was cleaned up).

## Documentation
- [User Guide](docs/user-guide.md)
- [Process Summary](docs/process-summary.md)
- [Migration Process](docs/migration-process.md)
- [Troubleshooting Guide](docs/troubleshooting.md)
- [Setup Guide](docs/setup-guide.md) - installing on a new machine

If any doc and the actual code disagree, `scripts/*.sh` header comments are authoritative.

## Contributing
1. Fork the repository
2. Create a feature branch
3. Commit your changes
4. Push to the branch
5. Create a pull request

## License
This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
