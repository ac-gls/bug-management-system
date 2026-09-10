# Bug Management System User Guide

## What This Does

Investigates ADO bugs tagged `MigrateToGitHub` (via `bcx-bug-rca-agent` against a read-only
checkout of the target app repo) and creates a GitHub tracking issue from the resulting
resolution plan - or comments back on the ADO ticket if the agent couldn't establish enough
context. It does not implement fixes, run tests, or open pull requests; that's your team's own
process once the tracking issue exists. See `docs/process-summary.md` for the full picture.

## Getting Started

1. Run the setup script: `./scripts/install-dependencies.sh`
2. Configure `configs/system.conf` (GitHub org/repo, ADO org/project, target app repo location)
3. Configure credentials (see below)
4. Tag the ADO bugs you want migrated with `MigrateToGitHub`
5. Run the system (dry run first - see below)

## Configuration

Copy `configs/credentials.conf.example` to `configs/credentials.conf` and fill in what's
missing:
- `GITHUB_TOKEN` - only needed if `gh` isn't already authenticated in this shell
- `ADO_PAT` - only needed if `az` isn't already authenticated

`configs/system.conf` holds everything else: GitHub org/repo, ADO org/project, the target app
repo's location, the migration tag, and Herdr agent settings.

## Running the System

```bash
# Dry run (default) - review what would be created without touching ADO/GitHub
./scripts/run-full-process.sh

# Actually create tracking issues and post ADO comments
./scripts/run-full-process.sh --limit 10 --live

# Investigate bugs against a non-default base branch
./scripts/run-full-process.sh --branch release/6.17.1 --live
```

`run-full-process.sh` is a thin wrapper around `./scripts/start-bug-migration.sh` - run that
directly if you want the same behavior without the wrapper.

## Directory Structure

- `agents/` - vendored copy of `bcx-bug-rca-agent.md`, installed into the target app repo if
  missing there
- `scripts/`: automation scripts (`scripts/lib/` has shared helpers)
- `configs/`: `system.conf` and `credentials.conf` (gitignored)
- `docs/`: documentation (this guide, process summary, troubleshooting)
- `state/`: `ado-to-github-map.json` - which ADO bugs already have a GitHub issue, or are
  `BLOCKED` pending more information
- `logs/`, `temp/`: runtime output
- `win-scripts/`: Windows batch scripts

## Prerequisites

- WSL2 Ubuntu with `gh`, `az` (+ `azure-devops` extension), `jq`, and `herdr` installed and
  authenticated
- A `claude` CLI reachable from WSL
- The target app repo cloned separately at the path configured by `APP_REPO_DIR` (cloned
  automatically on first run if missing)

See `README.md` for the full prerequisite and configuration reference.
