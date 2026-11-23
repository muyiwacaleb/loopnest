import AppKit
import SwiftUI

enum Theme {
    static let bg = Color(red: 0.055, green: 0.047, blue: 0.075)
    static let panel = Color(red: 0.105, green: 0.09, blue: 0.14)
    static let strip = Color(red: 0.13, green: 0.11, blue: 0.175)
    static let well = Color(red: 0.045, green: 0.04, blue: 0.06)
    static let purple = Color(red: 0.55, green: 0.36, blue: 0.96)
    static let gold = Color(red: 0.98, green: 0.78, blue: 0.25)
    static let blue = Color(red: 0.25, green: 0.55, blue: 0.95)
    static let text = Color(white: 0.92)
    static let dim = Color(white: 0.55)
    static let green = Color(red: 0.25, green: 0.85, blue: 0.4)
    static let orange = Color(red: 1.0, green: 0.55, blue: 0.15)
    static let red = Color(red: 0.95, green: 0.25, blue: 0.3)
}

/// Pill-style toggle button (MUTE / SOLO / COMP / GRP ...).
struct PillButton: View {
    let label: String
    var on: Bool
    var tint: Color = Theme.purple
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .frame(maxWidth: .infinity, minHeight: 22)
                .foregroundColor(on ? .black : Theme.text)
                .background(RoundedRectangle(cornerRadius: 5).fill(on ? tint : Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }
}

/// Rotary knob. Drag up/down; double-click resets.
struct Knob: View {
    @Binding var value: Float
    var range: ClosedRange<Float> = -1...1
    var reset: Float = 0
    var label: String = ""
    var size: CGFloat = 34
    @LState private var startValue: Float?

    var body: some View {
        let frac = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
        VStack(spacing: 2) {
            ZStack {
                Circle().fill(Theme.well)
                Circle().trim(from: 0.125, to: 0.875).stroke(Color.white.opacity(0.1), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(90))
                Circle().trim(from: 0.125, to: 0.125 + 0.75 * frac).stroke(Theme.purple, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(90))
                Rectangle().fill(Theme.gold).frame(width: 2, height: size * 0.28).offset(y: -size * 0.2)
                    .rotationEffect(.degrees(-135 + 270 * Double(frac)))
            }
            .frame(width: size, height: size)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if startValue == nil { startValue = value }
                    let span = range.upperBound - range.lowerBound
                    let v = startValue! - Float(g.translation.height) / 150 * span
                    let nv = min(range.upperBound, max(range.lowerBound, v))
                    if nv != value { value = nv }
                }
                .onEnded { _ in startValue = nil })
            .simultaneousGesture(TapGesture(count: 2).onEnded { value = reset })
            if !label.isEmpty { Text(label).font(.system(size: 9)).foregroundColor(Theme.dim) }
        }
    }
}

/// Vertical slider used for faders and EQ bands.
struct VSlider: View {
    @Binding var value: Float
    var range: ClosedRange<Float>
    var reset: Float
    var width: CGFloat = 28
    var tint: Color = Theme.purple
    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let frac = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 3).fill(Theme.well).frame(width: 6)
                RoundedRectangle(cornerRadius: 3).fill(tint.opacity(0.55)).frame(width: 6, height: max(0, frac * h))
                RoundedRectangle(cornerRadius: 4).fill(LinearGradient(colors: [Color(white: 0.9), Color(white: 0.6)], startPoint: .top, endPoint: .bottom))
                    .overlay(Rectangle().fill(Theme.gold).frame(height: 2))
                    .frame(width: width, height: 16)
                    .offset(y: -(frac * (h - 16)))
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let f = 1 - min(1, max(0, (g.location.y - 8) / (h - 16)))
                value = range.lowerBound + Float(f) * (range.upperBound - range.lowerBound)
            })
            .simultaneousGesture(TapGesture(count: 2).onEnded { value = reset })
        }
    }
}

/// Stereo level meter in a recessed well: green / yellow / orange.
struct LevelMeter: View {
    let meter: Meter
    var height: CGFloat = 150
    var showScale = true
    private static let marks: [Int] = [0, -6, -12, -24, -48]
    var body: some View {
        HStack(spacing: 1) {
            if showScale { scale }
            LayerMeter(meter: meter)
            .frame(width: 22)
        }
        .frame(width: showScale ? 38 : 22, height: height)
    }
    /// dB numbers beside the meter (0 is the loudest the output can be before it clips).
    private var scale: some View {
        GeometryReader { g in
            ZStack(alignment: .topTrailing) {
                ForEach(Self.marks, id: \.self) { m in
                    Text(m == 0 ? "0" : "\(m)")
                        .font(.system(size: 7, design: .monospaced))
                        .foregroundColor(m == 0 ? Theme.orange : Theme.dim)
                        .offset(y: 3 + (1 - frac(Float(pow(10, Double(m) / 20)))) * (g.size.height - 6) - 4)
                }
            }
            .frame(width: g.size.width, height: g.size.height, alignment: .topTrailing)
        }
        .frame(width: 15)
    }
    private func frac(_ a: Float) -> CGFloat {
        guard a > 0.00001 else { return 0 }
        return CGFloat(max(0, min(1, (20 * log10(a) + 60) / 60)))
    }
}

func dbText(_ db: Float) -> String { db <= StripSettings.minDB ? "-∞" : String(format: "%+.1f", db) }

/// Local view state. Stands in for @State, which the Command Line Tools can't compile (it's a macro that needs Xcode).
final class LStateBox<Value>: ObservableObject {
    var value: Value { didSet { objectWillChange.send() } }
    init(_ v: Value) { value = v }
}

@propertyWrapper
struct LState<Value>: DynamicProperty {
    @StateObject private var box: LStateBox<Value>
    init(wrappedValue: Value) { _box = StateObject(wrappedValue: LStateBox(wrappedValue)) }
    var wrappedValue: Value {
        get { box.value }
        nonmutating set { box.value = newValue }
    }
    var projectedValue: Binding<Value> {
        Binding(get: { box.value }, set: { box.value = $0 })
    }
}


/// Colour tags for channels (index 1...8; 0 means none).
let channelColors: [Color] = [.clear, Color(red: 0.93, green: 0.35, blue: 0.35), Color(red: 0.96, green: 0.58, blue: 0.25),
                              Color(red: 0.95, green: 0.82, blue: 0.30), Color(red: 0.42, green: 0.80, blue: 0.45),
                              Color(red: 0.30, green: 0.75, blue: 0.80), Color(red: 0.38, green: 0.55, blue: 0.95),
                              Color(red: 0.66, green: 0.47, blue: 0.93), Color(red: 0.92, green: 0.47, blue: 0.75)]


/// True while any LoopNest window can actually be seen. Meters and timelines stop redrawing when it is false,
/// so a hidden or covered window costs almost nothing.
final class UIVisibility: ObservableObject {
    static let shared = UIVisibility()
    @Published private(set) var visible = true
    private init() {
        let nc = NotificationCenter.default
        for n in [NSWindow.didChangeOcclusionStateNotification, NSApplication.didHideNotification, NSApplication.didUnhideNotification,
                  NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification, NSApplication.didBecomeActiveNotification] {
            nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in self?.update() }
        }
    }
    func update() {
        let v = !NSApp.isHidden && NSApp.windows.contains { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) }
        if v != visible { visible = v }
    }
}

/// Redraws its content on a fixed interval, but only while a window is visible.
struct LiveTimeline<Content: View>: View {
    @ObservedObject private var vis = UIVisibility.shared
    let interval: Double
    let content: () -> Content
    init(_ interval: Double, @ViewBuilder content: @escaping () -> Content) { self.interval = interval; self.content = content }
    var body: some View {
        TimelineView(.animation(minimumInterval: interval, paused: !vis.visible)) { _ in content() }
    }
}
