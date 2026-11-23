import Foundation
import AVFoundation
import CRing

/// Records the master mix, the stream mix or the recording mix, plus optional per-channel files and the microphone.
/// Audio is written to a crash-safe temporary .caf first, then converted to WAV / AIFF / FLAC (24-bit) when you stop.
/// If LoopNest quits unexpectedly, the temporary file is recovered the next time it opens.
final class Recorder: ObservableObject {
    @Published var isRecording = false
    @Published var elapsed: TimeInterval = 0
    @Published var lastFolder: URL?
    @Published var status = ""
    @Published var sizeBytes: Int64 = 0
    @Published var dropped = 0
    @Published var format: Int { didSet { UserDefaults.standard.set(format, forKey: "recFormat") } }          // 0 WAV, 1 AIFF, 2 FLAC
    @Published var mainSource: Int { didSet { UserDefaults.standard.set(mainSource, forKey: "recSource") } }  // 0 master, 1 stream, 2 recording mix

    static let formatNames = ["WAV (24-bit)", "AIFF (24-bit)", "FLAC (24-bit)"]
    static let formatExt = ["wav", "aiff", "flac"]
    static let sourceNames = ["Master mix (what you hear)", "Stream mix (what OBS and vMix get)", "Recording mix (channels with Recording on)"]
    static let sourceFile = ["Master mix", "Stream mix", "Recording mix"]

    private struct Track { var name: String; var temp: URL; var file: AVAudioFile }
    private var tracks: [String: Track] = [:]
    private let lock = NSLock()
    private var timer: Timer?
    private var startDate = Date()
    private var micEngine: AVAudioEngine?
    private weak var engine: MixerEngine?
    private var armedStrips: [Strip] = []
    private var dir: URL?

    init() {
        let ud = UserDefaults.standard
        format = ud.integer(forKey: "recFormat")
        mainSource = ud.integer(forKey: "recSource")
    }

    static var defaultFolder: URL {
        FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0].appendingPathComponent("LoopNest Recordings")
    }
    static var baseFolder: URL {
        if let p = UserDefaults.standard.string(forKey: "recDir"), !p.isEmpty { return URL(fileURLWithPath: p, isDirectory: true) }
        return defaultFolder
    }
    static func setBaseFolder(_ url: URL?) { UserDefaults.standard.set(url?.path, forKey: "recDir") }

    // MARK: files
    private func tempSettings(rate: Double, channels: Int) -> [String: Any] {
        [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
         AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
    }
    private static func finalSettings(_ fmt: Int, rate: Double, channels: Int) -> [String: Any] {
        switch fmt {
        case 2: return [AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 24]
        case 1: return [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
                        AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: true]
        default: return [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
                         AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        }
    }

    private func open(_ name: String, in dir: URL, rate: Double, channels: Int) {
        let safe = name.replacingOccurrences(of: "/", with: "-")
        let url = dir.appendingPathComponent("\(safe).recording.caf")
        if let f = try? AVAudioFile(forWriting: url, settings: tempSettings(rate: rate, channels: channels)) {
            lock.lock(); tracks[name] = Track(name: name, temp: url, file: f); lock.unlock()
        }
    }

    private func write(_ key: String, _ buf: AVAudioPCMBuffer) {
        lock.lock(); let f = tracks[key]?.file; lock.unlock()
        try? f?.write(from: buf)
    }

    /// Converts a temporary .caf into the chosen format next to it, then removes the .caf. Returns the final URL.
    @discardableResult
    static func convert(_ temp: URL, format: Int, suffix: String = "") -> URL? {
        let base = temp.deletingPathExtension().deletingPathExtension().lastPathComponent
        let out = temp.deletingLastPathComponent().appendingPathComponent("\(base)\(suffix).\(formatExt[format])")
        do {
            let inFile = try AVAudioFile(forReading: temp)
            guard inFile.length > 0 else { Health.shared.log("Recording \(temp.lastPathComponent) had no audio; the temporary file was kept."); return nil }
            let pf = inFile.processingFormat
            let outFile = try AVAudioFile(forWriting: out, settings: finalSettings(format, rate: pf.sampleRate, channels: Int(pf.channelCount)))
            guard let buf = AVAudioPCMBuffer(pcmFormat: pf, frameCapacity: 16384) else { return nil }
            while inFile.framePosition < inFile.length {
                try inFile.read(into: buf, frameCount: 16384)
                if buf.frameLength == 0 { break }
                if let ch = buf.floatChannelData {      // keep 24-bit conversion from wrapping on overs
                    for c in 0..<Int(pf.channelCount) { for i in 0..<Int(buf.frameLength) { ch[c][i] = max(-1, min(1, ch[c][i])) } }
                }
                try outFile.write(from: buf)
            }
            try? FileManager.default.removeItem(at: temp)
            return out
        } catch {
            Health.shared.log("Recording conversion failed for \(temp.lastPathComponent): \(error.localizedDescription). The .caf file was kept.")
            return nil
        }
    }

    /// Finds recordings that a crash left unfinished and turns them into normal files.
    static func recoverOrphans(format: Int) -> Int {
        var n = 0
        guard let en = FileManager.default.enumerator(at: baseFolder, includingPropertiesForKeys: nil) else { return 0 }
        for case let url as URL in en where url.lastPathComponent.hasSuffix(".recording.caf") {
            if convert(url, format: format, suffix: " (recovered)") != nil { n += 1 }
        }
        return n
    }

    // MARK: transport
    func start(engine: MixerEngine, strips: [Strip], includeMic: Bool) {
        guard !isRecording else { return }
        self.engine = engine
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let dir = Recorder.baseFolder.appendingPathComponent(df.string(from: Date()))
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { status = "Can't write to \(Recorder.baseFolder.path): \(error.localizedDescription)"; return }
        self.dir = dir; lastFolder = dir
        let rate = engine.format.sampleRate
        let main = Recorder.sourceFile[mainSource]
        Health.shared.recDropped = 0; dropped = 0

        open(main, in: dir, rate: rate, channels: 2)
        switch mainSource {
        case 1: engine.streamRecTap = { [weak self] buf in self?.write(main, buf) }
        case 2: engine.recMixTap = { [weak self] buf in self?.write(main, buf) }
        default: engine.recorderTap = { [weak self] buf in self?.write(main, buf) }
        }

        armedStrips = strips.filter { $0.s.armed }
        for s in armedStrips {
            open(s.name, in: dir, rate: rate, channels: 2)
            let key = s.name
            s.recordTap = { [weak self] buf in self?.write(key, buf) }
        }
        if includeMic {
            let mic = AVAudioEngine()
            let fmt = mic.inputNode.outputFormat(forBus: 0)
            if fmt.sampleRate > 0 {
                open("Microphone", in: dir, rate: fmt.sampleRate, channels: Int(fmt.channelCount))
                mic.inputNode.installTap(onBus: 0, bufferSize: 2048, format: fmt) { [weak self] buf, _ in self?.write("Microphone", buf) }
                try? mic.start()
                micEngine = mic
            }
        }
        startDate = Date(); elapsed = 0; sizeBytes = 0; isRecording = true
        status = "Recording \(tracks.count) file\(tracks.count == 1 ? "" : "s")"
        Health.shared.log("Recording started: \(main) → \(Recorder.formatNames[format]) in \(dir.path)")
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.elapsed = Date().timeIntervalSince(self.startDate)
            self.dropped = Health.shared.recDropped
            self.lock.lock(); let urls = self.tracks.values.map { $0.temp }; self.lock.unlock()
            self.sizeBytes = urls.reduce(Int64(0)) { $0 + ((try? FileManager.default.attributesOfItem(atPath: $1.path)[.size] as? Int64) ?? 0) }
        }
    }

    func stop() {
        guard isRecording else { return }
        timer?.invalidate(); timer = nil
        engine?.recorderTap = nil; engine?.streamRecTap = nil; engine?.recMixTap = nil
        for s in armedStrips { s.recordTap = nil }
        armedStrips = []
        micEngine?.inputNode.removeTap(onBus: 0); micEngine?.stop(); micEngine = nil
        lock.lock(); let finished = tracks.values.map { $0.temp }; tracks.removeAll(); lock.unlock()   // drops the last reference, which closes the files
        isRecording = false
        let fmt = format
        status = "Saving…"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var ok = 0, kept = 0
            for t in finished { if Recorder.convert(t, format: fmt) != nil { ok += 1 } else { kept += 1 } }
            DispatchQueue.main.async {
                self?.status = kept == 0 ? "Saved \(ok) file\(ok == 1 ? "" : "s") as \(Recorder.formatNames[fmt])"
                                         : "Saved \(ok); \(kept) kept as .caf (conversion failed, the audio is safe)"
                Health.shared.log("Recording finished: \(self?.status ?? "")")
            }
        }
    }
}
