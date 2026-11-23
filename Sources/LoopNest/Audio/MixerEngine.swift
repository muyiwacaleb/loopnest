import Foundation
import AVFoundation
import AudioToolbox
import Accelerate
import CRing
import AppKit

/// Lock-free-ish level holder written on audio threads and read by the UI.
final class Meter {
    var l: Float = 0
    var r: Float = 0
    var holdL: Float = 0
    var holdR: Float = 0
    var peakL: Float = 0     // highest level since you last clicked the dB box
    var peakR: Float = 0
    func resetPeak() { peakL = 0; peakR = 0 }
    func decay() {
        holdL = max(l, holdL * 0.96); holdR = max(r, holdR * 0.96)
        peakL = max(peakL, l); peakR = max(peakR, r)
    }
}

final class Strip: ObservableObject, Identifiable {
    enum Kind { case app, deck, input, board }
    let id: String
    let name: String
    let kind: Kind
    var icon: NSImage?
    var processObjects: [AudioObjectID] = []
    var xfade: Float = 1
    @Published var isActive = true
    @Published var s = StripSettings() { didSet {
        engine?.apply(self)
        // linked channels: fader, mute and solo follow the partner (the guard on equal values stops the echo)
        if let pid = s.linkTo, pid != id, let p = engine?.strips[pid] {
            var q = p.s, changed = false
            if s.gainDB != oldValue.gainDB, q.gainDB != s.gainDB { q.gainDB = s.gainDB; changed = true }
            if s.mute != oldValue.mute, q.mute != s.mute { q.mute = s.mute; changed = true }
            if s.solo != oldValue.solo, q.solo != s.solo { q.solo = s.solo; changed = true }
            if changed { p.s = q }
        }
    } }
    let meter = Meter()
    weak var engine: MixerEngine?

    // per-channel insert effects (after the compressor)
    let fxFilter = AVAudioUnitEQ(numberOfBands: 2)
    let fxDist = AVAudioUnitDistortion()
    let fxPitch = AVAudioUnitTimePitch()
    let fxGlue = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_DynamicsProcessor,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
    var lastFX = ChannelFX()
    var lastFXDistPreset = -1

    // graph
    var source: AVAudioNode!
    var eq: AVAudioUnitEQ!
    var comp: AVAudioUnitEffect!
    var mixer: AVAudioMixerNode!
    var reverbBus: AVAudioNodeBus = 0
    var delayBus: AVAudioNodeBus = 0
    var subBus: [AVAudioNodeBus] = [0, 0]
    var inputUID: String?
    var padDuck: Float = 1
    var auxUID: String?
    var backupUID: String?
    var usingBackup = false
    var wasActive = true
    var auxRing: OpaquePointer?
    var auxScratch: UnsafeMutablePointer<Float>?
    let voice = VoiceDSP()
    let mod = ModFX()
    /// Stereo pan matrix [L->L, L->R, R->L, R->R], read by the audio thread.
    let panG: UnsafeMutablePointer<Float> = { let p = UnsafeMutablePointer<Float>.allocate(capacity: 4); p[0] = 1; p[1] = 0; p[2] = 0; p[3] = 1; return p }()
    var dspPan: Bool { kind == .app || kind == .input }
    var displayName: String { s.label.isEmpty ? name : s.label }
    var masterIdx: AVAudioNodeBus = 0
    var streamIdx: AVAudioNodeBus = 0
    var recIdx: AVAudioNodeBus = 0
    var meetingIdx: AVAudioNodeBus = 0
    let pluginSlot = PluginSlot()
    /// Pre-fader listen: this channel is sent, before its fader and mute, to the headphone (cue) output. Never saved.
    let cueMixer = AVAudioMixerNode()
    @Published var pfl = false { didSet { if pfl != oldValue { engine?.applyPFL(self) } } }
    var capture: AudioCapture?
    var duck: Float = 1
    var recordTap: ((AVAudioPCMBuffer) -> Void)?
    var lastSeen = Date()

    init(id: String, name: String, kind: Kind) { self.id = id; self.name = name; self.kind = kind }
}

final class MixerEngine {
    let engine = AVAudioEngine()
    private(set) var format: AVAudioFormat
    let masterBus = AVAudioMixerNode()
    let masterEQ = AVAudioUnitEQ(numberOfBands: 10)
    let limiter: AVAudioUnitEffect
    let outMixer = AVAudioMixerNode()
    let streamBus = AVAudioMixerNode()
    let streamSink = AVAudioMixerNode()
    let streamDelay = AVAudioUnitDelay()
    let monitorDelay = AVAudioUnitDelay()
    let streamEQ = AVAudioUnitEQ(numberOfBands: 10)
    let streamComp = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_DynamicsProcessor,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
    let streamLimiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
    let loudness = LoudnessMeter()
    let streamMeter = Meter()
    let streamRing: OpaquePointer = cring_create(96000, 2)!
    var streamFeed: AVAudioSinkNode!
    let masterPlugin = PluginSlot()
    /// Meeting mix: only channels with "Meeting" on -> limiter -> ring -> LoopNest Meeting device.
    let meetingBus = AVAudioMixerNode()
    let meetingLimiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
    let meetingRing: OpaquePointer = cring_create(96000, 2)!
    var meetingFeed: AVAudioSinkNode!
    let analyzer = StreamAnalyzer()
    /// Recording mix: only channels with "Recording" on. Separate from the Stream mix.
    let recBus = AVAudioMixerNode()
    /// Cue (PFL) bus: channels with PFL on, taken before their faders, played on the headphone output.
    let cueBus = AVAudioMixerNode()
    var cueFeed: AVAudioSinkNode!
    let cueRing: OpaquePointer = cring_create(48000, 2)!
    var cueUID: String?
    private var cueTarget: String?
    var recMixFeed: AVAudioSinkNode!
    let streamRecRing: OpaquePointer = cring_create(96000, 2)!     // copy of the stream mix for the recorder
    let recMixRing: OpaquePointer = cring_create(96000, 2)!
    let streamMonRing: OpaquePointer = cring_create(96000, 2)!     // copy of the stream mix for "listen to what OBS gets"
    /// [0] stream monitor on, [1] stream recording on, [2] recording-mix recording on. Read by the audio thread.
    let flags: UnsafeMutablePointer<Int32> = { let p = UnsafeMutablePointer<Int32>.allocate(capacity: 8); p.initialize(repeating: 0, count: 8); return p }()
    private var monUID: String?
    private let streamScratch = UnsafeMutablePointer<Float>.allocate(capacity: 16384 * 2)
    let fxFilter = AVAudioUnitEQ(numberOfBands: 2)
    let fxDist = AVAudioUnitDistortion()
    let fxPitch = AVAudioUnitTimePitch()
    let fxGlue = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_DynamicsProcessor,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
    private var lastDistPreset = -1
    let reverbIn = AVAudioMixerNode()
    let conv = ConvReverb()
    let reverb = AVAudioUnitReverb()
    let reverbOut = AVAudioMixerNode()
    let delayIn = AVAudioMixerNode()
    /// Submix buses: channels that send here are grouped and controlled together, then reach the master, stream and recording mixes.
    let subIn = [AVAudioMixerNode(), AVAudioMixerNode()]
    /// After each submix: this mixer feeds the main, stream and recording mixes (silenced by "only to its own device").
    let subToMix = [AVAudioMixerNode(), AVAudioMixerNode()]
    let subRing: [OpaquePointer] = [cring_create(96000, 2)!, cring_create(96000, 2)!]
    var subFeed: [AVAudioSinkNode] = []
    var subOutTarget: [String?] = [nil, nil]
    let subEQ = [AVAudioUnitEQ(numberOfBands: 3), AVAudioUnitEQ(numberOfBands: 3)]
    let subComp = [0, 1].map { _ in AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_DynamicsProcessor,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)) }
    let delay = AVAudioUnitDelay()
    let delayOut = AVAudioMixerNode()

    let masterMeter = Meter()
    var spectrum = [Float](repeating: 0, count: 32)
    var master = MasterSettings()
    fileprivate(set) var strips: [String: Strip] = [:]
    private let monoFlag = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
    private(set) var running = false
    var captureOK = 0
    var captureFailures = 0
    var lastCaptureError: OSStatus = 0
    var recorderTap: ((AVAudioPCMBuffer) -> Void)?
    var streamRecTap: ((AVAudioPCMBuffer) -> Void)?     // stream mix copy for the recorder
    var recMixTap: ((AVAudioPCMBuffer) -> Void)?        // recording mix copy for the recorder
    var streamMonTap: ((AVAudioPCMBuffer) -> Void)?     // stream mix copy for "listen to what OBS receives"
    private let monScratch: UnsafeMutablePointer<Float> = { let p = UnsafeMutablePointer<Float>.allocate(capacity: 16384 * 2); p.initialize(repeating: 0, count: 16384 * 2); return p }()
    private var fftSetup: FFTSetup?

    init() {
        monoFlag.initialize(to: false)
        let lim = AudioComponentDescription(componentType: kAudioUnitType_Effect,
                                            componentSubType: kAudioUnitSubType_PeakLimiter,
                                            componentManufacturer: kAudioUnitManufacturer_Apple,
                                            componentFlags: 0, componentFlagsMask: 0)
        limiter = AVAudioUnitEffect(audioComponentDescription: lim)
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        format = AVAudioFormat(standardFormatWithSampleRate: rate > 0 ? rate : 48000, channels: 2)!
        fftSetup = vDSP_create_fftsetup(11, FFTRadix(kFFTRadix2))
        buildMasterGraph()
    }

    // MARK: master chain
    private func buildMasterGraph() {
        for n in [meetingBus, meetingLimiter, masterBus, streamBus, recBus, cueBus, streamEQ, streamComp, streamLimiter, streamSink, streamDelay, monitorDelay, masterEQ, fxFilter, fxDist, fxPitch, fxGlue, limiter, outMixer, reverbIn, reverb, reverbOut, delayIn, delay, delayOut, subIn[0], subIn[1], subEQ[0], subEQ[1], subComp[0], subComp[1], subToMix[0], subToMix[1]] as [AVAudioNode] {
            engine.attach(n)
        }
        for i in 0..<2 {
            let b = subComp[i]
            subEQ[i].bands[0].filterType = .lowShelf; subEQ[i].bands[0].frequency = 120; subEQ[i].bands[0].bypass = false
            subEQ[i].bands[1].filterType = .parametric; subEQ[i].bands[1].frequency = 1000; subEQ[i].bands[1].bandwidth = 1.0; subEQ[i].bands[1].bypass = false
            subEQ[i].bands[2].filterType = .highShelf; subEQ[i].bands[2].frequency = 6000; subEQ[i].bands[2].bypass = false
            engine.connect(subIn[i], to: subEQ[i], format: format)
            engine.connect(subEQ[i], to: subComp[i], format: format)
            let ring = subRing[i], fl = flags, flagIdx = 4 + i
            let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 16384 * 2); scratch.initialize(repeating: 0, count: 16384 * 2)
            let feed = AVAudioSinkNode { _, frames, abl in
                guard fl[flagIdx] != 0 else { return noErr }
                let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
                guard list.count >= 2, let l = list[0].mData?.assumingMemoryBound(to: Float.self),
                      let r = list[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
                let n = min(Int(frames), 16384)
                for k in 0..<n { scratch[k * 2] = l[k]; scratch[k * 2 + 1] = r[k] }
                _ = cring_write(ring, scratch, UInt32(n))
                return noErr
            }
            subFeed.append(feed); engine.attach(feed)
            engine.connect(b, to: [AVAudioConnectionPoint(node: subToMix[i], bus: 0),
                                   AVAudioConnectionPoint(node: feed, bus: 0)], fromBus: 0, format: format)
            engine.connect(subToMix[i], to: [AVAudioConnectionPoint(node: masterBus, bus: masterBus.nextAvailableInputBus),
                                   AVAudioConnectionPoint(node: streamBus, bus: streamBus.nextAvailableInputBus),
                                   AVAudioConnectionPoint(node: recBus, bus: recBus.nextAvailableInputBus)], fromBus: 0, format: format)
        }
        for (i, f) in eqFrequencies.enumerated() {
            let b = masterEQ.bands[i]
            b.filterType = .parametric; b.frequency = f; b.bandwidth = 1.0; b.gain = 0; b.bypass = false
        }
        engine.connect(masterBus, to: masterEQ, format: format)
        fxFilter.bands[0].filterType = .highPass; fxFilter.bands[0].frequency = 80; fxFilter.bands[0].bypass = true
        fxFilter.bands[1].filterType = .lowPass; fxFilter.bands[1].frequency = 8000; fxFilter.bands[1].bypass = true
        engine.connect(masterEQ, to: fxFilter, format: format)
        engine.connect(fxFilter, to: fxDist, format: format)
        engine.connect(fxDist, to: fxPitch, format: format)
        engine.connect(fxPitch, to: fxGlue, format: format)
        engine.connect(fxGlue, to: limiter, format: format)
        engine.connect(limiter, to: monitorDelay, format: format)
        engine.connect(monitorDelay, to: outMixer, format: format)
        engine.connect(outMixer, to: engine.outputNode, format: nil)
        // Shared FX: strips -> reverbIn -> reverb -> reverbOut -> masterBus
        conv.install(engine: engine, input: reverbIn, builtIn: reverb, output: reverbOut, format: format)
        engine.connect(reverb, to: reverbOut, format: format)
        engine.connect(reverbOut, to: [AVAudioConnectionPoint(node: masterBus, bus: masterBus.nextAvailableInputBus),
                                       AVAudioConnectionPoint(node: streamBus, bus: streamBus.nextAvailableInputBus),
                                       AVAudioConnectionPoint(node: recBus, bus: recBus.nextAvailableInputBus)], fromBus: 0, format: format)
        engine.connect(delayIn, to: delay, format: format)
        engine.connect(delay, to: delayOut, format: format)
        engine.connect(delayOut, to: [AVAudioConnectionPoint(node: masterBus, bus: masterBus.nextAvailableInputBus),
                                      AVAudioConnectionPoint(node: streamBus, bus: streamBus.nextAvailableInputBus),
                                       AVAudioConnectionPoint(node: recBus, bus: recBus.nextAvailableInputBus)], fromBus: 0, format: format)
        // Stream mix: channels with "Stream" on -> streamBus -> stream EQ -> compressor -> limiter -> (silent sink).
        // A tap on the limiter hands the result to the LoopNest Stream device and the loudness meter.
        for (i, f) in eqFrequencies.enumerated() {
            let b = streamEQ.bands[i]; b.filterType = .parametric; b.frequency = f; b.bandwidth = 1.0; b.gain = 0; b.bypass = false
        }
        streamSink.outputVolume = 0
        engine.connect(streamBus, to: streamEQ, format: format)
        engine.connect(streamEQ, to: streamComp, format: format)
        engine.connect(streamComp, to: streamLimiter, format: format)
        // Real-time feed of the stream mix into the ring (one small block per engine cycle, no tap latency).
        let feedRing = streamRing, feedScratch = streamScratch, monRing = streamMonRing, srecRing = streamRecRing, fl = flags, health = Health.shared
        streamFeed = AVAudioSinkNode { _, frames, abl in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
            guard list.count >= 2, let l = list[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = list[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let n = min(Int(frames), 16384)
            for i in 0..<n { feedScratch[i * 2] = l[i]; feedScratch[i * 2 + 1] = r[i] }
            _ = cring_write(feedRing, feedScratch, UInt32(n))
            if fl[0] != 0 { _ = cring_write(monRing, feedScratch, UInt32(n)) }
            if fl[1] != 0 { let w = Int(cring_write(srecRing, feedScratch, UInt32(n))); if w < n { health.recDropped &+= n - w } }
            return noErr
        }
        engine.attach(streamFeed)
        let mRing = meetingRing, mScratch = UnsafeMutablePointer<Float>.allocate(capacity: 16384 * 2)
        mScratch.initialize(repeating: 0, count: 16384 * 2)
        meetingFeed = AVAudioSinkNode { _, frames, abl in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
            guard list.count >= 2, let l = list[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = list[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let n = min(Int(frames), 16384)
            for i in 0..<n { mScratch[i * 2] = l[i]; mScratch[i * 2 + 1] = r[i] }
            _ = cring_write(mRing, mScratch, UInt32(n))
            return noErr
        }
        engine.attach(meetingFeed)
        engine.connect(meetingBus, to: meetingLimiter, format: format)
        engine.connect(meetingLimiter, to: meetingFeed, format: format)
        let recRingLocal = recMixRing, recScratch = UnsafeMutablePointer<Float>.allocate(capacity: 16384 * 2)
        recScratch.initialize(repeating: 0, count: 16384 * 2)
        recMixFeed = AVAudioSinkNode { _, frames, abl in
            guard fl[2] != 0 else { return noErr }
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
            guard list.count >= 2, let l = list[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = list[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let n = min(Int(frames), 16384)
            for i in 0..<n { recScratch[i * 2] = l[i]; recScratch[i * 2 + 1] = r[i] }
            let w = Int(cring_write(recRingLocal, recScratch, UInt32(n))); if w < n { health.recDropped &+= n - w }
            return noErr
        }
        engine.attach(recMixFeed)
        engine.connect(recBus, to: recMixFeed, format: format)
        let cueRingLocal = cueRing, cueScratch = UnsafeMutablePointer<Float>.allocate(capacity: 16384 * 2)
        cueScratch.initialize(repeating: 0, count: 16384 * 2)
        cueFeed = AVAudioSinkNode { _, frames, abl in
            guard fl[3] != 0 else { return noErr }
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
            guard list.count >= 2, let l = list[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = list[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let n = min(Int(frames), 16384)
            for i in 0..<n { cueScratch[i * 2] = l[i]; cueScratch[i * 2 + 1] = r[i] }
            _ = cring_write(cueRingLocal, cueScratch, UInt32(n))
            return noErr
        }
        engine.attach(cueFeed)
        engine.connect(cueBus, to: cueFeed, format: format)
        engine.connect(streamLimiter, to: streamDelay, format: format)
        engine.connect(streamDelay, to: [AVAudioConnectionPoint(node: streamSink, bus: 0), AVAudioConnectionPoint(node: streamFeed, bus: 0)], fromBus: 0, format: format)
        for d in [streamDelay, monitorDelay] { d.wetDryMix = 100; d.feedback = 0; d.lowPassCutoff = 20000; d.bypass = true }
        engine.connect(streamSink, to: masterBus, format: format)
        loudness.setRate(format.sampleRate)
        streamScratch.initialize(repeating: 0, count: 16384 * 2)
        let sm = streamMeter, loud = loudness, an = analyzer
        streamLimiter.installTap(onBus: 0, bufferSize: 512, format: format) { [weak self] buf, _ in
            self?.streamRecTap?(buf); self?.streamMonTap?(buf)
            guard let ch = buf.floatChannelData else { return }
            let n = min(Int(buf.frameLength), 16384)
            let r = buf.format.channelCount > 1 ? ch[1] : ch[0]
            var pl: Float = 0, pr: Float = 0
            for i in 0..<n { pl = max(pl, abs(ch[0][i])); pr = max(pr, abs(r[i])) }
            sm.l = pl; sm.r = pr
            loud.process(ch[0], r, n)
            an.process(ch[0], r, n)
        }
        recBus.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in self?.recMixTap?(buf) }
        reverb.wetDryMix = 100
        delay.wetDryMix = 100
        applyMaster()
    }

    private var configObserver: NSObjectProtocol?
    /// macOS audio restarts (device unplugged, sample-rate change, coreaudiod restart) stop an AVAudioEngine. Bring it back.
    private func watchConfigChanges() {
        guard configObserver == nil else { return }
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self, self.running, !self.standingAside else { return }
            Health.shared.engineRestarts += 1
            Health.shared.log("Audio engine configuration changed (device or sample-rate change). Restarting audio.")
            self.setOutput(uid: self.master.outputUID)
            if !self.engine.isRunning { try? self.engine.start() }
        }
    }

    func start() {
        watchConfigChanges()
        guard !running else { return }
        engine.prepare()
        do { try engine.start(); running = true } catch { NSLog("LoopNest: engine start failed: \(error)") }
        installMasterTap()
    }

    func stop() {
        for s in strips.values { s.capture?.stop() }
        outMixer.removeTap(onBus: 0)
        engine.stop(); running = false
    }

    /// Stop all captures so apps are heard normally again (panic / bypass).
    func releaseAllApps() { for s in strips.values where s.kind != .deck { s.capture?.stop() } }

    /// "LoopNest off": stop capturing apps and inputs and release the output device, so everything goes straight to your speakers or headset.
    var standingAside = false
    func standAside(_ on: Bool) {
        standingAside = on
        if on { releaseAllApps(); engine.pause() } else if running { try? engine.start() }
    }

    func setOutput(uid: String?) {
        guard let unit = engine.outputNode.audioUnit else { return }
        var id = uid.flatMap { CA.deviceID(forUID: $0) } ?? CA.defaultOutput()
        let wasRunning = running && !standingAside
        if wasRunning { engine.pause() }
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id,
                             UInt32(MemoryLayout<AudioObjectID>.size))
        if wasRunning { try? engine.start() }
    }

    // MARK: master settings
    /// Left/right pan of a channel into every mix it feeds. Master and stream pan are added on top (clamped to -1...1).
    func applyPans(_ s: Strip) {
        // Apps and inputs are panned inside their own audio path (true stereo pan). Decks and the soundboard
        // use the mixer's balance pan, set from the average of the two knobs.
        let p: Float = s.dspPan ? 0 : (s.s.panL + s.s.panR) / 2
        func c(_ v: Float) -> Float { max(-1, min(1, v)) }
        s.mixer.destination(forMixer: masterBus, bus: s.masterIdx)?.pan = c(p + master.pan)
        s.mixer.destination(forMixer: streamBus, bus: s.streamIdx)?.pan = c(p + master.streamPan)
        s.mixer.destination(forMixer: recBus, bus: s.recIdx)?.pan = c(p)
        s.mixer.destination(forMixer: reverbIn, bus: s.reverbBus)?.pan = c(p)
        s.mixer.destination(forMixer: delayIn, bus: s.delayBus)?.pan = c(p)
        for i in 0..<2 { s.mixer.destination(forMixer: subIn[i], bus: s.subBus[i])?.pan = c(p) }
    }

    func syncMasterPlugin() {
        syncPlugin(masterPlugin, wanted: master.pluginID, state: master.pluginState, bypass: master.pluginBypass, label: "Master") { [weak self] unit in
            guard let self else { return }
            if let u = unit { self.engine.connect(self.fxGlue, to: u, format: self.format); self.engine.connect(u, to: self.limiter, format: self.format) }
            else { self.engine.connect(self.fxGlue, to: self.limiter, format: self.format) }
        }
    }
    func syncStripPlugin(_ s: Strip) {
        guard s.mixer != nil, s.mixer.engine != nil else { return }
        syncPlugin(s.pluginSlot, wanted: s.s.pluginID, state: s.s.pluginState, bypass: s.s.pluginBypass, label: s.displayName) { [weak self, weak s] unit in
            guard let self, let s else { return }
            let pts = [AVAudioConnectionPoint(node: s.mixer, bus: 0), AVAudioConnectionPoint(node: s.cueMixer, bus: 0)]
            if let u = unit { self.engine.connect(s.fxGlue, to: u, format: self.format); self.engine.connect(u, to: pts, fromBus: 0, format: self.format) }
            else { self.engine.connect(s.fxGlue, to: pts, fromBus: 0, format: self.format) }
        }
    }

    func applyMaster() {
        syncMasterPlugin()
        for (i, g) in master.eq.enumerated() { masterEQ.bands[i].gain = master.eqEnabled ? g : 0 }
        limiter.bypass = !master.limiterOn
        outMixer.outputVolume = master.mute ? 0 : pow(10, master.gainDB / 20) * (master.dim ? 0.1 : 1)   // DIM = -20 dB
        monoFlag.pointee = master.mono
        for i in 0..<2 where master.subDB.indices.contains(i) && master.subMute.indices.contains(i) {
            subIn[i].outputVolume = master.subMute[i] ? 0 : pow(10, master.subDB[i] / 20)
        }
        for i in 0..<2 {
            let target = (master.subOutUID.indices.contains(i) && !master.subOutUID[i].isEmpty && !safeMode) ? master.subOutUID[i] : nil
            if target != subOutTarget[i] { setSubmixOutput(i, uid: target) }
            subToMix[i].outputVolume = (target != nil && master.subOutOnly.indices.contains(i) && master.subOutOnly[i]) ? 0 : 1
        }
        for i in 0..<2 {
            for b in 0..<3 where master.subTone.indices.contains(i * 3 + b) { subEQ[i].bands[b].gain = master.subTone[i * 3 + b] }
            if master.subCompOn.indices.contains(i), master.subCompThreshold.indices.contains(i) {
                subComp[i].bypass = !master.subCompOn[i]
                let au = subComp[i].audioUnit
                AudioUnitSetParameter(au, kDynamicsProcessorParam_Threshold, kAudioUnitScope_Global, 0, master.subCompThreshold[i], 0)
                AudioUnitSetParameter(au, kDynamicsProcessorParam_HeadRoom, kAudioUnitScope_Global, 0, 10, 0)
                AudioUnitSetParameter(au, kDynamicsProcessorParam_OverallGain, kAudioUnitScope_Global, 0, 2, 0)
            }
        }
        for s in strips.values { applyPans(s) }
        streamBus.outputVolume = master.streamMute ? 0 : pow(10, master.streamGainDB / 20)
        for i in 0..<10 { streamEQ.bands[i].gain = master.streamEQOn ? master.streamEQ[i] : 0 }
        streamComp.bypass = !master.streamCompOn
        let sau = streamComp.audioUnit
        AudioUnitSetParameter(sau, kDynamicsProcessorParam_Threshold, kAudioUnitScope_Global, 0, master.streamCompThreshold, 0)
        AudioUnitSetParameter(sau, kDynamicsProcessorParam_HeadRoom, kAudioUnitScope_Global, 0, max(0.1, min(40, 40 / max(1, master.streamCompRatio))), 0)
        AudioUnitSetParameter(sau, kDynamicsProcessorParam_OverallGain, kAudioUnitScope_Global, 0, 3, 0)
        streamLimiter.bypass = !master.streamLimiterOn
        for (d, ms) in [(streamDelay, master.streamDelayMs), (monitorDelay, master.monitorDelayMs)] {
            d.bypass = ms < 1
            if ms >= 1 { d.delayTime = TimeInterval(min(1000, ms) / 1000) }
        }
        AudioUnitSetParameter(streamLimiter.audioUnit, kLimiterParam_PreGain, kAudioUnitScope_Global, 0, master.streamPreGainDB, 0)
        reverbOut.outputVolume = master.reverbOn ? master.reverbMix : 0
        let convOn = master.reverbOn && !safeMode && master.reverbPreset >= 99 && (master.reverbPreset != 99 || master.reverbIRPath != nil)
        conv.setActive(convOn)
        if convOn { conv.configure(preset: master.reverbPreset, path: master.reverbIRPath, rate: format.sampleRate) }
        reverb.wetDryMix = convOn ? 0 : 100
        if let p = AVAudioUnitReverbPreset(rawValue: master.reverbPreset >= 99 ? 4 : master.reverbPreset) { reverb.loadFactoryPreset(p) }
        delayOut.outputVolume = master.delayOn ? master.delayMix : 0
        delay.delayTime = TimeInterval(master.delayTime)
        delay.feedback = master.delayFeedback
        // Extra FX
        fxFilter.bands[0].frequency = master.hpHz; fxFilter.bands[0].bypass = !master.filterOn
        fxFilter.bands[1].frequency = master.lpHz; fxFilter.bands[1].bypass = !master.filterOn
        fxDist.bypass = !master.distOn
        if master.distPreset != lastDistPreset, distortionPresets.indices.contains(master.distPreset) {
            fxDist.loadFactoryPreset(distortionPresets[master.distPreset].1); lastDistPreset = master.distPreset
        }
        fxDist.wetDryMix = master.distMix
        fxDist.preGain = master.distPregain
        fxPitch.bypass = !master.pitchOn
        fxPitch.pitch = master.pitchCents
        fxGlue.bypass = !master.glueOn
        let au = fxGlue.audioUnit
        AudioUnitSetParameter(au, kDynamicsProcessorParam_Threshold, kAudioUnitScope_Global, 0, master.glueThreshold, 0)
        AudioUnitSetParameter(au, kDynamicsProcessorParam_HeadRoom, kAudioUnitScope_Global, 0, max(0.1, min(40, 40 / max(1, master.glueRatio))), 0)
        AudioUnitSetParameter(au, kDynamicsProcessorParam_OverallGain, kAudioUnitScope_Global, 0, master.glueGain, 0)
        if safeMode {   // Safe mode: every effect is bypassed, levels and routing stay as they are
            fxFilter.bands[0].bypass = true; fxFilter.bands[1].bypass = true
            fxDist.bypass = true; fxPitch.bypass = true; fxGlue.bypass = true
            reverbOut.outputVolume = 0; delayOut.outputVolume = 0
            streamComp.bypass = true
            for i in 0..<10 { streamEQ.bands[i].gain = 0 }
            for i in 0..<2 { subComp[i].bypass = true; for b in 0..<3 { subEQ[i].bands[b].gain = 0 } }
        }
        for s in strips.values { apply(s) }
    }

    private func applyChannelFX(_ s: Strip, _ requested: ChannelFX) {
        let f = safeMode ? ChannelFX() : requested
        if f == s.lastFX { return }
        s.lastFX = f
        s.fxFilter.bands[0].frequency = f.hpHz; s.fxFilter.bands[0].bypass = !f.filterOn
        s.fxFilter.bands[1].frequency = f.lpHz; s.fxFilter.bands[1].bypass = !f.filterOn
        s.fxDist.bypass = !f.distOn
        if f.distPreset != s.lastFXDistPreset, distortionPresets.indices.contains(f.distPreset) {
            s.fxDist.loadFactoryPreset(distortionPresets[f.distPreset].1); s.lastFXDistPreset = f.distPreset
        }
        s.fxDist.wetDryMix = f.distMix
        s.fxDist.preGain = f.distPregain
        s.fxPitch.bypass = !f.pitchOn
        s.fxPitch.pitch = f.pitchCents
        s.fxGlue.bypass = !f.glueOn
        let au = s.fxGlue.audioUnit
        AudioUnitSetParameter(au, kDynamicsProcessorParam_Threshold, kAudioUnitScope_Global, 0, f.glueThreshold, 0)
        AudioUnitSetParameter(au, kDynamicsProcessorParam_HeadRoom, kAudioUnitScope_Global, 0, max(0.1, min(40, 40 / max(1, f.glueRatio))), 0)
        AudioUnitSetParameter(au, kDynamicsProcessorParam_OverallGain, kAudioUnitScope_Global, 0, f.glueGain, 0)
    }

    let distortionPresets: [(String, AVAudioUnitDistortionPreset)] = [
        ("Lo-Fi drums", .drumsLoFi), ("Bit brush", .drumsBitBrush), ("Buffer beats", .drumsBufferBeats),
        ("Broken speaker", .multiBrokenSpeaker), ("Cellphone concert", .multiCellphoneConcert),
        ("Decimator (bitcrush)", .multiDecimated1), ("Decimator 2", .multiDecimated2),
        ("Everything is broken", .multiEverythingIsBroken), ("Radio tower", .speechRadioTower),
        ("Waves", .speechWaves), ("Alien chatter", .speechAlienChatter), ("Cosmic interference", .speechCosmicInterference),
        ("Golden pi", .speechGoldenPi)]

    private var anySolo: Bool { strips.values.contains { $0.s.solo } }

    // MARK: strips
    func makeAppStrip(for group: [AudioProcessInfo]) -> Strip {
        let p = group.first(where: { $0.groupID == $0.bundleID }) ?? group[0]
        let strip = Strip(id: p.groupID, name: p.name, kind: .app)
        strip.processObjects = group.map { $0.id }
        strip.icon = CA.icon(forBundleID: p.groupID, pid: nil) ?? CA.icon(forBundleID: p.bundleID, pid: p.pid)
        let cap = AudioCapture()
        strip.capture = cap
        strip.voice.rate = format.sampleRate
        let node = ringSource(ring: cap.ring, srcRate: format.sampleRate, voice: strip.voice, pan: strip.panG, mod: strip.mod)
        strip.source = node
        attach(strip)
        strips[strip.id] = strip
        if cap.start(.processes(strip.processObjects, mute: true)) { captureOK += 1 }
        else { lastCaptureError = cap.lastStatus; captureFailures += 1 }
        return strip
    }

    /// Source node that plays a capture ring into the engine (with sample-rate conversion).
    func ringSource(ring: OpaquePointer, srcRate: Double, voice: VoiceDSP? = nil, capture: AudioCapture? = nil, pan: UnsafeMutablePointer<Float>? = nil, mod: ModFX? = nil) -> AVAudioSourceNode {
        let player = RingPlayer(), mono = monoFlag
        let engineRate = format.sampleRate
        return AVAudioSourceNode(format: format) { _, _, frames, abl in
            let list = UnsafeMutableAudioBufferListPointer(abl)
            guard list.count >= 2, let l = list[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = list[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            player.render(ring: ring, n: Int(frames), ratio: (capture?.rate ?? srcRate) / engineRate, l: l, r: r)
            voice?.process(l, r, min(Int(frames), 8192))
            if mono.pointee { for i in 0..<min(Int(frames), 8192) { let m = (l[i] + r[i]) * 0.5; l[i] = m; r[i] = m } }
            mod?.process(l, r, min(Int(frames), 16384))
            if let g = pan {      // stereo pan: the left and right signals are each placed anywhere in the stereo field
                let a = g[0], b = g[1], c = g[2], d = g[3]
                if !(a == 1 && b == 0 && c == 0 && d == 1) {
                    for i in 0..<min(Int(frames), 16384) { let x = l[i], y = r[i]; l[i] = a * x + c * y; r[i] = b * x + d * y }
                }
            }
            return noErr
        }
    }

    /// A hardware input (mic / interface channels) as a mixer channel.
    func addInput(_ cfg: InputConfig) -> Bool {
        guard strips[cfg.id] == nil, let dev = inputDeviceID(cfg.uid) else { return false }
        let strip = Strip(id: cfg.id, name: cfg.label, kind: .input)
        strip.inputUID = cfg.uid
        strip.s.toMonitor = false          // default: stream only, so a mic doesn't feed back into your headphones
        let cap = AudioCapture()
        cap.channelOffset = cfg.offset; cap.monoInput = cfg.mono
        strip.capture = cap
        strip.voice.rate = format.sampleRate
        strip.source = ringSource(ring: cap.ring, srcRate: CA.nominalRate(dev), voice: strip.voice, capture: cap, pan: strip.panG, mod: strip.mod)
        strip.backupUID = cfg.backupUID
        attach(strip)
        strips[strip.id] = strip
        if cap.start(.device(dev)) { strip.isActive = true } else { strip.isActive = false; lastInputError = cap.lastStatus }
        return true
    }
    var lastInputError: OSStatus = 0
    func inputDeviceID(_ uid: String) -> AudioObjectID? {
        if uid == "default" { let d = CA.defaultInput(); return d != 0 ? d : nil }
        return CA.deviceID(forUID: uid)
    }

    /// Re-open input devices that were unplugged / dropped (called every few seconds).
    func reconnectInputs() {
        for s in strips.values where s.kind == .input {
            guard let cap = s.capture, let uid = s.inputUID else { continue }
            var dev = inputDeviceID(uid)
            var backup = false
            if dev == nil, let b = s.backupUID, let bd = inputDeviceID(b) { dev = bd; backup = true }
            if backup != s.usingBackup {
                s.usingBackup = backup
                onEvent?(backup ? "Input \(s.name): main device missing, switched to the backup input" : "Input \(s.name): main device is back, switched back from the backup")
                if cap.running { cap.stop() }
            }
            if let dev {
                if cap.running && cap.activeDevice != dev { cap.stop() }       // default mic changed
                if !cap.running { s.isActive = cap.start(.device(dev)) } else { s.isActive = true }
            } else { if cap.running { cap.stop() }; s.isActive = false }
            if s.isActive != s.wasActive {
                s.wasActive = s.isActive
                onEvent?(s.isActive ? "Input \(s.name): receiving again" : "Input \(s.name): lost (unplugged or device failure). Retrying every few seconds")
            }
        }
    }
    var onEvent: ((String) -> Void)?

    /// Plays submix i on its own output device (nil = stop). Reuses the shared output device handling.
    func setSubmixOutput(_ i: Int, uid: String?) {
        let id = "submix\(i + 1)"
        if let old = subOutTarget[i] { auxOutputs[old]?.removeFeed(id) }
        flags[4 + i] = 0; subOutTarget[i] = nil
        guard let target = uid, CA.deviceID(forUID: target) != nil else { return }
        cring_reset(subRing[i])
        let out = auxOutputs[target] ?? AuxOutput(uid: target)
        auxOutputs[target] = out
        out.addFeed(id: id, ring: subRing[i], engineRate: format.sampleRate)
        subOutTarget[i] = target; flags[4 + i] = 1
    }
    /// Plays a copy of the stream mix on an output device, so you hear exactly what OBS / vMix receive.
    func setStreamMonitor(on: Bool, uid: String?) {
        if let old = monUID { auxOutputs[old]?.removeFeed("streamMonitor"); monUID = nil }
        streamMonTap = nil
        guard on, !safeMode else { return }
        let target = (uid?.isEmpty ?? true) ? CA.deviceUID(CA.defaultOutput()) : uid!
        guard !target.isEmpty else { return }
        cring_reset(streamMonRing)
        let out = auxOutputs[target] ?? AuxOutput(uid: target)
        auxOutputs[target] = out
        out.addFeed(id: "streamMonitor", ring: streamMonRing, engineRate: format.sampleRate)
        let ring = streamMonRing, scratch = monScratch
        streamMonTap = { buf in
            guard let ch = buf.floatChannelData else { return }
            let n = min(Int(buf.frameLength), 16384)
            let r = buf.format.channelCount > 1 ? ch[1] : ch[0]
            for i in 0..<n { scratch[i * 2] = ch[0][i]; scratch[i * 2 + 1] = r[i] }
            _ = cring_write(ring, scratch, UInt32(n))
        }
        monUID = target
    }
    /// Turns a channel's pre-fader listen on or off and starts or stops the headphone feed as needed.
    func applyPFL(_ s: Strip) {
        s.cueMixer.outputVolume = (s.pfl && !safeMode) ? 1 : 0
        let any = strips.values.contains { $0.pfl } && !safeMode
        if any && cueTarget == nil { reloadCue() }      // first use: open the headphone output once
        flags[3] = any ? 1 : 0                          // turning PFL off just stops feeding it; the output is left alone
    }
    /// Opens (or moves) the headphone feed. Called the first time PFL is used and when you pick another device.
    func reloadCue() {
        flags[3] = 0
        if let old = cueTarget { auxOutputs[old]?.removeFeed("cue"); cueTarget = nil }
        guard !safeMode, strips.values.contains(where: { $0.pfl }) else { return }
        let target = (cueUID?.isEmpty ?? true) ? CA.deviceUID(CA.defaultOutput()) : cueUID!
        guard !target.isEmpty else { return }
        cring_reset(cueRing)
        let out = auxOutputs[target] ?? AuxOutput(uid: target)
        auxOutputs[target] = out
        out.addFeed(id: "cue", ring: cueRing, engineRate: format.sampleRate)
        cueTarget = target
        flags[3] = 1
    }
    var safeMode = false

    /// Attach the shared per-strip chain: source -> EQ -> compressor -> mixer -> (master, reverb send, delay send)
    func attach(_ strip: Strip) {
        strip.engine = self
        strip.eq = AVAudioUnitEQ(numberOfBands: 10)
        for (i, f) in eqFrequencies.enumerated() {
            let b = strip.eq.bands[i]; b.filterType = .parametric; b.frequency = f; b.bandwidth = 1.0; b.gain = 0
        }
        let desc = AudioComponentDescription(componentType: kAudioUnitType_Effect,
                                             componentSubType: kAudioUnitSubType_DynamicsProcessor,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0, componentFlagsMask: 0)
        strip.comp = AVAudioUnitEffect(audioComponentDescription: desc)
        strip.comp.bypass = true
        strip.mixer = AVAudioMixerNode()
        strip.fxFilter.bands[0].filterType = .highPass; strip.fxFilter.bands[0].frequency = 80; strip.fxFilter.bands[0].bypass = true
        strip.fxFilter.bands[1].filterType = .lowPass; strip.fxFilter.bands[1].frequency = 8000; strip.fxFilter.bands[1].bypass = true
        strip.fxDist.bypass = true; strip.fxPitch.bypass = true; strip.fxGlue.bypass = true
        engine.attach(strip.source); engine.attach(strip.eq); engine.attach(strip.comp); engine.attach(strip.mixer)
        for n in [strip.fxFilter, strip.fxDist, strip.fxPitch, strip.fxGlue] as [AVAudioNode] { engine.attach(n) }
        engine.connect(strip.source, to: strip.eq, format: format)
        engine.connect(strip.eq, to: strip.comp, format: format)
        engine.connect(strip.comp, to: strip.fxFilter, format: format)
        engine.connect(strip.fxFilter, to: strip.fxDist, format: format)
        engine.connect(strip.fxDist, to: strip.fxPitch, format: format)
        engine.connect(strip.fxPitch, to: strip.fxGlue, format: format)
        engine.attach(strip.cueMixer)
        engine.connect(strip.fxGlue, to: [AVAudioConnectionPoint(node: strip.mixer, bus: 0),
                                          AVAudioConnectionPoint(node: strip.cueMixer, bus: 0)], fromBus: 0, format: format)
        engine.connect(strip.cueMixer, to: cueBus, format: format)
        strip.cueMixer.outputVolume = 0
        let pts = [AVAudioConnectionPoint(node: masterBus, bus: masterBus.nextAvailableInputBus),
                   AVAudioConnectionPoint(node: reverbIn, bus: reverbIn.nextAvailableInputBus),
                   AVAudioConnectionPoint(node: delayIn, bus: delayIn.nextAvailableInputBus),
                   AVAudioConnectionPoint(node: streamBus, bus: streamBus.nextAvailableInputBus),
                   AVAudioConnectionPoint(node: recBus, bus: recBus.nextAvailableInputBus),
                   AVAudioConnectionPoint(node: subIn[0], bus: subIn[0].nextAvailableInputBus),
                   AVAudioConnectionPoint(node: subIn[1], bus: subIn[1].nextAvailableInputBus),
                   AVAudioConnectionPoint(node: meetingBus, bus: meetingBus.nextAvailableInputBus)]
        strip.masterIdx = pts[0].bus; strip.reverbBus = pts[1].bus; strip.delayBus = pts[2].bus; strip.streamIdx = pts[3].bus; strip.recIdx = pts[4].bus; strip.subBus = [pts[5].bus, pts[6].bus]; strip.meetingIdx = pts[7].bus
        engine.connect(strip.mixer, to: pts, fromBus: 0, format: format)
        let meter = strip.meter
        strip.mixer.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak strip] buf, _ in
            strip?.recordTap?(buf)
            guard let ch = buf.floatChannelData else { return }
            if let ring = strip?.auxRing, let sc = strip?.auxScratch {
                let n = min(Int(buf.frameLength), 16384)
                let rr = buf.format.channelCount > 1 ? ch[1] : ch[0]
                for i in 0..<n { sc[i * 2] = ch[0][i]; sc[i * 2 + 1] = rr[i] }
                _ = cring_write(ring, sc, UInt32(n))
            }
            var l: Float = 0, r: Float = 0
            vDSP_maxmgv(ch[0], 1, &l, vDSP_Length(buf.frameLength))
            vDSP_maxmgv(ch[1], 1, &r, vDSP_Length(buf.frameLength))
            meter.l = l; meter.r = r
        }
        apply(strip)
    }

    func removeStrip(_ id: String) {
        guard let s = strips.removeValue(forKey: id) else { return }
        routeStrip(s, to: nil)
        s.capture?.stop()
        s.mixer.removeTap(onBus: 0)
        s.cueMixer.removeTap(onBus: 0)
        s.pluginSlot.window?.close()
        // Detaching nodes while the engine runs crashed macOS's audio engine (seen twice in crash reports), so stop it briefly.
        let wasRunning = running && !standingAside
        if wasRunning { engine.pause() }
        defer { if wasRunning { try? engine.start() } }
        engine.disconnectNodeOutput(s.mixer)
        // every node the strip owns, so none is left connected to a node that is gone (this crashed AVAudioEngine)
        for n in ([s.source, s.eq, s.comp, s.fxFilter, s.fxDist, s.fxPitch, s.fxGlue, s.cueMixer, s.mixer] as [AVAudioNode]) + (s.pluginSlot.unit.map { [$0] } ?? []) where n.engine != nil { engine.detach(n) }
    }

    func apply(_ s: Strip) {
        guard let eq = s.eq, let mixer = s.mixer else { return }
        let st = s.s
        for i in 0..<10 { eq.bands[i].gain = st.eqEnabled ? st.eq[i] : 0 }
        // Compressor (Apple DynamicsProcessor). Ratio is approximated through headroom.
        s.comp.bypass = !st.compEnabled
        let au = s.comp.audioUnit
        AudioUnitSetParameter(au, kDynamicsProcessorParam_Threshold, kAudioUnitScope_Global, 0, st.compThreshold, 0)
        AudioUnitSetParameter(au, kDynamicsProcessorParam_HeadRoom, kAudioUnitScope_Global, 0, max(0.1, min(40, 40 / max(1, st.compRatio))), 0)
        AudioUnitSetParameter(au, kDynamicsProcessorParam_AttackTime, kAudioUnitScope_Global, 0, st.compAttack, 0)
        AudioUnitSetParameter(au, kDynamicsProcessorParam_ReleaseTime, kAudioUnitScope_Global, 0, st.compRelease, 0)
        AudioUnitSetParameter(au, kDynamicsProcessorParam_OverallGain, kAudioUnitScope_Global, 0, st.compMakeup, 0)
        let v = s.voice
        v.hpfOn = st.hpfOn; v.hpfFreq = st.hpfFreq
        v.agcOn = st.agcOn && !safeMode; v.agcTargetDB = st.agcTarget
        v.mbOn = st.mbOn && !safeMode; v.mbThresholdDB = st.mbThreshold; v.mbRatio = st.mbRatio
        v.satOn = st.satOn && !safeMode; v.satDrive = st.satDrive
        v.exOn = st.exOn && !safeMode; v.exAmount = st.exAmount
        v.tsOn = st.tsOn && !safeMode; v.tsAttack = st.tsAttack; v.tsSustain = st.tsSustain
        v.nrOn = st.nrOn && !safeMode; v.nrAmount = st.nrAmount
        v.gateOn = st.gateOn && !safeMode; v.gateThresholdDB = st.gateThreshold; v.gateFloorDB = st.gateFloor
        v.deessOn = st.deessOn && !safeMode; v.deessAmount = st.deessAmount
        if v.delayMs != st.delayMs { v.delayMs = st.delayMs }
        let audible = !st.mute && (!anySolo || st.solo)
        var vca: Float = 1
        if let g = st.group, master.vcaDB.indices.contains(g), master.vcaMute.indices.contains(g) {
            vca = master.vcaMute[g] ? 0 : pow(10, master.vcaDB[g] / 20)
        }
        mixer.outputVolume = audible ? st.linearGain * s.duck * s.padDuck * s.xfade * vca : 0
        mixer.pan = 0     // pan is set per destination in applyPans (a channel feeds several mixes)
        func place(_ p: Float) -> (Float, Float) { let a = (max(-1, min(1, p)) + 1) * Float.pi / 4; return (cos(a), sin(a)) }
        let m = s.mod
        m.sampleRate = Float(format.sampleRate)
        m.mode = safeMode ? 0 : st.modMode; m.rate = st.modRate; m.depth = st.modDepth; m.mix = st.modMix
        let pl = place(st.panL), pr = place(st.panR)
        let a = pl.0, b = pl.1, c = pr.0, d = pr.1                 // pan: left signal -> (a, b), right signal -> (c, d)
        let sL: Float = st.invertL ? -1 : 1, sR: Float = st.invertR ? -1 : 1
        let kA = (1 + st.width) / 2, kB = (1 - st.width) / 2      // width (mid/side): 1 = unchanged, 0 = mono
        // order matters for the audio thread: write all four values, they are plain floats
        s.panG[0] = sL * (a * kA + c * kB)     // left in  -> left out
        s.panG[1] = sL * (b * kA + d * kB)     // left in  -> right out
        s.panG[2] = sR * (a * kB + c * kA)     // right in -> left out
        s.panG[3] = sR * (b * kB + d * kA)     // right in -> right out
        applyChannelFX(s, st.fx)
        routeStrip(s, to: st.outputUID)
        let direct: Float = (st.subOnly && (st.sub1 > 0 || st.sub2 > 0)) ? 0 : 1      // "only through submix": the direct paths go quiet
        s.mixer.destination(forMixer: masterBus, bus: s.masterIdx)?.volume = (st.toMonitor && st.outputUID == nil) ? direct : 0
        if let u = s.auxUID { auxOutputs[u]?.setVolume(s.id, st.toMonitor ? 1 : 0) }
        s.mixer.destination(forMixer: streamBus, bus: s.streamIdx)?.volume = st.toStream ? direct : 0
        applyPans(s)
        s.mixer.destination(forMixer: recBus, bus: s.recIdx)?.volume = st.toRecord ? direct : 0
        s.mixer.destination(forMixer: meetingBus, bus: s.meetingIdx)?.volume = st.toMeeting ? direct : 0
        s.mixer.destination(forMixer: subIn[0], bus: s.subBus[0])?.volume = st.sub1
        s.mixer.destination(forMixer: subIn[1], bus: s.subBus[1])?.volume = st.sub2
        s.mixer.destination(forMixer: reverbIn, bus: s.reverbBus)?.volume = st.reverbSend
        s.mixer.destination(forMixer: delayIn, bus: s.delayBus)?.volume = st.delaySend
        syncStripPlugin(s)
    }

    // MARK: per-channel output device
    var auxOutputs: [String: AuxOutput] = [:]
    func routeStrip(_ s: Strip, to uid: String?) {
        let target = (safeMode || (uid?.isEmpty ?? true)) ? nil : uid
        if s.auxUID == target { return }
        if let old = s.auxUID { auxOutputs[old]?.removeFeed(s.id) }
        s.auxUID = target
        guard let t = target else { s.auxRing = nil; return }
        if s.auxScratch == nil { s.auxScratch = UnsafeMutablePointer<Float>.allocate(capacity: 16384 * 2); s.auxScratch!.initialize(repeating: 0, count: 16384 * 2) }
        let ring = cring_create(96000, 2)!
        let out = auxOutputs[t] ?? AuxOutput(uid: t)
        auxOutputs[t] = out
        out.addFeed(id: s.id, ring: ring, engineRate: format.sampleRate)
        s.auxRing = ring
    }
    /// Restart secondary outputs after audio restarts / device changes.
    func ensureAux() {
        if let m = monUID, auxOutputs[m]?.running == false, CA.deviceID(forUID: m) != nil { setStreamMonitor(on: true, uid: m) }
        for i in 0..<2 { if let t = subOutTarget[i], auxOutputs[t]?.running == false, CA.deviceID(forUID: t) != nil { setSubmixOutput(i, uid: t) } }
        for i in 0..<2 where subOutTarget[i] == nil && master.subOutUID.indices.contains(i) && !master.subOutUID[i].isEmpty && !safeMode && CA.deviceID(forUID: master.subOutUID[i]) != nil { setSubmixOutput(i, uid: master.subOutUID[i]) }
        for (uid, out) in auxOutputs where !out.running {
            guard CA.deviceID(forUID: uid) != nil else { continue }
            for s in strips.values where s.auxUID == uid { let u = uid; s.auxUID = nil; routeStrip(s, to: u) }
        }
    }

    // MARK: process discovery
    /// Apps the user removed by hand; they stay off until added again from the + slot.
    var dismissed = Set<String>()
    /// Off by default: LoopNest only touches an app (Zoom, a browser, ...) after you add it with "Add mic or app".
    var autoAddApps = false
    func syncProcesses(_ procs: [AudioProcessInfo], onChange: () -> Void) {
        var changed = false
        let now = Date()
        let groups = Dictionary(grouping: procs, by: { $0.groupID })
        for (gid, members) in groups {
            let ids = members.map { $0.id }.sorted()
            let playing = members.contains { $0.isRunningOutput }
            if let s = strips[gid], s.kind == .app {
                s.lastSeen = now
                if s.processObjects.sorted() != ids {          // helper started/stopped or app restarted
                    s.processObjects = ids
                    if s.capture?.start(.processes(ids, mute: true)) == true { captureOK += 1 }
                }
                if s.isActive != playing { s.isActive = playing }
            } else if autoAddApps && playing && !dismissed.contains(gid) {
                _ = makeAppStrip(for: members); changed = true
            }
        }
        for (id, s) in strips where s.kind == .app && now.timeIntervalSince(s.lastSeen) > 15 {
            removeStrip(id); changed = true
        }
        if changed { onChange() }
    }

    /// Add a strip for an app that isn't playing yet (the "Add app" slot).
    func addApp(group members: [AudioProcessInfo]) -> Bool {
        if let g = members.first?.groupID { dismissed.remove(g) }
        guard let first = members.first, strips[first.groupID] == nil else { return false }
        _ = makeAppStrip(for: members)
        return true
    }

    // MARK: ducking
    func updateDucking() {
        let callLevel = strips.values.filter { callApps.contains($0.id) && !$0.s.mute }
            .map { max($0.meter.l, $0.meter.r) }.max() ?? 0
        let talking = master.duckingOn && callLevel > 0.01     // ~ -40 dB
        let target = talking ? pow(10, master.duckAmountDB / 20) : 1
        for s in strips.values {
            let t: Float = (s.s.duckable && !callApps.contains(s.id)) ? target : 1
            let k: Float = t < s.duck ? 0.35 : 0.03       // fast attack, slow release
            let new = s.duck + (t - s.duck) * k
            if abs(new - s.duck) > 0.002 { s.duck = new; apply(s) }
        }
        // Soundboard + "lower music when I talk" ducking
        let micLevel = strips.values.filter { $0.kind == .input && !$0.s.mute }.map { max($0.meter.l, $0.meter.r) }.max() ?? 0
        if master.micDuckOn && micLevel > pow(10, master.micDuckThreshold / 20) { micLastTalk = Date() }
        let voiceTarget: Float = (master.micDuckOn && Date().timeIntervalSince(micLastTalk) < 0.7) ? pow(10, master.micDuckDB / 20) : 1
        for s in strips.values {
            var t: Float = 1
            switch s.kind {
            case .input: t = padMicTarget
            case .app: t = padAppsTarget * voiceTarget
            case .deck: t = voiceTarget
            case .board: t = 1
            }
            let k: Float = t < s.padDuck ? 0.3 : 0.04
            let new = s.padDuck + (t - s.padDuck) * k
            if abs(new - s.padDuck) > 0.002 || (t == 1 && new != 1 && abs(new - 1) < 0.002) { s.padDuck = abs(new - t) < 0.002 ? t : new; apply(s) }
        }
    }
    var padMicTarget: Float = 1
    var padAppsTarget: Float = 1
    private var micLastTalk = Date.distantPast

    // MARK: test tone (checks that OBS / vMix hear the stream device)
    private var toneNode: AVAudioSourceNode?
    func setTestTone(_ on: Bool) {
        if toneNode == nil {
            final class Phase { var p: Double = 0 }
            let ph = Phase(), rate = format.sampleRate
            let node = AVAudioSourceNode(format: format) { _, _, frames, abl in
                let list = UnsafeMutableAudioBufferListPointer(abl)
                let step = 2 * Double.pi * 1000 / rate
                for i in 0..<Int(frames) {
                    let v = Float(sin(ph.p)) * 0.125          // about -18 dBFS
                    ph.p += step; if ph.p > 2 * Double.pi { ph.p -= 2 * Double.pi }
                    for b in list { b.mData?.assumingMemoryBound(to: Float.self)[i] = v }
                }
                return noErr
            }
            let wasRunning = running && !standingAside
            if wasRunning { engine.pause() }
            engine.attach(node)
            engine.connect(node, to: streamBus, format: format)
            toneNode = node
            if wasRunning { try? engine.start() }
        }
        toneNode?.volume = on ? 1 : 0
    }

    // MARK: master metering, spectrum, recording tap
    private func installMasterTap() {
        outMixer.removeTap(onBus: 0)
        let mm = masterMeter
        outMixer.installTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] buf, _ in
            guard let self, let ch = buf.floatChannelData else { return }
            let n = Int(buf.frameLength)
            var l: Float = 0, r: Float = 0
            vDSP_maxmgv(ch[0], 1, &l, vDSP_Length(n))
            vDSP_maxmgv(ch[buf.format.channelCount > 1 ? 1 : 0], 1, &r, vDSP_Length(n))
            mm.l = l; mm.r = r
            self.computeSpectrum(ch[0], n)
            self.recorderTap?(buf)
        }
    }

    // Spectrum scratch buffers are allocated once; the audio-side tap only does the FFT while a spectrum is on screen.
    var spectrumActive = false
    private lazy var specReal = [Float](repeating: 0, count: 1024)
    private lazy var specImag = [Float](repeating: 0, count: 1024)
    private lazy var specMags = [Float](repeating: 0, count: 1024)
    private lazy var specWindowed = [Float](repeating: 0, count: 2048)
    private lazy var specWindow: [Float] = { var w = [Float](repeating: 0, count: 2048); vDSP_hann_window(&w, 2048, Int32(vDSP_HANN_NORM)); return w }()
    private lazy var specBands: [(Int, Int)] = (0..<32).map { b in
        let lo = Int(pow(1024.0, Double(b) / 32.0)), hi = max(lo + 1, Int(pow(1024.0, Double(b + 1) / 32.0)))
        return (min(lo, 1023), min(hi, 1024))
    }

    private func computeSpectrum(_ data: UnsafePointer<Float>, _ n: Int) {
        guard spectrumActive, let setup = fftSetup, n >= 2048 else { return }
        vDSP_vmul(data, 1, specWindow, 1, &specWindowed, 1, 2048)
        specReal.withUnsafeMutableBufferPointer { rp in
            specImag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                specWindowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: 1024) { vDSP_ctoz($0, 2, &split, 1, 1024) }
                }
                vDSP_fft_zrip(setup, &split, 1, 11, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &specMags, 1, 1024)
            }
        }
        for b in 0..<32 {
            let (lo, hi) = specBands[b]
            var m: Float = 0
            for k in lo..<hi { m = max(m, specMags[k]) }
            let db = 20 * log10(max(m / 64, 1e-6))
            spectrum[b] = max(0, min(1, (db + 70) / 70))
        }
    }
}

extension MixerEngine {
    func registerStrip(_ s: Strip) { strips[s.id] = s }
}
