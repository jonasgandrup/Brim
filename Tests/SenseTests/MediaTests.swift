import Foundation
import Testing
@testable import Sense

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
