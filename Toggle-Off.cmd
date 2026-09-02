@echo off
rem Toggle-Off.cmd — pause dings (EyeBreak keeps running, tray icon goes grey)
if exist "%~dp0enabled.flag" del "%~dp0enabled.flag"
