@echo off
echo ========================================
echo GitHub LFS Upload - VEO3 Infinity v3.0.0
echo ========================================
echo.

:: Check if Git is installed
git --version >nul 2>&1
if errorlevel 1 (
    echo ✗ Git is not installed!
    echo Please install Git from: https://git-scm.com/download/win
    pause
    exit /b 1
)

:: Check if Git LFS is installed
git lfs version >nul 2>&1
if errorlevel 1 (
    echo ✗ Git LFS is not installed!
    echo Please install Git LFS from: https://git-lfs.github.com/
    echo.
    echo After installing, run: git lfs install
    pause
    exit /b 1
)

echo ✓ Git and Git LFS are installed
echo.

:: Check if the EXE file exists
if not exist "installer_output\VEO3_Infinity_Setup_3.0.0.exe" (
    echo ✗ Installer file not found!
    echo Expected: installer_output\VEO3_Infinity_Setup_3.0.0.exe
    echo.
    echo Please build the installer first using Inno Setup.
    pause
    exit /b 1
)

echo ✓ Installer file found
echo.

:: Initialize Git LFS (if not already done)
echo Step 1: Initializing Git LFS...
git lfs install
echo.

:: Track .exe files with LFS
echo Step 2: Configuring LFS to track .exe files...
git lfs track "*.exe"
echo.

:: Add .gitattributes if it was created/modified
if exist ".gitattributes" (
    echo Step 3: Adding .gitattributes...
    git add .gitattributes
    echo.
)

:: Add the installer file
echo Step 4: Adding installer file to Git LFS...
git add installer_output/VEO3_Infinity_Setup_3.0.0.exe
echo.

:: Check LFS status
echo Step 5: Verifying LFS tracking...
git lfs ls-files
echo.

:: Commit the changes
echo Step 6: Committing changes...
git commit -m "Release v3.0.0 - Add installer with Git LFS

Features:
- Persistent state management (projects, images, videos)
- Retry failed video generations
- First + Last frame mode for video generation
- Improved 403 error handling with token refresh
- Fixed asset loading for EXE builds
- Account validation with helpful error messages
- WebView2 user data folder fix for permissions
- Installation to LocalAppData (no admin required)

File: VEO3_Infinity_Setup_3.0.0.exe (tracked with Git LFS)"
echo.

:: Push to GitHub
echo Step 7: Pushing to GitHub...
echo.
echo ⚠️  IMPORTANT: Make sure you have set up your GitHub remote!
echo    If not, run: git remote add origin https://github.com/YOUR_USERNAME/YOUR_REPO.git
echo.
set /p CONFIRM="Ready to push to GitHub? (Y/N): "
if /i "%CONFIRM%" NEQ "Y" (
    echo.
    echo ✓ Changes committed locally but not pushed.
    echo   Run 'git push origin main' when ready.
    pause
    exit /b 0
)

git push origin main
echo.

if errorlevel 1 (
    echo.
    echo ✗ Push failed!
    echo.
    echo Common issues:
    echo 1. Remote not configured: git remote add origin https://github.com/USERNAME/REPO.git
    echo 2. Authentication failed: Use GitHub Personal Access Token
    echo 3. Branch name: Try 'git push origin master' instead of 'main'
    echo.
    echo Your changes are committed locally. Fix the issue and run:
    echo   git push origin main
    pause
    exit /b 1
)

echo.
echo ========================================
echo ✓ Successfully uploaded to GitHub!
echo ========================================
echo.
echo The installer is now available on GitHub with Git LFS.
echo File size will be optimized and won't bloat your repository.
echo.
pause
