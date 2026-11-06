import AppKit
import SwiftUI
import UserNotifications

struct StopwatchState {
    private(set) var accumulated: TimeInterval = 0
    private(set) var startedAt: TimeInterval?
    private(set) var laps: [TimeInterval] = []
    var running: Bool { startedAt != nil }
    func value(at now: TimeInterval) -> TimeInterval { accumulated + (startedAt.map { max(0, now - $0) } ?? 0) }
    mutating func start(at now: TimeInterval) { if startedAt == nil { startedAt = now } }
    mutating func pause(at now: TimeInterval) { accumulated = value(at: now); startedAt = nil }
    mutating func lap(at now: TimeInterval) {
        guard running else { return }
        laps.insert(value(at: now), at: 0); if laps.count > 20 { laps.removeLast() }
    }
    mutating func reset() { self = Self() }
}

enum AlarmRepeat: String, CaseIterable, Identifiable {
    case once = "Once", daily = "Daily", weekdays = "Weekdays"
    /// The raw value is what's saved; this is what's shown.
    var title: String {
        switch self { case .once: String(localized: "Once"); case .daily: String(localized: "Daily"); case .weekdays: String(localized: "Weekdays") }
    }
    var repeatsText: String {
        switch self { case .once: ""; case .daily: String(localized: "Repeats daily"); case .weekdays: String(localized: "Repeats on weekdays") }
    }
    var id: String { rawValue }
}

struct AlarmSchedule {
    static func next(time: Date, after now: Date, repeat mode: AlarmRepeat = .once, calendar: Calendar = .current) -> Date? {
        let parts = calendar.dateComponents([.hour, .minute], from: time)
        var cursor = now
        // Weekday alarms skip Saturday and Sunday; a week of attempts always finds one.
        for _ in 0..<8 {
            guard let candidate = calendar.nextDate(after: cursor, matching: parts, matchingPolicy: .nextTime, repeatedTimePolicy: .first) else { return nil }
            if mode != .weekdays || !calendar.isDateInWeekend(candidate) { return candidate }
            cursor = candidate
        }
        return nil
    }
}

enum ClockMode: String, CaseIterable {
    case timer = "Timer", focus = "Focus", stopwatch = "Stopwatch", alarm = "Alarm"
    var title: String {
        switch self {
        case .timer: String(localized: "Timer"); case .focus: String(localized: "Focus Session")
        case .stopwatch: String(localized: "Stopwatch"); case .alarm: String(localized: "Alarm")
        }
    }
    var symbol: String {
        switch self { case .timer: "timer"; case .focus: "brain.head.profile"; case .stopwatch: "stopwatch"; case .alarm: "alarm" }
    }
}

@MainActor @Observable final class ClockTools {
    var mode: ClockMode = .timer
    private(set) var stopwatch = StopwatchState()
    /// Monotonic seconds that keep counting while the Mac sleeps (unlike systemUptime).
    nonisolated static var continuousNow: TimeInterval { TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1e9 }
    var alarmTime = Date().addingTimeInterval(3600)
    var alarmRepeat: AlarmRepeat = .once { didSet { defaults.set(alarmRepeat.rawValue, forKey: "clockAlarmRepeat") } }
    private(set) var alarmDate: Date?
    private(set) var ringing = false
    var notice: String?
    @ObservationIgnored var onAlarm: () -> Void = {}
    private var alarmTicker: Task<Void, Never>?
    @ObservationIgnored private var clockObservers: [NSObjectProtocol] = []
    private let defaults: UserDefaults
    private let notificationsEnabled: Bool
    private let notificationID = "sense.clock.alarm"
    var active: Bool { stopwatch.running || ringing }
    /// Read when asked; nothing ticks. Views that count up do it themselves from `stopwatchStart`.
    var label: String { ringing ? "Alarm" : Self.label(stopwatch.value(at: Self.continuousNow)) }
    /// When a running stopwatch would have started had it never paused, for the system's own timer text.
    var stopwatchStart: Date? { stopwatch.running ? Date().addingTimeInterval(-stopwatch.value(at: Self.continuousNow)) : nil }
    static func label(_ seconds: TimeInterval, fractions: Bool = false) -> String {
        let whole = Int(max(0, seconds))
        let text = whole >= 3600 ? String(format: "%d:%02d:%02d", whole / 3600, whole / 60 % 60, whole % 60) : String(format: "%d:%02d", whole / 60, whole % 60)
        return fractions ? text + String(format: ".%02d", Int(max(0, seconds) * 100) % 100) : text
    }
    init(defaults: UserDefaults? = nil, notificationsEnabled: Bool? = nil) {
        self.defaults = defaults ?? AppEnvironment.defaults
        self.notificationsEnabled = notificationsEnabled ?? AppEnvironment.allowsAlerts
        alarmRepeat = AlarmRepeat(rawValue: self.defaults.string(forKey: "clockAlarmRepeat") ?? "") ?? .once
        if let saved = self.defaults.object(forKey: "clockAlarmDate") as? Date, saved > Date() {
            alarmDate = saved; alarmTime = saved; runAlarmTicker()
        } else { self.defaults.removeObject(forKey: "clockAlarmDate") }
        // Waking up or a changed clock can move the alarm closer: look again at once.
        for (center, name) in [(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification),
                               (NotificationCenter.default, Notification.Name.NSSystemClockDidChange)] {
            clockObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if self?.alarmDate != nil { self?.runAlarmTicker() } }
            })
        }
    }
    /// Nothing ticks while the stopwatch runs: its views count up on their own.
    func toggleStopwatch() {
        if stopwatch.running { stopwatch.pause(at: Self.continuousNow) } else { stopwatch.start(at: Self.continuousNow) }
    }
    func resetStopwatch() { stopwatch.reset() }
    func lap() { stopwatch.lap(at: Self.continuousNow) }
    func arm() {
        guard let next = AlarmSchedule.next(time: alarmTime, after: Date(), repeat: alarmRepeat) else { return }
        arm(at: next)
    }
    func arm(at date: Date) {
        guard date > Date() else { return }
        cancelAlarm(); alarmDate = date; defaults.set(date, forKey: "clockAlarmDate"); runAlarmTicker()
        notice = String(localized: "Keep Brim running. A sleeping Mac rings on wake.")
        guard notificationsEnabled else { return }
        Task { [weak self] in
            let center = UNUserNotificationCenter.current()
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                guard let self, self.alarmDate == date else { return }
                guard granted else { self.notice = String(localized: "Notifications are off. Keep Brim running for the alarm."); return }
                let content = UNMutableNotificationContent()
                content.title = String(localized: "Brim Alarm"); content.body = String(localized: "Your alarm is ready."); content.sound = .default
                let request = UNNotificationRequest(identifier: self.notificationID, content: content,
                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, date.timeIntervalSinceNow), repeats: false))
                try await center.add(request)
                if self.alarmDate != date { center.removePendingNotificationRequests(withIdentifiers: [self.notificationID]) }
            } catch { self?.notice = String(localized: "Notifications unavailable. Keep Brim running for the alarm.") }
        }
    }
    func cancelAlarm() {
        alarmTicker?.cancel(); alarmTicker = nil; alarmDate = nil; ringing = false
        defaults.removeObject(forKey: "clockAlarmDate")
        if notificationsEnabled {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [notificationID])
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [notificationID])
        }
    }
    /// Stops a ringing alarm. Repeating alarms are armed again for their next occurrence.
    func stopAlarm() {
        cancelAlarm()
        if alarmRepeat != .once { arm() }
    }
    func snooze() { arm(at: Date().addingTimeInterval(300)) }
    func checkAlarm(at now: Date) {
        guard let date = alarmDate, now >= date else { return }
        alarmDate = nil; defaults.removeObject(forKey: "clockAlarmDate"); ringing = true; mode = .alarm
        onAlarm()
    }
    /// Waits for the alarm rather than watching the clock: it wakes at the alarm time, and at most every quarter hour
    /// before that in case the Mac's clock moved. Once ringing, it chimes every four seconds until stopped.
    private func runAlarmTicker() {
        alarmTicker?.cancel()
        alarmTicker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.checkAlarm(at: Date())
                if self.ringing {
                    if self.notificationsEnabled { NSSound(named: "Glass")?.play() }
                    try? await Task.sleep(for: .seconds(4))
                } else if let date = self.alarmDate {
                    try? await Task.sleep(for: .seconds(min(900, max(0.05, date.timeIntervalSinceNow))))
                } else { self.alarmTicker = nil; return }
            }
        }
    }
    // Preserve a scheduled native notification when the app quits.
    func stop() {
        alarmTicker?.cancel()
        for observer in clockObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer); NotificationCenter.default.removeObserver(observer) }
        clockObservers.removeAll()
    }
}

struct IslandClockView: View {
    @Bindable var clock: ClockTools
    let timer: IslandTimer
    var calendar: CalendarPeek?
    /// Once something is counting, it's what you came for: the modes step back into a small menu.
    private var running: Bool {
        switch clock.mode {
        case .timer: timer.active
        case .focus: timer.active && timer.focus != nil
        case .stopwatch: clock.stopwatch.running
        case .alarm: false
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            // The modes are the header: one segmented control, as in the Clock app, instead of a title beside it.
            if !running {
                HStack(spacing: 2) {
                    ForEach(ClockMode.allCases, id: \.self) { mode in
                        Button { clock.mode = mode } label: {
                            Text(mode.title).font(.system(size: 11, weight: clock.mode == mode ? .semibold : .medium))
                                .frame(maxWidth: .infinity).padding(.vertical, 3)
                                .background(clock.mode == mode ? IslandStyle.raisedFill : .clear, in: Capsule())
                                .foregroundStyle(clock.mode == mode ? .primary : .secondary)
                                .contentShape(Capsule())
                        }.buttonStyle(.plain).accessibilityAddTraits(clock.mode == mode ? .isSelected : [])
                    }
                }.padding(2).background(IslandStyle.tileFill, in: Capsule()).frame(height: 24)
            }
            if let event = calendar?.next {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    HStack(spacing: 6) {
                        Image(systemName: "calendar").foregroundStyle(.red)
                        Text("\(event.title) · \(event.relative(at: context.date))").lineLimit(1)
                        Spacer(minLength: 4)
                        if let link = event.meetingURL {
                            Button("Join") { NSWorkspace.shared.open(link) }
                                .buttonStyle(.plain).font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                .background(Color.green, in: Capsule()).foregroundStyle(.black)
                                .help("Join \(link.host ?? "the meeting")")
                        }
                    }.font(.system(size: 10)).foregroundStyle(.primary)
                }
            }
            switch clock.mode {
            case .timer: IslandTimerView(timer: timer, showsHeader: false)
            case .focus: FocusTimerView(timer: timer)
            case .stopwatch:
                VStack(alignment: .leading, spacing: 8) {
                    // Hundredths only while this pane is open and the stopwatch runs; the pane isn't laid out otherwise.
                    TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !clock.stopwatch.running)) { _ in
                        Text(ClockTools.label(clock.stopwatch.value(at: ClockTools.continuousNow), fractions: true))
                            .font(.system(size: 32, weight: .light, design: .rounded)).monospacedDigit().frame(maxWidth: .infinity)
                    }
                    if let lap = clock.stopwatch.laps.first {
                        Text("Lap \(clock.stopwatch.laps.count) · \(ClockTools.label(lap, fractions: true))")
                            .font(.system(size: 10)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                    }
                    HStack(spacing: 10) {
                        TimerActionButton(title: clock.stopwatch.running ? "Pause" : "Start", symbol: clock.stopwatch.running ? "pause.fill" : "play.fill", prominent: true) { clock.toggleStopwatch() }
                        if clock.stopwatch.running { TimerActionButton(title: "Lap", symbol: "flag.fill") { clock.lap() } }
                        else { TimerActionButton(title: "Reset", symbol: "arrow.counterclockwise") { clock.resetStopwatch() } }
                    }.frame(maxWidth: .infinity)
                }
            case .alarm:
                VStack(alignment: .leading, spacing: 8) {
                    if clock.ringing {
                        Text("Time to wake up").font(.system(size: 24, weight: .light)).frame(maxWidth: .infinity)
                        HStack(spacing: 10) {
                            TimerActionButton(title: "Stop", symbol: "stop.fill", prominent: true) { clock.stopAlarm() }
                            TimerActionButton(title: "Snooze 5 min", symbol: "zzz") { clock.snooze() }
                        }.frame(maxWidth: .infinity)
                    } else if let date = clock.alarmDate {
                        Text(date, format: .dateTime.weekday(.abbreviated).hour().minute()).font(.system(size: 22, weight: .light)).frame(maxWidth: .infinity)
                        if clock.alarmRepeat != .once { Text(clock.alarmRepeat.repeatsText).font(.system(size: 10)).foregroundStyle(.secondary).frame(maxWidth: .infinity) }
                        TimerActionButton(title: "Cancel Alarm", symbol: "xmark") { clock.cancelAlarm() }.frame(maxWidth: .infinity)
                    } else {
                        HStack {
                            DatePicker("Time", selection: $clock.alarmTime, displayedComponents: .hourAndMinute).labelsHidden().datePickerStyle(.field)
                            Picker("Repeat", selection: $clock.alarmRepeat) { ForEach(AlarmRepeat.allCases) { Text($0.title).tag($0) } }
                                .labelsHidden().pickerStyle(.menu).controlSize(.small).fixedSize()
                            Spacer(); TimerActionButton(title: "Set Alarm", symbol: "alarm.fill", prominent: true) { clock.arm() }
                        }
                        Text(clock.alarmRepeat == .once ? "One-time alarm · a sleeping Mac rings on wake" : "Repeating alarm · a sleeping Mac rings on wake").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    if let notice = clock.notice { Text(notice).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2) }
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if running {
                Menu {
                    ForEach(ClockMode.allCases, id: \.self) { mode in Button(mode.title) { clock.mode = mode } }
                } label: {
                    Image(systemName: "ellipsis.circle").frame(width: 20, height: 20)
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().foregroundStyle(.secondary)
                    .help("Clock Tools").accessibilityLabel("Clock Tools")
            }
        }
    }
}
