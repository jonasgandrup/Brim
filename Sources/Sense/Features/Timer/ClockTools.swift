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
    var symbol: String {
        switch self { case .timer: "timer"; case .focus: "brain.head.profile"; case .stopwatch: "stopwatch"; case .alarm: "alarm" }
    }
}

@MainActor @Observable final class ClockTools {
    var mode: ClockMode = .timer
    private(set) var stopwatch = StopwatchState()
    /// Monotonic seconds that keep counting while the Mac sleeps (unlike systemUptime).
    nonisolated static var continuousNow: TimeInterval { TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1e9 }
    private(set) var uptime = ClockTools.continuousNow
    var alarmTime = Date().addingTimeInterval(3600)
    var alarmRepeat: AlarmRepeat = .once { didSet { defaults.set(alarmRepeat.rawValue, forKey: "clockAlarmRepeat") } }
    private(set) var alarmDate: Date?
    private(set) var ringing = false
    var notice: String?
    @ObservationIgnored var onAlarm: () -> Void = {}
    /// Hundredths are only visible while the stopwatch pane is open; otherwise whole seconds suffice.
    @ObservationIgnored var wantsFineTicks: @MainActor () -> Bool = { false }
    private var stopwatchTicker: Task<Void, Never>?
    private var alarmTicker: Task<Void, Never>?
    private let defaults: UserDefaults
    private let notificationsEnabled: Bool
    private let notificationID = "sense.clock.alarm"
    var active: Bool { stopwatch.running || ringing }
    var label: String { ringing ? "Alarm" : Self.label(stopwatch.value(at: uptime)) }
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
    }
    func toggleStopwatch() {
        uptime = Self.continuousNow
        if stopwatch.running { stopwatch.pause(at: uptime); stopwatchTicker?.cancel(); stopwatchTicker = nil }
        else {
            stopwatch.start(at: uptime)
            stopwatchTicker = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    self.uptime = Self.continuousNow
                    try? await Task.sleep(for: .milliseconds(self.wantsFineTicks() && self.mode == .stopwatch ? 50 : 250))
                }
            }
        }
    }
    func resetStopwatch() { stopwatchTicker?.cancel(); stopwatchTicker = nil; stopwatch.reset() }
    func lap() { stopwatch.lap(at: Self.continuousNow) }
    func arm() {
        guard let next = AlarmSchedule.next(time: alarmTime, after: Date(), repeat: alarmRepeat) else { return }
        arm(at: next)
    }
    func arm(at date: Date) {
        guard date > Date() else { return }
        cancelAlarm(); alarmDate = date; defaults.set(date, forKey: "clockAlarmDate"); runAlarmTicker()
        notice = "Keep Sense running. A sleeping Mac rings on wake."
        guard notificationsEnabled else { return }
        Task { [weak self] in
            let center = UNUserNotificationCenter.current()
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                guard let self, self.alarmDate == date else { return }
                guard granted else { self.notice = "Notifications are off. Keep Sense running for the alarm."; return }
                let content = UNMutableNotificationContent()
                content.title = "Sense Alarm"; content.body = "Your alarm is ready."; content.sound = .default
                let request = UNNotificationRequest(identifier: self.notificationID, content: content,
                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, date.timeIntervalSinceNow), repeats: false))
                try await center.add(request)
                if self.alarmDate != date { center.removePendingNotificationRequests(withIdentifiers: [self.notificationID]) }
            } catch { self?.notice = "Notifications unavailable. Keep Sense running for the alarm." }
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
    private func runAlarmTicker() {
        alarmTicker?.cancel()
        alarmTicker = Task { [weak self] in
            var soundTick = 0
            while !Task.isCancelled {
                guard let self else { return }
                self.checkAlarm(at: Date())
                if self.ringing, self.notificationsEnabled, soundTick % 4 == 0 { NSSound(named: "Glass")?.play() }
                soundTick += 1
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
    // Preserve a scheduled native notification when the app quits.
    func stop() { stopwatchTicker?.cancel(); alarmTicker?.cancel() }
}

struct IslandClockView: View {
    @Bindable var clock: ClockTools
    let timer: IslandTimer
    var calendar: CalendarPeek?
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            IslandPaneHeader(title: clock.mode.rawValue, symbol: clock.mode.symbol) {
                HStack(spacing: 2) {
                    ForEach(ClockMode.allCases, id: \.self) { mode in
                        Button { clock.mode = mode } label: {
                            Text(mode.rawValue).font(.system(size: 10, weight: clock.mode == mode ? .semibold : .medium))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(clock.mode == mode ? .white.opacity(0.16) : .clear, in: Capsule())
                                .foregroundStyle(.white.opacity(clock.mode == mode ? 1 : 0.6))
                                .contentShape(Capsule())
                        }.buttonStyle(.plain).accessibilityAddTraits(clock.mode == mode ? .isSelected : [])
                    }
                }.padding(2).background(.white.opacity(0.06), in: Capsule())
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
                    }.font(.system(size: 10)).foregroundStyle(.white.opacity(0.7))
                }
            }
            switch clock.mode {
            case .timer: IslandTimerView(timer: timer, showsHeader: false)
            case .focus: FocusTimerView(timer: timer)
            case .stopwatch:
                VStack(alignment: .leading, spacing: 8) {
                    Text(ClockTools.label(clock.stopwatch.value(at: clock.uptime), fractions: true))
                        .font(.system(size: 32, weight: .light, design: .rounded)).monospacedDigit().frame(maxWidth: .infinity)
                    if let lap = clock.stopwatch.laps.first {
                        Text("Lap \(clock.stopwatch.laps.count) · \(ClockTools.label(lap, fractions: true))")
                            .font(.system(size: 10)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                    }
                    HStack {
                        Button(clock.stopwatch.running ? "Pause" : "Start") { clock.toggleStopwatch() }.tint(.orange)
                        if clock.stopwatch.running { Button("Lap") { clock.lap() } }
                        else { Button("Reset") { clock.resetStopwatch() } }
                    }.buttonStyle(.bordered).controlSize(.small).frame(maxWidth: .infinity)
                }
            case .alarm:
                VStack(alignment: .leading, spacing: 8) {
                    if clock.ringing {
                        Text("Time to wake up").font(.system(size: 24, weight: .light)).frame(maxWidth: .infinity)
                        HStack { Button("Stop") { clock.stopAlarm() }; Button("Snooze 5 min") { clock.snooze() } }
                            .buttonStyle(.bordered).controlSize(.small).frame(maxWidth: .infinity)
                    } else if let date = clock.alarmDate {
                        Text(date, format: .dateTime.weekday(.abbreviated).hour().minute()).font(.system(size: 22, weight: .light)).frame(maxWidth: .infinity)
                        if clock.alarmRepeat != .once { Text("Repeats \(clock.alarmRepeat.rawValue.lowercased())").font(.system(size: 10)).foregroundStyle(.secondary).frame(maxWidth: .infinity) }
                        Button("Cancel alarm") { clock.cancelAlarm() }.buttonStyle(.bordered).controlSize(.small).frame(maxWidth: .infinity)
                    } else {
                        HStack {
                            DatePicker("Time", selection: $clock.alarmTime, displayedComponents: .hourAndMinute).labelsHidden().datePickerStyle(.field)
                            Picker("Repeat", selection: $clock.alarmRepeat) { ForEach(AlarmRepeat.allCases) { Text($0.rawValue).tag($0) } }
                                .labelsHidden().pickerStyle(.menu).controlSize(.small).fixedSize()
                            Spacer(); Button("Set alarm") { clock.arm() }.buttonStyle(.borderedProminent).tint(.orange).controlSize(.small)
                        }
                        Text("\(clock.alarmRepeat == .once ? "One-time alarm" : "Repeating alarm") · sleeping Mac rings on wake").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    if let notice = clock.notice { Text(notice).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(2) }
                }
            }
        }
    }
}
