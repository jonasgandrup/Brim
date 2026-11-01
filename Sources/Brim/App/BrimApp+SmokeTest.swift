#if DEBUG
import SwiftUI
import AppKit
import ScreenCaptureKit

/// Captures one of Brim's own windows as it appears on screen, including scrolling Forms that
/// `cacheDisplay` leaves blank. Only this process's windows are visible to the API, so no permission is needed.
@MainActor enum SmokeCapture {
    static func png(of window: NSWindow) async -> Data? {
        if #available(macOS 14.4, *), let content = try? await SCShareableContent.currentProcess,
           let match = content.windows.first(where: { $0.windowID == window.windowID }) {
            let configuration = SCStreamConfiguration()
            configuration.width = Int(window.frame.width * 2); configuration.height = Int(window.frame.height * 2)
            configuration.showsCursor = false
            if let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: match), configuration: configuration) {
                return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            }
        }
        guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])
    }
}

/// The `--smoke-test` run: renders every settings page and island state to PNGs and writes a JSON report.
extension BrimAppModel {
    func exportSmokeTest() async {
        let output = ProcessInfo.processInfo.environment["BRIM_SMOKE_OUTPUT"] ?? "/tmp/brim-smoke"
        try? FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        settingsWindow?.setContentSize(NSSize(width: 900, height: 840))
        // Labs is off by default; the run still has to exercise the hinge and force sensors.
        preferences.lidEffectEnabled = true; preferences.scaleEnabled = true; apply()
        var rendered: [String] = []
        for appearance in [Appearance.light, .dark] {
            preferences.appearance = appearance
            for section in SettingsPage.allCases {
                page = section
                try? await Task.sleep(for: .milliseconds(450))
                if let window = settingsWindow, let data = await SmokeCapture.png(of: window) {
                    let name = "\(section.id.replacingOccurrences(of: " ", with: "-").lowercased())-\(appearance.rawValue).png"
                    try? data.write(to: URL(fileURLWithPath: output).appendingPathComponent(name))
                    rendered.append(name)
                }
            }
            for section in IslandSection.allCases {
                page = .notch; islandSection = section
                try? await Task.sleep(for: .milliseconds(450))
                if let window = settingsWindow, let data = await SmokeCapture.png(of: window) {
                    let name = "island-\(section.id.replacingOccurrences(of: " & ", with: "-").replacingOccurrences(of: " ", with: "-").lowercased())-\(appearance.rawValue).png"
                    try? data.write(to: URL(fileURLWithPath: output).appendingPathComponent(name))
                    rendered.append(name)
                }
            }
            islandSection = nil
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
        let forceAvailable = scale.available
        let forceSamples = scale.receivedSamples
        scaleWindow?.close()
        preferences.appearance = .system
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
            let layoutSnapshot = SystemMediaSnapshot(available: true, title: "Preview track", artist: "Layout preview · no audio", source: "brim.preview.player", sourceName: "Preview Player", rate: 0, duration: 240, position: 80, identifier: "layout-preview", canSeek: false, processID: 1)
            if let name = await notch.exportMediaPreview(layoutSnapshot, to: URL(fileURLWithPath: output), layoutPreview: true) { rendered.append(name) }
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
            window.title = "Brim · Spaces check"
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
        let shortcutChecks = toolShortcuts.checkDelivery()
        let report: [String: Any] = ["activitiesAndPresentation": notch.smoke.activityChecks, "toolShortcuts": shortcutChecks,"app": "Brim", "bundleID": Bundle.main.bundleIdentifier ?? "unbundled", "settingsWindow": settingsWindow != nil, "rendered": rendered, "previewMode": "own-window capture",
            "menuBarIconVisible": statusBar?.isVisible ?? false,
            "menuBarFrame": [statusFrame.minX, statusFrame.minY, statusFrame.width, statusFrame.height],
            "menuEntries": statusBar?.menuTitles ?? [],
            "islandPanelFrame": [islandFrame.minX, islandFrame.minY, islandFrame.width, islandFrame.height],
            "islandExpectedPanelSize": [notch.layout.expandedSize.width, notch.layout.expandedSize.height],
            "islandIdleHidden": notch.presentation == .hidden,
            "islandIdlePassesThroughMouse": notch.ignoresMouseEvents,
            "islandTransitionsKeepPanelStable": notch.smoke.transitionsKeepPanelStable,
            "islandRapidTabChangesSettle": notch.smoke.rapidTabChangesSettle,
            "nativeMenusRetainIsland": notch.smoke.nativeMenusRetainIsland,
            "islandPointerExitClosesPromptly": notch.smoke.pointerExitClosesPromptly,
            "islandIdleHoverOpens": notch.smoke.idleHoverOpensIsland,
            "islandHoverAfterTransitions": hoverAfterTransitions,
            "hoverChecks": notch.smoke.hoverCheckDiagnostics,
            "islandHidesForDesktopTransitions": notch.smoke.desktopTransitionHidesIsland,
            "islandTransitionState": notch.transitionDiagnostics,
            "spacesCheck": spacesCheck,
            "fileActionsCheck": fileActionsCheck,
            "mediaCheck": mediaCheck,
            "powerNotificationsActive": status.powerNotificationsActive,
            "chargeTarget": preferences.chargeTarget,
            "missionControlRestoredIsland": missionControlRestoredIsland as Any? ?? NSNull(),
            "systemSwitcherObserved": notch.smoke.systemSwitcherObserved,
            "scaleForceDeviceAvailable": forceAvailable, "scaleForceFramesObserved": forceSamples,
            "spaceGestureTrackpadDevices": notch.trackpadDeviceCount,
            "observedContactGestures": notch.observedContactGestures,
            "systemSwitcherHidIsland": notch.smoke.systemSwitcherHidIsland,
            "islandNativeSnapshots": notch.smoke.nativeSnapshotCount,
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
#endif
