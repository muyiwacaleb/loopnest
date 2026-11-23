import SwiftUI

struct OBSCard: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var obs: OBSLink
    @LState private var showSetup = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("OBS LINK").font(.system(size: 10, weight: .heavy)).foregroundColor(Theme.dim)
                Spacer()
                pill("LIVE", obs.streaming, Theme.red)
                pill("RECORDING", obs.recording, Theme.orange)
                if obs.connected { Button("Disconnect") { obs.disconnect() }.controlSize(.small) }
                else { Button("Connect") { obs.connect() }.controlSize(.small).buttonStyle(.borderedProminent) }
            }
            Text(obs.state).font(.caption).foregroundColor(obs.connected ? Theme.green : Theme.dim)

            if obs.connected {
                Text("Scene → mix preset. When you switch scene in OBS, LoopNest switches to the preset you pick.")
                    .font(.caption2).foregroundColor(Theme.dim)
                ForEach(obs.scenes, id: \.self) { scene in
                    HStack {
                        Button { obs.switchScene(scene) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: obs.currentScene == scene ? "record.circle.fill" : "circle")
                                Text(scene).lineLimit(1)
                            }
                        }.buttonStyle(.plain).foregroundColor(obs.currentScene == scene ? Theme.green : Theme.text)
                        Spacer()
                        Picker("", selection: Binding(get: { app.presetLinks[scene] ?? "" },
                                                      set: { app.presetLinks[scene] = $0 })) {
                            Text("No change").tag("")
                            ForEach(AppState.usePresets, id: \.self) { Text($0).tag($0) }
                        }.labelsHidden().frame(width: 140)
                    }.font(.caption)
                }
            } else {
                DisclosureGroup("First-time setup in OBS", isExpanded: $showSetup) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("1. In OBS: Tools → WebSocket Server Settings.")
                        Text("2. Tick “Enable WebSocket server”. Port 4455 is the default.")
                        Text("3. If you set a password, type it below, then press Connect.")
                    }.font(.caption2).foregroundColor(Theme.dim)
                }.font(.caption)
                HStack {
                    TextField("Host", text: $obs.config.host).frame(width: 120)
                    TextField("Port", value: $obs.config.port, format: .number.grouping(.never)).frame(width: 60)
                    SecureField("Password (if any)", text: $obs.config.password)
                }.textFieldStyle(.roundedBorder).font(.caption)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
    }

    private func pill(_ t: String, _ on: Bool, _ c: Color) -> some View {
        Text(t).font(.system(size: 9, weight: .heavy))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(on ? c : Color.gray.opacity(0.25)))
            .foregroundColor(on ? .white : Theme.dim)
    }
}
