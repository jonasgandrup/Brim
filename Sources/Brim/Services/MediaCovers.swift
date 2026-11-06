import AppKit

/// Covers already seen this session, so going back to a track shows its cover at once instead of the app icon
/// while it's fetched again. Small and memory-only.
struct MediaCoverCache {
    private var covers: [String: NSImage] = [:]
    private static func key(source: String, title: String, identifier: String) -> String { source + "\n" + title + "\n" + identifier }
    func cover(source: String, title: String, identifier: String) -> NSImage? { covers[Self.key(source: source, title: title, identifier: identifier)] }
    mutating func remember(_ image: NSImage, source: String, title: String, identifier: String) {
        if covers.count >= 24 { covers.removeAll(keepingCapacity: true) }
        covers[Self.key(source: source, title: title, identifier: identifier)] = image
    }
}
