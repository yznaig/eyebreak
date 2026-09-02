@echo off
rem Toggle-On.cmd — enable dings (and start EyeBreak if it isn't running)
echo.>"%~dp0enabled.flag"
wscript.exe "%~dp0start-hidden.vbs"
