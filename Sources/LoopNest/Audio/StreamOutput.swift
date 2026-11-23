import Foundation
import AVFoundation
import AudioToolbox
import CRing

/// Plays the "stream mix" into the LoopNest Stream virtual device, so OBS / vMix / Zoom can pick it as an input.
final class StreamOutput {
    static let slot = 7
    static let uid = "LoopNest.7"
    static let deviceName = "LoopNest Stream"
    /// The second mix for calls ("Meeting mix"): only the channels switched to "Meeting" are in it.
    static let meetingSlot = 6
    static let meetingUID = "LoopNest.6"
    static let meetingName = "LoopNest Meeting"
    let uid: String
    let deviceName: String
    let countsHealth: Bool
    init(uid: String = StreamOutput.uid, deviceName: String = StreamOutput.deviceName, countsHealth: Bool = true) {
        self.uid = uid; self.deviceName = deviceName; self.countsHealth = countsHealth
    }

    private var eng: AVAudioEngine?
    private let player = RingPlayer()
    private(set) var running = false
    /// The device ID this engine was bound to. macOS gives the virtual device a new ID when the audio service restarts.
    private var boundID: AudioObjectID = 0
    /// False when macOS re-created the device (new ID) or an app such as OBS switched its sample rate, so this engine must restart.
    var isBoundToCurrentDevice: Bool {
        guard running, CA.deviceID(forUID: uid) == boundID else { return false }
        return abs(CA.nominalRate(boundID) - deviceRate) < 1
    }
    private(set) var statusText = "Driver not installed"
    private(set) var deviceRate: Double = 48000
    let meter = Meter()

    func start(ring: OpaquePointer, engineRate: Double) {
        guard !running else { return }
        guard let devID = CA.deviceID(forUID: uid) else { statusText = "Driver not installed"; return }
        let e = AVAudioEngine()
        guard let unit = e.outputNode.audioUnit else { return }
        var id = devID
        boundID = devID
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id,
                             UInt32(MemoryLayout<AudioObjectID>.size))
        let fmt = e.outputNode.inputFormat(forBus: 0)
        guard fmt.channelCount >= 1, fmt.sampleRate > 0 else { statusText = "Stream device has no output"; return }
        deviceRate = fmt.sampleRate
        let ratio = engineRate / fmt.sampleRate
        let player = self.player, meter = self.meter, counts = self.countsHealth
        let src = AVAudioSourceNode(format: AVAudioFormat(standardFormatWithSampleRate: fmt.sampleRate, channels: fmt.channelCount)!) { _, _, frames, abl in
            let t0 = mach_absolute_time()
            let h = Health.shared
            if counts { h.streamCallbacks &+= 1 }
            defer { if counts {
                let used = Health.seconds(mach_absolute_time() - t0), period = Double(frames) / fmt.sampleRate
                let pct = period > 0 ? used / period * 100 : 0
                h.renderLoad = h.renderLoad * 0.9 + pct * 0.1
                if pct > h.renderLoadPeak { h.renderLoadPeak = pct }
            } }
            let list = UnsafeMutableAudioBufferListPointer(abl)
            guard list.count >= 1, let l = list[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let r = (list.count > 1 ? list[1].mData : list[0].mData)!.assumingMemoryBound(to: Float.self)
            if list.count == 1 {   // single mono buffer
                let tmp = UnsafeMutablePointer<Float>.allocate(capacity: Int(frames)); defer { tmp.deallocate() }
                player.render(ring: ring, n: Int(frames), ratio: ratio, l: l, r: tmp)
            } else {
                player.render(ring: ring, n: Int(frames), ratio: ratio, l: l, r: r)
                if list.count > 2 { for c in 2..<list.count { if let d = list[c].mData { memset(d, 0, Int(list[c].mDataByteSize)) } } }
            }
            if counts { h.streamUnderruns = player.underruns }
            var pl: Float = 0, pr: Float = 0
            for i in 0..<Int(frames) { pl = max(pl, abs(l[i])); pr = max(pr, abs(r[i])) }
            meter.l = pl; meter.r = pr
            return noErr
        }
        e.attach(src)
        e.connect(src, to: e.outputNode, format: src.outputFormat(forBus: 0))
        NotificationCenter.default.removeObserver(self)
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: e, queue: .main) { [weak self] _ in self?.stop() }
        do { try e.start(); eng = e; running = true; statusText = "Sending to \(deviceName)" }
        catch { statusText = "Stream error: \(error.localizedDescription)" }
    }

    func stop() { NotificationCenter.default.removeObserver(self); eng?.stop(); eng = nil; running = false; statusText = "Stopped" }
}
