import Foundation
import AppKit
import AVFoundation
import CoreAudio

/// Session backups, restart helper and the diagnostic report.
extension AppState {
    static var supportDir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LoopNest", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static var backupDir: URL {
        let d = supportDir.appendingPathComponent("Backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func settingsDictionary() -> [String: Any] {
        persistStrips()
        var dict: [String: Any] = [:]
        for k in AppState.settingsKeys { if let v = ud.object(forKey: k) { dict[k] = v } }
        return dict
    }

    func writeBackup(reason: String) {
        if safeMode && reason != "before restore" { return }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HHmmss"
        let url = AppState.backupDir.appendingPathComponent("Session \(f.string(from: Date())) (\(reason)).loopnest")
        guard let data = try? PropertyListSerialization.data(fromPropertyList: settingsDictionary(), format: .xml, options: 0) else { return }
        try? data.write(to: url)
        // keep the 20 newest
        let all = listBackups()
        for old in all.dropFirst(20) { try? FileManager.default.removeItem(at: old.url) }
        DispatchQueue.main.async { self.backups = self.listBackups() }
    }

    func listBackups() -> [(url: URL, date: Date)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: AppState.backupDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "loopnest" }.compactMap { u in
            ((try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate).map { (u, $0) }
        }.sorted { $0.date > $1.date }
    }

    func restoreBackup(_ url: URL) {
        guard let data = try? Data(contentsOf: url),
              let dict = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { statusMessage = "Couldn't read that backup."; return }
        let wasSafe = safeMode; safeMode = false
        writeBackup(reason: "before restore")
        safeMode = wasSafe
        for (k, v) in dict where AppState.settingsKeys.contains(k) { ud.set(v, forKey: k) }
        Health.shared.log("Restored settings from \(url.lastPathComponent)")
        relaunchApp()
    }

    /// Quit and open LoopNest again (used after restoring settings or switching Safe Mode).
    func relaunchApp(safe: Bool? = nil) {
        if let safe { ud.set(safe, forKey: "safeModeNext") }
        let path = Bundle.main.bundlePath
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "nohup sh -c \"sleep 2; open '\(path)'\" >/dev/null 2>&1 &"]
        shutdown(); try? p.run()
        NSApp.terminate(nil)
    }

    func setBackupInput(_ strip: Strip, uid: String?) {
        guard let i = inputs.firstIndex(where: { $0.id == strip.id }) else { return }
        inputs[i].backupUID = uid
        strip.backupUID = uid
        Health.shared.log("Backup input for \(strip.name): \(uid.flatMap { u in devices.first { $0.uid == u }?.name } ?? "none")")
    }

    // MARK: diagnostic report
    func diagnosticReport() -> String {
        let h = Health.shared
        var o: [String] = []
        let info = Bundle.main.infoDictionary
        func sysctl(_ n: String) -> String {
            var size = 0; sysctlbyname(n, nil, &size, nil, 0); guard size > 0 else { return "?" }
            var buf = [CChar](repeating: 0, count: size); sysctlbyname(n, &buf, &size, nil, 0); return String(cString: buf)
        }
        o.append("LoopNest diagnostic report")
        o.append("Created: \(Date().formatted(date: .complete, time: .complete))")
        o.append("App version: \(info?["CFBundleShortVersionString"] ?? "?") (\(info?["CFBundleVersion"] ?? "?"))")
        o.append("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)   Mac: \(sysctl("hw.model"))   Chip: \(sysctl("machdep.cpu.brand_string"))")
        o.append("Memory: \(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB   Uptime: \(Int(ProcessInfo.processInfo.systemUptime / 3600)) h")
        o.append("")
        o.append("MODE")
        o.append("Safe mode: \(safeMode ? "ON" : "off")   Crashed last time: \(crashedLastTime ? "yes" : "no")   Consecutive unclean launches: \(ud.integer(forKey: "crashStreak"))")
        o.append("")
        o.append("PERFORMANCE")
        o.append(String(format: "LoopNest CPU: %.1f%% of one core   Stream render load: %.1f%% (peak %.1f%%)", h.cpuPercent, h.load, h.loadPeak))
        o.append("Stream buffer underruns: \(h.underruns)   Audio engine restarts: \(h.engineRestarts)   Engine sample rate: \(Int(engine.format.sampleRate)) Hz")
        o.append("")
        o.append("PERMISSIONS / DRIVER")
        o.append("Microphone permission: \(micPermission.rawValue) (0 not asked, 1 restricted, 2 denied, 3 allowed)")
        o.append("Driver installed: \(driverInstalled)   Stream: \(streamStatus)")
        o.append("OBS: \(obs.state)\(obs.connected ? " (live: \(obs.streaming), recording: \(obs.recording))" : "")")
        o.append("")
        o.append("AUDIO DEVICES")
        for d in devices {
            let buf = CA.bufferSize(d.id)
            let li = d.inputChannels > 0 ? CA.latencyFrames(d.id, input: true) : 0
            let lo = d.outputChannels > 0 ? CA.latencyFrames(d.id, input: false) : 0
            o.append("- \(d.name) [\(CA.transportIsUSBOrBuiltIn(d.id))] in \(d.inputChannels) / out \(d.outputChannels) · \(Int(d.sampleRate)) Hz · buffer \(buf) frames · latency in \(li) / out \(lo) frames · uid \(d.uid)")
        }
        o.append("Default input: \(CA.deviceUID(CA.defaultInput()))   Default output: \(CA.deviceUID(CA.defaultOutput()))")
        o.append("")
        o.append("CHANNELS")
        for s in allStrips {
            let fx = s.s.fx.activeNames.joined(separator: "+")
            var line = "- \(s.name) [\(s.kind)] \(s.isActive ? "active" : "idle") · \(String(format: "%.1f", s.s.gainDB)) dB · mute \(s.s.mute) · monitor \(s.s.toMonitor) · stream \(s.s.toStream)"
            if !fx.isEmpty { line += " · FX \(fx)" }
            if let u = s.s.outputUID { line += " · output \(u)" }
            if let c = s.capture, s.kind == .input { line += " · clips \(c.clipCount) · backup \(s.backupUID ?? "none")\(s.usingBackup ? " (IN USE)" : "")" }
            o.append(line)
        }
        o.append("")
        o.append("RECENT EVENTS (newest last)")
        o.append(contentsOf: h.events.suffix(200))
        return o.joined(separator: "\n")
    }

    func exportDiagnosticReport() {
        let p = NSSavePanel()
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HHmm"
        p.nameFieldStringValue = "LoopNest Report \(f.string(from: Date())).txt"
        guard p.runModal() == .OK, let url = p.url else { return }
        do { try diagnosticReport().write(to: url, atomically: true, encoding: .utf8); statusMessage = "Report saved to \(url.lastPathComponent)." }
        catch { statusMessage = "Couldn't save the report: \(error.localizedDescription)" }
    }
}
