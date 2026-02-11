@echo off
echo Downloading Microsoft Edge WebView2 Runtime...
echo.

:: Download WebView2 Runtime Bootstrapper
powershell -Command "& {Invoke-WebRequest -Uri 'https://go.microsoft.com/fwlink/p/?LinkId=2124703' -OutFile 'MicrosoftEdgeWebview2Setup.exe'}"

if exist "MicrosoftEdgeWebview2Setup.exe" (
    echo.
    echo ✓ WebView2 Runtime installer downloaded successfully!
    echo File: MicrosoftEdgeWebview2Setup.exe
    echo.
    echo This file will be bundled with your installer.
) else (
    echo.
    echo ✗ Download failed!
    echo Please download manually from: https://go.microsoft.com/fwlink/p/?LinkId=2124703
)

pause
