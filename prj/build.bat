@echo off
rem Full implementation of anxin_screen, about 8 minutes.
rem Set TD_HOME to the Tang Dynasty folder, or add its bin folder to PATH. Python 3 is required.
setlocal
cd /d "%~dp0"
if not exist build mkdir build
set "TD_EXE=td_commands_prompt.exe"
if defined TD_HOME set "TD_EXE=%TD_HOME%\bin\td_commands_prompt.exe"
"%TD_EXE%" build_td.tcl > build\console.log 2>&1
python scripts\check_build.py
exit /b %errorlevel%
