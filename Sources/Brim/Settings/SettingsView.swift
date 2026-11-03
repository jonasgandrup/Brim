import SwiftUI
import ServiceManagement

/// Laid out like System Settings: a sidebar of colored icons and grouped forms with a header per page.
struct SettingsView: View {
    @Bindable var model: BrimAppModel
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
                    if model.page == .notch, let section = model.islandSection {
                        Button("Dynamic Island", systemImage: "chevron.left") { model.islandSection = nil }
                            .buttonStyle(.borderless).keyboardShortcut("[", modifiers: .command)
                        SettingsPageHeader(symbol: section.symbol, tint: section.tint, title: .verbatim(section.title), detail: .verbatim(section.subtitle))
                    } else {
                        SettingsPageHeader(symbol: model.page.symbol, tint: model.page.tint, title: .verbatim(model.page.title), detail: .verbatim(model.page.subtitle))
                    }
                }
                content
            }
            .formStyle(.grouped)
            .scrollDisabled(captureMode)
            .id(model.page.id + "/" + (model.islandSection?.id ?? ""))
        }
        .frame(minWidth: 820, minHeight: 560)
        .onChange(of: preferences.notchEnabled) { model.apply() }
        .onChange(of: preferences.switcherEnabled) { model.apply() }
        .onChange(of: preferences.scaleEnabled) { model.apply() }
        .onChange(of: preferences.lidEffectEnabled) { model.apply() }
        .onChange(of: preferences.showOnExternal) { model.apply() }
        .onChange(of: preferences.followActiveDisplay) { model.apply() }
        .onChange(of: preferences.toolShortcutsEnabled) { model.apply() }
        .onChange(of: preferences.toolShortcutModifiers) { model.apply() }
        .onChange(of: preferences.sectionShortcuts) { model.apply() }
        .onChange(of: preferences.mediaEnabled) { model.apply() }
        .onChange(of: preferences.playerAccess) { model.apply() }
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
        .onChange(of: preferences.focusFeedback) { model.apply() }
        .onChange(of: preferences.systemChanges) { model.apply() }
        .onChange(of: preferences.smallNotices) { model.apply() }
        .onChange(of: preferences.openWhenIdle) { model.apply() }
        .onChange(of: preferences.showFiles) { model.apply() }
        .onChange(of: preferences.showClipboard) { model.apply() }
        .onChange(of: preferences.showClock) { model.apply() }
        .onChange(of: preferences.showControls) { model.apply() }
        .onChange(of: preferences.shortcut) { model.switcher.stop(); model.apply() }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: Binding<SettingsPage?>(get: { model.page }, set: { if let page = $0 { model.page = page } })) {
            HStack(spacing: 10) {
                BrimMark(size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Brim").font(.system(size: 13, weight: .semibold))
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
        case .notch:
            switch model.islandSection {
            case nil: notch
            case .shelf: shelfSettings
            case .notices: noticeSettings
            case .battery: batterySettings
            case .hiding: hidingSettings
            case .keyboard: keyboardSettings
            }
        case .switcher: switcher
        case .labs: labs
        case .permissions: permissions
        }
    }

    // MARK: Welcome

    /// First launch: choose features in one place, then go straight to whatever they need.
    @ViewBuilder private var welcome: some View {
        levelSection
        Section {
            welcomeToggle(SettingsPage.switcher.symbol, SettingsPage.switcher.tint, "Window Switcher", "Every window, with a preview, on ⌘ Tab.", binding(\.switcherEnabled))
            Toggle(isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) })) {
                Label { SettingsLabel(title: "Open at Login", detail: "Ready when your Mac is.") } icon: { SettingsIcon(symbol: "power", tint: .gray, size: 26) }
            }
        } footer: {
            // In the footer, so the page's one action stands on its own instead of in a box.
            VStack(alignment: .leading, spacing: 16) {
                Footnote(text: "Brim asks for a permission only when a feature you turned on needs it. Nothing leaves your Mac.", symbol: "lock.shield")
                HStack {
                    Spacer()
                    Button("Continue") { model.permissions.refresh(); model.page = preferences.switcherEnabled ? .permissions : .notch }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }
        }
    }
    /// One choice for most people; the switches below it are there for anyone who wants their own mix.
    private var levelSection: some View {
        Section {
            VStack(spacing: 10) {
                Picker("How Much to Show", selection: Binding<IslandLevel?>(get: { preferences.level }, set: { preferences.level = $0 })) {
                    ForEach(IslandLevel.allCases) { Text($0.title).tag(IslandLevel?.some($0)) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .disabled(!preferences.notchEnabled)
                Text(verbatim: preferences.level?.summary ?? String(localized: "Your own mix. Choose a level to start over."))
                    .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity).padding(.vertical, 4)
        } header: { Text("How Much to Show") } footer: {
            Footnote(text: "Anything that reads your calendar, downloads, screenshots or clipboard history, or needs a macOS permission, stays a separate switch.")
        }
    }
    private func welcomeToggle(_ symbol: String, _ tint: Color, _ title: LocalizedStringKey, _ detail: LocalizedStringKey, _ isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Label { SettingsLabel(title: title, detail: detail) } icon: { SettingsIcon(symbol: symbol, tint: tint, size: 26) }
        }
    }

    // MARK: General

    @ViewBuilder private var general: some View {
        Section("Features") {
            featureToggle(.notch, detail: "Now playing, files, timers and system status around the camera.", isOn: binding(\.notchEnabled))
            featureToggle(.switcher, detail: "Move between windows, not just apps.", isOn: binding(\.switcherEnabled))
            LabeledContent {
                Button("Show") { model.page = .labs }
            } label: {
                Label { SettingsLabel(title: "Labs", detail: "Trackpad Scale and Lid Fold.") } icon: { SettingsIcon(symbol: SettingsPage.labs.symbol, tint: SettingsPage.labs.tint, size: 26) }
            }
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
            if LockScreenService.available {
                Toggle(isOn: binding(\.menuLockMac)) {
                    SettingsLabel(title: "Lock Mac in Menu", detail: "Adds Lock Mac to Brim’s menu bar menu.")
                }
            }
            LabeledContent {
                Button("Show") { model.page = .welcome }
            } label: {
                SettingsLabel(title: "Welcome Tour", detail: "Choose features again from one page.")
            }
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let message = model.loginMessage { Footnote(text: .verbatim(message), symbol: "exclamationmark.circle") }
                Footnote(text: "No accounts. No cloud. Your settings and calibration stay on this Mac.", symbol: "lock.shield")
            }
        }
    }

    // MARK: Dynamic Island

    @ViewBuilder private var notch: some View {
        Section {
            notchPreview
            Toggle(isOn: binding(\.notchEnabled)) {
                SettingsLabel(title: "Dynamic Island", detail: "Activities and brief updates around the camera.")
            }
        }
        levelSection
        Section {
            sectionToggle("play.fill", .pink, "Now Playing", binding(\.mediaEnabled),
                          info: "Works with apps that publish a Now Playing session; some omit artwork or ignore playback commands. Uses an undocumented macOS interface that may change with updates. You can also allow Music and Spotify under Permissions.")
            sectionToggle("tray.fill", .teal, "Files", binding(\.showFiles))
            sectionToggle("pin.fill", .yellow, "Clipboard", binding(\.showClipboard))
            sectionToggle("clock.fill", .orange, "Clock", binding(\.showClock))
            sectionToggle("battery.100percent", .green, "Battery & Controls", binding(\.showControls))
            sectionToggle("arrow.down.circle.fill", .blue, "Downloads & AirDrop", binding(\.liveTransfers),
                          detail: model.notch.transfers.accessProblem.map(LocalizedStringKey.verbatim), info: "macOS asks once for access to your Downloads folder.")
        } header: { Text("Show in the Island") } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Footnote(text: "Sections you turn off leave the island and the menu. A timer that’s already running stays until it ends.")
                if let message = model.media.message { Footnote(text: .verbatim(message), symbol: "exclamationmark.circle") }
            }
        }.disabled(!preferences.notchEnabled)
        Section("Behavior") {
            Toggle(isOn: binding(\.hoverToExpand)) {
                SettingsLabel(title: "Open on Hover", detail: "Rest the pointer on the island to open it. A click always works.")
            }.disabled(!preferences.notchEnabled)
            Toggle(isOn: binding(\.openWhenIdle)) {
                SettingsLabel(title: "Open When Nothing’s Happening", detail: "Point at the camera for the time and battery.")
            }.disabled(!preferences.notchEnabled)
            Toggle(isOn: binding(\.smallNotices)) {
                SettingsLabel(title: "Keep Notices Small", detail: "Short notices stay around the camera instead of opening the island.")
            }.disabled(!preferences.notchEnabled)
            Toggle(isOn: binding(\.islandGestures)) {
                SettingsLabel(title: "Gestures", detail: "Scroll on the island for volume, Force Click for controls.",
                              info: "Over the compact island: scroll up or down to change the volume and Force Click to open the controls. Swiping an activity away always works.")
            }.disabled(!preferences.notchEnabled)
            Toggle(isOn: binding(\.haptics)) {
                SettingsLabel(title: "Haptic Feedback", detail: "A soft tap at moments worth feeling.",
                              info: "When a file lands or a timer ends, never just from moving the pointer. Felt only while a finger rests on a Force Touch trackpad.")
            }.disabled(!preferences.notchEnabled)
            Toggle(isOn: binding(\.showOnExternal)) {
                SettingsLabel(title: "Show on Displays Without a Notch", detail: "A small island at the top of the screen.")
            }.disabled(!preferences.notchEnabled)
            if preferences.showOnExternal {
                Toggle(isOn: binding(\.followActiveDisplay)) {
                    SettingsLabel(title: "Follow the Active Display", detail: "Moves to the display you’re working on.")
                }.disabled(!preferences.notchEnabled)
            }
        }
        Section {
            ForEach(IslandSection.allCases) { section in
                Button { model.islandSection = section } label: {
                    HStack {
                        Label { Text(section.title).foregroundStyle(.primary) } icon: { SettingsIcon(symbol: section.symbol, tint: section.tint) }
                        Spacer()
                        Text(summary(section)).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }.disabled(!preferences.notchEnabled)
    }
    private func sectionToggle(_ symbol: String, _ tint: Color, _ title: LocalizedStringKey, _ isOn: Binding<Bool>, detail: LocalizedStringKey? = nil, info: LocalizedStringKey? = nil) -> some View {
        Toggle(isOn: isOn) {
            Label { SettingsLabel(title: title, detail: detail, info: info) } icon: { SettingsIcon(symbol: symbol, tint: tint) }
        }
    }
    /// The state beside each sub-page row, like "On" or "3 on" in System Settings.
    private func summary(_ section: IslandSection) -> String {
        func count(_ flags: [Bool]) -> String {
            let on = flags.filter { $0 }.count
            return on == 0 ? String(localized: "Off") : on == flags.count && flags.count == 1 ? String(localized: "On") : String(localized: "\(on) on")
        }
        return switch section {
        case .shelf: count([preferences.keepShelf, preferences.screenshotShelf, preferences.clipboardHistory])
        case .notices: count([preferences.calendarPreview, preferences.sensorIndicator, preferences.systemHUD, preferences.focusFeedback, preferences.systemChanges])
        case .battery: count([preferences.chargingFeedback, preferences.lowBatteryAlert > 0, preferences.bluetoothBatteries])
        case .hiding: count([preferences.autoHideFocus, preferences.autoHideSharing])
        case .keyboard: preferences.toolShortcutsEnabled ? String(localized: "\(preferences.toolShortcutModifiers.label)0") : String(localized: "Off")
        }
    }
    @ViewBuilder private var shelfSettings: some View {
        Section {
            LabeledContent {
                Button("Open Files") { model.notch.openShelfFromMenu() }.disabled(!model.notch.shows(.files))
                Button("Clipboard") { model.notch.openClipboardFromMenu() }.disabled(!model.notch.shows(.clipboard))
            } label: {
                SettingsLabel(title: "Files", detail: "Drop files on the island, then drag them out anywhere.")
            }
            Toggle(isOn: binding(\.keepShelf)) {
                SettingsLabel(title: "Keep After Quitting", detail: "Files and clipboard pins stay put.",
                              info: "Files are remembered by location, never copied. Clipboard pins are saved on this Mac; turning this off deletes them. History is never saved.")
            }
            Toggle(isOn: binding(\.screenshotShelf)) {
                SettingsLabel(title: "Screenshots", detail: "New screenshots wait in the island.", info: "Found with Spotlight, so only indexed folders are seen.")
            }
            Toggle(isOn: binding(\.clipboardHistory)) {
                SettingsLabel(title: "Clipboard History", detail: "Recent text and links, kept in memory.", info: "Skips password managers. Nothing is saved to disk.")
            }
        } footer: {
            Footnote(text: "In Files, ⌘-click selects several, Space previews them and dragging a selected file takes the whole selection.")
        }
    }
    @ViewBuilder private var noticeSettings: some View {
        Section {
            Toggle(isOn: binding(\.calendarPreview)) {
                SettingsLabel(title: "Next Calendar Event", detail: calendarDetail)
            }
            Toggle(isOn: binding(\.focusFeedback)) {
                SettingsLabel(title: "Focus", detail: model.autoHide.focusDenied ? focusDenied : "A brief note when a Focus turns on or off.",
                              info: "Brim learns only whether a Focus is on, not which one.")
            }
            Toggle(isOn: binding(\.sensorIndicator)) {
                SettingsLabel(title: "Camera & Microphone", detail: "A dot while any app uses them.", info: "Brim never records anything.")
            }
            Toggle(isOn: binding(\.systemHUD)) {
                SettingsLabel(title: "Volume & Brightness", detail: "Changes appear as a small level.")
            }
            Toggle(isOn: binding(\.systemChanges)) {
                SettingsLabel(title: "System Changes", detail: "Where sound is playing, Low Power Mode, and going offline.",
                              info: "Brim notices only that the connection dropped or returned, never which network you’re on.")
            }
        }
    }
    private var focusDenied: LocalizedStringKey { "Focus access is off. Allow Brim in System Settings → Privacy & Security → Focus." }
    @ViewBuilder private var batterySettings: some View {
        Section {
            Toggle(isOn: binding(\.chargingFeedback)) {
                SettingsLabel(title: "Charging Feedback", detail: "When power connects or the battery reaches your target.")
            }
            Stepper(value: binding(\.chargeTarget), in: 50...100, step: 5) {
                LabeledContent {
                    Text("\(preferences.chargeTarget)%").monospacedDigit()
                } label: {
                    SettingsLabel(title: "Battery Target", detail: "A reminder only. Charging isn’t limited.")
                }
            }
            Picker(selection: binding(\.lowBatteryAlert)) {
                Text("Off").tag(0)
                ForEach([10, 15, 20, 30], id: \.self) { Text("\($0)%").tag($0) }
            } label: {
                SettingsLabel(title: "Low Battery Warning", detail: "Once per discharge.")
            }
            Toggle(isOn: binding(\.bluetoothBatteries)) {
                SettingsLabel(title: "Accessories", detail: "AirPods and other accessories, with a card when they connect.")
            }
        }
    }
    @ViewBuilder private var hidingSettings: some View {
        Section {
            Toggle(isOn: binding(\.autoHideFocus)) {
                SettingsLabel(title: "During Focus", detail: model.autoHide.focusDenied ? focusDenied : "Including Do Not Disturb.")
            }
            Toggle(isOn: binding(\.autoHideSharing)) {
                SettingsLabel(title: "While Sharing Your Screen", detail: "Mirroring, Zoom and Screen Sharing.",
                              info: "Browser meetings can’t be detected. Use Hide Island from the menu bar instead.")
            }
        } footer: {
            if let reason = model.notch.autoHideReason { Footnote(text: "Hidden right now: \(reason).", symbol: "eye.slash") }
        }
    }
    @ViewBuilder private var keyboardSettings: some View {
        Section {
            Toggle(isOn: binding(\.toolShortcutsEnabled)) {
                SettingsLabel(title: "Keyboard Shortcut", detail: "\(preferences.toolShortcutModifiers.label)0 opens the island.",
                              info: "Opened this way, ← and → switch sections, Return plays or pauses, and Escape closes.")
            }
            Toggle(isOn: binding(\.sectionShortcuts)) {
                SettingsLabel(title: "Section Shortcuts", detail: "\(preferences.toolShortcutModifiers.label)1 to 6 open a section.",
                              info: "1 Now Playing · 2 Files · 3 Clipboard · 4 Clock · 5 Battery · 6 Downloads & AirDrop.")
            }.disabled(!preferences.toolShortcutsEnabled)
            Picker("Modifier Keys", selection: binding(\.toolShortcutModifiers)) {
                ForEach(ShortcutModifiers.allCases) { Text($0.label).tag($0) }
            }.disabled(!preferences.toolShortcutsEnabled)
            LabeledContent {
                Button("Copy Example") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("brim://message?text=Coffee%20is%20ready&symbol=cup.and.saucer.fill", forType: .string)
                }
            } label: {
                SettingsLabel(title: "Shortcuts", detail: "Show your own messages and live activities, start timers and more.",
                              info: "Use a brim:// link with the Open URLs action: message, activity (with progress=0 to 1), activity/end, open, timer/start, focus/start, clipboard/pin, presentation and shelf/add.")
            }
        } footer: {
            if !model.toolShortcuts.unavailable.isEmpty {
                Footnote(text: "Shortcut unavailable: \(model.toolShortcuts.unavailable.joined(separator: ", ")). Another app may be using it.", symbol: "exclamationmark.triangle")
            }
        }
    }
    private var calendarDetail: LocalizedStringKey {
        switch model.notch.calendar.access {
        case .denied: "Calendar access is off. Allow it in System Settings → Privacy & Security → Calendars."
        default: "A heads-up five minutes before, with Join for calls."
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
            HStack(spacing: 2) {
                ForEach(0..<3) { index in
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.primary.opacity(0.06))
                        .overlay(Image(systemName: ["safari", "doc.text", "folder"][index]).font(.system(size: 22, weight: .light)).foregroundStyle(.secondary))
                        .frame(height: 72)
                        .padding(7)
                        .background(index == 1 ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }.padding(.vertical, 6).accessibilityLabel("Window switcher preview")
            Toggle(isOn: binding(\.switcherEnabled)) {
                SettingsLabel(title: "Window Switcher", detail: .verbatim(model.switcher.status))
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
            Footnote(text: "Choosing ⌘ Tab replaces the system app switcher while Brim runs. Shift reverses direction, arrows navigate and Escape cancels. While it’s open, Q quits an app, W closes a window, H hides an app and / searches. Protected or minimized windows show their app’s icon.")
        }
    }

    // MARK: Labs

    @ViewBuilder private var labs: some View {
        Section {
            Toggle(isOn: binding(\.lidEffectEnabled)) {
                SettingsLabel(title: "Lid Fold", detail: "Your desktop follows the lid as you close your MacBook.")
            }
            if preferences.lidEffectEnabled {
                LabeledContent {
                    lidSetupControl
                } label: {
                    SettingsLabel(title: .verbatim(model.lidSetupStatus.title), detail: .verbatim(model.lidSetupStatus.detail))
                }
                Picker(selection: binding(\.lidFoldStyle)) {
                    ForEach(LidFoldStyle.allCases) { Text($0.title).tag($0) }
                } label: {
                    SettingsLabel(title: "Closing Style", detail: .verbatim(preferences.lidFoldStyle.detail))
                }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if model.permissions.screenRecordingRequested && !model.permissions.screenRecording {
                    Footnote(text: "Turn on Brim in macOS settings. If it’s already on, choose Restart Brim above to finish setup.")
                }
                Footnote(text: "Close the lid slowly to see it. macOS still controls sleep and locking.")
            }
        }
        Section {
            Toggle(isOn: binding(\.scaleEnabled)) {
                SettingsLabel(title: "Trackpad Scale", detail: "Weigh small objects with the Force Touch sensor.",
                              info: "Uses an optional private macOS sensor interface. Needs a built-in Force Touch trackpad and a fingertip resting on it; objects alone may not register. Readings are estimates, not precision measurements.")
            }
            if preferences.scaleEnabled {
                LabeledContent {
                    Button("Open Scale") { model.openScale() }
                } label: {
                    SettingsLabel(title: "Scale", detail: "Steps and calibration are in the scale’s own window.")
                }
            }
        }
    }
    @ViewBuilder private var lidSetupControl: some View {
        switch model.lidFoldReadiness {
        case .permissionNeeded:
            Button("Allow Screen Recording…") { model.permissions.requestScreenRecording() }
            if model.permissions.screenRecordingRequested {
                Button("Restart Brim") { model.restartForLidSetup() }
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
                Button("Restart Brim") { model.restartForLidSetup() }
            }
        default: EmptyView()
        }
    }

    // MARK: Permissions

    @ViewBuilder private var permissions: some View {
        SetupChecklist(model: model)
        Section {
            Toggle(isOn: binding(\.playerAccess)) {
                Label { SettingsLabel(title: "Music & Spotify", detail: "Artwork and controls those apps don’t share with macOS. macOS asks once.") }
                    icon: { SettingsIcon(symbol: "music.note", tint: .pink) }
            }.disabled(!preferences.mediaEnabled)
            if preferences.playerAccess {
                LabeledContent {
                    Button("Manage…") { model.permissions.openPrivacy("Privacy_Automation") }
                } label: {
                    Label { SettingsLabel(title: "Automation", detail: "Music and Spotify fallback controls and artwork, when Now Playing is on.") }
                        icon: { SettingsIcon(symbol: "gearshape.2.fill", tint: .gray) }
                }
            }
        } header: { Text("Privacy") } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Footnote(text: "Grant only what you use. Battery, volume, the scale and the camera/microphone indicator need no permissions. Brim never captures from your camera or microphone.", symbol: "hand.raised")
            }
        }
        Section {
            HStack {
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
    private func featureToggle(_ page: SettingsPage, detail: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Label {
                SettingsLabel(title: .verbatim(page.title), detail: detail)
            } icon: {
                SettingsIcon(symbol: page.symbol, tint: page.tint, size: 26)
            }
        }
        .contextMenu { Button("Show \(page.title) Settings") { model.page = page } }
    }
}
