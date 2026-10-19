import SwiftUI

@MainActor @Observable
final class Preferences {
    private let defaults: UserDefaults
    var notchEnabled: Bool { didSet { save("notchEnabled", notchEnabled) } }
    var switcherEnabled: Bool { didSet { save("switcherEnabled", switcherEnabled) } }
    var scaleEnabled: Bool { didSet { save("scaleEnabled", scaleEnabled) } }
    var lidEffectEnabled: Bool { didSet { save("lidEffectEnabled", lidEffectEnabled) } }
    var lockEnabled: Bool { didSet { save("lockEnabled", lockEnabled) } }
    var hoverToExpand: Bool { didSet { save("hoverToExpand", hoverToExpand) } }
    var showOnExternal: Bool { didSet { save("showOnExternal", showOnExternal) } }
    var shortcut: String { didSet { save("shortcut", shortcut) } }
    var includeMinimized: Bool { didSet { save("includeMinimized", includeMinimized) } }
    var mediaEnabled: Bool { didSet { save("mediaEnabled", mediaEnabled) } }
    var appearance: String { didSet { save("appearance", appearance); applyAppearance() } }
    var chargingFeedback: Bool { didSet { save("chargingFeedback", chargingFeedback) } }
    var chargeTarget: Int { didSet { save("chargeTarget", chargeTarget) } }
    var gramsPerUnit: Double { didSet { save("gramsPerUnit", gramsPerUnit) } }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: ["notchEnabled": true, "switcherEnabled": false,
            "scaleEnabled": true, "lockEnabled": true, "lidEffectEnabled": true, "hoverToExpand": true,
            "showOnExternal": false, "shortcut": "command", "includeMinimized": true,
            "chargingFeedback": true, "chargeTarget": 80, "mediaEnabled": false, "appearance": "system", "gramsPerUnit": 0.0])
        notchEnabled = defaults.bool(forKey: "notchEnabled")
        switcherEnabled = defaults.bool(forKey: "switcherEnabled")
        scaleEnabled = defaults.bool(forKey: "scaleEnabled")
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
        gramsPerUnit = defaults.double(forKey: "gramsPerUnit")
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
