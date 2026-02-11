@echo off
REM Restore Antigravity Auto-Updates
REM This script re-enables updates

echo ========================================
echo  Antigravity Update Restorer
echo ========================================
echo.

REM Check for admin rights
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo This script requires administrator privileges.
    echo Please run as Administrator.
    pause
    exit /b 1
)

echo Running with administrator privileges...
echo.

REM 1. Restore settings.json
echo [1/4] Restoring settings.json...
set "SETTINGS_FILE=%APPDATA%\Antigravity\User\settings.json"

if exist "%SETTINGS_FILE%.backup" (
    copy "%SETTINGS_FILE%.backup" "%SETTINGS_FILE%" >nul 2>&1
    echo Settings restored from backup
) else (
    (
    echo {
    echo     "update.mode": "default",
    echo     "extensions.autoUpdate": true,
    echo     "extensions.autoCheckUpdates": true
    echo }
    ) > "%SETTINGS_FILE%"
    echo Default update settings applied
)
echo.

REM 2. Restore updater executable
echo [2/4] Restoring updater executable...
set "UPDATER=%LOCALAPPDATA%\Programs\Antigravity\tools\inno_updater.exe"

if exist "%UPDATER%.disabled" (
    REM Remove dummy if exists
    if exist "%UPDATER%" (
        attrib -r "%UPDATER%" >nul 2>&1
        del "%UPDATER%" >nul 2>&1
    )
    
    move "%UPDATER%.disabled" "%UPDATER%" >nul 2>&1
    echo Updater restored: inno_updater.exe
) else (
    echo Updater already active or not found
)
echo.

REM 3. Remove firewall rule
echo [3/4] Removing firewall rules...

netsh advfirewall firewall delete rule name="Block Antigravity Updater" >nul 2>&1

if %errorLevel% equ 0 (
    echo Firewall rule removed
) else (
    echo No firewall rule found
)
echo.

REM 4. Remove read-only attribute if exists
echo [4/4] Cleaning up...

if exist "%UPDATER%" (
    attrib -r "%UPDATER%" >nul 2>&1
    echo File attributes reset
)
echo.

echo ========================================
echo  SUCCESS!
echo ========================================
echo.
echo Auto-updates have been re-enabled:
echo   [x] Settings restored
echo   [x] Updater executable restored
echo   [x] Firewall rule removed
echo   [x] File protection removed
echo.
echo Restart Antigravity for changes to take effect.
echo.
pause
