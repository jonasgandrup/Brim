import SwiftUI

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { switch self { case .system: String(localized: "System"); case .light: String(localized: "Light"); case .dark: String(localized: "Dark") } }
}

enum MenuBarStatus: String, CaseIterable, Identifiable {
    case off, battery, activity
    var id: String { rawValue }
    var title: String { switch self { case .off: String(localized: "Off"); case .battery: String(localized: "Battery"); case .activity: String(localized: "Timer") } }
}

/// How much the island does. It isn't saved: it's read back from the switches, so changing one of them just makes it custom.
enum IslandLevel: String, CaseIterable, Identifiable {
    case essentials, more, everything
    var id: String { rawValue }
    var title: String {
        switch self {
        case .essentials: String(localized: "Essentials")
        case .more: String(localized: "More")
        case .everything: String(localized: "Everything")
        }
    }
    var summary: String {
        switch self {
        case .essentials: String(localized: "What iPhone shows: what’s playing, charging and your AirPods. Otherwise, nothing.")
        case .more: String(localized: "Adds files, clipboard, clock and quick controls, all a hover away.")
        case .everything: String(localized: "Adds every other extra, like the camera dot, system notices and more shortcuts.")
        }
    }
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
        "toolShortcutsEnabled": true, "notchEnabled": true, "switcherEnabled": false, "scaleEnabled": false,
        "lidEffectEnabled": false, "hoverToExpand": true, "showOnExternal": false,
        "followActiveDisplay": false, "shortcut": "command", "includeMinimized": true, "chargingFeedback": true,
        "chargeTarget": 80, "lowBatteryAlert": 20, "lidFoldStyle": "duo",
        "liveTransfers": false, "autoHideFocus": false, "autoHideSharing": false, "calendarPreview": false,
        "toolShortcutModifiers": "ctrlOptCmd", "menuBarStatus": "off",
        "screenshotShelf": false, "appearance": "system",
        "bluetoothBatteries": true, "keepShelf": true, "haptics": true, "focusFeedback": false, "islandGestures": false, "systemChanges": false,
        "smallNotices": true, "openWhenIdle": false, "showFiles": false, "showClipboard": false, "showClock": false,
        "sectionShortcuts": false, "menuLockMac": false,
    ]
    var toolShortcutsEnabled: Bool { didSet { save(toolShortcutsEnabled, "toolShortcutsEnabled") } }
    /// The shortcuts for each section, on top of the one that opens the island.
    var sectionShortcuts: Bool { didSet { save(sectionShortcuts, "sectionShortcuts") } }
    var toolShortcutModifiers: ShortcutModifiers { didSet { save(toolShortcutModifiers.rawValue, "toolShortcutModifiers") } }
    var notchEnabled: Bool { didSet { save(notchEnabled, "notchEnabled") } }
    var switcherEnabled: Bool { didSet { save(switcherEnabled, "switcherEnabled") } }
    var scaleEnabled: Bool { didSet { save(scaleEnabled, "scaleEnabled") } }
    var lidEffectEnabled: Bool { didSet { save(lidEffectEnabled, "lidEffectEnabled") } }
    var lidFoldStyle: LidFoldStyle { didSet { save(lidFoldStyle.rawValue, "lidFoldStyle") } }
    var calendarPreview: Bool { didSet { save(calendarPreview, "calendarPreview") } }
    var liveTransfers: Bool { didSet { save(liveTransfers, "liveTransfers") } }
    var autoHideFocus: Bool { didSet { save(autoHideFocus, "autoHideFocus") } }
    var autoHideSharing: Bool { didSet { save(autoHideSharing, "autoHideSharing") } }
    var menuBarStatus: MenuBarStatus { didSet { save(menuBarStatus.rawValue, "menuBarStatus") } }
    var screenshotShelf: Bool { didSet { save(screenshotShelf, "screenshotShelf") } }
    var hoverToExpand: Bool { didSet { save(hoverToExpand, "hoverToExpand") } }
    var showOnExternal: Bool { didSet { save(showOnExternal, "showOnExternal") } }
    /// On Macs with more than one display, the island moves to the display with the active window.
    var followActiveDisplay: Bool { didSet { save(followActiveDisplay, "followActiveDisplay") } }
    var shortcut: SwitcherShortcut { didSet { save(shortcut.rawValue, "shortcut") } }
    var includeMinimized: Bool { didSet { save(includeMinimized, "includeMinimized") } }
    var mediaEnabled: Bool { didSet { save(mediaEnabled, "mediaEnabled") } }
    /// Music and Spotify artwork and controls over Apple Events, which macOS asks about once.
    var playerAccess: Bool { didSet { save(playerAccess, "playerAccess") } }
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
    /// Volume and brightness changes appear in the island.
    var bluetoothBatteries: Bool { didSet { save(bluetoothBatteries, "bluetoothBatteries") } }
    /// Keep shelf files (as references, never copies) and clipboard pins across relaunches.
    var keepShelf: Bool { didSet { save(keepShelf, "keepShelf") } }
    /// A soft trackpad tap for island moments that are worth feeling.
    var haptics: Bool { didSet { save(haptics, "haptics") } }
    /// A brief compact notice when a Focus turns on or off.
    var focusFeedback: Bool { didSet { save(focusFeedback, "focusFeedback") } }
    /// Scroll for volume and Force Click for controls, on the compact island.
    var islandGestures: Bool { didSet { save(islandGestures, "islandGestures") } }
    /// Brief notices for sound output, Low Power Mode and connectivity changes.
    var systemChanges: Bool { didSet { save(systemChanges, "systemChanges") } }
    /// Notices that are only words stay around the camera instead of opening the island.
    var smallNotices: Bool { didSet { save(smallNotices, "smallNotices") } }
    /// The pointer can open the island with nothing going on. Off, as on iPhone, it stays out of the way until there's something to show.
    var openWhenIdle: Bool { didSet { save(openWhenIdle, "openWhenIdle") } }
    /// Lock Mac is in the menu bar menu.
    var menuLockMac: Bool { didSet { save(menuLockMac, "menuLockMac") } }
    var showFiles: Bool { didSet { save(showFiles, "showFiles") } }
    var showClipboard: Bool { didSet { save(showClipboard, "showClipboard") } }
    var showClock: Bool { didSet { save(showClock, "showClock") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Whoever already turned on Now Playing has answered the Automation prompt. Nobody else sees it unasked.
        // mediaEnabled stays unregistered so a saved value can be told apart from the default, which is on.
        let savedMedia = defaults.object(forKey: "mediaEnabled") as? Bool
        if defaults.object(forKey: "playerAccess") == nil { defaults.set(savedMedia == true, forKey: "playerAccess") }
        defaults.register(defaults: Self.initial)
        func flag(_ key: String) -> Bool { defaults.bool(forKey: key) }
        func choice<T: RawRepresentable>(_ key: String, _ fallback: T) -> T where T.RawValue == String {
            defaults.string(forKey: key).flatMap(T.init(rawValue:)) ?? fallback
        }
        toolShortcutsEnabled = flag("toolShortcutsEnabled")
        sectionShortcuts = flag("sectionShortcuts")
        playerAccess = flag("playerAccess")
        toolShortcutModifiers = choice("toolShortcutModifiers", ShortcutModifiers.ctrlOptCmd)
        notchEnabled = flag("notchEnabled")
        switcherEnabled = flag("switcherEnabled")
        scaleEnabled = flag("scaleEnabled")
        lidEffectEnabled = flag("lidEffectEnabled")
        lidFoldStyle = choice("lidFoldStyle", LidFoldStyle.duo)
        calendarPreview = flag("calendarPreview")
        liveTransfers = flag("liveTransfers")
        autoHideFocus = flag("autoHideFocus")
        autoHideSharing = flag("autoHideSharing")
        menuBarStatus = choice("menuBarStatus", MenuBarStatus.off)
        screenshotShelf = flag("screenshotShelf")
        hoverToExpand = flag("hoverToExpand")
        showOnExternal = flag("showOnExternal")
        followActiveDisplay = flag("followActiveDisplay")
        shortcut = choice("shortcut", SwitcherShortcut.command)
        includeMinimized = flag("includeMinimized")
        mediaEnabled = savedMedia ?? true
        appearance = choice("appearance", Appearance.system)
        chargingFeedback = flag("chargingFeedback")
        chargeTarget = Self.clampTarget(defaults.integer(forKey: "chargeTarget"))
        lowBatteryAlert = Self.clampLow(defaults.integer(forKey: "lowBatteryAlert"))
        bluetoothBatteries = flag("bluetoothBatteries")
        keepShelf = flag("keepShelf")
        haptics = flag("haptics")
        focusFeedback = flag("focusFeedback")
        islandGestures = flag("islandGestures")
        systemChanges = flag("systemChanges")
        smallNotices = flag("smallNotices")
        openWhenIdle = flag("openWhenIdle")
        menuLockMac = flag("menuLockMac")
        showFiles = flag("showFiles")
        showClipboard = flag("showClipboard")
        showClock = flag("showClock")
    }
    /// What each level turns on. Anything that reads personal data or makes macOS ask for a permission isn't here:
    /// those stay their own switches, so choosing a level never sets off a run of prompts.
    private var levelSwitches: [(key: ReferenceWritableKeyPath<Preferences, Bool>, on: Set<IslandLevel>)] {
        [(\.mediaEnabled, [.essentials, .more, .everything]), (\.smallNotices, [.essentials]),
         (\.showFiles, [.more, .everything]), (\.showClipboard, [.more, .everything]), (\.showClock, [.more, .everything]),
         (\.openWhenIdle, [.more, .everything]), (\.islandGestures, [.more, .everything]),
         (\.systemChanges, [.everything]),
         (\.sectionShortcuts, [.everything]), (\.menuLockMac, [.everything])]
    }
    /// The level the switches currently add up to, or nil for a custom mix.
    var level: IslandLevel? {
        get { IslandLevel.allCases.first { level in levelSwitches.allSatisfy { self[keyPath: $0.key] == $0.on.contains(level) } } }
        set {
            guard let newValue else { return }
            for item in levelSwitches where self[keyPath: item.key] != item.on.contains(newValue) { self[keyPath: item.key] = item.on.contains(newValue) }
        }
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
    case general = "General", notch = "Island", switcher = "Window Switcher"
    case labs = "Labs", permissions = "Permissions"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .welcome: String(localized: "Welcome to Brim")
        case .general: String(localized: "General")
        case .notch: String(localized: "Island")
        case .switcher: String(localized: "Window Switcher")
        case .labs: String(localized: "Labs")
        case .permissions: String(localized: "Permissions")
        }
    }
    /// The welcome page is reached on first launch or from General, not from the sidebar.
    static var sidebar: [SettingsPage] { allCases.filter { $0 != .welcome } }
    var symbol: String {
        switch self {
        case .welcome: "sparkles"
        case .general: "gearshape.fill"
        case .notch: "capsule.fill"
        case .switcher: "rectangle.on.rectangle"
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
        case .labs: .orange
        case .permissions: .blue
        }
    }
    var subtitle: String {
        switch self {
        case .welcome: String(localized: "Choose how much Brim shows. You can change it anytime.")
        case .general: String(localized: "A little more Mac.")
        case .notch: String(localized: "A quiet home for what’s happening.")
        case .switcher: String(localized: "Every window. One shortcut.")
        case .labs: String(localized: "Experiments that lean on your Mac’s sensors. Fun, and a little unpredictable.")
        case .permissions: String(localized: "You’re in control.")
        }
    }
}

/// The Island page's sub-pages, reached by drilling in, as System Settings does for Control Center.
enum IslandSection: String, CaseIterable, Identifiable {
    case shelf = "Files & Clipboard", notices = "Notices"
    case battery = "Battery", hiding = "Hide Automatically", keyboard = "Keyboard & Shortcuts"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .shelf: String(localized: "Files & Clipboard")
        case .notices: String(localized: "Notices")
        case .battery: String(localized: "Battery")
        case .hiding: String(localized: "Hide Automatically")
        case .keyboard: String(localized: "Keyboard & Shortcuts")
        }
    }
    var symbol: String {
        switch self {
        case .shelf: "tray.fill"
        case .notices: "bolt.horizontal.fill"
        case .battery: "battery.100percent"
        case .hiding: "eye.slash.fill"
        case .keyboard: "keyboard.fill"
        }
    }
    var tint: Color {
        switch self {
        case .shelf: .teal
        case .notices: .blue
        case .battery: .green
        case .hiding: .gray
        case .keyboard: .gray
        }
    }
    var subtitle: String {
        switch self {
        case .shelf: String(localized: "A place for files and snippets while you work.")
        case .notices: String(localized: "Brief updates from your Mac, right where you’re looking.")
        case .battery: String(localized: "Power at a glance, and a word when it matters.")
        case .hiding: String(localized: "The island steps aside when it should.")
        case .keyboard: String(localized: "Open the island without reaching for the pointer.")
        }
    }
}
