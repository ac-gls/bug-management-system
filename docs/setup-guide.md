# Bug Management System Installation and Configuration Plan

## Overview
This plan provides a complete guide for installing and configuring the entire bug management system on any Windows computer. The system will be set up in a separate Git repository with all necessary tools, configurations, and automation scripts.

## Prerequisites
- Windows 10 or Windows 11 computer
- Administrator privileges
- Internet connection
- Minimum 8GB RAM, 20GB free disk space

## Phase 1: Environment Setup

### Step 1: Install WSL2 with Ubuntu
```powershell
# Open PowerShell as Administrator and run:
wsl --install -d Ubuntu

# Restart computer when prompted
# Complete Ubuntu setup (set username and password)
```

### Step 2: Update Ubuntu and Install Base Tools
```bash
# In Ubuntu terminal:
sudo apt update && sudo apt upgrade -y
sudo apt install -y git curl wget jq unzip build-essential
```

### Step 3: Install Node.js and npm
```bash
# In Ubuntu terminal:
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt-get install -y nodejs
```

### Step 4: Install Python and pip
```bash
# In Ubuntu terminal:
sudo apt install -y python3 python3-pip
```

## Phase 2: Git Repository Setup

### Step 5: Create Bug Management Repository
```bash
# In Ubuntu terminal:
mkdir -p ~/projects
cd ~/projects
git init bug-management-system
cd bug-management-system
```

### Step 6: Set Up Repository Structure
```bash
# In Ubuntu terminal:
mkdir -p scripts configs docs logs temp
touch README.md .gitignore
```

### Step 7: Create Initial README.md
```markdown
# Bug Management System

This repository contains all scripts and configurations for the automated bug management system that integrates Azure DevOps and GitHub.

## Features
- Automated bug migration from ADO to GitHub
- Parallel bug fixing with Herdr
- TDD implementation with Playwright testing
- Dual-system status synchronization
- Comprehensive reporting and traceability

## Directories
- `scripts/` - All automation scripts
- `configs/` - Configuration files
- `docs/` - Documentation
- `logs/` - Log files
- `temp/` - Temporary files
```

## Phase 3: Tool Installation

### Step 8: Install GitHub CLI
```bash
# In Ubuntu terminal:
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
sudo apt update
sudo apt install gh
```

### Step 9: Install Azure CLI
```bash
# In Ubuntu terminal:
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
```

### Step 10: Install Herdr
```bash
# In Ubuntu terminal:
# (Assuming Herdr is available via package manager or needs to be built from source)
# Check if Herdr is available in repositories
sudo apt search herdr

# If not available, follow Herdr installation instructions from official documentation
# This may involve downloading binaries or building from source
```

### Step 11: Install Playwright
```bash
# In Ubuntu terminal:
npm init playwright@latest
```

### Step 12: Install Additional Utilities
```bash
# In Ubuntu terminal:
sudo apt install -y tmux htop tree silversearcher-ag
```

## Phase 4: Configuration Setup

### Step 13: Configure GitHub CLI
```bash
# In Ubuntu terminal:
gh auth login
# Follow prompts to authenticate with GitHub
```

### Step 14: Configure Azure CLI
```bash
# In Ubuntu terminal:
az login
# Follow prompts to authenticate with Azure
```

### Step 15: Create Configuration Files

#### Create configs/system.conf:
```bash
# System configuration
WORKSPACE_ROOT="$HOME/projects/bug-management-system"
LOG_DIR="$WORKSPACE_ROOT/logs"
TEMP_DIR="$WORKSPACE_ROOT/temp"
SCRIPTS_DIR="$WORKSPACE_ROOT/scripts"
CONFIGS_DIR="$WORKSPACE_ROOT/configs"

# GitHub settings
GITHUB_ORG="your-organization"
GITHUB_REPO="your-repo"

# Azure DevOps settings
ADO_ORG="your-ado-organization"
ADO_PROJECT="your-ado-project"

# Migration settings
MIGRATION_TAG="MigrateToGitHub"
READY_FOR_AGENT_TAG="ready-for-agent"
```

#### Create configs/credentials.conf:
```bash
# Credential placeholders (should be secured)
# This file should be added to .gitignore
GITHUB_TOKEN=""
ADO_PAT=""
```

## Phase 5: Script Implementation

### Step 16: Create Core Scripts

#### Create scripts/install-dependencies.sh:
```bash
#!/bin/bash
# Install all required dependencies

echo "Installing system dependencies..."
sudo apt update
sudo apt install -y git curl wget jq unzip build-essential

echo "Installing Node.js..."
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt-get install -y nodejs

echo "Installing Python..."
sudo apt install -y python3 python3-pip

echo "Installing GitHub CLI..."
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
sudo apt update
sudo apt install gh

echo "Installing Azure CLI..."
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

echo "Installing additional utilities..."
sudo apt install -y tmux htop tree silversearcher-ag

echo "Installing Playwright..."
npm init playwright@latest

echo "Dependencies installed successfully!"
```

#### Create scripts/setup-herdr.sh:
```bash
#!/bin/bash
# Setup Herdr terminal workspace manager

echo "Setting up Herdr..."
# Add Herdr installation steps here
# This will depend on how Herdr is distributed

echo "Herdr setup completed!"
```

#### Create scripts/authenticate.sh:
```bash
#!/bin/bash
# Authenticate with required services

source "$HOME/projects/bug-management-system/configs/system.conf"
source "$HOME/projects/bug-management-system/configs/credentials.conf"

echo "Authenticating with GitHub..."
echo "$GITHUB_TOKEN" | gh auth login --with-token

echo "Authenticating with Azure DevOps..."
echo "$ADO_PAT" | az devops login

echo "Authentication completed!"
```

### Step 17: Create Migration Scripts

#### Create scripts/get-ado-bugs.sh:
```bash
#!/bin/bash
# Script from the previous migration plan

source "$HOME/projects/bug-management-system/configs/system.conf"
source "$HOME/projects/bug-management-system/configs/credentials.conf"

ORGANIZATION=${1:-$ADO_ORG}
PROJECT=${2:-$ADO_PROJECT}
MIGRATION_TAG=${3:-$MIGRATION_TAG}

# Implementation from previous plan...
```

### Step 18: Create Fixing Scripts

#### Create scripts/start-bug-fixing.sh:
```bash
#!/bin/bash
# Script from the previous bug fixing plan

source "$HOME/projects/bug-management-system/configs/system.conf"
source "$HOME/projects/bug-management-system/configs/credentials.conf"

STATUS_LABEL=${1:-$READY_FOR_AGENT_TAG}

# Implementation from previous plan...
```

## Phase 6: System Integration

### Step 19: Create Main Orchestration Script

#### Create scripts/run-full-process.sh:
```bash
#!/bin/bash
# Main orchestration script

source "$HOME/projects/bug-management-system/configs/system.conf"
source "$HOME/projects/bug-management-system/configs/credentials.conf"

echo "Starting Bug Management System..."

# Phase 1: Migration
echo "Phase 1: Bug Migration"
./scripts/get-ado-bugs.sh

# Phase 2: Fixing
echo "Phase 2: Bug Fixing"
./scripts/start-bug-fixing.sh

echo "Bug Management System process completed!"
```

### Step 20: Create Utility Scripts

#### Create scripts/status-check.sh:
```bash
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
```

## Phase 7: Windows Integration

### Step 21: Create Windows Launcher

#### Create win-scripts/launch-bug-system.bat:
```batch
@echo off
echo Launching Bug Management System...
wsl -d Ubuntu -e bash -c "cd ~/projects/bug-management-system && ./scripts/run-full-process.sh"
pause
```

#### Create win-scripts/setup-bug-system.bat:
```batch
@echo off
echo Setting up Bug Management System...
wsl -d Ubuntu -e bash -c "cd ~/projects/bug-management-system && ./scripts/install-dependencies.sh"
pause
```

## Phase 8: Documentation

### Step 22: Create User Guide

#### Create docs/user-guide.md:
```markdown
# Bug Management System User Guide

## Getting Started

1. Run the setup script
2. Configure credentials
3. Run the main process

## Configuration

Edit configs/credentials.conf with your tokens:
- GITHUB_TOKEN: Personal access token for GitHub
- ADO_PAT: Personal access token for Azure DevOps

## Running the System

Execute the main script:
./scripts/run-full-process.sh
```

### Step 23: Create Troubleshooting Guide

#### Create docs/troubleshooting.md:
```markdown
# Troubleshooting Guide

## Common Issues

### Authentication Errors
- Verify credentials in configs/credentials.conf
- Ensure tokens have proper permissions

### Dependency Issues
- Run scripts/install-dependencies.sh to reinstall
- Check internet connectivity

### WSL Issues
- Ensure WSL2 is properly installed
- Restart WSL: wsl --shutdown
```

## Phase 9: Security and Backup

### Step 24: Secure Configuration Files

#### Update .gitignore:
```gitignore
# Configuration files with credentials
configs/credentials.conf

# Log files
logs/

# Temporary files
temp/

# IDE files
.vscode/
.idea/

# OS generated files
.DS_Store
.DS_Store?
._*
.Spotlight-V100
.Trashes
ehthumbs.db
Thumbs.db
```

### Step 25: Create Backup Script

#### Create scripts/backup-config.sh:
```bash
#!/bin/bash
# Backup configuration files

BACKUP_DIR="$HOME/projects/bug-management-system/backups"
DATE=$(date +%Y%m%d_%H%M%S)

mkdir -p "$BACKUP_DIR"

# Backup configuration files
cp -r "$HOME/projects/bug-management-system/configs" "$BACKUP_DIR/configs_$DATE"

echo "Configuration backed up to $BACKUP_DIR/configs_$DATE"
```

## Phase 10: Testing and Validation

### Step 26: Create Test Scripts

#### Create scripts/test-installation.sh:
```bash
#!/bin/bash
# Test installation and configuration

echo "Testing Bug Management System Installation..."

# Test 1: Check directory structure
echo "Test 1: Directory structure"
if [ -d "$HOME/projects/bug-management-system/scripts" ] && 
   [ -d "$HOME/projects/bug-management-system/configs" ] &&
   [ -d "$HOME/projects/bug-management-system/docs" ]; then
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
if [ -f "$HOME/projects/bug-management-system/configs/system.conf" ]; then
    echo "✓ System configuration exists"
else
    echo "✗ System configuration missing"
fi

echo "Installation testing completed!"
```

## Phase 11: Final Setup

### Step 27: Initialize Git Repository
```bash
# In Ubuntu terminal:
cd ~/projects/bug-management-system
git add .
git commit -m "Initial commit: Bug Management System setup"
```

### Step 28: Create Remote Repository
```bash
# In Ubuntu terminal:
gh repo create bug-management-system --public --clone
# Or if you want to push to existing repository:
# git remote add origin <repository-url>
# git push -u origin main
```

### Step 29: Final Validation
```bash
# In Ubuntu terminal:
./scripts/test-installation.sh
```

## Usage Instructions

### For Developers
1. Clone the repository
2. Run setup script: `./scripts/install-dependencies.sh`
3. Configure credentials in `configs/credentials.conf`
4. Run the system: `./scripts/run-full-process.sh`

### For Windows Users
1. Double-click `win-scripts/setup-bug-system.bat` to install
2. Edit `configs/credentials.conf` with your tokens
3. Double-click `win-scripts/launch-bug-system.bat` to run

## Maintenance

### Regular Tasks
- Run `./scripts/backup-config.sh` weekly
- Check for tool updates monthly
- Review logs in `logs/` directory

### Updating the System
```bash
cd ~/projects/bug-management-system
git pull origin main
./scripts/install-dependencies.sh
```

## Troubleshooting

If you encounter issues:
1. Run `./scripts/status-check.sh` to diagnose
2. Check `docs/troubleshooting.md` for solutions
3. Review logs in `logs/` directory
4. Re-run installation script if needed

This complete setup provides a robust, automated bug management system that integrates Azure DevOps and GitHub with proper status management and duplicate prevention.