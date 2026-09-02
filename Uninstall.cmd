@echo off
rem Uninstall.cmd — stop EyeBreak and remove it from Startup. The folder (and your sounds) is left for you to delete.
echo.>"%~dp0quit.flag"
del "%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\EyeBreak.lnk" 2>nul
echo EyeBreak stopped and removed from Startup. Delete this folder to finish: %~dp0
