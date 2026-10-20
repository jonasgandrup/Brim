import SwiftUI

@MainActor @Observable
final class Preferences {
    private let defaults: UserDefaults
    var toolShortcutsEnabled: Bool { didSet { save("toolShortcutsEnabled", toolShortcutsEnabled) } }
    var notchEnabled: Bool { didSet { save("notchEnabled", notchEnabled) } }
    var switcherEnabled: Bool { didSet { save("switcherEnabled", switcherEnabled) } }
    var scaleEnabled: Bool { didSet { save("scaleEnabled", scaleEnabled) } }
    var lidEffectEnabled: Bool { didSet { save("lidEffectEnabled", lidEffectEnabled) } }
    var toolShortcutModifiers: String { didSet { save("toolShortcutModifiers", toolShortcutModifiers) } }
    var clipboardHistory: Bool { didSet { save("clipboardHistory", clipboardHistory) } }
    var calendarPreview: Bool { didSet { save("calendarPreview", calendarPreview) } }
    var liveTransfers: Bool { didSet { save("liveTransfers", liveTransfers) } }
    var autoHideFocus: Bool { didSet { save("autoHideFocus", autoHideFocus) } }
    var autoHideSharing: Bool { didSet { save("autoHideSharing", autoHideSharing) } }
    var lidFoldStyle: String { didSet { save("lidFoldStyle", lidFoldStyle) } }
    var menuBarStatus: String { didSet { save("menuBarStatus", menuBarStatus) } }
    var screenshotShelf: Bool { didSet { save("screenshotShelf", screenshotShelf) } }
    var lockEnabled: Bool { didSet { save("lockEnabled", lockEnabled) } }
    var hoverToExpand: Bool { didSet { save("hoverToExpand", hoverToExpand) } }
    var showOnExternal: Bool { didSet { save("showOnExternal", showOnExternal) } }
    var shortcut: String { didSet { save("shortcut", shortcut) } }
    var includeMinimized: Bool { didSet { save("includeMinimized", includeMinimized) } }
    var mediaEnabled: Bool { didSet { save("mediaEnabled", mediaEnabled) } }
    var appearance: String { didSet { save("appearance", appearance); applyAppearance() } }
    var chargingFeedback: Bool { didSet { save("chargingFeedback", chargingFeedback) } }
    var chargeTarget: Int { didSet { save("chargeTarget", chargeTarget) } }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: ["toolShortcutsEnabled": true, "notchEnabled": true, "switcherEnabled": false,
            "scaleEnabled": true, "lockEnabled": true, "lidEffectEnabled": true, "hoverToExpand": true,
            "showOnExternal": false, "shortcut": "command", "includeMinimized": true,
            "chargingFeedback": true, "chargeTarget": 80, "mediaEnabled": false, "lidFoldStyle": "fold", "liveTransfers": false, "autoHideFocus": false, "autoHideSharing": false, "calendarPreview": false, "clipboardHistory": false, "toolShortcutModifiers": "ctrlOptCmd", "menuBarStatus": "off", "screenshotShelf": false, "appearance": "system"])
        toolShortcutsEnabled = defaults.bool(forKey: "toolShortcutsEnabled")
        notchEnabled = defaults.bool(forKey: "notchEnabled")
        switcherEnabled = defaults.bool(forKey: "switcherEnabled")
        scaleEnabled = defaults.bool(forKey: "scaleEnabled")
        toolShortcutModifiers = defaults.string(forKey: "toolShortcutModifiers") ?? "ctrlOptCmd"
        clipboardHistory = defaults.bool(forKey: "clipboardHistory")
        calendarPreview = defaults.bool(forKey: "calendarPreview")
        liveTransfers = defaults.bool(forKey: "liveTransfers")
        autoHideFocus = defaults.bool(forKey: "autoHideFocus")
        autoHideSharing = defaults.bool(forKey: "autoHideSharing")
        lidFoldStyle = defaults.string(forKey: "lidFoldStyle") ?? "fold"
        menuBarStatus = defaults.string(forKey: "menuBarStatus") ?? "off"
        screenshotShelf = defaults.bool(forKey: "screenshotShelf")
        lockEnabled = defaults.bool(forKey: "lockEnabled")
        lidEffectEnabled = defaults.bool(forKey: "lidEffectEnabled")
        hoverToExpand = defaults.bool(forKey: "hoverToExpand")
        showOnExternal = defaults.bool(forKey: "showOnExternal")
        shortcut = defaults.string(forKey: "shortcut") ?? "command"
        includeMinimized = defaults.bool(forKey: "includeMinimized")
        mediaEnabled = defaults.bool(forKey: "mediaEnabled")
        appearance = defaults.string(forKey: "appearance") ?? "system"
        chargingFeedback = defaults.bool(forKey: "chargingFeedback")
        chargeTarget = min(100, max(50, defaults.integer(forKey: "chargeTarget")))
    }
    private func save(_ key: String, _ value: Any) { defaults.set(value, forKey: key) }
    func applyAppearance() {
        NSApp.appearance = appearance == "system" ? nil : NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
    }
}

enum SettingsPage: String, CaseIterable, Identifiable {
    case general = "General", notch = "Dynamic Island", switcher = "Window Switcher"
    case scale = "Trackpad Scale", lock = "Lock Screen", permissions = "Permissions"
    var id: String { rawValue }
    var title: String { self == .lock ? "Lid Fold & Lock" : rawValue }
    var symbol: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .notch: "inset.filled.topthird.rectangle"
        case .switcher: "rectangle.on.rectangle"
        case .scale: "scalemass"
        case .lock: "lock"
        case .permissions: "hand.raised"
        }
    }
    var subtitle: String {
        switch self {
        case .general: "A little more Mac."
        case .notch: "A quiet home for what’s happening."
        case .switcher: "Every window. One shortcut."
        case .scale: "A small experiment in pressure."
        case .lock: "A softer landing. The same security."
        case .permissions: "You’re in control."
        }
    }
}
