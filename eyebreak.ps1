# eyebreak.ps1 — plays a sound every N minutes so you stand up and rest your eyes.
# Tray icon: green = enabled, grey = disabled. Right-click for menu; double-click toggles.
# Control from outside via flag files in this folder:
#   enabled.flag  present = ding, absent = silent   (Toggle-On.cmd / Toggle-Off.cmd)
#   quit.flag     present = exit                    (Quit.cmd)
# Config: config.json  { intervalMinutes, sound, checkInEvery, checkInSound, volume }  — re-read automatically when edited.
#   sound: a filename in sounds\ (default ding.mp3), "random" to shuffle every file in sounds\,
#          or a list of filenames (["a.mp3","b.mp3"]) to pick one of those at random.
#   checkInEvery / checkInSound: every Nth ding plays checkInSound instead (the "look around, anything else to do?" cue).
#          checkInSound takes the same forms as sound.
#   Set checkInEvery to 0 to disable.
# If a configured file is missing, the built-in default-ding.wav / default-checkin.wav play instead.
# Screen off (monitor power-down, not PC sleep) suspends dings; the clock restarts when the screen comes back.

$ErrorActionPreference = 'Stop'
$Root       = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $Root 'config.json'
$EnabledFlag = Join-Path $Root 'enabled.flag'
$QuitFlag    = Join-Path $Root 'quit.flag'
$ErrorLog    = Join-Path $Root 'error.log'

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

# ---- config ------------------------------------------------------------------
$script:cfg = $null
$script:cfgStamp = [DateTime]::MinValue
function Load-Config {
    $defaults = @{ intervalMinutes = 22; sound = 'ding.mp3'; checkInEvery = 3; checkInSound = 'ding2.mp3'; volume = 1.0 }
    $c = $defaults.Clone()
    if (Test-Path $ConfigPath) {
        try {
            $j = Get-Content $ConfigPath -Raw | ConvertFrom-Json
            foreach ($k in $defaults.Keys) {
                if ($null -ne $j.$k -and "$($j.$k)" -ne '') { $c[$k] = $j.$k }
            }
        } catch { Add-Content $ErrorLog "$(Get-Date -f s) bad config.json: $_" }
    }
    $c.intervalMinutes = [double]$c.intervalMinutes
    if ($c.intervalMinutes -le 0) { $c.intervalMinutes = 22 }
    $c.volume = [Math]::Min(1.0, [Math]::Max(0.0, [double]$c.volume))
    $c.checkInEvery = [Math]::Max(0, [int]$c.checkInEvery)
    $script:cfg = $c
    $script:cfgStamp = (Get-Item $ConfigPath -ErrorAction SilentlyContinue).LastWriteTimeUtc
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
$script:player = New-Object System.Windows.Media.MediaPlayer
function Play-Sound($name = $script:cfg.sound, [string]$fallback = 'default-ding.wav') {
    $file = Resolve-Sound $name $fallback
    if ($file) {
        try {
            $script:player.Open([Uri]$file)
            $script:player.Volume = $script:cfg.volume
            $script:player.Play()
            return
        } catch { Add-Content $ErrorLog "$(Get-Date -f s) play failed ($file): $_" }
    }
    [System.Media.SystemSounds]::Asterisk.Play()   # no sound file yet — fall back
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
$script:dingCount = 0                                 # dings so far; every checkInEvery-th plays checkInSound
$script:nextDue = [DateTime]::Now
$script:lastTip = ''

function Set-Enabled([bool]$on) {
    if ($on) { Set-Content $EnabledFlag '' } elseif (Test-Path $EnabledFlag) { Remove-Item $EnabledFlag }
}
function Reset-Timer { $script:nextDue = [DateTime]::Now.AddMinutes($script:cfg.intervalMinutes) }

# The ding itself: count it, and play the check-in sound on every Nth one.
function Invoke-Ding {
    $script:dingCount++
    $n = $script:cfg.checkInEvery
    if ($n -gt 0 -and ($script:dingCount % $n) -eq 0) { Play-Sound $script:cfg.checkInSound 'default-checkin.wav' }
    else { Play-Sound }
}
function Dings-UntilCheckIn {
    $n = $script:cfg.checkInEvery
    if ($n -le 0) { return -1 }
    return $n - ($script:dingCount % $n)
}

# All state changes flow through the flag file so tray, .cmd files and startup behave identically.
function Sync-State {
    $flag = Test-Path $EnabledFlag
    if ($flag -ne $script:enabled) {
        $script:enabled = $flag
        $miToggle.Checked = $flag
        $tray.Icon = if ($flag) { $IconOn } else { $IconOff }
        if ($flag) { Reset-Timer }
    }
    $off = ($script:display.State -eq 0)
    if ($off -ne $script:screenOff) {
        $script:screenOff = $off
        if (-not $off) { Reset-Timer }               # screen back on: count from now
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
        'Reset timer'     { Reset-Timer }
        'Play test sound' { Play-Sound }
        'Play check-in sound' { Play-Sound $script:cfg.checkInSound 'default-checkin.wav' }
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
$timer.Add_Tick({
    if (Test-Path $QuitFlag) { $timer.Stop(); [System.Windows.Forms.Application]::Exit(); return }
    $stamp = (Get-Item $ConfigPath -ErrorAction SilentlyContinue).LastWriteTimeUtc
    if ($stamp -ne $script:cfgStamp) { Load-Config; Reset-Timer }
    Sync-State
    if ($script:enabled -and -not $script:screenOff -and [DateTime]::Now -ge $script:nextDue) { Invoke-Ding; Reset-Timer }
})
$timer.Start()
Sync-State
[System.Windows.Forms.Application]::Run()

} catch {
    Add-Content $ErrorLog "$(Get-Date -f s) fatal: $_`n$($_.ScriptStackTrace)"
} finally {
    if ($tray) { $tray.Visible = $false; $tray.Dispose() }
    if ($script:display) { $script:display.Close() }
    if (Test-Path $QuitFlag) { Remove-Item $QuitFlag -ErrorAction SilentlyContinue }
    $mutex.ReleaseMutex() | Out-Null
}
