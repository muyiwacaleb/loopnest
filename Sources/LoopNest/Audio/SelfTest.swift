import Foundation
import CRing
import Accelerate

/// Built-in checks of LoopNest's own audio code. Run with: LoopNest --selftest (Test.command does this).
/// These test the math and the real-time building blocks, not your hardware or macOS audio permissions.
enum SelfTest {
    private static var lines: [String] = []
    private static var failed = 0
    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        lines.append("\(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  (\(detail))")")
        if !ok { failed += 1 }
    }
    private static func db(_ x: Float) -> Float { 20 * log10(max(x, 1e-9)) }
    private static func rms(_ a: [Float]) -> Float { sqrt(a.reduce(0) { $0 + $1 * $1 } / Float(max(1, a.count))) }
    private static func sine(_ n: Int, amp: Float, freq: Float = 440, rate: Float = 48000, from: Int = 0) -> [Float] {
        (0..<n).map { amp * sin(2 * .pi * freq * Float($0 + from) / rate) }
    }

    static func run() -> Int32 {
        lines = ["LoopNest self-test", "Date: \(Date())", ""]
        failed = 0

        // 1. Lock-free ring: data round trip, order, zero fill, overflow drop
        do {
            let ring = cring_create(1024, 2)!
            var src = [Float](repeating: 0, count: 200)
            for i in 0..<100 { src[i * 2] = Float(i); src[i * 2 + 1] = -Float(i) }
            let w = cring_write(ring, src, 100)
            var dst = [Float](repeating: 9, count: 240)
            let r = cring_read(ring, &dst, 120)
            check("Ring: writes and reads the same frames in order", w == 100 && r == 100 && dst[0] == 0 && dst[2 * 99] == 99 && dst[2 * 99 + 1] == -99, "wrote \(w), read \(r)")
            check("Ring: missing frames come back as silence", dst[2 * 100] == 0 && dst[2 * 119 + 1] == 0)
            var big = [Float](repeating: 1, count: 4000)
            let w2 = cring_write(ring, &big, 2000)
            check("Ring: overflow is dropped, never overwritten", w2 <= 1024, "accepted \(w2) of 2000")
            cring_destroy(ring)
        }

        // 2. Automatic level (AGC)
        do {
            let v = VoiceDSP(); v.rate = 48000; v.agcOn = true; v.agcTargetDB = -18
            func feed(_ amp: Float, seconds: Float) -> Float {
                let n = 480; var last: Float = 0
                for b in 0..<Int(seconds * 100) {
                    var l = sine(n, amp: amp, from: b * n), r = l
                    l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in v.process(lp.baseAddress!, rp.baseAddress!, n) } }
                    last = rms(l)
                }
                return db(last)
            }
            let quiet = feed(0.02, seconds: 8)          // about -37 dB peak
            check("AGC: raises a quiet voice toward the target", quiet > -37 + 3, String(format: "output %.1f dB RMS", quiet))
            let v2 = VoiceDSP(); v2.rate = 48000; v2.agcOn = true; v2.agcTargetDB = -18
            var loud = sine(480, amp: 0.8); var lr = loud
            var lastLoud: Float = 0
            for b in 0..<1000 { loud = sine(480, amp: 0.8, from: b * 480); lr = loud
                loud.withUnsafeMutableBufferPointer { lp in lr.withUnsafeMutableBufferPointer { rp in v2.process(lp.baseAddress!, rp.baseAddress!, 480) } }
                lastLoud = rms(loud) }
            check("AGC: lowers a loud voice, never more than 12 dB", db(lastLoud) < db(0.8 / 1.414) - 3 && db(lastLoud) > db(0.8 / 1.414) - 12.5, String(format: "output %.1f dB RMS", db(lastLoud)))
            let v3 = VoiceDSP(); v3.rate = 48000; v3.agcOn = true
            var silence = [Float](repeating: 0.0005, count: 480), sr = silence
            for _ in 0..<500 { silence.withUnsafeMutableBufferPointer { lp in sr.withUnsafeMutableBufferPointer { rp in v3.process(lp.baseAddress!, rp.baseAddress!, 480) } }; silence = [Float](repeating: 0.0005, count: 480); sr = silence }
            check("AGC: does not boost room noise in silence", db(rms(silence)) < db(0.0005) + 1, String(format: "%.1f dB", db(rms(silence))))
        }

        // 3. Gate closes on quiet audio
        do {
            let v = VoiceDSP(); v.rate = 48000; v.gateOn = true; v.gateThresholdDB = -40; v.gateFloorDB = -60
            var out: Float = 1
            for b in 0..<400 { var l = sine(480, amp: 0.003, from: b * 480), r = l
                l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in v.process(lp.baseAddress!, rp.baseAddress!, 480) } }
                out = rms(l) }
            check("Gate: closes below its threshold", db(out) < db(0.003 / 1.414) - 10, String(format: "%.1f dB", db(out)))
        }

        // 3b. Warmth, brightness, punch
        do {
            func run(_ cfg: (VoiceDSP) -> Void, freq: Float, amp: Float, seconds: Float = 1) -> (rms: Float, peak: Float, finite: Bool, first: Float) {
                let v = VoiceDSP(); v.rate = 48000; cfg(v)
                var r: [Float] = [], peak: Float = 0, fin = true, first: Float = 0
                for b in 0..<Int(seconds * 100) {
                    var l = sine(480, amp: amp, freq: freq, from: b * 480), rr = l
                    l.withUnsafeMutableBufferPointer { lp in rr.withUnsafeMutableBufferPointer { rp in v.process(lp.baseAddress!, rp.baseAddress!, 480) } }
                    for x in l { if !x.isFinite { fin = false }; peak = max(peak, abs(x)) }
                    r.append(rms(l)); if b == 0 { first = rms(l) }
                }
                return (rms(Array(r.suffix(20))), peak, fin, first)
            }
            let off = run({ _ in }, freq: 440, amp: 0.05)
            let sat = run({ $0.satOn = true; $0.satDrive = 0.5 }, freq: 440, amp: 0.05)
            check("Warmth: quiet sounds keep about their level", abs(db(sat.rms) - db(off.rms)) < 1.5, String(format: "%.2f dB change", db(sat.rms) - db(off.rms)))
            let hot = run({ $0.satOn = true; $0.satDrive = 1 }, freq: 440, amp: 1.0)
            check("Warmth: loud peaks are rounded off and stay finite", hot.finite && hot.peak < 1.2, String(format: "peak %.2f", hot.peak))
            let hiOff = run({ _ in }, freq: 8000, amp: 0.2), hiOn = run({ $0.exOn = true; $0.exAmount = 0.8 }, freq: 8000, amp: 0.2)
            check("Brightness: adds energy at high frequencies", db(hiOn.rms) > db(hiOff.rms) + 0.5, String(format: "%+.1f dB", db(hiOn.rms) - db(hiOff.rms)))
            let loOff = run({ _ in }, freq: 200, amp: 0.2), loOn = run({ $0.exOn = true; $0.exAmount = 0.8 }, freq: 200, amp: 0.2)
            check("Brightness: leaves low frequencies alone", abs(db(loOn.rms) - db(loOff.rms)) < 0.5, String(format: "%+.2f dB", db(loOn.rms) - db(loOff.rms)))
            // punch: a loud start (first block) followed by a quieter steady tone
            func burst(_ attack: Float) -> Float {
                let v = VoiceDSP(); v.rate = 48000; v.tsOn = true; v.tsAttack = attack
                var firstBlock: Float = 0
                for b in 0..<200 {
                    let amp: Float = b < 1 ? 0.7 : 0.15
                    var l = sine(480, amp: amp, freq: 700, from: b * 480), rr = l
                    if b == 0 { for i in 0..<240 { l[i] = 0.0001 * Float(i % 3); rr[i] = l[i] } }      // quiet lead-in so the loud start is a real transient
                    l.withUnsafeMutableBufferPointer { lp in rr.withUnsafeMutableBufferPointer { rp in v.process(lp.baseAddress!, rp.baseAddress!, 480) } }
                    if b == 0 { firstBlock = rms(Array(l[240..<480])) }
                }
                return firstBlock
            }
            let up = burst(1), flat = burst(0), down = burst(-1)
            check("Punch: attack up makes a sound's start louder, attack down softer", up > flat * 1.05 && down < flat * 0.95, String(format: "%.3f / %.3f / %.3f", down, flat, up))
        }

        // 3c. Three-band compressor
        do {
            func level(_ freq: Float, _ amp: Float, on: Bool) -> Float {
                let v = VoiceDSP(); v.rate = 48000; v.mbOn = on; v.mbThresholdDB = -24; v.mbRatio = 4
                var tail: [Float] = []
                for b in 0..<150 {
                    var l = sine(480, amp: amp, freq: freq, from: b * 480), rr = l
                    l.withUnsafeMutableBufferPointer { lp in rr.withUnsafeMutableBufferPointer { rp in v.process(lp.baseAddress!, rp.baseAddress!, 480) } }
                    if b >= 130 { tail += l }
                }
                return rms(tail)
            }
            let loudBass = db(level(100, 0.8, on: true)) - db(level(100, 0.8, on: false))
            check("Multiband: loud bass is turned down", loudBass < -4, String(format: "%+.1f dB", loudBass))
            let quietTop = db(level(8000, 0.02, on: true)) - db(level(8000, 0.02, on: false))
            check("Multiband: quiet treble is left alone", abs(quietTop) < 1.0, String(format: "%+.2f dB", quietTop))
            let quietMid = db(level(1000, 0.02, on: true)) - db(level(1000, 0.02, on: false))
            check("Multiband: quiet middle is left alone", abs(quietMid) < 1.0, String(format: "%+.2f dB", quietMid))
        }

        // 4. Modulation effects stay finite and bounded
        for mode in 1...4 {
            let m = ModFX(); m.sampleRate = 48000; m.mode = mode; m.rate = 2; m.depth = 1; m.mix = 1
            var peak: Float = 0, finite = true
            for b in 0..<200 { var l = sine(480, amp: 0.5, from: b * 480), r = l
                l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in m.process(lp.baseAddress!, rp.baseAddress!, 480) } }
                for x in l { if !x.isFinite { finite = false }; peak = max(peak, abs(x)) } }
            check("\(ModFX.names[mode]): output is finite and not louder than 2x input", finite && peak < 1.0, String(format: "peak %.2f", peak))
        }

        // 5. Stream analyzer: correlation and true peak
        do {
            let a = StreamAnalyzer(); a.active = true
            let l = sine(4800, amp: 0.5); let r = l
            for _ in 0..<40 { l.withUnsafeBufferPointer { lp in r.withUnsafeBufferPointer { rp in a.process(lp.baseAddress!, rp.baseAddress!, 4800) } } }
            check("Analyzer: identical left and right reads as mono-compatible", a.correlation > 0.95, String(format: "%.2f", a.correlation))
            let inv = l.map { -$0 }
            for _ in 0..<40 { l.withUnsafeBufferPointer { lp in inv.withUnsafeBufferPointer { rp in a.process(lp.baseAddress!, rp.baseAddress!, 4800) } } }
            check("Analyzer: inverted right channel reads as out of phase", a.correlation < -0.5, String(format: "%.2f", a.correlation))
            let full = sine(4800, amp: 1.0, freq: 11025, rate: 44100)
            let b = StreamAnalyzer()
            full.withUnsafeBufferPointer { p in b.process(p.baseAddress!, p.baseAddress!, 4800) }
            check("Analyzer: true peak is at least the sample peak", b.truePeakHoldDB >= -0.5, String(format: "%.2f dBTP", b.truePeakHoldDB))
        }

        // 6. Loudness meter orders levels correctly
        do {
            func lufs(_ amp: Float) -> Double {
                let m = LoudnessMeter(); m.setRate(48000)
                for b in 0..<500 { let l = sine(480, amp: amp, freq: 1000, from: b * 480)
                    l.withUnsafeBufferPointer { p in m.process(p.baseAddress!, p.baseAddress!, 480) } }
                return m.shortTerm
            }
            let a = lufs(0.1), b = lufs(0.2)
            check("Loudness: doubling the level reads about 6 LU higher", abs((b - a) - 6.02) < 0.7, String(format: "%.1f then %.1f", a, b))
        }

        // 7. Remote control message parsing
        do {
            var osc = Data("/loopnest/fader/Browser".utf8); osc.append(0)      // text ends with one zero, then pads to a multiple of 4
            while osc.count % 4 != 0 { osc.append(0) }
            osc.append(Data(",f".utf8)); osc.append(contentsOf: [0, 0])
            var bits = Float(0.75).bitPattern.bigEndian
            osc.append(Data(bytes: &bits, count: 4))
            let parsed = RemoteControl.parseOSC(osc)
            check("OSC: address and float value are read correctly", parsed?.0 == "/loopnest/fader/Browser" && parsed?.1 == 0.75)
            check("OSC: garbage is ignored", RemoteControl.parseOSC(Data([1, 2, 3])) == nil)
        }

        do {   // convolution reverb
            let core = ConvCore()
            var seed: UInt32 = 12345
            func rnd() -> Float { seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5; return Float(Int32(bitPattern: seed)) / 2147483648 }
            let irL = (0..<2500).map { _ in rnd() * 0.1 }
            let irR = irL.map { $0 * -0.5 }
            let blocks = 12, n = blocks * 512
            let x = (0..<n).map { _ in rnd() }
            var gotL = [Float](repeating: 0, count: n), gotR = [Float](repeating: 0, count: n)
            core.setKernel(core.makeKernel(irL, irR))
            var ol = [Float](repeating: 0, count: 512), orr = [Float](repeating: 0, count: 512)
            for b in 0..<blocks {
                x.withUnsafeBufferPointer { xp in core.processBlock(xp.baseAddress! + b * 512, xp.baseAddress! + b * 512, &ol, &orr) }
                for i in 0..<512 { gotL[b * 512 + i] = ol[i]; gotR[b * 512 + i] = orr[i] }
            }
            var errL: Float = 0, errR: Float = 0, peak: Float = 0
            for i in stride(from: 0, to: n, by: 7) {
                var rl: Float = 0, rr: Float = 0
                for k in 0..<min(irL.count, i + 1) { rl += irL[k] * x[i - k]; rr += irR[k] * x[i - k] }
                errL = max(errL, abs(rl - gotL[i])); errR = max(errR, abs(rr - gotR[i])); peak = max(peak, abs(rl))
            }
            check("Convolution reverb: matches direct convolution (left)", errL < 0.002 * max(peak, 1e-6), String(format: "worst error %.5f of peak %.3f", errL, peak))
            check("Convolution reverb: matches direct convolution (right)", errR < 0.002 * max(peak, 1e-6), String(format: "worst error %.5f", errR))
            let room = ConvReverb.generate(preset: 102, rate: 48000)
            let tenth = room[0].count / 10
            func energy(_ a: ArraySlice<Float>) -> Float { a.reduce(0) { $0 + $1 * $1 } }
            let e0 = energy(room[0][0..<tenth]), e1 = energy(room[0][(room[0].count - tenth)...])
            let total = (energy(room[0][...]) + energy(room[1][...])) / 2
            check("Convolution reverb: built-in room decays and has a fixed level", room[0].allSatisfy { $0.isFinite } && e0 > 20 * e1 && abs(total - 0.5) < 0.05, String(format: "start/end energy %.0fx, level %.2f", e0 / max(e1, 1e-12), total))
        }

        do {   // patchbay editing
            var d = VirtualDeviceConfig(slot: 0, name: "T", channels: 4)
            let a = RouteSource(kind: .app, ref: "a", name: "A"), b = RouteSource(kind: .app, ref: "b", name: "B")
            d.sources = [a, b]
            d.wires = [Wire(sourceID: a.id, srcChannel: 0, destChannel: 0), Wire(sourceID: a.id, srcChannel: 1, destChannel: 1),
                       Wire(sourceID: b.id, srcChannel: 0, destChannel: 2), Wire(sourceID: b.id, srcChannel: 1, destChannel: 3)]
            var s = d; PatchOps.swapSides(&s, source: a.id)
            check("Patchbay: swap left and right", s.wires.contains { $0.sourceID == a.id && $0.srcChannel == 0 && $0.destChannel == 1 } && s.wires.contains { $0.sourceID == a.id && $0.srcChannel == 1 && $0.destChannel == 0 } && s.wires.count == 4)
            s = d; PatchOps.swapOutputs(&s, 0, 2)
            check("Patchbay: swap two output channels", s.wires.contains { $0.sourceID == a.id && $0.srcChannel == 0 && $0.destChannel == 2 } && s.wires.contains { $0.sourceID == b.id && $0.srcChannel == 0 && $0.destChannel == 0 })
            s = d; PatchOps.split(&s, from: 0, to: 3); PatchOps.split(&s, from: 0, to: 3)
            check("Patchbay: split copies a feed once", s.wires.filter { $0.destChannel == 3 }.count == 2 && s.wires.count == 5)
            s = d; PatchOps.makeMono(&s, source: a.id)
            check("Patchbay: mono sends both sides to both outputs", s.wires.filter { $0.sourceID == a.id }.count == 4 && s.wires.filter { $0.sourceID == b.id }.count == 2)
            s = d; PatchOps.mergeAll(&s)
            check("Patchbay: merge puts every source on one pair", s.wires.count == 4 && s.wires.allSatisfy { $0.destChannel < 2 })
            var loopy = d; loopy.sources.append(RouteSource(kind: .device, ref: "LoopNest.7", name: "LoopNest Stream"))
            check("Patchbay: feedback check finds a LoopNest source", PatchOps.loopProblems([loopy]).count == 1 && PatchOps.loopProblems([d]).isEmpty)
        }

        lines.append("")
        lines.append(failed == 0 ? "ALL TESTS PASSED" : "\(failed) TEST(S) FAILED")
        let text = lines.joined(separator: "\n")
        print(text)
        return failed == 0 ? 0 : 1
    }
}
