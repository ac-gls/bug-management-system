@echo off
rem Runs the Bug Management System inside WSL. Arguments pass through, e.g.:
rem   run.bat                      dry run, 1 bug
rem   run.bat --limit 5 --live     create real issues for up to 5 bugs
rem Uses your default WSL distro - set BMS_WSL_DISTRO to pick another (see: wsl -l -v).
setlocal
set "DISTRO_ARGS="
if defined BMS_WSL_DISTRO set "DISTRO_ARGS=-d %BMS_WSL_DISTRO%"
wsl %DISTRO_ARGS% -e bash -lc "cd \"$(wslpath '%~dp0.')\"/.. && ./scripts/run-full-process.sh %*"
pause
