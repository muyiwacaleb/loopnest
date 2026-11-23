import SwiftUI

/// Choose an Audio Unit effect to insert, open its window, or bypass it. Nothing is inserted until you choose one.
struct PluginInsert: View {
    @EnvironmentObject var app: AppState
    let title: String
    @Binding var id: String?
    @Binding var bypass: Bool
    let slot: PluginSlot
    @LState private var list: [PluginInfo] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Plug-in (Audio Unit)").font(.subheadline)
                Spacer()
                Picker("", selection: Binding(get: { id ?? "" }, set: { id = $0.isEmpty ? nil : $0 })) {
                    Text("None").tag("")
                    if let cur = id, !list.contains(where: { $0.id == cur }) { Text(cur + " (not installed)").tag(cur) }
                    ForEach(list) { Text("\($0.manufacturer): \($0.name)").tag($0.id) }
                }.labelsHidden().frame(width: 220)
            }
            if id != nil {
                HStack {
                    Button("Open window") { app.engine.openPluginWindow(slot, title: title) { app.capturePluginStates() } }.controlSize(.small)
                    Toggle("Bypass", isOn: $bypass).fixedSize()
                    Spacer()
                    Button("Remove") { id = nil; bypass = false }.controlSize(.small)
                }
            }
            Text("Runs outside LoopNest, so a faulty plug-in cannot take the app down. Only stereo effects can be inserted. Nothing is inserted until you choose one.")
                .font(.caption2).foregroundColor(Theme.dim)
        }
        .onAppear { if list.isEmpty { list = PluginCatalog.effects() } }
    }
}
