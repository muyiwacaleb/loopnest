import Foundation
import AVFoundation
import AudioToolbox
import CoreAudioKit
import AppKit

/// One installed Audio Unit effect.
struct PluginInfo: Identifiable, Hashable {
    let id: String                 // "type.subtype.manufacturer" as four-character codes
    let name: String
    let manufacturer: String
}

enum PluginCatalog {
    static func code(_ v: OSType) -> String {
        let b = [UInt8((v >> 24) & 255), UInt8((v >> 16) & 255), UInt8((v >> 8) & 255), UInt8(v & 255)]
        return String(bytes: b, encoding: .isoLatin1) ?? "????"
    }
    static func fourCC(_ s: String) -> OSType { s.unicodeScalars.reduce(0) { ($0 << 8) | (OSType($1.value) & 255) } }
    static func identifier(_ d: AudioComponentDescription) -> String { "\(code(d.componentType)).\(code(d.componentSubType)).\(code(d.componentManufacturer))" }
    static func description(for id: String) -> AudioComponentDescription? {
        let p = id.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard p.count == 3, p.allSatisfy({ $0.count == 4 }) else { return nil }
        return AudioComponentDescription(componentType: fourCC(p[0]), componentSubType: fourCC(p[1]), componentManufacturer: fourCC(p[2]), componentFlags: 0, componentFlagsMask: 0)
    }
    /// Effects the user can insert. Apple's own are included (they are the ones that exist on every Mac).
    static func effects() -> [PluginInfo] {
        let want = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: 0, componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0)
        return AVAudioUnitComponentManager.shared().components(matching: want)
            .map { PluginInfo(id: identifier($0.audioComponentDescription), name: $0.name, manufacturer: $0.manufacturerName) }
            .sorted { ($0.manufacturer.lowercased(), $0.name.lowercased()) < ($1.manufacturer.lowercased(), $1.name.lowercased()) }
    }
    static func name(for id: String) -> String { effects().first { $0.id == id }?.name ?? id }
}

/// One insert slot (a channel's or the master's): which plug-in is loaded and its window.
final class PluginSlot {
    var unit: AVAudioUnit?
    var loadedID: String?
    var busy = false
    var window: NSWindow?
    var failedID: String?          // an id that could not be loaded: not retried until it changes
}

extension MixerEngine {
    private static let loadingKey = "pluginLoadingID"
    private static let blockedKey = "pluginBlockedIDs"

    /// A plug-in that was being loaded when LoopNest last quit unexpectedly is blocked, so a bad plug-in cannot crash the app on every start.
    func pluginIsBlocked(_ id: String) -> Bool { (UserDefaults.standard.stringArray(forKey: Self.blockedKey) ?? []).contains(id) }
    func pluginGuardOnLaunch() {
        let ud = UserDefaults.standard
        if let id = ud.string(forKey: Self.loadingKey) {
            var b = ud.stringArray(forKey: Self.blockedKey) ?? []
            if !b.contains(id) { b.append(id) }
            ud.set(b, forKey: Self.blockedKey); ud.removeObject(forKey: Self.loadingKey)
            onEvent?("The plug-in \(PluginCatalog.name(for: id)) was loading when LoopNest stopped last time, so it is switched off. Unblock it in Settings if you want to try again.")
        }
    }
    func unblockPlugins() { UserDefaults.standard.removeObject(forKey: Self.blockedKey) }

    /// Makes the slot match `wanted`. `rewire` connects the given plug-in (or none) into the audio graph while the engine is paused.
    func syncPlugin(_ slot: PluginSlot, wanted: String?, state: Data?, bypass: Bool, label: String, rewire: @escaping (AVAudioUnit?) -> Void) {
        let want = (safeMode ? nil : wanted).flatMap { pluginIsBlocked($0) ? nil : $0 }
        if let u = slot.unit { u.auAudioUnit.shouldBypassEffect = bypass }
        if want == slot.loadedID || slot.busy { return }
        if let w = want, slot.failedID == w { return }
        slot.busy = true
        guard let id = want, let desc = PluginCatalog.description(for: id) else {
            replace(slot, with: nil, rewire: rewire); slot.loadedID = nil; slot.busy = false; return
        }
        UserDefaults.standard.set(id, forKey: Self.loadingKey)
        AVAudioUnit.instantiate(with: desc, options: [.loadOutOfProcess]) { [weak self] unit, error in
            DispatchQueue.main.async {
                guard let self else { return }
                defer { UserDefaults.standard.removeObject(forKey: Self.loadingKey); slot.busy = false }
                guard let unit else {
                    slot.failedID = id
                    self.onEvent?("\(label): the plug-in could not be loaded (\(error?.localizedDescription ?? "unknown reason")).")
                    return
                }
                // only stereo-capable effects fit LoopNest's stereo channels; connecting anything else would crash the audio engine
                let caps = unit.auAudioUnit.channelCapabilities ?? []
                var ok = caps.isEmpty
                var i = 0
                while i + 1 < caps.count { let a = caps[i].intValue, b = caps[i + 1].intValue; if (a == 2 || a < 0) && (b == 2 || b < 0) { ok = true }; i += 2 }
                guard ok else {
                    slot.failedID = id
                    self.onEvent?("\(label): \(PluginCatalog.name(for: id)) does not work with stereo, so it was not inserted.")
                    return
                }
                if let state, let obj = try? PropertyListSerialization.propertyList(from: state, options: [], format: nil) as? [String: Any] {
                    unit.auAudioUnit.fullState = obj
                }
                unit.auAudioUnit.shouldBypassEffect = bypass
                self.replace(slot, with: unit, rewire: rewire)
                slot.loadedID = id; slot.failedID = nil
                self.onEvent?("\(label): \(PluginCatalog.name(for: id)) is inserted.")
            }
        }
    }

    /// Swaps the loaded plug-in. The engine is paused around the change, because changing the graph while it runs crashed AVAudioEngine.
    private func replace(_ slot: PluginSlot, with unit: AVAudioUnit?, rewire: (AVAudioUnit?) -> Void) {
        let wasRunning = running && !standingAside
        if wasRunning { engine.pause() }
        slot.window?.close(); slot.window = nil
        let old = slot.unit
        if let unit { engine.attach(unit) }
        rewire(unit)
        if let old { engine.detach(old) }
        slot.unit = unit
        if wasRunning { try? engine.start() }
    }

    /// The plug-in's saved settings, to store with the channel or master.
    func pluginState(_ slot: PluginSlot) -> Data? {
        guard let full = slot.unit?.auAudioUnit.fullState else { return nil }
        return try? PropertyListSerialization.data(fromPropertyList: full, format: .binary, options: 0)
    }

    func openPluginWindow(_ slot: PluginSlot, title: String, onClose: @escaping () -> Void) {
        if let w = slot.window { w.makeKeyAndOrderFront(nil); return }
        guard let unit = slot.unit else { return }
        unit.auAudioUnit.requestViewController { [weak slot] vc in
            DispatchQueue.main.async {
                guard let slot else { return }
                guard let vc else { self.onEvent?("This plug-in has no window of its own."); return }
                let w = NSWindow(contentViewController: vc)
                w.title = title; w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
                w.isReleasedWhenClosed = false
                NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in onClose() }
                slot.window = w
                w.center(); w.makeKeyAndOrderFront(nil)
            }
        }
    }
}
