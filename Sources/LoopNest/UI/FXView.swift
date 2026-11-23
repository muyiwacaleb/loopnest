import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// FX rack. Every effect has a Source dropdown: the master mix (everything you hear) or any single channel.
struct FXView: View {
    @EnvironmentObject var app: AppState

    private var sources: [Strip] { app.allStrips }
    private func target(_ key: String) -> Strip? {
        guard let id = app.fxTargets[key], !id.isEmpty else { return nil }
        return sources.first { $0.id == id }
    }
    private func bind<T>(_ key: String, _ m: WritableKeyPath<MasterSettings, T>, _ c: WritableKeyPath<ChannelFX, T>) -> Binding<T> {
        Binding(get: { if let s = target(key) { return s.s.fx[keyPath: c] } else { return app.master[keyPath: m] } },
                set: { v in if let s = target(key) { s.s.fx[keyPath: c] = v; app.objectWillChange.send() } else { app.master[keyPath: m] = v } })
    }
    private func sendBind(_ key: String, reverb: Bool) -> Binding<Float> {
        Binding(get: { guard let s = sendStrip(key) else { return 0 }; return reverb ? s.s.reverbSend : s.s.delaySend },
                set: { v in guard let s = sendStrip(key) else { return }; if reverb { s.s.reverbSend = v } else { s.s.delaySend = v }; app.objectWillChange.send() })
    }
    /// Reverb and echo are sends, so they always need a channel; fall back to the first one.
    private func sendStrip(_ key: String) -> Strip? { target(key) ?? sources.first(where: { $0.kind != .board }) ?? sources.first }

    private func sourcePicker(_ key: String, allowMaster: Bool = true) -> AnyView {
        AnyView(HStack(spacing: 6) {
            Text("SOURCE").font(.system(size: 9, weight: .heavy)).foregroundColor(Theme.dim)
            Picker("", selection: Binding(get: { app.fxTargets[key] ?? (allowMaster ? "" : (sendStrip(key)?.id ?? "")) },
                                          set: { app.fxTargets[key] = $0 })) {
                if allowMaster { Text("Master mix (everything you hear)").tag("") }
                ForEach(sources) { Text($0.name).tag($0.id) }
            }.labelsHidden().frame(maxWidth: 210)
        })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Text("Effects").font(.headline)
                    Spacer()
                    Text("QUICK LOOKS ON").font(.system(size: 10, weight: .heavy)).foregroundColor(Theme.dim)
                    sourcePicker("looks")
                    ForEach(FXLook.all) { look in Button(look.name) { applyLook(look) }.controlSize(.small) }
                    Button("Reset FX") { resetLook() }.controlSize(.small)
                }
                let active = sources.filter { !$0.s.fx.activeNames.isEmpty }
                if !active.isEmpty {
                    HStack(spacing: 6) {
                        Text("ON CHANNELS").font(.system(size: 9, weight: .heavy)).foregroundColor(Theme.dim)
                        ForEach(active) { s in
                            Text("\(s.name): \(s.s.fx.activeNames.joined(separator: ", "))").font(.system(size: 10))
                                .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(Theme.purple.opacity(0.35)))
                        }
                    }
                }
                let cols = [GridItem(.adaptive(minimum: 320, maximum: 440), spacing: 14, alignment: .top)]
                LazyVGrid(columns: cols, alignment: .leading, spacing: 14) {
                    card("FILTER", "High-pass cuts rumble, low-pass softens highs. Use both for a telephone or underwater sound.", bind("filter", \.filterOn, \.filterOn), sourcePicker("filter")) {
                        knob("Low cut", bind("filter", \.hpHz, \.hpHz), 20...2000, 80, "Hz", log: true)
                        knob("High cut", bind("filter", \.lpHz, \.lpHz), 1000...20000, 8000, "Hz", log: true)
                    }
                    card("DISTORTION / LO-FI", "Warmth, grit, bitcrush, broken radio.", bind("dist", \.distOn, \.distOn), sourcePicker("dist")) {
                        Picker("", selection: bind("dist", \.distPreset, \.distPreset)) {
                            ForEach(Array(app.engine.distortionPresets.enumerated()), id: \.offset) { Text($0.element.0).tag($0.offset) }
                        }.labelsHidden().frame(width: 150)
                        knob("Mix", bind("dist", \.distMix, \.distMix), 0...100, 30, "%")
                        knob("Drive", bind("dist", \.distPregain, \.distPregain), -40...20, -6, "dB")
                    }
                    card("PITCH SHIFT", "Move the pitch up or down (100 cents = 1 semitone).", bind("pitch", \.pitchOn, \.pitchOn), sourcePicker("pitch")) {
                        knob("Cents", bind("pitch", \.pitchCents, \.pitchCents), -1200...1200, 0, "ct")
                        VStack {
                            Button("+1 st") { let b = bind("pitch", \.pitchCents, \.pitchCents); b.wrappedValue = min(1200, b.wrappedValue + 100) }.controlSize(.mini)
                            Button("−1 st") { let b = bind("pitch", \.pitchCents, \.pitchCents); b.wrappedValue = max(-1200, b.wrappedValue - 100) }.controlSize(.mini)
                        }
                    }
                    card("GLUE COMPRESSOR", "Tames loud and quiet parts so they sit together.", bind("glue", \.glueOn, \.glueOn), sourcePicker("glue")) {
                        knob("Threshold", bind("glue", \.glueThreshold, \.glueThreshold), -50...0, -20, "dB")
                        knob("Ratio", bind("glue", \.glueRatio, \.glueRatio), 1...10, 3, ":1")
                        knob("Gain", bind("glue", \.glueGain, \.glueGain), 0...20, 2, "dB")
                    }
                    card("REVERB", "One shared room. Pick a channel to set how much of it goes into the room.", $app.master.reverbOn, sources.isEmpty ? nil : sourcePicker("reverb", allowMaster: false)) {
                        ReverbRoomPicker(compact: true)
                        knob("Send", sendBind("reverb", reverb: true), 0...1, 0, "")
                        knob("Return", $app.master.reverbMix, 0...1, 0.5, "")
                    }
                    card("ECHO / DELAY", "One shared echo. Pick a channel to set how much of it is echoed.", $app.master.delayOn, sources.isEmpty ? nil : sourcePicker("delay", allowMaster: false)) {
                        knob("Time", $app.master.delayTime, 0.02...2, 0.35, "s")
                        knob("Feedback", $app.master.delayFeedback, 0...90, 30, "%")
                        knob("Send", sendBind("delay", reverb: false), 0...1, 0, "")
                        knob("Return", $app.master.delayMix, 0...1, 0.5, "")
                    }
                    card("DUCKING", "Lowers other apps while a call or voice app is speaking. (Master)", $app.master.duckingOn, nil) {
                        knob("Amount", $app.master.duckAmountDB, -30 ... -3, -12, "dB")
                    }
                    card("LIMITER", "Stops the output from clipping. (Master)", $app.master.limiterOn, nil) {
                        Text("Always last in the chain").font(.caption).foregroundColor(Theme.dim)
                    }
                }
                PluginInsert(title: "Master plug-in", id: $app.master.pluginID, bypass: $app.master.pluginBypass, slot: app.engine.masterPlugin)
                    .padding(12).background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
                Text("Channel order: EQ → Compressor → Filter → Distortion → Pitch → Glue → Faders.  Master order: Master EQ → Filter → Distortion → Pitch → Glue → Limiter → Output.  The stream mix is separate: set its own EQ and limiter on the Stream page.")
                    .font(.caption).foregroundColor(Theme.dim)
            }.padding(16)
        }
    }

    private func applyLook(_ look: FXLook) {
        guard let s = target("looks") else { look.apply(&app.master); return }
        var m = MasterSettings(); look.apply(&m)
        s.s.fx = ChannelFX(from: m)
        s.s.reverbSend = m.reverbOn ? 0.6 : 0
        s.s.delaySend = m.delayOn ? 0.5 : 0
        if m.reverbOn { app.master.reverbOn = true; app.master.reverbPreset = m.reverbPreset; app.master.reverbMix = m.reverbMix }
        if m.delayOn { app.master.delayOn = true; app.master.delayTime = m.delayTime; app.master.delayFeedback = m.delayFeedback; app.master.delayMix = m.delayMix }
        app.objectWillChange.send()
    }
    private func resetLook() {
        guard let s = target("looks") else { FXLook.reset(&app.master); return }
        s.s.fx = ChannelFX(); s.s.reverbSend = 0; s.s.delaySend = 0
        app.objectWillChange.send()
    }

    private func card<C: View>(_ title: String, _ blurb: String, _ on: Binding<Bool>, _ picker: AnyView?, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 12, weight: .heavy, design: .rounded)).foregroundColor(on.wrappedValue ? Theme.gold : Theme.dim)
                Spacer()
                Toggle("", isOn: on).toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
            if let picker = picker { picker }
            Text(blurb).font(.system(size: 10)).foregroundColor(Theme.dim).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 14) { content() }
            Spacer(minLength: 0)
        }
        .padding(12).frame(minHeight: 170, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(on.wrappedValue ? Theme.purple : Color.clear, lineWidth: 1.5)))
        .opacity(on.wrappedValue ? 1 : 0.8)
    }

    @ViewBuilder private func knob(_ name: String, _ v: Binding<Float>, _ r: ClosedRange<Float>, _ reset: Float, _ unit: String, log: Bool = false) -> some View {
        VStack(spacing: 3) {
            Knob(value: log ? Binding(get: { logPos(v.wrappedValue, r) }, set: { v.wrappedValue = fromLog($0, r) }) : v,
                 range: log ? 0...1 : r, reset: log ? logPos(reset, r) : reset, size: 46)
            Text(name).font(.system(size: 9, weight: .bold)).foregroundColor(Theme.dim)
            Text(String(format: abs(v.wrappedValue) >= 100 ? "%.0f" : "%.1f", v.wrappedValue) + (unit.isEmpty ? "" : " " + unit))
                .font(.system(size: 9, design: .monospaced))
        }
    }
    private func logPos(_ v: Float, _ r: ClosedRange<Float>) -> Float { log(v / r.lowerBound) / log(r.upperBound / r.lowerBound) }
    private func fromLog(_ p: Float, _ r: ClosedRange<Float>) -> Float { r.lowerBound * pow(r.upperBound / r.lowerBound, max(0, min(1, p))) }
}

struct FXLook: Identifiable {
    let id: String
    var name: String { id }
    let apply: (inout MasterSettings) -> Void
    static func reset(_ m: inout MasterSettings) {
        m.filterOn = false; m.distOn = false; m.pitchOn = false; m.glueOn = false; m.reverbOn = false; m.delayOn = false
    }
    static let all: [FXLook] = [
        .init(id: "Telephone") { m in reset(&m); m.filterOn = true; m.hpHz = 400; m.lpHz = 3400; m.distOn = true; m.distPreset = 8; m.distMix = 15 },
        .init(id: "Underwater") { m in reset(&m); m.filterOn = true; m.hpHz = 20; m.lpHz = 700; m.reverbOn = true; m.reverbPreset = 4; m.reverbMix = 0.5 },
        .init(id: "Lo-Fi") { m in reset(&m); m.filterOn = true; m.hpHz = 120; m.lpHz = 6000; m.distOn = true; m.distPreset = 0; m.distMix = 35 },
        .init(id: "Cathedral") { m in reset(&m); m.reverbOn = true; m.reverbPreset = 8; m.reverbMix = 0.7 },
        .init(id: "Slap echo") { m in reset(&m); m.delayOn = true; m.delayTime = 0.12; m.delayFeedback = 15; m.delayMix = 0.4 },
        .init(id: "Loud & glued") { m in reset(&m); m.glueOn = true; m.glueThreshold = -28; m.glueRatio = 4; m.glueGain = 6 },
    ]
}

/// Room choice for the shared reverb: the built-in rooms, four convolution rooms, or your own impulse response file.
struct ReverbRoomPicker: View {
    @EnvironmentObject var app: AppState
    var compact: Bool
    private func chooseFile() {
        let p = NSOpenPanel()
        p.title = "Choose an impulse response (a short recording of a room)"
        p.allowedContentTypes = [.audio]
        p.allowsMultipleSelection = false
        if p.runModal() == .OK, let u = p.url {
            app.master.reverbIRPath = u.path
            app.master.reverbPreset = 99
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(compact ? "" : "Room", selection: $app.master.reverbPreset) {
                Text("Small room").tag(0); Text("Medium room").tag(1); Text("Large room").tag(2)
                Text("Medium hall").tag(3); Text("Large hall").tag(4); Text("Plate").tag(5); Text("Cathedral").tag(8)
                Text("Studio booth (convolution)").tag(100); Text("Warm room (convolution)").tag(101)
                Text("Concert hall (convolution)").tag(102); Text("Tunnel with echoes (convolution)").tag(103)
                Text("Bright plate (convolution)").tag(104); Text("My own impulse response file").tag(99)
            }.labelsHidden().frame(width: compact ? 120 : 220)
            if app.master.reverbPreset == 99 {
                Button(app.master.reverbIRPath == nil ? "Choose file…" : "Change file…") { chooseFile() }
                Text(app.master.reverbIRPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "No file chosen: using Medium hall")
                    .font(.caption2).foregroundColor(Theme.dim).lineLimit(1)
            } else if app.master.reverbPreset >= 100 {
                Text("Convolution rooms use more processor power.").font(.caption2).foregroundColor(Theme.dim)
            }
        }
    }
}
