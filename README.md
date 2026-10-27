# EyeBreak

A tiny Windows tray app that dings every 22 minutes so you stand up, look away from the screen, and move a little. Every third ding plays a different sound — your cue to look around and check whether anything else needs your attention.

No installer, no dependencies. It's a single PowerShell script using what Windows already ships with.

## Install

1. Download this repo (green **Code** button → **Download ZIP**) and unzip it anywhere, or `git clone` it.
2. Double-click **`Install.cmd`**.

That copies EyeBreak to `%LOCALAPPDATA%\EyeBreak`, adds it to your Startup folder, and launches it. A green dot appears in the tray (the `^` hidden-icons area next to the clock). From now on it starts itself every time you log in.

Want it somewhere else? `Install.cmd D:\Tools\EyeBreak`.

## Your sounds

Drop two files into the `sounds` folder of the installed copy (`%LOCALAPPDATA%\EyeBreak\sounds` — right-click the tray icon → **Open folder**):

| File | Plays on |
|---|---|
| `ding.mp3` | dings 1 and 2 |
| `ding2.mp3` | ding 3 — the check-in |

MP3, WAV, MP4, M4A all work. Until you add your own, two built-in chimes are used. Changes take effect on the next ding, no restart needed.

## Using it

**Tray icon** — green = on, grey = paused. Hover to see how long until the next ding and where you are in the cycle. Double-click to toggle. Right-click for:

- **Enabled** — pause / resume (resuming restarts the 22-minute clock)
- **Reset timer** — start the countdown over
- **Play test sound** / **Play check-in sound** — hear them now
- **Open folder** — where config and sounds live
- **Quit** — stop until next login

**Scripts** in the folder, for keyboard shortcuts or Stream Deck style use: `Toggle-On.cmd`, `Toggle-Off.cmd`, `Quit.cmd`, `Start.cmd`.

**Screen off** — when your monitor goes to sleep (screen goes black), dings are suspended and the countdown pauses. When it wakes, the countdown picks up where it stopped. If the screen was off for 5 minutes or more, that counts as your break and the clock restarts instead.

## Settings

`config.json` in the installed folder. Edits apply live; only a new `intervalMinutes` restarts the countdown, and a file that doesn't parse is ignored (the previous settings stay).

```json
{
  "intervalMinutes": 22,
  "sound": "ding.mp3",
  "checkInEvery": 3,
  "checkInSound": "ding2.mp3",
  "volume": 1.0,
  "breakMinutes": 5,
  "duckOthersTo": 0.25,
  "holdWhileRecording": [],
  "notify": true
}
```

- `intervalMinutes` — minutes between dings.
- `sound` — the regular ding. Set to `"random"` to shuffle through every file in `sounds` instead, or to a list like `["a.mp3", "b.mp3"]` to pick one of those at random each time.
- `checkInEvery` — every Nth ding is a check-in. `0` turns check-ins off.
- `checkInSound` — the check-in sound. Takes the same forms as `sound`.
- `volume` — `0.0` to `1.0`.
- `duckOthersTo` — while a ding plays, other apps (music, videos) are turned down to this share of their volume, then put back. `0.25` is a quarter; `1` turns it off. If EyeBreak is stopped mid-ding, it puts them back the next time it starts.
- `notify` — `true` shows a notification next to the clock with every ding, so you still see it if you miss the sound. `false` turns it off.
- `holdWhileRecording` — apps whose microphone use makes a ding wait until they stop (or 5 minutes at most). Empty by default: dings opt out of Windows' call ducking (the "reduce other sounds by 80%" during calls and dictation, such as Wispr Flow), so they play over it at full volume. Add an app's process name, as Task Manager shows it, only if it silences other sound some other way.
- `breakMinutes` — how long the screen has to stay off to count as a break and restart the clock. Shorter than that, the countdown just pauses. `0` restarts the clock on every screen wake.

## Updating

Download the new version and run `Install.cmd` again. It stops the running copy, replaces the script, and starts it again. Your config and sounds are never overwritten; a setting your config doesn't have yet uses its default.

## Uninstall

Run `Uninstall.cmd` in the installed folder. It stops the app and removes the Startup shortcut, then you delete the folder.

## How it works

`eyebreak.ps1` runs hidden (launched through `start-hidden.vbs` so no console window flashes) and ticks once a second. The tray icon is a WinForms `NotifyIcon`; sound plays through the WPF `MediaPlayer`, so anything Windows Media can decode works. Screen-off detection registers for the `GUID_CONSOLE_DISPLAY_STATE` power notification. All controls — tray menu, the `.cmd` scripts, startup — go through two flag files (`enabled.flag`, `quit.flag`), so there's one code path. If something goes wrong in the hidden process, it writes `error.log` next to the script.

**Did it ding?** `eyebreak.log` next to the script has a line for every ding with the Windows output it went to, a line when it played to the end confirming the sound reached that output, and a line every time the clock restarted and why. If a sound fails or doesn't start within five seconds, EyeBreak retries it once with a fresh player. If that fails too, or a ding ends without any sound reaching an output, it asks Windows for the system beep and shows a notification. The log shows what reached the output, not your ears: a muted speaker or an unplugged jack still logs a level. It trims itself to the last 2000 lines once it passes 512 KB.

**Music software.** A program using an ASIO driver (for example Ableton Live with ASIO4ALL) can take over the sound device, so no other program can play through it. While it's open, dings fail or go silent; EyeBreak shows a notification instead.

Requires Windows 10 or 11. Nothing to install: PowerShell 5.1 and .NET Framework are already part of Windows.

## License

MIT
