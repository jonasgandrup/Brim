import Foundation

/// `sense://` links, so Shortcuts (Open URLs), scripts and other apps can drive the island.
///
///     sense://open?tool=music|files|clipboard|clock|battery|transfers
///     sense://timer/start?minutes=10      sense://timer/cancel
///     sense://focus/start                 sense://clipboard/pin
///     sense://presentation?enabled=on|off|toggle
///     sense://message?text=Hello&symbol=bell
///     sense://shelf/add?path=/Users/me/file.pdf
///     sense://activity?id=export&title=Exporting&progress=0.4&symbol=film   (progress 0–1, or percent=40)
///     sense://activity/end?id=export&title=Export%20finished              sense://activity/cancel?id=export
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
    case activity(id: String, title: String?, symbol: String?, progress: Double?)
    case endActivity(id: String, title: String?, finished: Bool)
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
            self = .message(String(text.prefix(Self.maxMessageLength)), symbol: Self.symbol(value("symbol")) ?? "bell.fill")
        case "activity", "activity/update", "activity/start":
            let title = Self.text(value("title"))
            guard let id = Self.text(value("id")) ?? title else { return nil }
            var progress: Double?
            if let raw = value("progress") {
                guard let fraction = Double(raw), fraction.isFinite, (0...1).contains(fraction) else { return nil }
                progress = fraction
            } else if let raw = value("percent") {
                guard let percent = Double(raw.trimmingCharacters(in: CharacterSet(charactersIn: "% "))), percent.isFinite, (0...100).contains(percent) else { return nil }
                progress = percent / 100
            }
            self = .activity(id: id, title: title, symbol: Self.symbol(value("symbol")), progress: progress)
        case "activity/end", "activity/done", "activity/finish", "activity/cancel":
            guard let id = Self.text(value("id")) ?? Self.text(value("title")) else { return nil }
            self = .endActivity(id: id, title: Self.text(value("title")), finished: !path.hasSuffix("cancel"))
        case "shelf/add":
            guard let raw = value("path"), !raw.isEmpty else { return nil }
            let file = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
            self = .addToShelf(file)
        case "settings": self = .settings
        default: return nil
        }
    }
    /// SF Symbol names only: lowercase letters, digits and dots.
    static func symbol(_ raw: String?) -> String? {
        raw.flatMap { $0.range(of: #"^[a-z0-9.]{1,60}$"#, options: .regularExpression) == nil ? nil : $0 }
    }
    static func text(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(60))
    }
    static func tool(named name: String) -> ToolShortcuts.Tool? {
        switch name.lowercased() {
        case "music", "nowplaying", "now-playing", "media": .nowPlaying
        case "files", "shelf": .files
        case "clipboard": .clipboard
        case "clock", "timer": .clock
        case "battery": .battery
        case "island", "now": .island
        case "transfers", "downloads": .transfers
        default: nil
        }
    }
}
