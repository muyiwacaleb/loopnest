import SwiftUI
import AppKit

/// Recording screen: arm tracks, transport, elapsed clock, "Recording N files at 48000 Hz".
struct RecordView: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Button {
                    if app.recorder.isRecording { app.recorder.stop() }
                    else { app.recorder.start(engine: app.engine, strips: app.allStrips, includeMic: app.includeMic) }
                } label: {
                    HStack {
                        Image(systemName: app.recorder.isRecording ? "stop.fill" : "circle.fill").foregroundColor(Theme.red)
                        Text(app.recorder.isRecording ? "Stop" : "Record").font(.system(size: 13, weight: .bold))
                    }.frame(width: 100)
                }.controlSize(.large)
                Text(clock(app.recorder.elapsed)).font(.system(size: 28, weight: .bold, design: .monospaced))
                    .foregroundColor(app.recorder.isRecording ? Theme.red : Theme.dim)
                VStack(alignment: .leading) {
                    Text(app.recorder.isRecording ? "● REC" : "READY").font(.system(size: 11, weight: .heavy)).foregroundColor(app.recorder.isRecording ? Theme.red : Theme.dim)
                    Text(app.recorder.isRecording ? app.recorder.status : "\(fileCount) file\(fileCount == 1 ? "" : "s") at \(Int(app.engine.format.sampleRate)) Hz · \(Recorder.formatNames[app.recorder.format])").font(.caption).foregroundColor(Theme.dim)
                    if app.recorder.isRecording { Text(String(format: "%.1f MB%@", Double(app.recorder.sizeBytes) / 1_048_576, app.recorder.dropped > 0 ? " · DROPPED \(app.recorder.dropped) frames" : " · no dropouts")).font(.caption).foregroundColor(app.recorder.dropped > 0 ? Theme.red : Theme.dim) }
                    else if !app.recorder.status.isEmpty { Text(app.recorder.status).font(.caption).foregroundColor(Theme.dim) }
                }
                Spacer()
                Button("Open folder") {
                    try? FileManager.default.createDirectory(at: Recorder.baseFolder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(app.recorder.lastFolder ?? Recorder.baseFolder)
                }
            }
            HStack(spacing: 14) {
                Picker("Main track", selection: Binding(get: { app.recorder.mainSource }, set: { app.recorder.mainSource = $0 })) {
                    ForEach(0..<Recorder.sourceNames.count, id: \.self) { Text(Recorder.sourceNames[$0]).tag($0) }
                }.frame(width: 430).disabled(app.recorder.isRecording)
                Picker("Format", selection: Binding(get: { app.recorder.format }, set: { app.recorder.format = $0 })) {
                    ForEach(0..<Recorder.formatNames.count, id: \.self) { Text(Recorder.formatNames[$0]).tag($0) }
                }.frame(width: 200).disabled(app.recorder.isRecording)
                Button("Choose folder…") {
                    let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
                    p.directoryURL = Recorder.baseFolder
                    if p.runModal() == .OK { Recorder.setBaseFolder(p.url); app.objectWillChange.send() }
                }.disabled(app.recorder.isRecording)
                if UserDefaults.standard.string(forKey: "recDir") != nil { Button("Use default") { Recorder.setBaseFolder(nil); app.objectWillChange.send() }.disabled(app.recorder.isRecording) }
            }
            Divider()
            Text("TRACKS").font(.system(size: 10, weight: .heavy)).foregroundColor(Theme.dim)
            ScrollView {
                VStack(spacing: 6) {
                    trackRow(icon: nil, name: Recorder.sourceFile[app.recorder.mainSource], sub: Recorder.sourceNames[app.recorder.mainSource], armed: .constant(true), fixed: true, meter: app.recorder.mainSource == 1 ? app.engine.streamMeter : app.engine.masterMeter)
                    ForEach(app.allStrips) { s in StripTrackRow(strip: s) }
                    HStack {
                        Image(systemName: "mic.fill").foregroundColor(Theme.purple).frame(width: 28)
                        VStack(alignment: .leading) { Text("Microphone"); Text("Default input, own file").font(.system(size: 9)).foregroundColor(Theme.dim) }
                        Spacer()
                        Toggle("", isOn: $app.includeMic).labelsHidden()
                    }.padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Theme.strip))
                }
            }
            Text("Files start together and stay aligned. They go to \(Recorder.baseFolder.path). While recording, audio is written to a safe temporary file, so if LoopNest quits unexpectedly it is recovered next time.").font(.caption).foregroundColor(Theme.dim)
        }.padding(16)
    }

    private var fileCount: Int { 1 + app.allStrips.filter { $0.s.armed }.count + (app.includeMic ? 1 : 0) }
    private func clock(_ t: TimeInterval) -> String { String(format: "%02d:%02d:%02d", Int(t) / 3600, (Int(t) / 60) % 60, Int(t) % 60) }

    private func trackRow(icon: NSImage?, name: String, sub: String, armed: Binding<Bool>, fixed: Bool, meter: Meter) -> some View {
        HStack {
            Image(systemName: "waveform").foregroundColor(Theme.gold).frame(width: 28)
            VStack(alignment: .leading) { Text(name); Text(sub).font(.system(size: 9)).foregroundColor(Theme.dim) }
            Spacer()
            HBar(meter: meter).frame(width: 160, height: 8)
            Text("ARMED").font(.system(size: 9, weight: .bold)).foregroundColor(Theme.red).frame(width: 56)
        }.padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Theme.strip))
    }
}

struct StripTrackRow: View {
    @ObservedObject var strip: Strip
    var body: some View {
        HStack {
            if let i = strip.icon { Image(nsImage: i).resizable().frame(width: 28, height: 28) } else { Image(systemName: "app").frame(width: 28) }
            VStack(alignment: .leading) { Text(strip.displayName); Text(strip.isActive ? "Playing" : "Idle").font(.system(size: 9)).foregroundColor(Theme.dim) }
            Spacer()
            HBar(meter: strip.meter).frame(width: 160, height: 8)
            Toggle("Rec mix", isOn: $strip.s.toRecord).toggleStyle(.checkbox).font(.system(size: 10)).help("Include this channel in the Recording mix")
            Button(strip.s.armed ? "ARMED" : "ARM") { strip.s.armed.toggle() }
                .buttonStyle(.plain).font(.system(size: 9, weight: .bold))
                .foregroundColor(strip.s.armed ? .black : Theme.text)
                .frame(width: 56, height: 20)
                .background(RoundedRectangle(cornerRadius: 4).fill(strip.s.armed ? Theme.red : Color.white.opacity(0.1)))
        }.padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Theme.strip))
    }
}
