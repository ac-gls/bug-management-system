#!/bin/bash
# Check system status and dependencies

echo "Checking system status..."

# Check if required tools are installed
echo "Checking GitHub CLI..."
gh --version

echo "Checking Azure CLI..."
az --version

echo "Checking Node.js..."
node --version

echo "Checking Python..."
python3 --version

echo "System status check completed!"