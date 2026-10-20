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
    nonisolated static func command(_ request: MediaPlaybackRequest) async -> MediaCommandResult {
        let source = request.item.source
        guard ["com.apple.Music", "com.spotify.client"].contains(source) else { return .unsupported }
        // This adapter is used only when its own snapshot supplied the card.
        // Arguments keep media titles out of AppleScript source interpolation.
        let script = """
        on run argv
            if application id "\(source)" is not running then return "unavailable"
            tell application id "\(source)"
                if name of current track is not (item 1 of argv) then return "item-changed"
                \(request.action.appleScript)
            end tell
            return "submitted"
        end run
        """
        let (result, success) = await MediaScriptRunner.run(script, arguments: [request.item.title], timeout: 15)
        return success ? MediaCommandResult(rawValue: result) ?? .failed : .failed
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
    let sleepTimer = MediaSleepTimer()
    private(set) var players: [MediaPlayer] = []
    private(set) var pinnedPlayer: MediaPlayer?
    private(set) var selectionLoading = false
    private var selectionRevision = 0
    private var discoveryTime: TimeInterval = -.infinity
    private let defaults: UserDefaults?
    private var artworkCache: [String: NSImage] = [:]
    @ObservationIgnored var playerReader: @Sendable (MediaPlayer) async -> SystemMediaSnapshot? = { await SystemMediaBridge.snapshot(for: $0) }
    @ObservationIgnored var playersReader: @MainActor () async -> [MediaPlayer] = { await MediaPlayerDiscovery.players() }
    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? (Bundle.main.bundleURL.pathExtension == "app" ? (CommandLine.arguments.contains("--smoke-test") ? UserDefaults(suiteName: "Sense.MediaSmoke") : .standard) : nil)
        if let source = self.defaults?.string(forKey: "mediaPinnedSource"), !source.isEmpty {
            pinnedPlayer = MediaPlayer(source: source, name: self.defaults?.string(forKey: "mediaPinnedName") ?? source, processID: 0)
        }
        sleepTimer.readTrack = { [weak self] player in await self?.playerReader(player) }
        sleepTimer.pauseTrack = { [weak self] snapshot in
            guard let self, !Task.isCancelled, let source = snapshot.source, let title = snapshot.title,
                  let path = snapshot.playerPath else { return .unavailable }
            return await self.playbackTransport(.init(item: .init(source: source, title: title,
                identifier: snapshot.identifier ?? "", playerPath: path), action: .pause), true)
        }
        sleepTimer.pause = { [weak self] player in await self?.pausePlayerForSleep(player) ?? .unavailable }
    }
    var currentPlayer: MediaPlayer? { players.first { $0.source == source && (currentProcessID == 0 || $0.processID == currentProcessID) } }
    private var currentProcessID: Int32 = 0
    func updatePlayers(_ values: [MediaPlayer]) {
        players = values
        if let pinnedPlayer, let live = players.first(where: { $0.source == pinnedPlayer.source }) { self.pinnedPlayer = live }
    }
    func refreshPlayers() async { updatePlayers(await playersReader()); discoveryTime = ProcessInfo.processInfo.systemUptime }
    func selectPlayer(_ player: MediaPlayer?) {
        guard !commandPending else { return }
        seekTask?.cancel()
        pinnedPlayer = player; selectionRevision += 1
        defaults?.set(player?.source, forKey: "mediaPinnedSource"); defaults?.set(player?.name, forKey: "mediaPinnedName")
        updateTask?.cancel(); refreshing = false; selectionLoading = true
        cancelScrub(); refresh()
    }
    func startSleepTimer(minutes: Int) {
        guard !selectionLoading, let currentPlayer else { return }
        sleepTimer.start(minutes: minutes, player: currentPlayer)
    }
    private var trackEndSnapshot: SystemMediaSnapshot? {
        guard !selectionLoading, let player = currentPlayer, let timeline, timeline.usable else { return nil }
        return .init(available: true, title: title, source: source, rate: timeline.rate,
            duration: timeline.duration, position: timeline.elapsed(at: Date()), identifier: identifier,
            playerPath: playerPath, processID: player.processID)
    }
    var canSleepAtTrackEnd: Bool { trackEndSnapshot.map(MediaSleepTimer.supportsTrackEnd) ?? false }
    func startTrackEndSleepTimer() {
        guard let player = currentPlayer, let snapshot = trackEndSnapshot else { return }
        sleepTimer.startAtTrackEnd(player: player, snapshot: snapshot)
    }
    private func pausePlayerForSleep(_ player: MediaPlayer) async -> MediaCommandResult {
        guard let snapshot = await playerReader(player), !Task.isCancelled, snapshot.hasMedia, snapshot.source == player.source,
              snapshot.processID == player.processID, let title = snapshot.title, let path = snapshot.playerPath, !path.isEmpty else { return .unavailable }
        if snapshot.rate == 0 { return .submitted }
        let item = MediaItemIdentity(source: player.source, title: title, identifier: snapshot.identifier ?? "", playerPath: path)
        return await playbackTransport(.init(item: item, action: .pause), true)
    }
    private func coverKey(source: String, title: String, identifier: String) -> String { source + "\n" + title + "\n" + identifier }
    private func rememberCover(_ image: NSImage) {
        guard let source else { return }
        if artworkCache.count >= 24 { artworkCache.removeAll(keepingCapacity: true) }
        artworkCache[coverKey(source: source, title: title, identifier: identifier)] = image
    }
    private(set) var seekSupported = false
    private(set) var scrubPosition: Double?
    private var scrubItem: MediaItemIdentity?
    private var scrubInvalidated = false
    private var scrubbing = false
    var holdingScrubber: Bool { scrubbing || scrubPosition != nil }
    private var identifier = ""
    private var playerPath = ""
    private(set) var commandPending = false
    @ObservationIgnored var snapshotReader: @Sendable () async -> SystemMediaSnapshot? = { await SystemMediaBridge.snapshot() }
    @ObservationIgnored var playbackTransport: @Sendable (MediaPlaybackRequest, Bool) async -> MediaCommandResult = { request, system in
        system ? await SystemMediaBridge.send(request) : await PlayerAutomation.command(request)
    }
    private var seekTask: Task<Void, Never>?
    @ObservationIgnored var seekTransport: @Sendable (MediaSeekRequest) async -> Bool = { await SystemMediaBridge.seek($0) }
    var canSeek: Bool { !selectionLoading && seekSupported && timeline?.usable == true && source != nil }
    private var itemIdentity: MediaItemIdentity? {
        source.map { MediaItemIdentity(source: $0, title: title, identifier: identifier, playerPath: playerPath) }
    }
    func previewSeek(_ position: Double) {
        guard canSeek, !scrubInvalidated, position.isFinite, let timeline else { return }
        if !scrubbing { beginScrub() }
        scrubPosition = min(timeline.duration, max(0, position))
    }
    func beginScrub() {
        guard canSeek, !scrubbing else { return }
        seekTask?.cancel(); seekTask = nil
        scrubbing = true; scrubInvalidated = false; scrubItem = itemIdentity
        scrubPosition = timeline?.elapsed(at: Date())
    }
    func cancelScrub() { scrubItem = nil; scrubPosition = nil; scrubbing = false; scrubInvalidated = false }
    private func invalidateScrub() {
        if scrubbing { scrubItem = nil; scrubPosition = nil; scrubInvalidated = true }
        else { cancelScrub() }
    }
    func commitSeek() {
        scrubbing = false
        guard !scrubInvalidated, scrubItem == itemIdentity,
              let position = scrubPosition,
              let request = MediaSeekRequest.make(item: itemIdentity, timeline: timeline, position: position, supported: canSeek) else { cancelScrub(); return }
        scrubItem = nil
        let currentGeneration = generation
        seekTask?.cancel()
        let transport = seekTransport
        seekTask = Task { [weak self] in
            let submitted = await transport(request)
            guard !Task.isCancelled, let self, self.generation == currentGeneration, self.itemIdentity == request.item else { return }
            if submitted {
                // Keep the thumb at the requested position while the player publishes its update.
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                let snapshot = if let player = self.pinnedPlayer { await self.playerReader(player) } else { await self.snapshotReader() }
                guard !Task.isCancelled, self.generation == currentGeneration, self.itemIdentity == request.item else { return }
                self.cancelScrub()
                if let snapshot { self.apply(snapshot) }
            } else {
                self.cancelScrub()
                self.message = "Seeking isn’t available in this player."
            }
        }
    }
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
                // Position is extrapolated locally; this only catches changes apps do not announce.
                try? await Task.sleep(for: .seconds(self?.playing == true ? 3 : 6))
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }
    func refresh() {
        guard !refreshing, !commandPending else { return }
        refreshing = true
        let currentGeneration = generation
        let selection = selectionRevision
        let chosen = pinnedPlayer
        let runningPlayers = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        updateTask = Task { [weak self] in
            guard let self else { return }
            if ProcessInfo.processInfo.systemUptime - self.discoveryTime >= 5 { await self.refreshPlayers() }
            let selected = chosen.flatMap { choice in self.players.first { $0.source == choice.source } ?? choice }
            let system = if let selected { await self.playerReader(selected) } else { await self.snapshotReader() }
            guard !Task.isCancelled, self.generation == currentGeneration, self.selectionRevision == selection else { return }
            self.selectionLoading = false
            self.systemAvailable = system?.available == true
            if system?.changing == true { self.refreshing = false; return }
            if let system, system.hasMedia {
                self.apply(system)
                self.refreshing = false
                self.loadArtworkIfNeeded(runningPlayers: runningPlayers)
                return
            }
            if let chosen {
                self.clearPlayback(); self.refreshing = false
                self.message = "\(chosen.name) isn’t publishing a media session. Choose Automatic or another player."
                return
            }
            let native = await PlayerAutomation.snapshot(runningPlayers: runningPlayers)
            guard !Task.isCancelled, self.generation == currentGeneration, self.selectionRevision == selection else { return }
            self.refreshing = false
            guard let native else {
                self.clearPlayback()
                self.message = self.systemAvailable ? "No media session is available." : "Player access unavailable. Check Automation access in System Settings."
                return
            }
            self.systemTransport = false; self.identifier = ""; self.playerPath = ""; self.timeline = nil; self.seekSupported = false; self.cancelScrub()
            self.title = native.title; self.artist = native.artist; self.playing = native.playing
            self.setSource(native.source.isEmpty ? nil : native.source, name: native.source == "com.spotify.client" ? "Spotify" : native.source == "com.apple.Music" ? "Music" : "Now Playing")
            self.artwork = native.artwork.flatMap { NSImage(data: $0) }; self.message = nil
        }
    }
    func apply(_ snapshot: SystemMediaSnapshot) {
        guard snapshot.hasMedia else { clearPlayback(); return }
        let nextSource = snapshot.source ?? "system.nowplaying"
        let nextTitle = snapshot.title ?? "Untitled media"
        let nextIdentifier = snapshot.identifier ?? ""
        let nextPath = snapshot.playerPath ?? ""
        if nextSource != source || nextTitle != title || nextIdentifier != identifier || nextPath != playerPath {
            seekTask?.cancel(); invalidateScrub()
        }
        let coverChanged = nextSource != source || nextTitle != title || nextIdentifier != identifier
        currentProcessID = snapshot.processID ?? 0
        identifier = nextIdentifier; playerPath = nextPath; seekSupported = snapshot.canSeek == true
        if !seekSupported { invalidateScrub() }
        if coverChanged { artwork = artworkCache[coverKey(source: nextSource, title: nextTitle, identifier: nextIdentifier)]; artworkTask?.cancel(); artworkKey = "" }
        systemTransport = true; title = nextTitle; artist = snapshot.artist ?? ""
        playing = (snapshot.rate ?? 0) > 0
        setSource(nextSource, name: [snapshot.sourceName, players.first(where: { $0.source == nextSource })?.name].compactMap { $0 }.first(where: { !$0.isEmpty }) ?? "Media")
        timeline = nil
        if let duration = snapshot.duration, let position = snapshot.position, let rate = snapshot.rate {
            let value = MediaTimeline(duration: duration, position: position, rate: rate, measuredAt: Date())
            if value.usable { timeline = value }
        }
        if let encoded = snapshot.artwork, let data = Data(base64Encoded: encoded), data.count < 2_000_000, let image = NSImage(data: data) { artwork = image; rememberCover(image) }
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
            if let data = result?.artwork, let image = NSImage(data: data) { self.artwork = image; self.rememberCover(image) }
        }
    }
    private func clearPlayback() {
        title = "Nothing playing"; artist = ""; setSource(nil, name: "Now Playing")
        seekTask?.cancel(); cancelScrub(); seekSupported = false; identifier = ""; playerPath = ""
        artwork = nil; timeline = nil; playing = false; systemTransport = false; artworkKey = ""
        artworkTask?.cancel()
    }
    func stop() {
        generation += 1
        sleepTimer.cancel(); selectionLoading = false
        updateTask?.cancel(); updateTask = nil; refreshing = false
        pollTask?.cancel(); pollTask = nil; artworkTask?.cancel(); commandTask?.cancel()
        observers.forEach { DistributedNotificationCenter.default().removeObserver($0) }; observers.removeAll()
        commandPending = false
        clearPlayback(); message = nil; systemAvailable = false
    }
    func openPlayer() {
        guard let source, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: source) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }
    func command(_ command: String) {
        guard !commandPending, !selectionLoading, let item = itemIdentity else { return }
        let action: MediaPlaybackAction
        switch command {
        case "playpause": action = playing ? .pause : .play
        case "next track": action = .next
        case "previous track": action = .previous
        default: return
        }
        let request = MediaPlaybackRequest(item: item, action: action)
        let usesSystem = systemTransport
        let currentGeneration = generation
        let transport = playbackTransport
        // Discard a read started before this click, rather than painting stale
        // playing/paused state over the command's eventual result.
        updateTask?.cancel(); refreshing = false
        commandPending = true
        commandTask = Task { [weak self] in
            let result = await transport(request, usesSystem)
            guard !Task.isCancelled, let self, self.generation == currentGeneration else { return }
            self.commandPending = false
            guard self.itemIdentity == item else { return }
            if result == .submitted {
                self.message = nil
                try? await Task.sleep(for: .milliseconds(250))
                if !Task.isCancelled { self.refresh() }
            } else {
                self.message = result.stale ? "The player changed. Try again on the current track." : "This player didn’t accept the command. Open it to control playback."
                if result.stale { self.refresh() }
            }
        }
    }
}
