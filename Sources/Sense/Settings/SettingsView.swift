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
        .onChange(of: preferences.mediaEnabled) { model.apply() }
        .onChange(of: preferences.shortcut) { model.switcher.stop(); model.apply() }
    }
    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 7) {
                Text(model.page.title).font(.system(size: 27, weight: .semibold))
                Text(model.page.subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
            }.padding(.top, 8)
            content
            Spacer(minLength: 12)
        }.padding(32).frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity)
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                SenseMark(size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Sense").font(.system(size: 17, weight: .semibold))
                    Text("Made for your Mac").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 20).padding(.top, 42).padding(.bottom, 30)
            VStack(spacing: 5) {
                ForEach(SettingsPage.allCases) { page in
                    Button { withAnimation(.easeInOut(duration: 0.12)) { model.page = page } } label: {
                        HStack(spacing: 11) {
                            Image(systemName: page.symbol).font(.system(size: 14, weight: .regular)).frame(width: 21)
                            Text(page.title).font(.system(size: 12, weight: model.page == page ? .medium : .regular))
                            Spacer(minLength: 0)
                        }.padding(.horizontal, 12).frame(height: 36)
                            .background(model.page == page ? Color.primary.opacity(0.075) : .clear, in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityAddTraits(model.page == page ? .isSelected : [])
                }
            }.padding(.horizontal, 12)
            Spacer()
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) { Circle().fill(.green.opacity(0.8)).frame(width: 5, height: 5); Text("Quietly in the background").font(.system(size: 10)) }
                Text("Sense 0.1.0 · Local by design").font(.system(size: 10)).foregroundStyle(.tertiary)
            }.foregroundStyle(.secondary).padding(22)
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
            HStack(spacing: 20) {
                SenseMark(size: 72)
                VStack(alignment: .leading, spacing: 7) {
                    Text("Small touches.\nA better everyday.").font(.system(size: 23, weight: .medium)).lineSpacing(2)
                    Text("Thoughtful utilities, right where you need them.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }.padding(.vertical, 12)
            VStack(alignment: .leading, spacing: 10) {
                sectionLabel("YOUR MAC, YOUR WAY")
                SettingsCard {
                    featureRow(.notch, detail: "Now playing, power, and a little breathing room.", enabled: binding(\.notchEnabled))
                    Divider().padding(.leading, 54)
                    featureRow(.switcher, detail: "Move between windows, not just apps.", enabled: binding(\.switcherEnabled))
                    Divider().padding(.leading, 54)
                    featureRow(.scale, detail: "Explore your trackpad’s pressure sensitivity.", enabled: binding(\.scaleEnabled))
                    Divider().padding(.leading, 54)
                    featureRow(.lock, detail: "A gentle transition into the macOS lock screen.", enabled: binding(\.lockEnabled))
                }
            }
            SettingsCard {
                SettingRow(title: "Launch at login", detail: "Ready when your Mac is.") {
                    Toggle("Launch at login", isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) })).labelsHidden().toggleStyle(.switch).controlSize(.small)
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
                SettingRow(title: "File shelf", detail: "Drop files on the island, switch windows or Spaces, then drag them out.") {
                    Button("Open Shelf") { model.notch.openShelfFromMenu() }.disabled(!preferences.notchEnabled)
                }
                Divider().padding(.leading, 16)
                SettingRow(title: "Timers & clipboard", detail: "Start a timer, or explicitly pin copied text, links and images.") {
                    Button("Timer") { model.notch.openTimerFromMenu() }.disabled(!preferences.notchEnabled)
                    Button("Clipboard") { model.notch.openClipboardFromMenu() }.disabled(!preferences.notchEnabled)
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
                    Picker("Shortcut", selection: binding(\.shortcut)) { Text("⌘ Tab").tag("command"); Text("⌥ Tab").tag("option") }.labelsHidden().frame(width: 110)
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
            FeatureHeader(title: "Trackpad Scale", detail: "Experimental, calibrated pressure estimates.", enabled: binding(\.scaleEnabled))
            SettingsCard {
                SettingRow(title: "Pressure reader", detail: "Uses real AppKit Force Touch events inside the scale window.") { Button("Open Scale") { model.openScale() }.disabled(!preferences.scaleEnabled) }
                Divider().padding(.leading, 16)
                SettingRow(title: "Calibration", detail: preferences.gramsPerUnit > 0 ? "A local calibration is saved. Recalibrate each session." : "Not calibrated. No weight estimate will be shown.") {
                    Button("Reset") { model.scale.resetCalibration(preferences: preferences) }.disabled(preferences.gramsPerUnit == 0)
                }
            }
            VStack(alignment: .leading, spacing: 16) {
                sectionLabel("GETTING A READING")
                step("1", "Keep contact", "Move the pointer over the pressure pad, then press gently with a finger.")
                step("2", "Set a baseline", "With your finger resting lightly, press T on the keyboard to tare.")
                step("3", "Calibrate", "Enter a known mass first. Maintain contact, apply that mass, then press C to calibrate.")
            }.padding(4)
            Footnote(text: "Public AppKit pressure is relative and click-stage dependent, not a continuous force sensor. This cannot reproduce TrackWeight’s passive weighing behavior. No compatible events means this mode is unavailable. Never use it for safety-critical measurements.")
        }
    }
    private var lock: some View {
        VStack(alignment: .leading, spacing: 20) {
            FeatureHeader(title: "Lid Fold & Lock", detail: "The physical lid fold and optional Mac lock actions.", enabled: binding(\.lockEnabled))
            SettingsCard {
                SettingRow(title: "Duo lid closing", detail: "Follows the physical hinge angle as you close your MacBook.") {
                    Toggle("Duo lid closing", isOn: binding(\.lidEffectEnabled)).labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .disabled(!preferences.lockEnabled)
                }
                Divider().padding(.leading, 16)
                SettingRow(title: "Desktop fold", detail: model.lidFoldReadiness.message) {
                    if !model.permissions.screenRecording {
                        Button("Enable Screen Recording…") { model.permissions.requestScreenRecording() }
                    } else {
                        Button("Check Setup") { model.permissions.refresh(); model.apply() }
                    }
                }
                Divider().padding(.leading, 16)
                SettingRow(title: "Hinge sensor", detail: model.lid.status) {
                    Button("Set Open Position") { model.lid.calibrateOpenPosition() }.disabled(model.lid.angle == nil)
                }
            }
            Footnote(text: "Screen Recording permission is in macOS System Settings → Privacy & Security → Screen & System Audio Recording. Enable Sense there, then return to Sense. If macOS asks, quit and reopen Sense.")
            if let message = model.lid.captureMessage { Footnote(text: message) }
            Footnote(text: "Keep the screen at your usual working angle and choose Set Open Position. Then close the lid more than 6° to begin the vertical fold. Reopening reverses it. The effect follows real sensor readings and never changes system sleep or authentication.")
            SettingsCard {
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
            HStack { Button("Refresh Status", systemImage: "arrow.clockwise") { model.permissions.refresh(); model.apply() }; Spacer() }
            Footnote(text: "Grant only what you use. The island’s battery and volume display and the public pressure reader need no privacy permissions. Camera and microphone access are never requested.", symbol: "hand.raised")
            Footnote(text: "If macOS asks you to restart after granting Screen Recording, quit and reopen Sense. Local ad-hoc rebuilds may need permission to be granted again.")
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
