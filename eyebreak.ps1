# eyebreak.ps1 — plays a sound every N minutes so you stand up and rest your eyes.
# Tray icon: green = enabled, grey = disabled. Right-click for menu; double-click toggles.
# Control from outside via flag files in this folder:
#   enabled.flag  present = ding, absent = silent   (Toggle-On.cmd / Toggle-Off.cmd)
#   quit.flag     present = exit                    (Quit.cmd)
# Config: config.json  { intervalMinutes, sound, checkInEvery, checkInSound, volume, breakMinutes, duckOthersTo }  — re-read automatically when edited.
#   sound: a filename in sounds\ (default ding.mp3), "random" to shuffle every file in sounds\,
#          or a list of filenames (["a.mp3","b.mp3"]) to pick one of those at random.
#   checkInEvery / checkInSound: every Nth ding plays checkInSound instead (the "look around, anything else to do?" cue).
#          checkInSound takes the same forms as sound.
#   Set checkInEvery to 0 to disable.
# If a configured file is missing, the built-in default-ding.wav / default-checkin.wav play instead.
# Screen off (monitor power-down, not PC sleep) suspends dings and pauses the countdown. When the screen comes back
#   the countdown picks up where it stopped, unless it was off for breakMinutes or longer: that counts as the break,
#   and the clock restarts. Set breakMinutes to 0 to restart on every screen wake.
# duckOthersTo: while a ding plays, other apps (music, browser) are turned down to this share of their volume and put
#   back when it ends (default 0.25; 1 turns it off). One that another app moved during the ding is put back once
#   that app lets go. Their levels are saved to ducked.txt first, so a crash mid-ding is undone at the next start.
# Dings opt out of Windows' call ducking, so they play at full volume over a call or dictation (Wispr Flow, Discord).
# holdWhileRecording: process names whose microphone use makes a due ding wait until they stop (default [] = never
#   wait). For an app that silences other audio some way Windows lets no one opt out of.
# eyebreak.log records every ding with the Windows output it went to, whether it played to the end and reached that
#   output (a signal meter, read before volume), or why it failed, and every clock restart with its reason. A failed ding is retried once
#   with a fresh player; if that fails too, or a ding ends without any sound reaching an output, a notification shows.
#   The log shows what reached the output, not your ears: a muted speaker or an unplugged jack still logs a level.

$ErrorActionPreference = 'Stop'
$Root       = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $Root 'config.json'
$EnabledFlag = Join-Path $Root 'enabled.flag'
$QuitFlag    = Join-Path $Root 'quit.flag'
$ErrorLog    = Join-Path $Root 'error.log'
$LogPath     = Join-Path $Root 'eyebreak.log'
$DuckedPath  = Join-Path $Root 'ducked.txt'

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

# Windows Core Audio: the default output's name, and how loud this process's own sound is on each output.
# Diagnostics only: if it fails to load, dings still play and the log just lacks those details.
$script:audioInfo = $false
try {
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Runtime.InteropServices;
public static class EyeAudio {
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumeratorCom {}
    [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator {
        int EnumAudioEndpoints(int dataFlow, int stateMask, out IMMDeviceCollection devices);
        int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice device);
    }
    [Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceCollection { int GetCount(out int n); int Item(int i, out IMMDevice d); }
    [Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice {
        int Activate(ref Guid iid, int ctx, IntPtr p, [MarshalAs(UnmanagedType.IUnknown)] out object o);
        int OpenPropertyStore(int access, out IPropertyStore store);
    }
    [Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore { int GetCount(out int c); int GetAt(int i, out PROPERTYKEY k); int GetValue(ref PROPERTYKEY k, out PROPVARIANT v); }
    [StructLayout(LayoutKind.Sequential)] struct PROPERTYKEY { public Guid fmtid; public int pid; }
    [StructLayout(LayoutKind.Sequential)] struct PROPVARIANT { public short vt; short r1, r2, r3; public IntPtr p; public IntPtr p2; }
    [Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionManager2 {
        int GetAudioSessionControl(IntPtr a, int b, out IntPtr c); int GetSimpleAudioVolume(IntPtr a, int b, out IntPtr c);
        int GetSessionEnumerator(out IAudioSessionEnumerator e);
    }
    [Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionEnumerator { int GetCount(out int n); int GetSession(int i, out IAudioSessionControl2 s); }
    [Guid("bfb7ff88-7239-4fc9-8fa2-07c950be9c6d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionControl2 {
        int GetState(out int s); int GetDisplayName(out IntPtr n); int SetDisplayName(IntPtr a, IntPtr b);
        int GetIconPath(out IntPtr p); int SetIconPath(IntPtr a, IntPtr b); int GetGroupingParam(out Guid g); int SetGroupingParam(IntPtr a, IntPtr b);
        int RegisterAudioSessionNotification(IntPtr a); int UnregisterAudioSessionNotification(IntPtr a);
        int GetSessionIdentifier(out IntPtr a); int GetSessionInstanceIdentifier(out IntPtr a); int GetProcessId(out int pid);
        [PreserveSig] int IsSystemSoundsSession(); int SetDuckingPreference([MarshalAs(UnmanagedType.Bool)] bool optOut);
    }
    [Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioMeterInformation { int GetPeakValue(out float p); }
    [Guid("87CE5498-68D6-44E5-9215-6DA47EF883D8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface ISimpleAudioVolume { int SetMasterVolume(float v, IntPtr ctx); int GetMasterVolume(out float v); int SetMute(bool m, IntPtr ctx); int GetMute(out bool m); }
    const int RENDER = 0, MULTIMEDIA = 1, ACTIVE = 1, CLSCTX_ALL = 23;
    static string SessionId(IAudioSessionControl2 sc) {
        IntPtr p; sc.GetSessionIdentifier(out p);
        string id = Marshal.PtrToStringUni(p); Marshal.FreeCoTaskMem(p);
        return id;
    }
    // Every audio session on every active output, with its process id.
    static List<KeyValuePair<int, IAudioSessionControl2>> Sessions() {
        List<KeyValuePair<int, IAudioSessionControl2>> all = new List<KeyValuePair<int, IAudioSessionControl2>>();
        IMMDeviceEnumerator en = (IMMDeviceEnumerator)new MMDeviceEnumeratorCom();
        IMMDeviceCollection col; en.EnumAudioEndpoints(RENDER, ACTIVE, out col);
        int n; col.GetCount(out n);
        for (int i = 0; i < n; i++) {
            IMMDevice d; col.Item(i, out d);
            Guid sg = typeof(IAudioSessionManager2).GUID; object smo;
            d.Activate(ref sg, CLSCTX_ALL, IntPtr.Zero, out smo);
            IAudioSessionEnumerator se; ((IAudioSessionManager2)smo).GetSessionEnumerator(out se);
            int sn; se.GetCount(out sn);
            for (int j = 0; j < sn; j++) {
                IAudioSessionControl2 sc; se.GetSession(j, out sc);
                int spid; sc.GetProcessId(out spid);
                all.Add(new KeyValuePair<int, IAudioSessionControl2>(spid, sc));
            }
        }
        return all;
    }
    // Turn every other app's session down to factor x its volume. Returns "session id<TAB>original<TAB>set" rows to
    // save for crash recovery, or null on failure. System sounds (pid 0) and this process are left alone.
    public static string[] Duck(int pid, float factor) {
        List<string> rows = new List<string>();
        try {
            foreach (KeyValuePair<int, IAudioSessionControl2> kv in Sessions()) {
                if (kv.Key == pid || kv.Key == 0) continue;
                ISimpleAudioVolume vol = (ISimpleAudioVolume)kv.Value;
                float v; vol.GetMasterVolume(out v);
                if (v <= 0.001f) continue;
                float nv = v * factor;
                vol.SetMasterVolume(nv, IntPtr.Zero);
                rows.Add(SessionId(kv.Value) + "\t" + v.ToString(CultureInfo.InvariantCulture) + "\t" + nv.ToString(CultureInfo.InvariantCulture));
            }
            return rows.ToArray();
        } catch { return rows.Count > 0 ? rows.ToArray() : null; }
    }
    // Put back each saved session that is still at the volume Duck set. Returns the rows still owed: sessions some
    // other app moved meanwhile (dictation apps mute this way, then restore what they saw: the ducked level).
    // A session back at its original volume, or gone, is dropped.
    public static string[] RestoreRows(string[] rows) {
        Dictionary<string, string> owed = new Dictionary<string, string>();
        Dictionary<string, float[]> saved = new Dictionary<string, float[]>();
        foreach (string r in rows) {
            string[] f = r.Split('\t');
            if (f.Length != 3) continue;
            saved[f[0]] = new float[] { float.Parse(f[1], CultureInfo.InvariantCulture), float.Parse(f[2], CultureInfo.InvariantCulture) };
        }
        try {
            foreach (KeyValuePair<int, IAudioSessionControl2> kv in Sessions()) {
                string id = SessionId(kv.Value);
                float[] ov;
                if (!saved.TryGetValue(id, out ov)) continue;
                ISimpleAudioVolume vol = (ISimpleAudioVolume)kv.Value;
                float cur; vol.GetMasterVolume(out cur);
                if (Math.Abs(cur - ov[1]) < 0.01f) vol.SetMasterVolume(ov[0], IntPtr.Zero);
                else if (Math.Abs(cur - ov[0]) >= 0.01f)
                    owed[id] = id + "\t" + ov[0].ToString(CultureInfo.InvariantCulture) + "\t" + ov[1].ToString(CultureInfo.InvariantCulture);
            }
        } catch { return rows; }
        return new List<string>(owed.Values).ToArray();
    }
    // The first of the named processes that is recording from a microphone right now, or null.
    public static string Recording(string[] names) {
        try {
            IMMDeviceEnumerator en = (IMMDeviceEnumerator)new MMDeviceEnumeratorCom();
            IMMDeviceCollection col; en.EnumAudioEndpoints(1, ACTIVE, out col);
            int n; col.GetCount(out n);
            for (int i = 0; i < n; i++) {
                IMMDevice d; col.Item(i, out d);
                Guid sg = typeof(IAudioSessionManager2).GUID; object smo;
                d.Activate(ref sg, CLSCTX_ALL, IntPtr.Zero, out smo);
                IAudioSessionEnumerator se; ((IAudioSessionManager2)smo).GetSessionEnumerator(out se);
                int sn; se.GetCount(out sn);
                for (int j = 0; j < sn; j++) {
                    IAudioSessionControl2 sc; se.GetSession(j, out sc);
                    int st; sc.GetState(out st);
                    if (st != 1) continue;
                    int spid; sc.GetProcessId(out spid);
                    string pn;
                    try { pn = System.Diagnostics.Process.GetProcessById(spid).ProcessName; } catch { continue; }
                    foreach (string want in names) if (string.Equals(pn, want, StringComparison.OrdinalIgnoreCase)) return pn;
                }
            }
        } catch { }
        return null;
    }
    static string Name(IMMDevice d) {
        IPropertyStore ps; d.OpenPropertyStore(0, out ps);
        PROPERTYKEY k = new PROPERTYKEY(); k.fmtid = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"); k.pid = 14;
        PROPVARIANT v; ps.GetValue(ref k, out v);
        return v.vt == 31 ? Marshal.PtrToStringUni(v.p) : "unnamed output";
    }
    public static string DefaultOutput() {
        try {
            IMMDeviceEnumerator en = (IMMDeviceEnumerator)new MMDeviceEnumeratorCom();
            IMMDevice d; en.GetDefaultAudioEndpoint(RENDER, MULTIMEDIA, out d);
            return Name(d);
        } catch { return "unknown output"; }
    }
    // Opt this process's sessions out of Windows' call ducking (the "reduce other sounds by 80%" Windows applies
    // while it detects a call or dictation). Returns how many sessions were set.
    public static int OptOutOfDucking(int pid) {
        int n = 0;
        try {
            foreach (KeyValuePair<int, IAudioSessionControl2> kv in Sessions()) {
                if (kv.Key != pid) continue;
                try { kv.Value.SetDuckingPreference(true); n++; } catch { }
            }
        } catch { }
        return n;
    }
    // One "output name<TAB>level" row per audio session of this process; null when the meters cannot be read.
    public static string[] OwnLevels(int pid) {
        try {
            List<string> rows = new List<string>();
            IMMDeviceEnumerator en = (IMMDeviceEnumerator)new MMDeviceEnumeratorCom();
            IMMDeviceCollection col; en.EnumAudioEndpoints(RENDER, ACTIVE, out col);
            int n; col.GetCount(out n);
            for (int i = 0; i < n; i++) {
                IMMDevice d; col.Item(i, out d);
                Guid sg = typeof(IAudioSessionManager2).GUID; object smo;
                d.Activate(ref sg, CLSCTX_ALL, IntPtr.Zero, out smo);
                IAudioSessionEnumerator se; ((IAudioSessionManager2)smo).GetSessionEnumerator(out se);
                int sn; se.GetCount(out sn);
                string name = null;
                for (int j = 0; j < sn; j++) {
                    IAudioSessionControl2 sc; se.GetSession(j, out sc);
                    int spid; sc.GetProcessId(out spid);
                    if (spid != pid) continue;
                    float peak; ((IAudioMeterInformation)sc).GetPeakValue(out peak);
                    if (name == null) name = Name(d);
                    rows.Add(name + "\t" + peak.ToString(CultureInfo.InvariantCulture));
                }
            }
            return rows.ToArray();
        } catch { return null; }
    }
}
'@
$script:audioInfo = $true
} catch { Write-ErrorLog "audio diagnostics unavailable: $_" }

Trim-Log

# ---- config ------------------------------------------------------------------
$script:cfg = $null
$script:cfgStamp = [DateTime]::MinValue
function Load-Config {
    $defaults = @{ intervalMinutes = 22; sound = 'ding.mp3'; checkInEvery = 3; checkInSound = 'ding2.mp3'; volume = 1.0; breakMinutes = 5; duckOthersTo = 0.25; holdWhileRecording = @() }
    # Stamp first, so a bad file is read once and not on every tick. A bad file keeps the previous settings.
    $script:cfgStamp = (Get-Item $ConfigPath -ErrorAction SilentlyContinue).LastWriteTimeUtc
    $c = $defaults.Clone()
    try {
        if (Test-Path $ConfigPath) {
            $j = Get-Content $ConfigPath -Raw | ConvertFrom-Json
            foreach ($k in $defaults.Keys) {
                if ($k -eq 'holdWhileRecording') { if ($null -ne $j.$k) { $c[$k] = @($j.$k) } }   # [] turns holding off
                elseif ($null -ne $j.$k -and "$($j.$k)" -ne '') { $c[$k] = $j.$k }
            }
        }
        foreach ($k in 'intervalMinutes', 'volume', 'breakMinutes', 'duckOthersTo') {
            $c[$k] = [double]$c[$k]
            if ([double]::IsNaN($c[$k]) -or [double]::IsInfinity($c[$k])) { throw "$k is not a usable number" }
        }
        if ($c.intervalMinutes -le 0) { $c.intervalMinutes = 22 }
        $c.volume = [Math]::Min(1.0, [Math]::Max(0.0, $c.volume))
        $c.checkInEvery = [Math]::Max(0, [int]$c.checkInEvery)
        $c.breakMinutes = [Math]::Max(0.0, $c.breakMinutes)
        $c.duckOthersTo = [Math]::Min(1.0, [Math]::Max(0.0, $c.duckOthersTo))
        $script:cfg = $c
        return $true
    } catch {
        if (-not $script:cfg) { $script:cfg = $defaults }
        Write-ErrorLog "bad config.json: $_"
        Write-Log "bad config.json, keeping the previous settings: $_"
        return $false
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
# MediaPlayer reports a failed playback through MediaFailed, never as an exception, and MediaOpened does not fire when
# the same file is opened again, so success is judged by MediaEnded plus a level meter on this process's own sound.
# A failure gets one retry with a fresh player; a second failure, or a ding that ends without reaching any output
# (another app such as a DAW holding the sound device), requests the system beep and shows a notification.
$script:player = $null
$script:playFile = ''                                 # name of the sound now playing, for the log
$script:playPath = ''                                 # its full path, for the retry
$script:playWhat = ''                                 # what it is: "ding #3, next 12:05:10", "test sound"
$script:playCheckAt = $null                           # when the tick should confirm playback started; $null = nothing pending
$script:playLive = $false                             # a sound was started and has neither ended nor failed
$script:beeped = $false                               # the fallback already played for the current sound
$script:retried = $false                              # the current sound already had its one retry
$script:retryAt = $null                               # when to replay a failed sound with a fresh player
$script:levels = @{}                                  # output name -> loudest signal this process sent it (Windows meters it before volume)
$script:levelsRead = $false                           # the meters answered at least once for the current sound
$script:optedOut = 0                                  # this process's sessions opted out of Windows call ducking

# Other apps go down while a ding plays and come back when it ends, fails, or after 30 s at the latest. A volume that
# another app moved meanwhile is watched for a minute and put back once it returns to the ducked level.
$script:duckUntil = $null                             # set while other apps are down for a ding
$script:duckRows = @()                                # what Duck changed: session id, original volume, ducked volume
$script:duckOwedUntil = $null                         # set while some of those are still owed back
function Save-DuckRows {
    try {
        if ($script:duckRows.Count -gt 0) { Set-Content -LiteralPath $DuckedPath $script:duckRows -Encoding UTF8 }
        else { Remove-Item -LiteralPath $DuckedPath -ErrorAction SilentlyContinue }
    } catch { }
}
function Start-Duck {
    if (-not $script:audioInfo -or $script:cfg.duckOthersTo -ge 1 -or $script:cfg.volume -le 0) { return }
    if ($script:duckRows.Count -gt 0) { Pay-DuckOwed $true }   # an earlier duck still owed back: settle it first
    $rows = [EyeAudio]::Duck($PID, [float]$script:cfg.duckOthersTo)
    if ($null -eq $rows -or $rows.Count -eq 0) { return }
    $script:duckRows = @($rows)
    Save-DuckRows
    $script:duckUntil = [DateTime]::Now.AddSeconds(30)
    Write-Log ('turned {0} other app sound(s) down to {1:p0} for the ding' -f $rows.Count, $script:cfg.duckOthersTo)
}
function Stop-Duck {
    if (-not $script:duckUntil) { return }
    $script:duckUntil = $null
    Pay-DuckOwed $false
    if ($script:duckRows.Count -gt 0) {
        $script:duckOwedUntil = [DateTime]::Now.AddSeconds(60)
        Write-Log "$($script:duckRows.Count) app sound(s) were changed by another app during the ding; putting them back when it lets go"
    }
}
# Put back what is still at the ducked level. $final: give up on the rest (after the minute, or before a new duck).
function Pay-DuckOwed([bool]$final) {
    $before = $script:duckRows.Count
    try { $script:duckRows = @([EyeAudio]::RestoreRows([string[]]$script:duckRows)) } catch { }
    if ($script:duckOwedUntil -and $script:duckRows.Count -lt $before) { Write-Log "put $($before - $script:duckRows.Count) app sound(s) back after another app let go" }
    if ($final -and $script:duckRows.Count -gt 0) { Write-Log "left $($script:duckRows.Count) app sound(s) where another app put them"; $script:duckRows = @() }
    if ($script:duckRows.Count -eq 0) { $script:duckOwedUntil = $null }
    Save-DuckRows
}
function Restore-SavedDuck {                          # at startup: undo a duck a crash left behind
    if (-not $script:audioInfo -or -not (Test-Path -LiteralPath $DuckedPath)) { return }
    try {
        $script:duckRows = @(Get-Content -LiteralPath $DuckedPath -Encoding UTF8 | Where-Object { $_ })
        $n = $script:duckRows.Count
        Pay-DuckOwed $true
        Write-Log "checked $n app sound(s) left turned down by an interrupted ding and put back the ones still down"
    } catch { Write-Log "could not restore volumes from ducked.txt: $_" }
}

function Show-Alert([string]$msg) {
    try { $tray.ShowBalloonTip(15000, 'EyeBreak', $msg, [System.Windows.Forms.ToolTipIcon]::Warning) } catch { }
}
function Play-Fallback {
    if ($script:beeped) { return }                    # one beep per sound, however many ways it fails
    $script:beeped = $true
    [System.Media.SystemSounds]::Asterisk.Play()
}

# While a sound plays, read this process's level on every output several times a second.
function Read-Levels {
    if (-not $script:playLive) { $meterTimer.Stop(); return }
    if (-not $script:audioInfo) { return }
    if ($script:optedOut -eq 0) { $script:optedOut = [EyeAudio]::OptOutOfDucking($PID) }   # a session this play just created
    $rows = [EyeAudio]::OwnLevels($PID)
    if ($null -eq $rows) { return }
    $script:levelsRead = $true
    foreach ($r in $rows) {
        $name, $v = $r -split "`t"
        $v = [double]::Parse($v, [Globalization.CultureInfo]::InvariantCulture)
        if (-not $script:levels.ContainsKey($name) -or $v -gt $script:levels[$name]) { $script:levels[$name] = $v }
    }
}
$meterTimer = New-Object System.Windows.Forms.Timer
$meterTimer.Interval = 150
$meterTimer.Add_Tick({ try { Read-Levels } catch { } })

function Handle-PlayFailure([string]$why) {
    $script:playCheckAt = $null
    $script:playLive = $false
    $meterTimer.Stop()
    Stop-Duck
    if (-not $script:retried -and $script:playPath) {
        $script:retried = $true
        $script:retryAt = [DateTime]::Now.AddSeconds(3)
        Write-Log "PLAY FAILED: $($script:playFile): $why - retrying in 3 s with a fresh player"
    } else {
        Play-Fallback
        Write-Log "PLAY FAILED: $($script:playFile): $why - system beep requested, notification shown"
        Show-Alert "A ding couldn't play ($why). Time to stand up and rest your eyes. Music software using ASIO (Ableton with ASIO4ALL) can hold the sound device."
    }
}
$onEnded = [EventHandler]{
    param($s, $e)
    if ($s -ne $script:player) { return }             # a late event from a replaced player
    $script:playCheckAt = $null
    $script:playLive = $false
    $meterTimer.Stop()
    Stop-Duck
    if (-not $script:levelsRead) { Write-Log "played to the end: $($script:playFile) (output level not readable)"; return }
    $top = $script:levels.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1
    if ($top -and $top.Value -gt 0) { Write-Log ('played to the end: {0}, sound reached {1} (signal {2:0.00} before volume)' -f $script:playFile, $top.Key, $top.Value) }
    elseif ($script:cfg.volume -le 0) { Write-Log "played to the end: $($script:playFile) (volume 0)" }
    else {
        Write-Log "PLAYED SILENT: $($script:playFile) ended but no sound reached any output - another app may hold the sound device; notification shown"
        Show-Alert "A ding played but no sound reached your speakers. Time to stand up and rest your eyes. Music software using ASIO (Ableton with ASIO4ALL) can hold the sound device."
    }
}
$onFailed = [EventHandler[System.Windows.Media.ExceptionEventArgs]]{
    param($s, $e)
    if ($s -ne $script:player) { return }
    Handle-PlayFailure $e.ErrorException.Message
}
function New-Player {
    if ($script:player) {
        try { $script:player.Remove_MediaEnded($onEnded); $script:player.Remove_MediaFailed($onFailed); $script:player.Close() } catch { }
    }
    $script:player = New-Object System.Windows.Media.MediaPlayer
    $script:player.Add_MediaEnded($onEnded)
    $script:player.Add_MediaFailed($onFailed)
}
New-Player

function Start-Playback([string]$file, [string]$what) {
    if ($script:playLive) { Write-Log "replaced before it ended: $($script:playFile)" }
    $script:playFile = Split-Path -Leaf $file
    $script:playPath = $file
    $script:playWhat = $what
    $script:playLive = $true
    $script:levels = @{}
    $script:levelsRead = $false
    $script:playCheckAt = [DateTime]::Now.AddSeconds(5)   # set before Open, in case MediaFailed is raised inside it
    $out = if ($script:audioInfo) { [EyeAudio]::DefaultOutput() } else { 'unknown output' }
    Write-Log "${what}: $($script:playFile) at volume $($script:cfg.volume), default output $out"
    try { Start-Duck } catch { Write-Log "could not turn other apps down: $_" }
    $script:optedOut = 0
    if ($script:audioInfo) { try { $script:optedOut = [EyeAudio]::OptOutOfDucking($PID) } catch { } }
    try {
        $script:player.Open([Uri]$file)
        $script:player.Volume = $script:cfg.volume
        $script:player.Play()
        $meterTimer.Start()
    } catch {
        Write-ErrorLog "play failed ($file): $_"
        Handle-PlayFailure "$_"
    }
}
function Play-Sound($name = $script:cfg.sound, [string]$fallback = 'default-ding.wav', [string]$what = 'test sound') {
    $script:beeped = $false
    $script:retried = $false
    $script:retryAt = $null
    $file = $null
    try { $file = Resolve-Sound $name $fallback } catch { Write-Log "${what}: could not pick a sound: $_" }
    if ($file) { Start-Playback $file $what; return }
    Play-Fallback                                     # no sound file yet — fall back
    Write-Log "${what}: no sound file - system beep requested"
}
# Called from the tick: runs a due retry, and five seconds after Play, a sound that neither ended nor failed must be moving.
function Confirm-Playback {
    if ($script:duckUntil -and [DateTime]::Now -ge $script:duckUntil) { Stop-Duck }
    if ($script:duckOwedUntil) { Pay-DuckOwed ([DateTime]::Now -ge $script:duckOwedUntil) }
    if ($script:retryAt -and [DateTime]::Now -ge $script:retryAt) {
        $script:retryAt = $null
        New-Player
        Start-Playback $script:playPath "retry of $($script:playWhat)"
        return
    }
    if (-not $script:playCheckAt -or [DateTime]::Now -lt $script:playCheckAt) { return }
    $script:playCheckAt = $null
    if ($script:player.Position -le [TimeSpan]::Zero) {
        try { $script:player.Stop() } catch { }
        Handle-PlayFailure 'did not start within 5 s'
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

# A due ding waits while a dictation app (holdWhileRecording) records, since those mute other audio, and plays
# 1.5 s after it stops so its unmute lands first. After 5 minutes of holding it plays anyway.
$script:holdSince = $null
$script:holdWho = ''
$script:lastRecording = [DateTime]::MinValue
function Test-Held {
    $names = @($script:cfg.holdWhileRecording | Where-Object { $_ })
    if (-not $script:audioInfo -or $names.Count -eq 0) { return $false }
    $now = [DateTime]::Now
    $who = [EyeAudio]::Recording([string[]]$names)
    if ($who) { $script:lastRecording = $now; $script:holdWho = $who }
    if (-not $who -and ($now - $script:lastRecording).TotalSeconds -ge 1.5) {
        if ($script:holdSince) { Write-Log ('{0} stopped recording: playing the ding held for {1:n0} s' -f $script:holdWho, ($now - $script:holdSince).TotalSeconds); $script:holdSince = $null }
        return $false
    }
    if (-not $script:holdSince) { $script:holdSince = $now; Write-Log "ding held: $($script:holdWho) is recording" }
    if (($now - $script:holdSince).TotalMinutes -ge 5) { Write-Log 'held 5 min, playing the ding anyway'; $script:holdSince = $null; $script:lastRecording = [DateTime]::MinValue; return $false }
    return $true
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
    elseif ($script:holdSince) { "EyeBreak - ding waits for $($script:holdWho) to stop recording" }
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
Load-Config | Out-Null
Restore-SavedDuck
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
        if ($stamp -ne $script:cfgStamp) {           # only a new interval restarts the countdown; a rejected file changes nothing
            $was = $script:cfg.intervalMinutes
            if (Load-Config) {
                if ($script:cfg.intervalMinutes -ne $was) { Reset-Timer 'intervalMinutes changed in config.json' }
                else { Write-Log 'config.json reloaded, countdown unchanged' }
            }
        }
        Sync-State
        Confirm-Playback
        if ($script:enabled -and -not $script:screenOff -and [DateTime]::Now -ge $script:nextDue -and -not (Test-Held)) { Reset-Timer; Invoke-Ding }
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
    try { Stop-Duck; if ($script:duckRows.Count -gt 0) { Pay-DuckOwed $true } } catch { }
    Write-Log 'stopped'
    if ($tray) { $tray.Visible = $false; $tray.Dispose() }
    if ($script:display) { $script:display.Close() }
    if (Test-Path $QuitFlag) { Remove-Item $QuitFlag -ErrorAction SilentlyContinue }
    $mutex.ReleaseMutex() | Out-Null
}
