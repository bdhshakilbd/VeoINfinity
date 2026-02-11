@echo off
REM Antigravity Auto-Update Restorer
REM This script re-enables automatic updates in VS Code/Antigravity

echo ========================================
echo  Antigravity Auto-Update Restorer
echo ========================================
echo.

set "SETTINGS_DIR=%APPDATA%\Code\User"
set "SETTINGS_FILE=%SETTINGS_DIR%\settings.json"

echo Settings file: %SETTINGS_FILE%
echo.

REM Check if backup exists
for %%f in ("%SETTINGS_FILE%.backup.*") do (
    set "BACKUP_FILE=%%f"
    goto :found_backup
)

echo No backup found. Creating default enabled settings...
goto :create_enabled

:found_backup
echo Backup found: %BACKUP_FILE%
echo.
choice /C YN /M "Restore from backup"
if errorlevel 2 goto :create_enabled
if errorlevel 1 goto :restore_backup

:restore_backup
echo Restoring from backup...
copy "%BACKUP_FILE%" "%SETTINGS_FILE%" >nul
echo Backup restored successfully!
goto :done

:create_enabled
echo Enabling auto-updates...
powershell -Command "$json = if (Test-Path '%SETTINGS_FILE%') { Get-Content '%SETTINGS_FILE%' -Raw | ConvertFrom-Json } else { @{} }; $json | Add-Member -NotePropertyName 'update.mode' -NotePropertyValue 'default' -Force; $json | Add-Member -NotePropertyName 'extensions.autoUpdate' -NotePropertyValue $true -Force; $json | Add-Member -NotePropertyName 'extensions.autoCheckUpdates' -NotePropertyValue $true -Force; $json | ConvertTo-Json -Depth 10 | Set-Content '%SETTINGS_FILE%'"

:done
echo.
echo ========================================
echo  SUCCESS!
echo ========================================
echo.
echo Auto-updates have been re-enabled.
echo.
echo Restart VS Code/Antigravity for changes to take effect.
echo.
pause
