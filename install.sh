#!/bin/bash
# Installs and configures everything the Bug Management System needs, then verifies it.
# Safe to re-run: anything already installed, configured or logged in is left alone.
#
# Usage: ./install.sh           install whatever is missing, log in, then run the checks
#        ./install.sh --check   checks only - changes nothing; exits non-zero if any fail
#
# Supported: Ubuntu/Debian, including WSL2 on Windows (win-scripts/install.bat runs this).
# Every setting it uses comes from configs/system.conf.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$REPO_ROOT/configs/system.conf"

CHECK_ONLY=false
case "${1:-}" in
  --check) CHECK_ONLY=true ;;
  "") ;;
  *) echo "Usage: $0 [--check]" >&2; exit 2 ;;
esac

# herdr and Claude Code install into ~/.local/bin, which a fresh shell may not have on PATH yet.
export PATH="$HOME/.local/bin:$PATH"

step() { printf '\n== %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }
die() { echo "ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------------------------

install_apt_packages() {
  step "System packages"
  have apt-get || die "apt-get not found - this installer supports Ubuntu/Debian (incl. WSL2). Install git, curl, jq, flock (util-linux), gh, az, herdr and claude manually, then run ./install.sh --check"
  local missing=()
  have git   || missing+=(git)
  have curl  || missing+=(curl)
  have jq    || missing+=(jq)
  have flock || missing+=(util-linux)
  have gpg   || missing+=(gnupg)
  if [ ${#missing[@]} -eq 0 ]; then
    echo "  already installed"
    return
  fi
  sudo apt-get update && sudo apt-get install -y "${missing[@]}" ca-certificates || die "apt-get install failed"
}

install_gh() {
  step "GitHub CLI (gh)"
  if have gh; then echo "  already installed ($(gh --version | head -1))"; return; fi
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg status=none || die "failed to fetch gh signing key"
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
  sudo apt-get update && sudo apt-get install -y gh || die "gh install failed"
}

install_az() {
  step "Azure CLI (az) + azure-devops extension"
  if have az; then
    echo "  az already installed"
  else
    curl -fsSL https://aka.ms/InstallAzureCLIDeb | sudo bash || die "az install failed"
  fi
  if az extension show --name azure-devops -o none >/dev/null 2>&1; then
    echo "  azure-devops extension already installed"
  else
    az extension add --name azure-devops --yes --only-show-errors || die "az extension add azure-devops failed"
  fi
  az devops configure --defaults organization="$ADO_ORG" project="$ADO_PROJECT" || die "az devops configure failed"
}

install_herdr() {
  step "Herdr"
  if have herdr; then echo "  already installed ($(herdr --version))"; return; fi
  curl -fsSL https://herdr.dev/install.sh | sh || die "herdr install failed"
  have herdr || die "herdr installed but not on PATH - add ~/.local/bin to PATH and re-run"
}

install_claude() {
  step "Claude Code"
  if have claude; then echo "  already installed ($(claude --version))"; return; fi
  curl -fsSL https://claude.ai/install.sh | bash || die "Claude Code install failed"
  have claude || die "claude installed but not on PATH - add ~/.local/bin to PATH and re-run"
}

configure_git() {
  step "Git configuration"
  # The pipeline itself never commits; identity is only for contributing to this repo.
  local name email
  if [ -z "$(git config --global user.name)" ]; then
    read -rp "  Your name for git commits: " name
    git config --global user.name "$name"
  fi
  if [ -z "$(git config --global user.email)" ]; then
    read -rp "  Your email for git commits: " email
    git config --global user.email "$email"
  fi
  echo "  identity: $(git config --global user.name) <$(git config --global user.email)>"
  # Without a credential helper, `git clone` of the private app repo over https hangs silently.
  # This makes git reuse gh's login for github.com.
  if [ "$(git config --global --get credential.https://github.com.helper)" != "!gh auth git-credential" ]; then
    git config --global credential."https://github.com".helper "!gh auth git-credential"
    echo "  set git to use gh's login for github.com"
  fi
}

prepare_repo() {
  step "Repository setup"
  mkdir -p "$LOG_DIR" "$TEMP_DIR" "$STATE_DIR"
  chmod +x "$REPO_ROOT"/install.sh "$REPO_ROOT"/scripts/*.sh "$REPO_ROOT"/scripts/lib/*.sh
  if [ -f "$CONFIGS_DIR/credentials.conf" ]; then chmod 600 "$CONFIGS_DIR/credentials.conf"; fi
  if ! grep -qs '\.local/bin' "$HOME/.bashrc" "$HOME/.profile"; then
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
    echo "  added ~/.local/bin to PATH in ~/.bashrc"
  fi
  echo "  ok"
}

clone_app_repo() {
  step "Target app repo ($APP_REPO_DIR)"
  # Reuses the pipeline's own clone/fetch so first runs don't differ from installs.
  ( source "$REPO_ROOT/scripts/lib/common.sh" && ensure_app_clone ) || die "could not clone/fetch $APP_REPO_URL"
}

# ---------------------------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------------------------

PASSED=0 FAILED=0 WARNED=0
pass() { echo "  [ok]   $*"; PASSED=$((PASSED + 1)); }
fail() { echo "  [FAIL] $*"; FAILED=$((FAILED + 1)); }
warn() { echo "  [warn] $*"; WARNED=$((WARNED + 1)); }

run_checks() {
  step "Checks"
  local cmd
  for cmd in git curl jq flock gh az herdr claude; do
    if have "$cmd"; then pass "$cmd installed"; else fail "$cmd not installed"; fi
  done

  local var
  for var in GITHUB_ORG GITHUB_REPO APP_REPO_URL APP_REPO_DIR APP_WORKTREE_DIR ADO_ORG \
             ADO_PROJECT ADO_WORK_ITEM_TYPE ADO_NEW_STATE ADO_ACTIVE_STATE MIGRATION_TAG \
             MIGRATED_TAG BLOCKED_TAG RCA_AGENT_NAME HERDR_AGENT_KIND DEFAULT_BASE_BRANCH; do
    [ -n "${!var:-}" ] || fail "configs/system.conf: $var is empty"
  done
  pass "configs/system.conf loaded (workspace: $WORKSPACE_ROOT)"

  if have az && az extension show --name azure-devops -o none >/dev/null 2>&1; then
    pass "az azure-devops extension installed"
  else
    fail "az azure-devops extension missing"
  fi

  if [ -n "$(git config --global user.name)" ] && [ -n "$(git config --global user.email)" ]; then
    pass "git identity set"
  else
    warn "git user.name/user.email not set globally - only needed to commit changes to this repo"
  fi

  if have gh && gh auth status >/dev/null 2>&1; then
    pass "GitHub logged in"
    if gh repo view "$GITHUB_ORG/$GITHUB_REPO" --json name >/dev/null 2>&1; then
      pass "GitHub repo $GITHUB_ORG/$GITHUB_REPO reachable"
    else
      fail "no access to GitHub repo $GITHUB_ORG/$GITHUB_REPO"
    fi
    if gh auth status 2>&1 | grep -q "'project'"; then
      pass "GitHub token has 'project' scope"
    else
      warn "GitHub token lacks 'project' scope - issues won't be added to the project board (run scripts/authenticate.sh)"
    fi
  else
    fail "GitHub not logged in (run scripts/authenticate.sh)"
  fi

  if have az && az devops project show --project "$ADO_PROJECT" --organization "$ADO_ORG" -o none >/dev/null 2>&1; then
    pass "Azure DevOps project '$ADO_PROJECT' reachable"
  else
    fail "Azure DevOps not reachable/logged in (run scripts/authenticate.sh)"
  fi

  if have claude && claude auth status 2>/dev/null | jq -e '.loggedIn == true' >/dev/null 2>&1; then
    pass "Claude Code logged in"
  else
    fail "Claude Code not logged in (run: claude auth login)"
  fi

  if have herdr && herdr status server 2>/dev/null | grep -q 'status: running'; then
    pass "herdr server running"
  else
    warn "herdr server not running - start it by running 'herdr' in a separate terminal before each run"
  fi

  if [ -d "$APP_REPO_DIR/.git" ]; then
    pass "app repo cloned at $APP_REPO_DIR"
    if [ -f "$APP_REPO_DIR/.claude/agents/$RCA_AGENT_NAME.md" ]; then
      pass "$RCA_AGENT_NAME agent present in app repo"
    else
      warn "$RCA_AGENT_NAME agent missing from app repo - the first run installs agents/$RCA_AGENT_NAME.md"
    fi
  else
    warn "app repo not cloned yet - the first run clones it to $APP_REPO_DIR"
  fi

  printf '\n%d passed, %d warning(s), %d failed\n' "$PASSED" "$WARNED" "$FAILED"
  [ "$FAILED" -eq 0 ]
}

# ---------------------------------------------------------------------------------------------

if [ "$CHECK_ONLY" != true ]; then
  install_apt_packages
  install_gh
  install_az
  install_herdr
  install_claude
  prepare_repo
  step "Logins"
  "$REPO_ROOT/scripts/authenticate.sh" || die "authentication failed - fix the error above and re-run ./install.sh"
  configure_git
  clone_app_repo
fi

if run_checks; then
  if [ "$CHECK_ONLY" != true ]; then
    cat <<EOF

Installed. Next:
  1. Start herdr in a separate terminal:   herdr
  2. Do a dry run (changes nothing):       ./scripts/run-full-process.sh
  3. Go live when the preview looks right: ./scripts/run-full-process.sh --live
EOF
  fi
  exit 0
fi
echo "Fix the failures above, then re-run ./install.sh (or ./install.sh --check)."
exit 1
