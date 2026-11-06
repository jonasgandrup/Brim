#if DEBUG
import SwiftUI
import AppKit
import ScreenCaptureKit

/// Results the DEBUG smoke test records while it drives the real island. Absent from release builds.
struct NotchSmokeChecks {
    var nativeMenusRetainIsland = false
    var rapidTabChangesSettle = false
    var transitionsKeepPanelStable = true
    var pointerExitClosesPromptly = false
    var idleHoverOpensIsland = false
    var nativeSnapshotCount = 0
    var activityChecks: [String: Bool] = [:]
    var hoverCheckDiagnostics: [[String: Bool]] = []
    var switcherTucksIsland = false
}

extension NotchController {
    func verifyIdleHover() async -> Bool {
        for _ in 0..<40 {
            if !tuckedAway { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        setExpanded(false)
        try? await Task.sleep(for: .milliseconds(250))
        var check = transitionDiagnostics
        check["hoverEnabled"] = preferences?.hoverToExpand == true
        defer { previewPointer = nil }
        if let displayFrame {
            let target = layout.idleHoverFrame(on: displayFrame)
            // Keep the test's pointer source stable if the user moves their real mouse during capture.
            previewPointer = CGPoint(x: target.midX, y: target.minY + 2)
            check["targetInside"] = containsPointer(previewPointer!)
            updateInteraction()
        }
        try? await Task.sleep(for: HoverIntent.dwell + .milliseconds(150))
        let opened = expanded && panel?.isVisible == true && panel?.alphaValue == 1
        check["opened"] = opened; check["transitionAfterHover"] = tuckedAway
        smoke.hoverCheckDiagnostics.append(check)
        previewPointer = nil
        hover(false); setExpanded(false)
        try? await Task.sleep(for: .milliseconds(250))
        return opened
    }
    func verifyFileActions() async -> [String: Bool] {
        let urls = ["Contents/Info.plist", "Contents/Resources/Brim.icns"].map { Bundle.main.bundleURL.appendingPathComponent($0) }
        shelf.add(urls); shelf.select(Set(urls)); openShelfFromMenu()
        previewPointer = surfaceFrame.map { CGPoint(x: $0.midX, y: $0.midY) }
        try? await Task.sleep(for: .milliseconds(500))
        func findView<T: NSView>(_ type: T.Type, in view: NSView?, matching: (T) -> Bool = { _ in true }) -> T? {
            guard let view else { return nil }
            if let match = view as? T, matching(match) { return match }
            for child in view.subviews { if let match = findView(type, in: child, matching: matching) { return match } }
            return nil
        }
        var check: [String: Bool] = [:]
        let collection = findView(ShelfCollectionView.self, in: panel?.contentView)
        check["nativeCollectionShowsFiles"] = collection?.numberOfItems(inSection: 0) == 2
        check["multipleSelection"] = collection?.selectionIndexPaths.count == 2
        if let collection, let panel, let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49) {
            collection.keyDown(with: event)
        }
        try? await Task.sleep(for: .milliseconds(500))
        check["quickLookWindowVisible"] = shelf.actions.previewVisible
        check["quickLookHasSelectedItems"] = shelf.actions.previewItemCount == 2
        check["quickLookRetainsIslandHold"] = shelf.systemUIActive
        check["spaceOpensQuickLook"] = shelf.actions.previewVisible && shelf.actions.previewItemCount == 2 && shelf.systemUIActive
        shelf.actions.closePreview()
        check["previewClosesCleanly"] = !shelf.actions.previewVisible && !shelf.systemUIActive
        openShelfFromMenu()
        try? await Task.sleep(for: .milliseconds(400))
        if let button = findView(NSButton.self, in: panel?.contentView, matching: { $0.identifier?.rawValue == "Brim.FileShare" }),
           let coordinator = button.target as? FileShareButton.Coordinator {
            let location = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
            if let window = button.window {
                for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
                    if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) { NSApp.postEvent(event, atStart: false) }
                }
            }
            try? await Task.sleep(for: .milliseconds(700))
            check["nativeShareButtonWired"] = button.isEnabled && button.action == #selector(FileShareButton.Coordinator.share(_:))
            check["nativeShareMouseDelivery"] = coordinator.picker != nil
            // AppKit may drop synthetic mouse events after Quick Look changes activation.
            // Exercise the button's actual target/action too, without choosing or sending a share.
            if coordinator.picker == nil { button.performClick(nil) }
            for _ in 0..<20 {
                if coordinator.servicesPrepared { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            check["nativeSharePickerOpens"] = coordinator.servicesPrepared && coordinator.picker != nil && shelf.systemUIActive
            coordinator.close()
            try? await Task.sleep(for: .milliseconds(300))
            check["shareCancelReleasesIsland"] = !shelf.systemUIActive
        } else { check["nativeSharePickerOpens"] = false }
        shelf.clear(); previewPointer = nil; selectedTab = .music; hover(false); setExpanded(false)
        try? await Task.sleep(for: .milliseconds(300))
        return check
    }
    private func capturePanel(named name: String, in directory: URL) async -> Bool {
        guard let panel else { return false }
        var data: Data?
        // This API exposes only our own capturable windows; no Screen Recording grant is requested.
        if #available(macOS 14.4, *), presentation != .hidden {
            if let content = try? await SCShareableContent.currentProcess,
               let window = content.windows.first(where: { $0.windowID == panel.windowID }) {
                let configuration = SCStreamConfiguration()
                configuration.width = Int(panel.frame.width * 2)
                configuration.height = Int(panel.frame.height * 2)
                configuration.showsCursor = false; configuration.ignoreShadowsSingleWindow = true
                if let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration) {
                    data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
                    smoke.nativeSnapshotCount += 1
                }
            }
        }
        if data == nil, let view = panel.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            data = bitmap.representation(using: .png, properties: [:])
        }
        guard let data else { return false }
        do { try data.write(to: directory.appendingPathComponent(name)); return true }
        catch { return false }
    }
    func exportMediaPreview(_ snapshot: SystemMediaSnapshot, to directory: URL, layoutPreview: Bool = false) async -> String? {
        for _ in 0..<50 {
            if !tuckedAway { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard !tuckedAway, snapshot.hasMedia, let panel, let status, let originalView = panel.contentView else { return nil }
        let suite = "Brim.MediaPreview.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return nil }
        let previewPreferences = Preferences(defaults: defaults); previewPreferences.mediaEnabled = true
        let readOnlyMedia = MediaService(defaults: defaults); readOnlyMedia.apply(snapshot)
        if layoutPreview {
            let player = MediaPlayer(source: "brim.preview.player", name: "Preview Player", processID: 1)
            readOnlyMedia.playersReader = { [player] }
            readOnlyMedia.playerReader = { _ in snapshot }
            readOnlyMedia.snapshotReader = { snapshot }
            readOnlyMedia.playbackTransport = { _, _ in .failed }
            readOnlyMedia.sleepTimer.pause = { _ in .unavailable }
            readOnlyMedia.selectPlayer(player)
            for _ in 0..<20 {
                if !readOnlyMedia.selectionLoading { break }
                try? await Task.sleep(for: .milliseconds(25))
            }
            readOnlyMedia.startSleepTimer(minutes: 30)
        } else { await readOnlyMedia.refreshPlayers() }
        let hosting = NSHostingView(rootView: IslandView(controller: self, preferences: previewPreferences, status: status, media: readOnlyMedia))
        hosting.sizingOptions = []
        let originalFrame = panel.frame
        panel.contentView = hosting; panel.setFrame(originalFrame, display: true)
        let name = layoutPreview ? "player-sleep-layout-preview.png" : "now-playing-live.png"
        var captured = false
        for _ in 0..<4 {
            if tuckedAway || preparingAfterTransition {
                try? await Task.sleep(for: .milliseconds(500)); continue
            }
            selectedTab = .music; setExpanded(true)
            previewPointer = surfaceFrame.map { CGPoint(x: $0.midX, y: $0.midY) }
            try? await Task.sleep(for: .milliseconds(500))
            guard expanded, displayedTab == .music, paneOpacity == 1, surfaceReveal == 1, !tuckedAway else { continue }
            let exported = await capturePanel(named: name, in: directory)
            if exported && expanded && !tuckedAway && surfaceReveal == 1 { captured = true; break }
        }
        if !captured { try? FileManager.default.removeItem(at: directory.appendingPathComponent(name)) }
        if layoutPreview {
            let mediaWasVisible = mediaVisible
            mediaVisible = true
            countdown.start(seconds: 240)
            // A pointer of its own, so these checks don't depend on what's happening on this Mac meanwhile.
            previewPointer = CGPoint(x: -10000, y: -10000); hover(false); setExpanded(false)
            try? await Task.sleep(for: .milliseconds(300))
            smoke.activityChecks["dualActivityPreviewRendered"] = await capturePanel(named: "dual-activities-compact.png", in: directory)
            mediaVisible = false
            try? await Task.sleep(for: .milliseconds(300))
            smoke.activityChecks["pausedMediaLeavesTimerInIsland"] = presentation == .compact && !hasDualActivities && !showsActivityBubble && compactLeadingTab == .timer
            _ = await capturePanel(named: "timer-over-paused-media.png", in: directory)
            mediaVisible = true
            openCompactActivity(.music)
            // A real click has the pointer on the island, and an open island with no pointer over it closes.
            previewPointer = surfaceFrame.map { CGPoint(x: $0.midX, y: $0.midY) }
            updateInteraction(scheduleHover: false)
            try? await Task.sleep(for: .milliseconds(80))
            smoke.activityChecks["musicClickOpensPlayer"] = expanded && selectedTab == .music
            openCompactActivity(.timer)
            previewPointer = surfaceFrame.map { CGPoint(x: $0.midX, y: $0.midY) }
            try? await Task.sleep(for: .milliseconds(350))
            smoke.activityChecks["timerClickOpensClock"] = expanded && selectedTab == .timer && displayedTab == .timer
            _ = await capturePanel(named: "dual-activities-timer.png", in: directory)
            let frame = panel.frame
            setPresentationMode(true)
            hover(true); openFromMenu(); openTool(.nowPlaying)
            try? await Task.sleep(for: .milliseconds(100))
            smoke.activityChecks["presentationBlocksHoverAndShortcuts"] = !panel.isVisible && panel.ignoresMouseEvents && presentation == .hidden && !expanded
            setAway(.desktopMoving, true); setAway(.desktopMoving, false, settle: .milliseconds(100))
            try? await Task.sleep(for: .milliseconds(350))
            smoke.activityChecks["presentationStaysHiddenAfterSpaceChange"] = !panel.isVisible && presentation == .hidden
            smoke.activityChecks["timerContinuesDuringPresentation"] = countdown.state.phase == .running && countdown.remaining > 0
            setPresentationMode(false)
            smoke.activityChecks["presentationRestoresCompactIsland"] = panel.isVisible && presentation == .compact && !expanded && panel.frame == frame
            countdown.cancel()
            previewPointer = nil; hover(false); setExpanded(false)
            // Checked in one step, before the visibility observer can react to the changed app.
            if media?.playing == true, let source = media?.source, let displayFrame {
                let notch = CGPoint(x: displayFrame.midX, y: displayFrame.maxY - 4)
                let front = frontApp, idle = preferences?.openWhenIdle ?? false
                preferences?.openWhenIdle = false
                mediaVisible = false
                frontApp = source
                let answers = presentation == .hidden && containsPointer(notch)
                frontApp = "brim.preview.another.app"
                let staysOut = presentation == .hidden && !containsPointer(notch)
                smoke.activityChecks["bareNotchAnswersOnlyForMediaHiddenInItsApp"] = answers && staysOut
                frontApp = front; preferences?.openWhenIdle = idle
            }
            mediaVisible = mediaWasVisible
        }
        readOnlyMedia.stop()
        panel.contentView = originalView; panel.setFrame(originalFrame, display: true)
        previewPointer = nil; hover(false); setExpanded(false)
        defaults.removePersistentDomain(forName: suite)
        try? await Task.sleep(for: .milliseconds(250))
        return captured ? name : nil
    }
    /// Empty files with everyday names, so previews show nobody's real documents.
    private static func sampleFiles() -> [URL] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BrimSampleFiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return ["Trip.pdf", "Photos.zip", "Budget.pdf", "Notes.txt"].map { name in
            let url = folder.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: Data()) }
            return url
        }
    }
    /// A real swipe can't be sent from here, so this starts just after it: hiding, what brings the island back, and the way in.
    func verifySwipeDismissal() async {
        guard let displayFrame else { return }
        for _ in 0..<30 where tuckedAway || preparingAfterTransition { try? await Task.sleep(for: .milliseconds(100)) }
        let idle = preferences?.openWhenIdle ?? false
        preferences?.openWhenIdle = false; previewPointer = CGPoint(x: -10000, y: -10000); setExpanded(false)
        countdown.start(seconds: 60)
        try? await Task.sleep(for: .milliseconds(250))
        let startsCompact = presentation == .compact
        dismissActivities()
        try? await Task.sleep(for: .milliseconds(250))
        let hides = presentation == .hidden && activitiesDismissed
        let notchAnswers = containsPointer(CGPoint(x: displayFrame.midX, y: displayFrame.maxY - 4))
        showHUD(.init(symbol: "speaker.wave.2.fill", level: 0.5, label: "Volume"), seconds: 0.3)
        let levelsStillShow = presentation == .compact
        try? await Task.sleep(for: .milliseconds(500))
        let hidesAgain = presentation == .hidden
        clipboard.add(.text("Swipe check"))
        try? await Task.sleep(for: .milliseconds(250))
        let newActivityReturns = presentation == .compact && !activitiesDismissed
        dismissActivities(); setExpanded(true)
        let openingResets = !activitiesDismissed
        setExpanded(false); clipboard.clear(); countdown.cancel(); preferences?.openWhenIdle = idle; previewPointer = nil
        try? await Task.sleep(for: .milliseconds(150))
        smoke.activityChecks["swipeHidesUntilSomethingNewArrives"] = startsCompact && hides && notchAnswers && levelsStillShow && hidesAgain && newActivityReturns && openingResets
    }
    /// Drives the real island over a pretend covered item, because a test can't move the actual pointer into the menu bar.
    func verifyWingClearance() async {
        guard layout.hasHardwareNotch, let displayFrame, let panel else { return }
        for _ in 0..<30 where tuckedAway || preparingAfterTransition { try? await Task.sleep(for: .milliseconds(100)) }
        let frame = layout.frame(on: displayFrame, expanded: false)
        let wings = MenuBarClearance.wings(of: frame, cutoutWidth: layout.cutoutWidth)
        guard let left = wings.first, let right = wings.last else { return }
        let reader = menuBarItemsReader
        smoke.activityChecks["menuBarItemsReadWithoutCrashing"] = reader(displayFrame).allSatisfy { $0.lowerBound <= $0.upperBound }
        countdown.start(seconds: 60)
        let top = frame.maxY
        let coveredPoint = CGPoint(x: left.lowerBound + 10, y: top), clearPoint = CGPoint(x: left.upperBound - 10, y: top)
        func move(_ point: CGPoint) async {
            previewPointer = point; updateInteraction(scheduleHover: false)
            try? await Task.sleep(for: .milliseconds(320))
        }
        menuBarItemsReader = { _ in [left.lowerBound...(left.lowerBound + 20)] }
        await move(CGPoint(x: frame.minX - 40, y: top))
        let startsCompact = presentation == .compact
        await move(clearPoint)
        let staysOverClearPart = presentation == .compact && !wingsAside
        await move(coveredPoint)
        let stepsAside = presentation == .hidden && wingsAside && panel.ignoresMouseEvents
        await move(clearPoint)
        let staysAsideAcrossWing = presentation == .hidden && wingsAside
        await move(CGPoint(x: frame.midX, y: top))
        let returnsAtCamera = presentation == .compact && !wingsAside
        await move(coveredPoint)
        await move(CGPoint(x: right.upperBound + 40, y: top))
        let returnsWhenPointerLeaves = presentation == .compact && !wingsAside && panel.isVisible
        menuBarItemsReader = { _ in [] }
        await move(coveredPoint)
        let nothingCoveredStays = presentation == .compact && !wingsAside
        smoke.activityChecks["wingsStepAsideOnlyForCoveredItems"] = startsCompact && staysOverClearPart && stepsAside && staysAsideAcrossWing
            && returnsAtCamera && returnsWhenPointerLeaves && nothingCoveredStays
        menuBarItemsReader = reader
        previewPointer = nil; countdown.cancel(); updateInteraction(scheduleHover: false)
    }
    func exportPreview(to directory: URL) async -> [String] {
        guard let panel else { return [] }
        var result: [String] = []
        let initialFrame = panel.frame
        smoke.idleHoverOpensIsland = await verifyIdleHover()
        for preview in 0..<21 {
            let isExpanded = preview != 0 && preview != 9 && (preview < 10 || preview >= 12) && preview != 16 && preview != 19
            feedback = nil
            selectedTab = preview >= 8 ? .timer : (preview >= 4 ? .clipboard : (preview >= 2 ? .files : .music))
            if preview == 3 { shelf.add(Self.sampleFiles()) }
            if preview == 5 {
                clipboard.add(.text("Pick up flowers on the way home"))
                clipboard.add(.link(URL(string: "https://developer.apple.com")!))
                if let icon = NSImage(contentsOf: Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Brim.icns")),
                   let tiff = icon.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) { clipboard.add(.image(png)) }
            }
            if preview == 6 { clipboard.clear(); selectedTab = .timer }
            if preview == 7 { selectedTab = .timer; countdown.start() }
            if preview == 8 { countdown.pause() }
            if preview == 9 { countdown.cancel() }
            if preview == 10 { shelf.clear(); selectedTab = .music; countdown.start() }
            if preview == 11 { countdown.cancel(); clipboard.add(.text("Compact clipboard check")); selectedTab = .music }
            if preview == 12 { clipboard.clear(); selectedTab = .timer; clock.mode = .stopwatch }
            if preview == 13 { clock.toggleStopwatch() }
            if preview == 14 { clock.resetStopwatch(); clock.mode = .alarm }
            if preview == 15 {
                // Sample levels for the rendering check only; the real card shows what System Information reports.
                clock.mode = .timer
                showFeedback("AirPods Pro", symbol: "airpods.pro", tint: .white,
                             device: BluetoothDevice(id: "smoke", name: "AirPods Pro", kind: "Headphones", left: 80, right: 76, batteryCase: 45), seconds: 10)
            }
            if preview == 16 { dismissFeedback(); shelf.clear(); activities.update(id: "smoke", title: "Exporting video", symbol: "film", progress: 0.4) }
            if preview == 17 { selectedTab = .transfers }
            if preview == 18 { activities.clear(); selectedTab = .files; setDropTargeted(true); updateDropZone(x: 380, width: 408) }
            if preview == 19 { setDropTargeted(false) }
            if preview == 20 { showFeedback("Downloaded Report.pdf", symbol: "arrow.down.circle.fill", tint: .blue, seconds: 10) }
            setExpanded(isExpanded)
            // Sample levels for the rendering check only, cleared before the next state's capture.
            if preview == 9 { showHUD(.init(symbol: "battery.100percent.bolt", tint: .green, label: "Charging", battery: 42, charging: true), seconds: 1) }
            if preview == 19 { showHUD(.init(symbol: "battery.25percent", tint: .red, label: "Battery low", battery: 15), seconds: 1) }
            previewPointer = isExpanded ? surfaceFrame.map { CGPoint(x: $0.midX, y: $0.midY) } : CGPoint(x: -10000, y: -10000)
            try? await Task.sleep(for: .milliseconds(650))
            let extras = [4: "clipboard-empty.png", 5: "clipboard-pins.png", 6: "timer-ready.png", 7: "timer-running.png", 8: "timer-paused.png", 9: "charging-compact.png", 10: "timer-compact.png", 11: "clipboard-compact.png", 12: "stopwatch-ready.png", 13: "stopwatch-running.png", 14: "alarm-ready.png", 15: "accessory-card.png", 16: "activity-compact.png", 17: "activity-expanded.png", 18: "drop-zones.png", 19: "battery-low-compact.png", 20: "notice.png"]
            let name = extras[preview] ?? (preview == 3 ? "file-shelf-items.png" : (preview == 2 ? "file-shelf-empty.png" :
                (isExpanded ? "island-expanded.png" : (presentation == .hidden ? "island-idle.png" : "island-compact.png"))))
            if await capturePanel(named: name, in: directory) { result.append(name) }
        }
        clock.mode = .timer
        setDropTargeted(false); activities.clear()
        dismissFeedback(); shelf.clear(); clipboard.clear(); countdown.cancel()
        // The real island with what's really playing, which the layout preview's stand-in player can't show.
        if media?.playing == true {
            previewPointer = CGPoint(x: -10000, y: -10000); hover(false); setExpanded(false)
            selectedTab = .music; countdown.start(seconds: 240)
            try? await Task.sleep(for: .milliseconds(800))
            if await capturePanel(named: "dual-live.png", in: directory) { result.append("dual-live.png") }
            countdown.cancel()
        }
        // The new install's look: one section, so no tab strip.
        let level = preferences?.level
        dismissFeedback(); shelf.clear(); clipboard.clear(); preferences?.level = .essentials; selectedTab = .music; setExpanded(true)
        previewPointer = surfaceFrame.map { CGPoint(x: $0.midX, y: $0.midY) }
        try? await Task.sleep(for: .milliseconds(650))
        if await capturePanel(named: "essentials-home.png", in: directory) { result.append("essentials-home.png") }
        preferences?.level = level
        dismissFeedback(); countdown.cancel(); clipboard.clear(); shelf.add([Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist")]); selectedTab = .files; previewPointer = nil
        setSwitcherOverlayActive(true)
        try? await Task.sleep(for: .milliseconds(420))
        let stayedHidden = tuckedAway && !panel.isVisible
        setAway(.desktopMoving, true); setSwitcherOverlayActive(false); setAway(.desktopMoving, false, settle: .milliseconds(120))
        smoke.switcherTucksIsland = stayedHidden && presentation == .hidden && panel.ignoresMouseEvents && !panel.isVisible
        try? await Task.sleep(for: .milliseconds(450))
        smoke.switcherTucksIsland = smoke.switcherTucksIsland && !tuckedAway && panel.isVisible
        shelf.clear(); shelfSelected = false
        for _ in 0..<3 {
            setExpanded(false)
            try? await Task.sleep(for: .milliseconds(50))
            setExpanded(true)
            try? await Task.sleep(for: .milliseconds(50))
        }
        setExpanded(true)
        previewPointer = surfaceFrame.map { CGPoint(x: $0.midX, y: $0.midY) }
        for tab: IslandTab in [.files, .music, .clipboard, .timer, .files] {
            selectedTab = tab
            try? await Task.sleep(for: .milliseconds(25))
        }
        try? await Task.sleep(for: .milliseconds(250))
        smoke.rapidTabChangesSettle = displayedTab == selectedTab && selectedTab == .files && paneOpacity == 1 && panel.frame == initialFrame
        previewPointer = nil
        let menu = NSMenu(title: "Preview menu tracking")
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        hover(false)
        try? await Task.sleep(for: .milliseconds(180))
        smoke.nativeMenusRetainIsland = expanded
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
        hover(false)
        try? await Task.sleep(for: .milliseconds(160))
        smoke.pointerExitClosesPromptly = !expanded
        setExpanded(false)
        try? await Task.sleep(for: .milliseconds(250))
        smoke.transitionsKeepPanelStable = panel.frame == initialFrame
        return result
    }
}
#endif
