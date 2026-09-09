#!/bin/bash
# Authenticate with required services

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../configs/system.conf"
source "$SCRIPT_DIR/../configs/credentials.conf"

echo "Authenticating with GitHub..."
echo "$GITHUB_TOKEN" | gh auth login --with-token

echo "Authenticating with Azure DevOps..."
echo "$ADO_PAT" | az devops login

echo "Authentication completed!"