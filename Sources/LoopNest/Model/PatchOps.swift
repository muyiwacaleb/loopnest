import Foundation

/// Patchbay editing: split, merge and swap, plus feedback-loop checks. Pure functions on a device's wires so they can be self-tested.
enum PatchOps {
    /// Swap left and right of one source: its left wire goes where its right wire went, and the other way round.
    static func swapSides(_ cfg: inout VirtualDeviceConfig, source: UUID) {
        let l = cfg.wires.filter { $0.sourceID == source && $0.srcChannel == 0 }.map { $0.destChannel }
        let r = cfg.wires.filter { $0.sourceID == source && $0.srcChannel == 1 }.map { $0.destChannel }
        cfg.wires.removeAll { $0.sourceID == source }
        for d in r { cfg.wires.append(Wire(sourceID: source, srcChannel: 0, destChannel: d)) }
        for d in l { cfg.wires.append(Wire(sourceID: source, srcChannel: 1, destChannel: d)) }
    }

    /// Exchange what feeds two output channels.
    static func swapOutputs(_ cfg: inout VirtualDeviceConfig, _ a: Int, _ b: Int) {
        guard a != b else { return }
        for i in cfg.wires.indices {
            if cfg.wires[i].destChannel == a { cfg.wires[i].destChannel = b }
            else if cfg.wires[i].destChannel == b { cfg.wires[i].destChannel = a }
        }
    }

    /// Split: copy everything that feeds output channel `from` onto output channel `to` as well.
    static func split(_ cfg: inout VirtualDeviceConfig, from: Int, to: Int) {
        guard from != to, to >= 0, to < cfg.channels else { return }
        let feeds = cfg.wires.filter { $0.destChannel == from }
        for w in feeds where !cfg.wires.contains(where: { $0.sourceID == w.sourceID && $0.srcChannel == w.srcChannel && $0.destChannel == to }) {
            cfg.wires.append(Wire(sourceID: w.sourceID, srcChannel: w.srcChannel, destChannel: to))
        }
    }

    /// Mono: both sides of a source play on the left and right outputs (channels 1 and 2 of the pair starting at `pair`).
    static func makeMono(_ cfg: inout VirtualDeviceConfig, source: UUID, pair: Int = 0) {
        cfg.wires.removeAll { $0.sourceID == source }
        for ch in 0..<2 { for d in [pair, pair + 1] where d < cfg.channels { cfg.wires.append(Wire(sourceID: source, srcChannel: ch, destChannel: d)) } }
    }

    /// Merge: every source feeds the same stereo pair, so they are mixed together.
    static func mergeAll(_ cfg: inout VirtualDeviceConfig, pair: Int = 0) {
        guard cfg.channels >= pair + 2 else { return }
        cfg.wires = cfg.sources.flatMap { s in [Wire(sourceID: s.id, srcChannel: 0, destChannel: pair), Wire(sourceID: s.id, srcChannel: 1, destChannel: pair + 1)] }
    }

    /// Problems that could make a sound loop back on itself. Empty means none found.
    static func loopProblems(_ devices: [VirtualDeviceConfig]) -> [String] {
        var out: [String] = []
        for d in devices {
            for s in d.sources where s.kind == .device && s.ref.hasPrefix("LoopNest") {
                out.append("\(d.name): the source \(s.name) is a LoopNest device, which would feed back")
            }
            if let m = d.monitorUID, d.monitorOn, m.hasPrefix("LoopNest") { out.append("\(d.name): it is monitored on a LoopNest device") }
            if d.wires.contains(where: { w in !d.sources.contains { $0.id == w.sourceID } }) { out.append("\(d.name): a wire points at a source that is gone") }
        }
        return out
    }
}
