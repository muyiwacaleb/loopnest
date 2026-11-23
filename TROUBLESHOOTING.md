# LoopNest troubleshooting

## Start here
1. **Health page** (left sidebar): shows CPU, underruns, audio restarts, your devices and an event log. "Export diagnostic report…" saves everything support would need.
2. **Restart in Safe Mode** (Health page): starts LoopNest with effects, MIDI, remote control and extra outputs switched off, to find out whether one of them is the problem.
3. **Session backups** (Health page): LoopNest copies your settings every few minutes and when you quit. Press Restore beside a backup to go back.

## "LoopNest didn't close normally last time"
LoopNest quit unexpectedly. Your settings were restored from the last backup. Press "Check devices" to confirm microphones and outputs are still there. If it keeps happening, use Safe Mode and tell me what you were doing (the event log on the Health page has the last events).

## No sound in OBS / vMix / Zoom
- Pick **LoopNest Stream** as the audio input in that app. In OBS: add or open an "Audio Input Capture" source, set Device to LoopNest Stream, and make sure its eye icon is on. (On 22 Nov this source was set to the MacBook microphone and hidden.) In OBS Studio Mode the meter shows grey until the scene is sent to Program.
- LoopNest must be ON (top right). When it shows OFF, LoopNest steps aside and nothing is sent to the Stream device.
- In LoopNest, the channel's **Stream** button must be lit (red).
- Stream page: "Mute stream" must be off and the Stream level bar should move.
- Driver installed? Settings > General > Virtual device driver. Installing asks for your password and restarts macOS audio for a moment.

## "NO SIGNAL – CHECK PERMISSION"
macOS needs to allow LoopNest to hear apps and the microphone: System Settings > Privacy & Security > Microphone and Audio Recording, then switch LoopNest on. Quit and reopen LoopNest afterwards.

## Clicks, crackle or "underruns" climbing
Settings > General > **Audio buffer size**: choose a bigger buffer (512 or 1024). Close heavy apps. Smaller buffers (64 to 128) react faster but need a quiet computer.

## Echo or howling
A microphone is being played through speakers it can hear. Use headphones, or turn the microphone channel's **Monitor** off. LoopNest shows a yellow warning bar when it sees a built-in microphone playing through the Mac's speakers.

## PFL (headphone listen) makes no sound
Choose your headphones on the Stream page ("Headphones for PFL"), then press PFL on a channel. PFL is taken before the fader, so a channel at -inf still plays in PFL.

## Remote control (Stream Deck / Companion / OSC) does nothing
Settings > General > Remote control must be on. It only listens on this computer. Try http://127.0.0.1:9123/state in a browser; it should list your channels. If it says the port is in use, another program is using 9123 or 9124.

## vMix buttons do nothing
vMix > Settings > Web Controller must be on. Settings > General > vMix > "Test connection" shows what LoopNest can reach.

## Settings look wrong after an update
Settings file section in Settings > General can export and import everything. Backups from before each build are kept in the `backups` folder (rename a `.app-backup` back to `.app` to run it).

## Building
Double-click `Build.command`. It builds the app, builds the driver, signs it and opens it. `build.log` has the full output. Double-click `Test.command` to run the built-in self-test (results in `test-results.txt`).

## New in this version: where to find things and what to do if they misbehave

- **Warmth, Brightness, Punch, Even out tone**: click a channel's name at the bottom of its strip, then scroll to "Voice tools". If the sound gets harsh or too quiet, switch the newest one off. "Bypass" in the toolbar switches them all off at once.
- **Submix 1 and 2**: in the same panel, under "Effect sends". A SUBMIX fader appears next to the master once a channel sends to it. If a channel seems silent, check that "Only through the submix" is off or that the submix is not muted.
- **Link with**: in the same panel. Linked channels share fader, mute and solo. Choose "Not linked" to separate them. Double-click a fader to put it back to 0 dB.
- **A and B buttons** (top bar): click to store the current mix, click again to recall it, Option-click to store over it. The arrow button undoes a recall.
- **Channel presets**: in the channel options, "Save sound as preset…" and "Load preset…". A preset holds the sound settings, not the name, fader or routing.
- **Routing save and load**: the two small arrow icons above the virtual-device list on the Routing tab. A loaded file never connects a LoopNest device to itself.
- **Soundboard queue**: open a pad, switch on "When it ends, play the next pad". It stops at the end of the bank.
- **Scene shortcuts**: Settings, Scenes, one Shortcut row per scene.
- **Deck PFL**: the PFL button at the top of each deck. Choose the headphone output under Stream, "Headphones for PFL".


## A plug-in made LoopNest crash or misbehave
LoopNest turns off any plug-in that was loading when it last crashed. To use it again: Settings > Effects and apps > "Allow blocked plug-ins again". In Safe Mode plug-ins stay bypassed. Only stereo effect plug-ins can be inserted; instruments are not listed.
