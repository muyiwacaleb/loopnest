import Foundation
import AVFoundation
import AudioToolbox
import CRing
import os

/// Immutable snapshot handed to the render thread.
final class RoutePlan {
    struct Src { let ring: OpaquePointer; let gain: Float; let scratch: UnsafeMutablePointer<Float> }
    var srcs: [Src] = []
    var wires: [(src: Int, srcCh: Int, dest: Int)] = []
    var outGain: Float = 1
    deinit { for s in srcs { s.scratch.deallocate() } }
}

/// One Loopback-style virtual device: captures sources, mixes them through wires into the channels of a
/// driver slot, and optionally monitors the result on another device.
final class DeviceRouter {
    private(set) var config: VirtualDeviceConfig
    private let engine = AVAudioEngine()
    private var monitorEngine: AVAudioEngine?
    private var captures: [UUID: AudioCapture] = [:]
    private let lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
    private var plan = RoutePlan()
    private var monitorRing: OpaquePointer = cring_create(48000, 2)!
    let levels = UnsafeMutablePointer<Float>.allocate(capacity: 64)
    private(set) var running = false
    private(set) var statusText = "Stopped"
    var channelCount = 2

    init(config: VirtualDeviceConfig) {
        self.config = config
        lock.initialize(to: os_unfair_lock())
        levels.initialize(repeating: 0, count: 64)
    }
    deinit { stop(); cring_destroy(monitorRing) }

    func update(_ cfg: VirtualDeviceConfig) {
        let restart = cfg.slot != config.slot || cfg.monitorUID != config.monitorUID || cfg.monitorOn != config.monitorOn
        config = cfg
        if running && restart { stop(); start() } else { rebuild() }
    }

    func start() {
        guard config.enabled, !config.passThru else { statusText = config.passThru ? "Pass-Thru" : "Disabled"; return }
        guard let devID = CA.deviceID(forUID: "LoopNest.\(config.slot)") else {
            statusText = "Driver not installed (slot \(config.slot + 1) not found)"; return
        }
        guard let unit = engine.outputNode.audioUnit else { return }
        var id = devID
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id,
                             UInt32(MemoryLayout<AudioObjectID>.size))
        let fmt = engine.outputNode.inputFormat(forBus: 0)
        channelCount = Int(fmt.channelCount)
        guard channelCount > 0 else { statusText = "Device has no output channels"; return }
        let levelsPtr = levels
        let ch = channelCount
        let mRing = monitorRing
        let monitorScratch = UnsafeMutablePointer<Float>.allocate(capacity: 16384 * 2)
        monitorScratch.initialize(repeating: 0, count: 16384 * 2)

        let node = AVAudioSourceNode(format: fmt) { [weak self] _, _, frames, abl in
            guard let self else { return noErr }
            let list = UnsafeMutableAudioBufferListPointer(abl)
            let n = min(Int(frames), 16384)
            for b in list { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
            if os_unfair_lock_trylock(self.lock) {
                let p = self.plan
                os_unfair_lock_unlock(self.lock)
                for s in p.srcs {
                    var avail = Int(cring_available(s.ring))
                    while avail > n * 4 + 4800 {
                        let drop = min(avail - n * 2, 16384)
                        _ = cring_read(s.ring, s.scratch, UInt32(drop)); avail -= drop
                    }
                    _ = cring_read(s.ring, s.scratch, UInt32(n))
                }
                for w in p.wires where w.dest < list.count {
                    guard let out = list[w.dest].mData?.assumingMemoryBound(to: Float.self) else { continue }
                    let s = p.srcs[w.src]
                    for i in 0..<n { out[i] += s.scratch[i * 2 + w.srcCh] * s.gain }
                }
                for c in 0..<min(ch, list.count) {
                    guard let out = list[c].mData?.assumingMemoryBound(to: Float.self) else { continue }
                    var peak: Float = 0
                    for i in 0..<n { out[i] *= p.outGain; peak = max(peak, abs(out[i])) }
                    levelsPtr[c] = peak
                }
            }
            if list.count > 0, let l = list[0].mData?.assumingMemoryBound(to: Float.self) {
                let r = (list.count > 1 ? list[1].mData : list[0].mData)!.assumingMemoryBound(to: Float.self)
                for i in 0..<Int(min(frames, 16384)) { monitorScratch[i * 2] = l[i]; monitorScratch[i * 2 + 1] = r[i] }
                if self.config.monitorOn { _ = cring_write(mRing, monitorScratch, UInt32(min(frames, 16384))) }
            }
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.outputNode, format: fmt)
        rebuild()
        do { try engine.start(); running = true; statusText = "Running" } catch { statusText = "Engine error: \(error.localizedDescription)" }
        startMonitor()
    }

    func stop() {
        for c in captures.values { c.stop() }
        captures.removeAll()
        monitorEngine?.stop(); monitorEngine = nil
        if running { engine.stop() }
        running = false; statusText = "Stopped"
    }

    private func startMonitor() {
        guard config.monitorOn, let uid = config.monitorUID, let devID = CA.deviceID(forUID: uid) else { return }
        let m = AVAudioEngine()
        guard let unit = m.outputNode.audioUnit else { return }
        var id = devID
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id,
                             UInt32(MemoryLayout<AudioObjectID>.size))
        let rate = m.outputNode.inputFormat(forBus: 0).sampleRate
        let fmt = AVAudioFormat(standardFormatWithSampleRate: rate > 0 ? rate : 48000, channels: 2)!
        let ring = monitorRing
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 16384 * 2)
        scratch.initialize(repeating: 0, count: 16384 * 2)
        let node = AVAudioSourceNode(format: fmt) { _, _, frames, abl in
            let list = UnsafeMutableAudioBufferListPointer(abl)
            let n = min(Int(frames), 16384)
            var avail = Int(cring_available(ring))
            while avail > n * 4 + 4800 { let d = min(avail - n * 2, 16384); _ = cring_read(ring, scratch, UInt32(d)); avail -= d }
            _ = cring_read(ring, scratch, UInt32(n))
            guard list.count >= 2, let l = list[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = list[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            for i in 0..<n { l[i] = scratch[i * 2]; r[i] = scratch[i * 2 + 1] }
            return noErr
        }
        m.attach(node); m.connect(node, to: m.outputNode, format: fmt)
        try? m.start()
        monitorEngine = m
    }

    /// Re-create captures and the render plan from the current config. Cheap enough to call on every edit.
    func rebuild() {
        let active = config.sources.filter { $0.enabled }
        let activeIDs = Set(active.map { $0.id })
        for (id, c) in captures where !activeIDs.contains(id) { c.stop(); captures[id] = nil }

        let procs = CA.processes()
        let newPlan = RoutePlan()
        var indexOf: [UUID: Int] = [:]
        for src in active {
            let cap: AudioCapture
            if let c = captures[src.id] { cap = c } else { cap = AudioCapture(); captures[src.id] = cap }
            if !cap.running {
                switch src.kind {
                case .app:
                    let ids = procs.filter { $0.groupID == src.ref }.map { $0.id }
                    if !ids.isEmpty { _ = cap.start(.processes(ids, mute: config.muteOriginalApps)) }
                case .device:
                    if let d = CA.deviceID(forUID: src.ref) { _ = cap.start(.device(d)) }
                }
            }
            let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 16384 * 2)
            scratch.initialize(repeating: 0, count: 16384 * 2)
            let g: Float = src.mute ? 0 : pow(10, src.volumeDB / 20)
            indexOf[src.id] = newPlan.srcs.count
            newPlan.srcs.append(.init(ring: cap.ring, gain: g, scratch: scratch))
        }
        for w in config.wires {
            if let i = indexOf[w.sourceID], w.destChannel < channelCount { newPlan.wires.append((i, w.srcChannel, w.destChannel)) }
        }
        newPlan.outGain = pow(10, config.volumeDB / 20)
        os_unfair_lock_lock(lock)
        plan = newPlan
        os_unfair_lock_unlock(lock)
    }

    func sourceLevel(_ id: UUID) -> (Float, Float) {
        guard let c = captures[id] else { return (0, 0) }
        return (c.peakL, c.peakR)
    }
    func isSourceLive(_ id: UUID) -> Bool { captures[id]?.running ?? false }
}
