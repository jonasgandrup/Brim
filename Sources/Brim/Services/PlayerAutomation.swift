import AppKit

/// What Music or Spotify said over Apple Events.
struct PlayerSnapshot: Sendable {
    let source: String
    let title: String
    let artist: String
    let playing: Bool
    let artwork: Data?
}

/// Music and Spotify over Apple Events: the fallback when macOS isn't sharing what's playing, and their covers.
enum PlayerAutomation {
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
    /// Which of the two scriptable players are open. Asked only right before talking to them: each running app's
    /// identifier is a round-trip to Launch Services, too much for a check that runs every few seconds.
    @MainActor static func runningPlayers() -> Set<String> {
        Set(["com.spotify.client", "com.apple.Music"].filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty })
    }
    nonisolated static func snapshot(runningPlayers: Set<String>) async -> PlayerSnapshot? {
        let artworkFile = FileManager.default.temporaryDirectory.appendingPathComponent("brim-art-\(UUID().uuidString)")
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
        guard fields.count == 5 else { return PlayerSnapshot(source: "", title: String(localized: "Nothing playing"), artist: "Music & Spotify", playing: false, artwork: nil) }
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
