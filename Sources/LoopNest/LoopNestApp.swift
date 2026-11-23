import SwiftUI

@main
struct LoopNestApp: App {
    @StateObject private var app = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    init() {
        // Test.command runs the app with --selftest: run the checks first, before any audio or window is created.
        if CommandLine.arguments.contains("--selftest") { fflush(stdout); exit(SelfTest.run()) }
    }

    var body: some Scene {
        Window("LoopNest", id: "main") {
            RootView()
                .environmentObject(app)
                .frame(minWidth: 1180, minHeight: 640)
                .preferredColorScheme(.dark)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in app.shutdown() }
        }
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra("LoopNest", systemImage: "slider.vertical.3") {
            MenuBarView().environmentObject(app)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environmentObject(app)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--selftest") { exit(SelfTest.run()) }     // used by Test.command
        // Only one LoopNest at a time.
        if let id = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: id).filter { $0 != NSRunningApplication.current }
            if let o = others.first { o.activate(options: []); exit(0) }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    /// Clicking the Dock icon / re-opening the app brings the closed mixer window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for w in NSApp.windows where w.title == "LoopNest" { w.makeKeyAndOrderFront(nil) }
        }
        return true
    }
}

struct LogoMark: View {
    var size: CGFloat = 26
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24).fill(LinearGradient(colors: [Color(red: 0.42, green: 0.25, blue: 0.95), Color(red: 0.12, green: 0.08, blue: 0.35)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Circle().trim(from: 0.08, to: 0.92).stroke(Theme.gold, style: StrokeStyle(lineWidth: size * 0.09, lineCap: .round))
                .frame(width: size * 0.66, height: size * 0.66).rotationEffect(.degrees(-90))
            HStack(spacing: size * 0.06) {
                ForEach([0.16, 0.3, 0.22], id: \.self) { h in
                    Capsule().fill(Color.white).frame(width: size * 0.07, height: size * h)
                }
            }
        }.frame(width: size, height: size)
    }
}

struct RootView: View {
    @EnvironmentObject var app: AppState
    @LState private var sceneName = ""
    @LState private var askScene = false

    private let pages: [(ViewMode, String, String)] = [
        (.console, "slider.vertical.3", "Console"), (.classic, "list.bullet", "Classic"),
        (.routing, "point.3.connected.trianglepath.dotted", "Routing"), (.stream, "dot.radiowaves.left.and.right", "Stream"), (.board, "square.grid.3x3.fill", "Soundboard"), (.fx, "wand.and.stars", "FX"),
        (.decks, "opticaldisc", "Decks"), (.record, "record.circle", "Record"), (.health, "waveform.path.ecg", "Health")]

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(Color.black)
            VStack(spacing: 0) {
                toolbar
                Divider().overlay(Color.black)
                SafeModeBanner()
                CrashBanner()
                Group {
                    switch app.viewMode {
                    case .console, .classic: MixerView()
                    case .routing: RoutingView()
                    case .stream: StreamView()
                    case .board: SoundboardView()
                    case .fx: FXView()
                    case .decks: DecksView()
                    case .record: RecordView()
                    case .health: HealthView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.bg)
        .background(shortcuts)
        .alert("Save scene", isPresented: $askScene) {
            TextField("Name", text: $sceneName)
            Button("Save") { if !sceneName.isEmpty { app.saveScene(named: sceneName) }; sceneName = "" }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func go(_ m: ViewMode) { app.viewMode = m; app.saveViewMode() }

    private var sidebar: some View {
        VStack(spacing: 6) {
            LogoMark(size: 38).padding(.top, 14).padding(.bottom, 8)
            ForEach(Array(pages.enumerated()), id: \.offset) { i, p in
                let sel = app.viewMode == p.0
                Button { go(p.0) } label: {
                    VStack(spacing: 3) {
                        Image(systemName: p.1).font(.system(size: 18))
                        Text(p.2).font(.system(size: 10, weight: .semibold))
                    }
                    .frame(width: 70, height: 52)
                    .foregroundColor(sel ? .white : Theme.dim)
                    .background(RoundedRectangle(cornerRadius: 10).fill(sel ? Theme.purple : Color.clear))
                    .contentShape(Rectangle())
                }.buttonStyle(.plain).help("\(p.2)  (\u{2318}\(i + 1))")
            }
            Spacer()
            SettingsLink {
                VStack(spacing: 3) {
                    Image(systemName: "gearshape").font(.system(size: 18))
                    Text("Settings").font(.system(size: 10, weight: .semibold))
                }.frame(width: 70, height: 52).foregroundColor(Theme.dim).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
        .frame(width: 84).padding(.bottom, 10)
        .background(Theme.panel)
    }

    /// Cmd-1 ... Cmd-8 jump between pages.
    private var shortcuts: some View {
        ZStack {
            ForEach(Array(pages.enumerated()), id: \.offset) { i, p in
                Button("") { go(p.0) }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command).opacity(0)
            }
        }.frame(width: 0, height: 0)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text(app.viewMode.rawValue).font(.system(size: 15, weight: .heavy, design: .rounded))
            if app.viewMode == .console || app.viewMode == .classic {
                Picker("", selection: Binding(get: { app.viewMode }, set: { go($0) })) {
                    Text("Console").tag(ViewMode.console); Text("Classic").tag(ViewMode.classic)
                }.pickerStyle(.segmented).frame(width: 160).labelsHidden()
            }
            Spacer()
            statusBadge
            Spacer()
            Menu("Setups") {
                ForEach(AppState.usePresets, id: \.self) { n in Button(n) { app.applyUsePreset(n) } }
            }.frame(width: 80).help("One-click setups: Podcast, Gaming, Music stream, Call")
            Menu("Scenes") {
                Button("Save current setup…") { askScene = true }
                Divider()
                ForEach(app.scenes) { s in Button(s.name) { app.recall(s) } }
            }.frame(width: 80)
            HStack(spacing: 2) {
                ForEach(0..<2, id: \.self) { i in
                    Button(i == 0 ? "A" : "B") { if NSEvent.modifierFlags.contains(.option) || !app.abStored[i] { app.storeAB(i) } else { app.recallAB(i) } }
                        .help(app.abStored[i] ? "Recall \(i == 0 ? "A" : "B"). Option-click stores the current mix here instead." : "Store the current mix as \(i == 0 ? "A" : "B")")
                        .tint(app.abCurrent == i ? Theme.purple : nil)
                }
            }.controlSize(.small)
            Button { app.undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(!app.canUndo).help("Undo scene recall")
            Divider().frame(height: 18)
            Toggle("Mic", isOn: $app.includeMic).toggleStyle(.checkbox).help("Also record the microphone to its own file")
            Button {
                if app.recorder.isRecording { app.recorder.stop() }
                else { app.recorder.start(engine: app.engine, strips: app.allStrips, includeMic: app.includeMic) }
            } label: {
                HStack(spacing: 5) {
                    Circle().fill(app.recorder.isRecording ? Theme.red : Theme.dim).frame(width: 10, height: 10)
                    Text(app.recorder.isRecording ? timeString(app.recorder.elapsed) : "REC").font(.system(size: 11, weight: .bold, design: .monospaced))
                }
            }
            Button { app.setBypass(!app.bypass) } label: {
                Text(app.bypass ? "LoopNest OFF" : "LoopNest ON").font(.system(size: 10, weight: .bold))
            }.tint(app.bypass ? Theme.orange : Theme.green)
             .help("ON: sound goes through LoopNest. OFF: LoopNest steps aside completely and everything goes straight to your speakers or headset, as if LoopNest were not installed.")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Theme.panel)
    }

    private var statusBadge: some View {
        let (text, color, fix): (String, Color, Bool) = {
            if app.bypass { return ("LOOPNEST OFF · NOTHING SENT TO OBS OR ZOOM", Theme.orange, false) }
            switch app.captureStatus {
            case .waiting: return ("LIVE · WAITING FOR AUDIO", Theme.gold, false)
            case .live(let n): return ("LIVE · \(n) APP\(n == 1 ? "" : "S")", Theme.green, false)
            case .silent: return ("NO SIGNAL · CHECK PERMISSION", Theme.gold, true)
            case .failed(let c): return ("CAPTURE BLOCKED (\(c)) · CHECK PERMISSION", Theme.red, true)
            case .bypassed: return ("BYPASSED", Theme.dim, false)
            }
        }()
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(color)
            if fix { Button("Fix") { app.openAudioPrivacySettings() }.controlSize(.mini) }
        }
    }

    private func timeString(_ t: TimeInterval) -> String { String(format: "%02d:%02d", Int(t) / 60, Int(t) % 60) }
}
