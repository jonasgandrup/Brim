import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @Bindable var model: SenseAppModel
    var captureMode = false
    private var preferences: Preferences { model.preferences }
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 215)
            Divider()
            Group {
                if captureMode { mainContent.frame(maxHeight: .infinity, alignment: .top) }
                else { ScrollView { mainContent } }
            }.background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 790, minHeight: 560)
        .onChange(of: preferences.notchEnabled) { model.apply() }
        .onChange(of: preferences.switcherEnabled) { model.apply() }
        .onChange(of: preferences.scaleEnabled) { model.apply() }
        .onChange(of: preferences.lockEnabled) { model.apply() }
        .onChange(of: preferences.lidEffectEnabled) { model.apply() }
        .onChange(of: preferences.showOnExternal) { model.apply() }
        .onChange(of: preferences.toolShortcutsEnabled) { model.apply() }
        .onChange(of: preferences.toolShortcutModifiers) { model.apply() }
        .onChange(of: preferences.mediaEnabled) { model.apply() }
        .onChange(of: preferences.screenshotShelf) { model.apply() }
        .onChange(of: preferences.clipboardHistory) { model.apply() }
        .onChange(of: preferences.calendarPreview) { model.apply() }
        .onChange(of: preferences.liveTransfers) { model.apply() }
        .onChange(of: preferences.autoHideFocus) { model.apply() }
        .onChange(of: preferences.autoHideSharing) { model.apply() }
        .onChange(of: preferences.menuBarStatus) { model.apply() }
        .onChange(of: preferences.lidFoldStyle) { model.apply() }
        .onChange(of: preferences.shortcut) { model.switcher.stop(); model.apply() }
    }
    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 7) {
                Text(model.page.title).font(.system(size: 24, weight: .semibold))
                Text(model.page.subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
            }.padding(.top, 8)
            content
            Spacer(minLength: 12)
        }.padding(32).frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity)
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                SenseMark(size: 28)
                Text("Sense").font(.system(size: 17, weight: .semibold))
            }.padding(.horizontal, 20).padding(.top, 34).padding(.bottom, 18)
            List(selection: Binding<SettingsPage?>(get: { model.page }, set: { if let page = $0 { model.page = page } })) {
                ForEach(SettingsPage.allCases) { page in
                    Label {
                        Text(page.title).font(.system(size: 13))
                    } icon: {
                        Image(systemName: page.symbol).font(.system(size: 14)).frame(width: 20)
                    }
                    .padding(.vertical, 4)
                    .tag(page)
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.sidebar).scrollContentBackground(.hidden)
            .accessibilityLabel("Settings sections")
            Text("Version 0.1.0").font(.system(size: 10)).foregroundStyle(.secondary)
                .padding(.horizontal, 22).padding(.bottom, 20)
        }.frame(maxHeight: .infinity).background(.ultraThinMaterial)
    }
    @ViewBuilder private var content: some View {
        switch model.page {
        case .general: general
        case .notch: notch
        case .switcher: switcher
        case .scale: scale
        case .lock: lock
        case .permissions: permissions
        }
    }
    private var general: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                sectionLabel("FEATURES")
                SettingsCard {
                    featureRow(.notch, detail: "Now playing, power, and a little breathing room.", enabled: binding(\.notchEnabled))
                    Divider().padding(.leading, 54)
                    featureRow(.switcher, detail: "Move between windows, not just apps.", enabled: binding(\.switcherEnabled))
                    Divider().padding(.leading, 54)
                    featureRow(.scale, detail: "Weigh small objects with your Force Touch trackpad.", enabled: binding(\.scaleEnabled))
                    Divider().padding(.leading, 54)
                    featureRow(.lock, detail: "A gentle transition into the macOS lock screen.", enabled: binding(\.lockEnabled))
                }
            }
            SettingsCard {
                SettingRow(title: "Launch at login", detail: "Ready when your Mac is.") {
                    Toggle("Launch at login", isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                Divider().padding(.leading, 16)
                SettingRow(title: "Menu bar status", detail: "Show the battery level or a running timer next to the icon.") {
                    Picker("Menu bar status", selection: binding(\.menuBarStatus)) {
                        Text("Off").tag("off"); Text("Battery").tag("battery"); Text("Timer").tag("activity")
                    }.labelsHidden().frame(width: 130)
                }
                Divider().padding(.leading, 16)
                SettingRow(title: "Appearance") {
                    Picker("Appearance", selection: binding(\.appearance)) {
                        Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark")
                    }.labelsHidden().frame(width: 130)
                }
            }
            if let message = model.loginMessage { Footnote(text: message) }
            Footnote(text: "No accounts. No cloud. Your settings and calibration stay on this Mac.", symbol: "lock.shield")
        }
    }
    private var notch: some View {
        VStack(alignment: .leading, spacing: 20) {
            notchPreview
            FeatureHeader(title: "Dynamic Island", detail: "Playback and temporary updates, with native Liquid Glass.", enabled: binding(\.notchEnabled))
            SettingsCard {
                SettingRow(title: "Tool shortcuts", detail: "\((ShortcutModifiers(rawValue: preferences.toolShortcutModifiers) ?? .ctrlOptCmd).label)1 Now Playing · 2 Files · 3 Clipboard · 4 Clock · 5 Battery · 6 Transfers") {
                    Picker("Shortcut modifiers", selection: binding(\.toolShortcutModifiers)) {
                        ForEach(ShortcutModifiers.allCases) { Text($0.label).tag($0.rawValue) }
                    }.labelsHidden().frame(width: 90)
                    Toggle("Tool shortcuts", isOn: binding(\.toolShortcutsEnabled)).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                if !model.toolShortcuts.unavailable.isEmpty {
                    Footnote(text: "Shortcut unavailable: " + model.toolShortcuts.unavailable.joined(separator: ", ") + ". Another app may be using it.")
                }
                Divider().padding(.leading, 16)
                SettingRow(title: "File shelf", detail: "Drop files on the island, switch windows or Spaces, then drag them out.") {
                    Button("Open Shelf") { model.notch.openShelfFromMenu() }.disabled(!preferences.notchEnabled)
                }
                Divider().padding(.leading, 16)
                SettingRow(title: "Clock & clipboard", detail: "Use the timer, stopwatch or alarm, or pin copied text, links and images.") {
                    Button("Clock") { model.notch.openTimerFromMenu() }.disabled(!preferences.notchEnabled)
                    Button("Clipboard") { model.notch.openClipboardFromMenu() }.disabled(!preferences.notchEnabled)
                }
                Divider().padding(.leading, 16)
                SettingRow(title: "Screenshot shelf", detail: "New screenshots slide into the island with a preview and wait on the file shelf. Uses Spotlight, so it only sees files macOS has indexed.") {
                    Toggle("Screenshot shelf", isOn: binding(\.screenshotShelf)).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                Divider().padding(.leading, 16)
                SettingRow(title: "Clipboard history", detail: "Keep recent text and links in memory so you can search and pin them. Skips password managers and concealed copies; nothing is saved to disk.") {
                    Toggle("Clipboard history", isOn: binding(\.clipboardHistory)).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                Divider().padding(.leading, 16)
                SettingRow(title: "Next calendar event", detail: calendarDetail) {
                    Toggle("Next calendar event", isOn: binding(\.calendarPreview)).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                Divider().padding(.leading, 16)
                SettingRow(title: "Live transfers", detail: model.notch.transfers.accessProblem ?? "Show downloads still arriving in your Downloads folder, and AirDrops you send from the shelf, as a progress ring. macOS asks once to let Sense read Downloads.") {
                    Toggle("Live transfers", isOn: binding(\.liveTransfers)).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                Divider().padding(.leading, 16)
                SettingRow(title: "Hide during Focus", detail: model.autoHide.focusDenied ? "Focus access is off. Allow Sense in System Settings → Privacy & Security → Focus." : "Hide the island while any Focus, including Do Not Disturb, is on. Sense only learns that a Focus is active.") {
                    Toggle("Hide during Focus", isOn: binding(\.autoHideFocus)).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                Divider().padding(.leading, 16)
                SettingRow(title: "Hide while sharing your screen", detail: "Hides when displays are mirrored, or Zoom or macOS Screen Sharing is sharing. Meetings in a browser can’t be detected, so use Presentation Mode for those.") {
                    Toggle("Hide while sharing", isOn: binding(\.autoHideSharing)).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                if let reason = model.notch.autoHideReason {
                    Footnote(text: "Hidden right now: \(reason).", symbol: "eye.slash")
                }
                Divider().padding(.leading, 16)
                SettingRow(title: "Charging feedback", detail: "Brief feedback when power connects or your battery reaches the chosen level.") {
                    Toggle("Charging feedback", isOn: binding(\.chargingFeedback)).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                Divider().padding(.leading, 16)
                SettingRow(title: "Battery target", detail: "A reminder only; Sense doesn’t change charging limits.") {
                    Stepper("\(preferences.chargeTarget)%", value: binding(\.chargeTarget), in: 50...100, step: 5).fixedSize()
                }
                Divider().padding(.leading, 16)
                SettingRow(title: "Expand on hover", detail: "Hover at the camera to expand. Open it anytime from the menu bar.") { Toggle("Expand on hover", isOn: binding(\.hoverToExpand)).labelsHidden().toggleStyle(.switch).controlSize(.small) }
                Divider().padding(.leading, 16)
                SettingRow(title: "Show on displays without a notch", detail: "Adds a small island at the top of your main display.") { Toggle("External display island", isOn: binding(\.showOnExternal)).labelsHidden().toggleStyle(.switch).controlSize(.small) }
                Divider().padding(.leading, 16)
                SettingRow(title: "Now Playing", detail: "Audio and video from the active media app, including compatible browsers.") { Toggle("Now Playing", isOn: binding(\.mediaEnabled)).labelsHidden().toggleStyle(.switch).controlSize(.small) }
            }
            Footnote(text: "Works with apps that publish a Now Playing session. Some apps may omit artwork or ignore playback commands. System integration uses an undocumented macOS interface and may change after updates; Music and Spotify remain available as fallbacks.")
            if let message = model.media.message { Footnote(text: message) }
        }
    }
    private var calendarDetail: String {
        switch model.notch.calendar.access {
        case .denied: "Calendar access is off. Allow it in System Settings → Privacy & Security → Calendars."
        default: "Show your next timed event in the Clock tab and alert five minutes before it. Read locally; nothing is stored."
        }
    }
    private var notchPreview: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "waveform.path").font(.system(size: 16, weight: .medium))
                Spacer()
                Image(systemName: "waveform").font(.system(size: 16, weight: .medium)).foregroundStyle(.white.opacity(0.65))
            }.padding(.horizontal, 18).frame(width: 254, height: 40)
                .foregroundStyle(.white).background(.black, in: Capsule())
            Text("Quiet until there’s something to show.").font(.system(size: 11)).foregroundStyle(.secondary)
            Button("Open Dynamic Island", systemImage: "capsule") { model.notch.openFromMenu() }
                .disabled(!preferences.notchEnabled)
        }.frame(maxWidth: .infinity).padding(.vertical, 16)
            .accessibilityLabel("Dynamic Island appearance preview")
    }
    private var switcher: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                ForEach(0..<3) { index in
                    RoundedRectangle(cornerRadius: 12).fill(.primary.opacity(index == 1 ? 0.07 : 0.025))
                        .overlay(Image(systemName: ["safari", "doc.text", "folder"][index]).font(.system(size: 25, weight: .light)).foregroundStyle(.secondary))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(index == 1 ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.08), lineWidth: index == 1 ? 2 : 1)).frame(height: 100)
                }
            }.padding(.vertical, 10).accessibilityLabel("Window switcher appearance preview")
            FeatureHeader(title: "Window Switcher", detail: model.switcher.status, enabled: binding(\.switcherEnabled))
            SettingsCard {
                SettingRow(title: "Shortcut", detail: "Hold the modifier, press Tab. Release to switch.") {
                    Picker("Shortcut", selection: binding(\.shortcut)) { Text("⌘ Tab").tag("command"); Text("⌥ Tab").tag("option"); Text("⌃ Tab").tag("control") }.labelsHidden().frame(width: 110)
                }
                Divider().padding(.leading, 16)
                SettingRow(title: "Include minimized windows") { Toggle("Include minimized", isOn: binding(\.includeMinimized)).labelsHidden().toggleStyle(.switch).controlSize(.small) }
                Divider().padding(.leading, 16)
                SettingRow(title: "Permissions", detail: "Accessibility to switch. Screen Recording for previews.") { Button("Review…") { model.page = .permissions } }
            }
            Footnote(text: "Enabling ⌘ Tab replaces the system app switcher while Sense runs. Shift reverses direction; arrows navigate; Escape cancels. Protected or minimized windows may have no thumbnail. Windows in other Spaces remain subject to macOS’s Space-switching settings.")
        }
    }
    private var scale: some View {
        VStack(alignment: .leading, spacing: 20) {
            FeatureHeader(title: "Trackpad Scale", detail: "Small objects. Real Force Touch sensor readings.", enabled: binding(\.scaleEnabled))
            SettingsCard {
                SettingRow(title: "Native weighing", detail: "Reads the built-in Force Touch sensor while Scale is open.") { Button("Open Scale") { model.openScale() }.disabled(!preferences.scaleEnabled) }
                Divider().padding(.leading, 16)
                SettingRow(title: "Calibration", detail: "Native grams, with optional known-mass calibration.") {
                    Button("Reset") { model.scale.reset() }
                }
            }
            VStack(alignment: .leading, spacing: 16) {
                sectionLabel("GETTING A READING")
                step("1", "Keep contact", "Rest one fingertip lightly on your built-in Force Touch trackpad.")
                step("2", "Set a baseline", "With your finger resting lightly, press T on the keyboard to tare.")
                step("3", "Add your object", "Keep your finger still and place a small object beside it. The scale shows grams. Calibrate with a known mass if needed.")
            }.padding(4)
            Footnote(text: "Native weighing uses an optional private macOS sensor interface. Requires a built-in Force Touch trackpad and continuous fingertip contact; objects alone may not register. Losing contact requires a new zero. Readings are estimates, not precision measurements.")
        }
    }
    private var lock: some View {
        VStack(alignment: .leading, spacing: 20) {
            FeatureHeader(title: "Lid fold", detail: "Your desktop follows the lid as you close your MacBook.", enabled: binding(\.lidEffectEnabled))
            SettingsCard {
                SettingRow(title: model.lidSetupStatus.title, detail: model.lidSetupStatus.detail) {
                    switch model.lidFoldReadiness {
                    case .permissionNeeded:
                        Button("Allow Screen Recording…") { model.permissions.requestScreenRecording() }
                        if model.permissions.screenRecordingRequested {
                            Button("Restart Sense", systemImage: "arrow.clockwise") { model.restartForLidSetup() }
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
                Divider().padding(.leading, 16)
                SettingRow(title: "Closing style", detail: (LidFoldStyle(rawValue: preferences.lidFoldStyle) ?? .fold).detail) {
                    Picker("Closing style", selection: binding(\.lidFoldStyle)) {
                        ForEach(LidFoldStyle.allCases) { Text($0.title).tag($0.rawValue) }
                    }.labelsHidden().frame(width: 110)
                }
                Divider().padding(.leading, 16)
                SettingRow(title: "Hinge sensor", detail: model.lid.status) {
                    Text("Automatic calibration").font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.permissions.screenRecordingRequested && !model.permissions.screenRecording {
                Footnote(text: "Turn on Sense in macOS settings. If it’s already on, choose Restart Sense above to finish setup.")
            }
            Footnote(text: "Open the lid normally, then close it slowly. No manual calibration is needed. macOS still controls sleep and locking.")
            SettingsCard {
                SettingRow(title: "Lock actions", detail: "Optional Lock Now and welcome-back feedback, independent of the lid fold.") {
                    Toggle("Lock actions", isOn: binding(\.lockEnabled)).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                Divider().padding(.leading, 16)
                SettingRow(title: "Lock your Mac", detail: "Sends the standard Control–Command–Q shortcut.") {
                    Button("Lock Now", systemImage: "lock") { model.lock.lock() }.disabled(!preferences.lockEnabled)
                }
                Divider().padding(.leading, 16)
                SettingRow(title: "Welcome-back feedback", detail: "Appears in the island after a macOS unlock notification.") {
                    Text(preferences.notchEnabled ? "Island enabled" : "Enable the island").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = model.lock.error { Footnote(text: error, symbol: "exclamationmark.circle") }
            Footnote(text: "macOS handles password, Touch ID, and Apple Watch authentication. Sense never reads or stores credentials or draws on the secure login screen.", symbol: "lock.shield")
        }
    }
    private var permissions: some View {
        VStack(alignment: .leading, spacing: 20) {
            SetupChecklist(model: model)
            SettingsCard {
                SettingRow(title: "Accessibility", detail: "Find and focus windows; intercept the switcher shortcut; send Lock Screen.") {
                    permissionControl(granted: model.permissions.accessibility) { model.permissions.requestAccessibility() }
                }
                Divider().padding(.leading, 16)
                SettingRow(title: "Screen Recording", detail: "Window previews and the optional 3D desktop lid fold.") {
                    permissionControl(granted: model.permissions.screenRecording) { model.permissions.requestScreenRecording() }
                }
                Divider().padding(.leading, 16)
                SettingRow(title: "Automation", detail: "Used for Music and Spotify fallback controls and artwork when Now Playing is enabled.") { Button("Manage…") { model.permissions.openPrivacy("Privacy_Automation") } }
            }
            HStack {
                Button("Refresh Status", systemImage: "arrow.clockwise") { model.permissions.refresh(); model.apply() }
                Button("Copy Diagnostics", systemImage: "doc.on.clipboard") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.diagnosticsText, forType: .string)
                }.help("Copies versions and feature status for a bug report. No personal content.")
                Spacer()
            }
            Footnote(text: "Grant only what you use. The island’s battery and volume display and the trackpad scale need no privacy permissions. Camera and microphone access are never requested.", symbol: "hand.raised")
            Footnote(text: "If macOS asks you to restart after granting Screen Recording, use Restart Sense in Lid Fold & Lock. Local builds now reuse the same signing identity.")
        }
    }
    private func binding<T>(_ keyPath: ReferenceWritableKeyPath<Preferences, T>) -> Binding<T> {
        Binding(get: { preferences[keyPath: keyPath] }, set: { preferences[keyPath: keyPath] = $0 })
    }
    private func sectionLabel(_ title: String) -> some View {
        Text(title).font(.system(size: 9, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary).padding(.leading, 3)
    }
    private func featureRow(_ page: SettingsPage, detail: String, enabled: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: page.symbol).font(.system(size: 15)).foregroundStyle(.secondary).frame(width: 24)
            Button { model.page = page } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(page.title).font(.system(size: 12, weight: .medium))
                    Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Toggle(page.title, isOn: enabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }.padding(15)
    }
    private func step(_ number: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number).font(.system(size: 11, weight: .medium)).frame(width: 24, height: 24).background(.primary.opacity(0.05), in: Circle())
            VStack(alignment: .leading, spacing: 4) { Text(title).font(.system(size: 12, weight: .medium)); Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
    private func permissionControl(granted: Bool, action: @escaping () -> Void) -> some View {
        Group {
            if granted { Label("Allowed", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green) }
            else { Button("Allow…", action: action) }
        }
    }
}
