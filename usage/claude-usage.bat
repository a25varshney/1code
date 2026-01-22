@echo off
setlocal enabledelayedexpansion

set "HTML_FILE=D:\UbuntuContainer\codebase\1code\usage\claude-usage.html"

echo.
echo ============================================================
echo           Generating Claude Usage Dashboard...
echo ============================================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "D:\UbuntuContainer\codebase\1code\usage\generate-usage.ps1"

echo.
echo Opening dashboard...
start "" "%HTML_FILE%"