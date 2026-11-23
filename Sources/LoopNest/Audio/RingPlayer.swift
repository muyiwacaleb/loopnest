import Foundation
import CRing

/// Reads interleaved stereo frames from a ring on the audio thread, converting sample rate
/// (linear interpolation) and keeping latency low by dropping old audio when it falls behind.
final class RingPlayer {
    private let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 32768 * 2)
    private var frac = 0.0
    private var prevL: Float = 0, prevR: Float = 0
    init() { scratch.initialize(repeating: 0, count: 32768 * 2) }
    deinit { scratch.deallocate() }

    /// Times the reader ran out of audio and had to wait for the buffer to refill.
    private(set) var underruns = 0
    private var primed = false
    private var adj = 0.0

    private func clear(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int) {
        for i in 0..<n { l[i] = 0; r[i] = 0 }
    }

    /// ratio = ring rate / output rate.
    /// Keeps a small cushion of audio in the ring (so bursts and clock drift between two devices don't cause gaps),
    /// nudges the read speed to hold that cushion, and falls back to silence while the cushion refills.
    func render(ring: OpaquePointer, n requested: Int, ratio: Double,
                l: UnsafeMutablePointer<Float>, r: UnsafeMutablePointer<Float>) {
        let n = min(requested, 8192)
        var avail = Int(cring_available(ring))
        let target = max(1024.0, Double(n) * 2.5 * ratio)
        let want = Int(Double(n) * ratio * 1.01) + 3
        if requested > n { for i in n..<requested { l[i] = 0; r[i] = 0 } }
        if !primed {
            if Double(avail) < target { clear(l, r, n); return }
            primed = true
        }
        if avail < want { primed = false; underruns &+= 1; clear(l, r, n); return }
        let maxFill = Int(target * 4) + 2000
        while avail > maxFill {                       // far behind (after a stall): jump back to the cushion
            let drop = min(avail - Int(target), 16384)
            _ = cring_read(ring, scratch, UInt32(drop)); avail -= drop
        }
        if abs(ratio - 1) < 0.0005 {
            var take = n
            if Double(avail) > target + 384 { take = n + 1 }                      // drop one frame
            else if Double(avail) < target - 384 && n > 2 { take = n - 1 }        // repeat one frame
            _ = cring_read(ring, scratch, UInt32(take))
            for i in 0..<min(n, take) { l[i] = scratch[i * 2]; r[i] = scratch[i * 2 + 1] }
            if take < n { for i in take..<n { l[i] = scratch[(take - 1) * 2]; r[i] = scratch[(take - 1) * 2 + 1] } }
        } else {
            let err = (Double(avail) - target) / target
            adj += (max(-0.004, min(0.004, err * 0.004)) - adj) * 0.02
            let eff = ratio * (1 + adj)
            let consume = min(Int(frac + Double(n) * eff), 16000)
            _ = cring_read(ring, scratch, UInt32(consume))
            for i in 0..<n {
                let p = frac + Double(i) * eff
                let i0 = min(Int(p), consume)
                let t = Float(p - Double(Int(p)))
                let i1 = min(i0 + 1, consume)
                let a0l = i0 == 0 ? prevL : scratch[(i0 - 1) * 2], a0r = i0 == 0 ? prevR : scratch[(i0 - 1) * 2 + 1]
                let a1l = i1 == 0 ? prevL : scratch[(i1 - 1) * 2], a1r = i1 == 0 ? prevR : scratch[(i1 - 1) * 2 + 1]
                l[i] = a0l + (a1l - a0l) * t
                r[i] = a0r + (a1r - a0r) * t
            }
            if consume > 0 { prevL = scratch[(consume - 1) * 2]; prevR = scratch[(consume - 1) * 2 + 1] }
            frac = frac + Double(n) * eff - Double(consume)
        }
    }
}
