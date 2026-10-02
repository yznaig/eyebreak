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

**Screen off** — when your monitor goes to sleep (screen goes black), dings are suspended. When it wakes, the clock restarts from that moment.

## Settings

`config.json` in the installed folder. Edits apply live.

```json
{
  "intervalMinutes": 22,
  "sound": "ding.mp3",
  "checkInEvery": 3,
  "checkInSound": "ding2.mp3",
  "volume": 1.0
}
```

- `intervalMinutes` — minutes between dings.
- `sound` — the regular ding. Set to `"random"` to shuffle through every file in `sounds` instead, or to a list like `["a.mp3", "b.mp3"]` to pick one of those at random each time.
- `checkInEvery` — every Nth ding is a check-in. `0` turns check-ins off.
- `checkInSound` — the check-in sound. Takes the same forms as `sound`.
- `volume` — `0.0` to `1.0`.

## Updating

Download the new version and run `Install.cmd` again. Your config and sounds are never overwritten.

## Uninstall

Run `Uninstall.cmd` in the installed folder. It stops the app and removes the Startup shortcut, then you delete the folder.

## How it works

`eyebreak.ps1` runs hidden (launched through `start-hidden.vbs` so no console window flashes) and ticks once a second. The tray icon is a WinForms `NotifyIcon`; sound plays through the WPF `MediaPlayer`, so anything Windows Media can decode works. Screen-off detection registers for the `GUID_CONSOLE_DISPLAY_STATE` power notification. All controls — tray menu, the `.cmd` scripts, startup — go through two flag files (`enabled.flag`, `quit.flag`), so there's one code path. If something goes wrong in the hidden process, it writes `error.log` next to the script.

Requires Windows 10 or 11. Nothing to install: PowerShell 5.1 and .NET Framework are already part of Windows.

## License

MIT
