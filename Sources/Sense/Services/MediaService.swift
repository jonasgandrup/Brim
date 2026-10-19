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
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let output = Pipe(); let error = Pipe()
            process.standardOutput = output; process.standardError = error
            do {
                try process.run()
                let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15, execute: timeout)
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit(); timeout.cancel()
                return (String(data: data, encoding: .utf8)?.trimmingCharacters(in: .newlines) ?? "", process.terminationStatus == 0)
            } catch { return ("", false) }
        }.value
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

/// Public player automation and distributed player notifications; no private MediaRemote API.
@MainActor @Observable
final class MediaService {
    var title = "Nothing playing"
    var artist = "Music & Spotify"
    var playing = false
    var artwork: NSImage?
    var source: String?
    var message: String?
    var refreshing = false
    private var observers: [NSObjectProtocol] = []
    private var updateTask: Task<Void, Never>?
    func start() {
        guard observers.isEmpty else { return }
        for name in ["com.apple.Music.playerInfo", "com.spotify.client.PlaybackStateChanged"] {
            observers.append(DistributedNotificationCenter.default().addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        refresh()
    }
    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        let runningPlayers = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        updateTask = Task { [weak self] in
            let snapshot = await PlayerAutomation.snapshot(runningPlayers: runningPlayers)
            guard !Task.isCancelled, let self else { return }
            self.refreshing = false
            guard let snapshot else { self.title = "Player unavailable"; self.artist = "Check Automation permission"; self.playing = false; self.source = nil; self.artwork = nil; self.message = "Player access unavailable. Allow Sense in System Settings → Privacy & Security → Automation."; return }
            self.message = nil; self.title = snapshot.title; self.artist = snapshot.artist
            self.playing = snapshot.playing; self.source = snapshot.source.isEmpty ? nil : snapshot.source
            self.artwork = snapshot.artwork.flatMap { NSImage(data: $0) }
        }
    }
    func stop() {
        updateTask?.cancel(); updateTask = nil; refreshing = false
        observers.forEach { DistributedNotificationCenter.default().removeObserver($0) }; observers.removeAll()
        title = "Nothing playing"; artist = "Music & Spotify"; source = nil; artwork = nil; playing = false
    }
    func command(_ command: String) {
        guard let source, ["playpause", "next track", "previous track"].contains(command) else { return }
        Task {
            let (_, success) = await PlayerAutomation.run("tell application id \"\(source)\" to \(command)")
            message = success ? nil : "Allow Sense to control your player in System Settings → Privacy & Security → Automation."
            if success { refresh() }
        }
    }
}
