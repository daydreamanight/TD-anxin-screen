@echo off
rem Runs all retained testbenches with ModelSim. Put vlib, vlog and vsim on PATH first.
rem The BMP scaling test takes about 4 minutes; the others take seconds.
setlocal
cd /d "%~dp0"
set FAILED=0
if exist work_dir rmdir /s /q work_dir
mkdir work_dir\unit
mkdir work_dir\top

cd work_dir\unit
vlib work > vlib.log 2>&1
vsim -c -do "do ../../compile_unit.do; quit -f" > compile.log 2>&1
findstr /c:"Errors: 0" compile.log > nul || (echo COMPILE FAILED, see sim_do\work_dir\unit\compile.log & exit /b 1)
call :run tb_ui_keys "PASS tb_ui_keys"
call :run tb_prev_key "PASS tb_prev_key"
call :run tb_video_timing "PASS tb_video_timing"
call :run tb_fade_rgb "PASS tb_fade_rgb"
call :run tb_map_overlay "PASS tb_map_overlay"
call :run tb_emergency_control "PASS tb_emergency_control"
call :run tb_maintenance "PASS tb_maintenance"
call :run tb_navigation "PASS tb_navigation"
call :run tb_osd_public_maintenance "PASS tb_osd_public_maintenance"
call :run tb_screen_cfg "PASS tb_screen_cfg"
call :run tb_scene_audio "PASS tb_scene_audio"
call :run tb_audio_waveform "PASS tb_audio_waveform"
call :run tb_anxin_framebuffer "PASS:"
call :run tb_uart_status "PASS tb_uart_status"
call :run tb_mount_control "PASS tb_mount_control"
call :run tb_anxin_bmp_scaling "BMP_SCALING_SELF_CHECK_PASS"

cd ..\top
vlib work > vlib.log 2>&1
vsim -c -do "do ../../compile_top.do; quit -f" > compile.log 2>&1
findstr /c:"Errors: 0" compile.log > nul || (echo COMPILE FAILED, see sim_do\work_dir\top\compile.log & exit /b 1)
call :run tb_top_display_policy "PASS tb_top_display_policy"

if %FAILED%==0 (echo ALL TESTBENCHES PASSED) else (echo %FAILED% TESTBENCH^(ES^) FAILED)
exit /b %FAILED%

:run
vsim -c -l %1.log work.%1 -do "onerror {quit -code 1}; onbreak {quit -code 1}; run -all; quit -code 0" > nul 2>&1
findstr /c:%2 %1.log > nul
if errorlevel 1 (
    echo FAIL %~1
    set /a FAILED+=1
) else (
    echo PASS %~1
)
exit /b 0
