#!/bin/bash
# Test installation and configuration

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Testing Bug Management System Installation..."

# Test 1: Check directory structure
echo "Test 1: Directory structure"
if [ -d "$SCRIPT_DIR/../scripts" ] && 
   [ -d "$SCRIPT_DIR/../configs" ] &&
   [ -d "$SCRIPT_DIR/../docs" ]; then
    echo "✓ Directory structure OK"
else
    echo "✗ Directory structure missing"
fi

# Test 2: Check required tools
echo "Test 2: Required tools"
if command -v gh &> /dev/null; then
    echo "✓ GitHub CLI installed"
else
    echo "✗ GitHub CLI not installed"
fi

if command -v az &> /dev/null; then
    echo "✓ Azure CLI installed"
else
    echo "✗ Azure CLI not installed"
fi

# Test 3: Check configuration files
echo "Test 3: Configuration files"
if [ -f "$SCRIPT_DIR/../configs/system.conf" ]; then
    echo "✓ System configuration exists"
else
    echo "✗ System configuration missing"
fi

echo "Installation testing completed!"