import AppKit
import Darwin

/// One transfer shown as a Live Activity in the island.
struct TransferActivity: Identifiable, Equatable {
    enum Kind { case download, airDropSend, airDropReceive }
    enum State: Equatable { case running, finished, failed(String) }
    let id: String
    var kind: Kind
    var name: String
    /// nil when the app doesn't say how far along it is; the island then shows a spinner, never a guess.
    var fraction: Double?
    var bytes: Int64?
    var state: State = .running
    var url: URL?

    var symbol: String {
        switch kind { case .download: "arrow.down.circle.fill"; case .airDropSend: "airplayaudio"; case .airDropReceive: "dot.radiowaves.up.forward" }
    }
}

enum TransferScan {
    /// Temporary names browsers use while a file is still arriving, and the final name they become.
    static let partialExtensions: Set<String> = ["download", "crdownload", "part", "partial", "opdownload"]
    static func partials(in names: [String]) -> [(partial: String, final: String)] {
        names.compactMap { name in
            guard !name.hasPrefix(".") else { return nil }
            let url = URL(fileURLWithPath: name)
            guard partialExtensions.contains(url.pathExtension.lowercased()) else { return nil }
            let final = url.deletingPathExtension().lastPathComponent
            return final.isEmpty ? nil : (name, final)
        }
    }
    /// Safari's `.download` package records its own byte counts.
    static func safariProgress(_ plist: [String: Any]) -> (fraction: Double?, bytes: Int64?) {
        let loaded = (plist["DownloadEntryProgressBytesSoFar"] as? NSNumber)?.int64Value
        let total = (plist["DownloadEntryProgressTotalToLoad"] as? NSNumber)?.int64Value
        guard let loaded, loaded >= 0 else { return (nil, nil) }
        guard let total, total > 0 else { return (nil, loaded) }
        return (min(1, Double(loaded) / Double(total)), loaded)
    }
    /// The app that quarantined a file, from the `com.apple.quarantine` value ("flags;time;agent;uuid").
    static func quarantineAgent(_ value: String) -> String? {
        let parts = value.split(separator: ";", omittingEmptySubsequences: false)
        return parts.count >= 3 ? String(parts[2]) : nil
    }
    static func quarantineAgent(of url: URL) -> String? {
        let size = getxattr(url.path, "com.apple.quarantine", nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard getxattr(url.path, "com.apple.quarantine", &buffer, size, 0, 0) == size else { return nil }
        return quarantineAgent(String(decoding: buffer, as: UTF8.self))
    }
    static func combinedFraction(_ activities: [TransferActivity]) -> Double? {
        let values = activities.compactMap(\.fraction)
        return values.isEmpty || values.count < activities.count ? nil : values.reduce(0, +) / Double(values.count)
    }
}

/// Watches the Downloads folder for files that are still arriving, and reports AirDrops sent from the
/// shelf. Opt-in: reading Downloads makes macOS ask for permission the first time.
@MainActor @Observable final class TransferTracker {
    private(set) var running: [TransferActivity] = []
    private(set) var recent: [TransferActivity] = []
    private(set) var accessProblem: String?
    var hasRunning: Bool { !running.isEmpty }
    @ObservationIgnored var onFinished: (TransferActivity) -> Void = { _ in }
    private var directory: URL?
    private var source: DispatchSourceFileSystemObject?
    private var timer: Timer?
    private var known: Set<String>?
    private var downloads: [String: TransferActivity] = [:]
    private var airDropSend: TransferActivity?
    private var airDropToken = UUID()

    func start(directory override: URL? = nil) {
        guard source == nil else { return }
        let directory = override ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard let directory else { return }
        self.directory = directory
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { accessProblem = String(localized: "Sense can’t read the Downloads folder."); return }
        accessProblem = nil
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.scan() } }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
        scan()
    }
    func stop() {
        source?.cancel(); source = nil; timer?.invalidate(); timer = nil
        known = nil; downloads.removeAll(); airDropSend = nil; running.removeAll(); recent.removeAll()
    }
    func clearRecent() { recent.removeAll() }

    // MARK: AirDrop sent from the shelf

    func beginAirDropSend(count: Int) {
        airDropSend = TransferActivity(id: "airdrop-send", kind: .airDropSend, name: count == 1 ? String(localized: "Sending 1 file") : String(localized: "Sending \(count) files"))
        publish()
        // macOS reports completion or failure; this only keeps a lost callback from leaving a spinner behind.
        let token = UUID(); airDropToken = token
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(900))
            if let self, self.airDropToken == token, self.airDropSend != nil { self.cancelAirDropSend() }
        }
    }
    func cancelAirDropSend() { airDropSend = nil; publish() }
    func endAirDropSend(error: String?) {
        guard var activity = airDropSend else { return }
        airDropSend = nil
        activity.state = error.map { .failed($0) } ?? .finished
        if error == nil { activity.name = activity.name.replacingOccurrences(of: String(localized: "Sending"), with: String(localized: "Sent")) }
        publish(); finish(activity)
    }

    // MARK: Downloads folder

    func scan() {
        guard let directory, let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        let partials = TransferScan.partials(in: names)
        var seen: Set<String> = []
        for (partial, final) in partials {
            seen.insert(final)
            let url = directory.appendingPathComponent(partial)
            var activity = downloads[final] ?? TransferActivity(id: "download-\(final)", kind: .download, name: final)
            activity.url = directory.appendingPathComponent(final)
            if url.pathExtension.lowercased() == "download",
               let data = try? Data(contentsOf: url.appendingPathComponent("Info.plist")),
               let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                (activity.fraction, activity.bytes) = TransferScan.safariProgress(plist)
            } else {
                activity.bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
            }
            downloads[final] = activity
        }
        for (final, var activity) in downloads where !seen.contains(final) {
            downloads[final] = nil
            // The temporary name vanished: finished if the real file is there, otherwise cancelled.
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(final).path) {
                activity.state = .finished; activity.fraction = 1
                finish(activity)
            }
        }
        // Files that appear whole (no temporary name) from AirDrop are recognised by the app that quarantined them.
        let partialNames = Set(partials.flatMap { [$0.partial, $0.final] })
        if let known {
            for name in names where !known.contains(name) && !name.hasPrefix(".") && !partialNames.contains(name) {
                let url = directory.appendingPathComponent(name)
                if TransferScan.quarantineAgent(of: url) == "sharingd" {
                    finish(TransferActivity(id: "airdrop-\(name)", kind: .airDropReceive, name: name, fraction: 1, state: .finished, url: url))
                }
            }
        }
        known = Set(names)
        publish()
    }

    private func finish(_ activity: TransferActivity) {
        recent.insert(activity, at: 0)
        if recent.count > 5 { recent.removeLast() }
        onFinished(activity)
    }

    private func publish() {
        var next = downloads.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if let airDropSend { next.insert(airDropSend, at: 0) }
        if next != running { running = next }
        // Progress inside a package or file can change without a directory event, so poll gently while busy.
        if running.isEmpty { timer?.invalidate(); timer = nil }
        else if timer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.scan() } }
            timer.tolerance = 0.3
            RunLoop.main.add(timer, forMode: .common); self.timer = timer
        }
    }
}
