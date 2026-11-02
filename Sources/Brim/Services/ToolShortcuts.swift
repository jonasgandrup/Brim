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
        case nowPlaying = 1, files, clipboard, clock, battery, transfers, island
        var title: String {
            switch self { case .island: String(localized: "Island"); case .nowPlaying: String(localized: "Now Playing"); case .files: String(localized: "Files"); case .clipboard: String(localized: "Clipboard"); case .clock: String(localized: "Clock"); case .battery: String(localized: "Battery"); case .transfers: String(localized: "Downloads & AirDrop") }
        }
        var keyCode: UInt32 {
            switch self { case .island: UInt32(kVK_ANSI_0); case .nowPlaying: UInt32(kVK_ANSI_1); case .files: UInt32(kVK_ANSI_2)
            case .clipboard: UInt32(kVK_ANSI_3); case .clock: UInt32(kVK_ANSI_4); case .battery: UInt32(kVK_ANSI_5); case .transfers: UInt32(kVK_ANSI_6) }
        }
    }
    private(set) var unavailable: [String] = []
    private var handler: EventHandlerRef?
    private var registered: [Tool: EventHotKeyRef] = [:]
    @ObservationIgnored private var open: (Tool) -> Void = { _ in }
    static let signature: OSType = 0x53656E73
    private var modifiers = ShortcutModifiers.ctrlOptCmd
    /// Only the shortcut that opens the island, unless the section shortcuts are asked for too.
    private var tools: [Tool] = [.island]
    func configure(enabled: Bool, sections: Bool = false, modifiers next: ShortcutModifiers = .ctrlOptCmd, onOpen: @escaping (Tool) -> Void) {
        if next != modifiers { stop(); modifiers = next }
        open = onOpen
        guard enabled else { stop(); return }
        tools = sections ? Tool.allCases : [.island]
        for tool in Tool.allCases where !tools.contains(tool) {
            if let reference = registered.removeValue(forKey: tool) { UnregisterEventHotKey(reference) }
        }
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
        guard result == noErr else { unavailable = tools.map(\.title); return }
        registerMissing()
    }
    /// Registers any shortcut that isn't held yet, so one that another app released is picked up later.
    private func registerMissing() {
        unavailable = []
        for tool in tools {
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
        for tool in tools {
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

/// Plain keys the island borrows while it's open from the keyboard. They're registered with macOS only for
/// that moment, so the island responds without activating Brim, and released the moment it closes.
@MainActor final class IslandKeys {
    enum Key: UInt32, CaseIterable {
        case left = 1, right, `return`, space, escape
        var keyCode: UInt32 {
            switch self {
            case .left: UInt32(kVK_LeftArrow); case .right: UInt32(kVK_RightArrow); case .return: UInt32(kVK_Return)
            case .space: UInt32(kVK_Space); case .escape: UInt32(kVK_Escape)
            }
        }
    }
    static let signature: OSType = 0x53654B79
    private var handler: EventHandlerRef?
    private var registered: [EventHotKeyRef] = []
    private var receive: (Key) -> Void = { _ in }
    var active: Bool { !registered.isEmpty }

    func start(onKey: @escaping (Key) -> Void) {
        receive = onKey
        guard registered.isEmpty else { return }
        if handler == nil {
            var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                    id.signature == IslandKeys.signature else { return OSStatus(eventNotHandledErr) }
                return MainActor.assumeIsolated {
                    let owner = Unmanaged<IslandKeys>.fromOpaque(context).takeUnretainedValue()
                    guard let key = Key(rawValue: id.id), owner.active else { return OSStatus(eventNotHandledErr) }
                    owner.receive(key); return noErr
                }
            }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        }
        for key in Key.allCases {
            var reference: EventHotKeyRef?
            if RegisterEventHotKey(key.keyCode, 0, EventHotKeyID(signature: Self.signature, id: key.rawValue),
                                   GetApplicationEventTarget(), 0, &reference) == noErr, let reference { registered.append(reference) }
        }
    }
    func stop() {
        registered.forEach { UnregisterEventHotKey($0) }; registered.removeAll()
        receive = { _ in }
    }
}
