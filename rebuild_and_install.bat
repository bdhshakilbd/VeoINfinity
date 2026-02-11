@echo off
echo ========================================
echo VEO3 Infinity - Complete Rebuild Guide
echo ========================================
echo.

echo Step 1: Uninstall old version
echo ------------------------------
echo 1. Go to Settings ^> Apps ^> Installed Apps
echo 2. Find "VEO3 Infinity" and click Uninstall
echo 3. When asked about deleting data, choose NO (to keep your projects)
echo.
pause

echo.
echo Step 2: Clean build folders
echo ----------------------------
rmdir /s /q build 2>nul
echo ✓ Cleaned build folder
echo.

echo Step 3: Rebuild Flutter app
echo ----------------------------
flutter clean
flutter pub get
flutter build windows --release
echo.

if not exist "build\windows\x64\runner\Release\veo3_another.exe" (
    echo ✗ Build failed! Check errors above.
    pause
    exit /b 1
)

echo ✓ Build successful!
echo.

echo Step 4: Compile Inno Setup installer
echo -------------------------------------
echo 1. Open "setup.iss" in Inno Setup Compiler
echo 2. Press F9 or click "Compile"
echo 3. Installer will be created in: installer_output\VEO3_Infinity_Setup_3.0.0.exe
echo.
echo OR run this command:
echo "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" setup.iss
echo.

echo Step 5: Install new version
echo ---------------------------
echo 1. Run: installer_output\VEO3_Infinity_Setup_3.0.0.exe
echo 2. Install to: C:\Users\%USERNAME%\AppData\Local\VEO3 Infinity
echo 3. No admin prompt should appear!
echo.

echo ========================================
echo WebView2 Data will be stored in:
echo %LOCALAPPDATA%\VEO3_Infinity\WebView2Data
echo ========================================
echo.

pause
