# Setup Guide

Installs the Bug Management System on a new machine. `install.sh` does all of it and is safe
to re-run - anything already installed, configured or logged in is left alone.

## Requirements
- Any Ubuntu release (or Debian), or Windows 10/11 with WSL2 (`wsl --install -d Ubuntu` in an
  admin PowerShell, then restart)
- `sudo` rights, or a root shell
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
3. On first install, shows the default settings and offers to change them (see Configure).
4. Logs you in to GitHub, Azure DevOps and Claude Code (`scripts/authenticate.sh`).
5. Sets your git name/email if missing, and makes git reuse `gh`'s login for github.com.
6. Clones the target app repo to `APP_REPO_DIR`.
7. Runs the checks below.

### GitHub CLI (gh)
- **Version:** the pipeline needs `gh issue create --type`, which older builds lack - including
  the `gh` in Ubuntu's own archive. `install.sh` tests for that feature rather than just for
  `gh`, and installs or upgrades from GitHub's official apt repo (`cli.github.com`) when it's
  missing. An existing `gh` that's new enough is left alone, including a WSL wrapper around
  Windows' `gh.exe`.
- **Login:** `gh auth login` via a one-time code and URL, so it works without a browser. It
  asks for the scopes in `GITHUB_REQUIRED_SCOPES` (`repo read:org project`); an existing login
  missing any of them gets `gh auth refresh` for just those.
- **Tokens instead:** set `GITHUB_TOKEN` in `configs/credentials.conf`, or export `GH_TOKEN`.
  A token can't be refreshed, so create it with all three scopes.
- **No terminal** (CI, `docker run` without `-it`): interactive logins are skipped rather than
  left waiting, and the install stops at the login step with instructions - finish with
  `./scripts/authenticate.sh` in a terminal, or supply tokens.
- **git:** git is set to use `gh` for github.com credentials, so cloning the private app repo
  never hangs waiting for a password.

## Verify

```bash
./install.sh --check
```

Changes nothing; lists every dependency, login and setting as ok / warn / FAIL and exits
non-zero if anything failed. Run it whenever something stops working.

## Configure (optional)

The defaults in `configs/system.conf` are boostCX's and work as-is. To change them:

```bash
./install.sh --configure
```

It asks for the settings that commonly differ - GitHub org and repo, app clone location, base
branch, ADO org and project, migration tag, bugs per run, parallelism - showing each current
value (Enter keeps it). Only values that differ from the defaults are saved, to
`configs/system.local.conf` (gitignored, so `git pull` never conflicts); the checks then run
against the new settings.

Every other setting in `system.conf` (work-item states, tags, issue label/type, timeouts, ...)
can be overridden by adding it to `configs/system.local.conf` by hand.

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
