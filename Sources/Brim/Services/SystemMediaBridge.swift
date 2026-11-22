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
    /// The app behind a helper process that publishes media on its behalf.
    var parentSource: String? = nil
    var hasMedia: Bool { available && !(title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }
    var isPlaying: Bool { hasMedia && (rate ?? 0) > 0 }
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
        let result = await ProcessRunner.run("/usr/bin/osascript", arguments: (javaScript ? ["-l", "JavaScript"] : []) + ["-e", script] + arguments, timeout: timeout)
        if !result.succeeded { Log.media.debug("Media script failed (status \(result.status), timed out: \(result.timedOut))") }
        return (result.text, result.succeeded)
    }
}

/// A line from the helper: an answer to the oldest waiting read, or one of its own announcements.
enum NowPlayingHelperLine: Equatable {
    case reply(String), listening, changed, ignored
    init(_ line: String) {
        switch line {
        case "listening": self = .listening
        case "changed": self = .changed
        case "": self = .ignored
        default: self = .reply(line)
        }
    }
}

/// One long-lived scripting process answers Now Playing reads over stdin/stdout, instead of a new
/// `osascript` launch per poll. Requests are answered in order. It also says when playback changes, so Brim
/// reads then instead of asking at all. A helper that hangs or quits comes back by itself, and a periodic
/// one-shot comparison stops trusting its answers if it ever disagrees.
final class NowPlayingHelper: @unchecked Sendable {
    static let shared = NowPlayingHelper()
    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var pending: [(id: Int, continuation: CheckedContinuation<String?, Never>)] = []
    private var nextID = 0
    private var served = 0
    /// Until when the helper's answers aren't used after failing its check. It keeps running for its announcements, so
    /// Brim still reads only when something changes, through a one-shot launch. Trusted again later: one bad moment
    /// shouldn't cost a scripting launch per change for as long as Brim runs.
    private var distrustedUntil: TimeInterval = 0
    static let distrustFor: TimeInterval = 1800
    private var trustedLocked: Bool { ProcessInfo.processInfo.systemUptime >= distrustedUntil }
    private var lastVerified: TimeInterval = -.infinity
    /// Bounds memory growth inside the scripting runtime.
    private let recycleAfter = 600
    private var listening = false
    private var changeHandler: (@Sendable () -> Void)?
    /// Brim is relying on the announcements, so a helper that quits or hangs is started again without being asked.
    private var keepAlive = false
    private var launchedAt: TimeInterval = 0
    private var quickExits = 0

    var trusted: Bool { lock.withLock { trustedLocked } }
    /// Already up and trusted with a request.
    var isRunning: Bool { lock.withLock { trustedLocked && process?.isRunning == true } }
    /// True while a running helper announces changes, so asking every few seconds isn't needed.
    var announcesChanges: Bool { lock.withLock { listening } }
    /// Called, off the main thread, when the helper sees playback change in any player.
    var onChange: (@Sendable () -> Void)? {
        get { lock.withLock { changeHandler } }
        set { lock.withLock { changeHandler = newValue } }
    }
    /// Starts over with a fresh process, used only for its announcements until it's trusted again.
    func distrust(reason: String) {
        Log.media.error("Now Playing helper answers not trusted: \(reason, privacy: .public)")
        let failed = lock.withLock { distrustedUntil = ProcessInfo.processInfo.systemUptime + Self.distrustFor; let failed = tearDownLocked(); relaunchLaterLocked(); return failed }
        failed.forEach { $0.resume(returning: nil) }
    }
    /// Keeps a helper up to announce changes while nothing asks it anything.
    func listen() { lock.withLock { _ = launchIfNeededLocked() } }
    /// Starts the helper now and keeps it up until `stop()`, so changes are announced with nothing asking every so often.
    func keepListening() { lock.withLock { keepAlive = true; _ = launchIfNeededLocked() } }
    /// One that keeps quitting right away waits longer each time, up to a minute.
    private func relaunchLaterLocked() {
        guard keepAlive else { return }
        quickExits = ProcessInfo.processInfo.systemUptime - launchedAt < 30 ? min(quickExits + 1, 6) : 0
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + min(60, Double(1 << quickExits))) { [weak self] in
            self?.lock.withLock { if self?.keepAlive == true { _ = self?.launchIfNeededLocked() } }
        }
    }
    /// True for a new helper's first answer, then every ten minutes: time to compare it against a fresh one-shot
    /// read. Each one-shot is a whole scripting launch, so this stays rare.
    static let verificationInterval: TimeInterval = 600
    func dueForVerification(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        lock.withLock {
            guard now - lastVerified >= Self.verificationInterval else { return false }
            lastVerified = now; return true
        }
    }
    func read(_ arguments: [String]) async -> String? {
        guard let line = try? JSONSerialization.data(withJSONObject: arguments) else { return nil }
        return await withCheckedContinuation { continuation in
            let id: Int? = lock.withLock {
                guard let input = launchIfNeededLocked() else { return nil }
                nextID += 1
                pending.append((nextID, continuation))
                do { try input.write(contentsOf: line + Data([0x0A])) } catch {
                    pending.removeLast(); return nil
                }
                return nextID
            }
            guard let id else { continuation.resume(returning: nil); return }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 4) { [weak self] in self?.expire(id) }
        }
    }
    private func expire(_ id: Int) {
        let failed: [CheckedContinuation<String?, Never>] = lock.withLock {
            guard pending.contains(where: { $0.id == id }) else { return [] }
            Log.media.notice("Now Playing helper didn’t answer in time; restarting it")
            let failed = tearDownLocked(); relaunchLaterLocked(); return failed
        }
        failed.forEach { $0.resume(returning: nil) }
    }
    private func launchIfNeededLocked() -> FileHandle? {
        if served >= recycleAfter, pending.isEmpty { _ = tearDownLocked() }
        if let process, process.isRunning, let input { return input }
        _ = tearDownLocked()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", SystemMediaBridge.serveScript]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = FileHandle.nullDevice
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil } else { self?.receive(chunk) }
        }
        process.terminationHandler = { [weak self] ended in self?.ended(ended) }
        do { try process.run() } catch {
            Log.media.error("Couldn’t start the Now Playing helper: \(error.localizedDescription, privacy: .public)")
            relaunchLaterLocked(); return nil
        }
        self.process = process; self.input = stdin.fileHandleForWriting; served = 0; buffer.removeAll(); lastVerified = -.infinity
        launchedAt = ProcessInfo.processInfo.systemUptime
        return input
    }
    private func receive(_ chunk: Data) {
        var replies: [(CheckedContinuation<String?, Never>, String)] = []
        var changed: (@Sendable () -> Void)?
        lock.withLock {
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...newline)
                switch NowPlayingHelperLine(line) {
                // A new helper missed whatever happened before it started, so it counts as a change too.
                case .listening: listening = true; changed = changeHandler
                case .changed: changed = changeHandler
                case .ignored: break
                case .reply(let text):
                    guard !pending.isEmpty else { continue }
                    served += 1
                    replies.append((pending.removeFirst().continuation, text))
                }
            }
        }
        replies.forEach { $0.0.resume(returning: $0.1) }
        changed?()
    }
    private func ended(_ process: Process) {
        let failed: [CheckedContinuation<String?, Never>] = lock.withLock {
            guard process === self.process else { return [] }
            let failed = tearDownLocked(); relaunchLaterLocked(); return failed
        }
        failed.forEach { $0.resume(returning: nil) }
    }
    /// Stops the helper and hands back every waiting request so the caller can fail them outside the lock.
    private func tearDownLocked() -> [CheckedContinuation<String?, Never>] {
        let waiting = pending.map(\.continuation)
        pending.removeAll()
        try? input?.close()
        if let process, process.isRunning { process.terminate() }
        process = nil; input = nil; buffer.removeAll(); listening = false
        return waiting
    }
    func stop() { let failed = lock.withLock { keepAlive = false; return tearDownLocked() }; failed.forEach { $0.resume(returning: nil) } }
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
        const result={available:true,title:scalar(info,k+'Title'),artist:scalar(info,k+'Artist'),source:scalar(path.client,'bundleIdentifier'),parentSource:scalar(path.client,'parentApplicationBundleIdentifier'),sourceName:scalar(path.client,'displayName'),
                      processID:Number(scalar(path.client,'processIdentifier')), playerPath:pathData(path),identifier:identity(info),rate:rate,duration:scalar(info,k+'Duration'),position:position,canSeek:false};
        try { const commands=value.commands; for(let i=0;i<commands.count;i++){const c=commands.objectAtIndex(i);if(Number(scalar(c,'command'))===24 && scalar(c,'enabled')===true)result.canSeek=true;} } catch(_){}
        try {const art=info.objectForKey(k+'ArtworkData');if(art && art.length>0 && art.length<2000000)result.artwork=ObjC.unwrap(art.base64EncodedStringWithOptions(0));}catch(_){}
        return result;
    }
    """#
    static let readFunction = #"""
    function readOnce(argv) {
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
    static let readScript = bootstrap + "ObjC.import('AppKit');" + playerFunctions + readFunction + "\nfunction run(argv) { return readOnce(argv); }"
    /// The helper: one JSON argument array per input line, one JSON snapshot per output line, in order. It also listens
    /// for MediaRemote's change notifications, which macOS delivers to this Apple tool but not to Brim, and writes
    /// `changed` once a burst of them settles, so Brim reads when something happens instead of asking every few seconds.
    /// `listening` on its first line says the notifications are on.
    static let serveScript = bootstrap + "ObjC.import('AppKit');" + playerFunctions + readFunction + commandFunction + seekFunction + #"""
    function run() {
        const input=$.NSFileHandle.fileHandleWithStandardInput, output=$.NSFileHandle.fileHandleWithStandardOutput;
        let buffer='', done=false, changedAt=0, announcedAt=0;
        function write(text) { output.writeData($(String(text).replace(/\n/g,' ')+'\n').dataUsingEncoding($.NSUTF8StringEncoding)); }
        function answer(data) {
            if (!data || Number(data.length)===0) { done=true; return; }
            buffer+=ObjC.unwrap($.NSString.alloc.initWithDataEncoding(data,$.NSUTF8StringEncoding));
            let index;
            while ((index=buffer.indexOf('\n'))>=0) {
                const line=buffer.slice(0,index); buffer=buffer.slice(index+1);
                // Let MediaRemote deliver any queued updates before answering.
                $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.01));
                let reply;
                try { const request=JSON.parse(line); reply=request[0]==='command'?sendCommand(request.slice(1)):request[0]==='seek'?sendSeek(request.slice(1)):readOnce(request); } catch(_) { reply=JSON.stringify({available:false}); }
                write(reply);
            }
        }
        ObjC.registerSubclass({name:'BrimNowPlayingHelper', methods:{'received:':{types:['void',['id']], implementation:function(note) {
            const name=String(ObjC.unwrap(note.name));
            if (name==='NSFileHandleReadCompletionNotification') {
                answer(note.userInfo.objectForKey('NSFileHandleNotificationDataItem'));
                if (!done) input.readInBackgroundAndNotify;
            } else if (!changedAt && /NowPlaying|IsPlaying|PlaybackState|ActivePlayer/.test(name)) {
                changedAt=Date.now();
            }
        }}}});
        $.NSNotificationCenter.defaultCenter.addObserverSelectorNameObject($.BrimNowPlayingHelper.alloc.init,'received:',$(),$());
        try {
            if (frameworkReady()) {
                ObjC.bindFunction('MRMediaRemoteRegisterForNowPlayingNotifications',['void',['id']]);
                $.MRMediaRemoteRegisterForNowPlayingNotifications($.NSOperationQueue.mainQueue.underlyingQueue);
                write('listening');
            }
        } catch(_) {}
        input.readInBackgroundAndNotify;
        // A change arrives as a burst of notifications: say so once it settles, and at most every 0.3 seconds.
        while (!done) {
            const now=Date.now();
            const wait=changedAt ? Math.max(10, changedAt+150-now, announcedAt+300-now) : 3600000;
            $.NSRunLoop.currentRunLoop.runModeBeforeDate($.NSDefaultRunLoopMode,$.NSDate.dateWithTimeIntervalSinceNow(wait/1000));
            const later=Date.now();
            if (changedAt && later-changedAt>=150 && later-announcedAt>=300) { write('changed'); changedAt=0; announcedAt=later; }
        }
        return '';
    }
    """#
    static let commandFunction = #"""
    function sendCommand(argv) {
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
    static let commandScript = bootstrap + "ObjC.import('AppKit');" + playerFunctions + commandFunction + "\nfunction run(argv) { return sendCommand(argv); }"
    /// Through the helper when it's up, so a click doesn't wait for a scripting launch. A helper that doesn't answer is
    /// a failure, never a reason to try again: the first attempt may have worked, and skipping twice is worse.
    private static func perform(_ tag: String, script: String, arguments: [String]) async -> (String, Bool) {
        let helper = NowPlayingHelper.shared
        guard helper.isRunning else { return await MediaScriptRunner.run(script, javaScript: true, arguments: arguments) }
        guard let reply = await helper.read([tag] + arguments) else { return ("", false) }
        return (reply, true)
    }
    static func send(_ request: MediaPlaybackRequest, validateOnly: Bool = false) async -> MediaCommandResult {
        let (result, success) = await perform("command", script: commandScript,
            arguments: [String(request.action.code), request.item.source, request.item.title, request.item.identifier,
                        request.item.playerPath, validateOnly ? "validate" : "send"])
        return success ? MediaCommandResult(rawValue: result) ?? .failed : .failed
    }
    static let seekFunction = #"""
    function sendSeek(argv) {
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
    static let seekScript = bootstrap + "ObjC.import('AppKit');" + playerFunctions + seekFunction + "\nfunction run(argv) { return sendSeek(argv); }"
    static func seek(_ request: MediaSeekRequest, validateOnly: Bool = false) async -> Bool {
        guard request.position.isFinite, request.position >= 0 else { return false }
        let (result, success) = await perform("seek", script: seekScript,
            arguments: [request.item.source, request.item.title, request.item.identifier, String(request.position), validateOnly ? "validate" : "send", request.item.playerPath])
        return success && result == (validateOnly ? "validated" : "submitted")
    }
    static func snapshot(for player: MediaPlayer) async -> SystemMediaSnapshot? {
        await read([player.source, String(player.processID)])
    }
    static func snapshot() async -> SystemMediaSnapshot? { await read([]) }
    private static func decode(_ text: String?) -> SystemMediaSnapshot? {
        guard let data = text?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SystemMediaSnapshot.self, from: data)
    }
    static func oneShotSnapshot(_ arguments: [String]) async -> SystemMediaSnapshot? {
        let (text, success) = await MediaScriptRunner.run(readScript, javaScript: true, arguments: arguments)
        return success ? decode(text) : nil
    }
    private static func read(_ arguments: [String]) async -> SystemMediaSnapshot? {
        let helper = NowPlayingHelper.shared
        guard helper.trusted else { helper.listen(); return await oneShotSnapshot(arguments) }
        guard let fromHelper = decode(await helper.read(arguments)) else { return await oneShotSnapshot(arguments) }
        guard helper.dueForVerification(), let fresh = await oneShotSnapshot(arguments), !agrees(fromHelper, fresh) else { return fromHelper }
        // Playback can change between the two reads, so one mismatch proves nothing: compare a second pair. Not trusting
        // the helper sends every later read through a scripting launch of its own.
        guard let again = decode(await helper.read(arguments)), let confirm = await oneShotSnapshot(arguments) else { return fresh }
        if agrees(again, confirm) { return again }
        helper.distrust(reason: "a long-lived read disagreed with a fresh one, twice")
        return confirm
    }
    /// The parts that would make the island show the wrong thing. Position naturally drifts between reads.
    static func agrees(_ a: SystemMediaSnapshot, _ b: SystemMediaSnapshot) -> Bool {
        a.available == b.available && a.title == b.title && a.source == b.source && a.identifier == b.identifier
            && ((a.rate ?? 0) > 0) == ((b.rate ?? 0) > 0)
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
