@echo off
setlocal
pushd "%~dp0" 2>nul || cd /d "%~dp0"
title Devvy

rem --- Command line mode (no web page): devvy.bat /cli <Audit|Clean|Search|Update|Profile> [options]. It never asks for elevation: start it from an administrator prompt or task.
if /i "%~1"=="/cli" goto :cli
rem Asking for help (devvy.bat -h, /? or /help) shows the command line help instead of opening the web page
if /i "%~1"=="-h" goto :clihelp
if "%~1"=="/?" goto :clihelp
if /i "%~1"=="/help" goto :clihelp

rem --- Web page: "devvy.bat" alone or "devvy.bat /gui" start it (any other argument than the ones above also ends here)
if /i "%~1"=="/gui" set "DP_GUI=1"

rem --- Self-elevation: if we are not administrators, relaunch with the UAC request ---
net session >nul 2>&1
if %errorlevel% equ 0 goto :admin

echo Requesting administrator rights...
echo If the "User Account Control" window appears, press Yes.
set "DP_BAT=%~f0"
rem A mapped network drive is not visible to the elevated copy (UAC): hand over the real network path instead
for /f "usebackq delims=" %%i in (`powershell -NoProfile -Command "$p=$env:DP_BAT; $d=[IO.Path]::GetPathRoot($p).TrimEnd([char]92); $l=Get-CimInstance Win32_LogicalDisk -Filter ('DeviceID=''' + $d + '''') -ErrorAction SilentlyContinue; if($l -and $l.DriveType -eq 4 -and $l.ProviderName){ $l.ProviderName + $p.Substring($d.Length) } else { $p }"`) do set "DP_BAT=%%i"
set "DP_ARG=%~1"
if "%~1"=="" (
  powershell -NoProfile -Command "Start-Process -FilePath $env:DP_BAT -Verb RunAs"
) else (
  powershell -NoProfile -Command "Start-Process -FilePath $env:DP_BAT -ArgumentList $env:DP_ARG -Verb RunAs"
)
exit /b

:admin
if exist "%~dp0scripts\00-server.ps1" goto :run
echo ERROR: cannot find the scripts folder.
echo WHAT TO DO: extract the WHOLE zip into a folder and start devvy.bat from there.
pause
exit /b 1

:run
set "DP_EXTRA="
if /i "%~1"=="/afterrestart" set "DP_EXTRA=-AfterRestart"
rem The whole block below is read by cmd BEFORE it runs: replacing devvy.bat while the program is open (update, new zip copied over the folder) cannot
rem confuse this window (cmd reads a plain batch file line by line, by file position), so the window always ends with "exit".
(
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\00-server.ps1" %DP_EXTRA%
  if errorlevel 1 (
    echo.
    echo The web interface closed with an error: read the messages above.
    pause
  )
  exit
)

:cli
rem The whole block is read by cmd before it runs, so "Update -Apply" can replace this file safely
(
  rem help needs no administrator rights
  set "DV_NOADMIN="
  if "%~2"=="" set "DV_NOADMIN=1"
  if /i "%~2"=="-h" goto :clihelp
  if "%~2"=="/?" goto :clihelp
  if /i "%~2"=="/help" goto :clihelp
  if not defined DV_NOADMIN (
    net session >nul 2>&1
    if errorlevel 1 (
      echo ERROR: command line mode needs an administrator prompt. 1>&2
      echo Exit code 5: administrator rights needed 1>&2
      exit /b 5
    )
    echo Devvy: starting, please wait... 1>&2
  )
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\devvy-cli.ps1" %*
  exit /b %errorlevel%
)

:clihelp
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\devvy-cli.ps1" /cli /help
exit /b 0
