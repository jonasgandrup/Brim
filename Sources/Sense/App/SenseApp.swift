import SwiftUI
import AppKit
import ServiceManagement

@main
@MainActor
enum SenseApp {
    private static let delegate = AppDelegate()
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.delegate = delegate
        application.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var statusBar: StatusBarController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let model = SenseAppModel.shared
        statusBar = StatusBarController(model: model)
        model.apply()
        if CommandLine.arguments.contains("--lid-setup") { model.openSettings(page: .lock) }
        else if !UserDefaults.standard.bool(forKey: "hasLaunched") || CommandLine.arguments.contains("--settings") || CommandLine.arguments.contains("--smoke-test") {
            if !CommandLine.arguments.contains("--smoke-test") { UserDefaults.standard.set(true, forKey: "hasLaunched") }
            model.openSettings()
        }
        if CommandLine.arguments.contains("--smoke-test") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                await model.exportSmokeTest()
                NSApp.terminate(nil)
            }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { SenseAppModel.shared.stop() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SenseAppModel.shared.openSettings(); return true
    }
}

@MainActor @Observable
final class SenseAppModel {
    static let shared = SenseAppModel()
    let preferences = Preferences(defaults: CommandLine.arguments.contains("--smoke-test")
        ? UserDefaults(suiteName: "dk.jonasgandrup.Sense.SmokeTest")! : .standard)
    let permissions = PermissionService()
    let status = SystemStatus()
    let media = MediaService()
    let notch = NotchController()
    let switcher = WindowSwitcher()
    let scale = ScaleModel()
    let lock = LockScreenService()
    let lid = LidEffectService()
    var lidFoldReadiness: LidFoldReadiness {
        .resolve(enabled: preferences.lockEnabled && preferences.lidEffectEnabled, screenRecording: permissions.screenRecording,
                 reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, angle: lid.angle)
    }
    var page: SettingsPage = .general
    var loginEnabled = SMAppService.mainApp.status == .enabled
    var loginMessage: String?
    private var settingsWindow: NSWindow?
    private var scaleWindow: NSWindow?
    private var activationObserver: NSObjectProtocol?
    private init() {
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.permissions.refresh(); self.switcher.configure(preferences: self.preferences)
                self.loginEnabled = SMAppService.mainApp.status == .enabled
            }
        }
    }
    func apply() {
        preferences.applyAppearance()
        permissions.refresh()
        if preferences.notchEnabled {
            status.start(); notch.start(preferences: preferences, status: status, media: media, onOpenSettings: { [weak self] in self?.openSettings(page: .notch) })
        } else { notch.stop(); status.stop() }
        if preferences.notchEnabled && preferences.mediaEnabled { media.start() } else { media.stop() }
        switcher.onVisibilityChanged = { [weak self] visible in self?.notch.setSwitcherOverlayActive(visible) }
        switcher.configure(preferences: preferences)
        lock.configure(preferences: preferences, notch: notch)
        if preferences.lockEnabled && preferences.lidEffectEnabled { lid.start() } else { lid.stop() }
        if !preferences.scaleEnabled { scaleWindow?.close(); scale.release() }
    }
    func stop() { scale.native.stop(); notch.clock.stop(); notch.countdown.cancel(); lid.stop(); switcher.stop(); notch.stop(); status.stop(); media.stop() }
    func openSettings(page: SettingsPage? = nil) {
        if let page { self.page = page }
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 690), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "Sense Settings"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
            window.minSize = NSSize(width: 790, height: 600); window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(model: self))
            window.setFrameAutosaveName(CommandLine.arguments.contains("--smoke-test") ? "SenseSmokeSettings" : "SenseSettings"); window.center()
            settingsWindow = window
        }
        NSApp.activate(); settingsWindow?.makeKeyAndOrderFront(nil)
    }
    func openScale() {
        guard preferences.scaleEnabled else { return }
        if scaleWindow == nil {
            let window = ScaleWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 680), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.weighing = scale.native
            window.title = "Trackpad Scale"; window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ScaleView(model: scale, preferences: preferences))
            window.center(); scaleWindow = window
        }
        scale.native.start()
        NSApp.activate(); scaleWindow?.makeKeyAndOrderFront(nil)
    }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            loginMessage = SMAppService.mainApp.status == .requiresApproval ? "Approve Sense in System Settings → General → Login Items." : nil
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch { loginEnabled = SMAppService.mainApp.status == .enabled; loginMessage = error.localizedDescription }
    }
    func exportSmokeTest() async {
        let output = ProcessInfo.processInfo.environment["SENSE_SMOKE_OUTPUT"] ?? "/tmp/sense-smoke"
        try? FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        // cacheDisplay omits native scroll-layer contents on current macOS.
        // Render the identical settings content without the scrolling wrapper for exported previews.
        settingsWindow?.setContentSize(NSSize(width: 900, height: 840))
        settingsWindow?.contentView = NSHostingView(rootView: SettingsView(model: self, captureMode: true))
        var rendered: [String] = []
        for appearance in ["light", "dark"] {
            preferences.appearance = appearance
            for section in SettingsPage.allCases {
                page = section
                settingsWindow?.setContentSize(NSSize(width: 900, height: section == .lock ? 1020 : (section == .notch ? 1120 : 840)))
                try? await Task.sleep(for: .milliseconds(250))
                if let view = settingsWindow?.contentView,
                   let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    let name = "\(section.id.replacingOccurrences(of: " ", with: "-").lowercased())-\(appearance).png"
                    if let data = bitmap.representation(using: .png, properties: [:]) {
                        try? data.write(to: URL(fileURLWithPath: output).appendingPathComponent(name))
                        rendered.append(name)
                    }
                }
            }
        }
        openScale()
        try? await Task.sleep(for: .milliseconds(250))
        if let view = scaleWindow?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: output).appendingPathComponent("scale.png"))
                rendered.append("scale.png")
            }
        }
        let forceAvailable = scale.native.available
        let forceSamples = scale.native.receivedSamples
        scaleWindow?.close()
        preferences.appearance = "system"
        rendered += await notch.exportPreview(to: URL(fileURLWithPath: output))
        rendered += await DesktopFoldView.exportPreviews(to: URL(fileURLWithPath: output))
        let fileActionsCheck = CommandLine.arguments.contains("--check-file-actions") ? await notch.verifyFileActions() : [:]
        var mediaCheck: [String: Any] = [:]
        if CommandLine.arguments.contains("--check-media") {
            let discovered = await MediaPlayerDiscovery.players()
            var playerChecks: [[String: Any]] = []
            for player in discovered {
                let pinned = await SystemMediaBridge.snapshot(for: player)
                var check: [String: Any] = ["name": player.name, "sameApp": pinned?.source == player.source, "hasTrack": pinned?.hasMedia == true]
                if let pinned, pinned.hasMedia, let path = pinned.playerPath, let title = pinned.title {
                    let item = MediaItemIdentity(source: player.source, title: title, identifier: pinned.identifier ?? "", playerPath: path)
                    check["boundPauseValidatedWithoutPlaybackChange"] = await SystemMediaBridge.send(.init(item: item, action: .pause), validateOnly: true) == .validated
                }
                playerChecks.append(check)
            }
            mediaCheck["discoveredPlayers"] = playerChecks
            let snapshot = await SystemMediaBridge.snapshot()
            mediaCheck["systemBridgeAvailable"] = snapshot?.available == true
            mediaCheck["hasMediaSession"] = snapshot?.hasMedia == true
            mediaCheck["sourceName"] = snapshot?.sourceName ?? "None"
            mediaCheck["hasPlaybackRate"] = snapshot?.rate != nil
            mediaCheck["advertisesSeeking"] = snapshot?.canSeek == true
            if let snapshot, let source = snapshot.source, let title = snapshot.title, let position = snapshot.position {
                let item = MediaItemIdentity(source: source, title: title, identifier: snapshot.identifier ?? "", playerPath: snapshot.playerPath ?? "")
                mediaCheck["seekParametersValidatedWithoutPlaybackChange"] = await SystemMediaBridge.seek(.init(item: item, position: position), validateOnly: true)
            }
            if let snapshot, let source = snapshot.source, let title = snapshot.title {
                let item = MediaItemIdentity(source: source, title: title, identifier: snapshot.identifier ?? "", playerPath: snapshot.playerPath ?? "")
                let result = await SystemMediaBridge.send(.init(item: item, action: .pause), validateOnly: true)
                mediaCheck["playerBoundPauseValidatedWithoutPlaybackChange"] = result == .validated
                var wrongPlayer = item; wrongPlayer.playerPath = "not-the-displayed-player"
                let rejected = await SystemMediaBridge.send(.init(item: wrongPlayer, action: .pause), validateOnly: true)
                mediaCheck["rejectsAnotherSessionInTheSameApp"] = rejected != .validated && rejected != .submitted
            }
            mediaCheck["hasTimeline"] = snapshot?.position != nil && (snapshot?.duration ?? 0) > 0
            mediaCheck["rejectsChangedSource"] = !(await SystemMediaBridge.command("playpause", source: "dk.jonasgandrup.Sense.NotTheActivePlayer"))
            if let snapshot, let name = await notch.exportMediaPreview(snapshot, to: URL(fileURLWithPath: output)) { rendered.append(name) }
        }
        var missionControlRestoredIsland: Bool? = nil
        if CommandLine.arguments.contains("--check-mission-control") {
            notch.shelf.add([Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist")])
            notch.openShelfFromMenu()
            try? await Task.sleep(for: .milliseconds(400))
            let missionControl = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
            _ = try? await NSWorkspace.shared.openApplication(at: missionControl, configuration: .init())
            try? await Task.sleep(for: .seconds(1))
            _ = try? await NSWorkspace.shared.openApplication(at: missionControl, configuration: .init())
            try? await Task.sleep(for: .seconds(2))
            for _ in 0..<20 {
                if !notch.desktopTransition && notch.transitionDiagnostics["panelVisible"] == true { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            missionControlRestoredIsland = !notch.desktopTransition && notch.transitionDiagnostics["panelVisible"] == true
            notch.shelf.clear()
            try? await Task.sleep(for: .milliseconds(450))
        }
        var spacesCheck: [String: Any] = [:]
        if CommandLine.arguments.contains("--check-spaces") {
            let before = notch.spaceSlideCount
            notch.shelf.add([Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist")])
            notch.openShelfFromMenu()
            let window = NSWindow(contentRect: NSRect(x: 120, y: 150, width: 720, height: 400), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "Sense · Spaces check"
            window.collectionBehavior = [.fullScreenPrimary]
            window.contentView = NSHostingView(rootView: Text("Checking the island during a native desktop transition…").padding(40))
            NSApp.activate(); window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(400))
            window.toggleFullScreen(nil)
            for _ in 0..<50 {
                if window.styleMask.contains(.fullScreen) { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            let entered = window.styleMask.contains(.fullScreen)
            // Let AppKit finish its native transition before asking it to reverse.
            try? await Task.sleep(for: .seconds(1))
            if entered {
                window.toggleFullScreen(nil)
                for _ in 0..<50 {
                    if !window.styleMask.contains(.fullScreen) { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            window.close()
            for _ in 0..<50 {
                if !notch.desktopTransition { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            spacesCheck = ["enteredFullScreen": entered, "observedDesktopSurfaces": notch.spaceSlideCount > before,
                           "restored": !notch.desktopTransition, "shelfPreserved": !notch.shelf.files.isEmpty]
            notch.shelf.clear()
            try? await Task.sleep(for: .milliseconds(450))
        }
        let hoverAfterTransitions = await notch.verifyIdleHover()
        let statusBar = (NSApp.delegate as? AppDelegate)?.statusBar
        let statusFrame = statusBar?.buttonFrame ?? .zero
        let islandFrame = notch.panelFrame ?? .zero
        let report: [String: Any] = ["app": "Sense", "bundleID": Bundle.main.bundleIdentifier ?? "unbundled", "settingsWindow": settingsWindow != nil, "rendered": rendered, "previewMode": "settings content without scroll wrapper",
            "menuBarIconVisible": statusBar?.isVisible ?? false,
            "menuBarFrame": [statusFrame.minX, statusFrame.minY, statusFrame.width, statusFrame.height],
            "menuEntries": statusBar?.menuTitles ?? [],
            "islandPanelFrame": [islandFrame.minX, islandFrame.minY, islandFrame.width, islandFrame.height],
            "islandExpectedPanelSize": [notch.layout.expandedSize.width, notch.layout.expandedSize.height],
            "islandIdleHidden": notch.presentation == .hidden,
            "islandIdlePassesThroughMouse": notch.ignoresMouseEvents,
            "islandTransitionsKeepPanelStable": notch.transitionsKeepPanelStable,
            "islandRapidTabChangesSettle": notch.rapidTabChangesSettle,
            "islandPointerExitClosesPromptly": notch.pointerExitClosesPromptly,
            "islandIdleHoverOpens": notch.idleHoverOpensIsland,
            "islandHoverAfterTransitions": hoverAfterTransitions,
            "hoverChecks": notch.hoverCheckDiagnostics,
            "islandHidesForDesktopTransitions": notch.desktopTransitionHidesIsland,
            "islandTransitionState": notch.transitionDiagnostics,
            "spacesCheck": spacesCheck,
            "fileActionsCheck": fileActionsCheck,
            "mediaCheck": mediaCheck,
            "powerNotificationsActive": status.powerNotificationsActive,
            "chargeTarget": preferences.chargeTarget,
            "missionControlRestoredIsland": missionControlRestoredIsland as Any? ?? NSNull(),
            "systemSwitcherObserved": notch.systemSwitcherObserved,
            "scaleForceDeviceAvailable": forceAvailable, "scaleForceFramesObserved": forceSamples,
            "spaceGestureTrackpadDevices": notch.trackpadDeviceCount,
            "observedContactGestures": notch.observedContactGestures,
            "systemSwitcherHidIsland": notch.systemSwitcherHidIsland,
            "islandNativeSnapshots": notch.nativeSnapshotCount,
            "lidFoldReadiness": lidFoldReadiness.message,
            "lidSensorStatus": lid.status, "lidAngle": lid.angle as Any? ?? NSNull(),
            "screens": NSScreen.screens.count, "notchedScreens": NSScreen.screens.filter { $0.safeAreaInsets.top > 0 }.count,
            "accessibility": permissions.accessibility, "screenRecording": permissions.screenRecording, "switcher": switcher.status,
            "batteryPercent": status.battery as Any? ?? NSNull(), "volume": status.volume as Any? ?? NSNull()]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: output).appendingPathComponent("report.json"))
        }
    }
}
