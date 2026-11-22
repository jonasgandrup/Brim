import AppKit
import EventKit

/// The next timed event in the next day, read locally with EventKit. Opt-in; nothing leaves the Mac.
struct NextEvent: Equatable, Sendable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    var meetingURL: URL? = nil
    /// Every occurrence of a repeating event shares one `eventIdentifier`; the start time tells them apart.
    var occurrenceKey: String { "\(id)@\(Int(start.timeIntervalSinceReferenceDate))" }
    func isUnderway(at now: Date) -> Bool { start <= now && now < end }
    /// "in 12 min", "in 2 h", or "now".
    func relative(at now: Date) -> String {
        if isUnderway(at: now) { return String(localized: "now") }
        let minutes = max(1, Int((start.timeIntervalSince(now) / 60).rounded(.up)))
        return String(localized: "in \(BatteryDetails.duration(minutes: minutes))")
    }
    typealias Candidate = (id: String, title: String, start: Date, end: Date, allDay: Bool, meetingURL: URL?)
    /// Picks the first timed event that hasn't ended. All-day events are never "next".
    static func pick(from events: [Candidate], now: Date) -> NextEvent? {
        events.filter { !$0.allDay && $0.end > now }.sorted { $0.start < $1.start }.first
            .map { NextEvent(id: $0.id, title: $0.title, start: $0.start, end: $0.end, meetingURL: $0.meetingURL) }
    }
    /// Between calendar edits only the clock moves things on: look again five minutes before the event, when it ends,
    /// and hourly as the next day's window moves forward.
    static func nextLook(after event: NextEvent?, now: Date) -> TimeInterval {
        let moments = [event?.start.addingTimeInterval(-300), event?.end, now.addingTimeInterval(3600)].compactMap { $0 }
        return (moments.filter { $0 > now }.min() ?? now.addingTimeInterval(3600)).timeIntervalSince(now) + 0.5
    }
}

/// Finds a video-call link in an event's URL, location or notes. Only well-known meeting hosts count,
/// so an ordinary web link in the notes never becomes a "Join" button.
enum MeetingLink {
    static let hosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com",
                        "whereby.com", "meet.jit.si", "facetime.apple.com", "chime.aws", "gotomeeting.com"]
    static func isMeeting(_ url: URL) -> Bool {
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""), let host = url.host?.lowercased() else {
            return url.scheme?.lowercased() == "zoommtg" || url.scheme?.lowercased() == "msteams"
        }
        return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }
    static func find(url: URL?, location: String?, notes: String?) -> URL? {
        if let url, isMeeting(url) { return url }
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        for text in [location, notes].compactMap({ $0 }) where !text.isEmpty {
            let range = NSRange(text.startIndex..., in: text)
            let links = detector?.matches(in: text, range: range).compactMap(\.url) ?? []
            if let match = links.first(where: isMeeting) { return match }
        }
        return nil
    }
}

@MainActor @Observable final class CalendarPeek {
    enum Access: Equatable { case off, requesting, granted, denied }
    private(set) var access = Access.off
    private(set) var next: NextEvent?
    @ObservationIgnored var onSoon: (NextEvent) -> Void = { _ in }
    private var store: EKEventStore?
    private var task: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var lookTask: Task<Void, Never>?
    private var announced: Set<String> = []

    func start() {
        guard task == nil else { return }
        access = .requesting
        let store = EKEventStore(); self.store = store
        task = Task { [weak self] in
            let granted: Bool
            do { granted = try await store.requestFullAccessToEvents() }
            catch { Log.calendar.error("Calendar access request failed: \(error.localizedDescription, privacy: .public)"); granted = false }
            guard let self, !Task.isCancelled else { return }
            self.access = granted ? .granted : .denied
            guard granted else { Log.calendar.notice("Calendar access denied"); return }
            // Told when the calendar, the clock or the day changes, or the Mac wakes; otherwise asleep until the next event.
            for name in [Notification.Name.EKEventStoreChanged, .NSSystemClockDidChange, .NSCalendarDayChanged] {
                self.observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                })
            }
            self.observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
            self.refresh()
        }
    }
    func stop() {
        task?.cancel(); task = nil; lookTask?.cancel(); lookTask = nil; store = nil; next = nil; access = .off; announced.removeAll()
        observers.forEach { NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
    }
    func refresh() {
        guard let store, access == .granted else { return }
        let now = Date()
        let predicate = store.predicateForEvents(withStart: now, end: now.addingTimeInterval(86_400), calendars: nil)
        let events: [NextEvent.Candidate] = store.events(matching: predicate).map {
            (id: $0.eventIdentifier ?? UUID().uuidString, title: $0.title ?? String(localized: "Event"), start: $0.startDate ?? now, end: $0.endDate ?? now,
             allDay: $0.isAllDay, meetingURL: MeetingLink.find(url: $0.url, location: $0.location, notes: $0.notes))
        }
        let pick = NextEvent.pick(from: events, now: now)
        if pick != next { next = pick }
        announceIfSoon(pick, at: now)
        let wait = NextEvent.nextLook(after: pick, now: now)
        lookTask?.cancel()
        lookTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }
    /// Tells the island once per occurrence, five minutes ahead.
    func announceIfSoon(_ event: NextEvent?, at now: Date) {
        guard let event, !event.isUnderway(at: now), event.start.timeIntervalSince(now) <= 300,
              announced.insert(event.occurrenceKey).inserted else { return }
        if announced.count > 200 { announced = [event.occurrenceKey] }
        onSoon(event)
    }
}
