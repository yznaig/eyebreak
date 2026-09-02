' start-hidden.vbs — launch eyebreak.ps1 with no console window (used by the Startup shortcut)
Set sh = CreateObject("WScript.Shell")
dir = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
sh.Run "powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & dir & "eyebreak.ps1""", 0, False
