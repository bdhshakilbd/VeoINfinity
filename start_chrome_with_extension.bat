@echo off
echo ====================================
echo  Starting Chrome with CDP for Veo3
echo ====================================
echo.

REM Close any existing Chrome instances
taskkill /F /IM chrome.exe 2>nul
timeout /t 2 /nobreak >nul

REM Start Chrome with remote debugging
echo Starting Chrome with debugging enabled...
start "" "C:\Program Files\Google\Chrome\Application\chrome.exe" ^
  --remote-debugging-port=9222 ^
  --user-data-dir="%CD%\Profile 1" ^
  --load-extension="%CD%\flow_extension" ^
  https://labs.google/fx/tools/flow/

echo.
echo Chrome started! Please wait for it to load...
echo Extension should be loaded automatically.
echo.
echo You can now run: python quick_generate_video.py
echo.
pause
