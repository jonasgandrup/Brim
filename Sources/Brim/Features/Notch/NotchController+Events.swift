import SwiftUI
import AppKit
import Observation
import CoreAudio

/// Opening sections, what the system tells the island, and how its notices are shown.
extension NotchController {
    // MARK: Opening tools
    func openTool(_ tool: ToolShortcuts.Tool, fromKeyboard: Bool = false) {
        toolOpenTask?.cancel()
        toolOpenTask = Task { [weak self] in
            // A shortcut pressed while the island is away opens the tool once it's back.
            for _ in 0..<100 {
                guard !Task.isCancelled, let self, self.panel != nil, !self.presentationMode else { return }
                if !self.transitioning && !self.suspended {
                    switch tool {
                    case .island: self.openInContext()
                    case .nowPlaying: self.selectedTab = .music
                    case .files: self.selectedTab = .files
                    case .clipboard: self.selectedTab = .clipboard
                    case .clock: self.selectedTab = .timer
                    case .transfers: self.selectedTab = .transfers
                    }
                    if tool != .island { self.openFromMenu() }
                    if fromKeyboard && self.expanded { self.startKeyboardSession() }
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }
    // MARK: System events

    func transferFinished(_ activity: TransferActivity) {
        switch activity.state {
        case .finished:
            let text = switch activity.kind {
            case .airDropSend: activity.name
            case .airDropReceive: String(localized: "Received \(activity.name)")
            case .download: String(localized: "Downloaded \(activity.name)")
            }
            haptic(.finish)
            showFeedback(text, symbol: activity.symbol, tint: .blue, seconds: 3)
        case .failed(let message):
            Log.island.notice("Transfer failed: \(message, privacy: .private)")
            showFeedback(String(localized: "AirDrop didn’t finish"), symbol: "exclamationmark.circle", tint: .orange)
        case .running: break
        }
    }
    func receivePower(_ sample: PowerSample) {
        guard let preferences else { return }
        let event = powerFeedback.receive(sample, target: preferences.chargeTarget, low: preferences.lowBatteryAlert)
        guard !AppEnvironment.isSmokeTest, !expanded, !fileDragActive, let event else { return }
        switch event {
        case .connected(let percent) where preferences.chargingFeedback:
            showHUD(.init(symbol: "battery.100percent.bolt", tint: .green, label: String(localized: "Charging"), battery: percent, charging: true), seconds: 3)
        case .targetReached(let target) where preferences.chargingFeedback:
            showHUD(.init(symbol: "battery.100percent", tint: .green, label: String(localized: "Target reached"), battery: target), seconds: 3)
        case .low(let percent):
            showHUD(.init(symbol: "battery.25percent", tint: .red, label: String(localized: "Battery low"), battery: percent), seconds: 5)
        default: break
        }
    }
    /// Where sound is going now, as iPhone shows when you pick an AirPlay speaker. Bluetooth headphones get
    /// the accessory card instead, which says more.
    func outputChanged(_ output: AudioOutput) {
        guard preferences?.systemChanges == true, !expanded, feedback == nil else { return }
        let bluetooth = [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE].contains(output.transport)
        guard !(bluetooth && preferences?.bluetoothBatteries == true) else { return }
        showFeedback(String(localized: "Playing on \(output.name)"), symbol: output.symbol, tint: .white, seconds: 2.5)
    }
    func receive(_ moment: SystemMoments.Moment) {
        guard preferences?.systemChanges == true else { return }
        switch moment {
        case .lowPower(let on): showHUD(.init(symbol: on ? "leaf.fill" : "leaf", tint: .yellow, label: on ? String(localized: "Low Power Mode On") : String(localized: "Low Power Mode Off")), seconds: 2)
        case .offline: showHUD(.init(symbol: "wifi.slash", tint: .orange, label: String(localized: "Offline")), seconds: 3)
        case .online: showHUD(.init(symbol: "wifi", tint: .green, label: String(localized: "Back Online")), seconds: 2)
        }
    }
    func deviceConnected(_ device: BluetoothDevice) {
        guard preferences?.bluetoothBatteries == true, device.level != nil else { return }
        haptic(.land)
        showFeedback(device.name, symbol: device.symbol, tint: .white, device: device, seconds: 4)
    }
    /// Shown compact and brief, as on iPhone. Brim learns only that a Focus is on, not which one.
    func focusChanged(on: Bool) {
        guard preferences?.focusFeedback == true else { return }
        showHUD(.init(symbol: on ? "moon.fill" : "moon", tint: .indigo, label: on ? String(localized: "Focus On") : String(localized: "Focus Off")), seconds: 2)
    }
    /// A new screenshot goes onto the file shelf and gets a brief preview, like the iPhone's corner thumbnail.
    func receiveScreenshot(_ url: URL) {
        guard preferences?.notchEnabled == true, preferences?.screenshotShelf == true, shows(.files) else { return }
        shelf.add([url]); shelf.select([url.standardizedFileURL])
        selectedTab = .files
        haptic(.land)
        showFeedback(String(localized: "Screenshot"), symbol: "camera.viewfinder", image: ScreenshotWatcher.thumbnail(for: url), url: url, seconds: 4)
    }
    // MARK: Feedback presentation

    func showFeedback(_ text: String, symbol: String, tint: Color = .green,
                      image: NSImage? = nil, url: URL? = nil, action: (title: String, url: URL)? = nil, device: BluetoothDevice? = nil, seconds: Double = 3) {
        guard preferences?.notchEnabled == true else { return }
        if preferences?.smallNotices == true, image == nil, action == nil, device == nil { showHUD(.init(symbol: symbol, tint: tint, label: text), seconds: seconds); return }
        feedbackTask?.cancel(); hudTask?.cancel(); hud = nil
        feedback = text; feedbackSymbol = symbol; feedbackTint = tint
        feedbackImage = image; feedbackURL = url; feedbackAction = action; feedbackDevice = device
        setExpanded(true)
        announce(text)
        feedbackTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            self.clearFeedback()
            if !self.pointerInside { self.setExpanded(false) }
        }
    }
    func dismissFeedback() {
        feedbackTask?.cancel()
        clearFeedback()
        if !pointerInside { setExpanded(false) }
    }
    func clearFeedback() {
        feedback = nil; feedbackImage = nil; feedbackURL = nil; feedbackAction = nil; feedbackDevice = nil
    }
    /// The trackpad only plays this while a finger rests on it, so it's felt, never heard.
    enum Haptic { case open, land, finish }
    func haptic(_ kind: Haptic) {
        guard preferences?.haptics == true, AppEnvironment.allowsAlerts else { return }
        let pattern: NSHapticFeedbackManager.FeedbackPattern = switch kind {
        case .open: .alignment
        case .land: .generic
        case .finish: .levelChange
        }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
    /// Volume, brightness and privacy changes stay compact: they never open the island or take focus.
    func showHUD(_ value: IslandHUD, seconds: Double = 1.6) {
        guard preferences?.notchEnabled == true, !expanded, !presentationMode, !suspended else { return }
        hudTask?.cancel()
        hud = value
        if let text = value.announcement { announce(text) }
        hudTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.hud = nil
        }
    }
    /// Notices leave on their own, before VoiceOver would ever reach them, so they're spoken as they arrive.
    private func announce(_ text: String) {
        guard AppEnvironment.allowsAlerts else { return }
        NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}
