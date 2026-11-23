import SwiftUI

struct MixerView: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if app.viewMode == .console {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(app.strips) { ChannelStripView(strip: $0) }
                        AddAppSlot()
                        if app.strips.isEmpty { EmptyHint().frame(width: 320) }
                    }
                    .padding(10)
                }
                VCAView().padding(.vertical, 10)
                SubmixView().padding(.vertical, 10)
                MasterStripView().padding(.trailing, 10).padding(.vertical, 10)
            } else {
                ClassicView()
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { FeedbackBanner() }
    }
}

/// Shown when a built-in microphone is being played through the Mac's own speakers (it would howl or echo).
struct FeedbackBanner: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        if let id = app.feedbackRisk, let s = app.allStrips.first(where: { $0.id == id }) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(Theme.gold)
                Text("\(s.displayName) is being played through the speakers, which can cause echo or howling. Use headphones or turn Monitor off.").font(.caption)
                Spacer()
                Button("Turn Monitor off") { s.s.toMonitor = false }.controlSize(.small)
            }
            .padding(.horizontal, 12).padding(.vertical, 6).background(Theme.gold.opacity(0.15))
        }
    }
}

struct EmptyHint: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "speaker.wave.2").font(.system(size: 30)).foregroundColor(Theme.purple)
            Text("Waiting for audio").font(.headline)
            Text("Play something in any app and it gets its own channel here.")
                .font(.caption).multilineTextAlignment(.center).foregroundColor(Theme.dim)
            if case .silent = app.captureStatus { permissionHelp }
            if case .failed = app.captureStatus { permissionHelp }
        }.padding(20)
    }
    private var permissionHelp: some View {
        VStack(spacing: 6) {
            Text("macOS may be blocking audio capture. Turn on LoopNest under System Audio Recording, then quit and reopen LoopNest.")
                .font(.caption).multilineTextAlignment(.center).foregroundColor(Theme.gold)
            Button("Open System Settings") { app.openAudioPrivacySettings() }.controlSize(.small)
        }
    }
}

/// Classic layout: one list, same engine. Playing apps first, then idle and muted. Output dial and EQ on the right.
struct ClassicView: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ScrollView {
                VStack(spacing: 6) {
                    if app.strips.isEmpty { EmptyHint() }
                    ForEach(sorted) { ClassicRow(strip: $0) }
                }.padding(10)
            }
            VStack(spacing: 12) {
                Text("OUTPUT").font(.system(size: 11, weight: .heavy, design: .rounded)).foregroundColor(Theme.gold)
                Picker("", selection: Binding(get: { app.master.outputUID ?? "" },
                                              set: { app.master.outputUID = $0.isEmpty ? nil : $0; app.engine.setOutput(uid: app.master.outputUID) })) {
                    Text("System default").tag("")
                    ForEach(app.devices.filter { $0.outputChannels > 0 && !$0.isVirtualLoopNest }) { Text($0.name).tag($0.uid) }
                }.labelsHidden().frame(width: 200)
                Knob(value: Binding(get: { pct }, set: { app.master.gainDB = $0 <= 0.01 ? StripSettings.minDB : 20 * log10($0) }),
                     range: 0...1.5, reset: 1, size: 90)
                Text("\(Int(pct * 100))%").font(.system(size: 18, weight: .bold, design: .rounded)).foregroundColor(Theme.gold)
                HStack(spacing: 6) {
                    PillButton(label: "MUTE", on: app.master.mute, tint: Theme.orange) { app.master.mute.toggle() }
                    PillButton(label: "DIM", on: app.master.dim, tint: Theme.orange) { app.master.dim.toggle() }
                }.frame(width: 200)
                Divider()
                Text("10-BAND EQ").font(.system(size: 10, weight: .bold)).foregroundColor(Theme.dim)
                HStack(spacing: 4) {
                    ForEach(0..<10, id: \.self) { i in
                        VStack(spacing: 2) {
                            VSlider(value: Binding(get: { app.master.eq[i] }, set: { app.master.eq[i] = $0 }), range: -12...12, reset: 0, width: 14)
                                .frame(width: 18, height: 90)
                            Text(eqBandLabels[i]).font(.system(size: 8)).foregroundColor(Theme.dim)
                        }
                    }
                }
                Menu("Presets") { ForEach(EQPreset.all) { p in Button(p.name) { app.master.eq = p.gains } } }.frame(width: 120)
                Spacer()
            }
            .padding(14).frame(width: 240)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
            .padding(.trailing, 10).padding(.vertical, 10)
        }
    }
    private var pct: Float { app.master.gainDB <= StripSettings.minDB ? 0 : pow(10, app.master.gainDB / 20) }
    private var sorted: [Strip] {
        app.strips.sorted { a, b in
            let ra = a.isActive && !a.s.mute ? 0 : (a.s.mute ? 2 : 1)
            let rb = b.isActive && !b.s.mute ? 0 : (b.s.mute ? 2 : 1)
            return ra != rb ? ra < rb : a.name.lowercased() < b.name.lowercased()
        }
    }
}

struct ClassicRow: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var strip: Strip
    var body: some View {
        HStack(spacing: 10) {
            if let i = strip.icon { Image(nsImage: i).resizable().frame(width: 28, height: 28) }
            VStack(alignment: .leading, spacing: 0) {
                Text(strip.displayName).lineLimit(1)
                Text(strip.s.mute ? "Muted" : (strip.isActive ? "Playing" : "Idle")).font(.system(size: 9)).foregroundColor(Theme.dim)
            }.frame(width: 130, alignment: .leading)
            Button { app.toggleMute(strip) } label: {
                Image(systemName: strip.s.mute ? "speaker.slash.fill" : "speaker.wave.2.fill").foregroundColor(strip.s.mute ? Theme.orange : Theme.text)
            }.buttonStyle(.plain)
            Slider(value: Binding(get: { strip.s.gainDB }, set: { app.setGain(strip, db: $0) }), in: StripSettings.minDB...6)
            Text(dbText(strip.s.gainDB)).font(.system(size: 11, design: .monospaced)).frame(width: 44)
            HBar(meter: strip.meter).frame(width: 90, height: 8)
        }
        .padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Theme.strip))
        .opacity(strip.isActive || strip.s.mute ? 1 : 0.65)
    }
}

struct HBar: View {
    let meter: Meter
    var body: some View { LayerMeter(meter: meter, vertical: false) }
}

/// MASTER: output device, level, mute, FX, DIM (plus limiter / mono / EQ / spectrum).
struct MasterStripView: View {
    @EnvironmentObject var app: AppState
    @LState private var showEQ = false
    @LState private var showFX = false

    private var deviceName: String {
        if let uid = app.master.outputUID, let d = app.devices.first(where: { $0.uid == uid }) { return d.name }
        return app.devices.first(where: { $0.id == CA.defaultOutput() })?.name ?? "System default"
    }
    private var pct: Int { app.master.gainDB <= StripSettings.minDB ? 0 : Int((pow(10, app.master.gainDB / 20) * 100).rounded()) }

    var body: some View {
        VStack(spacing: 8) {
            Text("MASTER").font(.system(size: 11, weight: .heavy, design: .rounded)).foregroundColor(Theme.gold)
            Menu {
                Button("System default") { app.master.outputUID = nil; app.engine.setOutput(uid: nil) }
                Divider()
                ForEach(app.devices.filter { $0.outputChannels > 0 && !$0.isVirtualLoopNest }) { d in
                    Button(d.name) { app.master.outputUID = d.uid; app.engine.setOutput(uid: d.uid) }
                }
            } label: {
                Text(deviceName).font(.system(size: 10, weight: .medium)).lineLimit(1).frame(width: 118)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden)
            SpectrumView(engine: app.engine).frame(width: 118, height: 40)
            PanKnob(value: $app.master.pan, reset: 0, size: 38).help("Pan everything you hear left / right")
            HStack(spacing: 4) {
                PillButton(label: "EQ", on: app.master.eq.contains { $0 != 0 }) { showEQ.toggle() }
                    .popover(isPresented: $showEQ) { MasterEQPopover() }
                PillButton(label: "FX", on: app.master.reverbOn || app.master.delayOn, tint: Theme.blue) { showFX.toggle() }
                    .popover(isPresented: $showFX) { FXPopover() }
            }
            HStack(spacing: 4) {
                PillButton(label: "LIMIT", on: app.master.limiterOn, tint: Theme.green) { app.master.limiterOn.toggle() }
                PillButton(label: "MONO", on: app.master.mono, tint: Theme.blue) { app.master.mono.toggle() }
            }
            HStack(spacing: 4) {
                PillButton(label: "MUTE", on: app.master.mute, tint: Theme.orange) { app.master.mute.toggle() }
                PillButton(label: "DIM", on: app.master.dim, tint: Theme.orange) { app.master.dim.toggle() }
            }
            HStack(spacing: 4) {
                VSlider(value: $app.master.gainDB, range: StripSettings.minDB...6, reset: 0, width: 34, tint: Theme.gold)
                    .frame(width: 46, height: 150)
                LevelMeter(meter: app.engine.masterMeter, height: 150)
            }
            Text("\(pct)%").font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundColor(Theme.gold)
            Text("DIM = −20 dB").font(.system(size: 8)).foregroundColor(Theme.dim)
        }
        .padding(10).frame(width: 142)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.purple.opacity(0.5), lineWidth: 1)))
    }
}

struct SpectrumView: View {
    let engine: MixerEngine
    var body: some View {
        LayerSpectrum(engine: engine)
        .padding(3).background(RoundedRectangle(cornerRadius: 4).fill(Theme.well))
        .onAppear { engine.spectrumActive = true }
        .onDisappear { engine.spectrumActive = false }
    }
}

struct MasterEQPopover: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        VStack(spacing: 10) {
            HStack { Text("Master EQ").font(.headline); Spacer(); Toggle("On", isOn: $app.master.eqEnabled).toggleStyle(.switch) }
            HStack(spacing: 8) {
                ForEach(0..<10, id: \.self) { i in
                    VStack(spacing: 4) {
                        VSlider(value: Binding(get: { app.master.eq[i] }, set: { app.master.eq[i] = $0 }), range: -12...12, reset: 0, width: 22)
                            .frame(width: 28, height: 130)
                        Text(String(format: "%+.0f", app.master.eq[i])).font(.system(size: 9, design: .monospaced))
                        Text(eqBandLabels[i]).font(.system(size: 9)).foregroundColor(.secondary)
                    }
                }
            }
            Menu("Presets") { ForEach(EQPreset.all) { p in Button(p.name) { app.master.eq = p.gains } } }
        }.padding(16).frame(width: 380)
    }
}

struct FXPopover: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Shared effects").font(.headline)
            Text("Each channel can send to these from its EQ panel. Both start off.").font(.caption).foregroundColor(.secondary)
            Toggle("Reverb", isOn: $app.master.reverbOn)
            HStack { Text("Return"); Slider(value: $app.master.reverbMix, in: 0...1) }
            ReverbRoomPicker(compact: false)
            Divider()
            Toggle("Delay", isOn: $app.master.delayOn)
            HStack { Text("Time"); Slider(value: $app.master.delayTime, in: 0.02...2); Text(String(format: "%.2fs", app.master.delayTime)).font(.caption) }
            HStack { Text("Feedback"); Slider(value: $app.master.delayFeedback, in: 0...90) }
            HStack { Text("Return"); Slider(value: $app.master.delayMix, in: 0...1) }
            Divider()
            Toggle("Ducking (lower other apps while a call app speaks)", isOn: $app.master.duckingOn)
            HStack { Text("Amount"); Slider(value: $app.master.duckAmountDB, in: -30 ... -3); Text(String(format: "%.0f dB", app.master.duckAmountDB)).font(.caption) }
        }.padding(16).frame(width: 360)
    }
}


/// VCA group faders: one fader per group (A to D) that scales every channel in that group at once.
/// The channels' own faders do not move. Shown only for groups that have channels in them.
struct VCAView: View {
    @EnvironmentObject var app: AppState
    private let names = ["A", "B", "C", "D"]
    var body: some View {
        let used = (0..<4).filter { g in app.allStrips.contains { $0.s.group == g } }
        if !used.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                ForEach(used, id: \.self) { g in
                    VStack(spacing: 6) {
                        Text("GROUP \(names[g])").font(.system(size: 9, weight: .heavy)).foregroundColor(Theme.dim)
                        PillButton(label: "MUTE", on: app.master.vcaMute[g], tint: Theme.orange) { app.master.vcaMute[g].toggle() }
                        VSlider(value: Binding(get: { app.master.vcaDB[g] }, set: { app.master.vcaDB[g] = $0 }),
                                range: StripSettings.minDB...6, reset: 0, width: 30, tint: Theme.blue)
                            .frame(width: 40, height: 150)
                        Text(dbText(app.master.vcaDB[g])).font(.system(size: 10, design: .monospaced)).foregroundColor(Theme.blue)
                        Text("\(app.allStrips.filter { $0.s.group == g }.count) ch").font(.system(size: 8)).foregroundColor(Theme.dim)
                    }
                    .padding(8).frame(width: 64)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
                    .help("Group \(names[g]) fader: scales every channel in this group without moving their own faders.")
                }
            }
        }
    }
}


/// Faders for the two submix buses; a bus appears here once any channel sends to it.
struct SubmixView: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        let used = (0..<2).filter { i in app.allStrips.contains { (i == 0 ? $0.s.sub1 : $0.s.sub2) > 0 } }
        if !used.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                ForEach(used, id: \.self) { i in
                    VStack(spacing: 6) {
                        Text("SUBMIX \(i + 1)").font(.system(size: 9, weight: .heavy)).foregroundColor(Theme.dim)
                        PillButton(label: "MUTE", on: app.master.subMute[i], tint: Theme.orange) { app.master.subMute[i].toggle() }
                        SubmixFXButton(index: i)
                        VSlider(value: Binding(get: { app.master.subDB[i] }, set: { app.master.subDB[i] = $0 }),
                                range: StripSettings.minDB...6, reset: 0, width: 30, tint: Theme.purple)
                            .frame(width: 40, height: 150)
                        Text(dbText(app.master.subDB[i])).font(.system(size: 10, design: .monospaced)).foregroundColor(Theme.purple)
                        Text("\(app.allStrips.filter { (i == 0 ? $0.s.sub1 : $0.s.sub2) > 0 }.count) ch").font(.system(size: 8)).foregroundColor(Theme.dim)
                    }
                    .padding(8).frame(width: 64)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
                    .help("Submix \(i + 1): every channel that sends here is controlled together by this fader and mute.")
                }
            }
        }
    }
}

/// Tone and compressor for one submix.
struct SubmixFXButton: View {
    @EnvironmentObject var app: AppState
    let index: Int
    @LState private var open = false
    var body: some View {
        let active = app.master.subCompOn[index] || (0..<3).contains { app.master.subTone[index * 3 + $0] != 0 }
        PillButton(label: "FX", on: active, tint: Theme.blue) { open.toggle() }
            .popover(isPresented: $open) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Submix \(index + 1) sound").font(.headline)
                    ForEach(0..<3, id: \.self) { b in
                        HStack {
                            Text(["Low", "Middle", "High"][b]).frame(width: 52, alignment: .leading)
                            Slider(value: Binding(get: { app.master.subTone[index * 3 + b] }, set: { app.master.subTone[index * 3 + b] = $0 }), in: -12...12)
                            Text(String(format: "%+.0f dB", app.master.subTone[index * 3 + b])).font(.caption).frame(width: 46)
                        }
                    }
                    Toggle("Even out loud parts (compressor)", isOn: Binding(get: { app.master.subCompOn[index] }, set: { app.master.subCompOn[index] = $0 }))
                    HStack {
                        Text("Threshold").frame(width: 70, alignment: .leading)
                        Slider(value: Binding(get: { app.master.subCompThreshold[index] }, set: { app.master.subCompThreshold[index] = $0 }), in: -50...0)
                            .disabled(!app.master.subCompOn[index])
                        Text(String(format: "%.0f dB", app.master.subCompThreshold[index])).font(.caption).frame(width: 46)
                    }
                    Divider()
                    HStack {
                        Text("Also play on").frame(width: 70, alignment: .leading)
                        Picker("", selection: Binding(get: { app.master.subOutUID[index] }, set: { app.master.subOutUID[index] = $0 })) {
                            Text("No other device").tag("")
                            ForEach(app.devices.filter { $0.outputChannels > 0 && !$0.isVirtualLoopNest }) { Text($0.name).tag($0.uid) }
                        }.labelsHidden()
                    }
                    Toggle("Only on that device (leave it out of the main, stream and recording mixes)", isOn: Binding(get: { app.master.subOutOnly[index] }, set: { app.master.subOutOnly[index] = $0 }))
                        .disabled(app.master.subOutUID[index].isEmpty)
                    Button("Reset") {
                        for b in 0..<3 { app.master.subTone[index * 3 + b] = 0 }
                        app.master.subCompOn[index] = false; app.master.subCompThreshold[index] = -18
                    }.controlSize(.small)
                }.padding(14).frame(width: 330)
            }
            .help("Tone and compressor for everything in this submix.")
    }
}
