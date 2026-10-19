import AppKit
import SwiftUI

struct CountdownState {
    enum Phase { case idle, running, paused, finished }
    private(set) var phase: Phase = .idle
    private(set) var duration: TimeInterval = 0
    private var deadline: Date?
    private var pausedRemaining: TimeInterval = 0
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
}

@MainActor @Observable final class IslandTimer {
    var minutes = 5
    private(set) var state = CountdownState()
    private(set) var now = Date()
    @ObservationIgnored var onFinish: () -> Void = {}
    private var ticker: Task<Void, Never>?
    var active: Bool { state.phase != .idle }
    var remaining: TimeInterval { state.remaining(at: now) }
    var label: String {
        let seconds = Int(ceil(remaining))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    var progress: Double { state.duration > 0 ? min(1, max(0, 1 - remaining / state.duration)) : 0 }
    func start() { start(seconds: Double(minutes) * 60) }
    func start(seconds: TimeInterval) {
        guard seconds.isFinite, seconds > 0, seconds <= 86400 else { return }
        now = Date(); state.start(seconds: seconds, at: now); runTicker()
    }
    func pause() { guard state.phase == .running else { return }; now = Date(); state.pause(at: now); ticker?.cancel(); ticker = nil; if state.phase == .finished { onFinish() } }
    func resume() { guard state.phase == .paused else { return }; now = Date(); state.resume(at: now); runTicker() }
    func cancel() { ticker?.cancel(); ticker = nil; state.cancel() }
    private func runTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.now = Date()
                if self.state.update(at: self.now) { self.onFinish(); self.ticker = nil; return }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
}

struct IslandTimerView: View {
    @Bindable var timer: IslandTimer
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            IslandPaneHeader(title: "Timer", symbol: "timer") {
                if timer.state.phase == .idle {
                    Stepper(value: $timer.minutes, in: 1...180) { Text("\(timer.minutes) min").monospacedDigit() }
                        .controlSize(.mini).fixedSize()
                } else {
                    Text(timer.state.phase == .paused ? "Paused" : timer.state.phase == .finished ? "Finished" : "Running")
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            if timer.state.phase == .idle {
                HStack(spacing: 8) {
                    ForEach([1, 5, 15, 25], id: \.self) { minutes in
                        Button("\(minutes)m") { timer.minutes = minutes }
                            .buttonStyle(.plain).frame(maxWidth: .infinity).padding(.vertical, 8)
                            .background(.white.opacity(timer.minutes == minutes ? 0.16 : 0.06), in: Capsule())
                    }
                }.font(.system(size: 12))
                Button("Start timer", systemImage: "play.fill") { timer.start() }
                    .buttonStyle(.borderedProminent).tint(.orange).controlSize(.small).frame(maxWidth: .infinity).padding(.top, 6)
            } else {
                HStack(spacing: 16) {
                    ZStack {
                        Circle().stroke(.white.opacity(0.1), lineWidth: 3)
                        Circle().trim(from: 0, to: timer.progress).stroke(.orange, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
                        Image(systemName: timer.state.phase == .finished ? "checkmark" : "timer").foregroundStyle(.orange)
                    }.frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(timer.state.phase == .finished ? "Time’s up" : timer.label)
                            .font(.system(size: 27, weight: .light, design: .rounded)).monospacedDigit().contentTransition(.numericText())
                        Text(timer.state.phase == .paused ? "Paused" : timer.state.phase == .finished ? "Your timer has finished" : "\(timer.minutes)-minute timer")
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    }
                    Spacer()
                }
                HStack(spacing: 14) {
                    if timer.state.phase == .finished {
                        Button("Start again") { timer.start() }
                        Button("Dismiss") { timer.cancel() }
                    } else {
                        Button(timer.state.phase == .paused ? "Resume" : "Pause") {
                            if timer.state.phase == .paused { timer.resume() } else { timer.pause() }
                        }
                        Button("Cancel") { timer.cancel() }
                    }
                }.buttonStyle(.bordered).controlSize(.small).frame(maxWidth: .infinity)
            }
        }.foregroundStyle(.white)
    }
}
