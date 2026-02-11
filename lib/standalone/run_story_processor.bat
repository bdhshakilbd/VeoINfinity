@echo off
echo ========================================
echo Starting Story Prompt Processor
echo ========================================
echo.

REM Navigate to project root (two levels up from lib\standalone)
cd /d "%~dp0"
cd ..\..

echo Current directory: %CD%
echo.

flutter run -d windows -t lib\standalone\story_prompt_processor.dart

pause
