import SwiftUI
import UniformTypeIdentifiers
import AppKit
import AVFoundation

/// Click a pad to play, click again to stop. Drop audio files onto pads. Right-click or Edit for volume, loop, ducking and a global shortcut.
struct SoundboardView: View {
    @EnvironmentObject var app: AppState
    @LState private var editing: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Soundboard").font(.headline)
                Text("Plays into the Soundboard channel in Console, so it has its own volume plus Monitor and Stream switches.")
                    .font(.caption).foregroundColor(Theme.dim)
                Spacer()
                Picker("Bank", selection: $app.padBank) {
                    ForEach(0..<4, id: \.self) { b in Text("Bank \(b + 1)\(app.pads[(b * 16)..<(b * 16 + 16)].contains { !$0.isEmpty } ? " •" : "")").tag(b) }
                }.pickerStyle(.segmented).frame(width: 300).labelsHidden()
                Button("Stop all sounds") { app.soundboard.stopAll() }.controlSize(.small)
            }
            let cols = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)
            LazyVGrid(columns: cols, spacing: 10) {
                ForEach((app.padBank * 16)..<(app.padBank * 16 + 16), id: \.self) { i in
                    PadButton(index: i, onEdit: { editing = i })
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            if let i = editing { PadEditor(index: i, close: { editing = nil }).environmentObject(app) }
        }
    }
}

struct PadButton: View {
    @EnvironmentObject var app: AppState
    let index: Int
    var onEdit: () -> Void
    private let colors: [Color] = [Theme.purple, Theme.blue, Theme.green, Theme.gold, Theme.orange, Theme.red, Color(red: 0.8, green: 0.4, blue: 0.8), Color(red: 0.3, green: 0.8, blue: 0.8)]

    var body: some View {
        let pad = app.pads[index]
        let on = app.soundboard.playing.contains(pad.id)
        let c = colors[index % colors.count]
        Button {
            if pad.isEmpty { onEdit() } else { app.triggerPad(index) }
        } label: {
            VStack(spacing: 4) {
                if pad.isEmpty {
                    Image(systemName: "plus").font(.system(size: 22))
                    Text("Add sound").font(.system(size: 11))
                } else {
                    Image(systemName: on ? "stop.fill" : (pad.loop ? "repeat" : "play.fill")).font(.system(size: 18))
                    Text(pad.name.isEmpty ? URL(fileURLWithPath: pad.path).deletingPathExtension().lastPathComponent : pad.name)
                        .font(.system(size: 12, weight: .semibold)).lineLimit(2).multilineTextAlignment(.center)
                    if let hk = app.hotkeys["pad:\(pad.id)"] { Text(hk.display).font(.system(size: 9, design: .monospaced)).opacity(0.8) }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 96)
            .foregroundColor(pad.isEmpty ? Theme.dim : (on ? .black : .white))
            .background(RoundedRectangle(cornerRadius: 12).fill(pad.isEmpty ? Theme.strip : (on ? c : c.opacity(0.35)))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(pad.isEmpty ? Theme.dim.opacity(0.4) : c, style: StrokeStyle(lineWidth: 1.5, dash: pad.isEmpty ? [5, 4] : []))))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Edit…") { onEdit() }
            if !pad.isEmpty { Button("Clear pad") { app.soundboard.stop(pad.id); app.hotkeys["pad:\(pad.id)"] = nil; app.pads[index] = SoundPad() } }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { app.pads[index].path = url.path; if app.pads[index].name.isEmpty { app.pads[index].name = url.deletingPathExtension().lastPathComponent } }
            }
            return true
        }
    }
}

struct PadEditor: View {
    @EnvironmentObject var app: AppState
    let index: Int
    var close: () -> Void

    var body: some View {
        let id = app.pads[index].id
        VStack(alignment: .leading, spacing: 12) {
            Text("Pad \(index + 1)").font(.headline)
            HStack {
                Text(app.pads[index].isEmpty ? "No sound chosen" : URL(fileURLWithPath: app.pads[index].path).lastPathComponent).lineLimit(1).font(.caption)
                Spacer()
                Button(app.pads[index].isEmpty ? "Choose sound…" : "Change…") {
                    let p = NSOpenPanel(); p.allowedContentTypes = [.audio]; p.allowsMultipleSelection = false
                    if p.runModal() == .OK, let u = p.url {
                        app.pads[index].path = u.path
                        if app.pads[index].name.isEmpty { app.pads[index].name = u.deletingPathExtension().lastPathComponent }
                    }
                }
            }
            TextField("Name", text: $app.pads[index].name).textFieldStyle(.roundedBorder)
            HStack { Text("Volume").frame(width: 60, alignment: .leading); Slider(value: $app.pads[index].gainDB, in: -30...6) { _ in app.soundboard.updateVolume(app.pads[index]) }
                Text(String(format: "%+.0f dB", app.pads[index].gainDB)).font(.caption.monospaced()).frame(width: 52) }
            if !app.pads[index].isEmpty { WaveformView(path: app.pads[index].path, start: app.pads[index].startSec) }
            HStack { Text("Start at").frame(width: 60, alignment: .leading); Slider(value: $app.pads[index].startSec, in: 0...30)
                Text(String(format: "%.1f s", app.pads[index].startSec)).font(.caption.monospaced()).frame(width: 52) }
            HStack { Text("Fade in").frame(width: 60, alignment: .leading); Slider(value: $app.pads[index].fadeInSec, in: 0...5)
                Text(String(format: "%.1f s", app.pads[index].fadeInSec)).font(.caption.monospaced()).frame(width: 52) }
            HStack { Text("Fade out").frame(width: 60, alignment: .leading); Slider(value: $app.pads[index].fadeOutSec, in: 0...5)
                Text(String(format: "%.1f s", app.pads[index].fadeOutSec)).font(.caption.monospaced()).frame(width: 52) }
            Text("Fade out happens when you press the pad again to stop it.").font(.caption2).foregroundColor(Theme.dim)
            Picker("Heard by", selection: $app.pads[index].route) {
                Text("Everyone (follows the Soundboard channel)").tag(0)
                Text("The stream only").tag(1)
                Text("Only me (my speakers)").tag(2)
            }
            if app.pads[index].route != 0 { Text("Uses the Soundboard channel's fader, mute and switches, but not its EQ or effects.").font(.caption2).foregroundColor(Theme.dim) }
            Toggle("Loop (for music beds)", isOn: $app.pads[index].loop)
            Toggle("When it ends, play the next pad", isOn: $app.pads[index].playNext)
            if app.pads[index].playNext { Text("Builds a queue along the row of pads. It stops at the end of the bank or at an empty pad. Not used while Loop is on.").font(.caption2).foregroundColor(Theme.dim) }
            Toggle("Lower the microphone while it plays", isOn: $app.pads[index].duckMic)
            Toggle("Lower music / other apps while it plays", isOn: $app.pads[index].duckApps)
            HotkeyRow(title: "Global shortcut", action: "pad:\(id)")
            HStack {
                Button("Test") { app.triggerPad(index) }.disabled(app.pads[index].isEmpty)
                Spacer()
                Button("Done") { close() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 420)
    }
}

/// Records a global shortcut for an action id.
struct HotkeyRow: View {
    @EnvironmentObject var app: AppState
    let title: String
    let action: String
    @LState private var recording = false
    @LState private var monitor = MonitorBox()

    var body: some View {
        HStack {
            Text(title).font(.system(size: 12))
            Spacer()
            Button(recording ? "Press keys… (Esc cancels)" : (app.hotkeys[action]?.display ?? "Set shortcut")) { start() }
                .controlSize(.small)
            if app.hotkeys[action] != nil {
                Button { app.hotkeys[action] = nil } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain)
            }
        }
    }
    private func start() {
        if recording { stop(); return }
        recording = true
        monitor.m = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stop(); return nil }                 // Escape
            let b = HotkeyBinding.from(e)
            app.hotkeys[action] = b
            stop(); return nil
        }
    }
    private func stop() {
        if let m = monitor.m { NSEvent.removeMonitor(m) }
        monitor.m = nil; recording = false
    }
}
final class MonitorBox { var m: Any? }

struct HotkeysCard: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("GLOBAL HOTKEYS").font(.system(size: 10, weight: .heavy)).foregroundColor(Theme.dim)
            Text("Work even while OBS, a game or another app is in front. A Stream Deck can press these too.").font(.caption2).foregroundColor(Theme.dim)
            HotkeyRow(title: "Mute / unmute microphone", action: "mic.mute")
            HotkeyRow(title: "Mute / unmute the stream", action: "stream.mute")
            HotkeyRow(title: "Push-to-talk (hold)", action: "ptt")
            Toggle("Push-to-talk mode (mic is muted unless the key is held)", isOn: $app.pttMode).font(.caption)
            HotkeyRow(title: "Stop all soundboard sounds", action: "pads.stop")
            HotkeyRow(title: "Turn \"lower music when I talk\" on / off", action: "duck.toggle")
        }
        .padding(14).frame(minWidth: 320, maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
    }
}

struct MixAssistCard: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("QUICK SETUPS & VOICE").font(.system(size: 10, weight: .heavy)).foregroundColor(Theme.dim)
            HStack {
                ForEach(AppState.usePresets, id: \.self) { n in Button(n) { app.applyUsePreset(n) }.controlSize(.small) }
            }
            Text("Each setup sets your mic voice chain, which channels go to the stream, ducking and stream compression. Tweak anything afterwards.")
                .font(.caption2).foregroundColor(Theme.dim)
            Divider()
            Toggle("Lower music & apps when I talk", isOn: $app.master.micDuckOn)
            if app.master.micDuckOn {
                HStack { Text("Amount").font(.caption).frame(width: 70, alignment: .leading); Slider(value: $app.master.micDuckDB, in: -30 ... -3); Text(String(format: "%.0f dB", app.master.micDuckDB)).font(.caption).frame(width: 46) }
                HStack { Text("Mic level").font(.caption).frame(width: 70, alignment: .leading); Slider(value: $app.master.micDuckThreshold, in: -70 ... -20); Text(String(format: "%.0f dB", app.master.micDuckThreshold)).font(.caption).frame(width: 46) }
            }
            Divider()
            HStack {
                Button(app.toneOn ? "Stop test tone" : "Send a test tone to the stream") { app.setTestTone(!app.toneOn) }.controlSize(.small)
                Text("1 kHz for 6 s. Check that OBS / vMix's meter moves.").font(.caption2).foregroundColor(Theme.dim)
            }
        }
        .padding(14).frame(minWidth: 380, maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
    }
}


/// Loads a sound's overall shape once (200 peaks) and draws it, with a marker where playback will start.
final class WaveLoader: ObservableObject {
    @Published var peaks: [Float] = []
    @Published var duration: Double = 0
    private var loaded = ""
    func load(_ path: String) {
        guard path != loaded else { return }
        loaded = path
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let f = try? AVAudioFile(forReading: URL(fileURLWithPath: path)), f.length > 0,
                  let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(min(f.length, 48000 * 600))),
                  (try? f.read(into: buf)) != nil, let ch = buf.floatChannelData else { DispatchQueue.main.async { self?.peaks = [] }; return }
            let n = Int(buf.frameLength), bins = 200, per = max(1, n / bins)
            var out = [Float](repeating: 0, count: bins)
            for b in 0..<bins {
                var m: Float = 0, i = b * per
                let end = min(n, i + per)
                while i < end { m = max(m, abs(ch[0][i])); i += 4 }
                out[b] = m
            }
            let dur = Double(f.length) / f.processingFormat.sampleRate
            DispatchQueue.main.async { self?.peaks = out; self?.duration = dur }
        }
    }
}

struct WaveformView: View {
    let path: String
    let start: Double
    @StateObject private var loader = WaveLoader()
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 6), with: .color(Theme.well))
            guard !loader.peaks.isEmpty else { return }
            let w = size.width / CGFloat(loader.peaks.count)
            for (i, p) in loader.peaks.enumerated() {
                let h = max(1, CGFloat(p) * size.height * 0.9)
                ctx.fill(Path(CGRect(x: CGFloat(i) * w, y: (size.height - h) / 2, width: max(1, w - 0.5), height: h)), with: .color(Theme.purple))
            }
            if loader.duration > 0 {
                let x = CGFloat(min(1, start / loader.duration)) * size.width
                ctx.fill(Path(CGRect(x: x, y: 0, width: 2, height: size.height)), with: .color(Theme.gold))
            }
        }
        .frame(height: 56)
        .onAppear { loader.load(path) }
        .onChange(of: path) { _, p in loader.load(p) }
        .overlay(alignment: .topTrailing) {
            if loader.duration > 0 { Text(String(format: "%.1f s", loader.duration)).font(.system(size: 9, design: .monospaced)).foregroundColor(Theme.dim).padding(4) }
        }
    }
}
