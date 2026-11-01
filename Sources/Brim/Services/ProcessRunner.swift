import Foundation

/// Runs a short-lived helper process without blocking a Swift concurrency thread.
/// Output is collected by a readability handler and completion arrives through the termination handler,
/// so a slow or hung child only costs its timeout, never a thread from the shared pool.
enum ProcessRunner {
    struct Result: Sendable {
        let output: Data
        let status: Int32
        let timedOut: Bool
        var succeeded: Bool { status == 0 && !timedOut }
        var text: String { String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var overflow = false
        private var continuation: CheckedContinuation<Result, Never>?
        private var finished = false
        private var timedOut = false
        private var reachedEnd = false
        private var exitStatus: Int32?
        let limit: Int
        init(limit: Int, continuation: CheckedContinuation<Result, Never>) { self.limit = limit; self.continuation = continuation }
        func append(_ chunk: Data) {
            lock.withLock {
                guard !overflow else { return }
                if data.count + chunk.count > limit { overflow = true; data.removeAll() } else { data.append(chunk) }
            }
        }
        func markTimedOut() { lock.withLock { timedOut = true } }
        /// Completes once both the pipe reached end-of-file and the process exited, so no output is lost.
        func endOfFile() { lock.withLock { reachedEnd = true }; deliverIfDone() }
        func exited(_ status: Int32) { lock.withLock { exitStatus = status }; deliverIfDone() }
        func forceFinish(status: Int32) { lock.withLock { reachedEnd = true; if exitStatus == nil { exitStatus = status } }; deliverIfDone() }
        private func deliverIfDone() {
            let delivery: (CheckedContinuation<Result, Never>, Result)? = lock.withLock {
                guard !finished, reachedEnd, let status = exitStatus, let continuation else { return nil }
                finished = true; self.continuation = nil
                return (continuation, Result(output: overflow ? Data() : data, status: overflow ? -1 : status, timedOut: timedOut))
            }
            if let (continuation, result) = delivery { continuation.resume(returning: result) }
        }
    }

    static func run(_ executable: String, arguments: [String], timeout: TimeInterval, outputLimit: Int = 4_000_000) async -> Result {
        await withCheckedContinuation { continuation in
            let collector = Collector(limit: outputLimit, continuation: continuation)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty { handle.readabilityHandler = nil; collector.endOfFile() } else { collector.append(chunk) }
            }
            process.terminationHandler = { finished in
                collector.exited(finished.terminationStatus)
                // A grandchild could keep the pipe open; don't wait on it forever.
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    collector.forceFinish(status: finished.terminationStatus)
                }
            }
            do { try process.run() } catch {
                Log.system.error("Couldn’t start \(executable, privacy: .public): \(error.localizedDescription, privacy: .public)")
                pipe.fileHandleForReading.readabilityHandler = nil
                collector.forceFinish(status: -1)
                return
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                collector.markTimedOut()
                Log.system.notice("\(executable, privacy: .public) timed out after \(timeout, privacy: .public) s")
                process.terminate()
            }
        }
    }
}
