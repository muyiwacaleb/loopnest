import Foundation
import CoreAudio
import AppKit

struct AudioDeviceInfo: Identifiable, Hashable {
    var id: AudioObjectID
    var uid: String
    var name: String
    var inputChannels: Int
    var outputChannels: Int
    var sampleRate: Double
    var isVirtualLoopNest: Bool { uid.hasPrefix("LoopNest.") }
}

struct AudioProcessInfo: Identifiable, Hashable {
    var id: AudioObjectID          // process object id
    var pid: pid_t
    var bundleID: String
    var name: String
    var isRunningOutput: Bool
    var groupID: String           // helper processes (Chrome Helper, ...) share their parent app's id
}

enum CA {
    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func get<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, default def: T) -> T {
        var addr = address(sel, scope: scope)
        var value = def
        var size = UInt32(MemoryLayout<T>.size)
        let st = AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value)
        return st == noErr ? value : def
    }

    static func set<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, value: T) -> OSStatus {
        var addr = address(sel, scope: scope)
        var v = value
        return AudioObjectSetPropertyData(obj, &addr, 0, nil, UInt32(MemoryLayout<T>.size), &v)
    }

    static func getString(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector,
                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String {
        var addr = address(sel, scope: scope)
        var cf: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let st = AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &cf)
        guard st == noErr, let s = cf else { return "" }
        return s.takeRetainedValue() as String
    }

    static func getArray<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector,
                            scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, of: T.Type) -> [T] {
        var addr = address(sel, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(obj, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        var buf = [T](unsafeUninitializedCapacity: count) { p, n in n = count }
        let st = buf.withUnsafeMutableBytes { raw -> OSStatus in
            var s = size
            return AudioObjectGetPropertyData(obj, &addr, 0, nil, &s, raw.baseAddress!)
        }
        return st == noErr ? buf : []
    }

    static func channelCount(_ dev: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    // MARK: Devices
    static func devices() -> [AudioDeviceInfo] {
        let ids = getArray(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices, of: AudioObjectID.self)
        return ids.compactMap { id in
            // Skip private aggregate devices (our own taps).
            let uid = getString(id, kAudioDevicePropertyDeviceUID)
            if uid.hasPrefix("LoopNestTap.") { return nil }
            let inC = channelCount(id, scope: kAudioObjectPropertyScopeInput)
            let outC = channelCount(id, scope: kAudioObjectPropertyScopeOutput)
            if inC == 0 && outC == 0 { return nil }
            let rate: Float64 = get(id, kAudioDevicePropertyNominalSampleRate, default: 48000)
            return AudioDeviceInfo(id: id, uid: uid, name: getString(id, kAudioObjectPropertyName),
                                   inputChannels: inC, outputChannels: outC, sampleRate: rate)
        }
    }

    static func defaultOutput() -> AudioObjectID {
        get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID(0))
    }
    static func defaultInput() -> AudioObjectID {
        get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, default: AudioObjectID(0))
    }
    @discardableResult static func setDefaultOutput(_ id: AudioObjectID) -> OSStatus {
        set(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, value: id)
    }
    @discardableResult static func setDefaultInput(_ id: AudioObjectID) -> OSStatus {
        set(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, value: id)
    }
    @discardableResult static func setSampleRate(_ id: AudioObjectID, _ rate: Double) -> OSStatus {
        set(id, kAudioDevicePropertyNominalSampleRate, value: Float64(rate))
    }
    /// Smallest and largest buffer (in frames) the device accepts.
    static func bufferRange(_ id: AudioObjectID) -> ClosedRange<Int> {
        let r: AudioValueRange = get(id, kAudioDevicePropertyBufferFrameSizeRange, default: AudioValueRange(mMinimum: 32, mMaximum: 4096))
        return Int(r.mMinimum)...max(Int(r.mMinimum), Int(r.mMaximum))
    }
    /// Sets the device's I/O buffer size. Returns the size the device actually reports afterwards.
    @discardableResult static func setBufferSize(_ id: AudioObjectID, _ frames: Int) -> Int {
        let r = bufferRange(id)
        _ = set(id, kAudioDevicePropertyBufferFrameSize, value: UInt32(min(max(frames, r.lowerBound), r.upperBound)))
        return bufferSize(id)
    }
    static func deviceUID(_ id: AudioObjectID) -> String { getString(id, kAudioDevicePropertyDeviceUID) }
    static func deviceID(forUID uid: String) -> AudioObjectID? {
        devices().first { $0.uid == uid }?.id
    }

    // MARK: Processes
    static func processes() -> [AudioProcessInfo] {
        let ids = getArray(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self)
        let me = ProcessInfo.processInfo.processIdentifier
        var out: [AudioProcessInfo] = []
        for id in ids {
            let pid: pid_t = get(id, kAudioProcessPropertyPID, default: -1)
            if pid <= 0 || pid == me { continue }
            let bundle = getString(id, kAudioProcessPropertyBundleID)
            let running: UInt32 = get(id, kAudioProcessPropertyIsRunningOutput, default: 0)
            let app = NSRunningApplication(processIdentifier: pid)
            let fullID = bundle.isEmpty ? "pid.\(pid)" : bundle
            let gid = groupID(fullID)
            var name = app?.localizedName ?? (bundle.isEmpty ? "pid \(pid)" : bundle.split(separator: ".").last.map(String.init) ?? bundle)
            if gid != fullID {
                if let parent = NSRunningApplication.runningApplications(withBundleIdentifier: gid).first?.localizedName { name = parent }
                else if let r = name.range(of: " Helper") { name = String(name[..<r.lowerBound]) }
            }
            // Skip system daemons with no UI presence unless they are playing.
            if app == nil && running == 0 { continue }
            out.append(AudioProcessInfo(id: id, pid: pid, bundleID: fullID, name: name,
                                        isRunningOutput: running != 0, groupID: gid))
        }
        return out
    }

    static func groupID(_ bundle: String) -> String {
        if let r = bundle.range(of: ".helper", options: .caseInsensitive) { return String(bundle[..<r.lowerBound]) }
        return bundle
    }

    static func icon(forBundleID bundleID: String, pid: pid_t? = nil) -> NSImage? {
        if let pid, let img = NSRunningApplication(processIdentifier: pid)?.icon { return img }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return nil
    }

    static func nominalRate(_ dev: AudioObjectID) -> Double {
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var r: Float64 = 0; var sz = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &sz, &r) == noErr, r > 0 else { return 48000 }
        return r
    }
}
