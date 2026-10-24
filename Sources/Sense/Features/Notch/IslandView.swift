import SwiftUI

struct IslandView: View {
    @Bindable var controller: NotchController
    let preferences: Preferences
    let status: SystemStatus
    let media: MediaService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var layout: IslandLayout { controller.layout }
    private var dualActivities: Bool { preferences.mediaEnabled && media.source != nil && controller.countdown.active }
    private var headerTab: IslandTab { controller.expanded ? controller.displayedTab : (dualActivities ? .music : controller.compactLeadingTab) }
    private var radius: CGFloat { controller.presentation == .hidden ? 9 : (controller.expanded ? 34 : layout.compactSize.height / 2) }
    private var surface: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: layout.hasHardwareNotch ? 0 : radius,
            bottomLeadingRadius: radius,
            bottomTrailingRadius: radius,
            topTrailingRadius: layout.hasHardwareNotch ? 0 : radius,
            style: .continuous)
    }
    var body: some View {
        let size = layout.surfaceSize(for: controller.presentation, reveal: controller.surfaceReveal)
        header
            .opacity(controller.presentation == .hidden ? 0 : controller.surfaceReveal)
            .frame(width: size.width, height: layout.headerHeight)
            .frame(width: size.width, height: size.height, alignment: .top)
            .overlay(alignment: .top) {
                // An overlay keeps expanded content from changing the compact header's layout.
                expandedPane
                    .frame(width: layout.expandedSize.width - 44, height: 176, alignment: .top)
                    .padding(.top, layout.headerHeight + 4)
                    .opacity(controller.expanded ? 1 : 0)
                    .blur(radius: controller.expanded || reduceMotion ? 0 : 6)
                    .scaleEffect(controller.expanded ? 1 : 0.94, anchor: .top)
                    .offset(y: controller.expanded ? 0 : -8)
                    .allowsHitTesting(controller.expanded)
                    .accessibilityHidden(!controller.expanded)
            }
        .background { IslandGlass(shape: surface) }
        .clipShape(surface)
        .opacity(layout.hasHardwareNotch ? 1 : controller.surfaceReveal)
        .foregroundStyle(.white).preferredColorScheme(.dark)
        .contentShape(surface)
        .opacity(!layout.hasHardwareNotch && controller.presentation == .hidden ? 0 : 1)
        .animation(reduceMotion || controller.surfaceAnimationsSuppressed ? nil : .smooth(duration: controller.expanded ? 0.32 : 0.22, extraBounce: controller.expanded ? 0.06 : 0), value: controller.presentation)
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: controller.hud)
        .transaction { transaction in
            if controller.surfaceAnimationsSuppressed { transaction.disablesAnimations = true; transaction.animation = nil }
        }
        .onDrop(of: [.fileURL, .url, .plainText, .image], delegate: ShelfDropDelegate(controller: controller))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityHidden(controller.presentation == .hidden)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sense Dynamic Island")
        .accessibilityAction(named: controller.expanded ? "Collapse" : "Expand") { controller.setExpanded(!controller.expanded) }
    }

    // MARK: Compact header

    private var header: some View {
        HStack(spacing: 0) {
            Button {
                if dualActivities { controller.openCompactActivity(.music) }
                else if controller.expanded { controller.setExpanded(false) }
                else { controller.openCompactActivity(controller.compactLeadingTab) }
            } label: {
                leadingActivity.frame(width: 38, height: layout.headerHeight).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel(dualActivities ? "Open Now Playing" : controller.expanded ? "Collapse island" : "Open \(controller.compactLeadingTab == .timer ? "Clock" : "island")")
            Spacer(minLength: 0)
            if layout.hasHardwareNotch {
                // Keep all controls outside the actual, physically occluded camera region.
                Color.clear.frame(width: layout.cutoutWidth).contentShape(Rectangle())
                    .onTapGesture { controller.setExpanded(!controller.expanded) }
            } else {
                Text(controller.hud?.label ?? (media.playing ? "Now Playing" : "Sense"))
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
                    .contentTransition(.opacity).frame(maxWidth: .infinity)
                    .onTapGesture { controller.setExpanded(!controller.expanded) }
            }
            Spacer(minLength: 0)
            if controller.expanded {
                collapseControl.frame(width: 38, height: layout.headerHeight)
            } else {
                Button { controller.openCompactActivity(controller.compactTrailingTab) } label: {
                    trailingActivity.frame(width: 38, height: layout.headerHeight).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel(controller.compactTrailingTab == .timer ? "Open timer controls" : "Expand island")
            }
        }.padding(.horizontal, 8)
        .overlay(alignment: .trailing) {
            if controller.sensorIndicatorVisible && controller.hud == nil {
                Circle().fill(controller.sensors.camera ? Color.green : .orange).frame(width: 6, height: 6)
                    .padding(.trailing, 6)
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityLabel(controller.sensors.camera ? "Camera in use" : "Microphone in use")
            }
        }
        .background(alignment: .top) {
            if layout.hasHardwareNotch {
                UnevenRoundedRectangle(bottomLeadingRadius: 9, bottomTrailingRadius: 9)
                    .fill(.black).frame(width: layout.cutoutWidth, height: layout.menuBarHeight)
            }
        }
    }
    @ViewBuilder private var leadingActivity: some View {
        if let hud = controller.hud, !controller.expanded {
            Image(systemName: hud.symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(hud.tint)
                .contentTransition(.symbolEffect(.replace)).accessibilityLabel(hud.label)
        } else if headerTab == .timer && !dualActivities {
            Image(systemName: controller.countdown.focus != nil ? "brain.head.profile" : "timer")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(controller.countdown.focus?.phase == .focus ? Color.red : .orange)
        } else if headerTab == .transfers && !dualActivities {
            Image(systemName: "arrow.down.circle.fill").font(.system(size: 15)).foregroundStyle(.blue)
        } else if headerTab == .clipboard && !dualActivities {
            Image(systemName: "pin.fill").font(.system(size: 13)).foregroundStyle(.yellow)
        } else if headerTab == .files && !dualActivities {
            Image(systemName: "tray.full.fill").font(.system(size: 14)).foregroundStyle(.white.opacity(0.85))
        } else if media.source != nil && preferences.mediaEnabled {
            MediaCover(image: media.artwork, size: 22, radius: 6)
                .opacity(controller.expanded && controller.displayedTab == .music ? 0 : 1)
        } else {
            Image(systemName: controller.feedback != nil ? controller.feedbackSymbol : "waveform.path")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(controller.feedback != nil ? controller.feedbackTint : .white.opacity(0.85))
        }
    }
    @ViewBuilder private var trailingActivity: some View {
        if let hud = controller.hud {
            if let level = hud.level { HUDLevel(level: level, tint: hud.tint) }
            else { Circle().fill(hud.tint).frame(width: 7, height: 7) }
        } else if controller.countdown.active {
            Text(controller.countdown.state.phase == .finished ? "Done" : controller.countdown.label)
                .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                .foregroundStyle(controller.countdown.focus?.phase == .focus ? Color.red : .orange).minimumScaleFactor(0.6)
                .contentTransition(.numericText(countsDown: true))
        } else if controller.clock.active {
            Text(controller.clock.label).font(.system(size: 10, weight: .semibold)).monospacedDigit()
                .foregroundStyle(.orange).minimumScaleFactor(0.6)
        } else if controller.transfers.hasRunning {
            TransferRing(fraction: TransferScan.combinedFraction(controller.transfers.running))
        } else if !controller.clipboard.pins.isEmpty && headerTab == .clipboard {
            CountBadge(count: controller.clipboard.pins.count)
        } else if !controller.shelf.files.isEmpty {
            CountBadge(count: controller.shelf.files.count)
        } else if controller.fileDragActive {
            Image(systemName: "plus.circle.fill").font(.system(size: 15)).foregroundStyle(.white, .white.opacity(0.2))
        } else if media.source != nil && preferences.mediaEnabled {
            if media.sleepTimer.schedule != nil && !media.playing {
                Image(systemName: "moon.zzz.fill").font(.system(size: 12)).foregroundStyle(.orange)
            } else { PlaybackActivity(playing: media.playing) }
        } else if controller.feedback != nil {
            Image(systemName: controller.feedbackSymbol).font(.system(size: 13)).foregroundStyle(controller.feedbackTint.opacity(0.8))
        }
    }
    @ViewBuilder private var collapseControl: some View {
        let button = Button { controller.setExpanded(false) } label: {
            Image(systemName: "chevron.up").font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.8)).frame(width: 24, height: 18)
        }.help("Collapse island").accessibilityLabel("Collapse island")
        if #available(macOS 26.0, *) {
            button.buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.mini)
        } else {
            button.buttonStyle(.plain).padding(4)
                .background(.white.opacity(0.08), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
        }
    }

    // MARK: Expanded

    private var expandedPane: some View {
        VStack(spacing: 8) {
            if controller.feedback == nil {
                IslandTabBar(selection: $controller.selectedTab,
                             tabs: IslandTabBar.visible(showsTransfers: preferences.liveTransfers || controller.transfers.hasRunning || controller.selectedTab == .transfers,
                                                        hasBattery: status.battery != nil))
            }
            if controller.feedback != nil { feedbackContent }
            else {
                selectedPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .opacity(controller.paneOpacity)
                    .allowsHitTesting(controller.displayedTab == controller.selectedTab)
            }
        }
    }
    @ViewBuilder private var selectedPane: some View {
        switch controller.displayedTab {
        case .files: FileShelfView(shelf: controller.shelf, dropTargeted: controller.dropTargeted)
        case .clipboard: ClipboardShelfView(shelf: controller.clipboard, pinClipboard: { controller.pinClipboard() })
        case .timer: IslandClockView(clock: controller.clock, timer: controller.countdown, calendar: controller.calendar)
        case .battery: BatteryPaneView(status: status, bluetooth: preferences.bluetoothBatteries ? controller.bluetooth : nil, brightness: controller.brightnessControl)
        case .transfers:
            TransfersPaneView(transfers: controller.transfers, enabled: preferences.liveTransfers, enable: { controller.connectTransfers() },
                              addToShelf: { url in controller.shelf.add([url]); controller.selectedTab = .files })
        case .music:
            VStack(spacing: 6) {
                IslandPaneHeader(title: "Now Playing", symbol: "waveform") {
                    MediaPlayerControls(media: media)
                    Button { controller.openSettings() } label: { Image(systemName: "gearshape").frame(width: 20, height: 20) }
                        .help("Dynamic Island settings").accessibilityLabel("Open island settings")
                }
                nowPlaying
            }
        }
    }
    @ViewBuilder private var feedbackContent: some View {
        if let feedback = controller.feedback, let battery = controller.feedbackBattery {
            ChargeFeedbackView(level: battery.level, charging: battery.charging, title: feedback)
        } else if let feedback = controller.feedback, let image = controller.feedbackImage {
            VStack(spacing: 8) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 104)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
                    .onDrag { controller.feedbackURL.flatMap { NSItemProvider(contentsOf: $0) } ?? NSItemProvider() }
                    .help("Drag the screenshot anywhere")
                Text(feedback).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.75))
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let feedback = controller.feedback {
            VStack(spacing: 10) {
                Image(systemName: controller.feedbackSymbol).font(.system(size: 24, weight: .semibold)).symbolRenderingMode(.hierarchical)
                    .foregroundStyle(controller.feedbackTint)
                    .frame(width: 54, height: 54).background(controller.feedbackTint.opacity(0.16), in: Circle())
                    .symbolEffect(.bounce, value: feedback)
                Text(feedback).font(.system(size: 15, weight: .semibold)).multilineTextAlignment(.center).lineLimit(2)
                if let action = controller.feedbackAction {
                    Button {
                        NSWorkspace.shared.open(action.url); controller.dismissFeedback()
                    } label: {
                        Label(action.title, systemImage: "video.fill").font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 16).padding(.vertical, 6)
                            .background(Color.green, in: Capsule()).foregroundStyle(.black)
                    }.buttonStyle(.plain)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    @ViewBuilder private var nowPlaying: some View {
        if media.source == nil {
            IslandEmptyState(symbol: "play.circle", title: "Nothing Playing",
                             detail: preferences.mediaEnabled ? (media.message ?? "Play audio or video in any app to see it here.") : nil) {
                if !preferences.mediaEnabled {
                    Button("Turn On Now Playing") { controller.connectMedia() }
                        .buttonStyle(.borderedProminent).controlSize(.small).tint(.white.opacity(0.18))
                }
            }
        } else {
            VStack(spacing: 6) {
                HStack(spacing: 12) {
                    MediaCover(image: preferences.mediaEnabled ? media.artwork : nil, size: 52, radius: 12)
                        .shadow(color: .black.opacity(0.45), radius: 8, y: 3)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(media.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                            .contentTransition(.opacity)
                        Text(media.artist.isEmpty ? media.sourceName : media.artist)
                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                            .contentTransition(.opacity)
                        HStack(spacing: 4) {
                            if let icon = media.sourceIcon { Image(nsImage: icon).resizable().frame(width: 11, height: 11) }
                            Text("\(media.playing ? "Playing" : "Paused") in \(media.sourceName)")
                        }.font(.system(size: 10)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                    }.animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: media.title)
                    Spacer(minLength: 0)
                }
                if let message = media.message {
                    Text(message).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                        .frame(height: 17).help(message)
                } else { MediaProgress(media: media) }
                HStack(spacing: 28) {
                    playbackButton("backward.fill", label: "Previous", command: "previous track")
                    playControl
                    playbackButton("forward.fill", label: "Next", command: "next track")
                }.frame(maxWidth: .infinity)
            }
            .help(media.message ?? "Now Playing from \(media.sourceName)")
        }
    }
    @ViewBuilder private var playControl: some View {
        if #available(macOS 26.0, *) {
            playButton.buttonStyle(.glass).buttonBorderShape(.circle)
        } else { playButton.buttonStyle(.plain) }
    }
    private var playButton: some View {
        Button { media.command("playpause") } label: {
            Image(systemName: media.playing ? "pause.fill" : "play.fill")
                .contentTransition(.symbolEffect(.replace))
                .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: media.playing)
                .font(.system(size: 19, weight: .semibold)).foregroundStyle(.white).frame(width: 38, height: 32)
        }.disabled(media.source == nil || media.commandPending || media.selectionLoading)
            .foregroundStyle(.white.opacity(media.source == nil ? 0.22 : 1))
            .accessibilityLabel("\(media.playing ? "Pause" : "Play") in \(media.sourceName)")
            .help("\(media.playing ? "Pause" : "Play") \(media.sourceName) only")
    }
    private func playbackButton(_ symbol: String, label: String, command: String) -> some View {
        Button { media.command(command) } label: {
            Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).frame(width: 34, height: 30).contentShape(Rectangle())
        }.buttonStyle(IslandPressStyle()).disabled(media.source == nil || media.commandPending || media.selectionLoading)
            .foregroundStyle(.white.opacity(media.source == nil ? 0.22 : 0.85)).accessibilityLabel("\(label) in \(media.sourceName)").help("\(label) in \(media.sourceName) only")
    }
}

/// The island's sections as a strip of symbols with one sliding highlight, like Control Center's modules.
struct IslandTabBar: View {
    typealias Item = (tab: IslandTab, symbol: String, title: String)
    @Binding var selection: IslandTab
    let tabs: [Item]
    @Namespace private var highlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Only the sections that have something to offer: Transfers appears once it's turned on or busy,
    /// and the controls tab is named for what this Mac has.
    static func visible(showsTransfers: Bool, hasBattery: Bool) -> [Item] {
        var items: [Item] = [(.music, "play.fill", "Now Playing"), (.files, "tray.fill", "Files"), (.clipboard, "pin.fill", "Clipboard"),
                             (.timer, "clock.fill", "Clock"),
                             (.battery, hasBattery ? "battery.100percent" : "slider.horizontal.3", hasBattery ? "Battery & Controls" : "Controls")]
        if showsTransfers { items.append((.transfers, "arrow.down.circle.fill", "Transfers")) }
        return items
    }
    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs, id: \.tab) { item in
                let selected = selection == item.tab
                Button {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) { selection = item.tab }
                } label: {
                    Image(systemName: item.symbol).font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(selected ? 1 : 0.5))
                        .frame(maxWidth: .infinity, minHeight: 22)
                        .background {
                            if selected { Capsule().fill(.white.opacity(0.17)).matchedGeometryEffect(id: "tab", in: highlight) }
                        }
                        .contentShape(Capsule())
                }.buttonStyle(.plain)
                    .help(item.title).accessibilityLabel(item.title)
                    .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(.white.opacity(0.07), in: Capsule())
        .accessibilityElement(children: .contain).accessibilityLabel("Island section")
    }
}

/// A shared empty state: one symbol, a title, a line of detail and an optional action.
struct IslandEmptyState<Actions: View>: View {
    let symbol: String
    let title: String
    var detail: String?
    var minHeight: CGFloat = 100
    @ViewBuilder var actions: () -> Actions
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 24, weight: .light)).foregroundStyle(.white.opacity(0.4))
            Text(title).font(.system(size: 13, weight: .semibold))
            if let detail {
                Text(detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    .multilineTextAlignment(.center).lineLimit(2).padding(.horizontal, 12)
            }
            actions().padding(.top, 2)
        }.frame(maxWidth: .infinity, minHeight: minHeight)
    }
}
extension IslandEmptyState where Actions == EmptyView {
    init(symbol: String, title: String, detail: String? = nil, minHeight: CGFloat = 100) {
        self.init(symbol: symbol, title: title, detail: detail, minHeight: minHeight) { EmptyView() }
    }
}

/// Scales slightly while pressed, the way Dynamic Island controls respond to touch.
struct IslandPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

private struct CountBadge: View {
    let count: Int
    var body: some View {
        Text("\(count)").font(.system(size: 10, weight: .bold)).monospacedDigit()
            .padding(.horizontal, 5).frame(minWidth: 17, minHeight: 17)
            .background(.white.opacity(0.18), in: Capsule())
    }
}

/// The compact HUD's level: a short capsule that fills like the system volume slider.
private struct HUDLevel: View {
    let level: Double
    let tint: Color
    var body: some View {
        Capsule().fill(.white.opacity(0.22)).frame(width: 30, height: 5)
            .overlay(alignment: .leading) {
                Capsule().fill(tint).frame(width: max(5, 30 * min(1, max(0, level))), height: 5)
            }
            .animation(.snappy(duration: 0.15), value: level)
            .accessibilityElement().accessibilityLabel("\(Int((level * 100).rounded())) percent")
    }
}

/// Keeps one indicator alive across pause/play so bars settle and grow instead of being replaced.
private struct PlaybackActivity: View {
    var playing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: reduceMotion || !playing)) { timeline in
            PlaybackBars(activity: playing ? 1 : 0, time: reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate)
                .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: playing)
        }.frame(width: 21, height: 16).accessibilityLabel(playing ? "Media playing" : "Media paused")
    }
}

private struct PlaybackBars: View, Animatable {
    nonisolated var activity: Double
    var time: Double
    nonisolated var animatableData: Double {
        get { activity }
        set { activity = newValue }
    }
    var body: some View {
        Canvas { context, size in
            for index in 0..<5 {
                let wave = (sin(time * 4.5 + Double(index) * 1.8) + 1) * 5
                let height = 2.5 + activity * (1.5 + wave)
                let rect = CGRect(x: Double(index) * 4.5, y: (size.height - height) / 2, width: 2.5, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: 1.25), with: .color(Color(red: 0.55 - 0.3 * activity, green: 0.55 + 0.3 * activity, blue: 0.55 - 0.2 * activity)))
            }
        }
    }
}

private struct MediaProgress: View {
    @Bindable var media: MediaService
    var body: some View {
        Group {
            if let timeline = media.timeline, timeline.usable {
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    let elapsed = media.scrubPosition ?? timeline.elapsed(at: context.date)
                    VStack(spacing: 1) {
                        Slider(value: Binding(get: { media.scrubPosition ?? timeline.elapsed(at: context.date) },
                                              set: { media.previewSeek($0) }), in: 0...timeline.duration,
                               onEditingChanged: { editing in
                            if editing { media.beginScrub() } else { media.commitSeek() }
                        })
                        .controlSize(.mini).tint(.white.opacity(0.8))
                        .disabled(!media.canSeek).frame(height: 12)
                        .accessibilityLabel("Playback position")
                        .accessibilityValue("\(MediaTimeline.label(elapsed)) of \(MediaTimeline.label(timeline.duration))")
                        .help(media.canSeek ? "Click or drag to seek" : "This player doesn’t support seeking")
                        HStack {
                            Text(MediaTimeline.label(elapsed))
                            Spacer()
                            Text("−" + MediaTimeline.label(timeline.duration - elapsed))
                        }.font(.system(size: 9, weight: .medium)).monospacedDigit().foregroundStyle(.white.opacity(0.5))
                    }
                }
            } else {
                Color.clear.accessibilityHidden(true)
            }
        }.frame(height: 22)
    }
}
