import AppKit

/// Retained for the app's lifetime, independently of any SwiftUI window or scene.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let model: SenseAppModel
    private let item: NSStatusItem
    private let menu = NSMenu()
    var isVisible: Bool { item.isVisible && item.button?.window != nil }
    var buttonFrame: CGRect? {
        guard let button = item.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }
    var menuTitles: [String] { menu.items.filter { !$0.isSeparatorItem }.map(\.title) }

    init(model: SenseAppModel) {
        self.model = model
        item = NSStatusBar.system.statusItem(withLength: 28)
        super.init()
        item.autosaveName = "SenseStatusItem"
        item.isVisible = true
        if let button = item.button {
            // A hand-drawn template avoids depending on symbol availability in a particular SDK.
            let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
                NSColor.labelColor.setStroke()
                let path = NSBezierPath()
                let points: [NSPoint] = [
                    .init(x: 1, y: 9), .init(x: 4, y: 9), .init(x: 6, y: 14),
                    .init(x: 9, y: 3), .init(x: 12, y: 14), .init(x: 14, y: 9), .init(x: 17, y: 9)
                ]
                path.move(to: points[0]); points.dropFirst().forEach { path.line(to: $0) }
                path.lineWidth = 1.6; path.lineCapStyle = .round; path.lineJoinStyle = .round
                path.stroke()
                return true
            }
            image.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
            button.toolTip = String(localized: "Sense — Dynamic Island and Mac utilities")
            button.setAccessibilityLabel("Sense")
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
        let root = NSMenuItem(title: "Sense", action: nil, keyEquivalent: "")
        root.submenu = application; main.addItem(root)
        let settings = NSMenuItem(title: String(localized: "Settings…"), action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self; application.addItem(settings)
        application.addItem(.separator())
        let quit = NSMenuItem(title: String(localized: "Quit Sense"), action: #selector(quit), keyEquivalent: "q")
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
        let heading = add("Sense"); heading.isEnabled = false
        let presentation = add(model.notch.manualPresentation ? String(localized: "End Presentation Mode") : String(localized: "Presentation Mode"), action: #selector(togglePresentation), symbol: "display")
        presentation.state = model.notch.manualPresentation ? .on : .off
        if let reason = model.notch.autoHideReason { add(String(localized: "Island hidden automatically · \(reason)")).isEnabled = false }
        menu.addItem(.separator())
        add(String(localized: "Open Dynamic Island"), action: #selector(openIsland), symbol: "capsule").isEnabled = model.preferences.notchEnabled && !model.notch.presentationMode
        add(String(localized: "Now Playing"), action: #selector(openNowPlaying), symbol: "play.rectangle").isEnabled = model.preferences.notchEnabled && !model.notch.presentationMode
        add(String(localized: "Open File Shelf"), action: #selector(openFileShelf), symbol: "tray").isEnabled = model.preferences.notchEnabled && !model.notch.presentationMode
        add(String(localized: "Clock…"), action: #selector(openTimer), symbol: "timer").isEnabled = model.preferences.notchEnabled && !model.notch.presentationMode
        add(String(localized: "Start Focus Session"), action: #selector(startFocus), symbol: "brain.head.profile").isEnabled = model.preferences.notchEnabled && !model.notch.presentationMode && !model.notch.countdown.active
        add(String(localized: "Clipboard Shelf"), action: #selector(openClipboard), symbol: "pin").isEnabled = model.preferences.notchEnabled && !model.notch.presentationMode
        add(String(localized: "Battery"), action: #selector(openBattery), symbol: "battery.100").isEnabled = model.preferences.notchEnabled && !model.notch.presentationMode
        add(String(localized: "Transfers"), action: #selector(openTransfers), symbol: "arrow.down.circle").isEnabled = model.preferences.notchEnabled && !model.notch.presentationMode
        if model.preferences.toolShortcutsEnabled {
            for (title, key) in [(String(localized: "Now Playing"), "1"), (String(localized: "Open File Shelf"), "2"), (String(localized: "Clipboard Shelf"), "3"), (String(localized: "Clock…"), "4"), (String(localized: "Battery"), "5"), (String(localized: "Transfers"), "6")] {
                if let entry = menu.items.first(where: { $0.title == title }) {
                    entry.keyEquivalent = key; entry.keyEquivalentModifierMask = model.preferences.toolShortcutModifiers.menuMask
                }
            }
        }
        add(String(localized: "Pin Clipboard"), action: #selector(pinClipboard), symbol: "doc.on.clipboard").isEnabled = model.preferences.notchEnabled && !model.notch.presentationMode
        add(String(localized: "Set Up Lid Fold…"), action: #selector(openLidSetup), symbol: "macbook")
        add(String(localized: "Settings…"), action: #selector(openSettings), key: ",", symbol: "gearshape")
        menu.addItem(.separator())
        for (title, key, enabled) in [
            (String(localized: "Dynamic Island"), "notch", model.preferences.notchEnabled),
            (String(localized: "Window Switcher"), "switcher", model.preferences.switcherEnabled),
            (String(localized: "Trackpad Scale"), "scale", model.preferences.scaleEnabled),
            (String(localized: "Lid Fold"), "lid", model.preferences.lidEffectEnabled),
            (String(localized: "Lock Actions"), "lock", model.preferences.lockEnabled)
        ] {
            let entry = add(title, action: #selector(toggleFeature(_:)))
            entry.representedObject = key; entry.state = enabled ? .on : .off
        }
        menu.addItem(.separator())
        add(String(localized: "Open Trackpad Scale"), action: #selector(openScale), symbol: "scalemass").isEnabled = model.preferences.scaleEnabled
        add(String(localized: "Lock Mac"), action: #selector(lockMac), symbol: "lock").isEnabled = model.preferences.lockEnabled
        menu.addItem(.separator())
        add(String(localized: "Quit Sense"), action: #selector(quit), key: "q")
    }
    @objc private func togglePresentation() {
        model.notch.setPresentationMode(!model.notch.manualPresentation)
        item.button?.toolTip = model.notch.manualPresentation ? String(localized: "Sense — Presentation Mode · island hidden") : String(localized: "Sense — Dynamic Island and Mac utilities")
        rebuildMenu()
    }
    @objc private func openNowPlaying() { model.notch.openTool(.nowPlaying) }
    @objc private func openTimer() { model.notch.openTimerFromMenu() }
    @objc private func startFocus() { model.notch.startFocus() }
    @objc private func openTransfers() { model.notch.openTransfersFromMenu() }
    @objc private func openBattery() { model.notch.openBatteryFromMenu() }
    @objc private func openClipboard() { model.notch.openClipboardFromMenu() }
    @objc private func pinClipboard() { model.notch.pinClipboard() }
    @objc private func openLidSetup() { model.openSettings(page: .labs) }
    @objc private func openSettings() { model.openSettings() }
    @objc private func openFileShelf() { model.notch.openShelfFromMenu() }
    @objc private func openIsland() { model.notch.openInContext() }
    @objc private func openScale() { model.openScale() }
    @objc private func lockMac() { model.lock.lock() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func toggleFeature(_ sender: NSMenuItem) {
        switch sender.representedObject as? String {
        case "notch": model.preferences.notchEnabled.toggle()
        case "switcher": model.preferences.switcherEnabled.toggle()
        case "scale": model.preferences.scaleEnabled.toggle()
        case "lid": model.preferences.lidEffectEnabled.toggle()
        case "lock": model.preferences.lockEnabled.toggle()
        default: return
        }
        model.apply()
    }
}
