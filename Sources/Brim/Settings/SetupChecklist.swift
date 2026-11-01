import SwiftUI

/// One line of the setup overview: what it is, whether it works right now, and the one thing to do if not.
struct SetupItem: Identifiable {
    enum State { case ready, attention, notNeeded }
    let id: String
    let title: String
    let state: State
    let detail: String
    var actionTitle: String?
    var action: (@MainActor () -> Void)?
}

extension BrimAppModel {
    /// Everything that can stop an enabled feature from working, in one list. Features that are
    /// switched off never ask for anything.
    var setupItems: [SetupItem] {
        var items: [SetupItem] = []
        let needsAccessibility = preferences.switcherEnabled
        items.append(SetupItem(id: "accessibility", title: String(localized: "Accessibility"),
            state: permissions.accessibility ? .ready : (needsAccessibility ? .attention : .notNeeded),
            detail: permissions.accessibility ? String(localized: "The Window Switcher can work.")
                : (needsAccessibility ? String(localized: "Needed to switch windows. Already on in System Settings? Allow clears the old approval so you can give it again.") : String(localized: "Only needed for the Window Switcher.")),
            actionTitle: permissions.accessibility ? nil : String(localized: "Allow…"),
            action: { [permissions] in permissions.requestAccessibility() }))

        let needsCapture = preferences.lidEffectEnabled || preferences.switcherEnabled
        let waitingForRestart = permissions.screenRecordingRequested && !permissions.screenRecording
        items.append(SetupItem(id: "screen", title: String(localized: "Screen Recording"),
            state: permissions.screenRecording ? .ready : (needsCapture ? .attention : .notNeeded),
            detail: permissions.screenRecording ? String(localized: "Window previews and the lid fold can capture the desktop.")
                : (waitingForRestart ? String(localized: "If you just turned it on, restart Brim to finish.") : String(localized: "Needed for the lid fold and window previews. Already on in System Settings? Allow clears the old approval so you can give it again.")),
            actionTitle: permissions.screenRecording ? nil : (waitingForRestart ? String(localized: "Restart Brim") : String(localized: "Allow…")),
            action: { [weak self] in
                guard let self else { return }
                if waitingForRestart { self.restartForLidSetup() } else { self.permissions.requestScreenRecording() }
            }))

        if preferences.lidEffectEnabled {
            let ready = lid.angle != nil
            items.append(SetupItem(id: "hinge", title: String(localized: "Hinge Sensor"), state: ready ? .ready : .attention,
                detail: ready ? String(localized: "Reading the lid angle. Open position is learned automatically.") : lid.status,
                actionTitle: ready ? nil : String(localized: "Retry"), action: { [weak self] in self?.lid.stop(); self?.lid.start() }))
        }
        if preferences.notchEnabled && preferences.mediaEnabled {
            items.append(SetupItem(id: "media", title: String(localized: "Now Playing"), state: media.systemAvailable ? .ready : .attention,
                detail: media.systemAvailable ? String(localized: "Reading the active media session.") : (media.message ?? String(localized: "No media session yet. Play something, or check Automation access for Music and Spotify.")),
                actionTitle: media.systemAvailable ? nil : String(localized: "Automation…"), action: { [permissions] in permissions.openPrivacy("Privacy_Automation") }))
        }
        if preferences.notchEnabled && preferences.toolShortcutsEnabled {
            let blocked = toolShortcuts.unavailable
            items.append(SetupItem(id: "shortcuts", title: String(localized: "Keyboard Shortcuts"), state: blocked.isEmpty ? .ready : .attention,
                detail: blocked.isEmpty ? String(localized: "All island shortcuts are registered.") : String(localized: "Taken by another app: \(blocked.joined(separator: ", ")). Pick other modifiers in Dynamic Island settings."),
                actionTitle: blocked.isEmpty ? nil : String(localized: "Change…"), action: { [weak self] in self?.openSettings(page: .notch) }))
        }
        if preferences.notchEnabled && preferences.autoHideFocus {
            let monitor = autoHide
            items.append(SetupItem(id: "focus", title: String(localized: "Focus Status"), state: monitor.focusAuthorized ? .ready : (monitor.focusDenied ? .attention : .ready),
                detail: monitor.focusAuthorized ? String(localized: "The island hides while a Focus is on.") : (monitor.focusDenied ? String(localized: "Focus access is off, so Brim can’t tell when a Focus is on.") : String(localized: "Waiting for your answer.")),
                actionTitle: monitor.focusDenied ? String(localized: "Open Settings…") : nil, action: { [permissions] in permissions.openPrivacy("Privacy_Focus") }))
        }
        if preferences.notchEnabled && preferences.liveTransfers {
            let problem = notch.transfers.accessProblem
            items.append(SetupItem(id: "transfers", title: String(localized: "Downloads Folder"), state: problem == nil ? .ready : .attention,
                detail: problem ?? String(localized: "Watching for downloads and received AirDrops."),
                actionTitle: problem == nil ? nil : String(localized: "Files & Folders…"), action: { [permissions] in permissions.openPrivacy("Privacy_FilesAndFolders") }))
        }
        if preferences.notchEnabled && preferences.calendarPreview {
            let access = notch.calendar.access
            items.append(SetupItem(id: "calendar", title: String(localized: "Calendar"), state: access == .granted ? .ready : (access == .denied ? .attention : .ready),
                detail: access == .denied ? String(localized: "Calendar access is off.") : (access == .granted ? String(localized: "Showing your next event.") : String(localized: "Waiting for your answer.")),
                actionTitle: access == .denied ? String(localized: "Open Settings…") : nil, action: { [permissions] in permissions.openPrivacy("Privacy_Calendars") }))
        }
        return items
    }
}

struct SetupChecklist: View {
    let model: BrimAppModel
    var body: some View {
        // A feature that's off isn't worth a line.
        let items = model.setupItems.filter { $0.state != .notNeeded }
        let problems = items.filter { $0.state == .attention }.count
        Section {
            ForEach(items) { item in
                LabeledContent {
                    switch item.state {
                    case .ready: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Ready")
                    case .notNeeded: Text("Not needed").foregroundStyle(.secondary)
                    case .attention:
                        if let title = item.actionTitle, let action = item.action { Button(title, action: action) }
                        else { Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange) }
                    }
                } label: {
                    SettingsLabel(title: .verbatim(item.title), detail: .verbatim(item.detail))
                }
            }
        } header: {
            Label(problems == 0 ? "Everything you’ve turned on is ready" : problems == 1 ? "1 thing needs attention" : "\(problems) things need attention",
                  systemImage: problems == 0 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(problems == 0 ? Color.green : .orange)
        }
    }
}

extension BrimAppModel {
    /// A plain-text snapshot for bug reports. Contains no file names, titles or personal content.
    var diagnosticsText: String {
        func sysctl(_ name: String) -> String {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
            var buffer = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "unknown" }
            return String(cString: buffer)
        }
        let info = Bundle.main.infoDictionary
        let yes = { (value: Bool) in value ? "yes" : "no" }
        var lines = [
            "Brim \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString) · \(sysctl("hw.model"))",
            "Accessibility: \(yes(permissions.accessibility)) · Screen Recording: \(yes(permissions.screenRecording))",
            "Lid fold: \(yes(preferences.lidEffectEnabled)) (\(preferences.lidFoldStyle.rawValue)) · hinge: \(lid.status) · capture check: \(lid.captureCheck.title)",
            "Now Playing: \(yes(preferences.mediaEnabled)) · system bridge available: \(yes(media.systemAvailable))",
            "Trackpad devices seen: \(notch.trackpadDeviceCount) · scale format recognized: \(yes(!scale.formatUnrecognized))",
            "Island: \(yes(preferences.notchEnabled)) · switcher: \(yes(preferences.switcherEnabled)) (\(switcher.status))",
            "Tool shortcuts unavailable: \(toolShortcuts.unavailable.isEmpty ? "none" : toolShortcuts.unavailable.joined(separator: ", "))",
            "Live transfers: \(yes(preferences.liveTransfers)) · hide on Focus: \(yes(preferences.autoHideFocus)) · hide on sharing: \(yes(preferences.autoHideSharing)) · auto-hidden now: \(notch.autoHideReason ?? "no")",
            "Screenshot shelf: \(yes(preferences.screenshotShelf)) · keep shelf: \(yes(preferences.keepShelf)) · clipboard history: \(yes(preferences.clipboardHistory)) · calendar: \(notch.calendar.access)",
            "Camera/mic indicator: \(yes(preferences.sensorIndicator)) · volume & brightness: \(yes(preferences.systemHUD)) (brightness API: \(yes(BrightnessMonitor.available))) · accessory batteries: \(yes(preferences.bluetoothBatteries)) (\(notch.bluetooth.devices.count) connected)",
            "Low battery warning: \(preferences.lowBatteryAlert == 0 ? "off" : "\(preferences.lowBatteryAlert)%") · follow active display: \(yes(preferences.followActiveDisplay)) · Now Playing helper: \(NowPlayingHelper.shared.enabled ? "resident" : "one-shot")"
        ]
        lines.append("Needs attention: " + (setupItems.filter { $0.state == .attention }.map(\.title).joined(separator: ", ").nonEmpty ?? "nothing"))
        return lines.joined(separator: "\n")
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
