import Foundation
import AVFoundation
import Combine

struct SoundPad: Codable, Identifiable, Hashable {
    var id = UUID()
    var name = ""
    var path = ""
    var gainDB: Float = 0
    var loop = false
    var duckMic = false        // lower the microphone while this plays
    var duckApps = true        // lower music / other apps while this plays
    var startSec: Double = 0   // skip this much of the beginning
    var fadeInSec: Double = 0
    var fadeOutSec: Double = 0 // used when you press the pad again to stop it
    var playNext = false       // when this ends by itself, start the next pad (builds a queue)
    var route = 0              // who hears it: 0 everyone (Monitor and Stream follow the Soundboard channel), 1 stream only, 2 me only
    var isEmpty: Bool { path.isEmpty }

    init() {}
    init(from d: Decoder) throws {   // older saved pads have no trim or fade fields
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        gainDB = try c.decodeIfPresent(Float.self, forKey: .gainDB) ?? 0
        loop = try c.decodeIfPresent(Bool.self, forKey: .loop) ?? false
        duckMic = try c.decodeIfPresent(Bool.self, forKey: .duckMic) ?? false
        duckApps = try c.decodeIfPresent(Bool.self, forKey: .duckApps) ?? true
        startSec = try c.decodeIfPresent(Double.self, forKey: .startSec) ?? 0
        fadeInSec = try c.decodeIfPresent(Double.self, forKey: .fadeInSec) ?? 0
        fadeOutSec = try c.decodeIfPresent(Double.self, forKey: .fadeOutSec) ?? 0
        playNext = try c.decodeIfPresent(Bool.self, forKey: .playNext) ?? false
        route = try c.decodeIfPresent(Int.self, forKey: .route) ?? 0
    }
}

/// 16-pad soundboard. Plays into its own mixer channel ("Soundboard") so it gets faders, EQ, Monitor and Stream switches.
final class SoundBoard: ObservableObject {
    let strip: Strip
    private let mix = AVAudioMixerNode()
    private let mixStream = AVAudioMixerNode()
    private let mixMe = AVAudioMixerNode()
    /// Two small hidden channels carry pads that only the stream or only you should hear. They follow the Soundboard
    /// channel's fader, mute, solo and Monitor/Stream/Recording switches, but do not have its EQ or effects.
    private let streamStrip: Strip
    private let meStrip: Strip
    private var routeSub: AnyCancellable?
    private var players: [UUID: AVAudioPlayerNode] = [:]
    private var gens: [UUID: Int] = [:]
    private weak var eng: MixerEngine?
    @Published var playing: Set<UUID> = []
    /// Called on the main thread when a pad reaches its end by itself (not when stopped by hand).
    var onFinished: ((UUID) -> Void)?

    init(engine: MixerEngine) {
        eng = engine
        strip = Strip(id: "soundboard", name: "Soundboard", kind: .board)
        strip.source = mix
        engine.engine.attach(mix)
        engine.attach(strip)
        engine.registerStrip(strip)
        streamStrip = Strip(id: "soundboard.stream", name: "Soundboard (stream only)", kind: .board)
        streamStrip.source = mixStream
        engine.engine.attach(mixStream); engine.attach(streamStrip); engine.registerStrip(streamStrip)
        meStrip = Strip(id: "soundboard.me", name: "Soundboard (me only)", kind: .board)
        meStrip.source = mixMe
        engine.engine.attach(mixMe); engine.attach(meStrip); engine.registerStrip(meStrip)
        routeSub = strip.$s.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.syncRoutes() }
        syncRoutes()
    }

    private func syncRoutes() {
        let m = strip.s
        var a = streamStrip.s
        a.gainDB = m.gainDB; a.mute = m.mute; a.solo = m.solo; a.group = m.group
        a.toMonitor = false; a.toStream = m.toStream; a.toRecord = m.toRecord
        if a != streamStrip.s { streamStrip.s = a }
        var b = meStrip.s
        b.gainDB = m.gainDB; b.mute = m.mute; b.solo = m.solo; b.group = m.group
        b.toMonitor = m.toMonitor; b.toStream = false; b.toRecord = false; b.outputUID = m.outputUID
        if b != meStrip.s { meStrip.s = b }
    }

    func toggle(_ pad: SoundPad) {
        if playing.contains(pad.id) { stop(pad.id, fade: pad.fadeOutSec) } else { play(pad) }
    }

    /// Moves a player's volume in small steps. It gives up if the pad was restarted or stopped meanwhile.
    private func ramp(_ p: AVAudioPlayerNode, id: UUID, gen: Int, from: Float, to: Float, secs: Double, then: (() -> Void)? = nil) {
        guard secs > 0.01 else { p.volume = to; then?(); return }
        let steps = max(2, Int(secs / 0.03)); var i = 0
        p.volume = from
        Timer.scheduledTimer(withTimeInterval: secs / Double(steps), repeats: true) { [weak self] t in
            guard self?.gens[id] == gen else { t.invalidate(); return }
            i += 1
            p.volume = from + (to - from) * Float(i) / Float(steps)
            if i >= steps { t.invalidate(); then?() }
        }
    }

    func play(_ pad: SoundPad) {
        guard !pad.isEmpty, let eng, let file = try? AVAudioFile(forReading: URL(fileURLWithPath: pad.path)) else { return }
        let e = eng.engine
        let p: AVAudioPlayerNode
        if let existing = players[pad.id] { p = existing; p.stop() }
        else { p = AVAudioPlayerNode(); e.attach(p); players[pad.id] = p }
        e.disconnectNodeOutput(p)
        e.connect(p, to: pad.route == 1 ? mixStream : (pad.route == 2 ? mixMe : mix), format: file.processingFormat)
        let target = pow(10, pad.gainDB / 20)
        p.volume = pad.fadeInSec > 0.01 ? 0 : target
        let gen = (gens[pad.id] ?? 0) + 1; gens[pad.id] = gen
        let id = pad.id
        let done: AVAudioPlayerNodeCompletionHandler = { [weak self] _ in
            DispatchQueue.main.async { if self?.gens[id] == gen { self?.playing.remove(id); self?.onFinished?(id) } }
        }
        if pad.loop {
            let startF = min(AVAudioFramePosition(pad.startSec * file.processingFormat.sampleRate), max(0, file.length - 1))
            file.framePosition = startF
            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length - startF)) else { return }
            do { try file.read(into: buf) } catch { return }
            p.scheduleBuffer(buf, at: nil, options: .loops, completionHandler: nil)
        } else {
            let startF = min(AVAudioFramePosition(pad.startSec * file.processingFormat.sampleRate), max(0, file.length - 1))
            p.scheduleSegment(file, startingFrame: startF, frameCount: AVAudioFrameCount(file.length - startF), at: nil,
                              completionCallbackType: .dataPlayedBack) { _ in done(.dataPlayedBack) }
        }
        p.play()
        playing.insert(pad.id)
        if pad.fadeInSec > 0.01 { ramp(p, id: id, gen: gen, from: 0, to: target, secs: pad.fadeInSec) }
    }

    func stop(_ id: UUID, fade: Double = 0) {
        guard let p = players[id] else { playing.remove(id); return }
        if fade > 0.01, playing.contains(id) {
            let gen = (gens[id] ?? 0) + 1; gens[id] = gen
            ramp(p, id: id, gen: gen, from: p.volume, to: 0, secs: fade) { [weak self] in p.stop(); self?.playing.remove(id) }
        } else { p.stop(); gens[id] = (gens[id] ?? 0) + 1; playing.remove(id) }
    }
    func stopAll() { for id in Array(playing) { stop(id) } }
    func updateVolume(_ pad: SoundPad) { players[pad.id]?.volume = pow(10, pad.gainDB / 20) }
}
