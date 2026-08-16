#!/bin/bash
# Main orchestration script

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../configs/system.conf"
source "$SCRIPT_DIR/../configs/credentials.conf"

echo "Starting Bug Management System..."

# Phase 1: Migration
echo "Phase 1: Bug Migration"
# ./scripts/get-ado-bugs.sh

# Phase 2: Fixing
echo "Phase 2: Bug Fixing"
# ./scripts/start-bug-fixing.sh

echo "Bug Management System process completed!"