@echo off
echo Setting up Bug Management System...
wsl -d Ubuntu -e bash -c "cd ~/bug-management-system && ./scripts/install-dependencies.sh"
pause