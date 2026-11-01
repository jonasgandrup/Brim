import Foundation
import Testing
@testable import Brim

@Test func playbackProgressUsesRealRateAndNeverRunsPastDuration() {
    let date = Date(timeIntervalSince1970: 1000)
    let playing = MediaTimeline(duration: 200, position: 20, rate: 1.5, measuredAt: date)
    #expect(playing.elapsed(at: date.addingTimeInterval(10)) == 35)
    #expect(playing.elapsed(at: date.addingTimeInterval(1000)) == 200)
    #expect(playing.elapsed(at: date.addingTimeInterval(-10)) == 20)
    let paused = MediaTimeline(duration: 200, position: 20, rate: 0, measuredAt: date)
    #expect(paused.elapsed(at: date.addingTimeInterval(1000)) == 20)
    for invalid in [
        MediaTimeline(duration: 0, position: 0, rate: 1, measuredAt: date),
        MediaTimeline(duration: .infinity, position: 2, rate: 1, measuredAt: date),
        MediaTimeline(duration: 100, position: .nan, rate: 1, measuredAt: date),
        MediaTimeline(duration: 100, position: -1, rate: 1, measuredAt: date),
        MediaTimeline(duration: 100, position: 1, rate: -1, measuredAt: date)
    ] {
        #expect(!invalid.usable)
        #expect(invalid.elapsed(at: date) == 0)
    }
    #expect(MediaTimeline.label(65) == "1:05")
    #expect(MediaTimeline.label(3665) == "1:01:05")
    #expect(MediaTimeline.label(.nan) == "—")
}

@Test func nowPlayingDecoderHandlesEmptyAndUnavailableSessions() throws {
    for json in [#"{"available":true}"#, #"{"available":false,"title":"Old title"}"#, #"{"available":true,"title":"   "}"#] {
        let session = try JSONDecoder().decode(SystemMediaSnapshot.self, from: Data(json.utf8))
        #expect(!session.hasMedia)
    }
    let browser = try JSONDecoder().decode(SystemMediaSnapshot.self, from: Data(#"{"available":true,"title":"Browser video","source":"com.apple.Safari","sourceName":"Safari","rate":1,"position":10,"duration":300}"#.utf8))
    #expect(browser.hasMedia)
    #expect(browser.source == "com.apple.Safari")
    #expect(browser.artwork == nil)
}

@Test @MainActor func mediaSourceChangesClearOldArtworkAndUnknownProgress() {
    let media = MediaService()
    media.apply(.init(available: true, title: "A track", artist: "Artist", source: "com.spotify.client", sourceName: "Spotify", rate: 1, duration: 180, position: 45))
    #expect(media.playing)
    #expect(media.timeline?.position == 45)
    media.artwork = .init(size: .init(width: 8, height: 8))
    media.apply(.init(available: true, title: "A video", artist: nil, source: "com.apple.Safari", sourceName: "Safari", rate: 0))
    #expect(media.title == "A video")
    #expect(media.artist.isEmpty)
    #expect(!media.playing)
    #expect(media.source == "com.apple.Safari")
    #expect(media.sourceName == "Safari")
    #expect(media.artwork == nil)
    #expect(media.timeline == nil)
    media.apply(.init(available: false))
    #expect(media.source == nil)
    #expect(media.timeline == nil)
    #expect(!media.playing)
}

@Test func unknownMediaCommandsAreRejectedWithoutLaunchingAScript() async {
    let success = await SystemMediaBridge.command("invented", source: "test")
    #expect(!success)
}

@Test func seekRequestsClampAndRejectUnavailableTimelines() {
    let item = MediaItemIdentity(source: "test.player", title: "Track", identifier: "1")
    let timeline = MediaTimeline(duration: 200, position: 10, rate: 0, measuredAt: Date())
    #expect(MediaSeekRequest.make(item: item, timeline: timeline, position: -20, supported: true)?.position == 0)
    #expect(MediaSeekRequest.make(item: item, timeline: timeline, position: 999, supported: true)?.position == 200)
    #expect(MediaSeekRequest.make(item: item, timeline: timeline, position: .nan, supported: true) == nil)
    #expect(MediaSeekRequest.make(item: item, timeline: nil, position: 20, supported: true) == nil)
    #expect(MediaSeekRequest.make(item: nil, timeline: timeline, position: 20, supported: true) == nil)
    #expect(MediaSeekRequest.make(item: item, timeline: timeline, position: 20, supported: false) == nil)
}

private actor SeekRecorder {
    var requests: [MediaSeekRequest] = []
    func receive(_ request: MediaSeekRequest) -> Bool { requests.append(request); return false }
    var count: Int { requests.count }
    var lastPosition: Double? { requests.last?.position }
}

@Test @MainActor func scrubPreviewsLocallyAndCommitsOnceOnRelease() async {
    let media = MediaService()
    let recorder = SeekRecorder()
    media.seekTransport = { await recorder.receive($0) }
    media.apply(.init(available: true, title: "Track", source: "test.player", rate: 0, duration: 200, position: 10, identifier: "one", canSeek: true))
    #expect(media.canSeek)
    media.beginScrub(); media.previewSeek(50); media.previewSeek(80)
    #expect(media.scrubPosition == 80); #expect(await recorder.count == 0)
    media.commitSeek(); media.commitSeek()
    for _ in 0..<100 {
        if media.message != nil { break }
        try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(await recorder.count == 1); #expect(await recorder.lastPosition == 80)
    #expect(media.timeline?.position == 10)
    #expect(media.scrubPosition == nil)
    #expect(media.message != nil)
    media.stop()
}

@Test @MainActor func draggingCannotSeekANewTrackOrNewPlayer() async {
    let media = MediaService()
    let recorder = SeekRecorder()
    media.seekTransport = { await recorder.receive($0) }
    for (source, identifier) in [("test.player", "two"), ("other.player", "one")] {
        media.apply(.init(available: true, title: "Same title", source: "test.player", rate: 1, duration: 200, position: 10, identifier: "one", canSeek: true))
        media.beginScrub(); media.previewSeek(50)
        media.apply(.init(available: true, title: "Same title", source: source, rate: 1, duration: 200, position: 10, identifier: identifier, canSeek: true))
        media.previewSeek(100); media.commitSeek()
    }
    try? await Task.sleep(for: .milliseconds(30))
    #expect(await recorder.count == 0)
    #expect(media.scrubPosition == nil)
    media.stop()
}

@Test @MainActor func seekCapabilityDoesNotFollowPlayerChanges() {
    let media = MediaService()
    media.apply(.init(available: true, title: "Track", source: "test.player", rate: 1, duration: 100, position: 2, canSeek: true))
    #expect(media.canSeek)
    media.apply(.init(available: true, title: "Live stream", source: "other.player", rate: 1, canSeek: false))
    #expect(!media.canSeek)
    media.previewSeek(40); #expect(media.scrubPosition == nil)
}

private actor PlaybackRecorder {
    private(set) var requests: [MediaPlaybackRequest] = []
    private(set) var systemRoutes: [Bool] = []
    private(set) var players = ["player.a": true, "player.b": true]
    let result: MediaCommandResult
    init(result: MediaCommandResult) { self.result = result }
    func receive(_ request: MediaPlaybackRequest, system: Bool) async -> MediaCommandResult {
        requests.append(request); systemRoutes.append(system)
        try? await Task.sleep(for: .milliseconds(40))
        if result == .submitted, request.action == .pause { players[request.item.source] = false }
        return result
    }
}

@Test @MainActor func pauseAffectsOnlyTheCapturedPlayerDuringASourceHandoff() async {
    let recorder = PlaybackRecorder(result: .submitted)
    let media = MediaService()
    media.playbackTransport = { await recorder.receive($0, system: $1) }
    media.apply(.init(available: true, title: "Audio A", source: "player.a", rate: 1, playerPath: "session.a"))
    media.command("playpause")
    #expect(media.commandPending)
    // Repeated clicks during dispatch must not toggle or queue commands for another player.
    media.command("playpause")
    media.apply(.init(available: true, title: "Video B", source: "player.b", rate: 1, playerPath: "session.b"))
    for _ in 0..<100 {
        if !media.commandPending { break }
        try? await Task.sleep(for: .milliseconds(10))
    }
    let requests = await recorder.requests
    #expect(requests.count == 1)
    #expect(requests.first?.action == .pause)
    #expect(requests.first?.item.source == "player.a")
    #expect(requests.first?.item.playerPath == "session.a")
    let players = await recorder.players
    #expect(players["player.a"] == false)
    #expect(players["player.b"] == true)
    #expect(media.source == "player.b"); #expect(media.playing)
    #expect(!media.commandPending); #expect(media.message == nil)
    media.stop()
}

@Test @MainActor func failedSystemPauseNeverRetriesThroughAnotherAdapter() async {
    let recorder = PlaybackRecorder(result: .failed)
    let media = MediaService()
    media.playbackTransport = { await recorder.receive($0, system: $1) }
    media.apply(.init(available: true, title: "Track", source: "com.spotify.client", rate: 1, playerPath: "spotify.session"))
    media.command("playpause")
    for _ in 0..<100 {
        if !media.commandPending { break }
        try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(await recorder.requests.count == 1)
    #expect(await recorder.systemRoutes == [true])
    #expect(media.playing) // Failure must not manufacture a paused state.
    #expect(media.message != nil)
    #expect(!media.commandPending)
    media.stop()
}

@Test @MainActor func playIsExplicitAndDoesNotBecomeAToggle() async {
    let recorder = PlaybackRecorder(result: .failed)
    let media = MediaService()
    media.playbackTransport = { await recorder.receive($0, system: $1) }
    media.apply(.init(available: true, title: "Paused track", source: "player.a", rate: 0, playerPath: "session.a"))
    media.command("playpause")
    for _ in 0..<100 {
        if !media.commandPending { break }
        try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(await recorder.requests.first?.action == .play)
    #expect(!media.playing)
    media.stop()
}

@Test @MainActor func browserSessionHandoffsInvalidateAnInProgressSeek() async {
    let media = MediaService()
    media.apply(.init(available: true, title: "Same title", source: "browser", rate: 1, duration: 200, position: 10, identifier: "same", canSeek: true, playerPath: "tab.one"))
    media.beginScrub(); media.previewSeek(50)
    media.apply(.init(available: true, title: "Same title", source: "browser", rate: 1, duration: 200, position: 10, identifier: "same", canSeek: true, playerPath: "tab.two"))
    #expect(media.scrubPosition == nil)
    media.previewSeek(100); #expect(media.scrubPosition == nil)
    media.commitSeek(); media.stop()
}

@Test @MainActor func staleCommandRefreshesWithoutSendingAnotherPause() async {
    let recorder = PlaybackRecorder(result: .sourceChanged)
    let media = MediaService()
    media.playbackTransport = { await recorder.receive($0, system: $1) }
    media.snapshotReader = { .init(available: true, title: "Video B", source: "player.b", rate: 1, playerPath: "session.b") }
    media.apply(.init(available: true, title: "Audio A", source: "player.a", rate: 1, playerPath: "session.a"))
    media.command("playpause")
    for _ in 0..<100 {
        if media.source == "player.b" { break }
        try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(await recorder.requests.count == 1)
    #expect(media.source == "player.b"); #expect(media.playing)
    media.stop()
}
