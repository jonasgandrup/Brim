import Foundation
import Observation

/// A Live Activity started from Shortcuts or a script with a `sense://activity` link: a title, a symbol and,
/// when the caller reports it, how far along it is. Sense never guesses progress.
struct ScriptActivity: Identifiable, Equatable {
    let id: String
    var title: String
    var symbol: String
    var progress: Double?
    var updated: Date
}

@MainActor @Observable final class ScriptActivities {
    private(set) var running: [ScriptActivity] = []
    @ObservationIgnored var onFinish: (ScriptActivity) -> Void = { _ in }
    static let limit = 4
    /// A caller that stops reporting (a script that crashed) doesn't leave a ring behind forever.
    static let staleAfter: TimeInterval = 15 * 60
    private var sweepTask: Task<Void, Never>?

    /// Starts or updates an activity. A progress of 1 finishes it.
    func update(id: String, title: String?, symbol: String?, progress: Double?, now: Date = Date()) {
        if let index = running.firstIndex(where: { $0.id == id }) {
            if let title { running[index].title = title }
            if let symbol { running[index].symbol = symbol }
            if let progress { running[index].progress = progress }
            running[index].updated = now
        } else {
            running.append(ScriptActivity(id: id, title: title ?? String(localized: "Activity"), symbol: symbol ?? "bolt.fill", progress: progress, updated: now))
            if running.count > Self.limit { running.removeFirst(running.count - Self.limit) }
        }
        if let progress, progress >= 1 { end(id: id, finished: true) }
        scheduleSweep()
    }
    /// Ends an activity: finished ones get a brief checkmark, cancelled ones simply leave.
    func end(id: String, title: String? = nil, finished: Bool) {
        guard let index = running.firstIndex(where: { $0.id == id }) else { return }
        var activity = running.remove(at: index)
        if let title { activity.title = title }
        if finished { onFinish(activity) }
    }
    func sweep(now: Date = Date()) {
        running.removeAll { now.timeIntervalSince($0.updated) > Self.staleAfter }
    }
    func clear() { running.removeAll(); sweepTask?.cancel(); sweepTask = nil }
    /// The average when every activity reports progress; nil (a spinner) when any of them doesn't.
    var combinedProgress: Double? {
        let values = running.compactMap(\.progress)
        guard !running.isEmpty, values.count == running.count else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
    private func scheduleSweep() {
        guard sweepTask == nil, !running.isEmpty else { return }
        sweepTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { return }
                self.sweep()
                if self.running.isEmpty { self.sweepTask = nil; return }
            }
        }
    }
}
