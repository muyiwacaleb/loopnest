import Foundation
import SwiftUI
import Combine
import ServiceManagement
import AVFoundation
import CoreAudio

enum ViewMode: String, CaseIterable { case console = "Console", classic = "Classic", routing = "Routing", stream = "Stream", board = "Soundboard", fx = "FX", decks = "Decks", record = "Record", health = "Health" }

enum CaptureStatus: Equatable {
    case waiting            // nothing playing yet
    case live(Int)          // n apps being mixed
    case silent             // apps report playing but we receive only silence: usually missing permission
    case failed(Int32)      // macOS refused to create the tap
    case bypassed
}

@MainActor
final class AppState: ObservableObject {
    let engine = MixerEngine()
    let recorder = Recorder()
    let midi = MIDIManager()
    var deckA: DJDeck!
    var deckB: DJDeck!

    @Published var strips: [Strip] = []
    @Published var master = MasterSettings() { didSet {
        engine.master = master; engine.applyMaster(); saveMaster()
        if oldValue.vcaDB != master.vcaDB || oldValue.vcaMute != master.vcaMute { for s in allStrips { engine.apply(s) } }
    } }
    @Published var scenes: [MixScene] = []
    /// Automatic scene recall, keyed by scene id.
    @Published var sceneRules: [String: SceneRule] = [:] { didSet { if let d = try? JSONEncoder().encode(sceneRules) { UserDefaults.standard.set(d, forKey: "sceneRules") } } }
    private var lastRuleMinute = ""
    @Published var viewMode: ViewMode = .console
    @Published var devices: [AudioDeviceInfo] = []
    @Published var vdevices: [VirtualDeviceConfig] = [] { didSet { saveVDevices(); syncRouters() } }
    @Published var bypass = false
    /// I/O buffer size in frames, like Logic's setting. 0 means leave the device as it is.
    @Published var bufferFrames: Int = UserDefaults.standard.integer(forKey: "bufferFrames") { didSet { ud.set(bufferFrames, forKey: "bufferFrames"); applyBuffer() } }
    @Published var bufferStatus = ""
    @Published var includeMic = false
    @Published var driverInstalled = false
    @Published var statusMessage = ""
    @Published var launchAtLogin = false
    @Published var captureStatus: CaptureStatus = .waiting
    @Published var library: [URL] = [] { didSet { ud.set(library.map { $0.path }, forKey: "library") } }
    @Published var crossfade: Float = 0.5 { didSet { applyCrossfade() } }
    private var silentTicks = 0
    @Published var inputs: [InputConfig] = [] { didSet { if let d = try? JSONEncoder().encode(inputs) { ud.set(d, forKey: "inputs") } } }
    let stream = StreamOutput()
    let meeting = StreamOutput(uid: StreamOutput.meetingUID, deviceName: StreamOutput.meetingName, countsHealth: false)
    var soundboard: SoundBoard!
    /// Local control from Stream Deck / Companion / OSC. Off until switched on.
    let remote = RemoteControl()
    @Published var autoAddApps = UserDefaults.standard.bool(forKey: "autoAddApps") { didSet {
        ud.set(autoAddApps, forKey: "autoAddApps"); engine.autoAddApps = autoAddApps
    } }
    @Published var remoteOn = UserDefaults.standard.bool(forKey: "remoteOn") { didSet {
        ud.set(remoteOn, forKey: "remoteOn")
        if remoteOn && !safeMode { remote.start() } else { remote.stop() }
    } }
    let vmix = VMixLink()
    @Published var vmixHost = UserDefaults.standard.string(forKey: "vmixHost") ?? "127.0.0.1" { didSet { ud.set(vmixHost, forKey: "vmixHost") } }
    @Published var vmixPort = UserDefaults.standard.object(forKey: "vmixPort") as? Int ?? 8088 { didSet { ud.set(vmixPort, forKey: "vmixPort") } }
    /// Warns about the classic echo set-up: a built-in microphone playing through the Mac's own speakers.
    var feedbackRisk: String? {
        let out = master.outputUID.flatMap { CA.deviceID(forUID: $0) } ?? CA.defaultOutput()
        guard let name = devices.first(where: { $0.id == out })?.name.lowercased(), name.contains("speaker") else { return nil }
        for s in micStrips where s.s.toMonitor && !s.s.mute && s.s.outputUID == nil {
            let n = (inputs.first { $0.id == s.id }?.name ?? s.name).lowercased()
            if n.contains("microphone") || n.contains("macbook") || n.contains("built-in") { return s.id }
        }
        return nil
    }
    @Published var padBank = 0       // which set of 16 pads the Soundboard page shows (4 banks, 64 pads in all)
    @Published var pads: [SoundPad] = (0..<64).map { _ in SoundPad() } { didSet { if let d = try? JSONEncoder().encode(pads) { ud.set(d, forKey: "pads") } } }
    @Published var hotkeys: [String: HotkeyBinding] = [:] { didSet { if let d = try? JSONEncoder().encode(hotkeys) { ud.set(d, forKey: "hotkeys") }; HotkeyCenter.shared.set(hotkeys) } }
    @Published var pttMode = false { didSet { ud.set(pttMode, forKey: "pttMode"); setMicsMuted(pttMode) } }
    @Published var toneOn = false
    let obs = OBSLink()
    /// True when this launch is in Safe Mode: effects bypassed, hotkeys / MIDI / OBS auto-connect / extra outputs off, nothing saved.
    static let safeLaunch: Bool = {
        let ud = UserDefaults.standard
        let flagged = ud.bool(forKey: "safeModeNext")
        let held = NSEvent.modifierFlags.contains(.option)
        let streak = ud.integer(forKey: "crashStreak") + (ud.bool(forKey: "running") ? 1 : 0)
        return flagged || held || streak >= 2
    }()
    @Published var safeMode = AppState.safeLaunch
    @Published var backups: [(url: URL, date: Date)] = []
    private var slowTicks = 0
    private var recSub: AnyCancellable?
    private var remoteSub: AnyCancellable?
    private var vmixSub: AnyCancellable?
    /// Hear exactly what OBS / vMix receive on an output device you choose. Never starts on its own (it would echo a live mic).
    @Published var streamMonitorOn = false { didSet { applyStreamMonitor() } }
    @Published var streamMonitorUID: String? = UserDefaults.standard.string(forKey: "streamMonUID") {
        didSet { UserDefaults.standard.set(streamMonitorUID, forKey: "streamMonUID"); if streamMonitorOn { applyStreamMonitor() } }
    }
    /// Where PFL (pre-fader listen) is heard. nil = the system output.
    @Published var cueDeviceUID: String? = UserDefaults.standard.string(forKey: "cueUID") {
        didSet { UserDefaults.standard.set(cueDeviceUID, forKey: "cueUID"); engine.cueUID = cueDeviceUID; engine.reloadCue() }
    }
    func applyStreamMonitor() { engine.setStreamMonitor(on: streamMonitorOn, uid: streamMonitorUID) }
    /// Which source each FX card is editing: "" = master mix, otherwise a channel id.
    @Published var fxTargets: [String: String] = [:] { didSet { ud.set(fxTargets, forKey: "fxTargets") } }
    @Published var phantom: [String: PhantomInfo] = [:] { didSet { if let d = try? JSONEncoder().encode(phantom) { ud.set(d, forKey: "phantom") } } }
    @Published var phantomConfirmed: Set<String> = []        // this session only: the user says 48V is on
    @Published var crashBannerDismissed = false
    @Published var lastAliveBeforeLaunch: Date?
    @Published var recoveryReport = ""
    @Published var presetLinks: [String: String] = [:] { didSet { ud.set(presetLinks, forKey: "presetLinks") } }
    @Published var crashedLastTime = false
    @Published var autoRecover = false
    @Published var streamStatus = "Driver not installed"

    private var routers: [UUID: DeviceRouter] = [:]
    var savedStrips: [String: StripSettings] = [:]
    private var undoStack: [([String: StripSettings], MasterSettings)] = []
    private var timers: [Timer] = []
    private var lastOutPresent: Bool?

    init() {
        loadAll()
        engine.autoAddApps = autoAddApps
        if !ud.bool(forKey: "cleanSlate22Nov") {      // one time: start from a clean slate with no effect on anything
            ud.set(true, forKey: "cleanSlate22Nov")
            turnOffEveryEffect(announce: false)
        }
        deckA = DJDeck(id: "A", engine: engine)
        deckB = DJDeck(id: "B", engine: engine)
        soundboard = SoundBoard(engine: engine)
        vmixSub = vmix.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.objectWillChange.send() } }
        remoteSub = remote.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.objectWillChange.send() } }
        soundboard.onFinished = { [weak self] id in self?.chainNextPad(after: id) }
        engine.conv.onLoadFailed = { [weak self] in self?.statusMessage = "That impulse response file could not be read. Choose a WAV or AIFF file." }
        recSub = recorder.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.objectWillChange.send() } }
        obs.onSceneChanged = { [weak self] scene in if let p = self?.presetLinks[scene], !p.isEmpty { self?.applyUsePreset(p) } }
        presetLinks = (ud.dictionary(forKey: "presetLinks") as? [String: String]) ?? [:]
        crashedLastTime = ud.bool(forKey: "running")
        ud.set(crashedLastTime ? ud.integer(forKey: "crashStreak") + 1 : 0, forKey: "crashStreak")
        ud.set(false, forKey: "safeModeNext")
        engine.safeMode = safeMode
        engine.onEvent = { [weak self] m in Health.shared.log(m); DispatchQueue.main.async { self?.statusMessage = m } }
        engine.pluginGuardOnLaunch()
        HotkeyCenter.shared.disabled = safeMode
        Health.shared.log("LoopNest launched\(safeMode ? " in SAFE MODE" : "")\(crashedLastTime ? " after an unexpected quit" : "")")
        lastAliveBeforeLaunch = ud.object(forKey: "lastAlive") as? Date
        fxTargets = (ud.dictionary(forKey: "fxTargets") as? [String: String]) ?? [:]
        if let d = ud.data(forKey: "phantom"), let p = try? JSONDecoder().decode([String: PhantomInfo].self, from: d) { phantom = p }
        ud.set(true, forKey: "running")
        autoRecover = FileManager.default.fileExists(atPath: AppState.agentURL.path)
        HotkeyCenter.shared.onEvent = { [weak self] a, p in self?.handleHotkey(a, p) }
        HotkeyCenter.shared.set(hotkeys)
        for d in [deckA!, deckB!] {
            if let s = savedStrips[d.strip.id] { d.strip.s = s }
        }
        engine.master = master
        engine.applyMaster()
        engine.cueUID = cueDeviceUID
        remote.handler = { [unowned self] p, v in self.remoteCommand(p, v) }
        if remoteOn && !safeMode { remote.start() }
        applyBuffer(restart: false)
        engine.setOutput(uid: master.outputUID)
        engine.start()
        for cfg in inputs { if engine.addInput(cfg) { if let saved = savedStrips[cfg.id] { engine.strips[cfg.id]?.s = saved } } }
        rebuildStripList()
        midi.onValue = { [weak self] t, v, note in self?.handleMIDI(t, v, note) }
        if !safeMode { midi.start() }
        let recFmt = recorder.format
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let n = Recorder.recoverOrphans(format: recFmt)
            if n > 0 {
                Health.shared.log("Recovered \(n) unfinished recording(s) after an unexpected quit")
                DispatchQueue.main.async { self?.statusMessage = "Recovered \(n) unfinished recording\(n == 1 ? "" : "s"). Look for “(recovered)” in your recordings folder." }
            }
        }
        refreshDevices()
        syncRouters()
        launchAtLogin = SMAppService.mainApp.status == .enabled
        applyCrossfade()

        timers.append(Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickSlow() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickFast() }
        })
        tickSlow()
    }

    // MARK: ticking
    private func tickSlow() {
        if !bypass { checkSceneRules() }
        ud.set(Date(), forKey: "lastAlive")
        Health.shared.refresh()
        slowTicks += 1
        if slowTicks % 200 == 0 { writeBackup(reason: "auto") }     // about every 5 minutes
        refreshDevices()
        guard !bypass else { return }
        engine.reconnectInputs()
        engine.ensureAux()
        engine.syncProcesses(CA.processes()) { [weak self] in self?.rebuildStripList() }
        for s in engine.strips.values where s.kind == .app && savedStrips[s.id] != nil && s.s == StripSettings() {
            s.s = savedStrips[s.id]!
        }
        if strips.count != engine.strips.values.filter({ $0.kind != .deck && !$0.id.hasPrefix("soundboard.") }).count { rebuildStripList() }
        for r in routers.values { r.rebuild() }   // picks up apps that started playing
        persistStrips()
        updateCaptureStatus()
    }

    private func updateCaptureStatus() {
        if bypass { captureStatus = .bypassed; return }
        let playing = strips.filter { $0.kind == .app && $0.isActive }
        if playing.isEmpty {
            silentTicks = 0
            captureStatus = engine.captureFailures > 0 && engine.captureOK == 0 ? .failed(engine.lastCaptureError) : .waiting
            return
        }
        let heard = playing.contains { max($0.meter.holdL, $0.meter.holdR, $0.capture?.peakL ?? 0) > 0.0005 }
        silentTicks = heard ? 0 : silentTicks + 1
        if engine.captureFailures > 0 && engine.captureOK == 0 { captureStatus = .failed(engine.lastCaptureError) }
        else if silentTicks >= 4 { captureStatus = .silent }
        else { captureStatus = .live(playing.count) }
    }

    func openAudioPrivacySettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") { NSWorkspace.shared.open(u) }
    }

    /// Apps known to the audio system that don't have a strip yet (for the "Add app" slot).
    func addableApps() -> [(id: String, name: String, members: [AudioProcessInfo])] {
        let groups = Dictionary(grouping: CA.processes(), by: { $0.groupID })
        return groups.compactMap { gid, m in
            guard engine.strips[gid] == nil else { return nil }
            return (gid, m.first(where: { $0.groupID == $0.bundleID })?.name ?? m[0].name, m)
        }.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }
    /// Turns every effect off, everywhere: master (EQ, limiter, reverb, delay, filter, distortion, pitch, glue, ducking, stream
    /// processing, submixes) and each channel's sound shaping and effect sends. Faders, mutes, names and routing are kept.
    func turnOffEveryEffect(announce: Bool = true) {
        var m = MasterSettings()
        m.outputUID = master.outputUID
        m.gainDB = master.gainDB; m.mute = master.mute
        master = m
        savedStrips = savedStrips.mapValues { var v = $0; v.applyPreset(StripSettings()); return v }     // remembered settings for channels not added right now
        for s in allStrips { s.s.applyPreset(StripSettings()); s.pfl = false }
        persistStrips(); saveMaster()
        if announce { statusMessage = "Every effect is off. Your faders, mutes, names and routing were kept." }
    }
    func removeStrip(_ strip: Strip) {
        if strip.kind == .app { engine.dismissed.insert(strip.id) }
        savedStrips[strip.id] = strip.s       // remembered if you add this device / app again
        inputs.removeAll { $0.id == strip.id }
        engine.removeStrip(strip.id); rebuildStripList()
    }
    func addInput(_ cfg: InputConfig) {
        if !inputs.contains(cfg) { inputs.append(cfg) }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.engine.addInput(cfg) { if let saved = self.savedStrips[cfg.id] { self.engine.strips[cfg.id]?.s = saved }; self.rebuildStripList() }
            }
        }
    }
    /// Input devices with their channel layout, for the "Add input" menus.
    func inputDevices() -> [AudioDeviceInfo] { devices.filter { $0.inputChannels > 0 && !$0.isVirtualLoopNest && !$0.name.hasPrefix("CADefaultDeviceAggregate") && !$0.name.hasPrefix("LoopNestTap") } }

    /// Replace a microphone input with a different device/channel, keeping its settings.
    func changeInput(_ strip: Strip, to cfg: InputConfig) {
        let saved = strip.s
        inputs.removeAll { $0.id == strip.id }
        engine.removeStrip(strip.id)
        savedStrips[cfg.id] = saved
        addInput(cfg)
    }

    // MARK: save / load settings file
    static let settingsKeys = ["master", "scenes", "strips", "vdevices", "inputs", "library", "viewMode", "pads", "hotkeys", "obs", "presetLinks", "phantom", "fxTargets", "sceneRules"]
    func exportSettings() {
        persistStrips()
        let p = NSSavePanel(); p.nameFieldStringValue = "LoopNest Settings.loopnest"
        guard p.runModal() == .OK, let url = p.url else { return }
        var dict: [String: Any] = [:]
        for k in AppState.settingsKeys { if let v = ud.object(forKey: k) { dict[k] = v } }
        if let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0) {
            try? data.write(to: url); statusMessage = "Settings saved to \(url.lastPathComponent)."
        }
    }
    func importSettings() {
        let p = NSOpenPanel(); p.allowsMultipleSelection = false
        guard p.runModal() == .OK, let url = p.url, let data = try? Data(contentsOf: url),
              let dict = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { statusMessage = "Couldn't read that file."; return }
        for (k, v) in dict where AppState.settingsKeys.contains(k) { ud.set(v, forKey: k) }
        statusMessage = "Settings loaded. Quit and reopen LoopNest to apply them."
    }

    // MARK: phantom power reminders (informational only)
    func phantomKey(_ strip: Strip) -> String? {
        guard strip.kind == .input, let c = inputs.first(where: { $0.id == strip.id }) else { return nil }
        return "\(c.uid)#\(c.offset)"
    }
    func phantomInfo(_ strip: Strip) -> PhantomInfo { phantomKey(strip).flatMap { phantom[$0] } ?? PhantomInfo() }
    func setPhantom(_ strip: Strip, _ f: (inout PhantomInfo) -> Void) {
        guard let k = phantomKey(strip) else { return }
        var p = phantom[k] ?? PhantomInfo(); f(&p); phantom[k] = p
        if !p.expected { phantomConfirmed.remove(k) }
    }
    func phantomConfirm(_ strip: Strip, _ on: Bool) {
        guard let k = phantomKey(strip) else { return }
        if on { phantomConfirmed.insert(k) } else { phantomConfirmed.remove(k) }
    }

    // MARK: crash recovery notice
    func recoveryCheck() {
        refreshDevices()
        engine.reconnectInputs()
        let outs = devices.filter { $0.outputChannels > 0 && !$0.isVirtualLoopNest }.count
        let ins = inputDevices().count
        let perm: String
        switch micPermission { case .authorized: perm = "allowed"; case .denied, .restricted: perm = "BLOCKED"; default: perm = "not asked yet" }
        let waiting = micStrips.filter { !$0.isActive }.map { $0.name }
        var parts = ["\(outs) output device(s), \(ins) input device(s) found",
                     "microphone permission \(perm)",
                     driverInstalled ? "driver installed" : "driver NOT installed",
                     "stream: \(streamStatus)"]
        parts.append(waiting.isEmpty ? "all added microphones are receiving" : "not receiving: " + waiting.joined(separator: ", "))
        parts.append("OBS: \(obs.state)")
        recoveryReport = parts.joined(separator: " · ")
    }

    // MARK: auto-restart (LaunchAgent restarts LoopNest if it quits unexpectedly)
    static let agentLabel = "com.loopnest.app.recover"
    static var agentURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist") }
    func setAutoRecover(_ on: Bool) {
        let uid = getuid()
        let app = Bundle.main.bundlePath
        if on {
            guard let exe = Bundle.main.executablePath else { return }
            let plist: [String: Any] = ["Label": AppState.agentLabel, "ProgramArguments": [exe], "RunAtLoad": true,
                                        "KeepAlive": ["SuccessfulExit": false], "ThrottleInterval": 5, "ProcessType": "Interactive"]
            try? FileManager.default.createDirectory(at: AppState.agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard let d = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0), (try? d.write(to: AppState.agentURL)) != nil else { statusMessage = "Couldn't write the startup file."; return }
            try? SMAppService.mainApp.unregister()
            let cmd = "nohup sh -c \"sleep 2; launchctl bootout gui/\(uid)/\(AppState.agentLabel) 2>/dev/null; launchctl bootstrap gui/\(uid) '\(AppState.agentURL.path)'\" >/dev/null 2>&1 &"
            shutdown(); let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", cmd]; try? p.run()
            NSApp.terminate(nil)
        } else {
            let cmd = "nohup sh -c \"sleep 1; launchctl bootout gui/\(uid)/\(AppState.agentLabel) 2>/dev/null; rm -f '\(AppState.agentURL.path)'; sleep 1; open '\(app)'\" >/dev/null 2>&1 &"
            shutdown(); let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", cmd]; try? p.run()
            NSApp.terminate(nil)
        }
    }

    // MARK: permissions
    var micPermission: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }
    func requestMic() { AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in DispatchQueue.main.async { self?.objectWillChange.send() } } }
    func openMicSettings() { if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(u) } }

    func addApp(_ members: [AudioProcessInfo]) {
        if engine.addApp(group: members) { rebuildStripList() }
    }

    private func applyCrossfade() {
        // equal-power crossfade between the two decks
        let a = cos(crossfade * .pi / 2), b = sin(crossfade * .pi / 2)
        deckA.strip.xfade = Float(a); deckB.strip.xfade = Float(b)
        engine.apply(deckA.strip); engine.apply(deckB.strip)
    }

    /// Applies the chosen buffer size to the output device LoopNest plays through and to the default input.
    func applyBuffer(restart: Bool = true) {
        guard bufferFrames > 0 else { bufferStatus = "Automatic (the device decides)"; return }
        let frames = bufferFrames
        let out = master.outputUID.flatMap { CA.deviceID(forUID: $0) } ?? CA.defaultOutput()
        let inp = CA.defaultInput()
        let rate = engine.format.sampleRate
        // Changing a device's buffer can block for a while if another program is using it, so never do it on the main thread.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var got: [String] = [], notes: [String] = []
            for (label, id) in [("Output", out), ("Input", inp)] where id != 0 {
                let r = CA.setBufferSize(id, frames)
                got.append("\(label) \(r) frames")
                if r != frames { notes.append("\(label) device accepted \(r) frames instead of \(frames)") }
            }
            let status = got.joined(separator: " · ") + String(format: " · about %.1f ms each way", Double(frames) / max(1, rate) * 1000)
            DispatchQueue.main.async {
                guard let self else { return }
                self.bufferStatus = status
                for n in notes { Health.shared.log(n) }
                Health.shared.log("Buffer size set: \(status)")
                if restart { self.engine.setOutput(uid: self.master.outputUID) }
            }
        }
    }

    private func tickFast() {
        var duckMic = false, duckApps = false
        for id in soundboard.playing { if let p = pads.first(where: { $0.id == id }) { duckMic = duckMic || p.duckMic; duckApps = duckApps || p.duckApps } }
        engine.padMicTarget = duckMic ? 0.25 : 1
        engine.padAppsTarget = duckApps ? 0.3 : 1
        engine.updateDucking()
        engine.masterMeter.decay()
        for s in engine.strips.values { s.meter.decay() }
    }

    /// Device rules: a scene can recall itself when an audio device whose name matches is plugged in or removed.
    private func deviceSceneRules(_ name: String, removed: Bool) {
        for sc in scenes {
            if let r = sceneRules[sc.id.uuidString], r.devOn, !r.devMatch.isEmpty, r.devRemoved == removed,
               name.localizedCaseInsensitiveContains(r.devMatch) {
                recall(sc)
                let msg = "Scene \(sc.name) recalled because \(name) was \(removed ? "removed" : "plugged in")."
                statusMessage = msg; Health.shared.log(msg)
            }
        }
    }

    /// Time-of-day rules: checked every few seconds, fired once per minute.
    private func checkSceneRules() {
        guard sceneRules.values.contains(where: { $0.timeOn }) else { return }
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let key = "\(c.hour ?? 0):\(c.minute ?? 0)"
        guard key != lastRuleMinute else { return }
        lastRuleMinute = key
        for sc in scenes {
            if let r = sceneRules[sc.id.uuidString], r.timeOn, r.hour == c.hour, r.minute == c.minute {
                recall(sc); statusMessage = "Scene \(sc.name) recalled by its schedule."; Health.shared.log("Scene \(sc.name) recalled by its schedule (\(key))")
            }
        }
    }
    private func rebuildStripList() {
        let before = Set(strips.map { $0.id })
        defer {
            for s in strips where !before.contains(s.id) && !before.isEmpty {       // an app or input just appeared
                for sc in scenes {
                    if let r = sceneRules[sc.id.uuidString], r.appOn, !r.appMatch.isEmpty, s.displayName.localizedCaseInsensitiveContains(r.appMatch) {
                        recall(sc); statusMessage = "Scene \(sc.name) recalled because \(s.displayName) started."; Health.shared.log("Scene \(sc.name) recalled: \(s.displayName) started")
                    }
                }
            }
        }
        strips = engine.strips.values.filter { $0.kind != .deck && !$0.id.hasPrefix("soundboard.") }.sorted { ($0.kind == .input ? 0 : 1, $0.name.lowercased()) < ($1.kind == .input ? 0 : 1, $1.name.lowercased()) }
        for s in strips where s.s == StripSettings() { if let saved = savedStrips[s.id] { s.s = saved } }
    }

    func refreshDevices() {
        let d = CA.devices()
        if d != devices {
            let oldIDs = Set(devices.map { $0.uid }), newIDs = Set(d.map { $0.uid })
            if !devices.isEmpty {
                for x in d where !oldIDs.contains(x.uid) && !x.isVirtualLoopNest { Health.shared.log("Device connected: \(x.name)"); deviceSceneRules(x.name, removed: false) }
                for x in devices where !newIDs.contains(x.uid) && !x.isVirtualLoopNest { Health.shared.log("Device disconnected: \(x.name)"); deviceSceneRules(x.name, removed: true) }
            }
            devices = d
        }
        // Failover: if the output device you chose is unplugged, play through the system default instead, and move back when it returns.
        if let u = master.outputUID {
            let present = d.contains { $0.uid == u }
            if let was = lastOutPresent, was != present {
                let name = devices.first { $0.uid == u }?.name ?? "Your chosen output"
                engine.setOutput(uid: u)                       // falls back to the default output while the device is missing
                let msg = present ? "\(name) is back. Playing through it again." : "\(name) was disconnected. Playing through the system default output until it returns."
                Health.shared.log(msg); statusMessage = msg
            }
            lastOutPresent = present
        } else { lastOutPresent = nil }
        if !phantomConfirmed.isEmpty {   // many interfaces lose 48V when unplugged, so ask again after a reconnect
            let gone = phantomConfirmed.filter { k in !d.contains { $0.uid == String(k.split(separator: "#").first ?? "") } }
            if !gone.isEmpty { phantomConfirmed.subtract(gone) }
        }
        let installed = d.contains { $0.isVirtualLoopNest }
        if installed != driverInstalled { driverInstalled = installed }
        if installed {
            if stream.running && CA.deviceID(forUID: StreamOutput.uid) != nil && !stream.isBoundToCurrentDevice { stream.stop(); Health.shared.log("LoopNest Stream device was re-created by macOS. Reconnecting.") }
            if meeting.running && CA.deviceID(forUID: StreamOutput.meetingUID) != nil && !meeting.isBoundToCurrentDevice { meeting.stop() }
            if CA.deviceID(forUID: StreamOutput.uid) == nil { if stream.running { stream.stop() }; streamStatus = "Driver installed - restart audio to add LoopNest Stream (Apply in Stream page)" }
            else if !stream.running { stream.start(ring: engine.streamRing, engineRate: engine.format.sampleRate); streamStatus = stream.statusText }
            else { streamStatus = stream.statusText }
            if CA.deviceID(forUID: StreamOutput.meetingUID) == nil { if meeting.running { meeting.stop() } }
            else if !meeting.running { meeting.start(ring: engine.meetingRing, engineRate: engine.format.sampleRate) }
        } else if stream.running { stream.stop(); meeting.stop(); streamStatus = "Driver not installed" }
        else { streamStatus = "Driver not installed" }
    }

    // MARK: strip control (with groups)
    func setGain(_ strip: Strip, db: Float) {
        let clamped = max(StripSettings.minDB, min(6, db))
        let delta = clamped - strip.s.gainDB
        strip.s.gainDB = clamped
        guard let g = strip.s.group else { return }
        for other in allStrips where other.id != strip.id && other.s.group == g {
            other.s.gainDB = max(StripSettings.minDB, min(6, other.s.gainDB + delta))
        }
    }
    func toggleMute(_ s: Strip) {
        s.s.mute.toggle()
        if let g = s.s.group { for o in allStrips where o.id != s.id && o.s.group == g { o.s.mute = s.s.mute } }
    }
    var allStrips: [Strip] { strips + [deckA.strip, deckB.strip] }
    var micStrips: [Strip] { strips.filter { $0.kind == .input } }

    // MARK: soundboard, hotkeys, presets
    /// A queue: a pad with "play the next pad" starts the pad after it when it ends. The chain stops at the end of the bank or at an empty pad.
    func chainNextPad(after id: UUID) {
        guard let i = pads.firstIndex(where: { $0.id == id }), pads[i].playNext, !pads[i].loop else { return }
        let n = i + 1
        guard n < pads.count, n % 16 != 0, !pads[n].isEmpty, !soundboard.playing.contains(pads[n].id) else { return }
        soundboard.toggle(pads[n])
    }
    func triggerPad(_ i: Int) {
        guard pads.indices.contains(i), !pads[i].isEmpty else { return }
        soundboard.toggle(pads[i])
    }
    func setMicsMuted(_ m: Bool) { for s in micStrips where s.s.mute != m { s.s.mute = m } }
    func handleHotkey(_ action: String, _ pressed: Bool) {
        switch action {
        case "mic.mute": if pressed { setMicsMuted(!(micStrips.first?.s.mute ?? false)) }
        case "stream.mute": if pressed { master.streamMute.toggle() }
        case "ptt": if pttMode { setMicsMuted(!pressed) }
        case "pads.stop": if pressed { soundboard.stopAll() }
        case "duck.toggle": if pressed { master.micDuckOn.toggle() }
        default:
            if action.hasPrefix("scene:"), pressed, let sc = scenes.first(where: { "scene:\($0.id)" == action }) { recall(sc); statusMessage = "Scene \(sc.name) recalled." }
            if action.hasPrefix("pad:"), pressed, let i = pads.firstIndex(where: { "pad:\($0.id)" == action }) { triggerPad(i) }
        }
    }
    func setTestTone(_ on: Bool) {
        toneOn = on; engine.setTestTone(on)
        if on { DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in if self?.toneOn == true { self?.setTestTone(false) } } }
    }

    static let usePresets = ["Podcast", "Gaming", "Music stream", "Call"]
    /// One-click starting points for common streaming setups.
    func applyUsePreset(_ name: String) {
        var m = master
        m.streamLimiterOn = true; m.streamEQOn = false; m.streamCompOn = false; m.micDuckOn = false
        for s in allStrips where s.kind == .input {
            s.s.toStream = true; s.s.toMonitor = false; s.s.mute = false
            switch name {
            case "Music stream": s.s.applyStreamerVoice(); s.s.nrOn = false; s.s.compEnabled = false
            default: s.s.applyStreamerVoice()
            }
        }
        for s in allStrips where s.kind == .app {
            let isCall = callApps.contains(s.id)
            s.s.toMonitor = true
            switch name {
            case "Podcast": s.s.toStream = isCall; s.s.gainDB = 0
            case "Gaming": s.s.toStream = true; s.s.gainDB = isCall ? 0 : -3
            case "Music stream": s.s.toStream = true; s.s.gainDB = 0
            default: s.s.toStream = isCall; s.s.gainDB = 0       // Call
            }
        }
        switch name {
        case "Podcast": m.streamCompOn = true; m.streamCompThreshold = -20; m.streamCompRatio = 3; m.loudnessTarget = -16
        case "Gaming": m.micDuckOn = true; m.micDuckDB = -8; m.streamCompOn = true; m.streamCompThreshold = -16; m.streamCompRatio = 2.5; m.loudnessTarget = -14
        case "Music stream": m.micDuckOn = true; m.micDuckDB = -12; m.streamEQOn = true; m.streamEQ = [2, 1, 0, 0, 0, 0, 0, 1, 2, 1]; m.loudnessTarget = -14
        default: m.streamCompOn = true; m.streamCompThreshold = -22; m.streamCompRatio = 3; m.loudnessTarget = -16
        }
        master = m
        statusMessage = "Applied the \(name) preset."
    }

    // MARK: scenes + undo
    func snapshot() -> ([String: StripSettings], MasterSettings) {
        (Dictionary(uniqueKeysWithValues: allStrips.map { ($0.id, $0.s) }), master)
    }
    /// A/B compare: store two mixer states and flip between them to hear the difference.
    @Published var abStored: [Bool] = [false, false]
    @Published var abCurrent = -1
    private var abSnaps: [([String: StripSettings], MasterSettings)?] = [nil, nil]
    func storeAB(_ i: Int) { abSnaps[i] = snapshot(); abStored[i] = true; abCurrent = i }
    func recallAB(_ i: Int) {
        guard let snap = abSnaps[i] else { return }
        if abCurrent >= 0, abCurrent != i { abSnaps[abCurrent] = snapshot() }     // edits made while on the other slot are kept
        pushUndo()
        for s in allStrips { if let v = snap.0[s.id] { s.s = v } }
        var m = snap.1; m.outputUID = master.outputUID
        master = m
        abCurrent = i
    }
    func pushUndo() { undoStack.append(snapshot()); if undoStack.count > 50 { undoStack.removeFirst() } }
    func undo() {
        guard let last = undoStack.popLast() else { return }
        for s in allStrips { if let v = last.0[s.id] { s.s = v } }
        master = last.1
    }
    var canUndo: Bool { !undoStack.isEmpty }

    func saveScene(named name: String) {
        let snap = snapshot()
        scenes.append(MixScene(name: name, strips: snap.0, master: snap.1)); saveScenes()
    }
    func recall(_ scene: MixScene) {
        pushUndo()
        for s in allStrips { if let v = scene.strips[s.id] { s.s = v } }
        var m = scene.master; m.outputUID = master.outputUID
        master = m
    }
    func deleteScene(_ scene: MixScene) { scenes.removeAll { $0.id == scene.id }; saveScenes() }

    // MARK: bypass / panic
    func setBypass(_ on: Bool) {
        bypass = on
        engine.standAside(on)
        if on { engine.releaseAllApps() } else { engine.syncProcesses(CA.processes()) { [weak self] in self?.rebuildStripList() }
            for s in engine.strips.values where s.kind == .app { _ = s.capture?.start(.processes(s.processObjects, mute: true)) } }
    }

    // MARK: remote control
    func findStrip(_ key: String) -> Strip? {
        allStrips.first { $0.id == key } ?? allStrips.first { $0.displayName.caseInsensitiveCompare(key) == .orderedSame }
            ?? allStrips.first { $0.displayName.lowercased().hasPrefix(key.lowercased()) }
    }
    /// One entry point for every remote command. Returns a small JSON reply.
    func remoteCommand(_ p: [String], _ v: Float?) -> String {
        func ok(_ m: String) -> String { "{\"ok\":true,\"did\":\"\(m)\"}" }
        func err(_ m: String) -> String { "{\"error\":\"\(m)\"}" }
        guard let c = p.first?.lowercased() else { return err("empty command") }
        let arg = p.count > 1 ? p[1] : ""
        func level(_ x: Float?) -> Float { max(0, min(1, x ?? 0)) }
        switch c {
        case "state":
            func esc(_ t: String) -> String { t.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
            let items = allStrips.map { "{\"name\":\"\(esc($0.displayName))\",\"gainDB\":\(Int($0.s.gainDB)),\"mute\":\($0.s.mute),\"solo\":\($0.s.solo),\"pfl\":\($0.pfl),\"monitor\":\($0.s.toMonitor),\"stream\":\($0.s.toStream),\"meeting\":\($0.s.toMeeting)}" }
            return "{\"strips\":[\(items.joined(separator: ","))],\"masterDB\":\(Int(master.gainDB)),\"dim\":\(master.dim),\"mono\":\(master.mono),\"streamMute\":\(master.streamMute),\"submixMute\":[\(master.subMute.map { String($0) }.joined(separator: ","))],\"scenes\":[\(scenes.map { "\"\(esc($0.name))\"" }.joined(separator: ","))]}"
        case "stream", "meeting", "monitor":
            guard let s = findStrip(arg) else { return err("no channel \(arg)") }
            let cur = c == "stream" ? s.s.toStream : (c == "meeting" ? s.s.toMeeting : s.s.toMonitor)
            let want = v.map { $0 > 0.5 } ?? !cur
            if c == "stream" { s.s.toStream = want } else if c == "meeting" { s.s.toMeeting = want } else { s.s.toMonitor = want }
            return ok("\(c) \(s.displayName)")
        case "mute": guard let s = findStrip(arg) else { return err("no channel \(arg)") }
            if let v { if (v > 0.5) != s.s.mute { toggleMute(s) } } else { toggleMute(s) }; return ok("mute \(s.displayName)")
        case "solo": guard let s = findStrip(arg) else { return err("no channel \(arg)") }; s.s.solo.toggle(); return ok("solo \(s.displayName)")
        case "pfl": guard let s = findStrip(arg) else { return err("no channel \(arg)") }; s.pfl.toggle(); return ok("pfl \(s.displayName)")
        case "fader": guard let s = findStrip(arg), let v else { return err("use /fader/<channel>/<0 to 1>") }
            let x = level(v); setGain(s, db: x <= 0.001 ? StripSettings.minDB : -60 + x * 66); return ok("fader \(s.displayName)")
        case "pan": guard let s = findStrip(arg), let v else { return err("use /pan/<channel>/<0 to 1>") }
            s.s.panL = level(v) * 2 - 1; s.s.panR = level(v) * 2 - 1; return ok("pan \(s.displayName)")
        case "master": guard let v else { return err("use /master/<0 to 1>") }; master.gainDB = -60 + level(v) * 66; return ok("master")
        case "ab": guard let i = ["a": 0, "b": 1][arg.lowercased()] else { return err("use /ab/a or /ab/b") }
            if abStored[i] { recallAB(i) } else { storeAB(i) }; return ok("A/B \(arg.uppercased())")
        case "submix": guard let n = Int(arg), (1...2).contains(n) else { return err("use /submix/<1 or 2>/<0 to 1> or /submix/<1 or 2>/mute") }
            if p.count > 2, p[2].lowercased() == "mute" { master.subMute[n - 1].toggle(); return ok("submix \(n) mute") }
            guard let v else { return err("use /submix/<1 or 2>/<0 to 1>") }
            let x = level(v); master.subDB[n - 1] = x <= 0.001 ? StripSettings.minDB : -60 + x * 66; return ok("submix \(n)")
        case "streammute": master.streamMute.toggle(); return ok("stream mute")
        case "dim": master.dim.toggle(); return ok("dim")
        case "mono": master.mono.toggle(); return ok("mono")
        case "pad": guard let n = Int(arg) ?? v.map({ Int($0) }), n >= 1, n <= pads.count else { return err("use /pad/<1 to 64>") }; triggerPad(n - 1); return ok("pad \(n)")
        case "pads": soundboard.stopAll(); return ok("stop all pads")
        case "scene": guard let sc = scenes.first(where: { $0.name.caseInsensitiveCompare(arg) == .orderedSame }) else { return err("no scene \(arg)") }
            recall(sc); return ok("scene \(sc.name)")
        default: return err("unknown command \(c)")
        }
    }

    // MARK: MIDI
    private func handleMIDI(_ target: String, _ v: Float, _ isNote: Bool) {
        let parts = target.split(separator: ":").map(String.init)
        guard let kind = parts.first else { return }
        func strip(_ id: String) -> Strip? { allStrips.first { $0.id == id } }
        switch kind {
        case "fader": if let s = strip(parts[1]) { setGain(s, db: v <= 0.001 ? StripSettings.minDB : -60 + v * 66) }
        case "pan": if let s = strip(parts[1]) { s.s.panL = v * 2 - 1; s.s.panR = v * 2 - 1 }
        case "mute": if let s = strip(parts[1]), v > 0.5 { toggleMute(s) }
        case "solo": if let s = strip(parts[1]), v > 0.5 { s.s.solo.toggle() }
        case "master": master.gainDB = -60 + v * 66
        case "dim": if v > 0.5 { master.dim.toggle() }
        case "mono": if v > 0.5 { master.mono.toggle() }
        case "deck":
            let d = parts[1] == "A" ? deckA! : deckB!
            switch parts[2] {
            case "play": if v > 0.5 { d.playPause() }
            case "tempo": d.tempo = 0.5 + v * 1.5
            case "cue1": if v > 0.5 { d.cue(0) }
            case "cue2": if v > 0.5 { d.cue(1) }
            case "cue3": if v > 0.5 { d.cue(2) }
            case "cue4": if v > 0.5 { d.cue(3) }
            default: break
            }
        default: break
        }
    }

    /// Everything a controller can be mapped to, for the MIDI Learn list.
    var midiTargets: [(String, String)] {
        var t: [(String, String)] = [("master", "Master fader"), ("dim", "DIM"), ("mono", "Mono check")]
        for s in allStrips {
            t += [("fader:\(s.id)", "\(s.name) fader"), ("mute:\(s.id)", "\(s.name) mute"), ("solo:\(s.id)", "\(s.name) solo"), ("pan:\(s.id)", "\(s.name) pan")]
        }
        for d in ["A", "B"] {
            t += [("deck:\(d):play", "Deck \(d) play/pause"), ("deck:\(d):tempo", "Deck \(d) tempo")]
            t += (1...4).map { ("deck:\(d):cue\($0)", "Deck \(d) cue \($0)") }
        }
        return t
    }

    // MARK: virtual devices
    private func syncRouters() {
        let ids = Set(vdevices.map { $0.id })
        for (id, r) in routers where !ids.contains(id) { r.stop(); routers[id] = nil }
        for cfg in vdevices {
            if let r = routers[cfg.id] { r.update(cfg) }
            else { let r = DeviceRouter(config: cfg); routers[cfg.id] = r; r.start() }
        }
    }
    func router(for id: UUID) -> DeviceRouter? { routers[id] }

    func addVirtualDevice() {
        let used = Set(vdevices.map { $0.slot })
        guard let slot = (0..<StreamOutput.meetingSlot).first(where: { !used.contains($0) }) else { statusMessage = "All 6 device slots are in use (two more are kept for LoopNest Stream and LoopNest Meeting)."; return }
        vdevices.append(VirtualDeviceConfig(slot: slot, name: "Virtual Device \(slot + 1)"))
        writeDriverConfig()
    }
    /// Save the whole routing set-up (virtual devices, sources, wires) to a file, or load one back.
    func exportRouting() {
        let p = NSSavePanel(); p.nameFieldStringValue = "LoopNest Routing.json"
        guard p.runModal() == .OK, let url = p.url else { return }
        if let d = try? JSONEncoder().encode(vdevices) { try? d.write(to: url); statusMessage = "Routing saved to \(url.lastPathComponent)." }
    }
    func importRouting() {
        let p = NSOpenPanel(); p.allowsMultipleSelection = false
        guard p.runModal() == .OK, let url = p.url, let d = try? Data(contentsOf: url),
              var list = try? JSONDecoder().decode([VirtualDeviceConfig].self, from: d) else { statusMessage = "That file is not a LoopNest routing file."; return }
        var dropped = 0
        var used = Set(vdevices.map { $0.slot })
        var out: [VirtualDeviceConfig] = []
        for var v in list {
            // loop protection: a device must never take its own (or another LoopNest device's) output as a source
            let before = v.sources.count
            v.sources.removeAll { $0.kind == .device && $0.ref.hasPrefix("LoopNest") }
            dropped += before - v.sources.count
            let keep = Set(v.sources.map { $0.id })
            v.wires.removeAll { !keep.contains($0.sourceID) }
            guard let free = (0..<8).first(where: { !used.contains($0) }) else { break }
            v.slot = used.contains(v.slot) ? free : v.slot
            used.insert(v.slot); v.id = UUID(); out.append(v)
        }
        list = out
        vdevices.append(contentsOf: list)
        statusMessage = "Loaded \(list.count) device(s)" + (dropped > 0 ? "; removed \(dropped) source(s) that would have fed a LoopNest device back into itself." : ".")
    }
    func removeVirtualDevice(_ id: UUID) { vdevices.removeAll { $0.id == id }; writeDriverConfig() }

    // MARK: driver config / install
    static let driverConfigPath = "/Library/Application Support/LoopNest/devices.plist"

    /// Writes the device list the driver reads on load, to a temp file, then copies it with admin rights.
    func writeDriverConfig(restartAudio: Bool = false) {
        // slots 6 and 7 belong to LoopNest Meeting and LoopNest Stream: move any older device out of them
        var taken = Set(vdevices.filter { $0.slot < StreamOutput.meetingSlot }.map { $0.slot })
        for i in vdevices.indices where vdevices[i].slot >= StreamOutput.meetingSlot {
            if let free = (0..<StreamOutput.meetingSlot).first(where: { !taken.contains($0) }) { vdevices[i].slot = free; taken.insert(free) }
        }
        var list: [[String: Any]] = vdevices.filter { $0.slot < StreamOutput.meetingSlot }.sorted { $0.slot < $1.slot }.map {
            ["slot": $0.slot, "name": $0.name, "channels": $0.channels]
        }
        list.append(["slot": StreamOutput.meetingSlot, "name": StreamOutput.meetingName, "channels": 2])
        list.append(["slot": StreamOutput.slot, "name": StreamOutput.deviceName, "channels": 2])
        guard let data = try? PropertyListSerialization.data(fromPropertyList: ["devices": list], format: .xml, options: 0) else { return }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("loopnest-devices.plist")
        try? data.write(to: tmp)
        pendingDriverConfig = tmp
        if restartAudio { applyDriverConfig() }
    }
    private var pendingDriverConfig: URL?

    func applyDriverConfig() {
        guard let tmp = pendingDriverConfig else { writeDriverConfig(); return applyDriverConfig() }
        let sh = "mkdir -p '/Library/Application Support/LoopNest' && cp '\(tmp.path)' '\(AppState.driverConfigPath)' && killall coreaudiod || true"
        runAdmin(sh, success: "Audio restarted. New devices will appear in a few seconds.")
    }

    func installDriver() {
        guard let driver = Bundle.main.url(forResource: "LoopNestDriver", withExtension: "driver") else {
            statusMessage = "Driver bundle is missing from the app. Rebuild with Build.command."; return
        }
        writeDriverConfig()
        guard let tmp = pendingDriverConfig else { return }
        let sh = "mkdir -p '/Library/Application Support/LoopNest' && cp '\(tmp.path)' '\(AppState.driverConfigPath)' && rm -rf /Library/Audio/Plug-Ins/HAL/LoopNestDriver.driver && cp -R '\(driver.path)' /Library/Audio/Plug-Ins/HAL/ && killall coreaudiod || true"
        runAdmin(sh, success: "Driver installed. Your virtual devices will appear in a few seconds.")
    }

    func uninstallDriver() {
        runAdmin("rm -rf /Library/Audio/Plug-Ins/HAL/LoopNestDriver.driver && killall coreaudiod || true", success: "Driver removed.")
    }

    private func runAdmin(_ shell: String, success: String) {
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        DispatchQueue.global().async {
            var err: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&err)
            DispatchQueue.main.async {
                self.statusMessage = err == nil ? success : "Cancelled or failed: \((err?["NSAppleScriptErrorMessage"] as? String) ?? "unknown error")"
                self.refreshDevices()
            }
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch {
            statusMessage = "Launch at login: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setDefaultOutput(_ d: AudioDeviceInfo) { CA.setDefaultOutput(d.id); engine.setOutput(uid: master.outputUID) }
    func setDefaultInput(_ d: AudioDeviceInfo) { CA.setDefaultInput(d.id) }

    // MARK: persistence
    let ud = UserDefaults.standard
    private func loadAll() {
        let dec = JSONDecoder()
        if let d = ud.data(forKey: "master"), let m = Persist.master(d) { master = m }
        if let d = ud.data(forKey: "scenes"), let s = Persist.scenes(d) { scenes = s }
        if let d = ud.data(forKey: "sceneRules"), let r = try? JSONDecoder().decode([String: SceneRule].self, from: d) { sceneRules = r }
        if let d = ud.data(forKey: "strips"), let s = Persist.strips(d) { savedStrips = s }
        if let d = ud.data(forKey: "pads"), let v = try? dec.decode([SoundPad].self, from: d) { pads = v + (v.count < 64 ? (v.count..<64).map { _ in SoundPad() } : []) }
        if let d = ud.data(forKey: "hotkeys"), let v = try? dec.decode([String: HotkeyBinding].self, from: d) { hotkeys = v }
        pttMode = ud.bool(forKey: "pttMode")
        if let d = ud.data(forKey: "inputs"), let v = try? dec.decode([InputConfig].self, from: d) { inputs = v }
        if let d = ud.data(forKey: "vdevices"), let v = try? dec.decode([VirtualDeviceConfig].self, from: d) { vdevices = v }
        if let paths = ud.stringArray(forKey: "library") { library = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) } }
        if let m = ud.string(forKey: "viewMode"), let vm = ViewMode(rawValue: m) { viewMode = vm }
    }
    func saveMaster() { if safeMode { return }; if let d = try? JSONEncoder().encode(master) { ud.set(d, forKey: "master") } }
    private func saveScenes() { if let d = try? JSONEncoder().encode(scenes) { ud.set(d, forKey: "scenes") } }
    private func saveVDevices() { if let d = try? JSONEncoder().encode(vdevices) { ud.set(d, forKey: "vdevices") } }
    func saveViewMode() { ud.set(viewMode.rawValue, forKey: "viewMode") }
    /// Copies each loaded plug-in's own settings into the channel / master settings so they are saved.
    func capturePluginStates() {
        for s in allStrips where s.pluginSlot.unit != nil {
            if let d = engine.pluginState(s.pluginSlot), d != s.s.pluginState { s.s.pluginState = d }
        }
        if engine.masterPlugin.unit != nil, let d = engine.pluginState(engine.masterPlugin), d != master.pluginState { master.pluginState = d }
    }
    func persistStrips() {
        capturePluginStates()
        if safeMode { return }
        for s in allStrips { savedStrips[s.id] = s.s }
        if let d = try? JSONEncoder().encode(savedStrips) { ud.set(d, forKey: "strips") }
    }
    func shutdown() { UserDefaults.standard.removeObject(forKey: "pluginLoadingID"); UserDefaults.standard.synchronize(); if !safeMode { writeBackup(reason: "quit") }; Health.shared.log("LoopNest quit normally"); ud.set(false, forKey: "running"); ud.set(0, forKey: "crashStreak"); persistStrips(); engine.releaseAllApps(); for r in routers.values { r.stop() }; recorder.stop(); stream.stop(); meeting.stop() }
}
