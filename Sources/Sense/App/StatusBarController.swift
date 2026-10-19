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
            button.toolTip = "Sense — Dynamic Island and Mac utilities"
            button.setAccessibilityLabel("Sense")
        }
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        rebuildMenu()
        installApplicationMenu()
    }
    private func installApplicationMenu() {
        let main = NSMenu()
        let application = NSMenu()
        let root = NSMenuItem(title: "Sense", action: nil, keyEquivalent: "")
        root.submenu = application; main.addItem(root)
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self; application.addItem(settings)
        application.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Sense", action: #selector(quit), keyEquivalent: "q")
        quit.target = self; application.addItem(quit)
        let edit = NSMenu(title: "Edit")
        let editRoot = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editRoot.submenu = edit; main.addItem(editRoot)
        for (title, selector, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
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
        add("Open Dynamic Island", action: #selector(openIsland), symbol: "capsule").isEnabled = model.preferences.notchEnabled
        add("Open File Shelf", action: #selector(openFileShelf), symbol: "tray").isEnabled = model.preferences.notchEnabled
        add("Set Up Lid Fold…", action: #selector(openLidSetup), symbol: "macbook")
        add("Settings…", action: #selector(openSettings), key: ",", symbol: "gearshape")
        menu.addItem(.separator())
        for (title, key, enabled) in [
            ("Dynamic Island", "notch", model.preferences.notchEnabled),
            ("Window Switcher", "switcher", model.preferences.switcherEnabled),
            ("Trackpad Scale", "scale", model.preferences.scaleEnabled),
            ("Lid Fold & Lock", "lock", model.preferences.lockEnabled)
        ] {
            let entry = add(title, action: #selector(toggleFeature(_:)))
            entry.representedObject = key; entry.state = enabled ? .on : .off
        }
        menu.addItem(.separator())
        add("Open Trackpad Scale", action: #selector(openScale), symbol: "scalemass").isEnabled = model.preferences.scaleEnabled
        add("Lock Mac", action: #selector(lockMac), symbol: "lock").isEnabled = model.preferences.lockEnabled
        menu.addItem(.separator())
        add("Quit Sense", action: #selector(quit), key: "q")
    }
    @objc private func openLidSetup() { model.openSettings(page: .lock) }
    @objc private func openSettings() { model.openSettings() }
    @objc private func openFileShelf() { model.notch.openShelfFromMenu() }
    @objc private func openIsland() { model.notch.openFromMenu() }
    @objc private func openScale() { model.openScale() }
    @objc private func lockMac() { model.lock.lock() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func toggleFeature(_ sender: NSMenuItem) {
        switch sender.representedObject as? String {
        case "notch": model.preferences.notchEnabled.toggle()
        case "switcher": model.preferences.switcherEnabled.toggle()
        case "scale": model.preferences.scaleEnabled.toggle()
        case "lock": model.preferences.lockEnabled.toggle()
        default: return
        }
        model.apply()
    }
}
