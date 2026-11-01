import AppKit

/// Retained for the app's lifetime, independently of any SwiftUI window or scene.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let model: BrimAppModel
    private let item: NSStatusItem
    private let menu = NSMenu()
    var isVisible: Bool { item.isVisible && item.button?.window != nil }
    var buttonFrame: CGRect? {
        guard let button = item.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }
    var menuTitles: [String] { menu.items.filter { !$0.isSeparatorItem }.map(\.title) }

    init(model: BrimAppModel) {
        self.model = model
        item = NSStatusBar.system.statusItem(withLength: 28)
        super.init()
        item.autosaveName = "SenseStatusItem"
        item.isVisible = true
        if let button = item.button {
            // A hand-drawn template avoids depending on symbol availability in a particular SDK.
            let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
                // The island with its playback bars cut out, matching the app icon.
                NSColor.labelColor.setFill()
                NSBezierPath(roundedRect: NSRect(x: 0.5, y: 4, width: 17, height: 10), xRadius: 5, yRadius: 5).fill()
                NSGraphicsContext.current?.compositingOperation = .clear
                for (index, height) in [3.0, 6, 4].enumerated() {
                    NSBezierPath(roundedRect: NSRect(x: 0.5 + 5.75 + Double(index) * 2.25, y: 9 - height / 2, width: 1.25, height: height), xRadius: 0.625, yRadius: 0.625).fill()
                }
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                return true
            }
            image.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
            button.toolTip = String(localized: "Brim — Dynamic Island and Mac utilities")
            button.setAccessibilityLabel("Brim")
        }
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        rebuildMenu()
        installApplicationMenu()
        observeStatus()
    }
    /// Optional readout beside the icon: battery, or the running timer or stopwatch.
    private func observeStatus() {
        withObservationTracking {
            _ = model.preferences.menuBarStatus
            _ = model.status.battery; _ = model.status.charging
            _ = model.notch.countdown.state; _ = model.notch.countdown.now
            _ = model.notch.clock.stopwatch; _ = model.notch.clock.uptime; _ = model.notch.clock.ringing
        } onChange: { [weak self] in
            Task { @MainActor in self?.updateStatusText(); self?.observeStatus() }
        }
        updateStatusText()
    }
    private func statusText() -> (text: String, bolt: Bool)? {
        switch model.preferences.menuBarStatus {
        case .battery:
            guard let level = model.status.battery else { return nil }
            return ("\(level)%", model.status.charging)
        case .activity:
            let countdown = model.notch.countdown
            if countdown.active { return (countdown.state.phase == .finished ? String(localized: "Done") : countdown.label, false) }
            let clock = model.notch.clock
            if clock.active { return (clock.label, false) }
            return nil
        case .off: return nil
        }
    }
    private func updateStatusText() {
        guard let button = item.button else { return }
        guard let status = statusText() else {
            if button.attributedTitle.length > 0 { button.attributedTitle = NSAttributedString(); button.imagePosition = .imageOnly; item.length = 28 }
            return
        }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let title = NSMutableAttributedString()
        if status.bolt, let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: String(localized: "Charging")) {
            let attachment = NSTextAttachment(); attachment.image = bolt.withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
            title.append(NSAttributedString(attachment: attachment))
        }
        title.append(NSAttributedString(string: status.text, attributes: [.font: font]))
        if button.attributedTitle.string != title.string || button.imagePosition != .imageLeft {
            button.attributedTitle = title; button.imagePosition = .imageLeft; item.length = NSStatusItem.variableLength
        }
    }
    private func installApplicationMenu() {
        let main = NSMenu()
        let application = NSMenu()
        let root = NSMenuItem(title: "Brim", action: nil, keyEquivalent: "")
        root.submenu = application; main.addItem(root)
        let settings = NSMenuItem(title: String(localized: "Settings…"), action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self; application.addItem(settings)
        application.addItem(.separator())
        let quit = NSMenuItem(title: String(localized: "Quit Brim"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self; application.addItem(quit)
        let edit = NSMenu(title: String(localized: "Edit"))
        let editRoot = NSMenuItem(title: String(localized: "Edit"), action: nil, keyEquivalent: "")
        editRoot.submenu = edit; main.addItem(editRoot)
        for (title, selector, key) in [(String(localized: "Undo"), "undo:", "z"), (String(localized: "Cut"), "cut:", "x"), (String(localized: "Copy"), "copy:", "c"), (String(localized: "Paste"), "paste:", "v"), (String(localized: "Select All"), "selectAll:", "a")] {
            edit.addItem(NSMenuItem(title: title, action: NSSelectorFromString(selector), keyEquivalent: key))
        }
        NSApp.mainMenu = main
    }
    func menuNeedsUpdate(_ menu: NSMenu) { rebuildMenu() }
    @discardableResult
    private func add(_ title: String, action: Selector? = nil, key: String = "", symbol: String? = nil) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        if let symbol { entry.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        menu.addItem(entry)
        return entry
    }
    private func rebuildMenu() {
        menu.removeAllItems()
        let notch = model.notch
        let ready = model.preferences.notchEnabled && !notch.presentationMode
        if let reason = notch.autoHideReason {
            add(String(localized: "Island hidden automatically · \(reason)")).isEnabled = false
            menu.addItem(.separator())
        }
        add(String(localized: "Open Dynamic Island"), action: #selector(openIsland), symbol: "capsule").isEnabled = ready
        let sections = NSMenu()
        sections.autoenablesItems = false
        // The keys match the tools' global shortcuts. Turned-off sections leave the menu too.
        for (tab, title, action, symbol, key) in [
            (IslandTab.music, String(localized: "Now Playing"), #selector(openNowPlaying), "play.rectangle", "1"),
            (.files, String(localized: "Files"), #selector(openFileShelf), "tray", "2"),
            (.clipboard, String(localized: "Clipboard"), #selector(openClipboard), "pin", "3"),
            (.timer, String(localized: "Clock"), #selector(openTimer), "timer", "4"),
            (.battery, String(localized: "Battery"), #selector(openBattery), "battery.100", "5"),
            (.transfers, String(localized: "Transfers"), #selector(openTransfers), "arrow.down.circle", "6")
        ] where tab == .transfers ? !model.preferences.simpleIsland : notch.shows(tab) {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: model.preferences.toolShortcutsEnabled ? key : "")
            entry.target = self; entry.isEnabled = ready
            entry.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            if model.preferences.toolShortcutsEnabled { entry.keyEquivalentModifierMask = model.preferences.toolShortcutModifiers.menuMask }
            sections.addItem(entry)
        }
        if sections.items.count > 1 { let show = add(String(localized: "Show")); show.submenu = sections; show.isEnabled = ready }
        if notch.shows(.timer) { add(String(localized: "Start Focus Session"), action: #selector(startFocus), symbol: "brain.head.profile").isEnabled = ready && !notch.countdown.active }
        if notch.shows(.clipboard) { add(String(localized: "Pin Clipboard"), action: #selector(pinClipboard), symbol: "doc.on.clipboard").isEnabled = ready }
        menu.addItem(.separator())
        let presentation = add(notch.manualPresentation ? String(localized: "End Presentation Mode") : String(localized: "Presentation Mode"), action: #selector(togglePresentation), symbol: "display")
        presentation.state = notch.manualPresentation ? .on : .off
        if model.preferences.scaleEnabled { add(String(localized: "Open Trackpad Scale"), action: #selector(openScale), symbol: "scalemass") }
        if LockScreenService.available { add(String(localized: "Lock Mac"), action: #selector(lockMac), symbol: "lock") }
        menu.addItem(.separator())
        add(String(localized: "Settings…"), action: #selector(openSettings), key: ",", symbol: "gearshape")
        add(String(localized: "Quit Brim"), action: #selector(quit), key: "q")
    }
    @objc private func togglePresentation() {
        model.notch.setPresentationMode(!model.notch.manualPresentation)
        item.button?.toolTip = model.notch.manualPresentation ? String(localized: "Brim — Presentation Mode · island hidden") : String(localized: "Brim — Dynamic Island and Mac utilities")
        rebuildMenu()
    }
    @objc private func openNowPlaying() { model.notch.openTool(.nowPlaying) }
    @objc private func openTimer() { model.notch.openTimerFromMenu() }
    @objc private func startFocus() { model.notch.startFocus() }
    @objc private func openTransfers() { model.notch.openTransfersFromMenu() }
    @objc private func openBattery() { model.notch.openBatteryFromMenu() }
    @objc private func openClipboard() { model.notch.openClipboardFromMenu() }
    @objc private func pinClipboard() { model.notch.pinClipboard() }
    @objc private func openSettings() { model.openSettings() }
    @objc private func openFileShelf() { model.notch.openShelfFromMenu() }
    @objc private func openIsland() { model.notch.openInContext() }
    @objc private func openScale() { model.openScale() }
    @objc private func lockMac() { model.lock.lock() }
    @objc private func quit() { NSApp.terminate(nil) }
}
