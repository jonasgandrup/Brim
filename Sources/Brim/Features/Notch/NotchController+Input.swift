import SwiftUI
import AppKit
import Observation
import CoreAudio

/// The pointer, drags, trackpad gestures and the keyboard: how you reach the island.
extension NotchController {
    // MARK: Pointer and drags

    func trackMouseEvent(_ event: NSEvent) {
        guard systemMenuDepth == 0 else { return }
        switch event.type {
        case .leftMouseDown:
            dragStartChangeCount = NSPasteboard(name: .drag).changeCount
            startDragPolling()
            // With nothing on screen the panel lets clicks through, so a click on the bare notch is noticed here.
            if presentation == .hidden, containsPointer(NSEvent.mouseLocation) { openInContext() }
        case .leftMouseDragged: startDragPolling()
        case .leftMouseUp: endFileDrag()
        default: break
        }
        updateInteraction()
    }
    private func startDragPolling() {
        guard dragPollTimer == nil else { return }
        let timer = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollFileDrag() }
        }
        dragPollTimer = timer
        // Native drag sessions run in event-tracking mode; polling must survive that mode.
        RunLoop.main.add(timer, forMode: .common)
    }
    private func pollFileDrag() {
        guard NSEvent.pressedMouseButtons & 1 != 0 else { endFileDrag(); return }
        guard shows(.files) else { return }
        let board = NSPasteboard(name: .drag)
        guard board.changeCount != dragStartChangeCount,
              board.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else { return }
        if !fileDragActive { fileDragActive = true }
        updateInteraction(scheduleHover: false)
        guard let displayFrame else { return }
        let target = layout.frame(on: displayFrame, expanded: false).insetBy(dx: -22, dy: -14)
        if target.contains(NSEvent.mouseLocation) { setDropTargeted(true) }
    }
    private func endFileDrag() {
        dragPollTimer?.invalidate(); dragPollTimer = nil
        fileDragActive = false; dropTargeted = false
        updateInteraction(scheduleHover: false)
        if expanded && !pointerInside { collapseAfterDelay() }
    }
    func setDropTargeted(_ targeted: Bool, clipboard: Bool = false) {
        guard !targeted || shows(clipboard ? .clipboard : .files) else { return }
        if targeted && !dropTargeted { haptic(.open); dropZone = .shelf }
        if targeted { dropIsFiles = !clipboard }
        dropTargeted = targeted
        if targeted { selectedTab = clipboard ? .clipboard : .files; setExpanded(true) }
        else if !pointerInside { collapseAfterDelay() }
    }
    func finishFileDrop(clipboard: Bool = false) {
        haptic(.land)
        dropTargeted = false; fileDragActive = false; selectedTab = clipboard ? .clipboard : .files
        // The shelf stays open only while hovered; retained references survive collapse and Space changes.
        updateInteraction(scheduleHover: false)
        if !pointerInside { collapseAfterDelay() }
    }
    /// Follows a file drag across the expanded island, so the half under the pointer lights up.
    func updateDropZone(x: CGFloat, width: CGFloat) {
        let zone = DropZone.at(x: x, width: width, airDropAvailable: dropIsFiles && airDropAvailable)
        if zone != dropZone { dropZone = zone; haptic(.open) }
    }
    /// Files dropped on the AirDrop half wait on the shelf too, then go straight to the AirDrop picker.
    func airDrop(_ providers: [NSItemProvider]) -> Bool {
        shelf.accept(providers) { [weak self] urls in
            guard let self else { return }
            self.shelf.select(Set(urls.map(\.standardizedFileURL)))
            self.shelf.actions.airDrop()
        }
    }
    // MARK: Gestures
    /// The click that ends a Force Click mustn't then also count as an ordinary click on the island.
    var recentlyForceClicked: Bool { ProcessInfo.processInfo.systemUptime - forceClickedAt < 0.8 }
    private var gesturesEnabled: Bool { preferences?.islandGestures == true && !expanded && presentation == .compact }
    /// Over the compact island, a sideways swipe hides what's on it, at every level as on iPhone. Returns true when used.
    func handleScroll(_ event: NSEvent, at location: CGPoint) -> Bool {
        guard !expanded, presentation == .compact, containsPointer(location) else { return false }
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) { swipeTravel = 0; swipeFired = false }
        // The gesture is what the fingers did, not the momentum after they lift.
        guard event.momentumPhase.isEmpty else { return true }
        let fingers = IslandGesture.fingers(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY, inverted: event.isDirectionInvertedFromDevice)
        guard abs(fingers.right) > abs(fingers.up) else { return false }
        guard event.hasPreciseScrollingDeltas, !swipeFired else { return true }
        swipeTravel += fingers.right
        if abs(swipeTravel) >= IslandGesture.hideTravel {
            swipeFired = true
            haptic(.land)
            dismissActivities()
        }
        return true
    }
    /// A Force Click on the compact island opens it on what it's showing, like a long press on iPhone.
    func receivePressure(_ event: NSEvent) {
        defer { pressureStage = event.stage }
        guard event.stage == 2, pressureStage < 2, gesturesEnabled, containsPointer(NSEvent.mouseLocation) else { return }
        forceClickedAt = ProcessInfo.processInfo.systemUptime
        feedbackTask?.cancel(); clearFeedback()
        selectedTab = contextTab()
        setExpanded(true)
    }
    // MARK: Keyboard
    func startKeyboardSession() {
        collapseAfterDelay(seconds: 8)
        keys.start { [weak self] key in self?.receive(key) }
    }
    func receive(_ key: IslandKeys.Key) {
        guard expanded else { keys.stop(); return }
        switch key {
        case .escape: setExpanded(false); return
        case .left, .right:
            let tabs = visibleTabs
            let index = tabs.firstIndex(of: selectedTab) ?? 0
            selectedTab = tabs[(index + (key == .right ? 1 : tabs.count - 1)) % tabs.count]
        case .return, .space:
            if displayedTab == .music, media?.source != nil { media?.command("playpause") }
        }
        collapseAfterDelay(seconds: 8)
    }
    func openTimerFromMenu() { selectedTab = .timer; openFromMenu() }
    func openTransfersFromMenu() { selectedTab = .transfers; openFromMenu() }
    func openClipboardFromMenu() { selectedTab = .clipboard; openFromMenu() }
    func openShelfFromMenu() { shelfSelected = true; openFromMenu() }
    func openFromMenu() { setExpanded(true); collapseAfterDelay(seconds: 5) }
    func openSettings() { setExpanded(false); onOpenSettings() }
    func connectTransfers() { preferences?.liveTransfers = true; transfers.start() }
    func connectMedia() {
        preferences?.mediaEnabled = true
        media?.start()
    }
    func allowPlayerAccess() {
        preferences?.playerAccess = true
        media?.playerAccess = true
    }
    func startTimer(minutes: Double) {
        countdown.start(seconds: minutes * 60)
        clock.mode = .timer; selectedTab = .timer
        showHUD(.init(symbol: "timer", tint: .orange, label: String(localized: "Timer started")))
    }
    func startFocus() {
        countdown.startFocus()
        clock.mode = .focus; selectedTab = .timer
        showHUD(.init(symbol: "brain.head.profile", tint: .red, label: String(localized: "Focus started")))
    }
    func pinClipboard() {
        if let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            shelf.add(urls); selectedTab = .files
        } else { clipboard.pin(); selectedTab = .clipboard }
        openFromMenu()
    }
    func configureShelfPersistence(_ keep: Bool) {
        guard let defaults = AppEnvironment.persistentDefaults else { return }
        if keep, shelf.persistence == nil {
            shelf.restore(from: defaults)
            shelf.persistence = defaults
        } else if !keep, shelf.persistence != nil {
            shelf.persistence = nil
        }
        // Clipboard pins follow the same switch; turning it off deletes the saved copies.
        if keep, clipboard.persistence == nil, let store = ClipboardPinStore.standard {
            clipboard.restore(from: store)
            clipboard.persistence = store
        } else if !keep, clipboard.persistence != nil {
            clipboard.persistence = nil
        }
    }
}
