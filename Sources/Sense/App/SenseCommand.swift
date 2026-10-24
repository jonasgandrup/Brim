import Foundation

/// `sense://` links, so Shortcuts (Open URLs), scripts and other apps can drive the island.
///
///     sense://open?tool=music|files|clipboard|clock|battery|transfers
///     sense://timer/start?minutes=10      sense://timer/cancel
///     sense://focus/start                 sense://clipboard/pin
///     sense://presentation?enabled=on|off|toggle
///     sense://message?text=Hello&symbol=bell
///     sense://shelf/add?path=/Users/me/file.pdf
///     sense://settings
enum SenseCommand: Equatable {
    case open(ToolShortcuts.Tool?)
    case startTimer(minutes: Double)
    case cancelTimer
    case startFocus
    case pinClipboard
    case presentation(Bool?)
    case message(String, symbol: String)
    case addToShelf(URL)
    case settings

    static let maxMessageLength = 80

    init?(url: URL) {
        guard url.scheme?.lowercased() == "sense" else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        func value(_ name: String) -> String? { components?.queryItems?.first { $0.name == name }?.value }
        let path = ([url.host ?? ""] + url.pathComponents.filter { $0 != "/" }).filter { !$0.isEmpty }.joined(separator: "/").lowercased()
        switch path {
        case "open", "island":
            guard let name = value("tool") ?? value("tab") else { self = .open(nil); return }
            guard let tool = Self.tool(named: name) else { return nil }
            self = .open(tool)
        case "timer/start", "timer":
            let minutes = value("minutes").flatMap(Double.init) ?? 5
            guard minutes.isFinite, minutes > 0, minutes <= 24 * 60 else { return nil }
            self = .startTimer(minutes: minutes)
        case "timer/cancel", "timer/stop": self = .cancelTimer
        case "focus/start", "focus": self = .startFocus
        case "clipboard/pin": self = .pinClipboard
        case "presentation":
            switch value("enabled")?.lowercased() {
            case nil, "toggle": self = .presentation(nil)
            case "on", "true", "1", "yes": self = .presentation(true)
            case "off", "false", "0", "no": self = .presentation(false)
            default: return nil
            }
        case "message", "show":
            guard let text = value("text")?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            let symbol = value("symbol").flatMap { $0.range(of: #"^[a-z0-9.]{1,60}$"#, options: .regularExpression) == nil ? nil : $0 } ?? "bell.fill"
            self = .message(String(text.prefix(Self.maxMessageLength)), symbol: symbol)
        case "shelf/add":
            guard let raw = value("path"), !raw.isEmpty else { return nil }
            let file = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
            self = .addToShelf(file)
        case "settings": self = .settings
        default: return nil
        }
    }
    static func tool(named name: String) -> ToolShortcuts.Tool? {
        switch name.lowercased() {
        case "music", "nowplaying", "now-playing", "media": .nowPlaying
        case "files", "shelf": .files
        case "clipboard": .clipboard
        case "clock", "timer": .clock
        case "battery": .battery
        case "transfers", "downloads": .transfers
        default: nil
        }
    }
}
