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

extension SenseAppModel {
    /// Everything that can stop an enabled feature from working, in one list. Features that are
    /// switched off never ask for anything.
    var setupItems: [SetupItem] {
        var items: [SetupItem] = []
        let needsAccessibility = preferences.switcherEnabled || preferences.lockEnabled
        items.append(SetupItem(id: "accessibility", title: "Accessibility",
            state: permissions.accessibility ? .ready : (needsAccessibility ? .attention : .notNeeded),
            detail: permissions.accessibility ? "Window Switcher and Lock Now can work." : (needsAccessibility ? "Needed to switch windows and send Lock Screen." : "Only needed for the Window Switcher and Lock Now."),
            actionTitle: permissions.accessibility ? nil : "Allow…", action: { [permissions] in permissions.requestAccessibility() }))

        let needsCapture = preferences.lidEffectEnabled || preferences.switcherEnabled
        let waitingForRestart = permissions.screenRecordingRequested && !permissions.screenRecording
        items.append(SetupItem(id: "screen", title: "Screen Recording",
            state: permissions.screenRecording ? .ready : (needsCapture ? .attention : .notNeeded),
            detail: permissions.screenRecording ? "Window previews and the lid fold can capture the desktop."
                : (waitingForRestart ? "If you just turned it on, restart Sense to finish." : "Needed for the lid fold and window previews."),
            actionTitle: permissions.screenRecording ? nil : (waitingForRestart ? "Restart Sense" : "Allow…"),
            action: { [weak self] in
                guard let self else { return }
                if waitingForRestart { self.restartForLidSetup() } else { self.permissions.requestScreenRecording() }
            }))

        if preferences.lidEffectEnabled {
            let ready = lid.angle != nil
            items.append(SetupItem(id: "hinge", title: "Hinge sensor", state: ready ? .ready : .attention,
                detail: ready ? "Reading the lid angle. Open position is learned automatically." : lid.status,
                actionTitle: ready ? nil : "Retry", action: { [weak self] in self?.lid.stop(); self?.lid.start() }))
        }
        if preferences.notchEnabled && preferences.mediaEnabled {
            items.append(SetupItem(id: "media", title: "Now Playing", state: media.systemAvailable ? .ready : .attention,
                detail: media.systemAvailable ? "Reading the active media session." : (media.message ?? "No media session yet. Play something, or check Automation access for Music and Spotify."),
                actionTitle: media.systemAvailable ? nil : "Automation…", action: { [permissions] in permissions.openPrivacy("Privacy_Automation") }))
        }
        if preferences.notchEnabled && preferences.toolShortcutsEnabled {
            let blocked = toolShortcuts.unavailable
            items.append(SetupItem(id: "shortcuts", title: "Tool shortcuts", state: blocked.isEmpty ? .ready : .attention,
                detail: blocked.isEmpty ? "All island shortcuts are registered." : "Taken by another app: " + blocked.joined(separator: ", ") + ". Pick other modifiers in Dynamic Island settings.",
                actionTitle: blocked.isEmpty ? nil : "Change…", action: { [weak self] in self?.openSettings(page: .notch) }))
        }
        if preferences.notchEnabled && preferences.autoHideFocus {
            let monitor = autoHide
            items.append(SetupItem(id: "focus", title: "Focus status", state: monitor.focusAuthorized ? .ready : (monitor.focusDenied ? .attention : .ready),
                detail: monitor.focusAuthorized ? "The island hides while a Focus is on." : (monitor.focusDenied ? "Focus access is off, so Sense can’t tell when a Focus is on." : "Waiting for your answer."),
                actionTitle: monitor.focusDenied ? "Open Settings…" : nil, action: { [permissions] in permissions.openPrivacy("Privacy_Focus") }))
        }
        if preferences.notchEnabled && preferences.liveTransfers {
            let problem = notch.transfers.accessProblem
            items.append(SetupItem(id: "transfers", title: "Downloads folder", state: problem == nil ? .ready : .attention,
                detail: problem ?? "Watching for downloads and received AirDrops.",
                actionTitle: problem == nil ? nil : "Files & Folders…", action: { [permissions] in permissions.openPrivacy("Privacy_FilesAndFolders") }))
        }
        if preferences.notchEnabled && preferences.calendarPreview {
            let access = notch.calendar.access
            items.append(SetupItem(id: "calendar", title: "Calendar", state: access == .granted ? .ready : (access == .denied ? .attention : .ready),
                detail: access == .denied ? "Calendar access is off." : (access == .granted ? "Showing your next event." : "Waiting for your answer."),
                actionTitle: access == .denied ? "Open Settings…" : nil, action: { [permissions] in permissions.openPrivacy("Privacy_Calendars") }))
        }
        return items
    }
}

struct SetupChecklist: View {
    let model: SenseAppModel
    var body: some View {
        let items = model.setupItems
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
                    SettingsLabel(title: item.title, detail: item.detail)
                }
            }
        } header: {
            Label(problems == 0 ? "Everything you’ve turned on is ready" : "\(problems) \(problems == 1 ? "thing needs" : "things need") attention",
                  systemImage: problems == 0 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(problems == 0 ? Color.green : .orange)
        }
    }
}

extension SenseAppModel {
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
            "Sense \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))",
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
