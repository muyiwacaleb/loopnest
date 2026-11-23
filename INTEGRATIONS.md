# Controlling LoopNest from a Stream Deck, Companion, or any script

LoopNest has a built-in remote control. It is **off until you switch it on**: Settings, Remote control.
It only answers programs running on **this same Mac** (loopback), so nothing on your network can reach it.

Not tested against real Stream Deck or Companion software. The commands below are built; only the HTTP
`/state` and `/fader` commands were checked in a browser. The rest are built but not all tried.

## Plain web requests (HTTP, port 9123)

Any button that can send an HTTP GET works. Replace `Mic` with the channel's name as it shows in LoopNest
(part of the name is enough; spaces can be written `%20`). Every address starts with `http://127.0.0.1:9123`.

| Address | What it does |
|---|---|
| `/state` | Lists channels, levels, mutes, solos and scene names |
| `/mute/Mic` | Mute or unmute the channel (add `/1` to mute, `/0` to unmute) |
| `/solo/Mic` | Solo on or off |
| `/pfl/Mic` | Headphone listen on or off |
| `/fader/Mic/0.75` | Fader from 0 (silent) to 1 (+6 dB); about 0.91 is 0 dB |
| `/pan/Mic/0.5` | Pan, 0 left, 0.5 centre, 1 right |
| `/master/0.9` | Master fader |
| `/dim` and `/mono` | Toggle Dim and Mono |
| `/streammute` | Toggle the stream mix mute |
| `/pad/3` | Play or stop soundboard pad 3 (1 to 64) |
| `/pads` | Stop all pads |
| `/scene/Podcast` | Recall a saved scene by name |
| `/ab/a` and `/ab/b` | Recall mix A or B (stores it the first time) |
| `/submix/1/0.8` | Submix 1 fader, 0 to 1 |
| `/submix/1/mute` | Toggle Submix 1 mute |

A good answer is `{"ok":true,...}`; an unknown channel or command gives an error message instead.

## OSC (UDP, port 9124)

Send the same commands as OSC messages with the prefix `/loopnest`, for example `/loopnest/fader/Mic`
with the number 0.75, or `/loopnest/scene/Podcast`.

## Stream Deck

Use any plugin that sends an HTTP GET request and paste one of the addresses above. A plain "Website"
action also works but may open a browser tab each time.

## Bitfocus Companion

Add the **Generic: HTTP Requests** connection with base URL `http://127.0.0.1:9123`, then use a GET action
with the path from the table (for example `/mute/Mic`). For OSC, use **Generic: OSC** with host `127.0.0.1`
and port `9124`.

## Not included

The add-ons above are untested; the plain web commands work without them. Buttons do not light
up to show mute state). Poll `/state` from a script if you need that.

## Ready-made add-ons (folder `Integrations`, added 22 Nov, NOT yet tried in the real programs)

- `Integrations/companion-module-loopnest`: a Bitfocus Companion module (actions for mute, solo, headphone listen, Stream / Meeting / Monitor sends, faders, scenes, pads; feedback that lights buttons for muted, solo, sends, Dim, Mono, stream mute). Put the folder in Companion's developer modules folder, run `npm install` inside it, and pick "LoopNest" as a connection. The JavaScript passes a syntax check only.
- `Integrations/com.loopnest.sdPlugin`: a Stream Deck plugin with one "LoopNest command" action. Type a command such as `mute/Mic` and, to light the button, `mute:Mic`. Double-click the folder after copying it into `~/Library/Application Support/com.elgato.StreamDeck/Plugins/`. It has the manifest and code but has not been loaded into Stream Deck; its icon is the app icon at full size.
- New remote commands: `/stream/Mic`, `/meeting/Mic`, `/monitor/Mic` (add `/1` or `/0` to force on or off). `/state` now also reports pfl, monitor, stream, meeting, Dim, Mono and stream mute.
