@echo off
echo ========================================
echo Removing EXE from GitHub Repository
echo ========================================
echo.

REM Remove the EXE file from Git tracking
echo Removing installer from Git...
git rm --cached "Output\VEO3_Infinity_Setup.exe"

REM Also remove from Git LFS
echo Removing from Git LFS...
git lfs untrack "*.exe"

REM Update .gitignore to prevent future uploads
echo Updating .gitignore...
echo # Exclude all EXE files >> .gitignore
echo *.exe >> .gitignore
echo Output/*.exe >> .gitignore

REM Commit the changes
echo.
echo Committing changes...
git add .gitignore .gitattributes
git commit -m "Remove installer EXE from repository"

REM Push to GitHub
echo.
echo Pushing to GitHub...
git push origin main

echo.
echo ========================================
echo Done! EXE file removed from GitHub
echo ========================================
echo.
echo Note: The file is removed from tracking but may still
echo exist in Git history. To completely remove it from
echo history, you would need to use git filter-branch or
echo BFG Repo-Cleaner (more complex operation).
echo.
pause
