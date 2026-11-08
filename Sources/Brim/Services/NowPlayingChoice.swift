import AppKit

/// One player as the island weighs it.
struct NowPlayingCandidate: Equatable {
    var source: String?
    var playing: Bool
    /// A media app rather than a page in a browser.
    var app: Bool
    /// Music, a podcast, a book: a media app that's playing.
    var listening: Bool { playing && app }
    enum Pick: Equatable { case main, shown }
    /// The island shows what you're listening to, the way the iPhone's would on a Mac that can play two things at once.
    /// What's showing keeps the island while it plays; something newer takes over only if it ranks the same or higher,
    /// and a media app outranks a video in a browser. When everything pauses, what was showing stays as it was, so the
    /// island never swaps to another paused player on its way out.
    static func pick(main: Self, shown: Self?) -> Pick {
        guard let shown, shown.source != nil, shown.source != main.source else { return .main }
        if shown.playing { return main.playing && (main.app || !shown.app) ? .main : .shown }
        return main.playing ? .main : .shown
    }
}

/// Apps that open web links. Their media is a page in a tab, so a media app playing at the same time outranks it.
enum BrowserApps {
    @MainActor private static var known: Set<String>?
    @MainActor static func contains(_ bundle: String?) -> Bool {
        guard let bundle else { return false }
        // Safari and WebKit apps play through WebKit's own helper processes.
        if bundle.hasPrefix("com.apple.WebKit") { return true }
        if known == nil, let page = URL(string: "https://www.apple.com") {
            known = Set(NSWorkspace.shared.urlsForApplications(toOpen: page).compactMap { Bundle(url: $0)?.bundleIdentifier })
        }
        return known?.contains(bundle) == true
    }
}

/// Decides what the island shows while several players are going, and remembers what's showing between readings.
/// Another player is read directly only while it's on the island and playing, after it announced a change or was
/// clicked, or once when macOS's own reading changes; nothing extra runs while everything sits paused.
@MainActor final class NowPlayingChooser {
    /// What's on the island, which can differ from macOS's single Now Playing app (the last one to start).
    private(set) var shown: SystemMediaSnapshot?
    private var lastMain: NowPlayingCandidate?
    /// A player announced a change, or the island was clicked: what's showing is worth reading again.
    var checkShownAgain = false
    /// By process first: one app can publish from several.
    func shownPlayer(in players: [MediaPlayer]) -> MediaPlayer? {
        guard let item = shown else { return nil }
        return players.first { $0.source == item.source && $0.processID == item.processID } ?? players.first { $0.source == item.source }
    }
    func forget() { shown = nil; lastMain = nil; checkShownAgain = false }
    /// macOS names one Now Playing app; a Mac can play two things at once. See `NowPlayingCandidate.pick` for the rules.
    func choose(main: SystemMediaSnapshot, players: [MediaPlayer], isBrowser: (String?) -> Bool,
                read: (MediaPlayer) async -> SystemMediaSnapshot?) async -> SystemMediaSnapshot {
        func candidate(_ snapshot: SystemMediaSnapshot) -> NowPlayingCandidate {
            .init(source: snapshot.hasMedia ? snapshot.source : nil, playing: snapshot.isPlaying, app: !isBrowser(snapshot.parentSource ?? snapshot.source))
        }
        let mainCandidate = candidate(main)
        var lookElsewhere = mainCandidate != lastMain
        lastMain = mainCandidate
        let readAgain = checkShownAgain
        checkShownAgain = false
        if let current = shown, current.source != main.source {
            if let player = shownPlayer(in: players) {
                if current.isPlaying || readAgain {
                    var answer = await read(player)
                    // A player between tracks can answer with nothing for a moment, so it gets a second chance.
                    if answer?.hasMedia != true { try? await Task.sleep(for: .milliseconds(300)); answer = await read(player) }
                    if let answer, answer.hasMedia { shown = answer }
                    else { shown = nil; lastMain = nil; lookElsewhere = true } // Looked at again on the next reading too, should it come back.
                }
            } else { shown = nil }
        } else if main.hasMedia { shown = main }
        else if var current = shown, current.isPlaying {
            // The player has nothing to show any more, or for a moment between tracks: first treated as a pause, then gone.
            current.rate = 0; shown = current
        } else { shown = nil }
        // Music that was already going under a video, or before Brim started.
        if lookElsewhere, shown.map({ !candidate($0).listening }) ?? true, !mainCandidate.listening {
            for player in players where player.source != main.source && player.source != shown?.source && !isBrowser(player.source) {
                if let answer = await read(player), answer.isPlaying { shown = answer; break }
            }
        }
        guard let current = shown, NowPlayingCandidate.pick(main: mainCandidate, shown: candidate(current)) == .shown else {
            shown = main.hasMedia ? main : nil
            return main
        }
        return current
    }
}
