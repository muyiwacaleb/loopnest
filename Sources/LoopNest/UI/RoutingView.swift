import SwiftUI

/// Loopback-style: devices on the left; in the middle a Sources column, virtual wires, and an Output Channels column;
/// a Monitors / Volume bar along the bottom.
struct RoutingView: View {
    @EnvironmentObject var app: AppState
    @LState private var selected: UUID?

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 210)
            Divider()
            if let id = selected ?? app.vdevices.first?.id, let idx = app.vdevices.firstIndex(where: { $0.id == id }) {
                DeviceEditor(cfg: $app.vdevices[idx])
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 40)).foregroundColor(Theme.purple)
                    Text("Create a virtual device").font(.title3)
                    Text("Combine apps and inputs into one device that any app can pick as a microphone or speaker.")
                        .font(.caption).foregroundColor(Theme.dim).multilineTextAlignment(.center).frame(width: 300)
                    Button("New Virtual Device") { app.addVirtualDevice() }.buttonStyle(.borderedProminent).tint(Theme.purple)
                    if !app.driverInstalled { DriverBanner().frame(width: 300) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("VIRTUAL DEVICES").font(.system(size: 10, weight: .bold)).foregroundColor(Theme.dim)
                Spacer()
                Button { app.importRouting() } label: { Image(systemName: "square.and.arrow.down") }.buttonStyle(.plain).help("Load a saved routing set-up")
                Button { app.exportRouting() } label: { Image(systemName: "square.and.arrow.up") }.buttonStyle(.plain).help("Save this routing set-up to a file")
                Button { app.addVirtualDevice() } label: { Image(systemName: "plus") }.buttonStyle(.plain)
            }
            ForEach(app.vdevices) { d in
                let isSel = (selected ?? app.vdevices.first?.id) == d.id
                HStack {
                    Image(systemName: d.passThru ? "arrow.left.arrow.right" : "waveform.path")
                    VStack(alignment: .leading, spacing: 0) {
                        Text(d.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Text(d.passThru ? "Pass-Thru" : "\(d.channels) ch · \(d.sources.count) sources").font(.system(size: 10)).foregroundColor(Theme.dim)
                    }
                    Spacer()
                    Circle().fill(d.enabled && app.driverInstalled ? Theme.green : Theme.dim).frame(width: 7, height: 7)
                }
                .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(isSel ? Theme.purple.opacity(0.35) : Theme.strip))
                .onTapGesture { selected = d.id }
                .contextMenu { Button("Delete", role: .destructive) { app.removeVirtualDevice(d.id) } }
            }
            Spacer()
            if !app.driverInstalled { DriverBanner() }
        }.padding(12)
    }
}

struct DriverBanner: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Driver not installed", systemImage: "exclamationmark.triangle.fill").foregroundColor(Theme.gold).font(.caption.bold())
            Text("Virtual devices need LoopNest's audio driver so other apps can see them. Installing asks for your password once and restarts macOS audio for a moment.")
                .font(.caption2).foregroundColor(Theme.dim)
            Button("Install Driver…") { app.installDriver() }.controlSize(.small)
            if !app.statusMessage.isEmpty { Text(app.statusMessage).font(.caption2).foregroundColor(Theme.dim) }
        }.padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.3)))
    }
}

struct DeviceEditor: View {
    @EnvironmentObject var app: AppState
    @Binding var cfg: VirtualDeviceConfig
    @LState private var dragFrom: UUID?
    @LState private var dragSrcCh = 0
    @LState private var dragPoint: CGPoint = .zero

    let cardH: CGFloat = 78, rowH: CGFloat = 28, cardW: CGFloat = 240, chanW: CGFloat = 150, gap: CGFloat = 150
    var canvasW: CGFloat { cardW + gap + chanW }
    let top: CGFloat = 34

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView { wiring.padding(16).frame(maxWidth: .infinity) }
            Divider()
            bottomBar
        }
    }

    // MARK: header
    private var header: some View {
        HStack(spacing: 10) {
            TextField("Device name", text: $cfg.name).textFieldStyle(.roundedBorder).frame(width: 170)
            Toggle("Pass-Thru", isOn: $cfg.passThru).fixedSize()
                .help("Passes audio from one app to another with almost no setup: any app can play into this device and any other can record from it.")
            Menu("Patch tools") {
                Section("Split, merge and swap") {
                    ForEach(cfg.sources) { src in
                        Menu(src.name) {
                            Button("Swap its left and right") { PatchOps.swapSides(&cfg, source: src.id) }
                            Button("Make it mono (both sides on outputs 1 and 2)") { PatchOps.makeMono(&cfg, source: src.id) }
                        }
                    }
                    Button("Merge every source onto outputs 1 and 2") { PatchOps.mergeAll(&cfg) }.disabled(cfg.channels < 2 || cfg.sources.isEmpty)
                    Menu("Swap two output channels") {
                        ForEach(0..<max(cfg.channels - 1, 0), id: \.self) { c in Button("Channel \(c + 1) and \(c + 2)") { PatchOps.swapOutputs(&cfg, c, c + 1) } }
                    }
                    Menu("Copy an output channel to another (split)") {
                        ForEach(0..<cfg.channels, id: \.self) { f in
                            Menu("From channel \(f + 1)") {
                                ForEach((0..<cfg.channels).filter { $0 != f }, id: \.self) { t in Button("To channel \(t + 1)") { PatchOps.split(&cfg, from: f, to: t) } }
                            }
                        }
                    }
                }
            }.menuStyle(.borderlessButton).fixedSize()
                .help("Swap left and right, make a source mono, merge sources onto one pair, or copy one output channel to another")
            let loops = PatchOps.loopProblems(app.vdevices)
            if !loops.isEmpty {
                Label("Feedback risk", systemImage: "exclamationmark.triangle.fill").foregroundColor(Theme.orange).font(.caption)
                    .help(loops.joined(separator: "\n"))
            }
            Spacer(minLength: 0)
            Toggle("On", isOn: $cfg.enabled).toggleStyle(.switch).fixedSize()
            Button("Apply name & channels") { app.writeDriverConfig(restartAudio: true) }
                .controlSize(.small).help("The driver reads the name and channel count when macOS audio starts, so this restarts macOS audio.")
        }.padding(12)
    }

    // MARK: wiring
    private var wiring: some View {
        let rows = max(cfg.channels, 1)
        let height = max(CGFloat(rows) * rowH + top + 10, CGFloat(cfg.sources.count) * (cardH + 10) + top + 10)
        return ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                for w in cfg.wires {
                    guard let si = cfg.sources.firstIndex(where: { $0.id == w.sourceID }) else { continue }
                    let a = srcPort(si, w.srcChannel), b = CGPoint(x: canvasW - chanW, y: rowY(w.destChannel))
                    var p = Path(); p.move(to: a)
                    p.addCurve(to: b, control1: CGPoint(x: a.x + 70, y: a.y), control2: CGPoint(x: b.x - 70, y: b.y))
                    ctx.stroke(p, with: .color(w.srcChannel == 0 ? Theme.gold : Theme.purple), lineWidth: 3)
                }
                if dragFrom != nil, let si = cfg.sources.firstIndex(where: { $0.id == dragFrom }) {
                    let a = srcPort(si, dragSrcCh)
                    var p = Path(); p.move(to: a)
                    p.addCurve(to: dragPoint, control1: CGPoint(x: a.x + 70, y: a.y), control2: CGPoint(x: dragPoint.x - 70, y: dragPoint.y))
                    ctx.stroke(p, with: .color(Theme.text.opacity(0.6)), style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                }
            }
            .frame(width: canvasW, height: height)

            // Column headers
            HStack {
                Text("SOURCES").font(.system(size: 10, weight: .heavy)).foregroundColor(Theme.dim)
                Menu {
                    Section("Applications") {
                        ForEach(appChoices, id: \.id) { a in Button(a.name) { add(.app, a.id, a.name) } }
                    }
                    Section("Audio devices") {
                        ForEach(app.devices.filter { $0.inputChannels > 0 && !$0.isVirtualLoopNest }) { d in Button(d.name) { add(.device, d.uid, d.name) } }
                    }
                } label: { Label("Add", systemImage: "plus.circle.fill") }
                    .menuStyle(.borderlessButton).fixedSize()
            }.frame(width: cardW, alignment: .leading)
            HStack {
                Text("OUTPUT CHANNELS").font(.system(size: 10, weight: .heavy)).foregroundColor(Theme.dim)
                Spacer()
                Button { if cfg.channels > 2 { removeChannels(2) } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                Button { if cfg.channels < 64 { cfg.channels += 2 } } label: { Image(systemName: "plus.circle.fill") }.buttonStyle(.plain)
            }.frame(width: chanW).offset(x: canvasW - chanW)

            ForEach(Array(cfg.sources.enumerated()), id: \.element.id) { i, src in
                sourceCard(i, src).offset(x: 0, y: top + CGFloat(i) * (cardH + 10))
            }
            if cfg.sources.isEmpty {
                Text("Click Add to put apps or audio devices in the Sources column. Then drag from a source's L / R dot onto an output channel.")
                    .font(.caption).foregroundColor(Theme.dim).frame(width: cardW).offset(x: 0, y: top + 10)
            }
            VStack(spacing: 0) {
                ForEach(0..<cfg.channels, id: \.self) { c in
                    HStack(spacing: 6) {
                        Circle().fill(cfg.wires.contains { $0.destChannel == c } ? Theme.green : Theme.dim).frame(width: 8, height: 8)
                        Text("Channel \(c + 1)").font(.system(size: 11))
                        Spacer()
                        ChannelLevel(router: app.router(for: cfg.id), channel: c)
                    }
                    .padding(.horizontal, 8).frame(width: chanW, height: rowH)
                    .background(c % 2 == 0 ? Theme.strip : Theme.panel)
                    .contextMenu { Button("Remove wires to this channel") { cfg.wires.removeAll { $0.destChannel == c } } }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .offset(x: canvasW - chanW, y: top)
        }
        .frame(width: canvasW, height: height)
        .coordinateSpace(name: "canvas")
    }

    private var appChoices: [(id: String, name: String)] {
        let groups = Dictionary(grouping: CA.processes(), by: { $0.groupID })
        return groups.map { gid, m in (gid, m.first(where: { $0.groupID == $0.bundleID })?.name ?? m[0].name) }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    private func rowY(_ c: Int) -> CGFloat { top + CGFloat(c) * rowH + rowH / 2 }
    private func srcPort(_ i: Int, _ ch: Int) -> CGPoint {
        CGPoint(x: cardW + 14, y: top + CGFloat(i) * (cardH + 10) + 24 + CGFloat(ch) * 30)
    }

    private func removeChannels(_ n: Int) {
        cfg.channels -= n
        cfg.wires.removeAll { $0.destChannel >= cfg.channels }
    }

    private func sourceCard(_ i: Int, _ src: RouteSource) -> some View {
        let router = app.router(for: cfg.id)
        return HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Image(systemName: src.kind == .app ? "app.fill" : "mic.fill").foregroundColor(Theme.purple)
                    Text(src.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Spacer()
                    Circle().fill((router?.isSourceLive(src.id) ?? false) ? Theme.green : Theme.red).frame(width: 7, height: 7)
                        .help((router?.isSourceLive(src.id) ?? false) ? "Capturing" : "Not running or not available")
                }
                HStack(spacing: 6) {
                    Toggle("", isOn: $cfg.sources[i].enabled).toggleStyle(.switch).labelsHidden().controlSize(.mini)
                    Button { cfg.sources[i].mute.toggle() } label: {
                        Image(systemName: src.mute ? "speaker.slash.fill" : "speaker.wave.1.fill").foregroundColor(src.mute ? Theme.orange : Theme.text)
                    }.buttonStyle(.plain)
                    Slider(value: $cfg.sources[i].volumeDB, in: -40...6)
                    Button { remove(src) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain)
                }
            }
            .padding(8).frame(width: cardW - 24, height: cardH)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.strip).opacity(src.enabled ? 1 : 0.5))
            VStack(spacing: 14) {
                ForEach(0..<2, id: \.self) { ch in
                    ZStack {
                        Circle().fill(ch == 0 ? Theme.gold : Theme.purple).frame(width: 18, height: 18)
                        Text(ch == 0 ? "L" : "R").font(.system(size: 9, weight: .heavy)).foregroundColor(.black)
                    }
                    .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("canvas"))
                        .onChanged { g in dragFrom = src.id; dragSrcCh = ch; dragPoint = g.location }
                        .onEnded { g in finishDrag(src.id, ch, at: g.location) })
                }
            }.frame(width: 24)
        }
    }

    private func finishDrag(_ sid: UUID, _ ch: Int, at p: CGPoint) {
        defer { dragFrom = nil }
        guard p.x > canvasW - chanW - 30 else { return }
        let dest = Int((p.y - top) / rowH)
        guard dest >= 0, dest < cfg.channels else { return }
        if let existing = cfg.wires.firstIndex(where: { $0.sourceID == sid && $0.srcChannel == ch && $0.destChannel == dest }) {
            cfg.wires.remove(at: existing)       // dropping on an existing wire removes it
        } else {
            cfg.wires.append(Wire(sourceID: sid, srcChannel: ch, destChannel: dest))
        }
    }

    private func remove(_ s: RouteSource) {
        cfg.wires.removeAll { $0.sourceID == s.id }
        cfg.sources.removeAll { $0.id == s.id }
    }

    private func add(_ kind: SourceKind, _ ref: String, _ name: String) {
        guard !cfg.sources.contains(where: { $0.ref == ref }) else { return }
        let s = RouteSource(kind: kind, ref: ref, name: name)
        cfg.sources.append(s)
        let idx = cfg.sources.count - 1       // default mapping: next free channel pair
        let base = (idx * 2) % max(2, cfg.channels)
        cfg.wires.append(Wire(sourceID: s.id, srcChannel: 0, destChannel: base))
        cfg.wires.append(Wire(sourceID: s.id, srcChannel: 1, destChannel: min(base + 1, cfg.channels - 1)))
    }

    // MARK: monitors + volume
    private var bottomBar: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("MONITORS").font(.system(size: 10, weight: .heavy)).foregroundColor(Theme.dim)
                HStack {
                    Toggle("Hear this device on", isOn: $cfg.monitorOn).fixedSize()
                    Picker("", selection: Binding(get: { cfg.monitorUID ?? "" }, set: { cfg.monitorUID = $0.isEmpty ? nil : $0 })) {
                        Text("Choose output").tag("")
                        ForEach(app.devices.filter { $0.outputChannels > 0 && !$0.isVirtualLoopNest }) { Text($0.name).tag($0.uid) }
                    }.labelsHidden().frame(width: 190).disabled(!cfg.monitorOn)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("DEVICE VOLUME").font(.system(size: 10, weight: .heavy)).foregroundColor(Theme.dim)
                HStack { Slider(value: $cfg.volumeDB, in: -40...6).frame(width: 160); Text(dbText(cfg.volumeDB) + " dB").font(.caption.monospaced()) }
            }
            Toggle("Silence source apps on speakers", isOn: $cfg.muteOriginalApps).fixedSize()
                .help("Apps feeding this device are no longer heard on your normal output unless you monitor them.")
            Spacer()
        }.padding(12).background(Theme.panel)
    }
}

struct ChannelLevel: View {
    let router: DeviceRouter?
    let channel: Int
    var body: some View {
        LiveTimeline(1.0 / 12.0) {
            let a = router?.levels[channel] ?? 0
            let f = a > 0.00001 ? CGFloat(max(0, min(1, (20 * log10(a) + 60) / 60))) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.well)
                Capsule().fill(f > 0.85 ? Theme.orange : Theme.green).frame(width: 40 * f)
            }.frame(width: 40, height: 5)
        }
    }
}
