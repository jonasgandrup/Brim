import Foundation
import Network

/// Changes worth a brief word in the island: Low Power Mode turning on or off, and the Mac going offline
/// or coming back. Only the change is read, never a network's name, so no Location permission is needed.
@MainActor final class SystemMoments {
    enum Moment: Equatable { case lowPower(Bool), offline, online }
    private var onMoment: (Moment) -> Void = { _ in }
    private var powerObserver: NSObjectProtocol?
    private var monitor: NWPathMonitor?
    private var connected: Bool?
    private var announcedOffline = false
    private var offlineTask: Task<Void, Never>?
    /// Tests feed changes through `receive` without the real network and power notifications.
    private let watchesSystem: Bool
    init(watchesSystem: Bool = true) { self.watchesSystem = watchesSystem }

    func start(onMoment: @escaping (Moment) -> Void) {
        self.onMoment = onMoment
        guard watchesSystem, monitor == nil else { return }
        powerObserver = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onMoment(.lowPower(ProcessInfo.processInfo.isLowPowerModeEnabled)) }
        }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in self?.receive(connected: satisfied) }
        }
        monitor.start(queue: .main)
        self.monitor = monitor
    }
    func stop() {
        monitor?.cancel(); monitor = nil
        if let powerObserver { NotificationCenter.default.removeObserver(powerObserver) }
        powerObserver = nil; connected = nil; announcedOffline = false
        offlineTask?.cancel(); offlineTask = nil; onMoment = { _ in }
    }
    /// The first reading is the starting point. Going offline is announced only after a few seconds,
    /// so a network handoff (Wi-Fi to Ethernet, a hotspot reconnecting) doesn't flash a warning.
    func receive(connected next: Bool, settle: Duration = .seconds(4)) {
        defer { connected = next }
        guard let connected, connected != next else { return }
        offlineTask?.cancel(); offlineTask = nil
        if next {
            if announcedOffline { announcedOffline = false; onMoment(.online) }
        } else {
            offlineTask = Task { [weak self] in
                try? await Task.sleep(for: settle)
                guard !Task.isCancelled, let self, self.connected == false else { return }
                self.announcedOffline = true; self.onMoment(.offline)
            }
        }
    }
}
