@echo off
rem Control script for the Antigravity Masking Sidecar on Windows.
rem
rem install.ps1 copies this to %USERPROFILE%\.omp\sidecar\sidecar.cmd and
rem substitutes the two placeholders below.
rem
rem   sidecar.cmd start    start the sidecar if the health probe fails
rem   sidecar.cmd stop     kill whatever is listening on the sidecar port
rem   sidecar.cmd status   print the health payload
rem
rem Placeholders substituted by install.ps1:
rem   __BUN__    -> absolute path to bun.exe
rem   __SCRIPT__ -> absolute path to antigravity-masking-proxy.ts

setlocal
set BUN=__BUN__
set SCRIPT=__SCRIPT__
set HEALTH=http://127.0.0.1:45123/health

if "%~1"=="" goto :status
if /I "%~1"=="start"  goto :start
if /I "%~1"=="stop"   goto :stop
if /I "%~1"=="status" goto :status
echo Usage: sidecar.cmd [start^|stop^|status]
exit /b 1

:start
curl -s -m 2 %HEALTH% >nul 2>&1 && (echo already running & exit /b 0)
start "ag-sidecar" /min "%BUN%" "%SCRIPT%"
echo started
exit /b 0

:stop
for /f "tokens=5" %%p in ('netstat -ano ^| findstr ":45123" ^| findstr LISTENING') do taskkill /F /PID %%p >nul 2>&1
echo stopped
exit /b 0

:status
curl -s -m 3 %HEALTH%
echo.
exit /b 0
