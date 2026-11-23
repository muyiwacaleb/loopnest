import Foundation
import AVFoundation
import AudioToolbox
import CRing

/// Plays selected channels on a different output device (for example Discord in headphones, music on speakers).
final class AuxOutput {
    let uid: String
    private let eng = AVAudioEngine()
    private let mix = AVAudioMixerNode()
    private struct Feed { let node: AVAudioSourceNode }
    private var feeds: [String: Feed] = [:]
    private(set) var running = false
    private var rate: Double = 48000

    init(uid: String) { self.uid = uid }

    @discardableResult func start() -> Bool {
        if running && eng.isRunning { return true }
        guard let dev = CA.deviceID(forUID: uid), let unit = eng.outputNode.audioUnit else { return false }
        var id = dev
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioObjectID>.size))
        rate = eng.outputNode.inputFormat(forBus: 0).sampleRate
        if rate <= 0 { rate = 48000 }
        if mix.engine == nil {
            eng.attach(mix)
            eng.connect(mix, to: eng.outputNode, format: AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        }
        do { try eng.start(); running = true } catch { running = false }
        return running
    }

    func addFeed(id: String, ring: OpaquePointer, engineRate: Double) {
        removeFeed(id)
        guard start() else { return }
        let player = RingPlayer()
        let ratio = engineRate / rate
        let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let node = AVAudioSourceNode(format: fmt) { _, _, frames, abl in
            let list = UnsafeMutableAudioBufferListPointer(abl)
            guard list.count >= 2, let l = list[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = list[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            player.render(ring: ring, n: Int(frames), ratio: ratio, l: l, r: r)
            return noErr
        }
        eng.attach(node)
        eng.connect(node, to: mix, format: fmt)
        feeds[id] = Feed(node: node)
    }

    func setVolume(_ id: String, _ v: Float) { feeds[id]?.node.volume = v }

    func removeFeed(_ id: String) {
        guard let f = feeds.removeValue(forKey: id) else { return }
        eng.disconnectNodeOutput(f.node); eng.detach(f.node)
    }

    func stop() { eng.stop(); running = false }
}
