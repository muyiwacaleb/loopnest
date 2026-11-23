import SwiftUI
import AppKit

/// One console channel, laid out like Volume Nest's: balance knob, HI/MID/LO knobs beside the meter,
/// COMP / GRP, MUTE / SOLO, fader with dB readout, app icon at the bottom.
struct ChannelStripView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var strip: Strip
    @LState private var showEQ = false
    @LState private var showComp = false
    @LState private var showStereo = false

    private func toneBinding(_ bands: ClosedRange<Int>) -> Binding<Float> {
        Binding(get: { strip.s.eq[bands.lowerBound] },
                set: { v in for i in bands { strip.s.eq[i] = v } })
    }

    var body: some View {
        VStack(spacing: 7) {
            StereoPanView(strip: strip)
            HStack(alignment: .center, spacing: 6) {
                VStack(spacing: 5) {
                    Knob(value: toneBinding(7...9), range: -12...12, reset: 0, label: "HI", size: 26)
                    Knob(value: toneBinding(4...6), range: -12...12, reset: 0, label: "MID", size: 26)
                    Knob(value: toneBinding(0...3), range: -12...12, reset: 0, label: "LO", size: 26)
                }
                LevelMeter(meter: strip.meter, height: 124)
            }
            HStack(spacing: 4) {
                PillButton(label: "COMP", on: strip.s.compEnabled, tint: Theme.blue) { showComp.toggle() }
                    .popover(isPresented: $showComp) { CompPopover(strip: strip) }
                groupMenu
            }
            VStack(spacing: 4) {
                PillButton(label: "Monitor", on: strip.s.toMonitor, tint: Theme.green) { strip.s.toMonitor.toggle() }
                    .help("Hear this channel on your speakers / headphones")
                PillButton(label: "Stream", on: strip.s.toStream, tint: Theme.red) { strip.s.toStream.toggle() }
                    .help("Send this channel to the LoopNest Stream device (OBS, vMix, ...)")
                PillButton(label: "Meeting", on: strip.s.toMeeting, tint: Theme.blue) { strip.s.toMeeting.toggle() }
                    .help("Send this channel to the LoopNest Meeting device, a second mix for Zoom, Meet or Teams. Leave out what the people on the call should not hear.")
            }
            HStack(spacing: 4) {
                PillButton(label: "MUTE", on: strip.s.mute, tint: Theme.orange) { app.toggleMute(strip) }
                PillButton(label: "SOLO", on: strip.s.solo, tint: Theme.gold) { strip.s.solo.toggle() }
            }
            PillButton(label: "PFL", on: strip.pfl, tint: Theme.green) { strip.pfl.toggle() }
                .help("Pre-fader listen: hear this channel in your headphones before its fader, without changing what the stream or master hears. Choose the headphone output on the Stream page.")
            PillButton(label: strip.s.width != 1 || strip.s.invertL || strip.s.invertR || strip.s.modMode != 0 ? "STEREO •" : "STEREO", on: strip.s.width != 1 || strip.s.invertL || strip.s.invertR || strip.s.modMode != 0, tint: Theme.blue) { showStereo.toggle() }
                .popover(isPresented: $showStereo) { ChannelOptionsPopover(strip: strip) }
                .help("Stereo width, phase invert, channel name and colour")
            VSlider(value: Binding(get: { strip.s.gainDB }, set: { app.setGain(strip, db: $0) }),
                    range: StripSettings.minDB...6, reset: 0, width: 34)
                .frame(width: 50, height: 130)
            Text(dbText(strip.s.gainDB) + " dB").font(.system(size: 10, design: .monospaced)).foregroundColor(Theme.gold)
            Button { showEQ.toggle() } label: {
                VStack(spacing: 2) {
                    if let icon = strip.icon {
                        Image(nsImage: icon).resizable().frame(width: 30, height: 30)
                    } else {
                        Image(systemName: strip.kind == .deck ? "opticaldisc" : (strip.kind == .input ? "mic.fill" : "app")).font(.system(size: 24)).foregroundColor(Theme.dim)
                    }
                    Text(strip.displayName).font(.system(size: 9, weight: .medium)).lineLimit(1).foregroundColor(strip.isActive ? Theme.text : Theme.dim)
                        .frame(width: 92)
                }
            }
            .buttonStyle(.plain)
            .help("Click for the 10-band EQ, effect sends and ducking")
            .popover(isPresented: $showEQ) { EQPopover(strip: strip).environmentObject(app) }
        }
        .padding(.vertical, 8).padding(.horizontal, 6)
        .frame(width: 104)
        .overlay(alignment: .topLeading) {
            if strip.kind == .input { PhantomBadge(strip: strip).padding(5) }
        }
        .overlay(alignment: .topTrailing) {
            if strip.kind == .app || strip.kind == .input {
                Button { app.removeStrip(strip) } label: {
                    Image(systemName: "minus.circle.fill").font(.system(size: 15)).foregroundColor(Theme.dim)
                }
                .buttonStyle(.plain).padding(4)
                .help(strip.kind == .input ? "Remove this microphone" : "Remove this app from the mixer")
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.strip))
        .overlay(alignment: .top) {
            if strip.s.colorIdx > 0 && strip.s.colorIdx < channelColors.count {
                RoundedRectangle(cornerRadius: 2).fill(channelColors[strip.s.colorIdx]).frame(height: 4).padding(.horizontal, 10).padding(.top, 1)
            }
        }
        .opacity(strip.isActive ? 1 : 0.65)
        .contextMenu {
            Button(strip.s.armed ? "Disarm recording" : "Arm for recording") { strip.s.armed.toggle() }
            if strip.kind == .input { Menu("Change input") { InputMenuItems { app.changeInput(strip, to: $0) } } }
            if strip.kind != .deck { Button("Remove channel") { app.removeStrip(strip) } }
        }
    }

    private var groupMenu: some View {
        Menu {
            Button("No group") { strip.s.group = nil }
            ForEach(0..<4, id: \.self) { i in Button("Group \(["A", "B", "C", "D"][i])") { strip.s.group = i } }
        } label: {
            Text(strip.s.group.map { "GRP \(["A", "B", "C", "D"][$0])" } ?? "GRP")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .frame(maxWidth: .infinity, minHeight: 22)
                .foregroundColor(strip.s.group != nil ? .black : Theme.text)
                .background(RoundedRectangle(cornerRadius: 5).fill(strip.s.group != nil ? Theme.blue : Color.white.opacity(0.08)))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
    }
}

/// Menu items for choosing a microphone or audio-interface input (default mic, mono channels, stereo pairs).
struct InputMenuItems: View {
    @EnvironmentObject var app: AppState
    var onPick: (InputConfig) -> Void
    var body: some View {
        Button("System default microphone") { onPick(InputConfig(uid: "default", name: "System default microphone", offset: 0, mono: true)) }
        Divider()
        let devs = app.inputDevices()
        if devs.isEmpty { Text("No input devices found") }
        ForEach(devs) { d in
            Menu("\(d.name)  (\(d.inputChannels) in)") {
                ForEach(0..<d.inputChannels, id: \.self) { c in
                    Button("Input \(c + 1)  (mono)") { onPick(InputConfig(uid: d.uid, name: d.name, offset: c, mono: true)) }
                }
                if d.inputChannels >= 2 {
                    Divider()
                    ForEach(Array(stride(from: 0, to: d.inputChannels - 1, by: 2)), id: \.self) { c in
                        Button("Inputs \(c + 1) + \(c + 2)  (stereo)") { onPick(InputConfig(uid: d.uid, name: d.name, offset: c, mono: false)) }
                    }
                }
            }
        }
    }
}

/// "Add" slot beside the channels: microphones / interface inputs and apps.
struct AddAppSlot: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        Menu {
            Menu("Microphone / audio interface") { InputMenuItems { app.addInput($0) } }
            Divider()
            let apps = app.addableApps()
            if apps.isEmpty { Text("No other apps are using audio") }
            ForEach(apps, id: \.id) { a in Button(a.name) { app.addApp(a.members) } }
        } label: {
            VStack(spacing: 8) {
                Image(systemName: "plus.circle").font(.system(size: 26))
                Text("Add mic or app").font(.system(size: 11, weight: .semibold)).multilineTextAlignment(.center)
            }
            .foregroundColor(Theme.dim)
            .frame(width: 104, height: 400)
            .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.dim.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 104)
    }
}

struct EQPopover: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var strip: Strip
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("\(strip.name) — 10-band EQ").font(.headline)
                Spacer()
                Toggle("On", isOn: $strip.s.eqEnabled).toggleStyle(.switch)
            }
            HStack(spacing: 8) {
                ForEach(0..<10, id: \.self) { i in
                    VStack(spacing: 4) {
                        VSlider(value: Binding(get: { strip.s.eq[i] }, set: { strip.s.eq[i] = $0 }), range: -12...12, reset: 0, width: 22)
                            .frame(width: 28, height: 130)
                        Text(String(format: "%+.0f", strip.s.eq[i])).font(.system(size: 9, design: .monospaced))
                        Text(eqBandLabels[i]).font(.system(size: 9)).foregroundColor(.secondary)
                    }
                }
            }
            Menu("Presets") {
                ForEach(EQPreset.all) { p in Button(p.name) { strip.s.eq = p.gains } }
            }
            Divider()
            HStack {
                Text("Link with").frame(width: 62, alignment: .leading)
                Picker("", selection: Binding(get: { strip.s.linkTo ?? "" }, set: { new in
                    let old = strip.s.linkTo
                    if let o = old, let ps = app.allStrips.first(where: { $0.id == o }), ps.s.linkTo == strip.id { ps.s.linkTo = nil }
                    strip.s.linkTo = new.isEmpty ? nil : new
                    if !new.isEmpty, let ps = app.allStrips.first(where: { $0.id == new }) {
                        ps.s.linkTo = strip.id
                        ps.s.gainDB = strip.s.gainDB                         // start together
                    }
                })) {
                    Text("Not linked").tag("")
                    ForEach(app.allStrips.filter { $0.id != strip.id }) { Text($0.displayName).tag($0.id) }
                }.labelsHidden()
            }
            Text("Linked channels share fader, mute and solo, like a stereo pair.").font(.caption2).foregroundColor(Theme.dim)
            Divider()
            Text("Effect sends").font(.subheadline)
            HStack { Text("Reverb").frame(width: 50, alignment: .leading); Slider(value: $strip.s.reverbSend, in: 0...1) }
            HStack { Text("Delay").frame(width: 50, alignment: .leading); Slider(value: $strip.s.delaySend, in: 0...1) }
            HStack { Text("Submix 1").frame(width: 62, alignment: .leading); Slider(value: $strip.s.sub1, in: 0...1) }
            HStack { Text("Submix 2").frame(width: 62, alignment: .leading); Slider(value: $strip.s.sub2, in: 0...1) }
            if strip.s.sub1 > 0 || strip.s.sub2 > 0 {
                Toggle("Only through the submix (not directly)", isOn: $strip.s.subOnly)
                Text("A submix groups channels so one fader and mute control them together.").font(.caption2).foregroundColor(Theme.dim)
            }
            Toggle("Duck when a call app is speaking", isOn: $strip.s.duckable)
            Toggle("Record this channel to its own file", isOn: $strip.s.armed)
            Toggle("Include in the Recording mix", isOn: $strip.s.toRecord)
            HStack {
                Text("Play through").font(.subheadline)
                Spacer()
                Picker("", selection: Binding(get: { strip.s.outputUID ?? "" }, set: { strip.s.outputUID = $0.isEmpty ? nil : $0 })) {
                    Text("Main output").tag("")
                    ForEach(app.devices.filter { $0.outputChannels > 0 && !$0.isVirtualLoopNest }) { Text($0.name).tag($0.uid) }
                }.labelsHidden().frame(width: 190)
            }
            Divider()
            PluginInsert(title: "\(strip.displayName) plug-in", id: $strip.s.pluginID, bypass: $strip.s.pluginBypass, slot: strip.pluginSlot)
            Divider()
            HStack {
                Text("Voice tools").font(.subheadline)
                Spacer()
                Button("Streamer voice") { strip.s.applyStreamerVoice() }.controlSize(.small)
                    .help("Rumble filter, noise reduction, gate, de-esser, EQ and compression in one click")
            }
            Toggle("Rumble filter (high-pass)", isOn: $strip.s.hpfOn)
            Toggle("Noise reduction", isOn: $strip.s.nrOn)
            if strip.s.nrOn { HStack { Text("Amount").frame(width: 70, alignment: .leading); Slider(value: $strip.s.nrAmount, in: 0...1) } }
            Toggle("Noise gate", isOn: $strip.s.gateOn)
            if strip.s.gateOn {
                HStack { Text("Opens at").frame(width: 70, alignment: .leading); Slider(value: $strip.s.gateThreshold, in: -70 ... -20); Text(String(format: "%.0f dB", strip.s.gateThreshold)).font(.caption).frame(width: 46) }
            }
            Toggle("Automatic level (keeps your voice steady)", isOn: $strip.s.agcOn)
            if strip.s.agcOn {
                HStack { Text("Target").frame(width: 70, alignment: .leading); Slider(value: $strip.s.agcTarget, in: -30...(-8)); Text("\(Int(strip.s.agcTarget)) dB").font(.caption.monospaced()).frame(width: 50) }
                Text("Raises quiet speech and lowers loud speech, up to 12 dB either way. It holds still in silence so room noise is not boosted.").font(.caption2).foregroundColor(Theme.dim)
            }
            Toggle("Even out tone (3-band compressor)", isOn: $strip.s.mbOn)
            if strip.s.mbOn {
                HStack { Text("Above").frame(width: 70, alignment: .leading); Slider(value: $strip.s.mbThreshold, in: -50 ... -6); Text("\(Int(strip.s.mbThreshold)) dB").font(.caption.monospaced()).frame(width: 50) }
                HStack { Text("Ratio").frame(width: 70, alignment: .leading); Slider(value: $strip.s.mbRatio, in: 1...8); Text(String(format: "%.1f:1", strip.s.mbRatio)).font(.caption.monospaced()).frame(width: 50) }
                Text("Bass, middle and treble are each turned down when they get too loud, so a boomy voice or harsh top end is tamed without squashing the rest.").font(.caption2).foregroundColor(Theme.dim)
            }
            Toggle("Warmth (tape-style saturation)", isOn: $strip.s.satOn)
            if strip.s.satOn { HStack { Text("Drive").frame(width: 70, alignment: .leading); Slider(value: $strip.s.satDrive, in: 0...1) } }
            Toggle("Brightness (exciter)", isOn: $strip.s.exOn)
            if strip.s.exOn { HStack { Text("Amount").frame(width: 70, alignment: .leading); Slider(value: $strip.s.exAmount, in: 0...1) } }
            Toggle("Punch (transient shaper)", isOn: $strip.s.tsOn)
            if strip.s.tsOn {
                HStack { Text("Attack").frame(width: 70, alignment: .leading); Slider(value: $strip.s.tsAttack, in: -1...1); Text(String(format: "%+.1f", strip.s.tsAttack)).font(.caption.monospaced()).frame(width: 40) }
                HStack { Text("Sustain").frame(width: 70, alignment: .leading); Slider(value: $strip.s.tsSustain, in: -1...1); Text(String(format: "%+.1f", strip.s.tsSustain)).font(.caption.monospaced()).frame(width: 40) }
                Text("Attack makes the start of a sound sharper (or softer), Sustain lengthens (or shortens) what follows.").font(.caption2).foregroundColor(Theme.dim)
            }
            Toggle("De-esser (tames harsh S sounds)", isOn: $strip.s.deessOn)
            if strip.s.deessOn { HStack { Text("Amount").frame(width: 70, alignment: .leading); Slider(value: $strip.s.deessAmount, in: 0...1) } }
            HStack {
                Text("Sync delay").frame(width: 70, alignment: .leading)
                Slider(value: $strip.s.delayMs, in: 0...1000)
                Text(String(format: "%.0f ms", strip.s.delayMs)).font(.caption).frame(width: 52)
            }
        }
        .padding(16).frame(width: 400)
    }
}

struct CompPopover: View {
    @ObservedObject var strip: Strip
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(strip.name) — Compressor").font(.headline)
                Spacer()
                Toggle("On", isOn: $strip.s.compEnabled).toggleStyle(.switch)
            }
            row("Threshold", value: $strip.s.compThreshold, range: -40...0, fmt: "%.0f dB")
            row("Ratio", value: $strip.s.compRatio, range: 1...20, fmt: "%.1f : 1")
            row("Makeup", value: $strip.s.compMakeup, range: 0...24, fmt: "%.0f dB")
            row("Attack", value: $strip.s.compAttack, range: 0.001...0.2, fmt: "%.3f s")
            row("Release", value: $strip.s.compRelease, range: 0.01...1, fmt: "%.2f s")
        }
        .padding(16).frame(width: 340)
    }
    private func row(_ title: String, value: Binding<Float>, range: ClosedRange<Float>, fmt: String) -> some View {
        HStack {
            Text(title).frame(width: 70, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: fmt, value.wrappedValue)).font(.system(size: 11, design: .monospaced)).frame(width: 64, alignment: .trailing)
        }
    }
}


/// Stereo width, phase invert, your own name and a colour tag for one channel.
struct ChannelOptionsPopover: View {
    @ObservedObject var strip: Strip
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CHANNEL").font(.system(size: 10, weight: .heavy)).foregroundColor(Theme.dim)
            TextField("Name (\(strip.name))", text: $strip.s.label).textFieldStyle(.roundedBorder).frame(width: 240)
            HStack {
                Button("Save sound as preset…") { ChannelPreset.save(strip.s, name: strip.displayName) }.controlSize(.small)
                Button("Load preset…") { if let p = ChannelPreset.load() { strip.s.applyPreset(p) } }.controlSize(.small)
            }
            Text("A preset holds this channel's EQ, compressor, effects and voice tools (not its name, fader, pan or routing).").font(.caption2).foregroundColor(Theme.dim)
            HStack(spacing: 6) {
                ForEach(0..<channelColors.count, id: \.self) { i in
                    ZStack {
                        Circle().fill(i == 0 ? Color.white.opacity(0.1) : channelColors[i]).frame(width: 20, height: 20)
                        if i == 0 { Image(systemName: "slash.circle").font(.system(size: 12)).foregroundColor(Theme.dim) }
                        if strip.s.colorIdx == i { Circle().stroke(Color.white, lineWidth: 2).frame(width: 24, height: 24) }
                    }
                    .onTapGesture { strip.s.colorIdx = i }
                }
            }
            if strip.dspPan {
                Divider()
                HStack {
                    Text("Width").frame(width: 60, alignment: .leading)
                    Slider(value: $strip.s.width, in: 0...2).frame(width: 150)
                    Text("\(Int(strip.s.width * 100))%").font(.caption.monospaced()).frame(width: 44)
                    Button("100%") { strip.s.width = 1 }.controlSize(.mini)
                }
                Text("0% makes the channel mono, 100% leaves it alone, above 100% widens it.").font(.caption2).foregroundColor(Theme.dim)
                HStack(spacing: 8) {
                    Toggle("Invert left phase", isOn: $strip.s.invertL)
                    Toggle("Invert right phase", isOn: $strip.s.invertR)
                }
                Text("Phase invert fixes microphones that cancel each other out.").font(.caption2).foregroundColor(Theme.dim)
                Divider()
                Text("MODULATION").font(.system(size: 10, weight: .heavy)).foregroundColor(Theme.dim)
                Picker("Effect", selection: $strip.s.modMode) {
                    ForEach(0..<ModFX.names.count, id: \.self) { Text(ModFX.names[$0]).tag($0) }
                }.frame(width: 240)
                if strip.s.modMode != 0 {
                    HStack { Text("Rate").frame(width: 60, alignment: .leading); Slider(value: $strip.s.modRate, in: 0.05...8).frame(width: 150); Text(String(format: "%.2f Hz", strip.s.modRate)).font(.caption.monospaced()).frame(width: 58) }
                    HStack { Text("Depth").frame(width: 60, alignment: .leading); Slider(value: $strip.s.modDepth, in: 0...1).frame(width: 150); Text("\(Int(strip.s.modDepth * 100))%").font(.caption.monospaced()).frame(width: 58) }
                    if strip.s.modMode != 4 {
                        HStack { Text("Mix").frame(width: 60, alignment: .leading); Slider(value: $strip.s.modMix, in: 0...1).frame(width: 150); Text("\(Int(strip.s.modMix * 100))%").font(.caption.monospaced()).frame(width: 58) }
                    }
                }
            } else {
                Text("Width and phase invert are available on app and microphone channels.").font(.caption2).foregroundColor(Theme.dim)
            }
        }
        .padding(14)
    }
}


/// Save and load a channel's sound as a small file you can share or reuse on another channel.
enum ChannelPreset {
    static func save(_ s: StripSettings, name: String) {
        let p = NSSavePanel(); p.nameFieldStringValue = "\(name).loopnestpreset"
        guard p.runModal() == .OK, let url = p.url else { return }
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: url) }
    }
    static func load() -> StripSettings? {
        let p = NSOpenPanel(); p.allowsMultipleSelection = false
        guard p.runModal() == .OK, let url = p.url, let d = try? Data(contentsOf: url) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: d) else { return nil }
        return Persist.merged(obj, StripSettings())      // older or partial presets still load
    }
}
