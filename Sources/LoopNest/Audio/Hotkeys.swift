import Foundation
import AppKit
import Carbon.HIToolbox

struct HotkeyBinding: Codable, Hashable {
    var keyCode: UInt32
    var mods: UInt32          // Carbon modifier mask
    var label: String
    var display: String {
        var s = ""
        if mods & UInt32(controlKey) != 0 { s += "⌃" }
        if mods & UInt32(optionKey) != 0 { s += "⌥" }
        if mods & UInt32(shiftKey) != 0 { s += "⇧" }
        if mods & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + label
    }
    static func from(_ e: NSEvent) -> HotkeyBinding {
        var m: UInt32 = 0
        let f = e.modifierFlags
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        if f.contains(.command) { m |= UInt32(cmdKey) }
        let names: [UInt16: String] = [49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 123: "←", 124: "→", 125: "↓", 126: "↑",
                                       122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"]
        let label = names[e.keyCode] ?? (e.charactersIgnoringModifiers ?? "?").uppercased()
        return HotkeyBinding(keyCode: UInt32(e.keyCode), mods: m, label: label)
    }
}

/// System-wide shortcuts (work while OBS or a game has focus). Uses Carbon hot keys, which need no extra permission.
final class HotkeyCenter {
    static let shared = HotkeyCenter()
    var onEvent: ((String, Bool) -> Void)?
    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: String] = [:]
    private var installed = false
    private var nextID: UInt32 = 1

    private func install() {
        guard !installed else { return }
        installed = true
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            HotkeyCenter.shared.dispatch(hk.id, pressed)
            return noErr
        }, 2, &specs, nil, nil)
    }

    private func dispatch(_ id: UInt32, _ pressed: Bool) {
        guard let a = actions[id] else { return }
        DispatchQueue.main.async { self.onEvent?(a, pressed) }
    }

    var disabled = false
    func set(_ map: [String: HotkeyBinding]) {
        install()
        if disabled { for r in refs { UnregisterEventHotKey(r) }; refs.removeAll(); actions.removeAll(); return }
        for r in refs { UnregisterEventHotKey(r) }
        refs.removeAll(); actions.removeAll()
        for (action, b) in map {
            var ref: EventHotKeyRef?
            let id = nextID; nextID += 1
            let st = RegisterEventHotKey(b.keyCode, b.mods, EventHotKeyID(signature: OSType(0x4C4E5354), id: id),
                                         GetApplicationEventTarget(), 0, &ref)
            if st == noErr, let ref { refs.append(ref); actions[id] = action }
        }
    }
}
