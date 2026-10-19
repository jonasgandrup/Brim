import Foundation

/// The current macOS Now Playing feed is not a public API. Keep compatibility access
/// isolated in a short-lived scripting process; failure leaves the native adapters usable.
struct SystemMediaSnapshot: Decodable, Sendable {
    var available: Bool
    var title: String?
    var artist: String?
    var source: String?
    var sourceName: String?
    var rate: Double?
    var duration: Double?
    var position: Double?
    var artwork: String?
    var hasMedia: Bool { available && !(title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }
}

struct MediaTimeline: Sendable {
    let duration: TimeInterval
    let position: TimeInterval
    let rate: Double
    let measuredAt: Date
    var usable: Bool { duration.isFinite && duration > 0 && position.isFinite && position >= 0 && rate.isFinite && rate >= 0 }
    func elapsed(at date: Date) -> TimeInterval {
        guard usable else { return 0 }
        return min(duration, max(0, position + max(0, date.timeIntervalSince(measuredAt)) * rate))
    }
    static func label(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "—" }
        let value = Int(min(864000, max(0, seconds)))
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) : String(format: "%d:%02d", value / 60, value % 60)
    }
}

enum MediaScriptRunner {
    static func run(_ script: String, javaScript: Bool = false, arguments: [String] = [], timeout: TimeInterval = 4) async -> (String, Bool) {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = (javaScript ? ["-l", "JavaScript"] : []) + ["-e", script] + arguments
            let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                let limit = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: limit)
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit(); limit.cancel()
                guard data.count < 4_000_000 else { return ("", false) }
                return (String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", process.terminationStatus == 0)
            } catch { return ("", false) }
        }.value
    }
}

enum SystemMediaBridge {
    static let bootstrap = #"""
    ObjC.import('Foundation');
    function scalar(object, key) {
        try { const value = ObjC.unwrap(object.valueForKey(key)); return value === undefined ? null : value; }
        catch (_) { return null; }
    }
    function frameworkReady() {
        const bundle = $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework');
        return !!bundle.load && !!$.NSClassFromString('MRNowPlayingRequest');
    }
    """#
    static let readScript = bootstrap + #"""
    function run() {
        if (!frameworkReady()) return JSON.stringify({available:false});
        try {
            const request = $.NSClassFromString('MRNowPlayingRequest');
            const item = request.localNowPlayingItem;
            const client = request.localNowPlayingPlayerPath.client;
            const info = item.nowPlayingInfo;
            const key = 'kMRMediaRemoteNowPlayingInfo';
            let rate = scalar(info, key + 'PlaybackRate');
            if (rate === null) rate = scalar(item.metadata, 'playbackRate');
            let position = scalar(info, key + 'ElapsedTime');
            const timestamp = scalar(info, key + 'Timestamp');
            // The metadata helper can keep advancing after pause. Prefer the published
            // position plus its real rate and timestamp; a paused session stays fixed.
            if (position !== null && rate > 0 && timestamp && typeof timestamp.getTime === 'function') {
                position += Math.max(0, (Date.now() - timestamp.getTime()) / 1000) * rate;
            } else if (position === null && rate > 0) {
                position = scalar(item.metadata, 'calculatedPlaybackPosition');
            }
            const result = {
                available:true, title:scalar(info,key+'Title'), artist:scalar(info,key+'Artist'),
                source:scalar(client,'bundleIdentifier'), sourceName:scalar(client,'displayName'),
                rate:rate, duration:scalar(info,key+'Duration'), position:position
            };
            try {
                const art = info.objectForKey(key+'ArtworkData');
                if (art && art.length > 0 && art.length < 2000000) result.artwork = ObjC.unwrap(art.base64EncodedStringWithOptions(0));
            } catch (_) {}
            return JSON.stringify(result);
        } catch (_) { return JSON.stringify({available:false}); }
    }
    """#
    static let commandScript = bootstrap + #"""
    function run(argv) {
        if (!frameworkReady()) return 'unavailable';
        const command = Number(argv[0]);
        if ([0,1,2,4,5].indexOf(command) < 0) return 'unsupported';
        const request = $.NSClassFromString('MRNowPlayingRequest');
        const source = scalar(request.localNowPlayingPlayerPath.client,'bundleIdentifier') || 'system.nowplaying';
        if (source !== argv[1]) return 'source-changed';
        const controller = $.NSClassFromString('MRNowPlayingController').localRouteController;
        controller.sendCommandOptionsCompletion(command, $.NSDictionary.dictionary, null);
        return 'submitted';
    }
    """#
    static func snapshot() async -> SystemMediaSnapshot? {
        let (text, success) = await MediaScriptRunner.run(readScript, javaScript: true)
        guard success, let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SystemMediaSnapshot.self, from: data)
    }
    static func command(_ command: String, source: String) async -> Bool {
        let commands = ["playpause": 2, "next track": 4, "previous track": 5]
        guard let code = commands[command] else { return false }
        let (result, success) = await MediaScriptRunner.run(commandScript, javaScript: true, arguments: [String(code), source])
        return success && result == "submitted"
    }
}
