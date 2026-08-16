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
- `win-scripts/` - Windows batch scripts

## Prerequisites
- Windows 10/11 with WSL2 (for Windows users)
- Ubuntu 20.04 or later (for Linux users)
- Internet connection
- GitHub account with personal access token
- Azure DevOps account with personal access token

## Installation

### For Linux Users
```bash
# Clone the repository
git clone https://github.com/your-username/bug-management-system.git
cd bug-management-system

# Run the setup script
./scripts/install-dependencies.sh

# Configure credentials
cp configs/credentials.conf.example configs/credentials.conf
# Edit configs/credentials.conf with your tokens
```

### For Windows Users
```powershell
# Clone the repository
git clone https://github.com/your-username/bug-management-system.git
cd bug-management-system

# Run the setup script via WSL
wsl -d Ubuntu -e bash -c "cd $(pwd) && ./scripts/install-dependencies.sh"

# Configure credentials
cp configs/credentials.conf.example configs/credentials.conf
# Edit configs/credentials.conf with your tokens
```

## Configuration

Edit `configs/credentials.conf` with your personal access tokens:
- `GITHUB_TOKEN`: Personal access token for GitHub
- `ADO_PAT`: Personal access token for Azure DevOps

## Usage

### Run the Full Process
```bash
./scripts/run-full-process.sh
```

### Run Individual Components
```bash
# Migrate bugs from ADO to GitHub
./scripts/get-ado-bugs.sh

# Fix bugs with TDD methodology
./scripts/start-bug-fixing.sh
```

### Windows Users
Double-click the batch files in the `win-scripts` directory:
- `setup-bug-system.bat`: Install dependencies
- `launch-bug-system.bat`: Run the full process

## Documentation
- [User Guide](docs/user-guide.md)
- [Troubleshooting Guide](docs/troubleshooting.md)
- [Migration Process](docs/migration-process.md)
- [Bug Fixing Process](docs/bug-fixing-process.md)

## Contributing
1. Fork the repository
2. Create a feature branch
3. Commit your changes
4. Push to the branch
5. Create a pull request

## License
This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.