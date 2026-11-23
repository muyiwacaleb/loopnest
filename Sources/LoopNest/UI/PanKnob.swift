import SwiftUI

/// A pan knob in the style of a pro mixer: a green arc from the centre to the setting and the position as a number
/// inside (-64 ... +63). Drag up / down to change it, double-click to put it back.
struct PanKnob: View {
    @Binding var value: Float          // -1 ... +1
    var reset: Float = 0
    var size: CGFloat = 38
    @LState private var startValue: Float?

    static func label(_ v: Float) -> String {
        if abs(v) < 0.008 { return "0" }
        return v > 0 ? "+\(Int((v * 63).rounded()))" : "\(Int((v * 64).rounded()))"
    }

    var body: some View {
        let v = max(-1, min(1, value))
        ZStack {
            Circle().fill(Color.black)
            // track: 270 degrees, from lower left over the top to lower right
            Circle().trim(from: 0.125, to: 0.875).stroke(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 3, lineCap: .butt))
                .rotationEffect(.degrees(90)).padding(2)
            // value arc grows from the top centre to either side
            let half: CGFloat = 0.375
            let a = CGFloat(abs(v)) * half
            Circle().trim(from: v >= 0 ? 0.5 + 0 : 0.5 - a, to: v >= 0 ? 0.5 + a : 0.5)
                .stroke(Theme.green, style: StrokeStyle(lineWidth: 3, lineCap: .butt))
                .rotationEffect(.degrees(90)).padding(2)
            Circle().fill(LinearGradient(colors: [Color(white: 0.72), Color(white: 0.5)], startPoint: .top, endPoint: .bottom))
                .padding(size * 0.14)
            Text(PanKnob.label(v)).font(.system(size: size * 0.31, weight: .bold, design: .rounded)).foregroundColor(.white)
                .shadow(color: .black.opacity(0.5), radius: 1)
        }
        .frame(width: size, height: size)
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { g in
                if startValue == nil { startValue = value }
                let nv = min(1, max(-1, startValue! - Float(g.translation.height) / 80))
                if nv != value { value = nv }       // a plain click must not write anything back
            }
            .onEnded { _ in startValue = nil })
        .simultaneousGesture(TapGesture(count: 2).onEnded { value = reset })
        .help("Pan. Drag up / down, double-click to reset.")
    }
}

/// Peak level box: shows the highest level since you last clicked it, red once it passed 0 dB.
struct PeakBox: View {
    let meter: Meter
    let right: Bool
    var body: some View {
        LayerPeak(meter: meter, right: right)
            .frame(maxWidth: .infinity).frame(height: 18)
        .help("Peak level. Click to clear.")
    }
}

/// Left and right pan knobs with peak boxes underneath, side by side.
struct StereoPanView: View {
    @ObservedObject var strip: Strip
    var body: some View {
        VStack(spacing: 3) {
            Text("PAN").font(.system(size: 9, weight: .semibold)).foregroundColor(Theme.dim)
            HStack(spacing: 4) {
                VStack(spacing: 3) {
                    PanKnob(value: $strip.s.panL, reset: -1, size: 36)
                    PeakBox(meter: strip.meter, right: false)
                }
                VStack(spacing: 3) {
                    PanKnob(value: $strip.s.panR, reset: 1, size: 36)
                    PeakBox(meter: strip.meter, right: true)
                }
            }
            if strip.kind == .deck || strip.kind == .board {
                Text("balance").font(.system(size: 8)).foregroundColor(Theme.dim)
            }
        }
    }
}
