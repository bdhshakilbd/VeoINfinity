@echo off
setlocal

echo ========================================
echo Auto-Detecting Android Device...
echo ========================================

:: Use PowerShell to parse JSON output from 'flutter devices --machine' and extract the ID of the first Android device
for /f "delims=" %%i in ('flutter devices --machine ^| powershell -NoProfile -Command "$json = $input | Out-String | ConvertFrom-Json; $dev = $json | Where-Object { $_.targetPlatform -like 'android*' }; if ($dev) { if ($dev -is [array]) { $dev[0].id } else { $dev.id } }"') do set DEVICE_ID=%%i

if "%DEVICE_ID%"=="" (
    echo [ERROR] No Android device found!
    echo 1. Connect your Android phone via USB.
    echo 2. Enable Developer Options & USB Debugging on the phone.
    echo 3. Run this script again.
    pause
    exit /b 1
)

echo [SUCCESS] Found Android Device ID: %DEVICE_ID%
echo.
echo Starting App on Android...
echo (This may take a few minutes for the first build)
echo ========================================

flutter run -d %DEVICE_ID%

pause
