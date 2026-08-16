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

## Directory Structure

- `scripts/`: All automation scripts
- `configs/`: Configuration files
- `docs/`: Documentation
- `logs/`: Log files
- `temp/`: Temporary files
- `win-scripts/`: Windows batch scripts

## Prerequisites

- Ubuntu 20.04 or later (WSL2 for Windows users)
- Internet connection
- GitHub account with personal access token
- Azure DevOps account with personal access token

## System Requirements

- Minimum 8GB RAM
- 20GB free disk space
- Administrator privileges for initial setup