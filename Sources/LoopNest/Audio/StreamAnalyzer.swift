import Foundation
import Accelerate

/// Broadcast meters for the stream mix: true peak, stereo correlation, balance and a phase scope.
/// Runs on the engine's tap thread; the UI only reads the numbers.
final class StreamAnalyzer {
    var active = false                    // phase scope / correlation only run while they are on screen
    var truePeakDB: Float = -120          // recent true peak (decays slowly)
    var truePeakHoldDB: Float = -120      // highest since reset
    var correlation: Float = 0            // +1 mono-compatible ... -1 out of phase
    var balance: Float = 0                // -1 left ... +1 right
    static let scopePoints = 256
    var scope = [Float](repeating: 0, count: StreamAnalyzer.scopePoints * 2)
    private var scopeWrite = 0

    func reset() { truePeakHoldDB = -120; truePeakDB = -120 }

    /// 4x oversampled peak using a Catmull-Rom interpolator between neighbouring samples.
    private func truePeak(_ x: UnsafePointer<Float>, _ n: Int) -> Float {
        var peak: Float = 0
        vDSP_maxmgv(x, 1, &peak, vDSP_Length(n))
        guard n > 4 else { return peak }
        for i in 1..<(n - 2) {
            // only samples near the top can hide an inter-sample peak above the sample peak
            if abs(x[i]) < 0.35 && abs(x[i + 1]) < 0.35 { continue }
            let y0 = x[i - 1], y1 = x[i], y2 = x[i + 1], y3 = x[i + 2]
            for t: Float in [0.25, 0.5, 0.75] {
                let a = -0.5 * y0 + 1.5 * y1 - 1.5 * y2 + 0.5 * y3
                let b = y0 - 2.5 * y1 + 2 * y2 - 0.5 * y3
                let c = -0.5 * y0 + 0.5 * y2
                let v = ((a * t + b) * t + c) * t + y1
                if abs(v) > peak { peak = abs(v) }
            }
        }
        return peak
    }

    func process(_ l: UnsafePointer<Float>, _ r: UnsafePointer<Float>, _ n: Int) {
        guard n > 8 else { return }
        let tp = max(truePeak(l, n), truePeak(r, n))
        let db = tp > 0.000001 ? 20 * log10(tp) : -120
        truePeakDB = max(db, truePeakDB - 0.6)
        if db > truePeakHoldDB { truePeakHoldDB = db }

        guard active else { return }
        var sll: Float = 0, srr: Float = 0, slr: Float = 0
        vDSP_svesq(l, 1, &sll, vDSP_Length(n)); vDSP_svesq(r, 1, &srr, vDSP_Length(n)); vDSP_dotpr(l, 1, r, 1, &slr, vDSP_Length(n))
        if sll + srr > 1e-8 {
            let c = slr / max(1e-9, sqrt(sll * srr))
            correlation += (max(-1, min(1, c)) - correlation) * 0.25
            let rl = sqrt(sll), rr = sqrt(srr)
            balance += ((rr - rl) / max(1e-9, rr + rl) - balance) * 0.25
        } else {
            correlation *= 0.9; balance *= 0.9
        }
        let step = max(1, n / StreamAnalyzer.scopePoints)
        var i = 0
        while i < n {
            let m = (l[i] + r[i]) * 0.70710678, s = (l[i] - r[i]) * 0.70710678
            scope[scopeWrite * 2] = s; scope[scopeWrite * 2 + 1] = m
            scopeWrite = (scopeWrite + 1) % StreamAnalyzer.scopePoints
            i += step
        }
    }
}
