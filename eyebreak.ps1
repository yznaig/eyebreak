# eyebreak.ps1 — plays a sound every N minutes so you stand up and rest your eyes.
# Tray icon: green = enabled, grey = disabled. Right-click for menu; double-click toggles.
# Control from outside via flag files in this folder:
#   enabled.flag  present = ding, absent = silent   (Toggle-On.cmd / Toggle-Off.cmd)
#   quit.flag     present = exit                    (Quit.cmd)
# Config: config.json  { intervalMinutes, sound, checkInEvery, checkInSound, volume, breakMinutes }  — re-read automatically when edited.
#   sound: a filename in sounds\ (default ding.mp3), "random" to shuffle every file in sounds\,
#          or a list of filenames (["a.mp3","b.mp3"]) to pick one of those at random.
#   checkInEvery / checkInSound: every Nth ding plays checkInSound instead (the "look around, anything else to do?" cue).
#          checkInSound takes the same forms as sound.
#   Set checkInEvery to 0 to disable.
# If a configured file is missing, the built-in default-ding.wav / default-checkin.wav play instead.
# Screen off (monitor power-down, not PC sleep) suspends dings and pauses the countdown. When the screen comes back
#   the countdown picks up where it stopped, unless it was off for breakMinutes or longer: that counts as the break,
#   and the clock restarts. Set breakMinutes to 0 to restart on every screen wake.
# eyebreak.log records every ding, whether it played to the end or failed, and every clock restart with its reason.
#   It shows what the app did, not what reached your ears: a muted or wrong output device still logs a played ding.

$ErrorActionPreference = 'Stop'
$Root       = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $Root 'config.json'
$EnabledFlag = Join-Path $Root 'enabled.flag'
$QuitFlag    = Join-Path $Root 'quit.flag'
$ErrorLog    = Join-Path $Root 'error.log'
$LogPath     = Join-Path $Root 'eyebreak.log'

# A failed log write must never reach the app. Every 200 lines, a log past 512 KB is cut to its last 2000 lines.
$script:logWrites = 0
function Trim-Log {
    try {
        if ((Test-Path -LiteralPath $LogPath) -and (Get-Item -LiteralPath $LogPath).Length -gt 512KB) {
            $keep = Get-Content -LiteralPath $LogPath -Tail 2000 -Encoding UTF8
            Set-Content -LiteralPath $LogPath $keep -Encoding UTF8
        }
    } catch { }
}
function Write-Log([string]$msg) {
    try {
        Add-Content -LiteralPath $LogPath ("$(Get-Date -f s) $msg" -replace '\s*[\r\n]+\s*', ' ') -Encoding UTF8
        if ((++$script:logWrites % 200) -eq 0) { Trim-Log }
    } catch { }
}
function Write-ErrorLog([string]$msg) {
    try { Add-Content -LiteralPath $ErrorLog "$(Get-Date -f s) $msg" -Encoding UTF8 } catch { }
}

# ---- single instance ---------------------------------------------------------
$mutex = New-Object System.Threading.Mutex($false, 'Local\EyeBreakTimer')
if (-not $mutex.WaitOne(0, $false)) { exit 0 }

try {
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName PresentationCore

# Hidden window that receives WM_POWERBROADCAST for the console display state (0 = off, 1 = on, 2 = dimmed).
Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;
public class DisplayWatcher : NativeWindow {
    [DllImport("user32.dll", SetLastError = true)]
    static extern IntPtr RegisterPowerSettingNotification(IntPtr hRecipient, ref Guid PowerSettingGuid, int Flags);
    [DllImport("user32.dll")]
    static extern bool UnregisterPowerSettingNotification(IntPtr handle);
    static Guid GUID_CONSOLE_DISPLAY_STATE = new Guid("6fe69556-704a-47a0-8f24-c28d936fda47");
    const int WM_POWERBROADCAST = 0x0218, PBT_POWERSETTINGCHANGE = 0x8013;
    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    struct POWERBROADCAST_SETTING { public Guid PowerSetting; public uint DataLength; public byte Data; }
    public int State = 1;
    IntPtr hReg;
    public DisplayWatcher() {
        CreateHandle(new CreateParams());
        hReg = RegisterPowerSettingNotification(Handle, ref GUID_CONSOLE_DISPLAY_STATE, 0);
    }
    protected override void WndProc(ref Message m) {
        if (m.Msg == WM_POWERBROADCAST && (int)m.WParam == PBT_POWERSETTINGCHANGE) {
            var s = (POWERBROADCAST_SETTING)Marshal.PtrToStructure(m.LParam, typeof(POWERBROADCAST_SETTING));
            if (s.PowerSetting == GUID_CONSOLE_DISPLAY_STATE) State = s.Data;
        }
        base.WndProc(ref m);
    }
    public void Close() { if (hReg != IntPtr.Zero) UnregisterPowerSettingNotification(hReg); DestroyHandle(); }
}
'@
$script:display = New-Object DisplayWatcher

Trim-Log

# ---- config ------------------------------------------------------------------
$script:cfg = $null
$script:cfgStamp = [DateTime]::MinValue
function Load-Config {
    $defaults = @{ intervalMinutes = 22; sound = 'ding.mp3'; checkInEvery = 3; checkInSound = 'ding2.mp3'; volume = 1.0; breakMinutes = 5 }
    # Stamp first, so a bad file is read once and not on every tick. A bad file keeps the previous settings.
    $script:cfgStamp = (Get-Item $ConfigPath -ErrorAction SilentlyContinue).LastWriteTimeUtc
    $c = $defaults.Clone()
    try {
        if (Test-Path $ConfigPath) {
            $j = Get-Content $ConfigPath -Raw | ConvertFrom-Json
            foreach ($k in $defaults.Keys) {
                if ($null -ne $j.$k -and "$($j.$k)" -ne '') { $c[$k] = $j.$k }
            }
        }
        foreach ($k in 'intervalMinutes', 'volume', 'breakMinutes') {
            $c[$k] = [double]$c[$k]
            if ([double]::IsNaN($c[$k]) -or [double]::IsInfinity($c[$k])) { throw "$k is not a usable number" }
        }
        if ($c.intervalMinutes -le 0) { $c.intervalMinutes = 22 }
        $c.volume = [Math]::Min(1.0, [Math]::Max(0.0, $c.volume))
        $c.checkInEvery = [Math]::Max(0, [int]$c.checkInEvery)
        $c.breakMinutes = [Math]::Max(0.0, $c.breakMinutes)
        $script:cfg = $c
    } catch {
        if (-not $script:cfg) { $script:cfg = $defaults }
        Write-ErrorLog "bad config.json: $_"
        Write-Log "bad config.json, keeping the previous settings: $_"
    }
}

# Resolve a sound name to a file. A filename plays that file, else the built-in fallback for its role.
# "random" picks a random file from sounds\ (never the same one twice in a row; built-ins only if nothing else).
# A list picks at random among the listed files that exist (same no-repeat rule), else the fallback.
$script:lastSound = $null
function Get-SoundFiles {
    $files = @(Get-ChildItem (Join-Path $Root 'sounds') -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -match '^\.(mp3|wav|mp4|m4a|wma|aac|ogg|flac)$' })
    $own = @($files | Where-Object { $_.Name -notlike 'default-*' })
    if ($own.Count -gt 0) { return $own } else { return $files }
}
function Resolve-Sound($mode, [string]$fallback) {
    $dir = Join-Path $Root 'sounds'
    $files = $null
    if ($mode -is [array]) {
        $files = @($mode | ForEach-Object { Get-Item -LiteralPath (Join-Path $dir "$_") -ErrorAction SilentlyContinue })
        if ($files.Count -eq 0) { $files = $null; $mode = '' }   # none of the listed files exist: use the fallback
    }
    if (-not $files -and $mode -ne 'random') {
        if ($mode -and (Test-Path -LiteralPath (Join-Path $dir $mode))) { return (Join-Path $dir $mode) }
        if ($fallback -and (Test-Path (Join-Path $dir $fallback))) { return (Join-Path $dir $fallback) }
    }
    if (-not $files) { $files = Get-SoundFiles }
    if ($files.Count -eq 0) { return $null }
    $pool = @($files | Where-Object { $_.FullName -ne $script:lastSound })
    if ($pool.Count -eq 0) { $pool = $files }
    $pick = $pool | Get-Random
    $script:lastSound = $pick.FullName
    return $pick.FullName
}

# ---- sound -------------------------------------------------------------------
# MediaPlayer reports a failed playback through MediaFailed, never as an exception, so the fallback beep hangs off
# the event. MediaOpened is no use as a success signal: it does not fire when the same file is opened again.
$script:player = New-Object System.Windows.Media.MediaPlayer
$script:playFile = ''
$script:playCheckAt = $null                           # when the tick should confirm playback started; $null = nothing pending
$script:playLive = $false                             # a sound was started and has neither ended nor failed
$script:beeped = $false                               # the fallback already played for the current sound
function Play-Fallback {
    if ($script:beeped) { return }                    # one beep per sound, however many ways it fails
    $script:beeped = $true
    [System.Media.SystemSounds]::Asterisk.Play()
}
$script:player.Add_MediaEnded({
    $script:playCheckAt = $null
    $script:playLive = $false
    Write-Log "played to the end: $($script:playFile)"
})
$script:player.Add_MediaFailed({
    param($s, $e)
    $script:playCheckAt = $null
    $script:playLive = $false
    Play-Fallback
    Write-Log "PLAY FAILED: $($script:playFile): $($e.ErrorException.Message) - system beep instead"
})
function Play-Sound($name = $script:cfg.sound, [string]$fallback = 'default-ding.wav', [string]$what = 'test sound') {
    $script:beeped = $false
    $file = $null
    try { $file = Resolve-Sound $name $fallback } catch { Write-Log "${what}: could not pick a sound: $_" }
    if ($file) {
        try {
            if ($script:playLive) { Write-Log "cut short by the next sound: $($script:playFile)" }
            $script:playFile = Split-Path -Leaf $file
            $script:playLive = $true
            $script:playCheckAt = [DateTime]::Now.AddSeconds(5)   # set before Open, in case MediaFailed is raised inside it
            $script:player.Open([Uri]$file)
            $script:player.Volume = $script:cfg.volume
            $script:player.Play()
            Write-Log "${what}: $($script:playFile) at volume $($script:cfg.volume)"
            return
        } catch {
            $script:playCheckAt = $null
            $script:playLive = $false
            Play-Fallback
            Write-ErrorLog "play failed ($file): $_"
            Write-Log "PLAY FAILED: $($script:playFile): $_ - system beep instead"
            return
        }
    }
    Play-Fallback                                     # no sound file yet — fall back
    Write-Log "${what}: no sound file - system beep instead"
}
# Called from the tick: five seconds after Play, a sound that neither ended nor failed must be moving.
function Confirm-Playback {
    if (-not $script:playCheckAt -or [DateTime]::Now -lt $script:playCheckAt) { return }
    $script:playCheckAt = $null
    if ($script:player.Position -le [TimeSpan]::Zero) {
        Play-Fallback
        Write-Log "PLAY DID NOT START: $($script:playFile) - system beep instead"
    }
}

# ---- tray icon ---------------------------------------------------------------
function New-DotIcon([System.Drawing.Color]$color) {
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::Transparent)
    $g.FillEllipse((New-Object System.Drawing.SolidBrush $color), 3, 3, 26, 26)
    $g.DrawEllipse((New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(90,0,0,0)), 2), 3, 3, 26, 26)
    $g.Dispose()
    return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}
$IconOn  = New-DotIcon ([System.Drawing.Color]::FromArgb(64, 190, 90))
$IconOff = New-DotIcon ([System.Drawing.Color]::FromArgb(150, 150, 150))

$tray = New-Object System.Windows.Forms.NotifyIcon
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miToggle = $menu.Items.Add('Enabled')
$miToggle.CheckOnClick = $false
$menu.Items.Add('Reset timer')      | Out-Null
$menu.Items.Add('Play test sound')  | Out-Null
$menu.Items.Add('Play check-in sound') | Out-Null
$menu.Items.Add('Open folder')      | Out-Null
$menu.Items.Add('-')                | Out-Null
$menu.Items.Add('Quit')             | Out-Null
$tray.ContextMenuStrip = $menu
$tray.Visible = $true

# ---- state -------------------------------------------------------------------
$script:enabled = $null
$script:screenOff = $false
$script:screenOffAt = [DateTime]::Now
$script:pauseFrom = [DateTime]::Now                  # start of the paused stretch still owed back to the countdown
$script:lastTick = [DateTime]::Now
$script:lastTickError = ''
$script:dingCount = 0                                 # dings so far; every checkInEvery-th plays checkInSound
$script:nextDue = [DateTime]::Now
$script:lastTip = ''

function Set-Enabled([bool]$on) {
    if ($on) { Set-Content $EnabledFlag '' } elseif (Test-Path $EnabledFlag) { Remove-Item $EnabledFlag }
}
function Reset-Timer([string]$why) {
    $script:nextDue = [DateTime]::Now.AddMinutes($script:cfg.intervalMinutes)
    $script:pauseFrom = [DateTime]::Now               # a restart while the screen is off: only the time after it is owed
    if ($why) { Write-Log "clock restarted ($why), next ding $($script:nextDue.ToString('HH:mm:ss'))" }
}

# The ding itself: count it, and play the check-in sound on every Nth one.
function Invoke-Ding {
    $script:dingCount++
    $n = $script:cfg.checkInEvery
    $next = "next $($script:nextDue.ToString('HH:mm:ss'))"
    if ($n -gt 0 -and ($script:dingCount % $n) -eq 0) { Play-Sound $script:cfg.checkInSound 'default-checkin.wav' "check-in ding #$($script:dingCount), $next" }
    else { Play-Sound -what "ding #$($script:dingCount), $next" }
}
function Dings-UntilCheckIn {
    $n = $script:cfg.checkInEvery
    if ($n -le 0) { return -1 }
    return $n - ($script:dingCount % $n)
}

# A tick more than 30 s late means the process was frozen, usually PC sleep. If the screen-off was seen before
# the freeze, the screen logic below covers it; otherwise the gap is treated the same way a screen-off is.
function Sync-Clock {
    $now = [DateTime]::Now
    $gap = ($now - $script:lastTick).TotalMinutes
    $script:lastTick = $now
    if ([Math]::Abs($gap) -lt 0.5) { return }
    if ($script:screenOff) { Write-Log ('clock jumped {0:n1} min while the screen was off' -f $gap); return }
    if ($gap -ge $script:cfg.breakMinutes) { Reset-Timer ('clock jumped {0:n1} min (PC asleep?), counted as a break' -f $gap) }
    else {
        $script:nextDue = $script:nextDue.AddMinutes($gap)
        Write-Log ('clock jumped {0:n1} min, countdown resumed, next ding {1:HH:mm:ss}' -f $gap, $script:nextDue)
    }
}

# All state changes flow through the flag file so tray, .cmd files and startup behave identically.
function Sync-State {
    $flag = Test-Path $EnabledFlag
    if ($flag -ne $script:enabled) {
        $script:enabled = $flag
        $miToggle.Checked = $flag
        $tray.Icon = if ($flag) { $IconOn } else { $IconOff }
        if ($flag) { Reset-Timer 'enabled' } else { Write-Log 'paused' }
    }
    $off = ($script:display.State -eq 0)
    if ($off -ne $script:screenOff) {
        $script:screenOff = $off
        if ($off) { $script:screenOffAt = [DateTime]::Now; $script:pauseFrom = $script:screenOffAt; Write-Log 'screen off, countdown paused' }
        else {
            $now = [DateTime]::Now
            $away = [Math]::Max(0.0, ($now - $script:screenOffAt).TotalMinutes)
            if ($away -ge $script:cfg.breakMinutes) { Reset-Timer ('screen back after {0:n1} min, counted as a break' -f $away) }
            else {                                    # a blink, not a break: give back the time the screen was off
                $script:nextDue = $script:nextDue.AddMinutes([Math]::Max(0.0, ($now - $script:pauseFrom).TotalMinutes))
                Write-Log ('screen back after {0:n1} min, countdown resumed, next ding {1:HH:mm:ss}' -f $away, $script:nextDue)
            }
        }
    }
    $tip = if (-not $script:enabled) { 'EyeBreak - paused' }
    elseif ($script:screenOff) { 'EyeBreak - screen off, waiting' }
    else {
        $m = [Math]::Max(0, [Math]::Ceiling(($script:nextDue - [DateTime]::Now).TotalMinutes))
        $k = Dings-UntilCheckIn
        $ci = if ($k -eq 1) { ' - next is check-in' } elseif ($k -gt 1) { " - check-in in $k" } else { '' }
        "EyeBreak - next ding in $m min$ci"
    }
    if ($tip -ne $script:lastTip) { $tray.Text = $tip; $script:lastTip = $tip }
}

$menu.Add_ItemClicked({
    param($s, $e)
    switch ($e.ClickedItem.Text) {
        'Enabled'         { Set-Enabled (-not $script:enabled) }
        'Reset timer'     { Reset-Timer 'reset from the tray menu' }
        'Play test sound' { Play-Sound }
        'Play check-in sound' { Play-Sound $script:cfg.checkInSound 'default-checkin.wav' 'test check-in sound' }
        'Open folder'     { Start-Process explorer.exe $Root }
        'Quit'            { Set-Content $QuitFlag '' }
    }
})
$tray.Add_DoubleClick({ Set-Enabled (-not $script:enabled) })

# ---- main loop (1 s tick on the UI thread) ----------------------------------
if (Test-Path $QuitFlag) { Remove-Item $QuitFlag }   # stale flag from a previous Quit
Load-Config
Set-Enabled $true                                     # always start enabled

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
# An error in the tick is swallowed by PowerShell and skips the rest of that tick, so it is caught and logged here
# (once per distinct error). The clock restarts before the ding plays: a ding that throws must not repeat every second.
$timer.Add_Tick({
    try {
        if (Test-Path $QuitFlag) { $timer.Stop(); [System.Windows.Forms.Application]::Exit(); return }
        Sync-Clock
        $stamp = (Get-Item $ConfigPath -ErrorAction SilentlyContinue).LastWriteTimeUtc
        if ($stamp -ne $script:cfgStamp) { Load-Config; Reset-Timer 'config.json changed' }
        Sync-State
        Confirm-Playback
        if ($script:enabled -and -not $script:screenOff -and [DateTime]::Now -ge $script:nextDue) { Reset-Timer; Invoke-Ding }
        $script:lastTickError = ''
    } catch {
        if ("$_" -ne $script:lastTickError) {
            $script:lastTickError = "$_"
            Write-Log "tick error: $_"
            Write-ErrorLog "tick error: $_`n$($_.ScriptStackTrace)"
        }
    }
})
$timer.Start()
Write-Log "started: ding every $($script:cfg.intervalMinutes) min, check-in every $($script:cfg.checkInEvery), break after $($script:cfg.breakMinutes) min of screen off"
Sync-State
[System.Windows.Forms.Application]::Run()

} catch {
    Write-ErrorLog "fatal: $_`n$($_.ScriptStackTrace)"
    Write-Log "fatal: $_ (details in error.log)"
} finally {
    Write-Log 'stopped'
    if ($tray) { $tray.Visible = $false; $tray.Dispose() }
    if ($script:display) { $script:display.Close() }
    if (Test-Path $QuitFlag) { Remove-Item $QuitFlag -ErrorAction SilentlyContinue }
    $mutex.ReleaseMutex() | Out-Null
}
