import AppKit
import ImageIO

/// Notices new macOS screenshots through Spotlight, so Brim never reads or polls a folder itself.
/// Screenshots already on disk are ignored, and only files that appear while this is running are reported.
@MainActor final class ScreenshotWatcher {
    private var query: NSMetadataQuery?
    private var seen: Set<String> = []
    private var observers: [NSObjectProtocol] = []
    var onScreenshot: (URL) -> Void = { _ in }

    func start() {
        guard query == nil else { return }
        let query = NSMetadataQuery()
        query.predicate = NSPredicate(format: "kMDItemIsScreenCapture == 1")
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        query.notificationBatchingInterval = 0.25
        observers.append(NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let query = self.query else { return }
                // Everything gathered at launch predates this session.
                for case let item as NSMetadataItem in query.results {
                    if let path = item.value(forAttribute: NSMetadataItemPathKey) as? String { self.seen.insert(path) }
                }
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidUpdate, object: query, queue: .main) { [weak self] note in
            let added = (note.userInfo?[NSMetadataQueryUpdateAddedItemsKey] as? [NSMetadataItem]) ?? []
            let paths = added.compactMap { $0.value(forAttribute: NSMetadataItemPathKey) as? String }
            MainActor.assumeIsolated { self?.receive(paths: paths) }
        })
        self.query = query
        query.start()
    }

    func stop() {
        query?.stop(); query = nil; seen.removeAll()
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers.removeAll()
    }

    private func receive(paths: [String]) {
        for path in paths where seen.insert(path).inserted {
            let url = URL(fileURLWithPath: path)
            // Only screenshots taken moments ago; a restored backup or synced file isn't news.
            guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  abs(modified.timeIntervalSinceNow) < 60,
                  !url.lastPathComponent.hasPrefix(".") else { continue }
            onScreenshot(url)
        }
    }

    /// A small preview without decoding the full-resolution screenshot.
    static func thumbnail(for url: URL, maxPixels: Int = 320) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixels]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width / 2, height: image.height / 2))
    }
}
