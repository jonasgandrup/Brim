import AppKit
import Carbon

/// Modifier combinations offered for the island tool shortcuts.
enum ShortcutModifiers: String, CaseIterable, Identifiable {
    case ctrlOptCmd, ctrlOpt, ctrlCmd, optCmd
    var id: String { rawValue }
    var label: String { switch self { case .ctrlOptCmd: "⌃⌥⌘"; case .ctrlOpt: "⌃⌥"; case .ctrlCmd: "⌃⌘"; case .optCmd: "⌥⌘" } }
    var carbon: UInt32 {
        switch self {
        case .ctrlOptCmd: UInt32(controlKey | optionKey | cmdKey)
        case .ctrlOpt: UInt32(controlKey | optionKey)
        case .ctrlCmd: UInt32(controlKey | cmdKey)
        case .optCmd: UInt32(optionKey | cmdKey)
        }
    }
    var menuMask: NSEvent.ModifierFlags {
        switch self {
        case .ctrlOptCmd: [.control, .option, .command]
        case .ctrlOpt: [.control, .option]
        case .ctrlCmd: [.control, .command]
        case .optCmd: [.option, .command]
        }
    }
}

/// Registered with macOS, so these do not require an Accessibility event tap.
@MainActor @Observable final class ToolShortcuts {
    enum Tool: UInt32, CaseIterable {
        case nowPlaying = 1, files, clipboard, clock, battery, transfers
        var title: String {
            switch self { case .nowPlaying: "Now Playing"; case .files: "Files"; case .clipboard: "Clipboard"; case .clock: "Clock"; case .battery: "Battery"; case .transfers: "Transfers" }
        }
        var keyCode: UInt32 {
            switch self { case .nowPlaying: UInt32(kVK_ANSI_1); case .files: UInt32(kVK_ANSI_2)
            case .clipboard: UInt32(kVK_ANSI_3); case .clock: UInt32(kVK_ANSI_4); case .battery: UInt32(kVK_ANSI_5); case .transfers: UInt32(kVK_ANSI_6) }
        }
    }
    private(set) var unavailable: [String] = []
    private var handler: EventHandlerRef?
    private var registered: [Tool: EventHotKeyRef] = [:]
    @ObservationIgnored private var open: (Tool) -> Void = { _ in }
    static let signature: OSType = 0x53656E73
    private var modifiers = ShortcutModifiers.ctrlOptCmd
    func configure(enabled: Bool, modifiers next: ShortcutModifiers = .ctrlOptCmd, onOpen: @escaping (Tool) -> Void) {
        if next != modifiers { stop(); modifiers = next }
        open = onOpen
        guard enabled else { stop(); return }
        if handler != nil { registerMissing(); return }
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                id.signature == ToolShortcuts.signature else { return OSStatus(eventNotHandledErr) }
            return MainActor.assumeIsolated {
                let owner = Unmanaged<ToolShortcuts>.fromOpaque(context).takeUnretainedValue()
                guard let tool = Tool(rawValue: id.id) else { return OSStatus(eventNotHandledErr) }
                owner.open(tool); return noErr
            }
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard result == noErr else { unavailable = Tool.allCases.map(\.title); return }
        registerMissing()
    }
    /// Registers any shortcut that isn't held yet, so one that another app released is picked up later.
    private func registerMissing() {
        unavailable = []
        for tool in Tool.allCases {
            if registered[tool] != nil { continue }
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(tool.keyCode, modifiers.carbon,
                EventHotKeyID(signature: Self.signature, id: tool.rawValue), GetApplicationEventTarget(), 0, &reference)
            if status == noErr, let reference { registered[tool] = reference }
            else { unavailable.append(tool.title) }
        }
    }
    func stop() {
        registered.values.forEach { UnregisterEventHotKey($0) }; registered.removeAll()
        if let handler { RemoveEventHandler(handler) }; handler = nil; unavailable = []; open = { _ in }
    }
    /// Exercises the installed Carbon handler without injecting keys into another app.
    func checkDelivery() -> [String: Bool] {
        let savedOpen = open
        var received: [Tool] = []
        open = { received.append($0) }
        defer { open = savedOpen }
        var results: [String: Bool] = [:]
        for tool in Tool.allCases {
            var event: EventRef?
            var id = EventHotKeyID(signature: Self.signature, id: tool.rawValue)
            if CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0,
                           EventAttributes(kEventAttributeUserEvent), &event) == noErr, let event {
                SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  MemoryLayout<EventHotKeyID>.size, &id)
                SendEventToEventTarget(event, GetApplicationEventTarget())
                ReleaseEvent(event)
            }
            results[tool.title] = received.last == tool && !unavailable.contains(tool.title) && handler != nil
        }
        return results
    }
}
