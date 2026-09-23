#!/bin/bash
# Logs in to GitHub, Azure DevOps and Claude Code - skipping any that already work, so it's
# safe to re-run. Uses tokens from configs/credentials.conf when set, otherwise interactive
# logins. Called by install.sh; run it directly after a login expires.
#
# Usage: ./authenticate.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../configs/system.conf"
GITHUB_TOKEN="" ADO_PAT=""
if [ -f "$CONFIGS_DIR/credentials.conf" ]; then source "$CONFIGS_DIR/credentials.conf"; fi

failed=0

echo "GitHub..."
if gh auth status >/dev/null 2>&1; then
  echo "  already logged in"
elif [ -n "$GITHUB_TOKEN" ]; then
  echo "$GITHUB_TOKEN" | gh auth login --with-token || failed=1
else
  gh auth login --hostname github.com --git-protocol https --web --scopes "project,read:org" || failed=1
fi
# Adding tracking issues to the org project board needs the `project` scope, which a default
# `gh auth login` doesn't request. A token from credentials.conf can't be refreshed this way -
# regenerate it with the scope instead.
if gh auth status >/dev/null 2>&1 && ! gh auth status 2>&1 | grep -q "'project'"; then
  if [ -n "$GITHUB_TOKEN" ]; then
    echo "  warning: GITHUB_TOKEN lacks the 'project' scope - issues won't be added to the project board"
  else
    echo "  adding the 'project' scope (needed to add issues to the project board)..."
    gh auth refresh --hostname github.com --scopes project || failed=1
  fi
fi

echo "Azure DevOps..."
if az devops project show --project "$ADO_PROJECT" --organization "$ADO_ORG" -o none >/dev/null 2>&1; then
  echo "  already logged in"
elif [ -n "$ADO_PAT" ]; then
  echo "$ADO_PAT" | az devops login --organization "$ADO_ORG" || failed=1
else
  # ADO users often have no Azure subscription - without this flag az login refuses them.
  az login --allow-no-subscriptions -o none || failed=1
fi

echo "Claude Code..."
if claude auth status 2>/dev/null | jq -e '.loggedIn == true' >/dev/null 2>&1; then
  echo "  already logged in"
else
  claude auth login || failed=1
fi

if [ "$failed" -ne 0 ]; then
  echo "Authentication incomplete - see errors above."
  exit 1
fi
echo "Authentication completed!"
