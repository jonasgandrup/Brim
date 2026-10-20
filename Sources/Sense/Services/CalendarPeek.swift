import Foundation
import EventKit

/// The next timed event in the next day, read locally with EventKit. Opt-in; nothing leaves the Mac.
struct NextEvent: Equatable, Sendable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    func isUnderway(at now: Date) -> Bool { start <= now && now < end }
    /// "in 12 min", "in 2 h", or "now".
    func relative(at now: Date) -> String {
        if isUnderway(at: now) { return "now" }
        let minutes = max(1, Int((start.timeIntervalSince(now) / 60).rounded(.up)))
        return "in " + BatteryDetails.duration(minutes: minutes)
    }
    /// Picks the first timed event that hasn't ended. All-day events are never "next".
    static func pick(from events: [(id: String, title: String, start: Date, end: Date, allDay: Bool)], now: Date) -> NextEvent? {
        events.filter { !$0.allDay && $0.end > now }.sorted { $0.start < $1.start }.first
            .map { NextEvent(id: $0.id, title: $0.title, start: $0.start, end: $0.end) }
    }
}

@MainActor @Observable final class CalendarPeek {
    enum Access: Equatable { case off, requesting, granted, denied }
    private(set) var access = Access.off
    private(set) var next: NextEvent?
    @ObservationIgnored var onSoon: (NextEvent) -> Void = { _ in }
    private var store: EKEventStore?
    private var task: Task<Void, Never>?
    private var observer: NSObjectProtocol?
    private var announced: Set<String> = []

    func start() {
        guard task == nil else { return }
        access = .requesting
        let store = EKEventStore(); self.store = store
        task = Task { [weak self] in
            let granted = (try? await store.requestFullAccessToEvents()) ?? false
            guard let self, !Task.isCancelled else { return }
            self.access = granted ? .granted : .denied
            guard granted else { return }
            self.observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            while !Task.isCancelled {
                self.refresh()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }
    func stop() {
        task?.cancel(); task = nil; store = nil; next = nil; access = .off; announced.removeAll()
        if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil
    }
    func refresh() {
        guard let store, access == .granted else { return }
        let now = Date()
        let predicate = store.predicateForEvents(withStart: now, end: now.addingTimeInterval(86_400), calendars: nil)
        let events = store.events(matching: predicate).map {
            (id: $0.eventIdentifier ?? UUID().uuidString, title: $0.title ?? "Event", start: $0.startDate ?? now, end: $0.endDate ?? now, allDay: $0.isAllDay)
        }
        let pick = NextEvent.pick(from: events, now: now)
        if pick != next { next = pick }
        // Tell the island once, five minutes ahead.
        if let pick, !pick.isUnderway(at: now), pick.start.timeIntervalSince(now) <= 300, announced.insert(pick.id).inserted { onSoon(pick) }
    }
}
