import Foundation
import Accelerate
import AVFoundation
import CRing

/// Stereo uniform-partitioned FFT convolution (blocks of 512 frames). All buffers are allocated up front;
/// `processBlock` does no allocation and takes no locks, so it is safe on the audio thread.
final class ConvCore {
    static let B = 512
    static let N = 1024
    static let Hh = 512
    private let setup: FFTSetup
    private let log2n: vDSP_Length = 10

    /// The impulse response split into partitions (spectra) plus its own delay line, so swapping kernels starts clean.
    final class Kernel {
        let parts: Int
        let hRe: [UnsafeMutablePointer<Float>]
        let hIm: [UnsafeMutablePointer<Float>]
        let fRe: [UnsafeMutablePointer<Float>]
        let fIm: [UnsafeMutablePointer<Float>]
        var idx = 0
        init(parts: Int) {
            self.parts = parts
            func alloc(_ count: Int) -> UnsafeMutablePointer<Float> {
                let p = UnsafeMutablePointer<Float>.allocate(capacity: count)
                p.initialize(repeating: 0, count: count)
                return p
            }
            let c = parts * ConvCore.Hh
            hRe = [alloc(c), alloc(c)]; hIm = [alloc(c), alloc(c)]
            fRe = [alloc(c), alloc(c)]; fIm = [alloc(c), alloc(c)]
        }
        deinit { for p in hRe + hIm + fRe + fIm { p.deallocate() } }
    }

    private var kernel: Kernel?
    private var scale: Float = 1
    private let inBuf: [UnsafeMutablePointer<Float>]
    private let tmp = UnsafeMutablePointer<Float>.allocate(capacity: ConvCore.N)
    private let accRe = UnsafeMutablePointer<Float>.allocate(capacity: ConvCore.Hh)
    private let accIm = UnsafeMutablePointer<Float>.allocate(capacity: ConvCore.Hh)

    init() {
        setup = vDSP_create_fftsetup(10, FFTRadix(kFFTRadix2))!
        inBuf = [UnsafeMutablePointer<Float>.allocate(capacity: ConvCore.N), UnsafeMutablePointer<Float>.allocate(capacity: ConvCore.N)]
        for b in inBuf { b.initialize(repeating: 0, count: ConvCore.N) }
        tmp.initialize(repeating: 0, count: ConvCore.N)
        accRe.initialize(repeating: 0, count: ConvCore.Hh)
        accIm.initialize(repeating: 0, count: ConvCore.Hh)
        calibrate()
    }
    deinit {
        vDSP_destroy_fftsetup(setup)
        for b in inBuf { b.deallocate() }
        tmp.deallocate(); accRe.deallocate(); accIm.deallocate()
    }

    /// The FFT library's scaling differs by platform; measure it once with a unit impulse so the output level is exact.
    private func calibrate() {
        let B = ConvCore.B
        setKernel(makeKernel([1], [1]))
        var x = [Float](repeating: 0, count: B); x[0] = 1
        var o1 = [Float](repeating: 0, count: B), o2 = [Float](repeating: 0, count: B)
        x.withUnsafeBufferPointer { xp in
            processBlock(xp.baseAddress!, xp.baseAddress!, &o1, &o2)
        }
        if o1[0].isFinite && abs(o1[0]) > 1e-12 { scale = 1 / o1[0] }
        setKernel(nil)
    }

    private func fwd(_ x: UnsafePointer<Float>, _ re: UnsafeMutablePointer<Float>, _ im: UnsafeMutablePointer<Float>) {
        var s = DSPSplitComplex(realp: re, imagp: im)
        x.withMemoryRebound(to: DSPComplex.self, capacity: ConvCore.Hh) { vDSP_ctoz($0, 2, &s, 1, vDSP_Length(ConvCore.Hh)) }
        vDSP_fft_zrip(setup, &s, 1, log2n, FFTDirection(kFFTDirection_Forward))
    }
    private func inv(_ re: UnsafeMutablePointer<Float>, _ im: UnsafeMutablePointer<Float>, _ out: UnsafeMutablePointer<Float>) {
        var s = DSPSplitComplex(realp: re, imagp: im)
        vDSP_fft_zrip(setup, &s, 1, log2n, FFTDirection(kFFTDirection_Inverse))
        out.withMemoryRebound(to: DSPComplex.self, capacity: ConvCore.Hh) { vDSP_ztoc(&s, 1, $0, 2, vDSP_Length(ConvCore.Hh)) }
    }

    /// Not for the audio thread. Builds the partition spectra for a stereo impulse response (at most about 4 seconds).
    func makeKernel(_ irL: [Float], _ irR: [Float]) -> Kernel {
        let B = ConvCore.B, N = ConvCore.N, Hh = ConvCore.Hh
        let len = max(irL.count, irR.count, 1)
        let parts = min(max(1, (len + B - 1) / B), 400)
        let k = Kernel(parts: parts)
        var tin = [Float](repeating: 0, count: N)
        for ch in 0..<2 {
            let ir = ch == 0 ? irL : irR
            for p in 0..<parts {
                for i in 0..<N { tin[i] = 0 }
                let start = p * B
                if start < ir.count { let n = min(B, ir.count - start); for i in 0..<n { tin[i] = ir[start + i] } }
                tin.withUnsafeBufferPointer { fwd($0.baseAddress!, k.hRe[ch] + p * Hh, k.hIm[ch] + p * Hh) }
            }
        }
        return k
    }

    /// Audio thread (or tests). Switches to a new impulse response; `nil` means silence.
    func setKernel(_ k: Kernel?) {
        kernel = k
        for b in inBuf { b.update(repeating: 0, count: ConvCore.N) }
    }

    /// Convolves exactly one block of 512 frames per channel.
    func processBlock(_ inL: UnsafePointer<Float>, _ inR: UnsafePointer<Float>,
                      _ outL: UnsafeMutablePointer<Float>, _ outR: UnsafeMutablePointer<Float>) {
        let B = ConvCore.B, Hh = ConvCore.Hh
        guard let k = kernel else {
            outL.update(repeating: 0, count: B); outR.update(repeating: 0, count: B); return
        }
        k.idx = (k.idx - 1 + k.parts) % k.parts
        for ch in 0..<2 {
            let src = ch == 0 ? inL : inR
            let dst = ch == 0 ? outL : outR
            let buf = inBuf[ch]
            (buf + B).update(from: src, count: B)
            fwd(buf, k.fRe[ch] + k.idx * Hh, k.fIm[ch] + k.idx * Hh)
            accRe.update(repeating: 0, count: Hh); accIm.update(repeating: 0, count: Hh)
            for p in 0..<k.parts {
                let slot = (k.idx + p) % k.parts
                let xr = k.fRe[ch] + slot * Hh, xi = k.fIm[ch] + slot * Hh
                let hr = k.hRe[ch] + p * Hh, hi = k.hIm[ch] + p * Hh
                accRe[0] += xr[0] * hr[0]          // DC lives in real[0]
                accIm[0] += xi[0] * hi[0]          // Nyquist is packed into imag[0]
                var a = DSPSplitComplex(realp: xr + 1, imagp: xi + 1)
                var b = DSPSplitComplex(realp: hr + 1, imagp: hi + 1)
                var c = DSPSplitComplex(realp: accRe + 1, imagp: accIm + 1)
                vDSP_zvma(&a, 1, &b, 1, &c, 1, &c, 1, vDSP_Length(Hh - 1))
            }
            inv(accRe, accIm, tmp)
            var sc = scale
            vDSP_vsmul(tmp + B, 1, &sc, dst, 1, vDSP_Length(B))
            buf.update(from: buf + B, count: B)
        }
    }
}

/// Convolution reverb that sits beside the built-in reverb: the reverb send bus feeds a sink node, the sink runs the
/// convolver and hands the result through a lock-free ring to a source node that feeds the reverb return.
final class ConvReverb {
    let core = ConvCore()
    private var sink: AVAudioSinkNode!
    private var source: AVAudioSourceNode!
    private let ring: OpaquePointer
    private let active = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
    private let lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
    private var pending: ConvCore.Kernel?
    private var lastKey = ""
    var onLoadFailed: (() -> Void)?
    private let accL = UnsafeMutablePointer<Float>.allocate(capacity: ConvCore.B)
    private let accR = UnsafeMutablePointer<Float>.allocate(capacity: ConvCore.B)
    private let outL = UnsafeMutablePointer<Float>.allocate(capacity: ConvCore.B)
    private let outR = UnsafeMutablePointer<Float>.allocate(capacity: ConvCore.B)
    private let inter = UnsafeMutablePointer<Float>.allocate(capacity: ConvCore.B * 2)
    private let rscratch = UnsafeMutablePointer<Float>.allocate(capacity: 8192 * 2)
    private var fill = 0

    init() {
        active.initialize(to: false)
        lock.initialize(to: os_unfair_lock())
        ring = cring_create(16384, 2)!
        for p in [accL, accR, outL, outR] { p.initialize(repeating: 0, count: ConvCore.B) }
        inter.initialize(repeating: 0, count: ConvCore.B * 2)
        rscratch.initialize(repeating: 0, count: 8192 * 2)
        _ = cring_write(ring, inter, UInt32(ConvCore.B))     // a small cushion so the reader never starves
        _ = cring_write(ring, inter, UInt32(ConvCore.B))
    }

    func install(engine: AVAudioEngine, input: AVAudioNode, builtIn: AVAudioNode, output: AVAudioNode, format: AVAudioFormat) {
        sink = AVAudioSinkNode { [unowned self] _, frames, abl in
            self.consume(Int(frames), abl)
            return noErr
        }
        source = AVAudioSourceNode(format: format) { [unowned self] _, _, frames, abl in
            self.produce(Int(frames), abl)
            return noErr
        }
        engine.attach(sink); engine.attach(source)
        engine.connect(input, to: [AVAudioConnectionPoint(node: builtIn, bus: 0),
                                   AVAudioConnectionPoint(node: sink, bus: 0)], fromBus: 0, format: format)
        engine.connect(source, to: output, format: format)
    }

    func setActive(_ on: Bool) { active.pointee = on }

    /// Chooses the room. Builds the impulse response in the background and swaps it in when ready.
    func configure(preset: Int, path: String?, rate: Double) {
        let key = "\(preset)|\(path ?? "")|\(Int(rate))"
        guard key != lastKey else { return }
        lastKey = key
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let irs: [[Float]]? = preset == 99 ? path.flatMap { ConvReverb.loadIR($0, rate: rate) } : ConvReverb.generate(preset: preset, rate: rate)
            guard let irs else {
                DispatchQueue.main.async { self.lastKey = ""; self.onLoadFailed?() }
                return
            }
            let k = self.core.makeKernel(irs[0], irs[1])
            os_unfair_lock_lock(self.lock); self.pending = k; os_unfair_lock_unlock(self.lock)
        }
    }

    private func writeZeros(_ n: Int) {
        var left = n
        for i in 0..<(ConvCore.B * 2) { inter[i] = 0 }
        while left > 0 { let c = min(left, ConvCore.B); _ = cring_write(ring, inter, UInt32(c)); left -= c }
    }

    private func consume(_ n: Int, _ abl: UnsafePointer<AudioBufferList>) {
        guard active.pointee else { fill = 0; writeZeros(n); return }   // keeps the cushion steady while off
        if os_unfair_lock_trylock(lock) {
            if let p = pending { core.setKernel(p); pending = nil; fill = 0 }
            os_unfair_lock_unlock(lock)
        }
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
        guard list.count >= 1, n <= 8192, let d0 = list[0].mData else { writeZeros(n); return }
        let l = d0.assumingMemoryBound(to: Float.self)
        let r = list.count > 1 ? (list[1].mData?.assumingMemoryBound(to: Float.self) ?? l) : l
        let B = ConvCore.B
        var pos = 0
        while pos < n {
            let take = min(B - fill, n - pos)
            (accL + fill).update(from: l + pos, count: take)
            (accR + fill).update(from: r + pos, count: take)
            fill += take; pos += take
            if fill == B {
                core.processBlock(accL, accR, outL, outR)
                for i in 0..<B { inter[2 * i] = outL[i]; inter[2 * i + 1] = outR[i] }
                _ = cring_write(ring, inter, UInt32(B))
                fill = 0
            }
        }
    }

    private func produce(_ frames: Int, _ abl: UnsafeMutablePointer<AudioBufferList>) {
        let n = min(frames, 8192)
        let list = UnsafeMutableAudioBufferListPointer(abl)
        _ = cring_read(ring, rscratch, UInt32(n))
        for b in 0..<min(2, list.count) {
            guard let d = list[b].mData?.assumingMemoryBound(to: Float.self) else { continue }
            for i in 0..<n { d[i] = rscratch[2 * i + b] }
            if frames > n { for i in n..<frames { d[i] = 0 } }
        }
    }

    // MARK: impulse responses

    /// Built-in rooms made of shaped noise (deterministic, so a room always sounds the same).
    static func generate(preset: Int, rate: Double) -> [[Float]] {
        var rt = 1.5, pre = 0.0, damp = 0.7
        var taps: [(Double, Float)] = []
        switch preset {
        case 100: rt = 0.28; pre = 0.002; damp = 0.35
        case 101: rt = 0.7; pre = 0.008; damp = 0.25
        case 102: rt = 2.2; pre = 0.025; damp = 0.12
        case 103: rt = 3.0; pre = 0.04; damp = 0.2; taps = [(0.18, 0.5), (0.36, 0.35), (0.54, 0.25)]
        default: rt = 1.5; pre = 0.0; damp = 0.7
        }
        let preN = Int(pre * rate)
        let len = min(Int(rate * 3.5), preN + Int(rate * rt * 1.15))
        var out: [[Float]] = []
        for ch in 0..<2 {
            var h = [Float](repeating: 0, count: len)
            var s: UInt32 = ch == 0 ? 0x1234567 : 0x9E3779B
            var y: Float = 0
            for i in preN..<len {
                s ^= s << 13; s ^= s >> 17; s ^= s << 5
                let x = Float(Int32(bitPattern: s)) / 2147483648.0
                let t = Double(i - preN) / rate
                let a = Float(damp + (0.95 - damp) * exp(-t / (rt * 0.4)))
                y += a * (x - y)
                h[i] = y * Float(exp(-6.9078 * t / rt))
            }
            for j in 0..<6 {
                let d = preN + Int(rate * (0.004 + Double(j) * 0.011 + Double(ch) * 0.0023))
                if d < len { h[d] += Float(0.6 / Double(j + 1)) * (j % 2 == 0 ? 1 : -1) }
            }
            for (t, g) in taps {
                let d = preN + Int(rate * (t + Double(ch) * 0.007))
                if d < len { h[d] += g }
            }
            out.append(h)
        }
        normalize(&out)
        return out
    }

    /// Reads a WAV/AIFF impulse response (first 4 seconds), converts it to the engine's sample rate, makes it stereo.
    static func loadIR(_ path: String, rate: Double) -> [[Float]]? {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)), file.length > 0 else { return nil }
        let srcRate = file.processingFormat.sampleRate
        let frames = AVAudioFrameCount(min(file.length, Int64(srcRate * 4)))
        guard srcRate > 0, let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames),
              (try? file.read(into: buf, frameCount: frames)) != nil, let data = buf.floatChannelData else { return nil }
        let n = Int(buf.frameLength)
        guard n > 0 else { return nil }
        let chs = Int(buf.format.channelCount)
        var out: [[Float]] = []
        let ratio = srcRate / rate
        let m = max(1, min(Int(Double(n) / ratio), Int(rate * 4)))
        for c in 0..<2 {
            let src = data[min(c, chs - 1)]
            var h = [Float](repeating: 0, count: m)
            for i in 0..<m {
                let p = Double(i) * ratio
                let i0 = min(Int(p), n - 1), i1 = min(i0 + 1, n - 1)
                let t = Float(p - Double(i0))
                h[i] = src[i0] + (src[i1] - src[i0]) * t
            }
            out.append(h)
        }
        normalize(&out)
        return out
    }

    /// Scales so the average channel energy is 0.5, which puts every room at a similar level.
    static func normalize(_ irs: inout [[Float]]) {
        var e = 0.0
        for h in irs { for v in h { e += Double(v) * Double(v) } }
        e /= Double(max(1, irs.count))
        guard e > 1e-12 else { return }
        let g = Float((0.5 / e).squareRoot())
        for c in 0..<irs.count { for i in 0..<irs[c].count { irs[c][i] *= g } }
    }
}
