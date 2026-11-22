import AppKit

/// System-wide compatibility feed with native Music/Spotify automation fallbacks.
@MainActor @Observable
final class MediaService {
    var title = String(localized: "Nothing playing")
    var artist = ""
    var playing = false
    var artwork: NSImage? { didSet { if artwork !== oldValue { artworkTint = ArtworkTint.rgb(of: artwork) } } }
    private(set) var artworkTint = ArtworkTint.RGB.standard
    /// The new track's cover is still coming. The tile stays empty meanwhile; the app icon is for players with no covers.
    private(set) var coverOnItsWay = false
    var source: String?
    private var parentSource: String?
    /// Like the iPhone: the app playing already shows its own controls, so the compact island stays quiet until you
    /// leave it. A sleep timer is Brim's own and the app can't show it, so it keeps media on the island.
    func stepsAside(forFrontApp app: String?) -> Bool {
        guard let app, source != nil, sleepTimer.schedule == nil else { return false }
        return app == source || app == parentSource
    }
    var sourceName = String(localized: "Now Playing")
    var sourceIcon: NSImage?
    var timeline: MediaTimeline?
    var message: String?
    var refreshing = false
    /// Music and Spotify over Apple Events, which makes macOS ask for Automation access. Off until someone agrees.
    var playerAccess = false {
        didSet { if playerAccess != oldValue, started { artworkKey = ""; refresh() } }
    }
    /// macOS isn't sharing what's playing, so Music and Spotify are the only way left.
    var offersPlayerAccess: Bool { !playerAccess && !systemAvailable && message != nil }
    /// Music or Spotify is playing without artwork, which only they can supply.
    var offersArtworkAccess: Bool { !playerAccess && artwork == nil && source.map { ["com.apple.Music", "com.spotify.client"].contains($0) } == true }
    let sleepTimer = MediaSleepTimer()
    private(set) var players: [MediaPlayer] = []
    private(set) var pinnedPlayer: MediaPlayer?
    private(set) var selectionLoading = false
    private var selectionRevision = 0
    private var discoveryTime: TimeInterval = -.infinity
    private let defaults: UserDefaults?
    @ObservationIgnored private var covers = MediaCoverCache()
    @ObservationIgnored var playerReader: @Sendable (MediaPlayer) async -> SystemMediaSnapshot? = { await SystemMediaBridge.snapshot(for: $0) }
    @ObservationIgnored var playersReader: @MainActor () async -> [MediaPlayer] = { await MediaPlayerDiscovery.players() }
    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? AppEnvironment.persistentDefaults
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
        pinnedPlayer = player; selectionRevision += 1; chooser.forget()
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
    private func rememberCover(_ image: NSImage) {
        guard let source else { return }
        covers.remember(image, source: source, title: title, identifier: identifier)
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
                let snapshot = if let player = self.pinnedPlayer ?? self.chooser.shownPlayer(in: self.players) { await self.playerReader(player) } else { await self.snapshotReader() }
                guard !Task.isCancelled, self.generation == currentGeneration, self.itemIdentity == request.item else { return }
                self.cancelScrub()
                if let snapshot { self.apply(snapshot) }
            } else {
                self.cancelScrub()
                self.message = String(localized: "Seeking isn’t available in this player.")
            }
        }
    }
    private(set) var systemAvailable = false
    private var systemTransport = false
    private var generation = 0
    private var observers: [NSObjectProtocol] = []
    private var updateTask: Task<Void, Never>?
    private var started = false
    private var artworkTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?
    private var artworkKey = ""
    func start() {
        guard !started else { return }
        started = true
        for name in ["com.apple.Music.playerInfo", "com.spotify.client.PlaybackStateChanged"] {
            observers.append(DistributedNotificationCenter.default().addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                // The player announced a change itself, so what's on the island is worth reading again.
                Task { @MainActor in self?.playbackChanged() }
            })
        }
        // Nothing asks what's playing on a timer: the helper announces every change, Music and Spotify announce their
        // own, and the position moves on locally. Waking up is the one moment worth a look of its own.
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            wakeObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.playbackChanged() }
            })
        }
        NowPlayingHelper.shared.onChange = { [weak self] in Task { @MainActor in self?.playbackChanged() } }
        NowPlayingHelper.shared.keepListening()
        refresh()
    }
    private var wakeObservers: [NSObjectProtocol] = []
    private var changeTask: Task<Void, Never>?
    /// Something changed: read now, or as soon as the read or command already under way is done.
    private func playbackChanged() {
        chooser.checkShownAgain = true
        sleepTimer.playbackChanged()
        guard changeTask == nil else { return }
        changeTask = Task { [weak self] in
            for _ in 0..<30 {
                guard let self, !Task.isCancelled else { return }
                if !self.refreshing && !self.commandPending { self.changeTask = nil; self.refresh(); return }
                try? await Task.sleep(for: .milliseconds(100))
            }
            self?.changeTask = nil
        }
    }
    func refresh() {
        guard !refreshing, !commandPending else { return }
        refreshing = true
        let currentGeneration = generation
        let selection = selectionRevision
        let chosen = pinnedPlayer
        updateTask = Task { [weak self] in
            guard let self else { return }
            if ProcessInfo.processInfo.systemUptime - self.discoveryTime >= 5 { await self.refreshPlayers() }
            let selected = chosen.flatMap { choice in self.players.first { $0.source == choice.source } ?? choice }
            var system = if let selected { await self.playerReader(selected) } else { await self.snapshotReader() }
            if selected == nil, let main = system, main.changing != true {
                system = await self.chooser.choose(main: main, players: self.players, isBrowser: self.isBrowser, read: self.playerReader)
            }
            guard !Task.isCancelled, self.generation == currentGeneration, self.selectionRevision == selection else { return }
            self.selectionLoading = false
            self.systemAvailable = system?.available == true
            if system?.changing == true { self.refreshing = false; return }
            if let system, system.hasMedia {
                self.apply(system)
                self.refreshing = false
                self.loadArtworkIfNeeded()
                return
            }
            if let chosen {
                self.clearPlayback(); self.refreshing = false
                self.message = String(localized: "\(chosen.name) isn’t publishing a media session. Choose Automatic or another player.")
                return
            }
            guard self.playerAccess else {
                self.clearPlayback(); self.refreshing = false
                self.message = self.systemAvailable ? nil : String(localized: "Now Playing isn’t available.")
                return
            }
            let known = self.artwork == nil ? nil : self.source.map { (source: $0, title: self.title) }
            let native = await PlayerAutomation.snapshot(runningPlayers: PlayerAutomation.runningPlayers(), coverAlreadyHeld: known)
            guard !Task.isCancelled, self.generation == currentGeneration, self.selectionRevision == selection else { return }
            self.refreshing = false
            guard let native else {
                self.clearPlayback()
                self.message = self.systemAvailable ? String(localized: "No media session is available.") : String(localized: "Player access unavailable. Check Automation access in System Settings.")
                return
            }
            self.systemTransport = false; self.identifier = ""; self.playerPath = ""; self.timeline = nil; self.seekSupported = false; self.cancelScrub()
            let sameTrack = native.title == self.title && native.source == self.source
            self.title = native.title; self.artist = native.artist; self.playing = native.playing
            self.setSource(native.source.isEmpty ? nil : native.source, name: native.source == "com.spotify.client" ? "Spotify" : native.source == "com.apple.Music" ? "Music" : String(localized: "Now Playing"))
            if let image = native.artwork.flatMap({ NSImage(data: $0) }) { self.artwork = image } else if !sameTrack { self.artwork = nil }
            self.message = nil
        }
    }
    // MARK: What the island shows

    private let chooser = NowPlayingChooser()
    @ObservationIgnored var isBrowser: @MainActor (String?) -> Bool = { BrowserApps.contains($0) }

    func apply(_ snapshot: SystemMediaSnapshot) {
        guard snapshot.hasMedia else { clearPlayback(); return }
        let nextSource = snapshot.source ?? "system.nowplaying"
        let nextTitle = snapshot.title ?? String(localized: "Untitled media")
        let nextIdentifier = snapshot.identifier ?? ""
        let nextPath = snapshot.playerPath ?? ""
        if nextSource != source || nextTitle != title || nextIdentifier != identifier || nextPath != playerPath {
            seekTask?.cancel(); invalidateScrub()
        }
        let coverChanged = nextSource != source || nextTitle != title || nextIdentifier != identifier
        let hadCover = artwork != nil && nextSource == source
        currentProcessID = snapshot.processID ?? 0
        identifier = nextIdentifier; playerPath = nextPath; seekSupported = snapshot.canSeek == true
        if !seekSupported { invalidateScrub() }
        if coverChanged { artwork = covers.cover(source: nextSource, title: nextTitle, identifier: nextIdentifier); artworkTask?.cancel(); artworkKey = "" }
        // A player that had a cover for the last track will have one for this: an empty tile waits for it, not the app icon.
        coverOnItsWay = coverChanged ? artwork == nil && hadCover : false
        systemTransport = true; title = nextTitle; artist = snapshot.artist ?? ""
        playing = (snapshot.rate ?? 0) > 0
        setSource(nextSource, name: [snapshot.sourceName, players.first(where: { $0.source == nextSource })?.name].compactMap { $0 }.first(where: { !$0.isEmpty }) ?? String(localized: "Media"), parent: snapshot.parentSource)
        timeline = nil
        if let duration = snapshot.duration, let position = snapshot.position, let rate = snapshot.rate {
            let value = MediaTimeline(duration: duration, position: position, rate: rate, measuredAt: Date())
            if value.usable { timeline = value }
        }
        // Sent with every reading; only worth decoding for a new track, or when there's no cover yet.
        if coverChanged || artwork == nil, let encoded = snapshot.artwork, let data = Data(base64Encoded: encoded), data.count < 2_000_000, let image = NSImage(data: data) { artwork = image; rememberCover(image) }
        message = nil
    }
    private func setSource(_ bundle: String?, name: String, parent: String? = nil) {
        if bundle != source || parent != parentSource {
            // A helper process has no icon of its own worth showing, so the app behind it speaks for it.
            sourceIcon = (parent ?? bundle).flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.map { NSWorkspace.shared.icon(forFile: $0.path) }
        }
        parentSource = parent
        source = bundle; sourceName = name
    }
    private func loadArtworkIfNeeded() {
        guard playerAccess, artwork == nil, let source, ["com.apple.Music", "com.spotify.client"].contains(source) else { return }
        let key = source + "\n" + title
        guard key != artworkKey else { return }
        artworkKey = key
        let expectedTitle = title
        let currentGeneration = generation
        artworkTask = Task { [weak self] in
            let result = await PlayerAutomation.snapshot(runningPlayers: PlayerAutomation.runningPlayers().intersection([source]))
            guard !Task.isCancelled, let self, self.generation == currentGeneration, self.source == source, self.title == expectedTitle,
                  result?.title == expectedTitle, result?.source == source else { return }
            if let data = result?.artwork, let image = NSImage(data: data) { self.artwork = image; self.rememberCover(image) }
        }
    }
    private func clearPlayback() {
        title = String(localized: "Nothing playing"); artist = ""; setSource(nil, name: String(localized: "Now Playing"))
        seekTask?.cancel(); cancelScrub(); seekSupported = false; identifier = ""; playerPath = ""
        artwork = nil; coverOnItsWay = false; timeline = nil; playing = false; systemTransport = false; artworkKey = ""
        artworkTask?.cancel()
    }
    func stop() {
        generation += 1
        sleepTimer.cancel(); selectionLoading = false
        updateTask?.cancel(); updateTask = nil; refreshing = false
        started = false; artworkTask?.cancel(); commandTask?.cancel()
        observers.forEach { DistributedNotificationCenter.default().removeObserver($0) }; observers.removeAll()
        wakeObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }; wakeObservers.removeAll()
        changeTask?.cancel(); changeTask = nil
        NowPlayingHelper.shared.onChange = nil; NowPlayingHelper.shared.stop()
        commandPending = false; chooser.forget()
        clearPlayback(); message = nil; systemAvailable = false
    }
    func openPlayer() {
        guard let app = parentSource ?? source, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) else { return }
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
        // A paused player on the island isn't read again on its own; this click is worth a look.
        chooser.checkShownAgain = true
        let usesSystem = systemTransport
        let currentGeneration = generation
        let transport = playbackTransport
        // Discard a read started before this click, rather than painting stale
        // playing/paused state over the command's eventual result.
        updateTask?.cancel(); refreshing = false
        commandTask?.cancel()
        commandPending = true
        commandTask = Task { [weak self] in
            let result = await transport(request, usesSystem)
            guard !Task.isCancelled, let self, self.generation == currentGeneration else { return }
            self.commandPending = false
            guard self.itemIdentity == item else { return }
            if result == .submitted {
                self.message = nil
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                self.refresh()
                if action == .play || action == .pause { await self.noticeIfIgnored(action, by: item, generation: currentGeneration) }
            } else {
                self.message = result.stale ? String(localized: "The player changed. Try again on the current track.") : String(localized: "This player didn’t accept the command. Open it to control playback.")
                if result.stale { self.refresh() }
            }
        }
    }
    /// A player can take a command and do nothing with it. Chrome does that for a background tab it has put to sleep,
    /// and leaves the media keys unanswered too, so say so rather than leave the button looking broken.
    private func noticeIfIgnored(_ action: MediaPlaybackAction, by item: MediaItemIdentity, generation expected: Int) async {
        let wanted = action == .play
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, generation == expected, source == item.source, playing != wanted else { return }
        }
        for _ in 0..<10 where refreshing || commandPending { try? await Task.sleep(for: .milliseconds(100)) }
        guard !Task.isCancelled, generation == expected, source == item.source, playing != wanted, !refreshing, !commandPending else { return }
        message = String(localized: "\(sourceName) didn’t respond. Open it to control playback.")
    }
}
