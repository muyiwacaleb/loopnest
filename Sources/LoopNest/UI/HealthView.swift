import SwiftUI
import AppKit

/// Health page: performance counters, hardware, input status, event log, session backups.
struct HealthView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var health = Health.shared
    @LState private var restoreTarget: URL? = nil
    @LState private var askRestore = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Health & diagnostics").font(.headline)
                    Spacer()
                    Button("Export diagnostic report…") { app.exportDiagnosticReport() }.controlSize(.small)
                    if app.safeMode { Button("Leave Safe Mode") { app.relaunchApp(safe: false) }.controlSize(.small).buttonStyle(.borderedProminent) }
                    else { Button("Restart in Safe Mode") { app.relaunchApp(safe: true) }.controlSize(.small).help("Opens LoopNest with every effect, hotkey, MIDI and extra output turned off. Nothing is saved while Safe Mode is on.") }
                }
                HStack(alignment: .top, spacing: 14) { performanceCard; backupsCard }
                inputsCard
                hardwareCard
                logCard
            }.padding(16)
        }
        .alert("Restore this backup?", isPresented: $askRestore) {
            Button("Restore and restart") { if let u = restoreTarget { app.restoreBackup(u) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Your current settings are backed up first. LoopNest will restart to load the backup.") }
        .onAppear { app.backups = app.listBackups() }
    }

    private func card<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 10, weight: .heavy)).foregroundColor(Theme.dim)
            content()
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
    }

    private func stat(_ name: String, _ value: String, warn: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 20, weight: .bold, design: .rounded)).foregroundColor(warn ? Theme.orange : Theme.text)
            Text(name).font(.system(size: 9)).foregroundColor(Theme.dim)
        }
    }

    private var performanceCard: some View {
        card("PERFORMANCE") {
            LiveTimeline(1) {
                HStack(alignment: .top, spacing: 22) {
                    stat("LoopNest CPU (of one core)", String(format: "%.0f%%", health.cpuPercent), warn: health.cpuPercent > 60)
                    stat("Stream render load", String(format: "%.0f%%", health.load), warn: health.load > 50)
                    stat("Stream underruns", "\(health.underruns)", warn: health.underruns > 0)
                    stat("Audio restarts", "\(health.engineRestarts)", warn: health.engineRestarts > 0)
                }
            }
            Text("An underrun means the stream device asked for audio before LoopNest had it ready, which can cause a click in OBS. A few at start-up are normal. If the number keeps climbing, raise the interface's buffer size or close heavy apps.")
                .font(.caption2).foregroundColor(Theme.dim).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(String(format: "Peak render load since reset: %.0f%%", health.loadPeak)).font(.caption).foregroundColor(Theme.dim)
                Spacer()
                Button("Reset counters") { health.resetCounters() }.controlSize(.mini)
            }
        }
    }

    private var backupsCard: some View {
        card("SESSION BACKUPS") {
            Text("LoopNest saves a copy of all your settings every few minutes and when you quit. The newest 20 are kept.")
                .font(.caption2).foregroundColor(Theme.dim).fixedSize(horizontal: false, vertical: true)
            ForEach(Array(app.backups.prefix(5)), id: \.url) { b in
                HStack {
                    Text(b.date.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                    Text(b.url.lastPathComponent.components(separatedBy: "(").last?.replacingOccurrences(of: ").loopnest", with: "") ?? "").font(.caption2).foregroundColor(Theme.dim)
                    Spacer()
                    Button("Restore") { restoreTarget = b.url; askRestore = true }.controlSize(.mini)
                }
            }
            if app.backups.isEmpty { Text("No backups yet.").font(.caption).foregroundColor(Theme.dim) }
            HStack {
                Button("Back up now") { app.writeBackup(reason: "manual") }.controlSize(.small)
                Button("Show folder") { NSWorkspace.shared.activateFileViewerSelecting([AppState.backupDir]) }.controlSize(.small)
            }
        }
    }

    private var inputsCard: some View {
        card("MICROPHONE & INTERFACE INPUTS") {
            if app.micStrips.isEmpty { Text("No inputs added. Use + Add mic or app on the Console.").font(.caption).foregroundColor(Theme.dim) }
            LiveTimeline(0.5) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(app.micStrips) { s in InputHealthRow(strip: s) }
                }
            }
            Text("LoopNest can read levels, sample rate and connection state. It cannot change preamp gain or phantom power; those are controlled on the device. Use the +48V badge on each input as a reminder.")
                .font(.caption2).foregroundColor(Theme.dim).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var hardwareCard: some View {
        card("DETECTED AUDIO DEVICES") {
            let devs = app.devices.filter { !$0.isVirtualLoopNest && !$0.name.hasPrefix("CADefaultDeviceAggregate") && !$0.name.hasPrefix("LoopNestTap") }
            HStack { hdr("Device", 230); hdr("Type", 80); hdr("In", 34); hdr("Out", 34); hdr("Rate", 70); hdr("Buffer", 80); hdr("Latency in / out", 120) }
            LiveTimeline(3) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(devs) { d in
                        let buf = CA.bufferSize(d.id)
                        let li = d.inputChannels > 0 ? CA.latencyFrames(d.id, input: true) : 0
                        let lo = d.outputChannels > 0 ? CA.latencyFrames(d.id, input: false) : 0
                        let ms: (Int) -> String = { f in d.sampleRate > 0 ? String(format: "%.1f ms", Double(f) / d.sampleRate * 1000) : "-" }
                        HStack {
                            Text(d.name).lineLimit(1).frame(width: 230, alignment: .leading)
                            Text(CA.transportIsUSBOrBuiltIn(d.id)).frame(width: 80, alignment: .leading).foregroundColor(Theme.dim)
                            Text("\(d.inputChannels)").frame(width: 34, alignment: .leading)
                            Text("\(d.outputChannels)").frame(width: 34, alignment: .leading)
                            Text("\(Int(d.sampleRate)) Hz").frame(width: 70, alignment: .leading)
                            Text("\(buf) fr · \(d.sampleRate > 0 ? String(format: "%.1f", Double(buf) / d.sampleRate * 1000) : "-") ms").frame(width: 80, alignment: .leading)
                            Text("\(ms(li)) / \(ms(lo))").frame(width: 120, alignment: .leading)
                        }.font(.system(size: 11, design: .monospaced))
                    }
                }
            }
        }
    }
    private func hdr(_ t: String, _ w: CGFloat) -> some View { Text(t).font(.system(size: 9, weight: .heavy)).foregroundColor(Theme.dim).frame(width: w, alignment: .leading) }

    private var logCard: some View {
        card("EVENT LOG") {
            HStack {
                Spacer()
                Button("Show log file") { NSWorkspace.shared.activateFileViewerSelecting([health.logURL]) }.controlSize(.mini)
            }
            if health.events.isEmpty { Text("Nothing logged yet.").font(.caption).foregroundColor(Theme.dim) }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(health.events.suffix(40).enumerated().reversed()), id: \.offset) { _, e in
                    Text(e).font(.system(size: 10, design: .monospaced)).foregroundColor(Theme.text)
                }
            }
        }
    }
}

struct InputHealthRow: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var strip: Strip
    var body: some View {
        let clips = strip.capture?.clipCount ?? 0
        let rate = strip.capture?.rate ?? 0
        HStack(spacing: 10) {
            Circle().fill(strip.isActive ? Theme.green : Theme.red).frame(width: 9, height: 9)
            Text(strip.displayName).font(.system(size: 12, weight: .semibold)).lineLimit(1).frame(width: 190, alignment: .leading)
            Text(strip.isActive ? (strip.usingBackup ? "Receiving (backup device)" : "Receiving") : "Lost · retrying").font(.caption)
                .foregroundColor(strip.isActive ? Theme.dim : Theme.orange).frame(width: 140, alignment: .leading)
            HBar(meter: strip.meter).frame(width: 90, height: 8)
            Text(rate > 0 ? "\(Int(rate)) Hz" : "-").font(.system(size: 10, design: .monospaced)).foregroundColor(Theme.dim).frame(width: 64, alignment: .leading)
            Text(clips > 0 ? "CLIP ×\(clips)" : "no clipping").font(.system(size: 10, weight: .bold))
                .foregroundColor(clips > 0 ? Theme.red : Theme.dim).frame(width: 80, alignment: .leading)
            if clips > 0 { Button("Clear") { strip.capture?.clipCount = 0 }.controlSize(.mini) }
            Spacer()
            Menu {
                Button("None") { app.setBackupInput(strip, uid: nil) }
                Divider()
                ForEach(app.inputDevices()) { d in Button(d.name) { app.setBackupInput(strip, uid: d.uid) } }
            } label: {
                Text("Backup: " + (strip.backupUID.flatMap { u in app.devices.first { $0.uid == u }?.name } ?? "none")).font(.caption).lineLimit(1)
            }.menuStyle(.borderlessButton).fixedSize()
        }
    }
}
