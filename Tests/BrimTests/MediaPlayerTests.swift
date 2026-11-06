import AppKit
import Testing
@testable import Brim

private let playerA = MediaPlayer(source: "test.a", name: "Player A", processID: 111)
private let playerB = MediaPlayer(source: "test.b", name: "Player B", processID: 222)

private func session(_ player: MediaPlayer, title: String = "Track", rate: Double = 1) -> SystemMediaSnapshot {
    .init(available: true, title: title, source: player.source, sourceName: player.name, rate: rate, duration: 200, position: 10, identifier: title, canSeek: true, playerPath: player.id, processID: player.processID)
}

@MainActor private func settled(_ media: MediaService) async {
    for _ in 0..<100 {
        if !media.refreshing && !media.selectionLoading { break }
        try? await Task.sleep(for: .milliseconds(10))
    }
}

@Test @MainActor func pinnedPlayerIgnoresAnotherAppsGlobalSessionAndUnpins() async {
    let media = MediaService()
    media.playersReader = { [playerA, playerB] }
    media.snapshotReader = { session(playerB) }
    media.playerReader = { session($0) }
    media.selectPlayer(playerA); await settled(media)
    #expect(media.source == playerA.source); #expect(media.pinnedPlayer == playerA)
    media.refresh(); await settled(media)
    #expect(media.source == playerA.source)
    media.selectPlayer(nil); await settled(media)
    #expect(media.source == playerB.source); #expect(media.pinnedPlayer == nil)
    media.stop()
}

@Test @MainActor func closedPinnedPlayerDoesNotFallBackToAnotherApp() async {
    let media = MediaService()
    media.playersReader = { [playerB] }
    media.snapshotReader = { session(playerB) }
    media.playerReader = { _ in .init(available: true) }
    media.selectPlayer(playerA); await settled(media)
    #expect(media.pinnedPlayer == playerA)
    #expect(media.source == nil); #expect(media.message?.contains("Player A") == true)
    media.stop()
}

@Test @MainActor func rapidlySwitchingPinsDoesNotRestoreAnOldSelection() async {
    let media = MediaService()
    media.playersReader = { [playerA, playerB] }
    media.playerReader = { player in
        if player == playerA { try? await Task.sleep(for: .milliseconds(60)) }
        return session(player)
    }
    media.selectPlayer(playerA)
    await Task.yield()
    media.selectPlayer(playerB); await settled(media)
    try? await Task.sleep(for: .milliseconds(80))
    #expect(media.source == playerB.source); #expect(media.pinnedPlayer == playerB)
    #expect(!media.selectionLoading)
    media.stop()
}

@Test @MainActor func coversAreReusedWithoutAnAppIconFlash() {
    let media = MediaService()
    let image = NSImage(size: NSSize(width: 8, height: 8))
    image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 8, height: 8).fill(); image.unlockFocus()
    var first = session(playerA)
    first.artwork = image.tiffRepresentation?.base64EncodedString()
    media.apply(first)
    #expect(media.artwork != nil)
    media.apply(session(playerB)); #expect(media.artwork == nil)
    first.artwork = nil; media.apply(first)
    #expect(media.artwork != nil)
    media.apply(session(playerA, title: "Next track")); #expect(media.artwork == nil)
    media.stop()
}

@Test @MainActor func sleepTimerFiresOnceAtDeadlineAndCancellationStopsIt() async {
    let timer = MediaSleepTimer()
    var targets: [MediaPlayer] = []
    timer.pause = { targets.append($0); return .submitted }
    let now = Date()
    timer.start(minutes: 15, player: playerA, at: now)
    await timer.check(at: now.addingTimeInterval(899)); #expect(targets.isEmpty)
    await timer.check(at: now.addingTimeInterval(2000)) // Wake after expiry.
    await timer.check(at: now.addingTimeInterval(3000))
    #expect(targets == [playerA]); #expect(timer.schedule == nil)
    timer.start(minutes: 30, player: playerB, at: now); timer.cancel()
    await timer.check(at: now.addingTimeInterval(10000)); #expect(targets == [playerA])
}

private actor TimerCommands {
    private(set) var requests: [MediaPlaybackRequest] = []
    func send(_ request: MediaPlaybackRequest) -> MediaCommandResult { requests.append(request); return .submitted }
}

@Test @MainActor func nowPlayingStepsAsideOnlyWhileItsOwnAppIsInFront() {
    let media = MediaService()
    #expect(!media.stepsAside(forFrontApp: "com.spotify.client"))
    media.apply(.init(available: true, title: "Song", source: "com.spotify.client", rate: 1))
    #expect(media.stepsAside(forFrontApp: "com.spotify.client"))
    #expect(!media.stepsAside(forFrontApp: "com.apple.Safari"))
    #expect(!media.stepsAside(forFrontApp: nil))
    // A paused track still belongs to the app in front.
    media.apply(.init(available: true, title: "Song", source: "com.spotify.client", rate: 0))
    #expect(media.stepsAside(forFrontApp: "com.spotify.client"))
    media.apply(.init(available: true, title: "Video", source: "com.apple.WebKit.GPU", rate: 1, parentSource: "com.apple.Safari"))
    #expect(media.stepsAside(forFrontApp: "com.apple.Safari"))
    media.apply(.init(available: true, title: "Song", source: "com.spotify.client", rate: 1))
    #expect(!media.stepsAside(forFrontApp: "com.apple.Safari"))
    media.apply(.init(available: true))
    #expect(!media.stepsAside(forFrontApp: "com.spotify.client"))
    media.stop()
}

@Test @MainActor func mediaWithoutArtworkFallsBackToItsAppsIcon() {
    let media = MediaService()
    media.apply(.init(available: true, title: "Video", source: "com.apple.finder", rate: 1))
    #expect(media.artwork == nil && media.sourceIcon != nil)
    media.apply(.init(available: true, title: "Video", source: "test.not.installed", rate: 1))
    #expect(media.sourceIcon == nil)
    // A helper with no app of its own borrows the icon of the app behind it.
    media.apply(.init(available: true, title: "Video", source: "test.not.installed", rate: 1, parentSource: "com.apple.finder"))
    #expect(media.sourceIcon != nil)
    media.stop()
}

@Test func levelsStayQuietForVoiceOverWhileNoticesAreSpoken() {
    #expect(IslandHUD(symbol: "speaker.wave.2.fill", level: 0.5, label: "Volume").announcement == nil)
    #expect(IslandHUD(symbol: "wifi.slash", label: "Offline").announcement == "Offline")
    #expect(IslandHUD(symbol: "battery.25percent", label: "Battery low", battery: 15).announcement?.contains("15") == true)
    #expect(IslandHUD(symbol: "battery.25percent", label: "Battery low", battery: 15).announcement?.contains("Battery low") == true)
}

@Test @MainActor func aSleepTimerKeepsNowPlayingOnTheIslandInsideItsApp() {
    let media = MediaService()
    media.updatePlayers([playerA]); media.apply(session(playerA))
    #expect(media.stepsAside(forFrontApp: playerA.source))
    media.startSleepTimer(minutes: 15)
    #expect(!media.stepsAside(forFrontApp: playerA.source))
    media.sleepTimer.cancel()
    #expect(media.stepsAside(forFrontApp: playerA.source))
    media.stop()
}

@Test @MainActor func sleepTimerPausesItsOriginalPlayerAfterTheCardSwitches() async {
    let recorder = TimerCommands()
    let media = MediaService()
    media.playersReader = { [playerA, playerB] }
    media.playerReader = { session($0, title: "A later track") }
    media.playbackTransport = { request, _ in await recorder.send(request) }
    media.updatePlayers([playerA, playerB]); media.apply(session(playerA))
    media.startSleepTimer(minutes: 15)
    media.apply(session(playerB))
    await media.sleepTimer.check(at: Date().addingTimeInterval(901))
    let requests = await recorder.requests
    #expect(requests.count == 1); #expect(requests.first?.item.source == playerA.source)
    #expect(requests.first?.action == .pause)
    #expect(requests.first?.item.title == "A later track")
    #expect(media.source == playerB.source); #expect(media.playing)
    media.stop()
}

@Test @MainActor func sleepTimerRejectsAReplacedProcessAndAnAlreadyPausedPlayer() async {
    let recorder = TimerCommands()
    let media = MediaService()
    media.updatePlayers([playerA]); media.apply(session(playerA))
    media.playbackTransport = { request, _ in await recorder.send(request) }
    media.playerReader = { _ in session(.init(source: playerA.source, name: playerA.name, processID: 999)) }
    media.startSleepTimer(minutes: 15)
    await media.sleepTimer.check(at: Date().addingTimeInterval(901))
    #expect(await recorder.requests.isEmpty)
    #expect(media.sleepTimer.status?.contains("couldn’t") == true)
    media.playerReader = { session($0, rate: 0) }
    media.startSleepTimer(minutes: 15)
    await media.sleepTimer.check(at: Date().addingTimeInterval(901))
    #expect(await recorder.requests.isEmpty)
    media.stop()
}

@Test @MainActor func trackEndFollowsPausesAndSeekingAndFiresOnce() async {
    let timer = MediaSleepTimer()
    let date = Date()
    var sample = session(playerA)
    var paused: [String] = []
    timer.readTrack = { _ in sample }
    timer.pauseTrack = { paused.append($0.identifier ?? ""); return .submitted }
    timer.startAtTrackEnd(player: playerA, snapshot: sample, at: date)
    sample.position = 50; sample.rate = 0
    await timer.check(at: date.addingTimeInterval(190))
    #expect(timer.schedule?.endOfTrack == true); #expect(paused.isEmpty)
    sample.position = 198; sample.rate = 1
    await timer.check(at: date.addingTimeInterval(200))
    sample.position = 30 // Seeking backwards must not use the old deadline.
    await timer.check(at: date.addingTimeInterval(200.5))
    #expect(paused.isEmpty)
    sample.position = 200
    await timer.check(at: date.addingTimeInterval(201))
    await timer.check(at: date.addingTimeInterval(202))
    #expect(paused == ["Track"]); #expect(timer.schedule == nil)
    timer.cancel()
}

@Test @MainActor func trackEndCancelsManualSkipButPausesNaturalNextTrack() async {
    let timer = MediaSleepTimer()
    let date = Date()
    var sample = session(playerA)
    var paused = 0
    timer.readTrack = { _ in sample }
    timer.pauseTrack = { _ in paused += 1; return .submitted }
    timer.startAtTrackEnd(player: playerA, snapshot: sample, at: date)
    sample = session(playerA, title: "Skipped")
    await timer.check(at: date.addingTimeInterval(1))
    #expect(timer.schedule == nil); #expect(paused == 0)
    sample = session(playerA); sample.position = 199
    timer.startAtTrackEnd(player: playerA, snapshot: sample, at: date)
    sample = session(playerA, title: "Next"); sample.position = 0
    await timer.check(at: date.addingTimeInterval(1.1))
    #expect(paused == 1); #expect(timer.schedule == nil)
    timer.cancel()
}

@Test @MainActor func trackEndRejectsUnsupportedAndReplacedPlayers() async {
    let timer = MediaSleepTimer()
    let date = Date()
    var sample = session(playerA)
    sample.duration = nil
    timer.startAtTrackEnd(player: playerA, snapshot: sample)
    #expect(timer.schedule == nil)
    sample = session(playerA); sample.identifier = ""
    #expect(!MediaSleepTimer.supportsTrackEnd(sample))
    sample = session(playerA)
    timer.startAtTrackEnd(player: playerA, snapshot: sample, at: date)
    sample.processID = 999; sample.position = 200
    timer.readTrack = { _ in sample }
    var paused = false
    timer.pauseTrack = { _ in paused = true; return .submitted }
    for i in 1...3 { await timer.check(at: date.addingTimeInterval(Double(i))) }
    #expect(!paused); #expect(timer.schedule == nil)
    timer.cancel()
}

@Test @MainActor func cancellingTrackEndDuringAReadPreventsPlaybackCommands() async {
    let timer = MediaSleepTimer()
    var sample = session(playerA); sample.position = 199
    timer.startAtTrackEnd(player: playerA, snapshot: sample)
    timer.readTrack = { _ in
        timer.cancel()
        var ended = session(playerA); ended.position = 200
        return ended
    }
    var paused = false
    timer.pauseTrack = { _ in paused = true; return .submitted }
    await timer.check(at: Date().addingTimeInterval(2))
    #expect(!paused); #expect(timer.schedule == nil)
}

@Test @MainActor func trackEndRemainsBoundToOriginalPlayerWhenCardChanges() async {
    let recorder = TimerCommands()
    let media = MediaService()
    media.updatePlayers([playerA, playerB])
    var start = session(playerA); start.position = 199
    media.apply(start)
    media.playerReader = { player in var ended = session(player); ended.position = 200; return ended }
    media.playbackTransport = { request, _ in await recorder.send(request) }
    #expect(media.canSleepAtTrackEnd)
    media.startTrackEndSleepTimer()
    media.apply(session(playerB))
    await media.sleepTimer.check(at: Date().addingTimeInterval(2))
    let requests = await recorder.requests
    #expect(requests.count == 1)
    #expect(requests.first?.item.source == playerA.source)
    #expect(requests.first?.item.playerPath == playerA.id)
    #expect(requests.first?.action == .pause)
    #expect(media.source == playerB.source)
    media.stop()
}

// MARK: Following what's playing

/// macOS's Now Playing app, every player's own state, and which players were asked directly.
private actor PlaybackFeed {
    var main: SystemMediaSnapshot
    var rates: [String: Double]
    private(set) var asked: [String] = []
    init(main: SystemMediaSnapshot, rates: [String: Double]) { self.main = main; self.rates = rates }
    func set(main: SystemMediaSnapshot) { self.main = main }
    func set(_ player: MediaPlayer, rate: Double) { rates[player.source] = rate }
    func read(_ player: MediaPlayer) -> SystemMediaSnapshot? {
        asked.append(player.source)
        return rates[player.source].map { session(player, rate: $0) }
    }
    func clearAsked() { asked = [] }
}

@MainActor private func following(_ feed: PlaybackFeed) -> MediaService {
    let media = MediaService()
    media.playersReader = { [playerA, playerB] }
    media.snapshotReader = { await feed.main }
    media.playerReader = { await feed.read($0) }
    media.playbackTransport = { _, _ in .submitted }
    return media
}

@Test func theIslandShowsWhatYouAreListeningTo() {
    let spotify = NowPlayingCandidate(source: "spotify", playing: true, app: true)
    let video = NowPlayingCandidate(source: "chrome", playing: true, app: false)
    let pausedVideo = NowPlayingCandidate(source: "chrome", playing: false, app: false)
    let music = NowPlayingCandidate(source: "music", playing: true, app: true)
    // A video starting in a browser doesn't push music off the island, playing or paused.
    #expect(NowPlayingCandidate.pick(main: video, shown: spotify) == .shown)
    #expect(NowPlayingCandidate.pick(main: pausedVideo, shown: spotify) == .shown)
    // Music outranks a video that was showing; between two apps the newest wins.
    #expect(NowPlayingCandidate.pick(main: spotify, shown: video) == .main)
    #expect(NowPlayingCandidate.pick(main: music, shown: spotify) == .main)
    // Everything paused: what was showing stays, rather than swapping to another paused player.
    var pausedSpotify = spotify; pausedSpotify.playing = false
    #expect(NowPlayingCandidate.pick(main: pausedVideo, shown: pausedSpotify) == .shown)
    // Something playing beats anything paused.
    #expect(NowPlayingCandidate.pick(main: video, shown: pausedSpotify) == .main)
    #expect(NowPlayingCandidate.pick(main: video, shown: nil) == .main)
}

@Test @MainActor func aVideoPausingInTheBrowserLeavesTheMusicOnTheIsland() async {
    // Spotify (B) is playing; a YouTube video (A, in a browser) takes macOS's Now Playing and then pauses.
    let feed = PlaybackFeed(main: session(playerB, rate: 1), rates: [playerA.source: 1, playerB.source: 1])
    let media = following(feed)
    media.isBrowser = { $0 == playerA.source }
    media.refresh(); await settled(media)
    #expect(media.source == playerB.source)
    await feed.set(main: session(playerA, rate: 1))
    media.refresh(); await settled(media)
    #expect(media.source == playerB.source); #expect(media.playing)
    await feed.set(main: session(playerA, rate: 0)); await feed.set(playerA, rate: 0)
    media.refresh(); await settled(media)
    #expect(media.source == playerB.source); #expect(media.playing)
    media.stop()
}

@Test @MainActor func musicAlreadyPlayingUnderAVideoIsFoundOnce() async {
    let feed = PlaybackFeed(main: session(playerA, rate: 1), rates: [playerA.source: 1, playerB.source: 1])
    let media = following(feed)
    media.isBrowser = { $0 == playerA.source }
    media.refresh(); await settled(media)
    #expect(media.source == playerB.source)
    media.stop()
}

@Test @MainActor func pausingWhatsShowingNeverSwapsToAnotherPausedPlayer() async {
    // Spotify (B) is on the island; pausing it makes macOS hand Now Playing to a video that was already paused.
    let feed = PlaybackFeed(main: session(playerB, rate: 1), rates: [playerA.source: 0, playerB.source: 1])
    let media = following(feed)
    media.isBrowser = { $0 == playerA.source }
    media.refresh(); await settled(media)
    await feed.set(playerB, rate: 0); await feed.set(main: session(playerA, rate: 0))
    media.command("playpause"); await settled(media)
    try? await Task.sleep(for: .milliseconds(300)); await settled(media)
    #expect(media.source == playerB.source); #expect(!media.playing)
    // Held as it was: nothing more is read while everything sits paused.
    await feed.clearAsked()
    for _ in 0..<3 { media.refresh(); await settled(media) }
    #expect(await feed.asked.isEmpty); #expect(media.source == playerB.source)
    media.stop()
}

@Test @MainActor func nothingExtraIsReadWhileEverythingSitsPaused() async {
    let feed = PlaybackFeed(main: session(playerA, rate: 0), rates: [playerA.source: 0, playerB.source: 0])
    let media = following(feed)
    media.refresh(); await settled(media)
    #expect(media.source == playerA.source); #expect(!media.playing)
    await feed.clearAsked()
    for _ in 0..<3 { media.refresh(); await settled(media) }
    #expect(await feed.asked.isEmpty)
    media.stop()
}

@Test @MainActor func aNewTrackWaitsForItsCoverInsteadOfFlashingTheAppIcon() {
    let media = MediaService()
    let image = NSImage(size: NSSize(width: 8, height: 8))
    image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 8, height: 8).fill(); image.unlockFocus()
    var first = session(playerA)
    first.artwork = image.tiffRepresentation?.base64EncodedString()
    media.apply(first)
    media.apply(session(playerA, title: "Next track"))
    #expect(media.artwork == nil); #expect(media.coverOnItsWay)
    // No cover by the next reading: this player has none for it, so the app icon is right.
    media.apply(session(playerA, title: "Next track"))
    #expect(!media.coverOnItsWay)
    // A player that never had a cover shows its icon straight away.
    media.apply(session(playerB)); #expect(!media.coverOnItsWay)
    media.stop()
}

@Test func helperAnnouncementsAreToldApartFromAnswers() {
    #expect(NowPlayingHelperLine("listening") == .listening)
    #expect(NowPlayingHelperLine("changed") == .changed)
    // The script's own empty return value when it ends isn't an answer to anything.
    #expect(NowPlayingHelperLine("") == .ignored)
    #expect(NowPlayingHelperLine(#"{"available":true}"#) == .reply(#"{"available":true}"#))
}
