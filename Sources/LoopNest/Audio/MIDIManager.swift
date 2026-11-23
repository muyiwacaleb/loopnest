import Foundation
import CoreMIDI

/// Receives MIDI from USB controllers and maps knobs/sliders/buttons to app parameters (receive only).
final class MIDIManager: ObservableObject {
    @Published var bindings: [MIDIBinding] = [] { didSet { save() } }
    @Published var learnTarget: String?
    @Published var sourceNames: [String] = []
    @Published var lastMessage = ""

    /// (target, value 0...1, isNote)
    var onValue: ((String, Float, Bool) -> Void)?

    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private let key = "midiBindings"

    init() {
        if let d = UserDefaults.standard.data(forKey: key), let b = try? JSONDecoder().decode([MIDIBinding].self, from: d) { bindings = b }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(bindings) { UserDefaults.standard.set(d, forKey: key) }
    }

    func start() {
        MIDIClientCreateWithBlock("LoopNest" as CFString, &client) { [weak self] _ in
            DispatchQueue.main.async { self?.connectSources() }
        }
        MIDIInputPortCreateWithProtocol(client, "LoopNest In" as CFString, ._1_0, &port) { [weak self] list, _ in
            var packet = list.pointee.packet
            for _ in 0..<list.pointee.numPackets {
                let wc = Int(packet.wordCount)
                withUnsafePointer(to: &packet.words) { wp in
                    wp.withMemoryRebound(to: UInt32.self, capacity: max(wc, 1)) { w in
                        for i in 0..<wc { self?.handle(w[i]) }
                    }
                }
                packet = MIDIEventPacketNext(&packet).pointee
            }
        }
        connectSources()
    }

    private func connectSources() {
        var names: [String] = []
        for i in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i)
            MIDIPortConnectSource(port, src, nil)
            var cf: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(src, kMIDIPropertyDisplayName, &cf)
            names.append(cf?.takeRetainedValue() as String? ?? "MIDI source \(i)")
        }
        sourceNames = names
    }

    private func handle(_ word: UInt32) {
        guard (word >> 28) == 0x2 else { return }       // MIDI 1.0 channel voice
        let status = UInt8((word >> 16) & 0xF0)
        let ch = Int((word >> 16) & 0x0F)
        let d1 = Int((word >> 8) & 0x7F), d2 = Int(word & 0x7F)
        let isNote: Bool
        var value: Float
        switch status {
        case 0xB0: isNote = false; value = Float(d2) / 127
        case 0x90: isNote = true; value = d2 > 0 ? 1 : 0
        case 0x80: isNote = true; value = 0
        default: return
        }
        DispatchQueue.main.async {
            self.lastMessage = "\(isNote ? "Note" : "CC") \(d1) ch \(ch + 1)"
            if let target = self.learnTarget {
                self.bindings.removeAll { $0.target == target || ($0.channel == ch && $0.number == d1 && $0.isNote == isNote) }
                self.bindings.append(MIDIBinding(channel: ch, number: d1, isNote: isNote, target: target))
                self.learnTarget = nil
                return
            }
            if let b = self.bindings.first(where: { $0.channel == ch && $0.number == d1 && $0.isNote == isNote }) {
                self.onValue?(b.target, value, isNote)
            }
        }
    }
}
