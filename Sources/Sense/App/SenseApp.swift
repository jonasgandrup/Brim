import SwiftUI
import AppKit
import ServiceManagement

@main
@MainActor
enum SenseApp {
    private static let delegate = AppDelegate()
    static func main() {
        // Writing to a helper process that just exited must fail with an error, not terminate Sense.
        signal(SIGPIPE, SIG_IGN)
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
        if CommandLine.arguments.contains("--lid-diagnostics") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                model.permissions.refresh()
                let values: [String: Any] = ["screenRecording": model.permissions.screenRecording,
                    "reduceMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                    "foldEnabled": model.preferences.lidEffectEnabled,
                    "hingeStatus": model.lid.status, "angle": model.lid.angle as Any? ?? NSNull(),
                    "referenceAngle": model.lid.referenceAngle as Any? ?? NSNull(),
                    "readiness": model.lidFoldReadiness.message, "captureCheck": model.lid.captureCheck.title, "launchAtLogin": model.loginEnabled]
                if let data = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]),
                   let text = String(data: data, encoding: .utf8) { print(text) }
                NSApp.terminate(nil)
            }
            return
        }
        if CommandLine.arguments.contains("--lid-setup") { model.openSettings(page: .lock) }
        else if !UserDefaults.standard.bool(forKey: "hasLaunched") || CommandLine.arguments.contains("--settings") || AppEnvironment.isSmokeTest {
            let firstLaunch = !UserDefaults.standard.bool(forKey: "hasLaunched") && !AppEnvironment.isSmokeTest
            if !AppEnvironment.isSmokeTest { UserDefaults.standard.set(true, forKey: "hasLaunched") }
            model.openSettings(page: firstLaunch ? .welcome : nil)
        }
        #if DEBUG
        if AppEnvironment.isSmokeTest {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                await model.exportSmokeTest()
                NSApp.terminate(nil)
            }
        }
        #endif
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    /// `sense://` links from Shortcuts, scripts or other apps.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let command = SenseCommand(url: url) else { Log.app.notice("Ignored unknown link \(url.absoluteString, privacy: .private)"); continue }
            SenseAppModel.shared.perform(command)
        }
    }
    func applicationWillTerminate(_ notification: Notification) { SenseAppModel.shared.stop() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SenseAppModel.shared.openSettings(); return true
    }
}

@MainActor @Observable
final class SenseAppModel {
    static let shared = SenseAppModel()
    let preferences = Preferences(defaults: AppEnvironment.defaults)
    let permissions = PermissionService()
    let status = SystemStatus()
    let media = MediaService()
    let notch = NotchController()
    let switcher = WindowSwitcher()
    let toolShortcuts = ToolShortcuts()
    let scale = NativeWeighing()
    let autoHide = AutoHideMonitor()
    let lock = LockScreenService()
    let lid = LidEffectService()
    var lidFoldReadiness: LidFoldReadiness {
        .resolve(enabled: preferences.lidEffectEnabled, screenRecording: permissions.screenRecording,
                 reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, angle: lid.angle)
    }
    var lidSetupStatus: LidSetupStatus { .init(readiness: lidFoldReadiness, capture: lid.captureCheck) }
    var page: SettingsPage = .general
    var loginEnabled = SMAppService.mainApp.status == .enabled
    var loginMessage: String?
    private(set) var settingsWindow: NSWindow?
    private(set) var scaleWindow: NSWindow?
    private var activationObserver: NSObjectProtocol?
    private init() {
        lid.hasScreenAccess = { [permissions] in permissions.screenRecording }
        switcher.hasScreenAccess = { [permissions] in permissions.screenRecording }
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.permissions.refresh(); self.lid.verifyDesktopCapture(); self.switcher.configure(preferences: self.preferences)
                self.loginEnabled = SMAppService.mainApp.status == .enabled
            }
        }
    }
    func apply() {
        preferences.applyAppearance()
        permissions.refresh()
        if preferences.notchEnabled {
            status.start(); notch.start(preferences: preferences, status: status, media: media, onOpenSettings: { [weak self] in self?.openSettings(page: .notch) })
        } else { notch.stop(); if preferences.menuBarStatus == .battery { status.start() } else { status.stop() } }
        if preferences.notchEnabled && preferences.mediaEnabled { media.start() } else { media.stop() }
        if preferences.notchEnabled {
            autoHide.configure(focus: preferences.autoHideFocus, sharing: preferences.autoHideSharing) { [notch] reason in notch.setAutoHide(reason: reason) }
        } else { autoHide.stop() }
        toolShortcuts.configure(enabled: preferences.notchEnabled && preferences.toolShortcutsEnabled, modifiers: preferences.toolShortcutModifiers) { [weak self] tool in
            self?.notch.openTool(tool)
        }
        switcher.onVisibilityChanged = { [weak self] visible in self?.notch.setSwitcherOverlayActive(visible) }
        switcher.configure(preferences: preferences)
        lock.configure(preferences: preferences, notch: notch)
        lid.style = preferences.lidFoldStyle
        if preferences.lidEffectEnabled { lid.start() } else { lid.stop() }
        if !preferences.scaleEnabled { scaleWindow?.close(); scale.stop() }
    }
    func perform(_ command: SenseCommand) {
        let islandReady = preferences.notchEnabled
        switch command {
        case .open(let tool):
            guard islandReady else { openSettings(page: .notch); return }
            if let tool { notch.openTool(tool) } else { notch.openFromMenu() }
        case .startTimer(let minutes): if islandReady { notch.startTimer(minutes: minutes) }
        case .cancelTimer: notch.countdown.cancel()
        case .startFocus: if islandReady { notch.startFocus() }
        case .pinClipboard: if islandReady { notch.pinClipboard() }
        case .presentation(let enabled): notch.setPresentationMode(enabled ?? !notch.manualPresentation)
        case .message(let text, let symbol): notch.showFeedback(text, symbol: symbol, tint: .white, seconds: 4)
        case .addToShelf(let url):
            guard islandReady, notch.shelf.add([url]) > 0 else { return }
            notch.openShelfFromMenu()
        case .settings: openSettings()
        }
    }
    func stop() {
        autoHide.stop(); toolShortcuts.stop(); scale.stop(); lid.stop(); switcher.stop()
        // Timers are saved, not cancelled, so a running countdown picks up again after relaunch.
        notch.clock.stop(); notch.countdown.suspend()
        notch.stop(); status.stop(); media.stop()
    }
    func openSettings(page: SettingsPage? = nil) {
        if let page { self.page = page }
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 690), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "Sense Settings"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
            window.minSize = NSSize(width: 820, height: 600); window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(model: self))
            window.setFrameAutosaveName(AppEnvironment.isSmokeTest ? "SenseSmokeSettings" : "SenseSettings"); window.center()
            settingsWindow = window
        }
        NSApp.activate(); settingsWindow?.makeKeyAndOrderFront(nil)
    }
    func openScale() {
        guard preferences.scaleEnabled else { return }
        if scaleWindow == nil {
            let window = ScaleWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 680), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.weighing = scale
            window.title = "Trackpad Scale"; window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ScaleView(model: scale))
            window.center(); scaleWindow = window
        }
        scale.start()
        NSApp.activate(); scaleWindow?.makeKeyAndOrderFront(nil)
    }
    func restartForLidSetup() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "for attempt in 1 2 3 4 5 6 7 8 9 10; do /bin/kill -0 \"$1\" 2>/dev/null || exec /usr/bin/open -n \"$2\" --args --lid-setup; /bin/sleep 0.2; done", "sense-relaunch", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundleURL.path]
        do { try process.run(); NSApp.terminate(nil) }
        catch { lid.captureMessage = "Couldn’t restart Sense. Quit from the menu bar and reopen it." }
    }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            loginMessage = SMAppService.mainApp.status == .requiresApproval ? "Approve Sense in System Settings → General → Login Items." : nil
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch { loginEnabled = SMAppService.mainApp.status == .enabled; loginMessage = error.localizedDescription }
    }
}
