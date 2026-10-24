import SwiftUI
import ServiceManagement

/// Laid out like System Settings: a sidebar of colored icons and grouped forms with a header per page.
struct SettingsView: View {
    @Bindable var model: SenseAppModel
    var captureMode = false
    private var preferences: Preferences { model.preferences }
    private var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—" }
    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 236)
                .background { SidebarMaterial().ignoresSafeArea() }
            Divider().ignoresSafeArea()
            Form {
                Section {
                    SettingsPageHeader(symbol: model.page.symbol, tint: model.page.tint, title: model.page.title, detail: model.page.subtitle)
                }
                content
            }
            .formStyle(.grouped)
            .scrollDisabled(captureMode)
            .id(model.page)
        }
        .frame(minWidth: 820, minHeight: 560)
        .onChange(of: preferences.notchEnabled) { model.apply() }
        .onChange(of: preferences.switcherEnabled) { model.apply() }
        .onChange(of: preferences.scaleEnabled) { model.apply() }
        .onChange(of: preferences.lockEnabled) { model.apply() }
        .onChange(of: preferences.lidEffectEnabled) { model.apply() }
        .onChange(of: preferences.showOnExternal) { model.apply() }
        .onChange(of: preferences.followActiveDisplay) { model.apply() }
        .onChange(of: preferences.toolShortcutsEnabled) { model.apply() }
        .onChange(of: preferences.toolShortcutModifiers) { model.apply() }
        .onChange(of: preferences.mediaEnabled) { model.apply() }
        .onChange(of: preferences.screenshotShelf) { model.apply() }
        .onChange(of: preferences.keepShelf) { model.apply() }
        .onChange(of: preferences.clipboardHistory) { model.apply() }
        .onChange(of: preferences.calendarPreview) { model.apply() }
        .onChange(of: preferences.liveTransfers) { model.apply() }
        .onChange(of: preferences.sensorIndicator) { model.apply() }
        .onChange(of: preferences.systemHUD) { model.apply() }
        .onChange(of: preferences.bluetoothBatteries) { model.apply() }
        .onChange(of: preferences.autoHideFocus) { model.apply() }
        .onChange(of: preferences.autoHideSharing) { model.apply() }
        .onChange(of: preferences.menuBarStatus) { model.apply() }
        .onChange(of: preferences.lidFoldStyle) { model.apply() }
        .onChange(of: preferences.shortcut) { model.switcher.stop(); model.apply() }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: Binding<SettingsPage?>(get: { model.page }, set: { if let page = $0 { model.page = page } })) {
            HStack(spacing: 10) {
                SenseMark(size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Sense").font(.system(size: 13, weight: .semibold))
                    Text("Version \(version)").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
            .selectionDisabled()
            .accessibilityElement(children: .combine)
            Section {
                ForEach(SettingsPage.sidebar) { page in
                    Label {
                        Text(page.title)
                    } icon: {
                        SettingsIcon(symbol: page.symbol, tint: page.tint)
                    }
                    .tag(page)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .accessibilityLabel("Settings sections")
    }
    @ViewBuilder private var content: some View {
        switch model.page {
        case .welcome: welcome
        case .general: general
        case .notch: notch
        case .switcher: switcher
        case .scale: scale
        case .lock: lock
        case .permissions: permissions
        }
    }

    // MARK: Welcome

    /// First launch: choose features in one place, then go straight to whatever they need.
    @ViewBuilder private var welcome: some View {
        Section {
            welcomeToggle("capsule.fill", .black, "Dynamic Island", "Activities, files, timers and system status around the camera.", binding(\.notchEnabled))
            welcomeToggle("play.fill", .pink, "Now Playing", "What’s playing in any app, with controls and artwork.", binding(\.mediaEnabled))
                .disabled(!preferences.notchEnabled)
            welcomeToggle("camera.viewfinder", .teal, "Screenshot Shelf", "New screenshots appear in the island, ready to drag.", binding(\.screenshotShelf))
                .disabled(!preferences.notchEnabled)
            welcomeToggle("arrow.down.circle.fill", .blue, "Downloads & AirDrop", "Files still arriving show as a progress ring.", binding(\.liveTransfers))
                .disabled(!preferences.notchEnabled)
        } header: { Text("The Island") }
        Section {
            welcomeToggle(SettingsPage.switcher.symbol, SettingsPage.switcher.tint, "Window Switcher", "Every window, not just apps, on ⌘ Tab.", binding(\.switcherEnabled))
            welcomeToggle("laptopcomputer", .indigo, "Lid Fold", "Your desktop folds as you close the lid.", binding(\.lidEffectEnabled))
            welcomeToggle(SettingsPage.scale.symbol, SettingsPage.scale.tint, "Trackpad Scale", "Weigh small objects on your Force Touch trackpad.", binding(\.scaleEnabled))
            Toggle(isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) })) {
                Label { SettingsLabel(title: "Open at Login", detail: "Ready when your Mac is.") } icon: { SettingsIcon(symbol: "power", tint: .gray, size: 26) }
            }
        } header: { Text("Around Your Mac") } footer: {
            Footnote(text: "Sense asks for a permission only when a feature you turned on needs it. Nothing leaves your Mac.", symbol: "lock.shield")
        }
        Section {
            HStack {
                Button("Skip") { model.page = .general }
                Spacer()
                Button("Continue") { model.permissions.refresh(); model.page = .permissions }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        } footer: {
            Footnote(text: "Continue shows a checklist of anything your choices still need, each with a one-click fix.")
        }
    }
    private func welcomeToggle(_ symbol: String, _ tint: Color, _ title: String, _ detail: String, _ isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Label { SettingsLabel(title: title, detail: detail) } icon: { SettingsIcon(symbol: symbol, tint: tint, size: 26) }
        }
    }

    // MARK: General

    @ViewBuilder private var general: some View {
        Section("Features") {
            featureToggle(.notch, detail: "Now playing, files, timers and system status around the camera.", isOn: binding(\.notchEnabled))
            featureToggle(.switcher, detail: "Move between windows, not just apps.", isOn: binding(\.switcherEnabled))
            featureToggle(.scale, detail: "Weigh small objects on your Force Touch trackpad.", isOn: binding(\.scaleEnabled))
            featureToggle(.lock, detail: "A gentle transition into the macOS lock screen.", isOn: binding(\.lockEnabled))
        }
        Section {
            Toggle(isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) })) {
                SettingsLabel(title: "Open at Login", detail: "Ready when your Mac is.")
            }
            Picker(selection: binding(\.menuBarStatus)) {
                ForEach(MenuBarStatus.allCases) { Text($0.title).tag($0) }
            } label: {
                SettingsLabel(title: "Menu Bar Status", detail: "Show the battery level or a running timer next to the icon.")
            }
            Picker("Appearance", selection: binding(\.appearance)) {
                ForEach(Appearance.allCases) { Text($0.title).tag($0) }
            }
            LabeledContent {
                Button("Show") { model.page = .welcome }
            } label: {
                SettingsLabel(title: "Welcome Tour", detail: "Choose features again from one page.")
            }
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let message = model.loginMessage { Footnote(text: message, symbol: "exclamationmark.circle") }
                Footnote(text: "No accounts. No cloud. Your settings and calibration stay on this Mac.", symbol: "lock.shield")
            }
        }
    }

    // MARK: Dynamic Island

    @ViewBuilder private var notch: some View {
        Section {
            notchPreview
            Toggle(isOn: binding(\.notchEnabled)) {
                SettingsLabel(title: "Dynamic Island", detail: "Playback, live activities and brief updates around the camera.")
            }
            Toggle(isOn: binding(\.hoverToExpand)) {
                SettingsLabel(title: "Expand on Hover", detail: "Point at the camera to open the island. You can always open it from the menu bar.")
            }.disabled(!preferences.notchEnabled)
            Toggle(isOn: binding(\.showOnExternal)) {
                SettingsLabel(title: "Show on Displays Without a Notch", detail: "Adds a small island at the top of the display.")
            }.disabled(!preferences.notchEnabled)
            Toggle(isOn: binding(\.haptics)) {
                SettingsLabel(title: "Haptic Feedback", detail: "A soft tap on the trackpad when the island opens, a file lands or a timer ends. Felt only while a finger rests on a Force Touch trackpad.")
            }.disabled(!preferences.notchEnabled)
            Toggle(isOn: binding(\.followActiveDisplay)) {
                SettingsLabel(title: "Follow the Active Display", detail: "With several displays, the island moves to the one you’re working on.")
            }.disabled(!preferences.notchEnabled || !preferences.showOnExternal)
        }
        Section {
            Toggle(isOn: binding(\.mediaEnabled)) {
                SettingsLabel(title: "Now Playing", detail: "Audio and video from the active media app, including compatible browsers.")
            }
        } header: { Text("Media") } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Footnote(text: "Works with apps that publish a Now Playing session. Some apps omit artwork or ignore playback commands. System integration uses an undocumented macOS interface and may change after updates; Music and Spotify remain available as fallbacks.")
                if let message = model.media.message { Footnote(text: message, symbol: "exclamationmark.circle") }
            }
        }
        Section("Shelf & Clipboard") {
            LabeledContent {
                Button("Open Shelf") { model.notch.openShelfFromMenu() }
                Button("Clipboard") { model.notch.openClipboardFromMenu() }
            } label: {
                SettingsLabel(title: "File Shelf", detail: "Drop files on the island, switch windows or Spaces, then drag them out.")
            }.disabled(!preferences.notchEnabled)
            Toggle(isOn: binding(\.keepShelf)) {
                SettingsLabel(title: "Keep Shelf and Pins After Quitting", detail: "Files are remembered by location, never copied. Clipboard pins are saved on this Mac; turning this off deletes them. History is never saved.")
            }
            Toggle(isOn: binding(\.screenshotShelf)) {
                SettingsLabel(title: "Screenshot Shelf", detail: "New screenshots slide into the island and wait on the shelf. Uses Spotlight, so only indexed folders are seen.")
            }
            Toggle(isOn: binding(\.clipboardHistory)) {
                SettingsLabel(title: "Clipboard History", detail: "Keeps recent text and links in memory to search and pin. Skips password managers; nothing is saved to disk.")
            }
        }
        Section("Live Activities") {
            Toggle(isOn: binding(\.liveTransfers)) {
                SettingsLabel(title: "Downloads & AirDrop", detail: model.notch.transfers.accessProblem ?? "Shows files still arriving in Downloads as a progress ring. macOS asks once for access.")
            }
            Toggle(isOn: binding(\.calendarPreview)) {
                SettingsLabel(title: "Next Calendar Event", detail: calendarDetail)
            }
            Toggle(isOn: binding(\.sensorIndicator)) {
                SettingsLabel(title: "Camera & Microphone Indicator", detail: "A green or orange dot in the island while any app uses them. Sense never records anything.")
            }
            Toggle(isOn: binding(\.systemHUD)) {
                SettingsLabel(title: "Volume & Brightness", detail: "Shows changes as a small level in the island.")
            }
        }
        Section {
            Toggle(isOn: binding(\.chargingFeedback)) {
                SettingsLabel(title: "Charging Feedback", detail: "Brief feedback when power connects or the battery reaches your target.")
            }
            Stepper(value: binding(\.chargeTarget), in: 50...100, step: 5) {
                LabeledContent {
                    Text("\(preferences.chargeTarget)%").monospacedDigit()
                } label: {
                    SettingsLabel(title: "Battery Target", detail: "A reminder only; Sense doesn’t change charging limits.")
                }
            }
            Picker(selection: binding(\.lowBatteryAlert)) {
                Text("Off").tag(0)
                ForEach([10, 15, 20, 30], id: \.self) { Text("\($0)%").tag($0) }
            } label: {
                SettingsLabel(title: "Low Battery Warning", detail: "One reminder per discharge, on battery power.")
            }
            Toggle(isOn: binding(\.bluetoothBatteries)) {
                SettingsLabel(title: "Accessory Batteries", detail: "AirPods, headphones and Magic accessories in the Battery tab, with a note when they connect.")
            }
        } header: { Text("Battery") }
        Section {
            Toggle(isOn: binding(\.autoHideFocus)) {
                SettingsLabel(title: "During Focus", detail: model.autoHide.focusDenied ? "Focus access is off. Allow Sense in System Settings → Privacy & Security → Focus." : "Including Do Not Disturb. Sense only learns that a Focus is on.")
            }
            Toggle(isOn: binding(\.autoHideSharing)) {
                SettingsLabel(title: "While Sharing Your Screen", detail: "Mirrored displays, Zoom and macOS Screen Sharing. Browser meetings can’t be detected; use Presentation Mode.")
            }
        } header: { Text("Hide Automatically") } footer: {
            if let reason = model.notch.autoHideReason { Footnote(text: "Hidden right now: \(reason).", symbol: "eye.slash") }
        }
        Section {
            Toggle(isOn: binding(\.toolShortcutsEnabled)) {
                SettingsLabel(title: "Tool Shortcuts", detail: "\(preferences.toolShortcutModifiers.label)1 Now Playing · 2 Files · 3 Clipboard · 4 Clock · 5 Battery · 6 Transfers")
            }
            Picker("Modifier Keys", selection: binding(\.toolShortcutModifiers)) {
                ForEach(ShortcutModifiers.allCases) { Text($0.label).tag($0) }
            }.disabled(!preferences.toolShortcutsEnabled)
            LabeledContent {
                Button("Copy Example") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("sense://timer/start?minutes=25", forType: .string)
                }
            } label: {
                SettingsLabel(title: "Shortcuts & Automation", detail: "Use sense:// links with Shortcuts’ Open URLs action: open, timer/start, focus/start, clipboard/pin, message, presentation, shelf/add.")
            }
        } header: { Text("Keyboard & Shortcuts") } footer: {
            if !model.toolShortcuts.unavailable.isEmpty {
                Footnote(text: "Shortcut unavailable: " + model.toolShortcuts.unavailable.joined(separator: ", ") + ". Another app may be using it.", symbol: "exclamationmark.triangle")
            }
        }
    }
    private var calendarDetail: String {
        switch model.notch.calendar.access {
        case .denied: "Calendar access is off. Allow it in System Settings → Privacy & Security → Calendars."
        default: "Shows the next event in the Clock tab, alerts five minutes ahead, and offers Join for video calls."
        }
    }
    private var notchPreview: some View {
        VStack(spacing: 14) {
            HStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.orange.gradient).frame(width: 20, height: 20)
                    .overlay(Image(systemName: "music.note").font(.system(size: 10, weight: .bold)).foregroundStyle(.white))
                Spacer()
                HStack(spacing: 2) {
                    ForEach(Array([7.0, 12, 9, 14, 6].enumerated()), id: \.offset) { Capsule().fill(.green).frame(width: 2.5, height: $0.element) }
                }
            }.padding(.horizontal, 14).frame(width: 236, height: 36)
                .background(.black, in: Capsule())
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
            Text("Quiet until there’s something to show.").font(.system(size: 12)).foregroundStyle(.secondary)
            Button("Open Dynamic Island") { model.notch.openFromMenu() }
                .disabled(!preferences.notchEnabled)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 10)
        .accessibilityElement(children: .contain).accessibilityLabel("Dynamic Island preview")
    }

    // MARK: Window Switcher

    @ViewBuilder private var switcher: some View {
        Section {
            HStack(spacing: 12) {
                ForEach(0..<3) { index in
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(index == 1 ? 0.08 : 0.035))
                        .overlay(Image(systemName: ["safari", "doc.text", "folder"][index]).font(.system(size: 22, weight: .light)).foregroundStyle(.secondary))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(index == 1 ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: index == 1 ? 2.5 : 1))
                        .frame(height: 84)
                }
            }.padding(.vertical, 6).accessibilityLabel("Window switcher preview")
            Toggle(isOn: binding(\.switcherEnabled)) {
                SettingsLabel(title: "Window Switcher", detail: model.switcher.status)
            }
        }
        Section {
            Picker(selection: binding(\.shortcut)) {
                ForEach(SwitcherShortcut.allCases) { Text($0.title).tag($0) }
            } label: {
                SettingsLabel(title: "Shortcut", detail: "Hold the modifier and press Tab. Release to switch.")
            }
            Toggle("Include Minimized Windows", isOn: binding(\.includeMinimized))
            LabeledContent {
                Button("Review…") { model.page = .permissions }
            } label: {
                SettingsLabel(title: "Permissions", detail: "Accessibility to switch. Screen Recording for previews.")
            }
        } footer: {
            Footnote(text: "Choosing ⌘ Tab replaces the system app switcher while Sense runs. Shift reverses direction, arrows navigate and Escape cancels. Protected or minimized windows may have no thumbnail.")
        }
    }

    // MARK: Trackpad Scale

    @ViewBuilder private var scale: some View {
        Section {
            Toggle(isOn: binding(\.scaleEnabled)) {
                SettingsLabel(title: "Trackpad Scale", detail: "Small objects. Real Force Touch sensor readings.")
            }
            LabeledContent {
                Button("Open Scale") { model.openScale() }.disabled(!preferences.scaleEnabled)
            } label: {
                SettingsLabel(title: "Native Weighing", detail: "Reads the built-in Force Touch sensor while Scale is open.")
            }
            LabeledContent {
                Button("Reset") { model.scale.reset() }
            } label: {
                SettingsLabel(title: "Calibration", detail: "Native grams, with optional known-mass calibration.")
            }
        }
        Section {
            step(1, "Keep contact", "Rest one fingertip lightly on your built-in Force Touch trackpad.")
            step(2, "Set a baseline", "With your finger resting lightly, press T on the keyboard to tare.")
            step(3, "Add your object", "Keep your finger still and place a small object beside it. Calibrate with a known mass if needed.")
        } header: { Text("Getting a Reading") } footer: {
            Footnote(text: "Uses an optional private macOS sensor interface. Requires a built-in Force Touch trackpad and continuous fingertip contact; objects alone may not register. Readings are estimates, not precision measurements.")
        }
    }

    // MARK: Lid Fold & Lock

    @ViewBuilder private var lock: some View {
        Section {
            Toggle(isOn: binding(\.lidEffectEnabled)) {
                SettingsLabel(title: "Lid Fold", detail: "Your desktop follows the lid as you close your MacBook.")
            }
            LabeledContent {
                lidSetupControl
            } label: {
                SettingsLabel(title: model.lidSetupStatus.title, detail: model.lidSetupStatus.detail)
            }
            Picker(selection: binding(\.lidFoldStyle)) {
                ForEach(LidFoldStyle.allCases) { Text($0.title).tag($0) }
            } label: {
                SettingsLabel(title: "Closing Style", detail: preferences.lidFoldStyle.detail)
            }
            LabeledContent {
                Text("Automatic calibration").foregroundStyle(.secondary)
            } label: {
                SettingsLabel(title: "Hinge Sensor", detail: model.lid.status)
            }
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if model.permissions.screenRecordingRequested && !model.permissions.screenRecording {
                    Footnote(text: "Turn on Sense in macOS settings. If it’s already on, choose Restart Sense above to finish setup.")
                }
                Footnote(text: "Open the lid normally, then close it slowly. macOS still controls sleep and locking.")
            }
        }
        Section {
            Toggle(isOn: binding(\.lockEnabled)) {
                SettingsLabel(title: "Lock Actions", detail: "Lock Now and welcome-back feedback, independent of the lid fold.")
            }
            LabeledContent {
                Button("Lock Now") { model.lock.lock() }.disabled(!preferences.lockEnabled)
            } label: {
                SettingsLabel(title: "Lock Your Mac", detail: "Sends macOS’s own Lock Screen shortcut.")
            }
            LabeledContent {
                Text(preferences.notchEnabled ? "Island enabled" : "Enable the island").foregroundStyle(.secondary)
            } label: {
                SettingsLabel(title: "Welcome-Back Feedback", detail: "Appears in the island after you unlock.")
            }
        } header: { Text("Lock") } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let error = model.lock.error { Footnote(text: error, symbol: "exclamationmark.circle") }
                Footnote(text: "macOS handles password, Touch ID and Apple Watch authentication. Sense never reads or stores credentials or draws on the login screen.", symbol: "lock.shield")
            }
        }
    }
    @ViewBuilder private var lidSetupControl: some View {
        switch model.lidFoldReadiness {
        case .permissionNeeded:
            Button("Allow Screen Recording…") { model.permissions.requestScreenRecording() }
            if model.permissions.screenRecordingRequested {
                Button("Restart Sense") { model.restartForLidSetup() }
            }
        case .reduceMotion:
            Button("Open Accessibility…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess") { NSWorkspace.shared.open(url) }
            }
        case .sensorUnavailable:
            Button("Retry") { model.lid.stop(); model.lid.start() }
        case .ready:
            switch model.lid.captureCheck {
            case .verified: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Setup complete")
            case .checking, .unverified: ProgressView().controlSize(.small)
            case .failed:
                Button("Try Again") { model.lid.verifyDesktopCapture(force: true) }
                Button("Restart Sense") { model.restartForLidSetup() }
            }
        default: EmptyView()
        }
    }

    // MARK: Permissions

    @ViewBuilder private var permissions: some View {
        SetupChecklist(model: model)
        Section {
            LabeledContent {
                Button("Manage…") { model.permissions.openPrivacy("Privacy_Automation") }
            } label: {
                Label { SettingsLabel(title: "Automation", detail: "Music and Spotify fallback controls and artwork, when Now Playing is on.") }
                    icon: { SettingsIcon(symbol: "gearshape.2.fill", tint: .gray) }
            }
        } header: { Text("Privacy") } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Footnote(text: "Grant only what you use. Battery, volume, the scale and the camera/microphone indicator need no permissions. Sense never captures from your camera or microphone.", symbol: "hand.raised")
                Footnote(text: "If macOS asks you to restart after granting Screen Recording, use Restart Sense in Lid Fold & Lock.")
            }
        }
        Section {
            HStack {
                Button("Refresh Status", systemImage: "arrow.clockwise") { model.permissions.refresh(); model.apply() }
                Button("Copy Diagnostics", systemImage: "doc.on.clipboard") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.diagnosticsText, forType: .string)
                }.help("Copies versions and feature status for a bug report. No personal content.")
                Spacer()
            }
        }
    }

    // MARK: Helpers

    private func binding<T>(_ keyPath: ReferenceWritableKeyPath<Preferences, T>) -> Binding<T> {
        Binding(get: { preferences[keyPath: keyPath] }, set: { preferences[keyPath: keyPath] = $0 })
    }
    private func featureToggle(_ page: SettingsPage, detail: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Label {
                SettingsLabel(title: page.title, detail: detail)
            } icon: {
                SettingsIcon(symbol: page.symbol, tint: page.tint, size: 26)
            }
        }
        .contextMenu { Button("Show \(page.title) Settings") { model.page = page } }
    }
    private func step(_ number: Int, _ title: String, _ detail: String) -> some View {
        Label {
            SettingsLabel(title: title, detail: detail)
        } icon: {
            Text("\(number)").font(.system(size: 11, weight: .semibold)).frame(width: 22, height: 22)
                .background(.orange.opacity(0.15), in: Circle()).foregroundStyle(.orange)
        }
    }
}
