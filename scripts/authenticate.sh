#!/bin/bash
# Logs in to GitHub, Azure DevOps and Claude Code - skipping any that already work, so it's
# safe to re-run. Uses tokens from configs/credentials.conf when set, otherwise interactive
# logins. Called by install.sh; run it directly after a login expires.
#
# Usage: ./authenticate.sh
#        ./authenticate.sh --missing-scopes   print required GitHub scopes the current gh login
#                                             lacks (empty if none) and exit - used by install.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../configs/system.conf"
GITHUB_TOKEN="" ADO_PAT=""
if [ -f "$CONFIGS_DIR/credentials.conf" ]; then source "$CONFIGS_DIR/credentials.conf"; fi

# Prints each of $GITHUB_REQUIRED_SCOPES the active github.com login lacks, space-separated.
# Fine-grained tokens report no scopes at all (their permissions aren't visible this way), so
# nothing is reported missing for them.
missing_github_scopes() {
  local status scope missing=()
  status=$(gh auth status --hostname github.com 2>&1) || return 0
  grep -q "Token scopes:" <<< "$status" || return 0
  for scope in $GITHUB_REQUIRED_SCOPES; do
    grep -q "'$scope'" <<< "$status" || missing+=("$scope")
  done
  echo "${missing[*]}"
}

if [ "${1:-}" = "--missing-scopes" ]; then
  missing_github_scopes
  exit 0
fi

failed=0

# Interactive logins wait for a human to finish them in a browser - with no terminal (CI,
# `docker run` without -it, piped input) they would hang forever, so fail fast instead.
can_prompt() {
  if [ -t 0 ]; then return 0; fi
  echo "  needs an interactive login, but there is no terminal - run ./scripts/authenticate.sh in a terminal, or set tokens in configs/credentials.conf"
  return 1
}

echo "GitHub..."
# A token exported as GH_TOKEN/GITHUB_TOKEN overrides any stored login, and gh refuses to log in
# or refresh while one is set - so it must work as-is.
env_token_var=""
if [ -n "$(printenv GH_TOKEN)" ]; then env_token_var=GH_TOKEN
elif [ -n "$(printenv GITHUB_TOKEN)" ]; then env_token_var=GITHUB_TOKEN; fi

if gh auth status --hostname github.com >/dev/null 2>&1; then
  echo "  already logged in"
elif [ -n "$env_token_var" ]; then
  echo "  the token in \$$env_token_var is invalid or expired - replace it or unset it, then re-run"
  failed=1
elif [ -n "$GITHUB_TOKEN" ]; then
  echo "$GITHUB_TOKEN" | gh auth login --hostname github.com --with-token || failed=1
else
  # Device-code flow: prints a one-time code and URL, so it also works with no browser (plain
  # Ubuntu servers, WSL without a browser bridge).
  scopes_csv="${GITHUB_REQUIRED_SCOPES// /,}"
  can_prompt && gh auth login --hostname github.com --git-protocol https --web --scopes "$scopes_csv" || failed=1
fi

if gh auth status --hostname github.com >/dev/null 2>&1; then
  missing=$(missing_github_scopes)
  if [ -n "$missing" ]; then
    if [ -n "$env_token_var" ]; then
      # An exported token can't be refreshed - it has to be regenerated with the scopes. A
      # stored login (even one made from credentials.conf's token) can be.
      echo "  warning: the GitHub token lacks scope(s): $missing - regenerate it with: $GITHUB_REQUIRED_SCOPES"
    else
      echo "  adding missing scope(s): $missing"
      can_prompt && gh auth refresh --hostname github.com --scopes "${missing// /,}" || failed=1
    fi
  fi
fi

echo "Azure DevOps..."
if az devops project show --project "$ADO_PROJECT" --organization "$ADO_ORG" -o none >/dev/null 2>&1; then
  echo "  already logged in"
elif [ -n "$ADO_PAT" ]; then
  echo "$ADO_PAT" | az devops login --organization "$ADO_ORG" || failed=1
else
  # ADO users often have no Azure subscription - without this flag az login refuses them.
  can_prompt && az login --allow-no-subscriptions -o none || failed=1
fi

echo "Claude Code..."
if claude auth status 2>/dev/null | jq -e '.loggedIn == true' >/dev/null 2>&1; then
  echo "  already logged in"
else
  can_prompt && claude auth login || failed=1
fi

if [ "$failed" -ne 0 ]; then
  echo "Authentication incomplete - see errors above."
  exit 1
fi
echo "Authentication completed!"
