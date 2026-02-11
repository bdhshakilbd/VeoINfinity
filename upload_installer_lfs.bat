@echo off
echo ========================================
echo Upload Installer to GitHub with Git LFS
echo ========================================
echo.

set INSTALLER_PATH=installer_output\VEO3_Infinity_Setup_3.0.0.exe

REM Check if installer exists
if not exist "%INSTALLER_PATH%" (
    echo ERROR: Installer not found at %INSTALLER_PATH%
    pause
    exit /b 1
)

echo Found installer: %INSTALLER_PATH%
for %%A in ("%INSTALLER_PATH%") do echo Size: %%~zA bytes
echo.

REM Check if Git LFS is installed
git lfs version >nul 2>nul
if %ERRORLEVEL% NEQ 0 (
    echo ERROR: Git LFS is not installed!
    echo Please install from: https://git-lfs.github.com/
    pause
    exit /b 1
)

echo Git LFS is installed
echo.

REM Initialize Git LFS
echo Initializing Git LFS...
git lfs install

REM Track EXE files with LFS
echo Tracking *.exe files with Git LFS...
git lfs track "*.exe"
git lfs track "installer_output/*.exe"

REM Update .gitattributes
echo Updating .gitattributes...
git add .gitattributes

REM Update .gitignore to allow this specific installer
echo Updating .gitignore to allow installer...
if exist .gitignore (
    findstr /C:"# Allow installer output" .gitignore >nul
    if %ERRORLEVEL% NEQ 0 (
        echo. >> .gitignore
        echo # Allow installer output >> .gitignore
        echo !installer_output/*.exe >> .gitignore
    )
)

REM Add the installer
echo.
echo Adding installer to Git LFS...
git add "%INSTALLER_PATH%"
git add .gitignore

REM Check LFS status
echo.
echo Git LFS Status:
git lfs ls-files

REM Commit
echo.
echo Committing...
git commit -m "Add VEO3 Infinity v3.0.0 installer with Git LFS"

if %ERRORLEVEL% NEQ 0 (
    echo.
    echo No changes to commit or commit failed
    pause
    exit /b 1
)

REM Push to GitHub
echo.
echo Pushing to GitHub (this may take a while for large files)...
echo.
git push origin main

if %ERRORLEVEL% EQU 0 (
    echo.
    echo ========================================
    echo Successfully uploaded to GitHub!
    echo ========================================
    echo.
    echo The installer is now available on GitHub with Git LFS.
    echo.
) else (
    echo.
    echo ========================================
    echo Upload failed
    echo ========================================
    echo.
)

pause
