import Foundation
import AVFoundation
import CoreAudio
import Darwin

/// Counters and an event log for the Health page. Audio threads only touch plain numbers, never the UI.
final class Health: ObservableObject {
    static let shared = Health()

    // written from audio threads (a torn read is harmless for a display counter)
    var streamUnderruns = 0
    var streamCallbacks = 0
    var recDropped = 0                  // frames the recorder could not keep up with
    var renderLoad: Double = 0          // % of the buffer period the stream render callback used
    var renderLoadPeak: Double = 0
    private static var timebase: mach_timebase_info_data_t = { var t = mach_timebase_info_data_t(); mach_timebase_info(&t); return t }()
    static func seconds(_ ticks: UInt64) -> Double { Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1e9 }

    @Published var cpuPercent = 0.0
    @Published var underruns = 0
    @Published var load = 0.0
    @Published var loadPeak = 0.0
    @Published var engineRestarts = 0
    @Published var events: [String] = []

    private var lastUsage: (cpu: Double, wall: Date)?
    private let fmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f }()
    let logURL: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LoopNest", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("loopnest.log")
    }()

    init() {
        if let a = try? FileManager.default.attributesOfItem(atPath: logURL.path), (a[.size] as? Int ?? 0) > 1_000_000 {
            try? FileManager.default.removeItem(at: logURL)
        }
    }

    /// Called on the main thread about once a second.
    func refresh() {
        var ru = rusage(); getrusage(RUSAGE_SELF, &ru)
        let cpu = Double(ru.ru_utime.tv_sec + ru.ru_stime.tv_sec) + Double(ru.ru_utime.tv_usec + ru.ru_stime.tv_usec) / 1e6
        let now = Date()
        if let l = lastUsage { let dt = now.timeIntervalSince(l.wall); if dt >= 2.0 {   // measure over >= 2 s so short bursts don't read as load
            let p = max(0, (cpu - l.cpu) / dt * 100)
            cpuPercent = cpuPercent == 0 ? p : cpuPercent * 0.5 + p * 0.5
            lastUsage = (cpu, now)
        } } else { lastUsage = (cpu, now) }
        underruns = streamUnderruns
        load = renderLoad; loadPeak = renderLoadPeak
    }
    func resetCounters() { streamUnderruns = 0; renderLoadPeak = 0; underruns = 0; loadPeak = 0; engineRestarts = 0 }

    func log(_ message: String) {
        let line = "\(fmt.string(from: Date()))  \(message)"
        DispatchQueue.main.async {
            self.events.append(line); if self.events.count > 300 { self.events.removeFirst(self.events.count - 300) }
        }
        if let data = (line + "\n").data(using: .utf8) {
            if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(data); try? h.close() }
            else { try? data.write(to: logURL) }
        }
    }
}

extension CA {
    static func bufferSize(_ dev: AudioObjectID) -> Int { Int(get(dev, kAudioDevicePropertyBufferFrameSize, default: UInt32(0))) }
    /// Total one-way latency in frames: device + safety offset + stream.
    static func latencyFrames(_ dev: AudioObjectID, input: Bool) -> Int {
        let scope = input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
        let lat = Int(get(dev, kAudioDevicePropertyLatency, scope: scope, default: UInt32(0)))
        let safe = Int(get(dev, kAudioDevicePropertySafetyOffset, scope: scope, default: UInt32(0)))
        let streams = getArray(dev, kAudioDevicePropertyStreams, scope: scope, of: AudioObjectID.self)
        let sl = streams.first.map { Int(get($0, kAudioStreamPropertyLatency, default: UInt32(0))) } ?? 0
        return lat + safe + sl
    }
    static func transportIsUSBOrBuiltIn(_ dev: AudioObjectID) -> String {
        let t = get(dev, kAudioDevicePropertyTransportType, default: UInt32(0))
        switch t {
        case kAudioDeviceTransportTypeBuiltIn: return "built-in"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        case kAudioDeviceTransportTypeFireWire: return "FireWire"
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: return "virtual"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "display"
        default: return "other"
        }
    }
}
