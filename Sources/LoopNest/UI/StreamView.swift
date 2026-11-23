import SwiftUI

/// Everything for streaming: the LoopNest Stream device (what OBS / vMix hear), its level, and your mic / interface inputs.
struct StreamView: View {
    @EnvironmentObject var app: AppState

    private var inputStrips: [Strip] { app.strips.filter { $0.kind == .input } }
    private var deviceLive: Bool { CA.deviceID(forUID: StreamOutput.uid) != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                statusCard
                HStack(alignment: .top, spacing: 14) { levelCard; inputsCard }
                HStack(alignment: .top, spacing: 14) { LoudnessCard(); StreamFXCard() }
                HStack(alignment: .top, spacing: 14) { BroadcastMetersCard(); VStack(spacing: 14) { StreamMonitorCard(); CueOutputCard() } }
                HStack(alignment: .top, spacing: 14) { MixAssistCard(); HotkeysCard() }
                OBSCard(obs: app.obs)
                PermissionsCard()
                howToCard
            }.padding(16)
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle().fill(app.stream.running ? Theme.green : (app.driverInstalled ? Theme.gold : Theme.red)).frame(width: 10, height: 10)
                Text("LoopNest Stream").font(.headline)
                Spacer()
                Text(app.streamStatus).font(.caption).foregroundColor(Theme.dim)
            }
            Text("A virtual audio device that carries your stream mix. In OBS, vMix, Zoom or any app, pick **LoopNest Stream** as the microphone / audio input.")
                .font(.caption).foregroundColor(Theme.dim)
            if !app.driverInstalled {
                HStack {
                    Button("Install audio driver…") { app.installDriver() }.buttonStyle(.borderedProminent).tint(Theme.purple)
                    Text("Asks for your Mac password once, then macOS audio restarts for a few seconds.").font(.caption2).foregroundColor(Theme.dim)
                }
            } else if !deviceLive {
                HStack {
                    Button("Restart audio to add the device") { app.applyDriverConfig() }.buttonStyle(.borderedProminent).tint(Theme.purple)
                    Text("The driver is installed but doesn't have the Stream device yet.").font(.caption2).foregroundColor(Theme.dim)
                }
            } else {
                if app.bypass {
                    HStack {
                        Text("LoopNest is OFF, so nothing is being sent to LoopNest Stream or LoopNest Meeting. OBS and Zoom will hear silence.").font(.caption.bold()).foregroundColor(Theme.orange)
                        Button("Turn LoopNest ON") { app.setBypass(false) }.controlSize(.small)
                    }
                }
                Text("Device is live at \(Int(app.stream.deviceRate)) Hz · stereo").font(.caption).foregroundColor(Theme.green)
                Text(app.meeting.running ? "Second mix: **LoopNest Meeting** is live. Turn on the Meeting switch on the channels the people on a call should hear (leave their own voice out of it), then pick LoopNest Meeting as the microphone in Zoom, Meet or Teams."
                                         : "Second mix: LoopNest Meeting is not live yet. Press Apply or reinstall the driver once so macOS adds it.")
                    .font(.caption).foregroundColor(Theme.dim)
            }
            if !app.statusMessage.isEmpty { Text(app.statusMessage).font(.caption2).foregroundColor(Theme.gold) }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
    }

    private var levelCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("STREAM LEVEL").font(.system(size: 10, weight: .heavy)).foregroundColor(Theme.dim)
            HBar(meter: app.engine.streamMeter).frame(height: 10)
            HStack {
                Text("Volume").font(.caption)
                Slider(value: $app.master.streamGainDB, in: StripSettings.minDB...6)
                Text(dbText(app.master.streamGainDB) + " dB").font(.caption.monospaced()).frame(width: 60)
            }
            HStack {
                PillButton(label: "Mute stream", on: app.master.streamMute, tint: Theme.orange) { app.master.streamMute.toggle() }.frame(width: 130)
                PanKnob(value: $app.master.streamPan, reset: 0, size: 34).help("Pan the stream mix left / right")
                Button("0 dB") { app.master.streamGainDB = 0 }.controlSize(.small)
            }
            Text("The stream mix is separate from what you hear: each channel's Monitor switch controls your headphones, its Stream switch controls the stream. Master EQ and FX apply to what you hear, not the stream.")
                .font(.caption2).foregroundColor(Theme.dim)
        }
        .padding(14).frame(minWidth: 320, maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
    }

    private var inputsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("MIC & INTERFACE INPUTS").font(.system(size: 10, weight: .heavy)).foregroundColor(Theme.dim)
                Spacer()
                Menu { InputMenuItems { app.addInput($0) } } label: { Label("Add input", systemImage: "plus.circle.fill") }
                    .menuStyle(.borderlessButton).fixedSize()
            }
            if inputStrips.isEmpty {
                Menu { InputMenuItems { app.addInput($0) } } label: {
                    Label("Choose microphone…", systemImage: "mic.badge.plus").frame(maxWidth: .infinity, minHeight: 30)
                }.menuStyle(.borderlessButton)
                Text("Pick your system mic, a USB mic, or channels from an interface like a Focusrite Scarlett.")
                    .font(.caption).foregroundColor(Theme.dim)
            }
            ForEach(inputStrips) { InputRow(strip: $0) }
            Text("Tip: add the input, then use your headphones for monitoring and leave Monitor off on mics to avoid echo.")
                .font(.caption2).foregroundColor(Theme.dim)
        }
        .padding(14).frame(minWidth: 380, maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
    }

    private var howToCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("HOW TO USE IT").font(.system(size: 10, weight: .heavy)).foregroundColor(Theme.dim)
            Text("**OBS:** Sources → + → Audio Input Capture → Device: LoopNest Stream.  Turn off OBS's own Mic/Aux if you add the mic here, or you'll hear it twice.")
            Text("**vMix:** Add Input → Audio → Audio Input → Device: LoopNest Stream.")
            Text("**Zoom / Meet / Teams / Discord:** Settings → Audio → Microphone → LoopNest Stream.")
            Text("**Apps in the mix:** play music, a browser or a game and its channel appears in Console. Switch Stream on to send it to the stream.")
        }
        .font(.caption).foregroundColor(Theme.text)
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
    }
}

struct InputRow: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var strip: Strip
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "mic.fill").foregroundColor(strip.isActive ? Theme.green : Theme.red).frame(width: 18)
            Menu {
                InputMenuItems { app.changeInput(strip, to: $0) }
            } label: {
                Text(strip.displayName).font(.system(size: 12, weight: .semibold)).lineLimit(1).frame(width: 96, alignment: .leading)
            }.menuStyle(.borderlessButton).menuIndicator(.visible).fixedSize().help("Choose a different microphone or input channel")
            VStack(alignment: .leading, spacing: 0) {
                Text(strip.isActive ? "Listening" : "Not receiving").font(.system(size: 9)).foregroundColor(strip.isActive ? Theme.dim : Theme.orange)
            }
            Spacer()
            PhantomBadge(strip: strip)
            PanKnob(value: Binding(get: { (strip.s.panL + strip.s.panR) / 2 }, set: { strip.s.panL = $0; strip.s.panR = $0 }), reset: 0, size: 26).help("Pan this input left / right. Double-click to centre.")
            HBar(meter: strip.meter).frame(width: 28, height: 8)
            Slider(value: Binding(get: { strip.s.gainDB }, set: { app.setGain(strip, db: $0) }), in: StripSettings.minDB...6).frame(width: 40)
            PillButton(label: "Monitor", on: strip.s.toMonitor, tint: Theme.green) { strip.s.toMonitor.toggle() }.frame(width: 60)
            PillButton(label: "Stream", on: strip.s.toStream, tint: Theme.red) { strip.s.toStream.toggle() }.frame(width: 56)
            Button { app.removeStrip(strip) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain)
        }
        .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(Theme.strip))
    }
}


struct LoudnessCard: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        let m = app.engine.loudness
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("LOUDNESS (LUFS)").font(.system(size: 10, weight: .heavy)).foregroundColor(Theme.dim)
                Spacer()
                Button("Reset") { m.reset() }.controlSize(.mini)
            }
            LiveTimeline(0.2) {
                let t = Double(app.master.loudnessTarget)
                HStack(spacing: 18) {
                    value("Momentary", m.momentary, t)
                    value("Short-term", m.shortTerm, t)
                    value("Integrated", m.integrated, t)
                    VStack(spacing: 2) { Text(String(format: "%.1f", m.peakDB)).font(.system(size: 16, weight: .bold, design: .monospaced)); Text("Peak dBFS").font(.system(size: 9)).foregroundColor(Theme.dim) }
                }
            }
            HStack {
                Text("Target").font(.caption)
                Slider(value: $app.master.loudnessTarget, in: -24 ... -8, step: 1)
                Text(String(format: "%.0f LUFS", app.master.loudnessTarget)).font(.caption.monospaced()).frame(width: 66)
            }
            Text("Measured on the stream mix. Twitch/YouTube streams usually aim near -14 LUFS (green = within 2 LU).")
                .font(.caption2).foregroundColor(Theme.dim)
        }
        .padding(14).frame(minWidth: 320, maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
    }
    private func value(_ name: String, _ v: Double, _ target: Double) -> some View {
        let col: Color = v <= -69 ? Theme.dim : (abs(v - target) <= 2 ? Theme.green : (v > target ? Theme.orange : Theme.gold))
        return VStack(spacing: 2) {
            Text(v <= -69 ? "—" : String(format: "%.1f", v)).font(.system(size: 20, weight: .bold, design: .monospaced)).foregroundColor(col)
            Text(name).font(.system(size: 9)).foregroundColor(Theme.dim)
        }
    }
}

struct StreamFXCard: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("STREAM MIX EFFECTS").font(.system(size: 10, weight: .heavy)).foregroundColor(Theme.dim)
            Text("Only affects what OBS / vMix receive, not what you hear.").font(.caption2).foregroundColor(Theme.dim)
            Toggle("Stream EQ", isOn: $app.master.streamEQOn)
            HStack(spacing: 4) {
                ForEach(0..<10, id: \.self) { i in
                    VStack(spacing: 2) {
                        VSlider(value: Binding(get: { app.master.streamEQ[i] }, set: { app.master.streamEQ[i] = $0 }), range: -12...12, reset: 0, width: 14)
                            .frame(width: 18, height: 70)
                        Text(eqBandLabels[i]).font(.system(size: 8)).foregroundColor(Theme.dim)
                    }
                }
                Spacer()
                Menu("Presets") { ForEach(EQPreset.all) { p in Button(p.name) { app.master.streamEQ = p.gains; app.master.streamEQOn = true } } }.fixedSize()
            }.opacity(app.master.streamEQOn ? 1 : 0.5)
            Toggle("Leveler (compressor)", isOn: $app.master.streamCompOn)
            if app.master.streamCompOn {
                HStack { Text("Threshold").font(.caption).frame(width: 70, alignment: .leading); Slider(value: $app.master.streamCompThreshold, in: -50...0); Text(String(format: "%.0f dB", app.master.streamCompThreshold)).font(.caption).frame(width: 46) }
                HStack { Text("Ratio").font(.caption).frame(width: 70, alignment: .leading); Slider(value: $app.master.streamCompRatio, in: 1...10); Text(String(format: "%.1f:1", app.master.streamCompRatio)).font(.caption).frame(width: 46) }
            }
            Toggle("Limiter (stops clipping in OBS)", isOn: $app.master.streamLimiterOn)
            HStack { Text("Pre-gain").font(.caption).frame(width: 70, alignment: .leading); Slider(value: $app.master.streamPreGainDB, in: 0...24); Text(String(format: "+%.0f dB", app.master.streamPreGainDB)).font(.caption).frame(width: 46) }
            Divider()
            Text("Line up the outputs").font(.caption.bold())
            HStack { Text("Stream delay").font(.caption).frame(width: 90, alignment: .leading); Slider(value: $app.master.streamDelayMs, in: 0...1000, step: 5); Text(String(format: "%.0f ms", app.master.streamDelayMs)).font(.caption).frame(width: 56) }
            HStack { Text("Speaker delay").font(.caption).frame(width: 90, alignment: .leading); Slider(value: $app.master.monitorDelayMs, in: 0...1000, step: 5); Text(String(format: "%.0f ms", app.master.monitorDelayMs)).font(.caption).frame(width: 56) }
            Text("Stream delay holds back what OBS, vMix or Zoom receives (for a camera that lags). Speaker delay holds back what you hear on the master output. Both are 0 by default.").font(.caption2).foregroundColor(Theme.dim)
        }
        .padding(14).frame(minWidth: 380, maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
    }
}

struct PermissionsCard: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("PERMISSIONS & SETTINGS").font(.system(size: 10, weight: .heavy)).foregroundColor(Theme.dim)
                Spacer()
                Button("Save settings to file…") { app.exportSettings() }.controlSize(.small)
                Button("Load settings…") { app.importSettings() }.controlSize(.small)
            }
            row("Microphone", ok: app.micPermission == .authorized,
                detail: app.micPermission == .authorized ? "Allowed" : (app.micPermission == .notDetermined ? "Not asked yet" : "Blocked — turn it on in System Settings"),
                action: app.micPermission == .notDetermined ? ("Allow…", { app.requestMic() }) : ("Open Settings", { app.openMicSettings() }))
            row("System audio recording (app capture)", ok: { if case .failed = app.captureStatus { return false }; return true }(),
                detail: { if case .failed = app.captureStatus { return "Blocked — turn on LoopNest under System Audio Recording" }; return "No problems detected" }(),
                action: ("Open Settings", { app.openAudioPrivacySettings() }))
            row("Audio driver (LoopNest Stream)", ok: app.driverInstalled, detail: app.driverInstalled ? "Installed" : "Not installed",
                action: app.driverInstalled ? nil : ("Install…", { app.installDriver() }))
            Text("Your mixer, mics, effects, soundboard and presets are saved automatically and restored every time LoopNest opens. LoopNest is signed with a stable local certificate, so macOS keeps its permissions between updates.")
                .font(.caption2).foregroundColor(Theme.dim)
            if !app.statusMessage.isEmpty { Text(app.statusMessage).font(.caption2).foregroundColor(Theme.gold) }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
    }
    private func row(_ name: String, ok: Bool, detail: String, action: (String, () -> Void)?) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundColor(ok ? Theme.green : Theme.orange)
            Text(name).font(.system(size: 12, weight: .semibold))
            Text(detail).font(.caption).foregroundColor(Theme.dim)
            Spacer()
            if let a = action { Button(a.0, action: a.1).controlSize(.small) }
        }
    }
}


/// True peak, stereo correlation, balance and a phase scope for the stream mix.
struct BroadcastMetersCard: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        let a = app.engine.analyzer
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("BROADCAST METERS").font(.system(size: 10, weight: .heavy)).foregroundColor(Theme.dim)
                Spacer()
                Button("Reset peak") { a.reset() }.controlSize(.mini)
            }
            LiveTimeline(0.1) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(a.truePeakDB > -100 ? String(format: "%.1f dBTP", a.truePeakDB) : "-∞")
                                .font(.system(size: 18, weight: .bold, design: .rounded)).foregroundColor(a.truePeakHoldDB > -1 ? Theme.red : Theme.text)
                            Text(a.truePeakHoldDB > -100 ? String(format: "True peak · hold %.1f", a.truePeakHoldDB) : "True peak").font(.system(size: 9)).foregroundColor(Theme.dim)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text("STEREO CORRELATION").font(.system(size: 9, weight: .bold)).foregroundColor(Theme.dim)
                            GeometryReader { g in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.08))
                                    Rectangle().fill(Color.white.opacity(0.3)).frame(width: 1).offset(x: g.size.width / 2)
                                    Circle().fill(a.correlation < 0 ? Theme.red : Theme.green).frame(width: 10, height: 10)
                                        .offset(x: CGFloat((a.correlation + 1) / 2) * (g.size.width - 10))
                                }
                            }.frame(width: 170, height: 10)
                            Text(a.correlation < -0.2 ? "Out of phase: may cancel on mono speakers" : "-1 out of phase · 0 wide · +1 mono").font(.system(size: 9))
                                .foregroundColor(a.correlation < -0.2 ? Theme.red : Theme.dim)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text("BALANCE").font(.system(size: 9, weight: .bold)).foregroundColor(Theme.dim)
                            GeometryReader { g in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.08))
                                    Rectangle().fill(Color.white.opacity(0.3)).frame(width: 1).offset(x: g.size.width / 2)
                                    Circle().fill(Theme.gold).frame(width: 10, height: 10).offset(x: CGFloat((a.balance + 1) / 2) * (g.size.width - 10))
                                }
                            }.frame(width: 170, height: 10)
                        }
                    }
                    PhaseScope(analyzer: a).frame(width: 120, height: 120)
                }
            }
            Text("True peak is measured with 4× oversampling. Keep it under -1 dBTP for streaming platforms.").font(.caption2).foregroundColor(Theme.dim)
        }
        .padding(14).frame(minWidth: 380, maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
        .onAppear { a.active = true }
        .onDisappear { a.active = false }
    }
}

struct PhaseScope: View {
    let analyzer: StreamAnalyzer
    var body: some View {
        LiveTimeline(1.0 / 12.0) {
            Canvas { ctx, size in
                let r = RoundedRectangle(cornerRadius: 8).path(in: CGRect(origin: .zero, size: size))
                ctx.fill(r, with: .color(Color.black.opacity(0.35)))
                var axes = Path()
                axes.move(to: CGPoint(x: size.width / 2, y: 0)); axes.addLine(to: CGPoint(x: size.width / 2, y: size.height))
                axes.move(to: CGPoint(x: 0, y: size.height / 2)); axes.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                ctx.stroke(axes, with: .color(Color.white.opacity(0.15)), lineWidth: 1)
                let pts = analyzer.scope
                let c = CGPoint(x: size.width / 2, y: size.height / 2), sc = min(size.width, size.height) * 0.48
                for i in 0..<StreamAnalyzer.scopePoints {
                    let x = c.x + CGFloat(max(-1, min(1, pts[i * 2]))) * sc, y = c.y - CGFloat(max(-1, min(1, pts[i * 2 + 1]))) * sc
                    ctx.fill(Path(ellipseIn: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)), with: .color(Theme.green.opacity(0.7)))
                }
            }
        }
    }
}

/// Listen to a copy of the stream mix, exactly as OBS and vMix receive it.
struct CueOutputCard: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("HEADPHONES FOR PFL").font(.system(size: 10, weight: .heavy)).foregroundColor(Theme.dim)
            Picker("Device", selection: Binding(get: { app.cueDeviceUID ?? "" }, set: { app.cueDeviceUID = $0.isEmpty ? nil : $0 })) {
                Text("System output").tag("")
                ForEach(app.devices.filter { $0.outputChannels > 0 && !$0.isVirtualLoopNest }) { Text($0.name).tag($0.uid) }
            }.frame(maxWidth: 320)
            Text("Press PFL on a channel to hear it here before its fader, mute and solo. This never changes what OBS, vMix or the master output receive. PFL always starts switched off.")
                .font(.caption2).foregroundColor(Theme.dim).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14).frame(minWidth: 300, maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
    }
}

struct StreamMonitorCard: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("LISTEN TO WHAT OBS & vMIX RECEIVE").font(.system(size: 10, weight: .heavy)).foregroundColor(Theme.dim)
            Toggle("Play the stream mix on this device", isOn: $app.streamMonitorOn).toggleStyle(.switch)
            Picker("Device", selection: Binding(get: { app.streamMonitorUID ?? "" }, set: { app.streamMonitorUID = $0.isEmpty ? nil : $0 })) {
                Text("System output").tag("")
                ForEach(app.devices.filter { $0.outputChannels > 0 && !$0.isVirtualLoopNest }) { Text($0.name).tag($0.uid) }
            }.frame(maxWidth: 320)
            Text("This is the stream mix after its own EQ, leveler and limiter, before OBS touches it. Use headphones, and keep it off while your mic is live on speakers or you will hear echo. It always starts switched off.")
                .font(.caption2).foregroundColor(Theme.dim).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14).frame(minWidth: 300, maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
    }
}
