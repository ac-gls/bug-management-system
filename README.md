# Bug Management System

Automates the bridge between Azure DevOps bugs and GitHub, using [Herdr](https://herdr.dev) to
run real, parallel Claude Code agents per bug. It does **not** re-implement root-cause
analysis or fix implementation itself - it delegates that to the target application repo's
own purpose-built subagents (`bcx-bug-rca-agent` and `bcx-bug-coder-agent` in
`bcx-reporting-platform/.claude/agents/`), which already encode that repo's architecture rules
and learned-fix history. This repo's job is the plumbing: querying ADO, creating/labeling
GitHub issues, fanning agents out across git worktrees via Herdr, capturing their reports, and
independently verifying fixes before opening a PR.

## How it fits together

1. **Migration** (`start-bug-migration.sh`): finds ADO bugs tagged `MigrateToGitHub`, checks out
   one shared, read-only worktree for the whole run (detached HEAD on `origin/<branch>` - the
   RCA agent never writes code, so every bug in the run can safely read the same checkout
   concurrently instead of each getting its own), then opens one live `claude` agent per bug
   against it and asks it to run `bcx-bug-rca-agent` directly against the ADO ticket - no
   GitHub issue exists yet. The agent stops after producing a resolution plan; it never writes
   code. The shared worktree is removed once every bug in the run has finished investigating -
   it only exists to isolate this run's code snapshot from whatever else is happening in the
   app repo (a concurrent fixing pass, your own separate work in another app). Exactly one of
   two things happens as the deterministic final step:
   - A real plan was produced -> the **tracking GitHub issue is created from that report**
     (title `Fix: <bug title>`, body = the resolution plan itself, matching
     `bcx-bug-rca-agent`'s own Step 4 convention) rather than pre-creating a plain issue that
     just replicates the ADO ticket's raw description. The ADO ticket gets a comment linking to
     it.
   - The agent hit its own Step 0 "BLOCKER FOUND" case (not enough information to
     investigate) -> **no GitHub issue is created**; instead a comment is posted on the ADO
     ticket saying more information is required, with the specific blocker detail. The bug is
     marked `BLOCKED` in `state/ado-to-github-map.json` so it isn't re-investigated and
     re-commented on every future run - clear that entry once the ticket has enough
     information to retry.
2. **Human review**: read the tracking issue - it *is* the RCA output, not an ADO copy. If
   you're satisfied, add the `plan-approved` label yourself.
3. **Fixing** (`get-ready-issues.sh` + `start-bug-fixing.sh` + `new-pull-request.sh`): finds
   issues labeled `plan-approved`, opens a fresh worktree + agent per issue, asks it to run
   `bcx-bug-coder-agent` against the approved plan. That agent implements the fix and comments
   progress, but never opens a PR. This repo then independently runs the real build/test
   commands against the worktree and only opens a draft PR if they pass; otherwise it comments
   the failure back on the issue instead.

Everything defaults to a **dry run** (`--limit 1`, no `--live`) so you can review exactly what
would be created before anything touches real ADO tickets or GitHub issues/PRs.

Investigation's shared worktree and fix worktrees are both based on `main` by default - pass
`--branch <name>` to target a different base for bugs that live on a different branch (the
investigation worktree is a detached checkout of that branch; each fix worktree still branches
off it per issue, since that one actually gets committed to and becomes a PR). It applies to
every bug processed in that invocation, isn't persisted anywhere, and must be passed consistently to every script
call for the same batch of bugs (migration scripts, then later the fixing-phase scripts for
the same issues) - a mismatch silently opens the PR against the wrong base.

## Directories
- `agents/` - vendored copies of `bcx-bug-rca-agent.md` and `bcx-bug-coder-agent.md`.
  `bcx-reporting-platform/.claude/agents/` is the source of truth for these; `ensure_app_clone`
  in `scripts/lib/common.sh` installs a vendored copy into the cloned app repo only if it's
  missing there (older branch, fork, etc.) - a defensive fallback, not a fork of the real thing.
- `scripts/` - automation scripts (`scripts/lib/` has shared helpers: `common.sh` for
  config/state/worktrees, `herdr.sh` for driving Claude Code agents through Herdr panes)
- `configs/` - `system.conf` (org/repo/ADO settings) and `credentials.conf` (gitignored tokens)
- `docs/` - design docs (see note below - these predate the real implementation)
- `state/` - `ado-to-github-map.json` (which ADO bugs have a GitHub issue) and per-issue
  `fix-<n>.result` verification outcomes
- `logs/`, `temp/` - runtime output
- `win-scripts/` - Windows batch wrappers

## Prerequisites
- WSL2 Ubuntu with `gh`, `az` (+ `azure-devops` extension, `az devops configure -d
  organization=... project=...`), `jq`, and `herdr` installed and authenticated
- A `claude` CLI reachable from WSL (native install, or a `~/.local/bin/claude` wrapper
  execing a Windows-side `claude.exe` via WSL interop)
- A running herdr server/session (`herdr status`) - `herdr agent start --kind claude` needs an
  existing interactive pane, which this repo's scripts create via `herdr workspace create`
- The target app repo (`bcx-reporting-platform`) cloned separately at the path configured by
  `APP_REPO_DIR` in `configs/system.conf` - scripts clone it automatically on first run if
  missing, kept independent of any other local working copy you may have

## Configuration

`configs/system.conf` - GitHub org/repo, ADO org/project, target app repo location, migration
tag, and the herdr agent kind/timeout.

`configs/credentials.conf` (gitignored, copy from `configs/credentials.conf.example`):
- `GITHUB_TOKEN` - only needed if `gh` isn't already authenticated in this shell
- `ADO_PAT` - only needed if `az` isn't already authenticated

## Usage

```bash
# One bug/issue at a time, dry run (default) - review before going live
./scripts/start-bug-migration.sh
./scripts/run-full-process.sh

# Actually create issues/comments/PRs
./scripts/start-bug-migration.sh --live
./scripts/run-full-process.sh --limit 5 --live
```

Individual steps (each script's header comment documents its exact behavior):
`get-ado-bugs.sh`, `start-parallel-investigation.sh` (creates the tracking issue itself, via
`create_tracking_issue()` in `scripts/lib/common.sh`), `get-ready-issues.sh`,
`start-bug-fixing.sh`, `new-pull-request.sh`, `test-bug-migration.sh`, `verify-bug-fixes.sh`.

## Documentation
- [User Guide](docs/user-guide.md)
- [Troubleshooting Guide](docs/troubleshooting.md)
- [Migration Process](docs/migration-process.md)
- [Bug Fixing Process](docs/bug-fixing-process.md)

> **Note:** the docs above describe the original design (fictional `herdr agent start name --
> bash script.sh` job-runner syntax, `az boards work-item list`, hand-rolled RCA/TDD/Playwright
> templates). The real implementation in `scripts/` diverges from them where the real `herdr`
> and `az` CLIs, and the target repo's existing subagents, made a different approach both
> correct and considerably simpler. Treat `scripts/*.sh` header comments as authoritative.

## Contributing
1. Fork the repository
2. Create a feature branch
3. Commit your changes
4. Push to the branch
5. Create a pull request

## License
This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
