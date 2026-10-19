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
    var identifier: String? = nil
    var canSeek: Bool? = nil
    var playerPath: String? = nil
    var changing: Bool? = nil
    var processID: Int32? = nil
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
    function pathData(path) {
        try { return ObjC.unwrap(path.data.base64EncodedStringWithOptions(0)); } catch (_) { return ''; }
    }
    function itemMatches(info, title, identifier) {
        const key = 'kMRMediaRemoteNowPlayingInfo';
        return String(scalar(info,key+'Title') || '') === title &&
            String(scalar(info,key+'UniqueIdentifier') || scalar(info,key+'ContentItemIdentifier') || '') === identifier;
    }
    function targetedController(path) {
        const request = $.NSClassFromString('MRNowPlayingRequest').alloc.initWithPlayerPath(path);
        const controller = $.NSClassFromString('MRNowPlayingController').alloc.initWithDestination(request.destination);
        // Never fall back to the route controller if this runtime cannot bind a player.
        if (!controller.playerPath.isEqual(path)) return null;
        return controller;
    }
    function frameworkReady() {
        const bundle = $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework');
        return !!bundle.load && !!$.NSClassFromString('MRNowPlayingRequest');
    }
    """#
    static let playerFunctions = #"""
    function identity(info) {
        const k = 'kMRMediaRemoteNowPlayingInfo';
        return String(scalar(info,k+'ContentItemIdentifier') || scalar(info,k+'UniqueIdentifier') || '');
    }
    function pathFromData(encoded) {
        const data = $.NSData.alloc.initWithBase64EncodedStringOptions(encoded,0);
        return $.NSClassFromString('MRPlayerPath').alloc.initWithData(data);
    }
    function bound(path) {
        const source = String(scalar(path.client,'bundleIdentifier') || '');
        const pid = Number(scalar(path.client,'processIdentifier'));
        const app = $.NSRunningApplication.runningApplicationWithProcessIdentifier(pid);
        if (!app || !app.bundleIdentifier || ObjC.unwrap(app.bundleIdentifier) !== source || app.terminated) return null;
        const request = $.NSClassFromString('MRNowPlayingRequest');
        if (request.localNowPlayingPlayerPath.isEqual(path)) {
            return {path:path, info:request.localNowPlayingItem.nowPlayingInfo, commands:request.localSupportedCommands, close:function(){}};
        }
        const controller = targetedController(path);
        if (!controller) return null;
        controller.beginLoadingUpdates;
        const end = Date.now()+700;
        let response, info;
        do {
            $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.025));
            response = controller.response;
            try { info = response.playbackQueue.nowPlayingInfo; if (scalar(info,'kMRMediaRemoteNowPlayingInfoTitle')) break; } catch (_) {}
        } while (Date.now()<end);
        if (!response || !info) { controller.endLoadingUpdates; return null; }
        return {path:response.playerPath, info:info, commands:response.supportedCommands,
                rate:scalar(response,'playbackRate'), close:function(){controller.endLoadingUpdates;}};
    }
    function snapshotFrom(value) {
        const path=value.path, info=value.info, k='kMRMediaRemoteNowPlayingInfo';
        let rate=scalar(info,k+'PlaybackRate');
        if (rate===null) rate=value.rate;
        if (rate===undefined || rate===null) rate=0;
        let position=scalar(info,k+'ElapsedTime');
        const timestamp=scalar(info,k+'Timestamp');
        if (position!==null && rate>0 && timestamp && typeof timestamp.getTime==='function') position+=Math.max(0,(Date.now()-timestamp.getTime())/1000)*rate;
        const result={available:true,title:scalar(info,k+'Title'),artist:scalar(info,k+'Artist'),source:scalar(path.client,'bundleIdentifier'),sourceName:scalar(path.client,'displayName'),
                      processID:Number(scalar(path.client,'processIdentifier')), playerPath:pathData(path),identifier:identity(info),rate:rate,duration:scalar(info,k+'Duration'),position:position,canSeek:false};
        try { const commands=value.commands; for(let i=0;i<commands.count;i++){const c=commands.objectAtIndex(i);if(Number(scalar(c,'command'))===24 && scalar(c,'enabled')===true)result.canSeek=true;} } catch(_){}
        try {const art=info.objectForKey(k+'ArtworkData');if(art && art.length>0 && art.length<2000000)result.artwork=ObjC.unwrap(art.base64EncodedStringWithOptions(0));}catch(_){}
        return result;
    }
    """#
    static let readScript = bootstrap + "ObjC.import('AppKit');" + playerFunctions + #"""
    function run(argv) {
        if (!frameworkReady()) return JSON.stringify({available:false});
        let value;
        try {
            const request=$.NSClassFromString('MRNowPlayingRequest');
            if (argv.length>=2) {
                const app=$.NSRunningApplication.runningApplicationWithProcessIdentifier(Number(argv[1]));
                if (!app || !app.bundleIdentifier || ObjC.unwrap(app.bundleIdentifier)!==argv[0] || app.terminated) return JSON.stringify({available:true});
                const client=$.NSClassFromString('MRClient').alloc.initWithProcessIdentifierBundleIdentifier(Number(argv[1]),argv[0]);
                const path=$.NSClassFromString('MRPlayerPath').alloc.initWithOriginClientPlayer(request.localNowPlayingPlayerPath.origin,client,$());
                value=bound(path);
            } else {
                const path=request.localNowPlayingPlayerPath;
                const item=request.localNowPlayingItem;
                if (!path.isEqual(request.localNowPlayingPlayerPath)) return JSON.stringify({available:true,changing:true});
                value={path:path,info:item.nowPlayingInfo,commands:request.localSupportedCommands,rate:scalar(item.metadata,'playbackRate'),close:function(){}};
            }
            return JSON.stringify(value ? snapshotFrom(value) : {available:true});
        } catch(_){return JSON.stringify({available:false});}
        finally {if(value)value.close();}
    }
    """#
    static let commandScript = bootstrap + "ObjC.import('AppKit');" + playerFunctions + #"""
    function run(argv) {
        if(!frameworkReady())return 'unavailable';
        const command=Number(argv[0]);
        if([0,1,4,5].indexOf(command)<0)return 'unsupported';
        if(!argv[4])return 'item-changed';
        let value;
        try {
            const path=pathFromData(argv[4]);
            if(String(scalar(path.client,'bundleIdentifier'))!==argv[1])return 'source-changed';
            value=bound(path);
            if(!value)return 'unavailable';
            if(!value.path.isEqual(path) || String(scalar(value.info,'kMRMediaRemoteNowPlayingInfoTitle') || '')!==argv[2] || identity(value.info)!==argv[3])return 'item-changed';
            const controller=targetedController(path);
            if(!controller)return 'unavailable';
            if(argv[5]==='validate')return 'validated';
            controller.sendCommandOptionsCompletion(command,$.NSDictionary.dictionary,null);
            return 'submitted';
        } catch(_){return 'failed';} finally {if(value)value.close();}
    }
    """#
    static func send(_ request: MediaPlaybackRequest, validateOnly: Bool = false) async -> MediaCommandResult {
        let (result, success) = await MediaScriptRunner.run(commandScript, javaScript: true,
            arguments: [String(request.action.code), request.item.source, request.item.title, request.item.identifier,
                        request.item.playerPath, validateOnly ? "validate" : "send"])
        return success ? MediaCommandResult(rawValue: result) ?? .failed : .failed
    }
    static let seekScript = bootstrap + "ObjC.import('AppKit');" + playerFunctions + #"""
    function run(argv) {
        if(!frameworkReady())return 'unavailable';
        if(!argv[5])return 'item-changed';
        let value;
        try {
            const path=pathFromData(argv[5]);
            if(String(scalar(path.client,'bundleIdentifier'))!==argv[0])return 'source-changed';
            value=bound(path);
            if(!value)return 'unavailable';
            if(!value.path.isEqual(path) || String(scalar(value.info,'kMRMediaRemoteNowPlayingInfoTitle') || '')!==argv[1] || identity(value.info)!==argv[2])return 'item-changed';
            const duration=Number(scalar(value.info,'kMRMediaRemoteNowPlayingInfoDuration')),position=Number(argv[3]);
            if(!Number.isFinite(duration)||duration<=0||!Number.isFinite(position)||position<0||position>duration)return 'invalid';
            let supported=false;const commands=value.commands;
            for(let i=0;i<commands.count;i++){const c=commands.objectAtIndex(i);if(Number(scalar(c,'command'))===24&&scalar(c,'enabled')===true)supported=true;}
            if(!supported)return 'unsupported';
            const controller=targetedController(path);if(!controller)return 'unavailable';
            const options=$.NSDictionary.dictionaryWithObjectForKey($.NSNumber.numberWithDouble(position),'kMRMediaRemoteOptionPlaybackPosition');
            if(argv[4]==='validate')return 'validated';
            controller.sendCommandOptionsCompletion(24,options,null);return 'submitted';
        }catch(_){return 'failed';}finally{if(value)value.close();}
    }
    """#
    static func seek(_ request: MediaSeekRequest, validateOnly: Bool = false) async -> Bool {
        guard request.position.isFinite, request.position >= 0 else { return false }
        let (result, success) = await MediaScriptRunner.run(seekScript, javaScript: true,
            arguments: [request.item.source, request.item.title, request.item.identifier, String(request.position), validateOnly ? "validate" : "send", request.item.playerPath])
        return success && result == (validateOnly ? "validated" : "submitted")
    }
    static func snapshot(for player: MediaPlayer) async -> SystemMediaSnapshot? {
        let (text, success) = await MediaScriptRunner.run(readScript, javaScript: true, arguments: [player.source, String(player.processID)])
        guard success, let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SystemMediaSnapshot.self, from: data)
    }
    static func snapshot() async -> SystemMediaSnapshot? {
        let (text, success) = await MediaScriptRunner.run(readScript, javaScript: true)
        guard success, let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SystemMediaSnapshot.self, from: data)
    }
    static func command(_ command: String, source: String) async -> Bool {
        guard ["playpause", "next track", "previous track"].contains(command),
              let snapshot = await snapshot(), snapshot.hasMedia, snapshot.source == source else { return false }
        let action: MediaPlaybackAction = command == "playpause" ? ((snapshot.rate ?? 0) > 0 ? .pause : .play) : command == "next track" ? .next : .previous
        let item = MediaItemIdentity(source: source, title: snapshot.title ?? "", identifier: snapshot.identifier ?? "", playerPath: snapshot.playerPath ?? "")
        return await send(.init(item: item, action: action)) == .submitted
    }
}

struct MediaItemIdentity: Equatable, Sendable {
    let source: String
    let title: String
    let identifier: String
    var playerPath: String = ""
}

struct MediaSeekRequest: Sendable {
    let item: MediaItemIdentity
    let position: Double
    static func make(item: MediaItemIdentity?, timeline: MediaTimeline?, position: Double, supported: Bool) -> Self? {
        guard supported, let item, let timeline, timeline.usable, position.isFinite else { return nil }
        return Self(item: item, position: min(timeline.duration, max(0, position)))
    }
}

enum MediaPlaybackAction: String, Sendable {
    case play, pause, next, previous
    var code: Int { switch self { case .play: 0; case .pause: 1; case .next: 4; case .previous: 5 } }
    var appleScript: String { switch self { case .play: "play"; case .pause: "pause"; case .next: "next track"; case .previous: "previous track" } }
}
struct MediaPlaybackRequest: Sendable {
    let item: MediaItemIdentity
    let action: MediaPlaybackAction
}
enum MediaCommandResult: String, Sendable {
    case submitted, validated, unavailable, unsupported, failed
    case sourceChanged = "source-changed", itemChanged = "item-changed"
    var stale: Bool { self == .sourceChanged || self == .itemChanged }
}
