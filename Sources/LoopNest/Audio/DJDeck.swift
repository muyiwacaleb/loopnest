import Foundation
import AVFoundation

/// A file player deck: play/pause, cue points, loops, and tempo change that keeps pitch.
final class DJDeck: ObservableObject, Identifiable {
    let id: String            // "A" or "B"
    let strip: Strip
    let player = AVAudioPlayerNode()
    let timePitch = AVAudioUnitTimePitch()
    let inMixer = AVAudioMixerNode()
    private weak var mixerEngine: MixerEngine?

    @Published var title = "No track loaded"
    @Published var isPlaying = false
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var tempo: Float = 1.0 { didSet { timePitch.rate = tempo } }   // pitch is preserved
    @Published var cues: [Double?] = [nil, nil, nil, nil]
    @Published var loopIn: Double?
    @Published var loopOut: Double?
    @Published var loopActive = false
    @Published var peaks: [Float] = []

    private var file: AVAudioFile?
    private var startFrame: AVAudioFramePosition = 0
    private var timer: Timer?
    private var generation = 0

    init(id: String, engine: MixerEngine) {
        self.id = id
        self.mixerEngine = engine
        strip = Strip(id: "deck.\(id)", name: "Deck \(id)", kind: .deck)
        strip.source = inMixer
        engine.engine.attach(player); engine.engine.attach(timePitch); engine.engine.attach(inMixer)
        engine.attach(strip)
        engine.registerStrip(strip)
        timer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in self?.tick() }
    }

    var sampleRate: Double { file?.processingFormat.sampleRate ?? 44100 }

    func load(url: URL) {
        guard let f = try? AVAudioFile(forReading: url), let e = mixerEngine?.engine else { return }
        stop()
        file = f
        let fmt = f.processingFormat
        e.connect(player, to: timePitch, format: fmt)
        e.connect(timePitch, to: inMixer, format: fmt)
        e.connect(inMixer, to: strip.eq, format: mixerEngine!.format)
        title = url.deletingPathExtension().lastPathComponent
        duration = Double(f.length) / fmt.sampleRate
        position = 0; startFrame = 0; cues = [nil, nil, nil, nil]; loopIn = nil; loopOut = nil; loopActive = false
        schedule(from: 0)
        peaks = []
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let p = DJDeck.computePeaks(url: url, bins: 700)
            DispatchQueue.main.async { self?.peaks = p }
        }
    }

    static func computePeaks(url: URL, bins: Int) -> [Float] {
        guard let f = try? AVAudioFile(forReading: url), f.length > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: 32768) else { return [] }
        var out = [Float](repeating: 0, count: bins)
        let total = Double(f.length)
        var pos: Double = 0
        while f.framePosition < f.length {
            do { try f.read(into: buf, frameCount: 32768) } catch { break }
            let n = Int(buf.frameLength)
            if n == 0 { break }
            guard let ch = buf.floatChannelData else { break }
            let chans = Int(buf.format.channelCount)
            var i = 0
            while i < n {
                let bin = min(bins - 1, Int((pos + Double(i)) / total * Double(bins)))
                var m: Float = 0
                for c in 0..<chans { m = max(m, abs(ch[c][i])) }
                if m > out[bin] { out[bin] = m }
                i += 16
            }
            pos += Double(n)
        }
        return out
    }

    private func schedule(from frame: AVAudioFramePosition) {
        guard let f = file else { return }
        generation += 1
        let gen = generation
        player.stop()
        startFrame = max(0, min(frame, f.length - 1))
        let count = AVAudioFrameCount(f.length - startFrame)
        player.scheduleSegment(f, startingFrame: startFrame, frameCount: count, at: nil) { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                self.isPlaying = false; self.player.stop(); self.startFrame = 0; self.position = 0
                self.schedule(from: 0)
            }
        }
        position = Double(startFrame) / f.processingFormat.sampleRate
        if isPlaying { player.play() }
    }

    func playPause() {
        guard file != nil else { return }
        if isPlaying { player.pause(); isPlaying = false }
        else { player.play(); isPlaying = true }
    }
    func stop() { isPlaying = false; player.stop() }

    func seek(to seconds: Double) {
        guard file != nil else { return }
        schedule(from: AVAudioFramePosition(max(0, min(seconds, duration)) * sampleRate))
    }

    // Cues: press to jump (or set if empty); shift/option-click to clear in the UI.
    func cue(_ i: Int) {
        if let t = cues[i] { seek(to: t) } else { cues[i] = position }
    }
    func clearCue(_ i: Int) { cues[i] = nil }

    func setLoopIn() { loopIn = position; if let o = loopOut, o <= position { loopOut = nil; loopActive = false } }
    func setLoopOut() { if let i = loopIn, position > i { loopOut = position; loopActive = true } }
    func toggleLoop() { if loopIn != nil && loopOut != nil { loopActive.toggle() } }
    func clearLoop() { loopIn = nil; loopOut = nil; loopActive = false }

    private func tick() {
        guard let f = file, isPlaying,
              let nt = player.lastRenderTime, let pt = player.playerTime(forNodeTime: nt) else { return }
        let pos = (Double(startFrame) + Double(pt.sampleTime)) / f.processingFormat.sampleRate
        position = min(pos, duration)
        if loopActive, let i = loopIn, let o = loopOut, pos >= o { seek(to: i) }
    }
}
