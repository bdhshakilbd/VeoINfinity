@echo off
REM Comprehensive Antigravity Auto-Update Blocker
REM This script disables updates at multiple levels

echo ========================================
echo  Antigravity Update Blocker (Advanced)
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

REM 1. Update settings.json
echo [1/4] Updating settings.json...
set "SETTINGS_FILE=%APPDATA%\Antigravity\User\settings.json"

if exist "%SETTINGS_FILE%" (
    copy "%SETTINGS_FILE%" "%SETTINGS_FILE%.backup" >nul 2>&1
    echo Backup created
)

(
echo {
echo     "update.mode": "none",
echo     "extensions.autoUpdate": false,
echo     "extensions.autoCheckUpdates": false,
echo     "update.enableWindowsBackgroundUpdates": false,
echo     "update.showReleaseNotes": false
echo }
) > "%SETTINGS_FILE%"

echo Settings updated: %SETTINGS_FILE%
echo.

REM 2. Rename/disable the updater executable
echo [2/4] Disabling updater executable...
set "UPDATER=%LOCALAPPDATA%\Programs\Antigravity\tools\inno_updater.exe"

if exist "%UPDATER%" (
    if not exist "%UPDATER%.disabled" (
        move "%UPDATER%" "%UPDATER%.disabled" >nul 2>&1
        echo Updater disabled: inno_updater.exe
    ) else (
        echo Updater already disabled
    )
) else (
    echo Updater not found or already disabled
)
echo.

REM 3. Block updater with Windows Firewall
echo [3/4] Adding firewall rules...

netsh advfirewall firewall delete rule name="Block Antigravity Updater" >nul 2>&1

netsh advfirewall firewall add rule name="Block Antigravity Updater" dir=out action=block program="%LOCALAPPDATA%\Programs\Antigravity\tools\inno_updater.exe" enable=yes >nul 2>&1

if %errorLevel% equ 0 (
    echo Firewall rule added
) else (
    echo Firewall rule failed (may already exist)
)
echo.

REM 4. Create a dummy updater file (read-only)
echo [4/4] Creating dummy updater...

if not exist "%UPDATER%" (
    echo. > "%UPDATER%"
    attrib +r "%UPDATER%" >nul 2>&1
    echo Dummy updater created (read-only)
) else (
    echo Updater file exists
)
echo.

echo ========================================
echo  SUCCESS!
echo ========================================
echo.
echo Auto-updates have been blocked at multiple levels:
echo   [x] Settings configured
echo   [x] Updater executable disabled
echo   [x] Firewall rule added
echo   [x] Dummy updater created
echo.
echo Restart Antigravity for changes to take effect.
echo.
echo To restore updates, run: antigravity_update_restore.bat
echo.
pause
