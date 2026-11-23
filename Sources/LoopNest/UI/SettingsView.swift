import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gear") }
            DevicesSettings().tabItem { Label("Devices", systemImage: "hifispeaker.2") }
            MIDISettings().tabItem { Label("MIDI", systemImage: "pianokeys") }
            ScenesSettings().tabItem { Label("Scenes", systemImage: "square.stack") }
        }.frame(width: 560, height: 460)
    }
}

struct GeneralSettings: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        Form {
            Toggle("Launch at login", isOn: Binding(get: { app.launchAtLogin }, set: { app.setLaunchAtLogin($0) }))
            Toggle("Restart LoopNest automatically if it quits unexpectedly", isOn: Binding(get: { app.autoRecover }, set: { app.setAutoRecover($0) }))
            Text("Keeps your stream audio alive. LoopNest will briefly close and reopen when you change this. Choosing Quit from the menu still quits normally.")
                .font(.caption).foregroundColor(.secondary)
            Section("Audio buffer size") {
                Picker("Buffer size", selection: $app.bufferFrames) {
                    Text("Automatic").tag(0)
                    ForEach([32, 64, 128, 256, 512, 1024, 2048], id: \.self) { Text("\($0) samples").tag($0) }
                }
                Text("Smaller buffers respond faster but are more likely to crackle on a busy computer. Larger buffers are safer for streaming. 256 or 512 suits most setups. \(app.bufferStatus)")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section("Effects and apps") {
                Button("Turn off every effect") { app.turnOffEveryEffect() }
                Text("Switches off EQ, limiter, reverb, delay, filter, distortion, pitch, compressors, ducking, voice tools and every effect send on all outputs. Faders, mutes and routing stay.")
                    .font(.caption).foregroundColor(.secondary)
                Button("Allow blocked plug-ins again") { app.engine.unblockPlugins(); app.statusMessage = "Plug-ins are allowed again." }
                Text("A plug-in that was loading when LoopNest quit unexpectedly is switched off automatically. This lets you try it again.")
                    .font(.caption).foregroundColor(.secondary)
                Toggle("Pick up apps automatically when they play sound", isOn: $app.autoAddApps)
                Text("Off by default, so LoopNest never touches Zoom, a browser or any other app until you add it yourself with Add mic or app. When on, any app that plays sound gets its own channel and is routed through LoopNest.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section("Remote control (Stream Deck, Companion, OSC)") {
                Toggle("Allow control from this computer", isOn: $app.remoteOn)
                Text("Off by default. When on, LoopNest listens only on this computer (nothing on your network can reach it). HTTP port \(String(RemoteControl.httpPort)), for example http://127.0.0.1:\(String(RemoteControl.httpPort))/mute/Browser or /fader/Browser/0.75 or /pad/3 or /scene/Show. OSC (UDP) port \(String(RemoteControl.oscPort)), for example /loopnest/fader/Browser 0.75. /state lists channel names.")
                    .font(.caption).foregroundColor(.secondary)
                if !app.remote.errorText.isEmpty { Text(app.remote.errorText).font(.caption).foregroundColor(Theme.red) }
                if !app.remote.lastCommand.isEmpty { Text("Last command: \(app.remote.lastCommand)").font(.caption.monospaced()).foregroundColor(.secondary) }
            }
            Section("vMix") {
                HStack {
                    TextField("Address", text: $app.vmixHost).textFieldStyle(.roundedBorder).frame(width: 160)
                    TextField("Port", value: $app.vmixPort, format: .number.grouping(.never)).textFieldStyle(.roundedBorder).frame(width: 70)
                    Button("Test connection") { app.vmix.test(host: app.vmixHost, port: app.vmixPort) }
                }
                HStack {
                    Button("Mute vMix master") { app.vmix.send(host: app.vmixHost, port: app.vmixPort, function: "MasterAudioOff") }
                    Button("Unmute vMix master") { app.vmix.send(host: app.vmixHost, port: app.vmixPort, function: "MasterAudioOn") }
                }
                Text(app.vmix.status).font(.caption).foregroundColor(app.vmix.connected ? Theme.green : .secondary)
                Text("In vMix, turn on Settings > Web Controller. To receive LoopNest's audio in vMix, add LoopNest Stream as an audio input. These buttons only send when you press them.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section("Virtual device driver") {
                HStack {
                    Image(systemName: app.driverInstalled ? "checkmark.circle.fill" : "xmark.circle").foregroundColor(app.driverInstalled ? Theme.green : Theme.red)
                    Text(app.driverInstalled ? "Installed" : "Not installed")
                    Spacer()
                    Button(app.driverInstalled ? "Reinstall" : "Install…") { app.installDriver() }
                    Button("Uninstall") { app.uninstallDriver() }.disabled(!app.driverInstalled)
                }
                if !app.statusMessage.isEmpty { Text(app.statusMessage).font(.caption).foregroundColor(.secondary) }
            }
            Section("Settings file") {
                HStack {
                    Button("Save settings to file…") { app.exportSettings() }
                    Button("Load settings…") { app.importSettings() }
                }
                Text("Everything is also saved automatically.").font(.caption).foregroundColor(.secondary)
            }
            Section("Recording") {
                Text(Recorder.baseFolder.path).font(.caption.monospaced())
                Button("Open recordings folder") {
                    try? FileManager.default.createDirectory(at: Recorder.baseFolder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(Recorder.baseFolder)
                }
            }
            Section("Troubleshooting") {
                Button("Restore normal audio (stop capturing apps)") { app.setBypass(true) }
                Text("If an app ever goes silent, use this or quit LoopNest — apps return to playing normally.").font(.caption).foregroundColor(.secondary)
            }
        }.formStyle(.grouped).padding()
    }
}

struct DevicesSettings: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        List(app.devices) { d in
            HStack {
                Image(systemName: d.outputChannels > 0 ? "speaker.wave.2" : "mic")
                VStack(alignment: .leading) {
                    Text(d.name)
                    Text("\(d.inputChannels) in · \(d.outputChannels) out").font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Menu(String(format: "%.1f kHz", d.sampleRate / 1000)) {
                    ForEach([44100.0, 48000, 88200, 96000, 176400, 192000], id: \.self) { r in
                        Button(String(format: "%.1f kHz", r / 1000)) { CA.setSampleRate(d.id, r) }
                    }
                }.frame(width: 90)
                if d.outputChannels > 0 { Button("Use as output") { app.setDefaultOutput(d) } }
                if d.inputChannels > 0 { Button("Use as input") { app.setDefaultInput(d) } }
            }
        }
    }
}

struct MIDISettings: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(app.midi.sourceNames.isEmpty ? "No MIDI controllers found." : "Controllers: " + app.midi.sourceNames.joined(separator: ", "))
                .font(.caption).foregroundColor(.secondary)
            if app.midi.learnTarget != nil { Text("Move a knob, slider or press a button on your controller…").foregroundColor(Theme.gold) }
            if !app.midi.lastMessage.isEmpty { Text("Last message: \(app.midi.lastMessage)").font(.caption.monospaced()) }
            List(app.midiTargets, id: \.0) { t in
                HStack {
                    Text(t.1)
                    Spacer()
                    if let b = app.midi.bindings.first(where: { $0.target == t.0 }) {
                        Text("\(b.isNote ? "Note" : "CC") \(b.number) · ch \(b.channel + 1)").font(.caption.monospaced())
                        Button("Clear") { app.midi.bindings.removeAll { $0.target == t.0 } }.controlSize(.small)
                    }
                    Button(app.midi.learnTarget == t.0 ? "Listening…" : "Learn") { app.midi.learnTarget = t.0 }.controlSize(.small)
                }
            }
        }.padding()
    }
}

struct ScenesSettings: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        List {
            if app.scenes.isEmpty { Text("No scenes yet. Use Scenes → Save current setup… in the toolbar.").foregroundColor(.secondary) }
            ForEach(app.scenes) { s in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(s.name); Spacer()
                        Button("Recall") { app.recall(s) }
                        Button("Delete", role: .destructive) { app.hotkeys["scene:\(s.id)"] = nil; app.sceneRules[s.id.uuidString] = nil; app.deleteScene(s) }
                    }
                    HotkeyRow(title: "Shortcut", action: "scene:\(s.id)")
                    let rule = Binding(get: { app.sceneRules[s.id.uuidString] ?? SceneRule() }, set: { app.sceneRules[s.id.uuidString] = $0 })
                    HStack {
                        Toggle("Recall every day at", isOn: rule.timeOn)
                        DatePicker("", selection: Binding(
                            get: { Calendar.current.date(bySettingHour: rule.wrappedValue.hour, minute: rule.wrappedValue.minute, second: 0, of: Date()) ?? Date() },
                            set: { d in let c = Calendar.current.dateComponents([.hour, .minute], from: d); var r = rule.wrappedValue; r.hour = c.hour ?? 0; r.minute = c.minute ?? 0; rule.wrappedValue = r }),
                            displayedComponents: .hourAndMinute).labelsHidden().disabled(!rule.wrappedValue.timeOn)
                    }
                    HStack {
                        Toggle("Recall when this starts playing:", isOn: rule.appOn)
                        TextField("app or input name", text: rule.appMatch).textFieldStyle(.roundedBorder).disabled(!rule.wrappedValue.appOn)
                    }
                    HStack {
                        Toggle("Recall when a device is", isOn: rule.devOn)
                        Picker("", selection: rule.devRemoved) { Text("plugged in").tag(false); Text("removed").tag(true) }
                            .labelsHidden().frame(width: 110).disabled(!rule.wrappedValue.devOn)
                        TextField("device name", text: rule.devMatch).textFieldStyle(.roundedBorder).disabled(!rule.wrappedValue.devOn)
                    }
                }.padding(.vertical, 3)
            }
        }
    }
}
