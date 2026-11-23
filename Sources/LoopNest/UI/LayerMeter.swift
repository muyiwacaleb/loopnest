import AppKit
import SwiftUI
import QuartzCore

/// A level meter drawn with plain Core Animation layers. It reads the meter on its own timer and moves layers
/// directly, so a meter moving does not make SwiftUI recalculate the window. The timer only runs while the window is visible.
final class LayerMeterView: NSView {
    var meter: Meter? { didSet { needsLayout = true } }
    var vertical = true
    var inset: CGFloat = 3
    var corner: CGFloat = 4
    private let bg = CALayer()
    private var clips: [CALayer] = [CALayer(), CALayer()]
    private var grads: [CAGradientLayer] = [CAGradientLayer(), CAGradientLayer()]
    private var cells: [CALayer] = [CALayer(), CALayer()]
    private var holds: [CALayer] = [CALayer(), CALayer()]
    private var timer: Timer?
    private var last: (Float, Float, Float, Float) = (-1, -1, -1, -1)

    override init(frame: NSRect) { super.init(frame: frame); setup() }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        wantsLayer = true
        layer = CALayer()
        bg.backgroundColor = NSColor(Theme.well).cgColor
        layer?.addSublayer(bg)
        let colors = [NSColor(Theme.green), NSColor(Theme.green), NSColor(Theme.gold), NSColor(Theme.orange)].map { $0.cgColor }
        for i in 0..<2 {
            cells[i].backgroundColor = NSColor.white.withAlphaComponent(0.04).cgColor
            layer?.addSublayer(cells[i])
            clips[i].masksToBounds = true
            grads[i].colors = colors
            grads[i].locations = [0, 0.7, 0.85, 1]
            grads[i].anchorPoint = .zero
            clips[i].addSublayer(grads[i])
            layer?.addSublayer(clips[i])
            holds[i].backgroundColor = NSColor(Theme.text).withAlphaComponent(0.8).cgColor
            layer?.addSublayer(holds[i])
        }
    }

    override var isFlipped: Bool { false }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); restart() }
    override func layout() { super.layout(); last = (-1, -1, -1, -1); refresh() }

    private func restart() {
        timer?.invalidate(); timer = nil
        guard window != nil else { return }
        let t = Timer(timeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in self?.refresh() }
        t.tolerance = 0.02
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
    deinit { timer?.invalidate() }

    private func frac(_ a: Float) -> CGFloat {
        guard a > 0.00001 else { return 0 }
        return CGFloat(max(0, min(1, (20 * log10(a) + 60) / 60)))
    }

    private func refresh() {
        guard let m = meter, UIVisibility.shared.visible, !isHiddenOrHasHiddenAncestor else { return }
        let cur = (m.l, m.r, m.holdL, m.holdR)
        if cur == last { return }
        last = cur
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let b = bounds
        bg.frame = b; bg.cornerRadius = corner
        let pairs = [(m.l, m.holdL), (m.r, m.holdR)]
        if vertical {
            let w = (b.width - 2 * inset - 2) / 2, h = b.height - 2 * inset
            for i in 0..<2 {
                let x = inset + CGFloat(i) * (w + 2)
                cells[i].frame = CGRect(x: x, y: inset, width: w, height: h)
                let fh = frac(pairs[i].0) * h
                clips[i].frame = CGRect(x: x, y: inset, width: w, height: fh)
                grads[i].frame = CGRect(x: 0, y: 0, width: w, height: h)
                grads[i].startPoint = CGPoint(x: 0, y: 0); grads[i].endPoint = CGPoint(x: 0, y: 1)
                holds[i].isHidden = !(pairs[i].1 > 0.001)
                holds[i].frame = CGRect(x: x, y: inset + frac(pairs[i].1) * h, width: w, height: 1)
            }
        } else {
            // horizontal: one bar per channel is too thin to read, so show the louder of the two
            let a = max(m.l, m.r)
            let f = frac(a)
            cells[0].frame = b; cells[1].frame = .zero
            clips[0].frame = CGRect(x: 0, y: 0, width: b.width * f, height: b.height)
            grads[0].frame = CGRect(x: 0, y: 0, width: b.width, height: b.height)
            grads[0].startPoint = CGPoint(x: 0, y: 0); grads[0].endPoint = CGPoint(x: 1, y: 0)
            clips[1].frame = .zero; holds[0].isHidden = true; holds[1].isHidden = true
            cells[0].cornerRadius = b.height / 2; clips[0].cornerRadius = b.height / 2
        }
    }
}

struct LayerMeter: NSViewRepresentable {
    let meter: Meter
    var vertical = true
    func makeNSView(context: Context) -> LayerMeterView {
        let v = LayerMeterView(frame: .zero)
        v.vertical = vertical; v.meter = meter
        return v
    }
    func updateNSView(_ v: LayerMeterView, context: Context) { if v.meter !== meter { v.meter = meter } }
}

/// The master spectrum, drawn with layers (32 bars) so it does not make SwiftUI rebuild 32 views every tick.
final class LayerSpectrumView: NSView {
    var engine: MixerEngine?
    private var clips: [CALayer] = []
    private var grads: [CAGradientLayer] = []
    private var timer: Timer?
    private var last = [Float](repeating: -1, count: 32)

    override init(frame: NSRect) { super.init(frame: frame); setup() }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }
    private func setup() {
        wantsLayer = true
        layer = CALayer()
        let colors = [NSColor(Theme.purple).cgColor, NSColor(Theme.gold).cgColor]
        for _ in 0..<32 {
            let c = CALayer(); c.masksToBounds = true
            let g = CAGradientLayer(); g.colors = colors; g.anchorPoint = .zero
            g.startPoint = CGPoint(x: 0, y: 0); g.endPoint = CGPoint(x: 0, y: 1)
            c.addSublayer(g); layer?.addSublayer(c)
            clips.append(c); grads.append(g)
        }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate(); timer = nil
        guard window != nil else { return }
        let t = Timer(timeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in self?.refresh() }
        t.tolerance = 0.02
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
    override func layout() { super.layout(); last = [Float](repeating: -1, count: 32); refresh() }
    deinit { timer?.invalidate() }

    private func refresh() {
        guard let e = engine, UIVisibility.shared.visible, !isHiddenOrHasHiddenAncestor else { return }
        let spec = e.spectrum
        if spec == last { return }
        last = spec
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let b = bounds
        let w = (b.width - 31) / 32
        for i in 0..<min(32, spec.count) {
            let h = max(1, CGFloat(spec[i]) * b.height)
            clips[i].frame = CGRect(x: CGFloat(i) * (w + 1), y: 0, width: max(1, w), height: min(h, b.height))
            grads[i].frame = CGRect(x: 0, y: 0, width: max(1, w), height: b.height)
        }
    }
}

struct LayerSpectrum: NSViewRepresentable {
    let engine: MixerEngine
    func makeNSView(context: Context) -> LayerSpectrumView { let v = LayerSpectrumView(frame: .zero); v.engine = engine; return v }
    func updateNSView(_ v: LayerSpectrumView, context: Context) {}
}

/// Peak level box drawn with a text layer; click clears the peak.
final class LayerPeakView: NSView {
    var meter: Meter?
    var right = false
    private let text = CATextLayer()
    private var timer: Timer?
    private var lastText = "\u{1}"
    private var lastRed = false

    override init(frame: NSRect) { super.init(frame: frame); setup() }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }
    private func setup() {
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        layer?.cornerRadius = 4
        text.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
        text.fontSize = 10
        text.alignmentMode = .center
        text.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        layer?.addSublayer(text)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate(); timer = nil
        guard window != nil else { return }
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.refresh() }
        t.tolerance = 0.05
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
    override func layout() { super.layout(); text.frame = CGRect(x: 0, y: (bounds.height - 13) / 2, width: bounds.width, height: 13); lastText = "\u{1}"; refresh() }
    override func mouseDown(with event: NSEvent) { meter?.resetPeak(); refresh() }
    deinit { timer?.invalidate() }

    private func refresh() {
        guard let m = meter, UIVisibility.shared.visible, !isHiddenOrHasHiddenAncestor else { return }
        let p = right ? m.peakR : m.peakL
        let db: Float = p > 0.00001 ? 20 * log10(p) : -120
        let s = db > -100 ? String(format: "%.1f", db) : ""
        let red = db > 0
        if s == lastText && red == lastRed { return }
        lastText = s; lastRed = red
        CATransaction.begin(); CATransaction.setDisableActions(true)
        text.string = s
        text.foregroundColor = (red ? NSColor(Theme.red) : NSColor(Theme.text)).cgColor
        CATransaction.commit()
    }
}

struct LayerPeak: NSViewRepresentable {
    let meter: Meter
    let right: Bool
    func makeNSView(context: Context) -> LayerPeakView { let v = LayerPeakView(frame: .zero); v.meter = meter; v.right = right; return v }
    func updateNSView(_ v: LayerPeakView, context: Context) {}
}
