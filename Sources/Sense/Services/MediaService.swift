import AppKit

private struct PlayerSnapshot: Sendable {
    let source: String
    let title: String
    let artist: String
    let playing: Bool
    let artwork: Data?
}

private enum PlayerAutomation {
    // Child process keeps Apple Event waits off the UI thread. Only fixed commands are accepted.
    nonisolated static func run(_ script: String) async -> (String, Bool) {
        await MediaScriptRunner.run(script, timeout: 15)
    }
    nonisolated static func snapshot(runningPlayers: Set<String>) async -> PlayerSnapshot? {
        let artworkFile = FileManager.default.temporaryDirectory.appendingPathComponent("sense-art-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: artworkFile) }
        let spotifyPlaying = """
        if application id "com.spotify.client" is running then
            tell application id "com.spotify.client"
                if player state is playing then
                    return "com.spotify.client" & sep & name of current track & sep & artist of current track & sep & "playing" & sep & artwork url of current track
                end if
            end tell
        end if
        """
        let music = """
        if application id "com.apple.Music" is running then
            tell application id "com.apple.Music"
                if player state is not stopped then
                    set trackName to name of current track
                    set trackArtist to artist of current track
                    set trackState to player state as text
                    try
                        set coverData to raw data of artwork 1 of current track
                        set coverFile to open for access POSIX file "\(artworkFile.path)" with write permission
                        set eof coverFile to 0
                        write coverData to coverFile
                        close access coverFile
                    end try
                    return "com.apple.Music" & sep & trackName & sep & trackArtist & sep & trackState & sep & "local"
                end if
            end tell
        end if
        """
        let spotifyPaused = """
        if application id "com.spotify.client" is running then
            tell application id "com.spotify.client"
                if player state is paused then
                    return "com.spotify.client" & sep & name of current track & sep & artist of current track & sep & "paused" & sep & artwork url of current track
                end if
            end tell
        end if
        """
        let hasSpotify = runningPlayers.contains("com.spotify.client")
        let hasMusic = runningPlayers.contains("com.apple.Music")
        let script = ["set sep to ASCII character 31", hasSpotify ? spotifyPlaying : "", hasMusic ? music : "", hasSpotify ? spotifyPaused : "", "return \"\""].joined(separator: "\n")
        let (result, success) = await run(script)
        guard success, !Task.isCancelled else { return nil }
        let fields = result.components(separatedBy: "\u{1f}")
        guard fields.count == 5 else { return PlayerSnapshot(source: "", title: "Nothing playing", artist: "Music & Spotify", playing: false, artwork: nil) }
        var artwork: Data?
        if fields[4] == "local" { artwork = try? Data(contentsOf: artworkFile) }
        else if let url = URL(string: fields[4]), url.scheme == "https" {
            // Artwork URL is supplied by Spotify. This is the app's only network request.
            var request = URLRequest(url: url); request.timeoutInterval = 5
            if let (data, response) = try? await URLSession.shared.data(for: request),
               let response = response as? HTTPURLResponse, response.statusCode == 200, data.count < 10_000_000 { artwork = data }
        }
        return PlayerSnapshot(source: fields[0], title: fields[1], artist: fields[2], playing: fields[3].lowercased() == "playing", artwork: artwork)
    }
}

/// System-wide compatibility feed with native Music/Spotify automation fallbacks.
@MainActor @Observable
final class MediaService {
    var title = "Nothing playing"
    var artist = ""
    var playing = false
    var artwork: NSImage?
    var source: String?
    var sourceName = "Now Playing"
    var sourceIcon: NSImage?
    var timeline: MediaTimeline?
    var message: String?
    var refreshing = false
    private(set) var systemAvailable = false
    private var systemTransport = false
    private var generation = 0
    private var observers: [NSObjectProtocol] = []
    private var updateTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?
    private var artworkKey = ""
    func start() {
        guard pollTask == nil else { return }
        for name in ["com.apple.Music.playerInfo", "com.spotify.client.PlaybackStateChanged"] {
            observers.append(DistributedNotificationCenter.default().addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        refresh()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.playing == true ? 1 : 3))
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }
    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        let currentGeneration = generation
        let runningPlayers = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        updateTask = Task { [weak self] in
            let system = await SystemMediaBridge.snapshot()
            guard !Task.isCancelled, let self, self.generation == currentGeneration else { return }
            self.systemAvailable = system?.available == true
            if let system, system.hasMedia {
                self.apply(system)
                self.refreshing = false
                self.loadArtworkIfNeeded(runningPlayers: runningPlayers)
                return
            }
            let native = await PlayerAutomation.snapshot(runningPlayers: runningPlayers)
            guard !Task.isCancelled, self.generation == currentGeneration else { return }
            self.refreshing = false
            guard let native else {
                self.clearPlayback()
                self.message = self.systemAvailable ? "No media session is available." : "Player access unavailable. Check Automation access in System Settings."
                return
            }
            self.systemTransport = false; self.timeline = nil
            self.title = native.title; self.artist = native.artist; self.playing = native.playing
            self.setSource(native.source.isEmpty ? nil : native.source, name: native.source == "com.spotify.client" ? "Spotify" : native.source == "com.apple.Music" ? "Music" : "Now Playing")
            self.artwork = native.artwork.flatMap { NSImage(data: $0) }; self.message = nil
        }
    }
    func apply(_ snapshot: SystemMediaSnapshot) {
        guard snapshot.hasMedia else { clearPlayback(); return }
        let nextSource = snapshot.source ?? "system.nowplaying"
        let nextTitle = snapshot.title ?? "Untitled media"
        if nextSource != source || nextTitle != title { artwork = nil; artworkTask?.cancel(); artworkKey = "" }
        systemTransport = true; title = nextTitle; artist = snapshot.artist ?? ""
        playing = (snapshot.rate ?? 0) > 0
        setSource(nextSource, name: snapshot.sourceName ?? "Media")
        timeline = nil
        if let duration = snapshot.duration, let position = snapshot.position, let rate = snapshot.rate {
            let value = MediaTimeline(duration: duration, position: position, rate: rate, measuredAt: Date())
            if value.usable { timeline = value }
        }
        if let encoded = snapshot.artwork, let data = Data(base64Encoded: encoded), data.count < 2_000_000, let image = NSImage(data: data) { artwork = image }
        message = nil
    }
    private func setSource(_ bundle: String?, name: String) {
        if bundle != source {
            sourceIcon = bundle.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.map { NSWorkspace.shared.icon(forFile: $0.path) }
        }
        source = bundle; sourceName = name
    }
    private func loadArtworkIfNeeded(runningPlayers: Set<String>) {
        guard artwork == nil, let source, ["com.apple.Music", "com.spotify.client"].contains(source) else { return }
        let key = source + "\n" + title
        guard key != artworkKey else { return }
        artworkKey = key
        let expectedTitle = title
        let currentGeneration = generation
        artworkTask = Task { [weak self] in
            let result = await PlayerAutomation.snapshot(runningPlayers: runningPlayers.intersection([source]))
            guard !Task.isCancelled, let self, self.generation == currentGeneration, self.source == source, self.title == expectedTitle,
                  result?.title == expectedTitle, result?.source == source else { return }
            self.artwork = result?.artwork.flatMap { NSImage(data: $0) }
        }
    }
    private func clearPlayback() {
        title = "Nothing playing"; artist = ""; setSource(nil, name: "Now Playing")
        artwork = nil; timeline = nil; playing = false; systemTransport = false; artworkKey = ""
        artworkTask?.cancel()
    }
    func stop() {
        generation += 1
        updateTask?.cancel(); updateTask = nil; refreshing = false
        pollTask?.cancel(); pollTask = nil; artworkTask?.cancel(); commandTask?.cancel()
        observers.forEach { DistributedNotificationCenter.default().removeObserver($0) }; observers.removeAll()
        clearPlayback(); message = nil; systemAvailable = false
    }
    func openPlayer() {
        guard let source, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: source) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }
    func command(_ command: String) {
        guard let source, ["playpause", "next track", "previous track"].contains(command) else { return }
        let usesSystem = systemTransport
        let currentGeneration = generation
        commandTask?.cancel()
        commandTask = Task { [weak self] in
            var success = false
            if usesSystem { success = await SystemMediaBridge.command(command, source: source) }
            if !success && ["com.apple.Music", "com.spotify.client"].contains(source) {
                (_, success) = await PlayerAutomation.run("tell application id \"\(source)\" to \(command)")
            }
            guard !Task.isCancelled, let self, self.generation == currentGeneration else { return }
            self.message = success ? nil : "This player didn’t accept the command. Open it to control playback."
            if success {
                try? await Task.sleep(for: .milliseconds(250))
                if !Task.isCancelled { self.refresh() }
            }
        }
    }
}
