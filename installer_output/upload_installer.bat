@echo off
setlocal enabledelayedexpansion

:: Define the target folder
set "TARGET_DIR=G:\dyad-apps\veo3 10 march\veo3_another\installer_output"
cd /d "%TARGET_DIR%"

set "INPUT_FILE=%~1"

:: If no file was provided as an argument, look for the newest VEO3_Infinity_Setup_*.exe in the root installer_output directory
if "%INPUT_FILE%"=="" (
    echo No file specified. Searching for the latest installer in %TARGET_DIR%...
    set "LATEST_FILE="
    for /f "delims=" %%I in ('dir /b /a-d /o-d VEO3_Infinity_Setup_*.exe 2^>nul') do (
        if not defined LATEST_FILE (
            set "LATEST_FILE=%%I"
        )
    )
    if not "!LATEST_FILE!"=="" (
        set "INPUT_FILE=!LATEST_FILE!"
        echo Found latest installer: !INPUT_FILE!
    ) else (
        echo [ERROR] No VEO3_Infinity_Setup_*.exe found in %TARGET_DIR%.
        echo Please drag and drop the setup file onto this script or pass it as an argument.
        pause
        exit /b 1
    )
)

:: Get full path and filename of the input file
for %%I in ("%INPUT_FILE%") do (
    set "FULL_PATH=%%~fI"
    set "FILE_NAME_ONLY=%%~nxI"
    set "FILE_DIR=%%~dpI"
)

:: Check if file exists
if not exist "%FULL_PATH%" (
    echo [ERROR] File does not exist: %FULL_PATH%
    pause
    exit /b 1
)

echo.
echo ==================================================
echo Preparing Installer for GitHub Upload
echo File: %FILE_NAME_ONLY%
echo Path: %FULL_PATH%
echo ==================================================
echo.

:: Now the active installer is guaranteed to be in installer_output
set "FINAL_REL_PATH=%FILE_NAME_ONLY%"

echo.
echo ==================================================
echo [1/3] Staging files in git...
:: Stage the new installer directly
git add "%FILE_NAME_ONLY%"
if %ERRORLEVEL% neq 0 (
    echo [ERROR] Failed to stage files in git.
    pause
    exit /b 1
)

echo [2/3] Committing files...
git commit -m "chore: upload installer %FINAL_REL_PATH%"
if %ERRORLEVEL% neq 0 (
    echo [INFO] No new changes to commit. Maybe already committed.
)

echo [3/3] Pushing to GitHub...
git push
if %ERRORLEVEL% neq 0 (
    echo [ERROR] Failed to push to remote repository.
    pause
    exit /b 1
)

echo.
echo ==================================================
echo [SUCCESS] Installer uploaded successfully!
echo ==================================================
pause
