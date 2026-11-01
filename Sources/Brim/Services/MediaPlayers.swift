import AppKit
import Darwin

struct MediaPlayer: Identifiable, Codable, Equatable, Sendable {
    let source: String
    let name: String
    let processID: Int32
    var id: String { "\(source):\(processID)" }
}

private typealias ClientsReply = @convention(block) (NSArray?) -> Void
private typealias ReadClients = @convention(c) (UnsafeRawPointer, ClientsReply) -> Void

private final class DiscoveryCompletion: @unchecked Sendable {
    let continuation: CheckedContinuation<[MediaPlayer], Never>
    private let lock = NSLock()
    private var finished = false
    init(_ continuation: CheckedContinuation<[MediaPlayer], Never>) { self.continuation = continuation }
    func finish(_ players: [MediaPlayer]) {
        let deliver = lock.withLock { if finished { return false }; finished = true; return true }
        if deliver { continuation.resume(returning: players) }
    }
}

@MainActor enum MediaPlayerDiscovery {
    // Keep the image resident while asynchronous framework replies can be in flight.
    private static let framework = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY | RTLD_LOCAL)
    static func players() async -> [MediaPlayer] {
        guard let framework, let pointer = dlsym(framework, "MRMediaRemoteGetNowPlayingClients"),
              let queue = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_dispatch_main_q") else { return [] }
        return await withCheckedContinuation { continuation in
            let completion = DiscoveryCompletion(continuation)
            let reply: ClientsReply = { clients in
                // The explicit main dispatch queue owns these borrowed Objective-C objects.
                MainActor.assumeIsolated {
                    let values = clients?.compactMap { value -> MediaPlayer? in
                        guard let client = value as? NSObject,
                              let source = client.value(forKey: "bundleIdentifier") as? String,
                              let process = client.value(forKey: "processIdentifier") as? NSNumber,
                              !source.isEmpty, process.int32Value > 0,
                              let app = NSRunningApplication(processIdentifier: process.int32Value), !app.isTerminated else { return nil }
                        return MediaPlayer(source: source, name: app.localizedName ?? source, processID: process.int32Value)
                    } ?? []
                    var seen: Set<String> = []
                    completion.finish(values.filter { seen.insert($0.id).inserted }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
                }
            }
            unsafeBitCast(pointer, to: ReadClients.self)(UnsafeRawPointer(queue), reply)
            Task { try? await Task.sleep(for: .seconds(2)); completion.finish([]) }
        }
    }
}
