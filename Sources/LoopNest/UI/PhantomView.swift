import SwiftUI

/// Small "48V" badge for a hardware input. It is a reminder only: LoopNest never switches phantom power.
struct PhantomBadge: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var strip: Strip
    @LState private var show = false

    var body: some View {
        let info = app.phantomInfo(strip)
        let key = app.phantomKey(strip) ?? ""
        let confirmed = app.phantomConfirmed.contains(key)
        let bad = info.expected && info.micType == 3          // ribbon + 48V
        let color: Color = bad ? Theme.red : (info.expected ? (confirmed ? Theme.green : Theme.gold) : Theme.dim)
        let text = info.expected ? (confirmed ? "+48V ✓" : "+48V ?") : "48V"
        Button { show.toggle() } label: {
            Text(text).font(.system(size: 9, weight: .heavy))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Capsule().fill(info.expected ? color.opacity(0.9) : Color.gray.opacity(0.25)))
                .foregroundColor(info.expected ? .black : Theme.dim)
        }
        .buttonStyle(.plain)
        .help(bad ? "Ribbon microphones can be damaged by phantom power. Click for details."
              : info.expected ? (confirmed ? "You confirmed +48V is on for this input." : "This input needs +48V. Click to check it.")
              : "Does this microphone need phantom power? Click to set a reminder.")
        .popover(isPresented: $show) { PhantomPopover(strip: strip).environmentObject(app) }
    }
}

struct PhantomPopover: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var strip: Strip

    var body: some View {
        let info = app.phantomInfo(strip)
        let key = app.phantomKey(strip) ?? ""
        let confirmed = app.phantomConfirmed.contains(key)
        VStack(alignment: .leading, spacing: 10) {
            Text("Phantom power (+48V) reminder").font(.headline)
            Text(strip.name).font(.caption).foregroundColor(.secondary)
            Text("LoopNest can't see or switch phantom power. macOS only exposes it for a few interfaces, so this is a note you keep for yourself. The real switch is on your interface (a front-panel button, or an app like Focusrite Control).")
                .font(.caption).fixedSize(horizontal: false, vertical: true)

            Picker("Microphone type", selection: Binding(get: { info.micType }, set: { t in
                app.setPhantom(strip) { $0.micType = t; if t == 1 { $0.expected = true } else if t == 2 { $0.expected = false } }
            })) { ForEach(0..<PhantomInfo.typeNames.count, id: \.self) { Text(PhantomInfo.typeNames[$0]).tag($0) } }
            Toggle("This input needs +48V", isOn: Binding(get: { info.expected }, set: { v in app.setPhantom(strip) { $0.expected = v } }))

            if info.expected && info.micType == 3 {
                warn("Ribbon microphones can be damaged by phantom power. Check the manual before switching +48V on.")
            } else if info.expected && info.micType == 2 {
                warn("Dynamic microphones don't need +48V. Leave it off unless the manual says otherwise.")
            }

            if info.expected {
                Divider()
                Text("Switch-on checklist").font(.subheadline.bold())
                VStack(alignment: .leading, spacing: 3) {
                    Text("1. Turn the input gain down (or mute this channel below).")
                    Text("2. Connect the microphone with the +48V button off.")
                    Text("3. Press +48V on the interface (hardware button or its control app).")
                    Text("4. Raise the gain slowly. Don't unplug the mic while +48V is on.")
                }.font(.caption)
                HStack {
                    Toggle("Mute this channel while I switch it", isOn: Binding(get: { strip.s.mute }, set: { _ in app.toggleMute(strip) }))
                        .toggleStyle(.checkbox).font(.caption)
                }
                HStack {
                    Button(confirmed ? "Marked as on" : "I switched +48V on") { app.phantomConfirm(strip, !confirmed) }
                        .buttonStyle(.borderedProminent).tint(confirmed ? Theme.green : Theme.gold)
                    Text(confirmed ? "Asks again after you unplug the device or relaunch." : "Not confirmed yet.")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
            TextField("Note (for example: Focusrite channel 1, button 48V)", text: Binding(get: { info.note }, set: { v in app.setPhantom(strip) { $0.note = v } }))
                .textFieldStyle(.roundedBorder).font(.caption)
            Text("Remembered for this device and input channel, even if you remove and re-add it.")
                .font(.caption2).foregroundColor(.secondary)
        }
        .padding(14).frame(width: 340)
    }

    private func warn(_ t: String) -> some View {
        Text(t).font(.caption).foregroundColor(Theme.red).fixedSize(horizontal: false, vertical: true)
    }
}

/// Top-of-window notice after an unexpected quit. It never blocks the mixer underneath.
struct CrashBanner: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        if app.crashedLastTime && !app.crashBannerDismissed {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(Theme.gold)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("LoopNest didn't close normally last time. Your settings were restored.").font(.system(size: 12, weight: .semibold))
                        if let d = app.lastAliveBeforeLaunch {
                            Text("Last seen running \(d.formatted(date: .abbreviated, time: .shortened)).").font(.caption2).foregroundColor(Theme.dim)
                        }
                    }
                    Spacer()
                    Button("Check devices") { app.recoveryCheck() }.controlSize(.small)
                    if !app.obs.connected && app.obs.config.autoConnect { Button("Reconnect OBS") { app.obs.connect(); app.recoveryCheck() }.controlSize(.small) }
                    Button("Save settings backup") { app.exportSettings() }.controlSize(.small)
                    Button { app.crashBannerDismissed = true } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Dismiss")
                }
                if !app.recoveryReport.isEmpty {
                    Text(app.recoveryReport).font(.caption).foregroundColor(Theme.text).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Theme.gold.opacity(0.14))
            .overlay(Rectangle().fill(Theme.gold.opacity(0.6)).frame(height: 1), alignment: .bottom)
        }
    }
}

struct SafeModeBanner: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        if app.safeMode {
            HStack(spacing: 10) {
                Image(systemName: "shield.lefthalf.filled").foregroundColor(Theme.orange)
                Text("SAFE MODE: effects, hotkeys, MIDI and extra outputs are off, and changes are not saved. Use this to find out what is causing trouble.")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("Leave Safe Mode") { app.relaunchApp(safe: false) }.controlSize(.small).buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Theme.orange.opacity(0.18))
        }
    }
}
