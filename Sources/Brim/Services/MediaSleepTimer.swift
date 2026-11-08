import Foundation

struct MediaSleepSchedule: Sendable {
    let player: MediaPlayer
    let deadline: Date
    var endOfTrack = false
}

@MainActor @Observable final class MediaSleepTimer {
    private(set) var schedule: MediaSleepSchedule?
    private(set) var firing = false
    private(set) var status: String?
    private var task: Task<Void, Never>?
    private var revision = 0
    private var track: SystemMediaSnapshot?
    private var trackMeasuredAt = Date()
    private var reading = false
    private var missing = 0
    @ObservationIgnored var readTrack: @MainActor (MediaPlayer) async -> SystemMediaSnapshot? = { _ in nil }
    @ObservationIgnored var pauseTrack: @MainActor (SystemMediaSnapshot) async -> MediaCommandResult = { _ in .unavailable }
    static func supportsTrackEnd(_ snapshot: SystemMediaSnapshot) -> Bool {
        guard snapshot.hasMedia, let duration = snapshot.duration, let position = snapshot.position,
              let rate = snapshot.rate, let id = snapshot.identifier, let path = snapshot.playerPath else { return false }
        return duration.isFinite && duration > 0 && position.isFinite && position >= 0 && position < duration
            && rate.isFinite && rate >= 0 && !id.isEmpty && !path.isEmpty
    }
    func startAtTrackEnd(player: MediaPlayer, snapshot: SystemMediaSnapshot, at date: Date = Date()) {
        guard Self.supportsTrackEnd(snapshot), player.processID > 0,
              snapshot.processID == player.processID, snapshot.source == player.source else { return }
        cancel(); track = snapshot; trackMeasuredAt = date
        schedule = .init(player: player, deadline: date.addingTimeInterval(snapshot.duration! - snapshot.position!), endOfTrack: true)
        run()
    }
    /// Waits for the deadline rather than watching the clock. The end of a track can move, so that's read now and then,
    /// whenever playback changes, and closely only for the last two seconds.
    private func run(firstWait: TimeInterval? = nil) {
        task = Task { [weak self] in
            var wait = firstWait
            while !Task.isCancelled {
                guard let pause = wait ?? self?.nextCheck else { return }
                try? await Task.sleep(for: .seconds(pause))
                guard !Task.isCancelled, let self else { return }
                await self.check(at: Date())
                if self.schedule == nil { return }
                wait = nil
            }
        }
    }
    private var nextCheck: TimeInterval? {
        guard let schedule else { return nil }
        let left = schedule.deadline.timeIntervalSinceNow
        guard schedule.endOfTrack else { return max(0.05, left + 0.02) }
        return left > 17 ? 15 : left > 2 ? left - 2 : 0.5
    }
    /// The helper saw playback change: a seek, a pause or the next track moves the end, so look now.
    func playbackChanged() {
        guard schedule?.endOfTrack == true, !firing, !reading else { return }
        task?.cancel(); run(firstWait: 0.2)
    }
    @ObservationIgnored var pause: @MainActor (MediaPlayer) async -> MediaCommandResult = { _ in .unavailable }
    var remaining: TimeInterval { schedule.map { max(0, $0.deadline.timeIntervalSinceNow) } ?? 0 }
    func start(minutes: Int, player: MediaPlayer, at date: Date = Date()) {
        guard (1...240).contains(minutes), player.processID > 0 else { return }
        cancel(); schedule = .init(player: player, deadline: date.addingTimeInterval(Double(minutes)*60))
        status = nil
        run()
    }
    func cancel() { revision += 1; task?.cancel(); task = nil; schedule = nil; track = nil; missing = 0; firing = false; status = nil }
    func check(at date: Date) async {
        guard let schedule, !firing, !reading else { return }
        if schedule.endOfTrack { await checkTrack(schedule, at: date); return }
        guard date >= schedule.deadline else { return }
        firing = true; self.schedule = nil
        let ticket = revision
        let result = await pause(schedule.player)
        guard ticket == revision else { return }
        firing = false
        status = result == .submitted ? String(localized: "Paused \(schedule.player.name)") : String(localized: "\(schedule.player.name) couldn’t be paused")
    }
    private func checkTrack(_ schedule: MediaSleepSchedule, at date: Date) async {
        guard let previous = track else { return }
        let ticket = revision
        reading = true
        let snapshot = await readTrack(schedule.player)
        reading = false
        guard ticket == revision, !Task.isCancelled else { return }
        guard let snapshot, snapshot.hasMedia, snapshot.source == schedule.player.source,
              snapshot.processID == schedule.player.processID, snapshot.playerPath == previous.playerPath,
              let duration = snapshot.duration, duration.isFinite, duration > 0,
              let position = snapshot.position, position.isFinite, position >= 0, let rate = snapshot.rate, rate.isFinite, rate >= 0,
              let identifier = snapshot.identifier, !identifier.isEmpty else {
            missing += 1
            if missing >= 3 { self.schedule = nil; status = String(localized: "Track timer stopped · player unavailable") }
            return
        }
        missing = 0
        let projected = (previous.position ?? 0) + max(0, date.timeIntervalSince(trackMeasuredAt)) * (previous.rate ?? 0)
        let nearEnd = date.timeIntervalSince(trackMeasuredAt) <= 5 && (previous.rate ?? 0) > 0
            && projected >= (previous.duration ?? .infinity) - 0.3
        let changed = identifier != previous.identifier
        let repeated = position < 2 && position + 1 < (previous.position ?? 0) && nearEnd
        if changed && !nearEnd {
            self.schedule = nil; status = String(localized: "Track timer cancelled · track changed"); return
        }
        let reachedEnd = !changed && position >= duration
        if (changed && nearEnd) || repeated || reachedEnd {
            firing = true; self.schedule = nil
            let result = rate == 0 ? MediaCommandResult.submitted : await pauseTrack(snapshot)
            guard ticket == revision else { return }
            firing = false
            status = result == .submitted ? String(localized: "Paused \(schedule.player.name)") : String(localized: "\(schedule.player.name) couldn’t be paused")
            return
        }
        track = snapshot; trackMeasuredAt = date
        // Others watch the schedule, so it only changes when the end really moved.
        let end = date.addingTimeInterval(max(0, duration - position))
        if abs(end.timeIntervalSince(schedule.deadline)) > 1 { self.schedule = .init(player: schedule.player, deadline: end, endOfTrack: true) }
    }
}
