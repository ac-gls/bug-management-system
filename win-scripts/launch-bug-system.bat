@echo off
echo Launching Bug Management System...
wsl -d Ubuntu -e bash -c "cd ~/bug-management-system && ./scripts/run-full-process.sh"
pause