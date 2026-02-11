@echo off
REM Antigravity Auto-Update Disabler
REM This script disables automatic updates in VS Code/Antigravity

echo ========================================
echo  Antigravity Auto-Update Disabler
echo ========================================
echo.

REM Find VS Code settings file location
set "SETTINGS_DIR=%APPDATA%\Code\User"
set "SETTINGS_FILE=%SETTINGS_DIR%\settings.json"

REM Check if settings directory exists
if not exist "%SETTINGS_DIR%" (
    echo Creating settings directory...
    mkdir "%SETTINGS_DIR%"
)

echo Settings file: %SETTINGS_FILE%
echo.

REM Backup existing settings
if exist "%SETTINGS_FILE%" (
    echo Backing up existing settings...
    copy "%SETTINGS_FILE%" "%SETTINGS_FILE%.backup.%date:~-4,4%%date:~-10,2%%date:~-7,2%_%time:~0,2%%time:~3,2%%time:~6,2%" >nul 2>&1
    echo Backup created: %SETTINGS_FILE%.backup.*
    echo.
)

REM Create or update settings
echo Applying auto-update disable settings...

REM Check if file exists and has content
if exist "%SETTINGS_FILE%" (
    REM File exists, we need to merge settings
    echo Existing settings found, updating...
    
    REM Use PowerShell to merge JSON
    powershell -Command "$json = if (Test-Path '%SETTINGS_FILE%') { Get-Content '%SETTINGS_FILE%' -Raw | ConvertFrom-Json } else { @{} }; $json | Add-Member -NotePropertyName 'update.mode' -NotePropertyValue 'none' -Force; $json | Add-Member -NotePropertyName 'extensions.autoUpdate' -NotePropertyValue $false -Force; $json | Add-Member -NotePropertyName 'extensions.autoCheckUpdates' -NotePropertyValue $false -Force; $json | ConvertTo-Json -Depth 10 | Set-Content '%SETTINGS_FILE%'"
) else (
    REM Create new settings file
    echo Creating new settings file...
    (
        echo {
        echo     "update.mode": "none",
        echo     "extensions.autoUpdate": false,
        echo     "extensions.autoCheckUpdates": false
        echo }
    ) > "%SETTINGS_FILE%"
)

echo.
echo ========================================
echo  SUCCESS!
echo ========================================
echo.
echo Auto-updates have been disabled.
echo.
echo Settings applied:
echo   - update.mode: none
echo   - extensions.autoUpdate: false
echo   - extensions.autoCheckUpdates: false
echo.
echo Restart VS Code/Antigravity for changes to take effect.
echo.
echo To re-enable auto-updates, run: disable_autoupdate_restore.bat
echo.
pause
