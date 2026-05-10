@echo off
REM baseline.cmd -- shim so `baseline ...` works from cmd.exe + PATH.
REM Forwards all arguments to the PowerShell dispatcher.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0baseline.ps1" %*
