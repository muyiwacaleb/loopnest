# LoopNest architecture

LoopNest is a SwiftUI app (Swift Package, no Xcode project) plus a small C Audio Server plug-in (the virtual devices) and a C lock-free ring buffer.

```
Package.swift            targets: CRing (C), LoopNest (Swift executable)
Sources/CRing            lock-free single-producer/single-consumer ring (cring_create/write/read/reset)
Sources/LoopNest
  LoopNestApp.swift      app entry, windows, toolbar (LoopNest ON/OFF), --selftest switch
  Model/                 plain data + persistence
    Models.swift         Codable settings: StripSettings, MasterSettings, scenes, pads, virtual device config
    AppState.swift       the one ObservableObject: owns the engine, applies settings, driver install, remote commands
    PatchOps.swift       pure patchbay edits (swap, split, mono, merge) + feedback-loop check
    Persist.swift        tolerant loading (new fields get defaults)
    Maintenance.swift    backups, crash detection, Safe Mode
  Audio/                 everything that touches sound
    MixerEngine.swift    AVAudioEngine graph (strips, submixes, master, stream, meeting, recording buses)
    Capture.swift        per-app capture with Core Audio process taps
    StreamOutput.swift   plays the Stream / Meeting mix into the virtual device (one AVAudioEngine each)
    AuxOutput.swift, Router.swift, RingPlayer.swift   extra output devices and virtual-device routing
    PluginHost.swift     Audio Unit insert slots (out of process), crash guard, state save/restore
    VoiceDSP.swift, ModFX.swift, Convolver.swift      own DSP (gate, AGC, de-esser, chorus..., convolution reverb)
    Recorder.swift, DJDeck.swift, SoundBoard.swift, MIDIManager.swift, Hotkeys.swift
    RemoteControl.swift  loopback HTTP 9123 / OSC UDP 9124 (off by default)
    OBSLink.swift, VMixLink.swift                     optional integrations
    SelfTest.swift       34 automated checks; run with `LoopNest --selftest`
  UI/                    SwiftUI views (Console, Classic, Routing, Stream, FX, Soundboard, Decks, Record, Health, Settings)
Driver/LoopNestDriver.c  Audio Server plug-in (HAL): up to 8 loopback devices, ring per device
Integrations/            Bitfocus Companion module and Stream Deck plug-in (talk to the remote control)
Resources/               Info.plist, entitlements, icon
```

## Audio graph (MixerEngine)
`strip source -> EQ -> compressor -> filter -> distortion -> pitch -> glue -> [plug-in insert] -> strip mixer`, which feeds: master bus, reverb and delay sends, stream bus, recording bus, two submixes and the meeting bus.
`master bus -> master EQ -> master FX -> [plug-in] -> limiter -> monitor delay -> output mixer -> output`.
`stream bus -> EQ -> leveler -> limiter -> delay -> [analyzer sink, feed sink]`; the feed sink writes to a ring that `StreamOutput` plays into the LoopNest Stream device. The meeting bus works the same way for LoopNest Meeting.

## Virtual devices
`Driver/LoopNestDriver.c` publishes devices described in `/Library/Application Support/LoopNest/devices.plist` (`slot`, `name`, `channels`). Slots 0-5 are user devices, **6 = LoopNest Meeting, 7 = LoopNest Stream**. Whatever a client plays to a device's output appears on its input (ring of 16384 frames per device, shared timeline from `GetZeroTimeStamp`). The app installs the driver and rewrites the plist with administrator rights (`AppState.installDriver / applyDriverConfig`), then restarts `coreaudiod`.

## Rules the code follows (please keep them)
1. **Audio threads must not lock, allocate or do file I/O.** Use the C ring or atomics; render blocks only read/write memory they already own.
2. **Never change the AVAudioEngine graph while it runs.** `engine.pause()` first, change, then start. Detaching/reconnecting a running engine crashes (EXC_BAD_ACCESS in UpdateGraphAfterReconfig). See `removeStrip`, `setOutput`, `PluginHost.replace`.
3. **New persisted fields need defaults** so older saved settings still load (`Persist` is tolerant; `SoundPad` and `SceneRule` have custom decoders).
4. **No fake controls.** If a control is visible it must do something and be listed honestly in `STATUS.md` as verified, self-tested or untested.
5. **Prevent feedback and gain runaway.** Default effects are off; patchbay edits go through `PatchOps.loopProblems`.
6. **Never start or stop a broadcast without the user's explicit action.**
7. Swift tools 5.9; use `@LState` (not `@State`) naming already in the code base and `MixScene` (not `Scene`) to avoid SwiftUI name clashes.

## Adding things
- **A new effect on channels:** add fields (with defaults) to `StripSettings`, build the node in `Strip`, wire it in `MixerEngine` (paused), apply it in `apply(_:)`, add UI in `ChannelStripView`/`FXView`, add a check in `SelfTest.swift`.
- **A new remote command:** extend `AppState.remoteCommand`, document it in `INTEGRATIONS.md`.
- **A new patchbay operation:** add a pure function to `PatchOps`, a self-test, then a menu item in `RoutingView`.
