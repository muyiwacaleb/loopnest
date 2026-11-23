# LoopNest status: what is built, tested and verified

Legend: **Verified** = seen working on screen or by reading real output. **Self-tested** = covered by `Test.command` (34 checks, all passing on the last run, 22 Nov). **Built** = compiles and is in the app but not checked beyond that. **Not built** = not done.

## Verified
- Stereo pan (separate left and right) on app/mic channels, Logic-style display, double-click reset
- Master-mix and stream-mix recording to 24-bit WAV; format and source persist across restart
- Broadcast meters (true peak, loudness, correlation, scope), dB scale beside meters
- Audio buffer size picker (256 accepted by output and input; shown and remembered)
- Soundboard banks 1 to 4 (selector and switching)
- Remote control over HTTP (`/state`, `/fader/<channel>/<0-1>` changed and restored a fader)
- Crash banner and settings restore after an unexpected quit
- App is close to idle when its window is hidden (about 5 percent of one core); about 25 percent when visible

## Seen on screen (new build, 22 Nov)
- A and B buttons in the toolbar, routing save/load icons on the Routing tab, and the Warmth, Brightness and Punch toggles in the channel voice panel are all present; Punch's Attack and Sustain sliders appear when switched on (and it was switched back off).
- Not yet clicked through: A/B recall, presets, routing import/export file dialogs, pad waveform.

- Channel linking: a "Link with" picker in each channel's EQ panel was seen on screen. Picking a partner (dropdowns cannot be operated in the background) and watching fader, mute and solo follow has NOT been tried.

- Soundboard queue: "When it ends, play the next pad" in the pad editor (compiles and the app starts; not tried with real sounds, so the hand-off between pads is unverified).

- Scene shortcuts: a global keyboard shortcut per scene in Settings, Scenes (compiles and starts; no shortcut has been recorded or pressed yet). Scenes can also be recalled over the remote control (HTTP /scene/<name>, OSC), which was built earlier.

## Tried by hand on screen (22 Nov, full control, settings restored afterwards)
- Submix 1: raising a channel's send made a SUBMIX 1 fader appear next to the master ("1 ch") and the "Only through the submix" switch appear; setting it back to zero removed the fader. Audio through the submix, its mute, and "only through" were not listened to.
- Channel linking: linking the mic to Zoom made their faders move together (both reached -39.4 dB) and their mutes toggle together; choosing "Not linked" stopped it. Solo link not tried.
- A/B compare: storing a mix and recalling it restored the earlier fader value and enabled Undo. One earlier recall click appeared to do nothing, and Zoom ended up at +0.5 dB in the stored mix; I did not find the cause.
- Scene schedule: I saved a scene, ticked "Recall every day at", set the time two minutes ahead, moved the mic fader to -39.4 dB, and at the chosen minute the fader jumped back to 0.0 dB on its own. Then I unticked the rule and deleted the test scene.
- Soundboard: loaded test-sounds/tone-low.wav and tone-high.wav into two pads. The waveform, its length (2.0 s) and the start marker show. With "When it ends, play the next pad" on for pad 1, pad 2 started by itself when pad 1 finished. Both pads were cleared afterwards. Sound was not listened to.
- Not tried: channel presets (file dialogs), routing save/load, scene keyboard shortcut, app-start scene rule, Warmth/Brightness/Punch by ear, solo link.

- Deck PFL: a PFL button in each deck's header (and the deck channel strips already had one). Pressing Deck A's lit both and the app stayed up; the headphone audio was not listened to.

- Remote control additions (22 Nov): /ab/a, /ab/b, /submix/<1|2>/<0-1>, /submix/<1|2>/mute, /streammute, and a fix so /pad/<number> works over HTTP (before, the trailing number was read as a value and the pad was never found). Tried over HTTP: /state, /submix/1/<value> and /pad/1 answered OK. A/B, submix mute and stream mute commands were not called. Remote control was switched back off afterwards. INTEGRATIONS.md lists every command for Stream Deck and Companion; neither program was available to test.

- Output failover: if the output device chosen for the master is unplugged, LoopNest plays through the system default and switches back when the device returns, with a message in the status line and the Health log (built, compiles and starts; no device was unplugged, so it is untested). It checks every 3 seconds, so expect a short gap. Delay compensation between outputs is not built.

- Scene automation: in Settings, Scenes, each scene can recall itself every day at a chosen time, and/or when an app or input with a matching name starts playing (the daily-time rule was seen to fire; the app-start rule has not been tried). Rules are checked every 3 seconds, do nothing while BYPASS is on, and the app-start rule ignores whatever is already open at launch. Scenes only change the mixer; nothing here starts or stops a stream or recording.

- Convolution reverb (22 Nov): the Reverb room list (FX page and shared effects panel) now also has Studio booth, Warm room, Concert hall, Tunnel with echoes and Bright plate (all convolution), plus "My own impulse response file" (a WAV or AIFF of a real room, first 4 seconds used). Seen on screen: the new rooms are listed, choosing Concert hall showed the "more processor power" note, and with the mic sent into it for about 8 seconds the app stayed up. Not heard, its CPU use not measured, the impulse-response file picker not tried. It only runs while Reverb is on and a convolution room is chosen; everything else is unchanged. Added about 20 ms of delay to the reverb return only.

- Submix tone and compressor (22 Nov): each submix strip now has an FX button with Low, Middle and High tone sliders (plus or minus 12 dB) and an "Even out loud parts" compressor with a threshold, and a Reset. Seen on screen: the button appears with the submix, the sliders and switch respond, Reset puts them back. Not heard, so whether the sound actually changes has not been checked by ear. Safe mode switches them off like other effects.

- Per-pad output (22 Nov): each pad has a "Heard by" choice: everyone (follows the Soundboard channel), the stream only, or only me. The two special choices use hidden channels that follow the Soundboard channel's fader, mute, solo and Monitor/Stream/Recording switches but do not have its EQ or effects. Seen on screen: the choice appears in the pad editor, a pad set to "Only me" played with the app staying up, and the hidden channels do not show in the console (the first build showed them; fixed). Not heard, so whether each choice sends audio to the right place has not been checked by ear or on the stream.

- Device scene trigger (22 Nov): in Settings, Scenes, a scene can also recall itself when an audio device whose name contains your text is plugged in or removed (checked about every 3 seconds). Seen on screen: the new row appears, the picker and name box respond. It has not fired, because I did not unplug a device. Older saved scene rules still load (they get the new fields switched off).

- Output delay (22 Nov): on the Stream page, "Line up the outputs" has Stream delay (what OBS, vMix or Zoom receives) and Speaker delay (what you hear on the master output), 0 to 1000 ms each, both 0 by default. Seen on screen: the sliders move, the numbers show, the app and its meters kept running with 360 ms and 230 ms set, and both were put back to 0. The actual time offset was not measured (no tool here can compare the two outputs), so treat the milliseconds as set, not verified. Extra output devices (the "Play through" device on a channel) and the recording are not delayed.

- Meeting mix, the second virtual device (22 Nov): a new "LoopNest Meeting" device (driver slot 6) carries a separate mix of only the channels whose new "Meeting" switch is on, through its own peak limiter, for Zoom, Meet or Teams (leave your own voice or anything the callers should not hear out of it). Built, all 28 self-tests still pass, and on screen the Meeting switch shows on each channel, the app starts and runs, and the Stream page says "LoopNest Meeting is not live yet". NOT verified: the device itself appearing in macOS and any sound reaching it, because that needs the driver config re-applied with your Mac password (Stream page > Restart audio / Install audio driver). User-made virtual devices are now limited to 6 (slots 0 to 5); an older device in slot 6 or 7 is moved to a free slot when the config is written. The Meeting mix has no EQ, fader or meter yet and no delay setting.

- Stream Deck and Companion add-ons (22 Nov, folder Integrations): a Companion module (actions plus lit-button feedback by polling) and a Stream Deck plugin (one command action with an optional "light when" field), and new remote commands /stream, /meeting, /monitor with a richer /state. Checked in a browser against the running app: /state shows the new fields and /meeting/MacBook/0 turned the Meeting send off and /state confirmed it (Remote control was then switched back off). NOT checked: the Companion module and the Stream Deck plugin themselves, since neither program is here; the Companion JavaScript passes a syntax check and the manifests parse. Both may need small fixes when first loaded.

- Clean slate (22 Nov, after Zoom sounded distorted): (1) LoopNest no longer picks up apps by itself. Before, any app that played sound (Zoom included) was muted at its source and replayed through LoopNest, which is the likely cause of the crackle. Apps are now only touched after you add them with "Add mic or app"; Settings > "Pick up apps automatically" (off) brings the old behaviour back. (2) The limiter, stream limiter and ducking now start OFF. (3) On first start of this build every effect in the saved settings was switched off once (master EQ, reverb, delay, filter, distortion, pitch, glue, stream processing, submixes, and each channel's voice tools and sends; faders, mutes, names and routing kept). Settings > "Turn off every effect" does the same on demand. Seen on screen: LIMIT and DIM are off, no app channel was created while Zoom was open, and the new Settings section shows. NOT heard: I did not run a Zoom call to confirm the crackle is gone. Other possible causes remain (a Bluetooth headset such as AirPods switching to its low-quality call mode while LoopNest holds it open). Scenes you saved earlier can still switch effects back on when recalled.
- Channel removal crash fixed in code (all nine audio nodes are now detached); seen working only in that the app started, not by removing a channel again.
- Build.command now signs with a fixed identity requirement so macOS should stop asking for microphone and system-audio permission after each rebuild (it asked after builds on 22 Nov); confirm by rebuilding once more and checking no prompt appears.
- Per-submix output device ("Also play on" in the submix FX popover, with "Only on that device"): built, not tested.

- Crash on removing a channel (reports at 14:57 and 17:00, both inside Apple's audio engine while nodes were detached): the engine is now paused during removal. Seen working: I added the Terminal app as a channel and removed it, and LoopNest stayed up. One try only; a channel that is playing sound was not tried.
- "LoopNest ON / OFF" toggle in the toolbar (replaces BYPASS) and the menu bar item: OFF stops capturing apps and microphones and pauses LoopNest's audio so sound goes straight to your speakers or headset. Seen: the button switches between ON and OFF and the app stays up. NOT checked by ear, and the status text at the top still says "LIVE" while OFF. Choosing which speaker or headset LoopNest itself plays to is the output name button on the Master strip.
- The permission prompts did not come back after the last two rebuilds, so the fixed signing requirement appears to work.

## Self-tested (Test.command)
Lock-free ring buffer, automatic level (AGC), noise gate, chorus/flanger/phaser/tremolo stay bounded (the self-test found and I fixed a flanger that could be 2.6 times louder than its input), stereo analyzer, loudness meter, OSC message parsing, and (28 of 28 pass) the new warmth (tape-style saturation: quiet sounds unchanged, loud peaks rounded, no bad values), brightness (exciter: adds highs, leaves lows alone) and punch (transient shaper: attack up/down changes a sound's start). Convolution reverb: output matches a direct convolution to within 0.00001, and built-in rooms decay and have a fixed level. Three-band compressor per channel ("Even out tone"): loud bass is turned down 15 dB, quiet treble and middle are unchanged. The self-test caught warmth adding 2 dB to quiet sounds; fixed.

## Built, not checked beyond compiling
- PFL pre-fader listen and headphone output picker (button lights and app stays up; no one has heard it; an earlier version crashed once and was changed)
- VCA group faders A to D
- Automatic level control in the channel voice panel (DSP is self-tested, the panel is not)
- Soundboard start trim, fade in and fade out
- OSC remote control (parsing is tested; a live OSC message has not been sent)
- vMix connection test and master mute buttons (no vMix was available)
- Feedback warning bar (built-in microphone playing through speakers)
- AIFF and FLAC recording, Recording-mix source, "Listen to stream mix"
- Warmth, Brightness and Punch toggles and sliders in the Voice tools panel (the sound processing is self-tested; the panel itself and how it sounds have not been checked by ear or on screen)
- Even-out-tone toggle and sliders in the channel voice panel (not seen on screen; not heard)
- Channel presets: "Save sound as preset..." and "Load preset..." in channel options
- A/B mix compare buttons in the toolbar (click stores, click again recalls, Option-click re-stores)
- Routing export and import buttons on the Routing tab (import drops any source that would feed a LoopNest device back into itself; the check is a name match and is untested)
- Soundboard pad waveform with start marker
- Submix buses 1 and 2: per-channel "Submix 1/2" send sliders and "Only through the submix" in channel options (seen on screen; the app starts and runs with the new audio graph), plus a fader and mute per submix that appear in the console once a channel sends there. Moving a send slider could not be done in the background, so the fader, the mute and the audio itself have NOT been checked. No self-test covers the audio graph.

- Patch tools (22 Nov, Routing tab): swap a source's left and right, make it mono, merge every source onto outputs 1 and 2, swap two output channels, copy one output channel to another, plus an orange "Feedback risk" label when a device takes a LoopNest device as input or plays to LoopNest. Self-tested (6 checks pass). Verified on screen: "Swap its left and right" for Logic Pro crossed and then restored the wires. NOT tried on screen: mono, merge, output swap/copy; not tested by ear.
- Audio Unit plug-ins (22 Nov): one insert slot on every channel (channel options) and one on the master (FX tab, bottom card), effects only (stereo), loaded outside LoopNest, state saved with the setup, auto-bypassed in Safe Mode, crash guard turns a plug-in off if it was loading when LoopNest last crashed (Settings > Allow blocked plug-ins again). Verified on screen with Apple AUDelay on the master: it lists installed plug-ins, loads without crash, its own window opens, Bypass ticks, Remove clears it. Also verified on screen: AUDelay loads on a channel (channel name/icon popover, Plug-in row) without a crash, and a master plug-in is restored after quitting and reopening LoopNest. NOT tested: audio actually passing through a plug-in (LoopNest was switched OFF during the test), restoring a plug-in's own saved settings, a channel plug-in after restart (app channels are not re-created until the app plays sound), the crash guard, third-party plug-ins, CPU cost.

- OBS gets no sound from LoopNest Stream (22 Nov, investigated, NOT resolved): OBS's source was set to the MacBook microphone and hidden (fixed in OBS); LoopNest OFF sends nothing (status line and Stream page now say so); LoopNest now re-attaches the Stream and Meeting devices when macOS changes their ID or sample rate (built, 34 self-tests pass). After the last rebuild the built-in test tone reached LoopNest's Stream meters but OBS's meter stayed silent, so audio into OBS is NOT confirmed working. Next check: Stream page > Apply (asks your password, restarts macOS audio), then re-pick LoopNest Stream in OBS and press the test tone.

## Not built
- Patchbay: full loop detection across devices beyond the simple check (see Patch tools note above)
- Per-submix outputs (sending a submix to its own device) and per-submix reverb
- VST3 and AAX plug-in hosting (not planned; Audio Units are built, see above)

## Known issues
- CPU with the Console window visible, measured with Profile.command on 22 Nov: before the change about 12 to 15 percent of one core; after moving the level meters, peak boxes and master spectrum to lightweight native drawing, 2.2 percent (top reading, one measurement, 2 channels plus Soundboard, no audio playing). Memory about 90 to 110 MB. Not measured with many channels, with the Routing or Stream pages open, or while audio is playing. The meters were looked at on screen and draw correctly; the peak box text and clearing by click were not re-tried.
- Starting a second LoopNest process (for example Test.command while the app is open) could make the first start very slowly; the buffer change at launch now runs in the background to avoid this. Not re-measured.
- Health page CPU gauge may read about twice the true value (a 6-second sample suggested about 10 to 12 percent when it showed 25).

## Delivered files
- INTEGRATIONS.md: remote control commands for Stream Deck, Companion and scripts
`build/LoopNest.app` (double-click), `Build.command`, `Test.command`, `Profile.command`, `TROUBLESHOOTING.md`, `PLUGINS.md`, this file, `backups/` (earlier builds, rename `.app-backup` to `.app` to run).

## Packaging and GitHub (22 Nov 2026)
- **Verified:** `Package.command` ran on the Mac and produced `dist/LoopNest-0.1.0.dmg` (2.6 MB) plus a .sha256 file. Local git repository created with one commit.
- **Not verified:** opening the disk image and installing from it on a clean Mac; notarization (not done, needs an Apple Developer ID); the GitHub Actions workflow (never run); `Publish.command` (never run; GitHub is not linked to the session that built this).
