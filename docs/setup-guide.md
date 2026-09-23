# Setup Guide

Installs the Bug Management System on a new machine. `install.sh` does all of it and is safe
to re-run - anything already installed, configured or logged in is left alone.

## Requirements
- Ubuntu/Debian, or Windows 10/11 with WSL2 (`wsl --install -d Ubuntu` in an admin
  PowerShell, then restart)
- `sudo` rights inside Linux/WSL
- Access to the boostCX GitHub org (`boostCX/bcx-reporting-platform`), the boostCX Azure
  DevOps project, and a Claude account

## Install

In a Linux/WSL terminal:

```bash
git clone https://github.com/ac-gls/bug-management-system.git ~/source/repos/bug-management-system
cd ~/source/repos/bug-management-system
./install.sh
```

On Windows you can instead double-click `win-scripts\install.bat` inside the cloned repo (it
runs `install.sh` in your default WSL distro; set `BMS_WSL_DISTRO` to use another one).

The repo can be cloned anywhere - all paths are derived from its location.

### What install.sh does
1. Installs `git`, `curl`, `jq`, `flock`, the GitHub CLI (`gh`), the Azure CLI (`az`) with the
   `azure-devops` extension, Herdr and Claude Code - only whichever are missing.
2. Adds `~/.local/bin` (where Herdr and Claude Code live) to your `PATH`.
3. Logs you in to GitHub, Azure DevOps and Claude Code (`scripts/authenticate.sh`), including
   the GitHub `project` scope needed to add issues to the project board.
4. Sets your git name/email if missing, and makes git reuse `gh`'s login for github.com.
5. Clones the target app repo to `APP_REPO_DIR`.
6. Runs the checks below.

## Verify

```bash
./install.sh --check
```

Changes nothing; lists every dependency, login and setting as ok / warn / FAIL and exits
non-zero if anything failed. Run it whenever something stops working.

## Configure (optional)

The defaults in `configs/system.conf` are boostCX's and work as-is. Every tunable setting lives
there - org/repo, ADO project, work-item states, tags, issue label/type, parallelism, timeouts.
To change one for your machine only, copy `configs/system.local.conf.example` to
`configs/system.local.conf` and set it there (gitignored, so `git pull` never conflicts).

To use tokens instead of interactive logins, copy `configs/credentials.conf.example` to
`configs/credentials.conf` and fill it in.

## First run

```bash
herdr                               # in a separate terminal - the agents run in its panes
./scripts/run-full-process.sh       # dry run: 1 bug, nothing written to ADO/GitHub
./scripts/run-full-process.sh --live
```

See the [User Guide](user-guide.md) for options.

## Updating

```bash
git pull
./install.sh
```
