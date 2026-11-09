@echo off
chcp 65001 >nul
setlocal
set "SCRIPT=%~dp0win-init.ps1"

where pwsh.exe >nul 2>&1
if errorlevel 1 (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
) else (
    pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
)
