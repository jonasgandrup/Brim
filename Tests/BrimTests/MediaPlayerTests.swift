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
