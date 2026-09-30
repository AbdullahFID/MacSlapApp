# MacSlapApp

Slap your MacBook and it screams back. Free, open source, no license keys.

Built by reverse-engineering [SlapMac](https://slapmac.com/) and studying [taigrr/spank](https://github.com/taigrr/spank), then rewritten from scratch in Swift with extra features on top: trackpad haptics, screen shake, backlight flashes, combo announcers, and a USB moaner.

Website: [macslap.app](https://macslap.app)

## Quick Start

**Download (no Xcode needed):** grab the latest zip from [Releases](../../releases), unzip it, and run:

```bash
cd MacSlapApp-v3.0.0
./install.sh
```

**Build from source:**

```bash
git clone https://github.com/AbdullahFID/MacSlapApp.git
cd MacSlapApp
make install
```

> **Not comfortable with git?** Click the green **Code** button → **Download ZIP**, unzip it, open Terminal, drag the folder into the Terminal window to `cd` into it, and run `make install`.

Either way, `MacSlapApp.app` lands in `/Applications`, adds itself to Login Items, and a 👋 appears in your menu bar. Slap your MacBook.

It works immediately with the built-in **Robot Voice** pack — no sound files required. Add your own sounds for the other packs (see [Sounds](#sounds)).

## Requirements

- An Apple Silicon **MacBook** (M1 Pro and M2 or later — desktops have no accelerometer)
- macOS 14 Sonoma or newer. Tested on macOS 27 Golden Gate (M5 MacBook Pro).
- To build from source: Xcode 16 or newer (Swift 6 toolchain)

## What's New in 3.0

- **Built for macOS 27.** Ships as a real `.app` bundle with an icon, which macOS 26.1+ requires for Screen Recording permission, and uses `SMAppService` for Launch at Login instead of a hand-written LaunchAgent (macOS 27's launchd refuses quarantined agent plists).
- **Works out of the box.** New built-in packs — Robot Voice (talks back with the system voice, angrier the harder you slap) and macOS Sounds — so a fresh install is never silent.
- **Real trackpad haptics.** Drives the Taptic Engine directly, so you feel the slap even with no finger on the trackpad (the old API only buzzed while you were touching it).
- **Sturdier sensor.** Recovers automatically if the accelerometer stops streaming (sleep/wake, SPU resets), wakes only the accelerometer instead of every sensor, and adapts detection timing to the sensor's real sample rate.
- **Fixed combo announcer.** Each combo tier now plays its own clip (`2_*` on a 2-hit combo, `9_*` at nine) instead of walking a flat list.
- **Screen shake rebuilt** on ScreenCaptureKit with GPU animation. It now shakes side to side (the old one only moved vertically) and never flashes a wallpaper-only capture when permission is missing.
- **New menu:** live sensor status, today's count and hardest slap, Snooze, Test Slap, sounds-folder shortcuts, pack file counts, Launch at Login toggle, update notifications.
- **Upgrading from 2.x (SlapMacPro)** is automatic: your settings and slap count carry over, and the old LaunchAgent is removed so two copies never run at once.

## Sounds

Sound files are matched by filename prefix:

| Prefix | Voice Pack |
|--------|-----------|
| `sexy_` | Sexy (escalates with sustained slapping) |
| `punch_` | Combo Hit |
| `male_` | Male |
| `fart_` | Fart |
| `gentleman_` | Gentleman |
| `yamete_` | Yamete (escalates) |
| `goat_` | Goat |
| `1_` … `9_` | Combo announcer, one tier per number |

Examples: `sexy_01.mp3`, `punch_5.wav`, `goat_scream.m4a`, `3_1.mp3`. Supported formats: mp3, wav, m4a, aac, aiff, caf.

Where MacSlapApp looks, in order:

1. A folder you pick with **Voice Pack → Choose Sounds Folder…**
2. `~/Library/Application Support/MacSlapApp/Sounds` (**Voice Pack → Open Sounds Folder**)
3. `~/Desktop/slapmac/audio` (where 2.x kept them — still read)

After adding files, use **Voice Pack → Reload Sounds**. The Voice Pack menu shows how many files each pack found. If the selected pack has none, Robot Voice fills in until you add some.

Record your own, grab free sound effects, whatever you like.

**Using SlapMac's sounds:** if you own [SlapMac](https://slapmac.com/), you can copy its 130+ sound files for personal use:

```bash
mkdir -p ~/Library/Application\ Support/MacSlapApp/Sounds
cp /Applications/slapmac.app/Contents/Resources/*.{mp3,wav} ~/Library/Application\ Support/MacSlapApp/Sounds/
```

> SlapMac's audio files are copyrighted by tonnoz. Use them locally only, and don't redistribute them.

## Menu

Click the 👋 in your menu bar (it flashes 💥 on every slap and shows 💤 while paused):

```
 Sensor: Live (805 Hz)
 Slaps: 1,234  ·  Today: 12  ·  Hardest: 3.2 g
 ─────────
 Enabled
 Snooze                 → 15 minutes, 1 hour, until tomorrow
 ─────────
 SOUND
 Voice Pack: Sexy       → packs (with file counts), built-in packs, sounds folder actions
   Volume 80%  ━━━━━●━━
 Dynamic Volume
 Sensitivity: Medium    → Extremely Sensitive … Requires Significant Force
 Cooldown: Medium       → None … Very Slow
 ─────────
 EFFECTS
 Trackpad Haptics       + intensity
 Screen Flash           + intensity
 Screen Shake           + intensity (needs Screen Recording)
 Brightness Flash       + intensity
 USB Moaner
 ─────────
 Test Slap              ⌘T
 ─────────
 Show Count in Menu Bar
 Launch at Login
 Reset Stats…
 ─────────
 Check for Updates…
 Help                   → website, GitHub, log file
 About MacSlapApp
 Quit MacSlapApp        ⌘Q
```

Everything persists between launches. **Test Slap** fires every enabled effect so you can tune them without abusing your laptop.

## Permissions

- **Slap detection, sounds, haptics, brightness, USB:** no permissions needed.
- **Screen Shake:** needs Screen Recording (it captures the screen to shake it). Turning it on asks once; if macOS doesn't prompt, use **Allow Screen Recording…** in the menu and add MacSlapApp under System Settings → Privacy & Security → Screen & System Audio Recording.

## How Detection Works

Your MacBook has a **Bosch BMI286 IMU** behind Apple's Sensor Processing Unit (`AppleSPUHIDDevice`, vendor usage page `0xFF00`, usage 3). MacSlapApp wakes it through its `AppleSPUHIDDriver`, then reads 22-byte reports with X/Y/Z as int32 Q16 fixed-point at about 805 Hz, on a dedicated thread so menus and animations never drop a sample.

Each sample goes through a single-pass impact detector tuned from real captures on an M5:

1. **Gravity removal:** a 0.5 s low-pass tracks gravity; subtracting it leaves linear acceleration.
2. **Jerk:** how fast acceleration changes, summed across axes (g/s).
3. **The gate:** a slap has high amplitude *and* high jerk at the same instant. Typing never does — its big moments are slow (the chassis rocking) and its sharp moments are tiny (key clicks). Very large hits pass on amplitude alone.
4. **Adaptive noise floor:** the amplitude bar rises on a noisy desk and stays put during an impact.
5. **Peak hold + refractory:** a 50 ms window captures true peak force, and a 140 ms lockout stops one slap's ringing from retriggering.

All windows are in seconds and scale with the measured sample rate, so machines where the IMU runs slower still detect correctly.

| Sensitivity | Amplitude | Jerk | Big hit |
|---|---|---|---|
| Extremely Sensitive | 0.15 g | 14 g/s | 0.45 g |
| High | 0.25 g | 20 g/s | 0.60 g |
| Medium | 0.40 g | 30 g/s | 0.90 g |
| Low | 0.70 g | 50 g/s | 1.50 g |
| Requires Significant Force | 1.10 g | 90 g/s | 2.20 g |

Loudness follows the peak force on a log curve, `intensity = log(1 + t·99) / log(100)`, so taps whisper and hard slaps scream.

## Private APIs Used

| API | Framework | Purpose |
|-----|-----------|---------|
| `AppleSPUHIDDevice` / `AppleSPUHIDDriver` | IOKit (undocumented service) | Accelerometer access and wake-up |
| `DisplayServicesGetBrightness` / `SetBrightness` | DisplayServices | Backlight flash |
| `MTActuatorCreateFromDeviceID` / `MTActuatorActuate` | MultitouchSupport | Taptic Engine haptics |

Private frameworks are loaded at runtime with `dlopen`, so if Apple moves one the app still launches and only that effect switches off. None of this needs SIP changes.

## Troubleshooting

Start with the first line of the menu (sensor status) and the log: **Help → Open Log File** (`~/Library/Logs/MacSlapApp/MacSlapApp.log`).

**"Sensor: No motion sensor"**
- You need an Apple Silicon MacBook. iMac, Mac mini, Mac Studio and Mac Pro don't have an accelerometer, and neither do base M1 machines.

**"Sensor: Reconnecting…" that never goes Live**
- Quit and reopen MacSlapApp. If it persists, the log says why the device couldn't be opened.

**"Apple could not verify MacSlapApp…" when opening**
- Release builds are ad-hoc signed, not notarized. Run `./install.sh` from the zip (it clears the download quarantine), or open System Settings → Privacy & Security and click **Open Anyway**.

**No sound**
- Check which pack is selected and whether it shows a file count in the Voice Pack menu. Try **Test Slap**, and make sure your Mac isn't muted.

**Screen Shake does nothing**
- It needs Screen Recording permission (see [Permissions](#permissions)). After installing a new build you may need to toggle MacSlapApp off and on in that list, since the permission is tied to the app's signature.

**Typing triggers it / slaps don't register**
- Adjust **Sensitivity**. Medium is the default; "Requires Significant Force" only reacts to firm slaps.

**USB Moaner doesn't react**
- The device must show up as a USB data device (`system_profiler SPUSBDataType`). Charge-only cables won't trigger it.

**Doesn't start at login**
- Check **Launch at Login** in the menu. If it says *Needs Approval*, click it and allow MacSlapApp in System Settings → General → Login Items.

## Uninstall

```bash
make uninstall
```

Or quit it from the menu and drag `/Applications/MacSlapApp.app` to the Trash. Your sounds (`~/Library/Application Support/MacSlapApp`) are kept.

## Development

```bash
make app        # build dist/MacSlapApp.app
make run        # build and run the bundle with logs in the terminal
make test       # detector + version tests
make release    # tests, then dist/MacSlapApp-vX.Y.Z.zip for GitHub Releases
make icon       # regenerate Resources/AppIcon.icns
```

Bump `VERSION` in the `Makefile` when cutting a release; the update checker compares it with the latest GitHub release tag.

```
Sources/
  SlapCore/                 pure Swift, unit tested
    SlapDetector.swift      impact detector
    Sensitivity.swift       sensitivity presets
    VersionComparison.swift release tag comparison
  MacSlapApp/
    AppDelegate.swift       launch, 2.x migration, login item
    MenuController.swift    menu bar UI
    SlapController.swift    sensor → detector → reactions
    AccelerometerReader.swift  IOKit SPU reader + watchdog
    AudioPlayer.swift, SoundLibrary.swift, RobotVoice.swift
    HapticFeedback.swift, ScreenShaker.swift, ScreenFlash.swift, BrightnessFlash.swift
    USBMonitor.swift, UpdateChecker.swift, LoginItem.swift, SettingsStore.swift
Tests/SlapCoreTests/        synthetic slap/typing signals
probe/                      standalone sensor diagnostics
```

## Credits

- Inspired by [SlapMac](https://slapmac.com/) by tonnoz
- Accelerometer approach from [taigrr/spank](https://github.com/taigrr/spank) and [olvvier/apple-silicon-accelerometer](https://github.com/olvvier/apple-silicon-accelerometer)
- Driver wake sequence debugging by [@godigi](https://github.com/godigi) ([#2](https://github.com/AbdullahFID/MacSlapApp/issues/2))

## License

MIT
