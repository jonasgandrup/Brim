import SwiftUI

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum MenuBarStatus: String, CaseIterable, Identifiable {
    case off, battery, activity
    var id: String { rawValue }
    var title: String { switch self { case .off: "Off"; case .battery: "Battery"; case .activity: "Timer" } }
}

enum SwitcherShortcut: String, CaseIterable, Identifiable {
    case command, option, control
    var id: String { rawValue }
    var title: String { switch self { case .command: "⌘ Tab"; case .option: "⌥ Tab"; case .control: "⌃ Tab" } }
}

/// Every setting is stored under its own property name.
@MainActor @Observable
final class Preferences {
    private let defaults: UserDefaults
    private static let initial: [String: Any] = [
        "toolShortcutsEnabled": true, "notchEnabled": true, "switcherEnabled": false, "scaleEnabled": true,
        "lockEnabled": true, "lidEffectEnabled": true, "hoverToExpand": true, "showOnExternal": false,
        "followActiveDisplay": false, "shortcut": "command", "includeMinimized": true, "chargingFeedback": true,
        "chargeTarget": 80, "lowBatteryAlert": 20, "mediaEnabled": false, "lidFoldStyle": "duo",
        "liveTransfers": false, "autoHideFocus": false, "autoHideSharing": false, "calendarPreview": false,
        "clipboardHistory": false, "toolShortcutModifiers": "ctrlOptCmd", "menuBarStatus": "off",
        "screenshotShelf": false, "appearance": "system", "sensorIndicator": false, "systemHUD": false,
        "bluetoothBatteries": true, "keepShelf": true, "haptics": true, "focusFeedback": false,
    ]
    var toolShortcutsEnabled: Bool { didSet { save(toolShortcutsEnabled, "toolShortcutsEnabled") } }
    var toolShortcutModifiers: ShortcutModifiers { didSet { save(toolShortcutModifiers.rawValue, "toolShortcutModifiers") } }
    var notchEnabled: Bool { didSet { save(notchEnabled, "notchEnabled") } }
    var switcherEnabled: Bool { didSet { save(switcherEnabled, "switcherEnabled") } }
    var scaleEnabled: Bool { didSet { save(scaleEnabled, "scaleEnabled") } }
    var lidEffectEnabled: Bool { didSet { save(lidEffectEnabled, "lidEffectEnabled") } }
    var lidFoldStyle: LidFoldStyle { didSet { save(lidFoldStyle.rawValue, "lidFoldStyle") } }
    var clipboardHistory: Bool { didSet { save(clipboardHistory, "clipboardHistory") } }
    var calendarPreview: Bool { didSet { save(calendarPreview, "calendarPreview") } }
    var liveTransfers: Bool { didSet { save(liveTransfers, "liveTransfers") } }
    var autoHideFocus: Bool { didSet { save(autoHideFocus, "autoHideFocus") } }
    var autoHideSharing: Bool { didSet { save(autoHideSharing, "autoHideSharing") } }
    var menuBarStatus: MenuBarStatus { didSet { save(menuBarStatus.rawValue, "menuBarStatus") } }
    var screenshotShelf: Bool { didSet { save(screenshotShelf, "screenshotShelf") } }
    var lockEnabled: Bool { didSet { save(lockEnabled, "lockEnabled") } }
    var hoverToExpand: Bool { didSet { save(hoverToExpand, "hoverToExpand") } }
    var showOnExternal: Bool { didSet { save(showOnExternal, "showOnExternal") } }
    /// On Macs with more than one display, the island moves to the display with the active window.
    var followActiveDisplay: Bool { didSet { save(followActiveDisplay, "followActiveDisplay") } }
    var shortcut: SwitcherShortcut { didSet { save(shortcut.rawValue, "shortcut") } }
    var includeMinimized: Bool { didSet { save(includeMinimized, "includeMinimized") } }
    var mediaEnabled: Bool { didSet { save(mediaEnabled, "mediaEnabled") } }
    var appearance: Appearance { didSet { save(appearance.rawValue, "appearance"); applyAppearance() } }
    var chargingFeedback: Bool { didSet { save(chargingFeedback, "chargingFeedback") } }
    var chargeTarget: Int {
        didSet {
            let clamped = Self.clampTarget(chargeTarget)
            if clamped != chargeTarget { chargeTarget = clamped } else { save(chargeTarget, "chargeTarget") }
        }
    }
    /// 0 turns the warning off.
    var lowBatteryAlert: Int {
        didSet {
            let clamped = Self.clampLow(lowBatteryAlert)
            if clamped != lowBatteryAlert { lowBatteryAlert = clamped } else { save(lowBatteryAlert, "lowBatteryAlert") }
        }
    }
    /// A small camera/microphone dot in the island, like iPhone's privacy indicators.
    var sensorIndicator: Bool { didSet { save(sensorIndicator, "sensorIndicator") } }
    /// Volume and brightness changes appear in the island.
    var systemHUD: Bool { didSet { save(systemHUD, "systemHUD") } }
    var bluetoothBatteries: Bool { didSet { save(bluetoothBatteries, "bluetoothBatteries") } }
    /// Keep shelf files (as references, never copies) and clipboard pins across relaunches.
    var keepShelf: Bool { didSet { save(keepShelf, "keepShelf") } }
    /// A soft trackpad tap for island moments that are worth feeling.
    var haptics: Bool { didSet { save(haptics, "haptics") } }
    /// A brief compact notice when a Focus turns on or off.
    var focusFeedback: Bool { didSet { save(focusFeedback, "focusFeedback") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: Self.initial)
        func flag(_ key: String) -> Bool { defaults.bool(forKey: key) }
        func choice<T: RawRepresentable>(_ key: String, _ fallback: T) -> T where T.RawValue == String {
            defaults.string(forKey: key).flatMap(T.init(rawValue:)) ?? fallback
        }
        toolShortcutsEnabled = flag("toolShortcutsEnabled")
        toolShortcutModifiers = choice("toolShortcutModifiers", ShortcutModifiers.ctrlOptCmd)
        notchEnabled = flag("notchEnabled")
        switcherEnabled = flag("switcherEnabled")
        scaleEnabled = flag("scaleEnabled")
        lidEffectEnabled = flag("lidEffectEnabled")
        lidFoldStyle = choice("lidFoldStyle", LidFoldStyle.duo)
        clipboardHistory = flag("clipboardHistory")
        calendarPreview = flag("calendarPreview")
        liveTransfers = flag("liveTransfers")
        autoHideFocus = flag("autoHideFocus")
        autoHideSharing = flag("autoHideSharing")
        menuBarStatus = choice("menuBarStatus", MenuBarStatus.off)
        screenshotShelf = flag("screenshotShelf")
        lockEnabled = flag("lockEnabled")
        hoverToExpand = flag("hoverToExpand")
        showOnExternal = flag("showOnExternal")
        followActiveDisplay = flag("followActiveDisplay")
        shortcut = choice("shortcut", SwitcherShortcut.command)
        includeMinimized = flag("includeMinimized")
        mediaEnabled = flag("mediaEnabled")
        appearance = choice("appearance", Appearance.system)
        chargingFeedback = flag("chargingFeedback")
        chargeTarget = Self.clampTarget(defaults.integer(forKey: "chargeTarget"))
        lowBatteryAlert = Self.clampLow(defaults.integer(forKey: "lowBatteryAlert"))
        sensorIndicator = flag("sensorIndicator")
        systemHUD = flag("systemHUD")
        bluetoothBatteries = flag("bluetoothBatteries")
        keepShelf = flag("keepShelf")
        haptics = flag("haptics")
        focusFeedback = flag("focusFeedback")
    }
    static func clampTarget(_ value: Int) -> Int { min(100, max(50, value)) }
    static func clampLow(_ value: Int) -> Int { value <= 0 ? 0 : min(50, max(5, value)) }
    private func save(_ value: Any, _ key: String) { defaults.set(value, forKey: key) }
    func applyAppearance() {
        NSApp.appearance = switch appearance {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

enum SettingsPage: String, CaseIterable, Identifiable {
    case welcome = "Welcome"
    case general = "General", notch = "Dynamic Island", switcher = "Window Switcher"
    case lock = "Lock Screen", labs = "Labs", permissions = "Permissions"
    var id: String { rawValue }
    var title: String { self == .welcome ? "Welcome to Sense" : rawValue }
    /// The welcome page is reached on first launch or from General, not from the sidebar.
    static var sidebar: [SettingsPage] { allCases.filter { $0 != .welcome } }
    var symbol: String {
        switch self {
        case .welcome: "sparkles"
        case .general: "gearshape.fill"
        case .notch: "capsule.fill"
        case .switcher: "rectangle.on.rectangle"
        case .lock: "lock.fill"
        case .labs: "flask.fill"
        case .permissions: "hand.raised.fill"
        }
    }
    /// The tile color behind the sidebar icon, as in System Settings.
    var tint: Color {
        switch self {
        case .welcome: .purple
        case .general: .gray
        case .notch: .black
        case .switcher: .blue
        case .lock: .indigo
        case .labs: .orange
        case .permissions: .blue
        }
    }
    var subtitle: String {
        switch self {
        case .welcome: "Turn on what you want. Everything else stays off, and you can change it anytime."
        case .general: "A little more Mac."
        case .notch: "A quiet home for what’s happening."
        case .switcher: "Every window. One shortcut."
        case .lock: "A softer landing. The same security."
        case .labs: "Experiments that lean on your Mac’s sensors. Fun, and a little unpredictable."
        case .permissions: "You’re in control."
        }
    }
}

/// The Dynamic Island page's sub-pages, reached by drilling in, as System Settings does for Control Center.
enum IslandSection: String, CaseIterable, Identifiable {
    case nowPlaying = "Now Playing", shelf = "Shelf & Clipboard", activities = "Live Activities"
    case battery = "Battery", hiding = "Hide Automatically", keyboard = "Keyboard & Shortcuts"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .nowPlaying: "play.fill"
        case .shelf: "tray.fill"
        case .activities: "bolt.horizontal.fill"
        case .battery: "battery.100percent"
        case .hiding: "eye.slash.fill"
        case .keyboard: "keyboard.fill"
        }
    }
    var tint: Color {
        switch self {
        case .nowPlaying: .pink
        case .shelf: .teal
        case .activities: .blue
        case .battery: .green
        case .hiding: .gray
        case .keyboard: .gray
        }
    }
    var subtitle: String {
        switch self {
        case .nowPlaying: "What’s playing in any app, with artwork and controls."
        case .shelf: "A place for files and snippets while you work."
        case .activities: "Brief updates from your Mac, right where you’re looking."
        case .battery: "Power at a glance, and a word when it matters."
        case .hiding: "The island steps aside when it should."
        case .keyboard: "Open the island without reaching for the pointer."
        }
    }
}
