import Foundation

private struct Biquad {
    var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    var z1: Float = 0, z2: Float = 0
    mutating func highpass(freq: Double, rate: Double, q: Double = 0.7071) {
        let w = 2 * Double.pi * freq / rate, c = cos(w), s = sin(w), al = s / (2 * q), a0 = 1 + al
        b0 = Float((1 + c) / 2 / a0); b1 = Float(-(1 + c) / a0); b2 = b0
        a1 = Float(-2 * c / a0); a2 = Float((1 - al) / a0)
    }
    mutating func lowpass(freq: Double, rate: Double, q: Double = 0.7071) {
        let w = 2 * Double.pi * freq / rate, c = cos(w), s = sin(w), al = s / (2 * q), a0 = 1 + al
        b0 = Float((1 - c) / 2 / a0); b1 = Float((1 - c) / a0); b2 = b0
        a1 = Float(-2 * c / a0); a2 = Float((1 - al) / a0)
    }
    @inline(__always) mutating func run(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}

/// Per-channel voice processing done directly on the audio thread:
/// high-pass, adaptive noise reduction, noise gate, split-band de-esser and a sync delay.
final class VoiceDSP {
    // Parameters (written from the main thread; plain floats are fine to read from the audio thread)
    var hpfOn = false, hpfFreq: Float = 80
    var nrOn = false, nrAmount: Float = 0.5
    var gateOn = false, gateThresholdDB: Float = -50, gateFloorDB: Float = -45
    var deessOn = false, deessAmount: Float = 0.5, deessFreq: Float = 6000
    var satOn = false, satDrive: Float = 0.3          // tape-style warmth: soft saturation
    var exOn = false, exAmount: Float = 0.3           // exciter: adds a little brightness from the top end
    var tsOn = false, tsAttack: Float = 0, tsSustain: Float = 0   // transient shaper, -1 ... +1 each
    var mbOn = false, mbThresholdDB: Float = -24, mbRatio: Float = 3   // three-band compressor: evens out low, middle and high separately
    var agcOn = false, agcTargetDB: Float = -18       // automatic gain: keeps a voice at a steady level
    var delayMs: Float = 0 { didSet { delaySamples = min(Int(Double(delayMs) / 1000 * rate), maxDelay - 1) } }
    var rate: Double = 48000 { didSet { setup() } }

    var isActive: Bool { hpfOn || nrOn || gateOn || deessOn || agcOn || mbOn || satOn || exOn || tsOn || delaySamples > 0 }

    private var hp = [Biquad](repeating: Biquad(), count: 2)
    private var ds = [Biquad](repeating: Biquad(), count: 2)
    private var lastHpf: Float = -1, lastDs: Float = -1
    private var noiseFloor: Float = 0.01
    private var rms: Float = 0
    private var gateEnv: Float = 0, gateGain: Float = 1, holdCount = 0, gateOpen = false
    private var deEnv: Float = 0
    private var agcPow: Float = 0, agcGain: Float = 1
    private var ex = [Biquad](repeating: Biquad(), count: 2)
    private var lastEx = false
    private var mbLo = [Biquad](repeating: Biquad(), count: 2), mbHi = [Biquad](repeating: Biquad(), count: 2)
    private var lastMb = false
    private var mbEnv: [Float] = [0, 0, 0], mbGain: [Float] = [1, 1, 1]
    private var mbCount = 0
    private var tsFast: Float = 0, tsSlow: Float = 0
    private var buf: [[Float]] = [[], []]
    private var maxDelay = 96000
    private var wpos = 0
    private var delaySamples = 0

    init() { setup() }
    private func setup() {
        maxDelay = Int(rate * 2.0)
        buf = [[Float](repeating: 0, count: maxDelay), [Float](repeating: 0, count: maxDelay)]
        wpos = 0
        lastHpf = -1; lastDs = -1; lastEx = false; lastMb = false
        delaySamples = min(Int(Double(delayMs) / 1000 * rate), maxDelay - 1)
    }

    func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int) {
        guard isActive else { return }
        if hpfOn, hpfFreq != lastHpf { for c in 0..<2 { hp[c].highpass(freq: Double(hpfFreq), rate: rate) }; lastHpf = hpfFreq }
        if deessOn, deessFreq != lastDs { for c in 0..<2 { ds[c].highpass(freq: Double(deessFreq), rate: rate, q: 1.0) }; lastDs = deessFreq }

        if exOn, !lastEx { for c in 0..<2 { ex[c].highpass(freq: 3500, rate: rate, q: 0.7071) }; lastEx = true }
        if mbOn, !lastMb { for c in 0..<2 { mbLo[c].lowpass(freq: 200, rate: rate); mbHi[c].highpass(freq: 3000, rate: rate) }; lastMb = true }
        let sr = Float(rate)
        let mbAtk = 1 - exp(-1 / (0.005 * sr)), mbRel = 1 - exp(-1 / (0.08 * sr))
        let mbThr = pow(10, mbThresholdDB / 20), mbExp = 1 - 1 / max(1, mbRatio)
        let satK = 1 + satDrive * 5                                   // 1 ... 6
        let tsFastA = 1 - exp(-1 / (0.002 * sr)), tsSlowA = 1 - exp(-1 / (0.05 * sr))
        let rmsCoef = 1 - exp(-1 / (0.03 * sr))
        let attack = 1 - exp(-1 / (0.004 * sr)), release = 1 - exp(-1 / (0.15 * sr))
        let holdMax = Int(0.2 * rate)
        let thr = pow(10, gateThresholdDB / 20), thrClose = pow(10, (gateThresholdDB - 4) / 20)
        let floorGain = pow(10, gateFloorDB / 20)
        let nrMaxCut = 0.15 + (1 - nrAmount) * 0.0        // reserved
        _ = nrMaxCut
        let agcCoef = 1 - exp(-1 / (0.3 * sr)), agcDown = 1 - exp(-1 / (0.08 * sr)), agcUp = 1 - exp(-1 / (1.2 * sr))
        let agcTarget = pow(10, agcTargetDB / 20)
        let deThr: Float = 0.03 * (1.4 - deessAmount)       // ~ -30 dBFS, lower when amount is high
        let deRatioExp: Float = 0.4 + 0.5 * deessAmount

        for i in 0..<n {
            var x0 = l[i], x1 = r[i]
            if hpfOn { x0 = hp[0].run(x0); x1 = hp[1].run(x1) }

            // level detector shared by noise reduction and gate
            let lvl = max(abs(x0), abs(x1))
            rms += (lvl * lvl - rms) * rmsCoef
            let env = sqrt(max(rms, 0))

            if nrOn {
                // noise floor: falls fast to quiet passages, rises very slowly
                if env < noiseFloor { noiseFloor += (env - noiseFloor) * 0.002 } else { noiseFloor += (env - noiseFloor) * 0.000004 }
                noiseFloor = max(noiseFloor, 0.00003)
                let open = noiseFloor * (2.5 + 3 * nrAmount)
                if env < open {
                    let ratio = max(env / open, 0.02)
                    let g = pow(ratio, 0.5 + nrAmount)        // stronger expansion with higher amount
                    x0 *= g; x1 *= g
                }
            }

            if gateOn {
                if lvl > gateEnv { gateEnv = lvl } else { gateEnv += (lvl - gateEnv) * 0.0008 }
                if gateEnv > thr { gateOpen = true; holdCount = holdMax }
                else if gateEnv < thrClose { if holdCount > 0 { holdCount -= 1 } else { gateOpen = false } }
                let target: Float = gateOpen ? 1 : floorGain
                gateGain += (target - gateGain) * (target > gateGain ? attack : release)
                x0 *= gateGain; x1 *= gateGain
            }

            if agcOn {
                let lv = max(abs(x0), abs(x1))
                agcPow += (lv * lv - agcPow) * agcCoef
                let e = sqrt(max(agcPow, 0))
                if e > 0.003 {                                   // only adjust while someone is actually speaking (above about -50 dB)
                    let want = min(4, max(0.25, agcTarget / e))   // never more than 12 dB up or down
                    agcGain += (want - agcGain) * (want < agcGain ? agcDown : agcUp)
                }                                                // in silence the gain is simply held, so noise is not boosted
                x0 *= agcGain; x1 *= agcGain
            }

            if mbOn {
                let l0 = mbLo[0].run(x0), l1 = mbLo[1].run(x1)
                let h0 = mbHi[0].run(x0), h1 = mbHi[1].run(x1)
                let m0 = x0 - l0 - h0, m1 = x1 - l1 - h1
                let lv0 = max(abs(l0), abs(l1)), lv1 = max(abs(m0), abs(m1)), lv2 = max(abs(h0), abs(h1))
                mbEnv[0] += (lv0 - mbEnv[0]) * (lv0 > mbEnv[0] ? mbAtk : mbRel)
                mbEnv[1] += (lv1 - mbEnv[1]) * (lv1 > mbEnv[1] ? mbAtk : mbRel)
                mbEnv[2] += (lv2 - mbEnv[2]) * (lv2 > mbEnv[2] ? mbAtk : mbRel)
                mbCount += 1
                if mbCount >= 8 {                                   // gains change slowly, so work them out every 8th sample
                    mbCount = 0
                    for b in 0..<3 { mbGain[b] = mbEnv[b] > mbThr ? pow(mbThr / mbEnv[b], mbExp) : 1 }
                }
                x0 = l0 * mbGain[0] + m0 * mbGain[1] + h0 * mbGain[2]
                x1 = l1 * mbGain[0] + m1 * mbGain[1] + h1 * mbGain[2]
            }

            if deessOn {
                let h0 = ds[0].run(x0), h1 = ds[1].run(x1)
                let hl = max(abs(h0), abs(h1))
                deEnv += (hl - deEnv) * (hl > deEnv ? 0.02 : 0.002)
                var g: Float = 1
                if deEnv > deThr { g = pow(deThr / deEnv, deRatioExp) }
                x0 -= h0 * (1 - g); x1 -= h1 * (1 - g)
            }

            if tsOn {
                let lv = max(abs(x0), abs(x1))
                tsFast += (lv - tsFast) * tsFastA
                tsSlow += (lv - tsSlow) * tsSlowA
                if tsSlow > 0.0005 {
                    let ratio = tsFast / tsSlow
                    let trans = min(1, max(0, ratio - 1))            // 1 while a sound is starting
                    let g = 1 + tsAttack * 0.9 * trans + tsSustain * 0.9 * (1 - trans)
                    let gg = min(3, max(0.25, g))
                    x0 *= gg; x1 *= gg
                }
            }

            if exOn {
                let h0 = ex[0].run(x0), h1 = ex[1].run(x1)
                x0 += exAmount * 0.6 * tanh(4 * h0)
                x1 += exAmount * 0.6 * tanh(4 * h1)
            }

            if satOn {
                x0 = tanh(satK * x0) / satK     // small signals pass at unity gain
                x1 = tanh(satK * x1) / satK
            }

            if delaySamples > 0 {
                buf[0][wpos] = x0; buf[1][wpos] = x1
                var rp = wpos - delaySamples; if rp < 0 { rp += maxDelay }
                x0 = buf[0][rp]; x1 = buf[1][rp]
                wpos += 1; if wpos >= maxDelay { wpos = 0 }
            }
            l[i] = x0.isFinite ? x0 : 0; r[i] = x1.isFinite ? x1 : 0
        }
    }
}

/// ITU-R BS.1770 / EBU R128 loudness (momentary, short-term, integrated).
final class LoudnessMeter {
    private(set) var momentary: Double = -70
    private(set) var shortTerm: Double = -70
    private(set) var integrated: Double = -70
    private(set) var peakDB: Double = -120

    private var rate = 48000.0
    private var s1 = [Biquad](repeating: Biquad(), count: 2), s2 = [Biquad](repeating: Biquad(), count: 2)
    private var blockSamples = 4800, acc = 0.0, count = 0
    private var blocks: [Double] = []         // mean-square per 100 ms block
    private var gated: [Double] = []          // 400 ms windows (power)
    private let lock = NSLock()

    func setRate(_ r: Double) {
        lock.lock(); defer { lock.unlock() }
        rate = r; blockSamples = Int(r * 0.1)
        configure()
    }
    private func configure() {
        // Stage 1: high shelf, stage 2: RLB high-pass (coefficients derived for any sample rate)
        for c in 0..<2 {
            var a = Biquad()
            let f0 = 1681.974450955533, g = 3.999843853973347, q = 0.7071752369554196
            let k = tan(Double.pi * f0 / rate), vh = pow(10, g / 20), vb = pow(vh, 0.4996667741545416)
            let a0 = 1 + k / q + k * k
            a.b0 = Float((vh + vb * k / q + k * k) / a0); a.b1 = Float(2 * (k * k - vh) / a0); a.b2 = Float((vh - vb * k / q + k * k) / a0)
            a.a1 = Float(2 * (k * k - 1) / a0); a.a2 = Float((1 - k / q + k * k) / a0)
            s1[c] = a
            var b = Biquad()
            let f1 = 38.13547087602444, q1 = 0.5003270373238773
            let k1 = tan(Double.pi * f1 / rate), d0 = 1 + k1 / q1 + k1 * k1
            b.b0 = 1; b.b1 = -2; b.b2 = 1
            b.a1 = Float(2 * (k1 * k1 - 1) / d0); b.a2 = Float((1 - k1 / q1 + k1 * k1) / d0)
            s2[c] = b
        }
    }
    func reset() {
        lock.lock(); defer { lock.unlock() }
        blocks.removeAll(); gated.removeAll(); acc = 0; count = 0
        momentary = -70; shortTerm = -70; integrated = -70; peakDB = -120
    }
    init() { configure() }

    func process(_ l: UnsafePointer<Float>, _ r: UnsafePointer<Float>, _ n: Int) {
        lock.lock(); defer { lock.unlock() }
        var pk: Float = 0
        for i in 0..<n {
            pk = max(pk, abs(l[i]), abs(r[i]))
            let a = s2[0].run(s1[0].run(l[i])), b = s2[1].run(s1[1].run(r[i]))
            acc += Double(a * a + b * b); count += 1
            if count >= blockSamples {
                blocks.append(acc / Double(count)); acc = 0; count = 0
                if blocks.count > 36000 { blocks.removeFirst(6000) }
                finishBlock()
            }
        }
        if pk > 0 { peakDB = max(peakDB * 0.9995, Double(20 * log10(pk))) }
    }
    private func lufs(_ p: Double) -> Double { p > 0 ? -0.691 + 10 * log10(p) : -70 }
    private func finishBlock() {
        let nb = blocks.count
        if nb >= 4 {
            let p = blocks[(nb - 4)...].reduce(0, +) / 4
            momentary = lufs(p)
            gated.append(p)
            if gated.count > 36000 { gated.removeFirst(6000) }
        }
        if nb >= 30 { shortTerm = lufs(blocks[(nb - 30)...].reduce(0, +) / 30) }
        if nb % 10 == 0 {
            let abs1 = gated.filter { lufs($0) > -70 }
            if !abs1.isEmpty {
                let rel = lufs(abs1.reduce(0, +) / Double(abs1.count)) - 10
                let g2 = abs1.filter { lufs($0) > rel }
                if !g2.isEmpty { integrated = lufs(g2.reduce(0, +) / Double(g2.count)) }
            }
        }
    }
}
