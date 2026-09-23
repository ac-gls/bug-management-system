@echo off
rem Installs the Bug Management System inside WSL, from wherever this repo is cloned.
rem Uses your default WSL distro - set BMS_WSL_DISTRO to pick another (see: wsl -l -v).
setlocal
set "DISTRO_ARGS="
if defined BMS_WSL_DISTRO set "DISTRO_ARGS=-d %BMS_WSL_DISTRO%"
wsl %DISTRO_ARGS% -e bash -lc "cd \"$(wslpath '%~dp0.')\"/.. && ./install.sh %*"
pause
