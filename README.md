# LoopNest

A Mac app that combines virtual audio devices and routing (like Rogue Amoeba Loopback) with a per-app mixer, effects, recording and broadcast tools (like Volume Nest). It can feed OBS, vMix, Zoom, Teams and any app through its own virtual microphones: **LoopNest Stream**, **LoopNest Meeting**, and devices you create.

* Requires macOS 14.4+. No third-party dependencies.
* License: MIT.

## Documentation
| | |
|---|---|
| [docs/INSTALL.md](docs/INSTALL.md) | Install, build, package a disk image, sign and notarize |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | How the code and the driver fit together, rules for contributors |
| [CONTRIBUTING.md](CONTRIBUTING.md) | How to contribute and test |
| [STATUS.md](STATUS.md) | Honest list of what is verified, self-tested, built, untested, not built, and known issues |
| [TROUBLESHOOTING.md](TROUBLESHOOTING.md) | Fixes for common problems (no sound in OBS, crackle, permissions...) |
| [INTEGRATIONS.md](INTEGRATIONS.md) | Remote control (HTTP/OSC), Stream Deck, Companion |
| [PLUGINS.md](PLUGINS.md) | Audio Unit hosting notes |
| [CHANGELOG.md](CHANGELOG.md) | Versions |

## Quick start
```
./Package.command   # builds dist/LoopNest-<version>.dmg
./Build.command     # builds build/LoopNest.app only
./Test.command      # 34 self-tests
./Publish.command   # puts the project on your GitHub account
```
Then follow docs/INSTALL.md.

---

A Mac app that combines the ideas of Rogue Amoeba's Loopback (virtual audio devices + routing)
and Volume Nest (per-app mixer) in one window, with a few extras from similar tools.

## Build it (no Xcode needed) - details in docs/INSTALL.md
1. Double-click **Build.command**. If macOS blocks it: right-click → Open.
2. If asked, install Apple's Command Line Tools, then double-click it again.
3. LoopNest.app appears in `build/` and launches. Drag it to Applications if you like.

## First run
* Allow **System Audio Recording** for LoopNest (System Settings → Privacy & Security) and restart the app.
  Play something — the app appears as a channel strip.
* For virtual devices: Routing tab → New Virtual Device → **Install Driver…** (asks for your password;
  restarts macOS audio briefly).

## Features
Mixer (VolumeNest-style): per-app fader / pan / mute / solo / meters, 10-band EQ + presets, compressor,
shared reverb + delay sends, call-app ducking, groups A–D, scenes + undo, master EQ / limiter / DIM / mono,
spectrum, recording (mix + per-app + mic, 24-bit WAV), MIDI learn, two DJ decks (cues, loops, key-lock tempo),
Console and Classic layouts, menu-bar mixer.

Routing (Loopback-style): up to 8 virtual devices of 2–64 channels, apps and input devices as sources,
drag-to-wire channel routing, per-source volume / mute / on-off, monitoring on any output,
silence-original-apps, Pass-Thru devices.

Extras: output-device switcher, per-device sample-rate control, launch at login, Restore-normal-audio panic button.

## Known limits
See [STATUS.md](STATUS.md). In short: tested on one Mac; the OBS-receives-no-sound problem is open; VST3/AAX hosting is not planned; the app is ad-hoc signed, not notarized.
