import AppKit
import SwiftUI

struct CountdownState: Codable, Equatable {
    enum Phase: String, Codable { case idle, running, paused, finished }
    private(set) var phase: Phase = .idle
    private(set) var duration: TimeInterval = 0
    private var deadline: Date?
    private var pausedRemaining: TimeInterval = 0
    /// When a running timer ends.
    var end: Date? { deadline }
    func remaining(at now: Date) -> TimeInterval {
        if let deadline { return max(0, deadline.timeIntervalSince(now)) }
        return phase == .paused ? pausedRemaining : 0
    }
    mutating func start(seconds: TimeInterval, at now: Date) {
        guard seconds.isFinite, seconds > 0, seconds <= 86400 else { return }
        duration = seconds; deadline = now.addingTimeInterval(seconds); phase = .running
    }
    mutating func pause(at now: Date) {
        guard phase == .running else { return }
        if remaining(at: now) == 0 { _ = update(at: now); return }
        pausedRemaining = remaining(at: now); deadline = nil; phase = .paused
    }
    mutating func resume(at now: Date) {
        guard phase == .paused else { return }
        deadline = now.addingTimeInterval(pausedRemaining); phase = .running
    }
    @discardableResult mutating func update(at now: Date) -> Bool {
        guard phase == .running, remaining(at: now) == 0 else { return false }
        phase = .finished; deadline = nil; pausedRemaining = 0
        return true
    }
    mutating func cancel() { self = CountdownState() }
    /// A saved timer is worth restoring only while it still has time left.
    func restorable(at now: Date) -> Bool {
        switch phase {
        case .running: remaining(at: now) > 0
        case .paused: pausedRemaining > 0
        case .idle, .finished: false
        }
    }
}

/// Pomodoro-style focus sessions: 25 minutes of focus, short breaks, and a long break after every fourth session.
struct FocusCycle: Codable, Equatable {
    enum Phase: String, Codable { case focus, shortBreak, longBreak }
    static let sessionsPerRound = 4
    private(set) var phase: Phase = .focus
    /// Focus sessions completed in this cycle.
    private(set) var completed = 0
    var focusMinutes = 25
    var shortBreakMinutes = 5
    var longBreakMinutes = 15
    var minutes: Int {
        switch phase { case .focus: focusMinutes; case .shortBreak: shortBreakMinutes; case .longBreak: longBreakMinutes }
    }
    /// 1-based session number within the current round of four.
    var session: Int { phase == .focus ? completed % Self.sessionsPerRound + 1 : (completed - 1) % Self.sessionsPerRound + 1 }
    var title: String {
        switch phase { case .focus: "Focus"; case .shortBreak: String(localized: "Short Break"); case .longBreak: String(localized: "Long Break") }
    }
    mutating func advance() {
        if phase == .focus {
            completed += 1
            phase = completed % Self.sessionsPerRound == 0 ? .longBreak : .shortBreak
        } else { phase = .focus }
    }
    /// What the island says when a phase ends and the next one begins.
    var announcement: String {
        switch phase {
        case .focus: String(localized: "Break’s over · time to focus")
        case .shortBreak: String(localized: "Nice work · take \(shortBreakMinutes) minutes")
        case .longBreak: String(localized: "Round complete · take \(longBreakMinutes) minutes")
        }
    }
}

@MainActor @Observable final class IslandTimer {
    var minutes = 5
    private(set) var state = CountdownState()
    private(set) var focus: FocusCycle?
    /// The island's message for the most recent finish.
    private(set) var finishedTitle = String(localized: "Timer finished")
    @ObservationIgnored var onFinish: () -> Void = {}
    private var ticker: Task<Void, Never>?
    private let defaults: UserDefaults?
    private static let storageKey = "islandTimerState"
    private struct Saved: Codable { var state: CountdownState; var focus: FocusCycle?; var minutes: Int }

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        guard let data = defaults?.data(forKey: Self.storageKey),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        minutes = saved.minutes
        guard saved.state.restorable(at: Date()) else { defaults?.removeObject(forKey: Self.storageKey); return }
        state = saved.state; focus = saved.focus
        if state.phase == .running { runTicker() }
    }
    var active: Bool { state.phase != .idle }
    /// Read when asked; nothing ticks. Views that count down do it themselves from `state.end`.
    var remaining: TimeInterval { state.remaining(at: Date()) }
    var label: String { Self.label(remaining) }
    static func label(_ remaining: TimeInterval) -> String {
        let seconds = Int(ceil(max(0, remaining)))
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    /// Describes the timer that is actually running, not the stepper's current value.
    var subtitle: String {
        switch state.phase {
        case .paused: return String(localized: "Paused")
        case .finished: return focus == nil ? String(localized: "Your timer has finished") : String(localized: "Session complete")
        case .idle: return Self.timerText(Double(minutes) * 60)
        case .running:
            if let focus { return focus.phase == .focus ? String(localized: "Focus · session \(focus.session) of \(FocusCycle.sessionsPerRound)") : focus.title }
            return Self.timerText(state.duration)
        }
    }
    /// Six one-tap lengths: the last one used first (if it isn't a standard length), then the common ones.
    static func presets(last: Int) -> [Int] {
        let standard = [1, 5, 10, 15, 25, 45, 60]
        let first = (1...180).contains(last) ? [last] : []
        return Array((first + standard.filter { $0 != last }).prefix(6))
    }
    static func presetLabel(minutes: Int) -> String {
        minutes >= 60 && minutes % 60 == 0 ? String(localized: "\(minutes / 60) h") : String(localized: "\(minutes) min")
    }
    /// "5-minute timer", "1-hour timer": the timer's name in a sentence.
    static func timerText(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded())
        if whole % 3600 == 0 && whole >= 3600 { return whole == 3600 ? String(localized: "1-hour timer") : String(localized: "\(whole / 3600)-hour timer") }
        if whole % 60 == 0 { return whole == 60 ? String(localized: "1-minute timer") : String(localized: "\(whole / 60)-minute timer") }
        return whole < 60 ? String(localized: "\(whole)-second timer") : String(localized: "\(whole / 60) min \(whole % 60) s timer")
    }
    var progress: Double { progress(at: Date()) }
    func progress(at date: Date) -> Double { state.duration > 0 ? min(1, max(0, 1 - state.remaining(at: date) / state.duration)) : 0 }
    func start() { focus = nil; start(seconds: Double(minutes) * 60) }
    func start(seconds: TimeInterval) {
        guard seconds.isFinite, seconds > 0, seconds <= 86400 else { return }
        state.start(seconds: seconds, at: Date()); runTicker(); save()
    }
    func startFocus(_ cycle: FocusCycle = FocusCycle()) {
        focus = cycle
        start(seconds: Double(cycle.minutes) * 60)
    }
    /// Ends the current focus phase early and moves on, as if it had finished.
    func skipFocusPhase() {
        guard var cycle = focus else { return }
        cycle.advance(); focus = cycle
        start(seconds: Double(cycle.minutes) * 60)
    }
    func pause() {
        guard state.phase == .running else { return }
        state.pause(at: Date()); ticker?.cancel(); ticker = nil
        if state.phase == .finished { finish() } else { save() }
    }
    func resume() { guard state.phase == .paused else { return }; state.resume(at: Date()); runTicker(); save() }
    func cancel() { ticker?.cancel(); ticker = nil; state.cancel(); focus = nil; save() }
    /// Stops ticking without forgetting the timer, for quitting the app.
    func suspend() { ticker?.cancel(); ticker = nil; save() }
    private func finish() {
        if var cycle = focus {
            // Focus sessions roll straight into the next phase, like a kitchen timer you never have to reset.
            cycle.advance(); focus = cycle
            finishedTitle = cycle.announcement
            start(seconds: Double(cycle.minutes) * 60)
        } else {
            finishedTitle = String(localized: "Timer finished")
            save()
        }
        onFinish()
    }
    /// Nothing ticks while a timer runs: the system counts the views down from its end time, as with a Live Activity.
    /// This only wakes when it ends, to finish it or move a focus session on (and at most every quarter hour before).
    private func runTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.state.update(at: Date()) { self.ticker = nil; self.finish(); return }
                guard self.state.phase == .running else { self.ticker = nil; return }
                try? await Task.sleep(for: .seconds(min(900, self.remaining) + 0.02))
            }
        }
    }
    private func save() {
        guard let defaults else { return }
        if state.restorable(at: Date()), let data = try? JSONEncoder().encode(Saved(state: state, focus: focus, minutes: minutes)) {
            defaults.set(data, forKey: Self.storageKey)
        } else {
            defaults.removeObject(forKey: Self.storageKey)
        }
    }
}

struct IslandTimerView: View {
    @Bindable var timer: IslandTimer
    var showsHeader = true
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsHeader {
                IslandPaneHeader {
                    if timer.state.phase != .idle {
                        Text(timer.state.phase == .paused ? "Paused" : timer.state.phase == .finished ? "Finished" : "Running")
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            if timer.state.phase == .idle {
                // One tap starts, like the Clock app's recent timers. The last length used is offered first.
                let presets = IslandTimer.presets(last: timer.minutes)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(presets, id: \.self) { minutes in
                        Button { timer.minutes = minutes; timer.start() } label: {
                            Text(IslandTimer.presetLabel(minutes: minutes)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                                .frame(maxWidth: .infinity).padding(.vertical, 9)
                                .background(minutes == presets.first ? Color.orange.opacity(0.24) : IslandStyle.tileFill, in: Capsule())
                                .foregroundStyle(minutes == presets.first ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.primary))
                                .contentShape(Capsule())
                        }.buttonStyle(IslandPressStyle()).accessibilityLabel("Start \(IslandTimer.timerText(Double(minutes) * 60))")
                    }
                }
            } else {
                CountdownReadout(timer: timer)
                HStack(spacing: 10) {
                    if timer.state.phase == .finished {
                        TimerActionButton(title: "Repeat", symbol: "arrow.clockwise", prominent: true) { timer.start() }
                        TimerActionButton(title: "Done", symbol: "checkmark") { timer.cancel() }
                    } else {
                        TimerActionButton(title: timer.state.phase == .paused ? "Resume" : "Pause",
                                          symbol: timer.state.phase == .paused ? "play.fill" : "pause.fill", prominent: true) {
                            if timer.state.phase == .paused { timer.resume() } else { timer.pause() }
                        }
                        TimerActionButton(title: "Cancel", symbol: "xmark") { timer.cancel() }
                    }
                }.frame(maxWidth: .infinity)
            }
        }.foregroundStyle(.white)
    }
}

/// The ring and big digits shared by the timer and focus modes.
struct CountdownReadout: View {
    let timer: IslandTimer
    var tint: Color = .orange
    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().stroke(tint.opacity(0.2), lineWidth: 4)
                CountdownProgress(timer: timer) { progress in
                    Circle().trim(from: 0, to: progress)
                        .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round)).rotationEffect(.degrees(-90))
                }
                Image(systemName: timer.state.phase == .finished ? "checkmark" : timer.state.phase == .paused ? "pause.fill" : "timer")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
                    .contentTransition(.symbolEffect(.replace))
            }.frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                CountdownText(timer: timer, finished: String(localized: "Time’s up"))
                    .font(.system(size: 30, weight: .light, design: .rounded)).monospacedDigit()
                Text(timer.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A capsule action in the island: tinted when it's the primary action, quiet otherwise.
struct TimerActionButton: View {
    let title: LocalizedStringKey
    let symbol: String
    var prominent = false
    var tint: Color = .orange
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(prominent ? tint.opacity(0.9) : .white.opacity(0.1), in: Capsule())
                .foregroundStyle(prominent ? Color.black.opacity(0.85) : .white)
        }.buttonStyle(.plain)
    }
}

struct FocusTimerView: View {
    @Bindable var timer: IslandTimer
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let focus = timer.focus, timer.active {
                CountdownReadout(timer: timer, tint: focus.phase == .focus ? .red : .green)
                HStack(spacing: 10) {
                    TimerActionButton(title: timer.state.phase == .paused ? "Resume" : "Pause",
                                      symbol: timer.state.phase == .paused ? "play.fill" : "pause.fill", prominent: true,
                                      tint: focus.phase == .focus ? .red : .green) {
                        if timer.state.phase == .paused { timer.resume() } else { timer.pause() }
                    }
                    TimerActionButton(title: focus.phase == .focus ? "Skip to Break" : "Skip Break", symbol: "forward.end.fill") { timer.skipFocusPhase() }
                    TimerActionButton(title: "End", symbol: "xmark") { timer.cancel() }
                }.frame(maxWidth: .infinity)
            } else {
                HStack(spacing: 14) {
                    Image(systemName: "brain.head.profile").font(.system(size: 26, weight: .light)).foregroundStyle(.red)
                        .frame(width: 44, height: 44).background(.red.opacity(0.15), in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Focus sessions").font(.system(size: 15, weight: .semibold))
                        Text("25 min focus · 5 min break · long break after 4").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                HStack {
                    if timer.active {
                        Text("A timer is already running").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    TimerActionButton(title: "Start Focus Session", symbol: "play.fill", prominent: true, tint: .red) { timer.startFocus() }
                        .disabled(timer.active && timer.state.phase != .finished)
                }
            }
        }.foregroundStyle(.white)
    }
}

/// The countdown's digits. While running they're the system's own timer text, kept moving from the end time without
/// the app doing anything each second; paused or finished, they're plain text.
struct CountdownText: View {
    let timer: IslandTimer
    var finished = String(localized: "Done")
    var body: some View {
        if timer.state.phase == .running, let end = timer.state.end, end > Date() {
            Text(timerInterval: Date()...end, countsDown: true)
        } else {
            Text(timer.state.phase == .finished ? finished : timer.label)
        }
    }
}

/// A countdown's progress for a ring: redrawn once a second while running and on screen, still otherwise.
struct CountdownProgress<Content: View>: View {
    let timer: IslandTimer
    var live = true
    @ViewBuilder let content: (Double) -> Content
    var body: some View {
        if live, timer.state.phase == .running {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let progress = timer.progress(at: context.date)
                content(progress).animation(IslandStyle.progress, value: progress)
            }
        } else {
            content(timer.progress)
        }
    }
}
