# Bug Management System User Guide

## What This Does

Investigates ADO bugs tagged `MigrateToGitHub` (via `bcx-bug-rca-agent` against a read-only
checkout of the target app repo) and creates a GitHub tracking issue from the resulting
resolution plan - or comments back on the ADO ticket if the agent couldn't establish enough
context. It does not implement fixes, run tests, or open pull requests; that's your team's own
process once the tracking issue exists. See `docs/process-summary.md` for the full picture.

## Getting Started

1. Install: `./install.sh` (see the [Setup Guide](setup-guide.md))
2. Start Herdr in a separate terminal: `herdr`
3. Tag the ADO bugs you want migrated with `MigrateToGitHub`
4. Run the system (dry run first - see below)

## Configuration

`configs/system.conf` holds every setting, with boostCX defaults: GitHub org/repo and issue
label/type, ADO org/project/work-item states, the target app repo's location, the migration
tags, the RCA agent name, parallelism and Herdr timeouts. Override any of them per machine in
`configs/system.local.conf` (copy `system.local.conf.example`; gitignored).

`configs/credentials.conf` is optional - only needed to use tokens instead of the interactive
logins `install.sh` sets up (copy `credentials.conf.example`).

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
- `configs/`: `system.conf`, plus optional gitignored `system.local.conf` and `credentials.conf`
- `docs/`: documentation (this guide, process summary, troubleshooting)
- `state/`: `ado-to-github-map.json` - which ADO bugs already have a GitHub issue, or are
  `BLOCKED` pending more information
- `logs/`, `temp/`: runtime output (`temp/ado-bugs.json`, per-bug `temp/log-<id>.txt`)
- `win-scripts/`: `install.bat` and `run.bat` for launching from Windows

## Prerequisites

Everything is installed by `./install.sh` - see the [Setup Guide](setup-guide.md). Check the
installation any time with `./install.sh --check`.
