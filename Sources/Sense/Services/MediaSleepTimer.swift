import Foundation

struct MediaSleepSchedule: Sendable {
    let player: MediaPlayer
    let deadline: Date
    var overdue: Bool { Date() >= deadline }
}

@MainActor @Observable final class MediaSleepTimer {
    private(set) var schedule: MediaSleepSchedule?
    private(set) var now = Date()
    private(set) var firing = false
    private(set) var status: String?
    private var task: Task<Void, Never>?
    private var revision = 0
    @ObservationIgnored var pause: @MainActor (MediaPlayer) async -> MediaCommandResult = { _ in .unavailable }
    var remaining: TimeInterval { schedule.map { max(0, $0.deadline.timeIntervalSince(now)) } ?? 0 }
    func start(minutes: Int, player: MediaPlayer, at date: Date = Date()) {
        guard (1...240).contains(minutes), player.processID > 0 else { return }
        cancel(); now = date; schedule = .init(player: player, deadline: date.addingTimeInterval(Double(minutes)*60))
        status = nil
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.check(at: Date())
                if self.schedule == nil { return }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
    func cancel() { revision += 1; task?.cancel(); task = nil; schedule = nil; firing = false; status = nil }
    func check(at date: Date) async {
        now = date
        guard let schedule, date >= schedule.deadline, !firing else { return }
        firing = true; self.schedule = nil
        let ticket = revision
        let result = await pause(schedule.player)
        guard ticket == revision else { return }
        firing = false
        status = result == .submitted ? "Paused \(schedule.player.name)" : "\(schedule.player.name) couldn’t be paused"
    }
}
