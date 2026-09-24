#!/bin/bash
# Installs and configures everything the Bug Management System needs, then verifies it.
# Safe to re-run: anything already installed, configured or logged in is left alone.
#
# Usage: ./install.sh              install whatever is missing, log in, then run the checks
#        ./install.sh --configure  change settings (org, repo, ADO project, paths, ...) - writes
#                                  only what differs from the defaults to system.local.conf
#        ./install.sh --check      checks only - changes nothing; exits non-zero if any fail
#
# Supported: any Ubuntu (or Debian) release, including WSL2 on Windows (win-scripts/install.bat
# runs this), as root or as a user with sudo. Every setting comes from configs/system.conf.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$REPO_ROOT/configs/system.conf"

MODE=install
case "${1:-}" in
  --check) MODE=check ;;
  --configure) MODE=configure ;;
  "") ;;
  *) echo "Usage: $0 [--check | --configure]" >&2; exit 2 ;;
esac

# herdr and Claude Code install into ~/.local/bin, which a fresh shell may not have on PATH yet.
export PATH="$HOME/.local/bin:$PATH"

step() { printf '\n== %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }
die() { echo "ERROR: $*" >&2; exit 1; }

# Root (containers, minimal images) has no sudo and doesn't need it.
if [ "$(id -u)" -eq 0 ]; then
  SUDO=()
else
  SUDO=(sudo)
fi
need_sudo() {
  [ ${#SUDO[@]} -eq 0 ] || have sudo || die "sudo not found - re-run as root, or install sudo first"
}
apt_install() {
  need_sudo
  "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

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
  have dpkg-query && dpkg-query -W -f='${Status}' ca-certificates 2>/dev/null | grep -q 'ok installed' \
    || missing+=(ca-certificates)
  if [ ${#missing[@]} -eq 0 ]; then
    echo "  already installed"
    return
  fi
  need_sudo
  "${SUDO[@]}" apt-get update && apt_install "${missing[@]}" || die "apt-get install failed"
}

# The pipeline needs `gh issue create --type`, which older gh builds lack - including the one in
# Ubuntu's own archive (e.g. 2.45 on 24.04). So a gh that's merely present isn't enough: test
# for the feature, and install or upgrade from GitHub's official apt repo when it's missing.
gh_supported() {
  have gh && gh issue create --help 2>/dev/null | grep -q -- '--type'
}

install_gh() {
  step "GitHub CLI (gh)"
  if gh_supported; then
    echo "  ok: $(command -v gh) ($(gh --version | head -1))"
    return
  fi
  if have gh; then
    echo "  $(command -v gh) ($(gh --version | head -1)) is too old - installing the current release"
  fi
  need_sudo
  "${SUDO[@]}" mkdir -p -m 755 /etc/apt/keyrings
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | "${SUDO[@]}" tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null || die "failed to fetch gh signing key"
  "${SUDO[@]}" chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | "${SUDO[@]}" tee /etc/apt/sources.list.d/github-cli.list >/dev/null
  "${SUDO[@]}" apt-get update && apt_install gh || die "gh install failed"
  hash -r
  # A snap or hand-installed gh earlier on PATH would still shadow the new /usr/bin/gh.
  gh_supported || die "installed gh to /usr/bin/gh, but $(command -v gh) comes first on PATH and is too old - remove it (e.g. 'sudo snap remove gh') and re-run"
  echo "  ok: $(command -v gh) ($(gh --version | head -1))"
}

install_az() {
  step "Azure CLI (az) + azure-devops extension"
  if have az; then
    echo "  az already installed"
  else
    need_sudo
    curl -fsSL https://aka.ms/InstallAzureCLIDeb | "${SUDO[@]}" bash || die "az install failed"
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
  if [ -t 0 ]; then
    if [ -z "$(git config --global user.name)" ]; then
      read -rp "  Your name for git commits: " name
      [ -n "$name" ] && git config --global user.name "$name"
    fi
    if [ -z "$(git config --global user.email)" ]; then
      read -rp "  Your email for git commits: " email
      [ -n "$email" ] && git config --global user.email "$email"
    fi
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
# Configure
# ---------------------------------------------------------------------------------------------

# Settings the wizard asks about - the ones that differ between people or teams. Everything else
# in system.conf can still be overridden by adding it to system.local.conf by hand.
CONFIGURE_VARS=(
  GITHUB_ORG             "GitHub org that owns the app repo"
  GITHUB_REPO            "GitHub app repo (tracking issues are created here)"
  APP_REPO_DIR           "Where to clone the app repo locally"
  APP_WORKTREE_DIR       "Where to put investigation worktrees"
  DEFAULT_BASE_BRANCH    "Branch bugs are investigated against"
  ADO_ORG                "Azure DevOps organization URL"
  ADO_PROJECT            "Azure DevOps project"
  MIGRATION_TAG          "ADO tag that marks bugs to migrate"
  DEFAULT_LIMIT          "Bugs processed per run by default"
  MAX_PARALLEL_INVESTIGATIONS "Max bugs investigated at once"
)

# Prompts for each CONFIGURE_VARS setting (Enter keeps the current value), then rewrites
# system.local.conf with only the values that differ from system.conf's defaults. Lines for any
# other settings already in system.local.conf are kept as-is.
run_configure() {
  step "Configure (Enter keeps the value in [brackets])"
  local i var desc current default answer
  local -a changed=()
  local tmp
  tmp=$(mktemp)
  if [ -f "$LOCAL_CONF" ]; then cp "$LOCAL_CONF" "$tmp"; else
    echo "# Written by ./install.sh --configure - overrides for configs/system.conf" > "$tmp"
  fi
  for ((i = 0; i < ${#CONFIGURE_VARS[@]}; i += 2)); do
    var="${CONFIGURE_VARS[i]}" desc="${CONFIGURE_VARS[i+1]}"
    current="${!var}"
    default=$(BMS_NO_LOCAL_CONF=1 bash -c 'source "$1" && printf "%s" "${!2}"' _ "$CONFIGS_DIR/system.conf" "$var")
    read -rp "  $desc [$current]: " answer
    answer="${answer:-$current}"
    answer="${answer/#\~/$HOME}"
    grep -v "^${var}=" "$tmp" > "$tmp.new"; mv "$tmp.new" "$tmp"
    if [ "$answer" != "$default" ]; then
      printf '%s=%q\n' "$var" "$answer" >> "$tmp"
      changed+=("$var")
    fi
    printf -v "$var" '%s' "$answer"
  done
  mv "$tmp" "$LOCAL_CONF"
  if [ ${#changed[@]} -eq 0 ]; then
    echo "  all defaults - $LOCAL_CONF has no overrides for these settings"
  else
    echo "  saved to $LOCAL_CONF: ${changed[*]}"
  fi
  # Re-load so derived settings (APP_REPO_URL) follow the new org/repo.
  unset APP_REPO_URL
  source "$CONFIGS_DIR/system.conf"
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

  if gh_supported; then
    pass "gh supports issue types ($(command -v gh), $(gh --version | head -1 | awk '{print $3}'))"
  elif have gh; then
    fail "gh at $(command -v gh) is too old (no 'issue create --type') - re-run ./install.sh"
  fi

  if have gh && gh auth status >/dev/null 2>&1; then
    pass "GitHub logged in"
    if gh repo view "$GITHUB_ORG/$GITHUB_REPO" --json name >/dev/null 2>&1; then
      pass "GitHub repo $GITHUB_ORG/$GITHUB_REPO reachable"
    else
      fail "no access to GitHub repo $GITHUB_ORG/$GITHUB_REPO"
    fi
    local missing_scopes
    missing_scopes=$("$REPO_ROOT/scripts/authenticate.sh" --missing-scopes)
    if [ -z "$missing_scopes" ]; then
      pass "GitHub token has scopes: $GITHUB_REQUIRED_SCOPES"
    else
      warn "GitHub token lacks scope(s): $missing_scopes (run scripts/authenticate.sh)"
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

if [ "$MODE" = configure ]; then
  run_configure
elif [ "$MODE" = install ]; then
  install_apt_packages
  install_gh
  install_az
  install_herdr
  install_claude
  prepare_repo
  if [ ! -f "$LOCAL_CONF" ] && [ -t 0 ]; then
    step "Settings"
    echo "  Defaults: $GITHUB_ORG/$GITHUB_REPO, ADO '$ADO_PROJECT', app clone at $APP_REPO_DIR"
    read -rp "  Use these defaults? [Y/n] " answer
    case "$answer" in [nN]*) run_configure ;; esac
  fi
  step "Logins"
  "$REPO_ROOT/scripts/authenticate.sh" || die "authentication failed - fix the error above and re-run ./install.sh"
  configure_git
  clone_app_repo
fi

if run_checks; then
  if [ "$MODE" = install ]; then
    cat <<EOF

Installed. Next:
  1. Start herdr in a separate terminal:   herdr
  2. Do a dry run (changes nothing):       ./scripts/run-full-process.sh
  3. Go live when the preview looks right: ./scripts/run-full-process.sh --live

Change settings any time with: ./install.sh --configure
EOF
  fi
  exit 0
fi
echo "Fix the failures above, then re-run ./install.sh (or ./install.sh --check)."
exit 1
