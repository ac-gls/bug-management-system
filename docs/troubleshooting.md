# Troubleshooting Guide

## Common Issues

### Authentication Errors
- Verify credentials in configs/credentials.conf
- Ensure tokens have proper permissions
- Check that tokens haven't expired

### Dependency Issues
- Run scripts/install-dependencies.sh to reinstall
- Check internet connectivity
- Verify sudo privileges

### WSL Issues
- Ensure WSL2 is properly installed
- Restart WSL: wsl --shutdown
- Check Ubuntu distribution: wsl -l -v

### GitHub CLI Issues
- Re-authenticate: gh auth login
- Check token permissions
- Verify repository access

### Azure DevOps Issues
- Verify personal access token
- Check organization and project names
- Confirm API access permissions

## Debugging Steps

1. Run scripts/status-check.sh to diagnose system status
2. Check logs in the logs/ directory
3. Verify configuration files in configs/
4. Re-run installation script if needed

## Log Files

Check the following log files for detailed error information:
- Installation logs in logs/install.log
- Runtime logs in logs/runtime.log
- Error logs in logs/error.log

## Support

If you continue to experience issues:
1. Check the GitHub repository issues
2. Review the documentation
3. Contact the maintainers