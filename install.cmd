@echo off
setlocal DisableDelayedExpansion
rem Usage: install.cmd [-Help] [-Launch] [-StorageRoot "path"] [-NoShortcuts] [-KeepOldVersions]
if not "%~1"=="" goto commandline
"%SystemRoot%\System32\wscript.exe" "%~dp0Start-ChatGPT.vbs"
exit /b %errorlevel%
:commandline
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File "%~dp0src\Install-ChatGPTPortable.ps1" %*
exit /b %errorlevel%
