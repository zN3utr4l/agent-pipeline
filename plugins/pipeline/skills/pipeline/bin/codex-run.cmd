@echo off
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0codex-run.ps1" %*
exit /b %ERRORLEVEL%
