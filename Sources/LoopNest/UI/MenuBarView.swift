import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("LoopNest").font(.headline)
                Spacer()
                Button { app.master.dim.toggle() } label: { Text("DIM").font(.caption.bold()) }
                    .buttonStyle(.borderedProminent).tint(app.master.dim ? Theme.orange : .gray).controlSize(.small)
            }
            HStack(spacing: 8) {
                Button { app.setMicsMuted(!(app.micStrips.first?.s.mute ?? false)) } label: {
                    Label((app.micStrips.first?.s.mute ?? false) ? "Mic muted" : "Mic live", systemImage: (app.micStrips.first?.s.mute ?? false) ? "mic.slash.fill" : "mic.fill")
                }.tint((app.micStrips.first?.s.mute ?? false) ? Theme.red : Theme.green).buttonStyle(.borderedProminent).controlSize(.small)
                Button { app.master.streamMute.toggle() } label: {
                    Label(app.master.streamMute ? "Stream muted" : "Stream live", systemImage: app.master.streamMute ? "dot.radiowaves.left.and.right.slash" : "dot.radiowaves.left.and.right")
                }.tint(app.master.streamMute ? Theme.red : Theme.green).buttonStyle(.borderedProminent).controlSize(.small)
                Spacer()
                if app.obs.connected {
                    Text(app.obs.streaming ? "OBS LIVE" : (app.obs.recording ? "OBS REC" : "OBS")).font(.caption2.bold())
                        .foregroundColor(app.obs.streaming ? Theme.red : Theme.dim)
                }
            }
            HStack {
                Image(systemName: "speaker.fill")
                Slider(value: $app.master.gainDB, in: StripSettings.minDB...6)
                Text(dbText(app.master.gainDB)).font(.caption.monospaced()).frame(width: 40)
            }
            Picker("Output", selection: Binding(get: { app.master.outputUID ?? "" },
                                                set: { app.master.outputUID = $0.isEmpty ? nil : $0; app.engine.setOutput(uid: app.master.outputUID) })) {
                Text("System default").tag("")
                ForEach(app.devices.filter { $0.outputChannels > 0 && !$0.isVirtualLoopNest }) { Text($0.name).tag($0.uid) }
            }
            if app.pads.contains(where: { !$0.isEmpty }) {
                Divider()
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                    ForEach(Array(app.pads.enumerated()).filter { !$0.element.isEmpty }, id: \.offset) { i, p in
                        Button { app.triggerPad(i) } label: { Text(p.name.isEmpty ? "Pad \(i + 1)" : p.name).font(.caption2).lineLimit(1).frame(maxWidth: .infinity) }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
            Divider()
            if app.strips.isEmpty { Text("No apps playing audio").font(.caption).foregroundColor(.secondary) }
            ForEach(app.strips) { s in MenuRow(strip: s) }
            Divider()
            HStack {
                Button(app.recorder.isRecording ? "Stop (\(Int(app.recorder.elapsed))s)" : "Record") {
                    if app.recorder.isRecording { app.recorder.stop() }
                    else { app.recorder.start(engine: app.engine, strips: app.allStrips, includeMic: app.includeMic) }
                }.tint(app.recorder.isRecording ? Theme.red : nil)
                Toggle("LoopNest off (straight to speakers or headset)", isOn: Binding(get: { app.bypass }, set: { app.setBypass($0) })).toggleStyle(.button)
                Spacer()
                Button("Open") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
                Button("Quit") { app.shutdown(); NSApp.terminate(nil) }
            }
        }.padding(14).frame(width: 340)
    }
}

struct MenuRow: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var strip: Strip
    var body: some View {
        HStack(spacing: 8) {
            if let i = strip.icon { Image(nsImage: i).resizable().frame(width: 18, height: 18) }
            Text(strip.displayName).font(.caption).frame(width: 80, alignment: .leading).lineLimit(1)
            Slider(value: Binding(get: { strip.s.gainDB }, set: { app.setGain(strip, db: $0) }), in: StripSettings.minDB...6)
            Button { app.toggleMute(strip) } label: { Image(systemName: strip.s.mute ? "speaker.slash.fill" : "speaker.wave.2.fill") }
                .buttonStyle(.plain).foregroundColor(strip.s.mute ? Theme.orange : .primary)
        }
    }
}
