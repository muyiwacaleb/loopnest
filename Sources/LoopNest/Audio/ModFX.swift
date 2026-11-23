import Foundation

/// Per-channel modulation effect: chorus, flanger, phaser or tremolo. Runs on the audio thread:
/// fixed buffers allocated up front, no locks, no allocation while playing.
final class ModFX {
    static let names = ["Off", "Chorus", "Flanger", "Phaser", "Tremolo"]
    var mode = 0                 // 0 off, 1 chorus, 2 flanger, 3 phaser, 4 tremolo
    var rate: Float = 0.6        // Hz
    var depth: Float = 0.5       // 0...1
    var mix: Float = 0.5         // 0...1 wet
    var sampleRate: Float = 44100

    private let size = 8192
    private let buf: UnsafeMutablePointer<Float>       // two delay lines
    private var w = 0
    private var phase: Float = 0
    private var ap = [Float](repeating: 0, count: 8)   // phaser all-pass state, 4 stages x 2 channels
    private var fb: [Float] = [0, 0]

    init() { buf = .allocate(capacity: 8192 * 2); buf.initialize(repeating: 0, count: 8192 * 2) }
    deinit { buf.deallocate() }

    @inline(__always) private func read(_ ch: Int, _ delay: Float) -> Float {
        let d = min(max(delay, 1), Float(size - 2))
        let p = Float(w) - d
        var i0 = Int(p.rounded(.down)); let f = p - Float(i0)
        if i0 < 0 { i0 += size }
        let i1 = (i0 + 1) % size
        return buf[ch * size + i0] * (1 - f) + buf[ch * size + i1] * f
    }

    func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int) {
        guard mode != 0 else { return }
        let inc = 2 * Float.pi * rate / sampleRate
        let ms = sampleRate / 1000
        for i in 0..<n {
            let x0 = l[i], x1 = r[i]
            let s0 = sin(phase), s1 = sin(phase + Float.pi / 2)
            phase += inc; if phase > 2 * Float.pi { phase -= 2 * Float.pi }
            switch mode {
            case 1, 2:        // chorus / flanger: modulated delay line
                let base: Float = mode == 1 ? 14 * ms : 2.5 * ms
                let swing: Float = mode == 1 ? 7 * ms * depth : 2.2 * ms * depth
                let feedback: Float = mode == 2 ? 0.55 : 0
                let y0 = read(0, base + swing * s0), y1 = read(1, base + swing * s1)
                buf[w] = x0 + fb[0] * feedback; buf[size + w] = x1 + fb[1] * feedback
                fb[0] = y0; fb[1] = y1
                let wet: Float = mode == 2 ? (1 - feedback) : 1      // feedback can build the signal up to 1/(1-feedback) times; scale it back
                l[i] = x0 * (1 - mix * 0.5) + y0 * mix * wet
                r[i] = x1 * (1 - mix * 0.5) + y1 * mix * wet
                w = (w + 1) % size
            case 3:           // phaser: 4 all-pass stages swept by the LFO
                let sweep = 0.5 + 0.5 * s0
                let fc = 200 * pow(10, sweep * depth * 1.3 + 0.0)          // about 200 Hz ... 4 kHz
                let t = tan(Float.pi * min(fc, sampleRate * 0.45) / sampleRate)
                let a = (t - 1) / (t + 1)
                var v0 = x0 + fb[0] * 0.4, v1 = x1 + fb[1] * 0.4
                for st in 0..<4 {
                    let o0 = a * v0 + ap[st]; ap[st] = v0 - a * o0; v0 = o0
                    let o1 = a * v1 + ap[4 + st]; ap[4 + st] = v1 - a * o1; v1 = o1
                }
                fb[0] = v0; fb[1] = v1
                l[i] = x0 * (1 - mix * 0.5) + v0 * mix * 0.5
                r[i] = x1 * (1 - mix * 0.5) + v1 * mix * 0.5
            default:          // tremolo
                let g0 = 1 - depth * (0.5 - 0.5 * s0), g1 = 1 - depth * (0.5 - 0.5 * s1)
                l[i] = x0 * g0; r[i] = x1 * g1
            }
        }
    }
}
