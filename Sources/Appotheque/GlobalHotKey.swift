import AppKit
import Carbon

enum LauncherShortcut: String, CaseIterable, Identifiable {
    case space, d, l, disabled
    var id: String { rawValue }
    var label: String {
        switch self {
        case .space: return String(localized: "⌃⌥Space")
        case .d: return "⌃⌥D"
        case .l: return "⌃⌥L"
        case .disabled: return String(localized: "Off")
        }
    }
    var key: UInt32 {
        switch self {
        case .space, .disabled: return UInt32(kVK_Space)
        case .d: return UInt32(kVK_ANSI_D)
        case .l: return UInt32(kVK_ANSI_L)
        }
    }
}

@MainActor
final class GlobalHotKey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    func register(_ shortcut: LauncherShortcut) -> String? {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        if let handler { RemoveEventHandler(handler); self.handler = nil }
        guard shortcut != .disabled else { return nil }
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
                  identifier.signature == 0x44564150, identifier.id == 1 else { return OSStatus(eventNotHandledErr) }
            Task { @MainActor in AppWindows.showLauncher(LauncherModel.shared, resetSearch: true) }
            return noErr
        }, 1, &event, nil, &handler)
        guard installed == noErr else { return String(localized: "The shortcut could not be turned on (\(installed)).") }
        let result = RegisterEventHotKey(shortcut.key, UInt32(controlKey | optionKey),
                                        EventHotKeyID(signature: 0x44564150, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        guard result == noErr else {
            return String(localized: "\(shortcut.label) is unavailable or used by another app. Choose another shortcut.")
        }
        return nil
    }
}
