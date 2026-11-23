import Foundation
import CoreAudio
import AudioToolbox
import CRing

/// Captures stereo audio into a ring buffer. Either a single app (process tap) or a hardware input device.
final class AudioCapture {
    enum Kind { case processes([AudioObjectID], mute: Bool), device(AudioObjectID) }

    let ring: OpaquePointer
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var devID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "loopnest.capture", qos: .userInteractive)
    private(set) var running = false
    var activeDevice: AudioObjectID { devID }
    private(set) var lastStatus: OSStatus = 0
    var processIDs: [AudioObjectID] = []
    var channelOffset = 0
    var monoInput = false
    private var scratch = [Float](repeating: 0, count: 16384 * 2)

    /// Peak level written by IO thread (read by UI).
    var peakL: Float = 0
    var peakR: Float = 0
    var clipCount = 0                 // buffers that hit full scale
    var rate: Double = 48000          // sample rate of the device currently feeding the ring

    init() {
        ring = cring_create(48000, 2)!
    }
    deinit {
        stop()
        cring_destroy(ring)
    }

    func start(_ kind: Kind) -> Bool {
        stop()
        switch kind {
        case .processes(let objs, let mute): return startTap(objs, mute: mute)
        case .device(let id): return startDevice(id)
        }
    }

    private func startTap(_ processes: [AudioObjectID], mute: Bool) -> Bool {
        guard #available(macOS 14.4, *) else { return false }
        let desc = CATapDescription(stereoMixdownOfProcesses: processes)
        desc.uuid = UUID()
        desc.muteBehavior = mute ? .mutedWhenTapped : .unmuted
        desc.isPrivate = true
        var tap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(desc, &tap)
        lastStatus = tapStatus
        guard tapStatus == noErr else { return false }
        tapID = tap

        let outUID = CA.deviceUID(CA.defaultOutput())
        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "LoopNestTap",
            kAudioAggregateDeviceUIDKey: "LoopNestTap.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: desc.uuid.uuidString,
            ]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &agg)
        lastStatus = aggStatus
        guard aggStatus == noErr else {
            AudioHardwareDestroyProcessTap(tap); tapID = AudioObjectID(kAudioObjectUnknown); return false
        }
        aggID = agg
        return startIO(on: agg)
    }

    private func startDevice(_ id: AudioObjectID) -> Bool {
        devID = id
        rate = CA.nominalRate(id)
        return startIO(on: id)
    }

    private func startIO(on device: AudioObjectID) -> Bool {
        let ringPtr = ring
        var pid: AudioDeviceIOProcID?
        let st = AudioDeviceCreateIOProcIDWithBlock(&pid, device, queue) { [unowned self] _, inData, _, _, _ in
            self.handleInput(inData, ring: ringPtr)
        }
        guard st == noErr, let pid else { teardown(); return false }
        procID = pid
        guard AudioDeviceStart(device, pid) == noErr else { teardown(); return false }
        running = true
        return true
    }

    private func handleInput(_ inData: UnsafePointer<AudioBufferList>, ring: OpaquePointer) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
        guard abl.count > 0 else { return }
        var frames = 0
        scratch.withUnsafeMutableBufferPointer { sp in
            let out = sp.baseAddress!
            if abl.count == 1 {
                let b = abl[0]
                let ch = Int(b.mNumberChannels)
                guard let data = b.mData?.assumingMemoryBound(to: Float.self), ch > 0 else { return }
                frames = min(Int(b.mDataByteSize) / (MemoryLayout<Float>.size * ch), 16384)
                let off = min(channelOffset, ch - 1)
                for i in 0..<frames {
                    let a = data[i * ch + off]
                    out[i * 2] = a
                    out[i * 2 + 1] = (!monoInput && off + 1 < ch) ? data[i * ch + off + 1] : a
                }
            } else {
                let li = min(channelOffset, abl.count - 1)
                guard let l = abl[li].mData?.assumingMemoryBound(to: Float.self) else { return }
                let r = (monoInput ? nil : (li + 1 < abl.count ? abl[li + 1].mData?.assumingMemoryBound(to: Float.self) : nil)) ?? l
                frames = min(Int(abl[li].mDataByteSize) / MemoryLayout<Float>.size, 16384)
                for i in 0..<frames { out[i * 2] = l[i]; out[i * 2 + 1] = r[i] }
            }
            var pl: Float = 0, pr: Float = 0
            for i in 0..<frames { pl = max(pl, abs(out[i * 2])); pr = max(pr, abs(out[i * 2 + 1])) }
            peakL = pl; peakR = pr
            if max(pl, pr) >= 0.995 { clipCount &+= 1 }
            _ = cring_write(ring, out, UInt32(frames))
        }
    }

    func stop() {
        guard running || tapID != kAudioObjectUnknown || aggID != kAudioObjectUnknown else { return }
        teardown()
        running = false
    }

    private func teardown() {
        let dev = aggID != kAudioObjectUnknown ? aggID : devID
        if let procID, dev != kAudioObjectUnknown {
            AudioDeviceStop(dev, procID)
            AudioDeviceDestroyIOProcID(dev, procID)
        }
        procID = nil
        if aggID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggID); aggID = AudioObjectID(kAudioObjectUnknown) }
        if tapID != kAudioObjectUnknown {
            if #available(macOS 14.4, *) { AudioHardwareDestroyProcessTap(tapID) }
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        devID = AudioObjectID(kAudioObjectUnknown)
    }
}
