@echo off
rem Install.cmd [destination] — copy EyeBreak to a folder, add a Startup shortcut, and launch it.
rem   Default destination: %LOCALAPPDATA%\EyeBreak      e.g.  Install.cmd D:\Tools\EyeBreak
rem Safe to re-run (updates the app): never overwrites config.json or anything in sounds\.
setlocal
set "DEST=%~1"
if "%DEST%"=="" set "DEST=%LOCALAPPDATA%\EyeBreak"
if "%DEST:~-1%"=="\" set "DEST=%DEST:~0,-1%"
set "SRC=%~dp0"
if /i "%SRC:~0,-1%"=="%DEST%" goto :shortcut

if not exist "%DEST%\sounds" mkdir "%DEST%\sounds"
for %%F in (eyebreak.ps1 start-hidden.vbs Start.cmd Toggle-On.cmd Toggle-Off.cmd Quit.cmd Install.cmd Uninstall.cmd) do copy /y "%SRC%%%F" "%DEST%\" >nul
if not exist "%DEST%\config.json" copy "%SRC%config.json" "%DEST%\" >nul
for %%F in ("%SRC%sounds\*") do if not exist "%DEST%\sounds\%%~nxF" copy "%%F" "%DEST%\sounds\" >nul

:shortcut
powershell.exe -NoProfile -Command ^
  "$s=(New-Object -ComObject WScript.Shell).CreateShortcut([Environment]::GetFolderPath('Startup')+'\EyeBreak.lnk');" ^
  "$s.TargetPath='wscript.exe'; $s.Arguments='\"%DEST%\start-hidden.vbs\"'; $s.WorkingDirectory='%DEST%';" ^
  "$s.Description='EyeBreak - stand-up reminder'; $s.Save()"
echo Installed to %DEST% and added to Startup.
echo Put your sounds in %DEST%\sounds  (ding.mp3 and ding2.mp3) - see README.
if exist "%DEST%\quit.flag" del "%DEST%\quit.flag"
wscript.exe "%DEST%\start-hidden.vbs"
endlocal
