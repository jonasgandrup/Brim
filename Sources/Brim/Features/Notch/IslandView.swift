import SwiftUI

struct IslandView: View {
    @Bindable var controller: NotchController
    let preferences: Preferences
    let status: SystemStatus
    let media: MediaService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var artworkSpace
    private var layout: IslandLayout { controller.layout }
    /// Whether media has a place on the compact island: not while the app playing it is in front.
    private var mediaOnIsland: Bool { preferences.mediaEnabled && media.source != nil && !media.stepsAside(forFrontApp: controller.frontApp) }
    private var dualActivities: Bool { mediaOnIsland && controller.hasDualActivities }
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
    /// Whether the compact island's leading side is the artwork rather than another activity's symbol.
    private var compactShowsArtwork: Bool {
        controller.hud == nil && mediaOnIsland
            && (dualActivities || ![.timer, .transfers, .clipboard, .files].contains(headerTab))
    }
    private var expandedShowsArtwork: Bool {
        controller.expanded && controller.feedback == nil && controller.displayedTab == .music && preferences.mediaEnabled && media.source != nil
    }
    /// Retracting into the camera stays exact: a bounce there would show the hardware cutout.
    private var surfaceAnimation: Animation {
        switch controller.presentation {
        case .expanded: IslandStyle.open
        case .compact: IslandStyle.settle
        case .hidden: .smooth(duration: 0.22)
        }
    }
    var body: some View {
        let base = layout.surfaceSize(for: controller.presentation, reveal: controller.surfaceReveal, notice: controller.showsNotice, paneHeight: controller.paneHeight)
        let notice = controller.showsNotice
        let swell = controller.hoverSwell && !reduceMotion
        let size = CGSize(width: base.width + (swell ? 8 : 0), height: base.height + (swell ? 2 : 0))
        header
            .opacity(controller.presentation == .hidden ? 0 : controller.surfaceReveal)
            .frame(width: size.width, height: layout.headerHeight)
            .frame(width: size.width, height: size.height, alignment: .top)
            .overlay(alignment: .top) {
                // An overlay keeps expanded content from changing the compact header's layout.
                expandedPane
                    .fixedSize(horizontal: false, vertical: !notice && controller.paneFitsContent)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        if !controller.showsNotice { controller.receivePaneHeight(height) }
                    }
                    .frame(width: (notice ? layout.noticeSize : layout.expandedSize).width - 44, height: notice ? IslandLayout.noticeContentHeight : 176, alignment: .top)
                    .padding(.top, layout.headerHeight + IslandLayout.paneTopGap)
                    .opacity(controller.expanded ? 1 : 0)
                    .blur(radius: controller.expanded || reduceMotion ? 0 : 6)
                    .scaleEffect(controller.expanded ? 1 : 0.94, anchor: .top)
                    .offset(y: controller.expanded ? 0 : -8)
                    .allowsHitTesting(controller.expanded)
                    .accessibilityHidden(!controller.expanded)
            }
            .overlay(alignment: .topLeading) { morphingArtwork }
        .background { IslandGlass(shape: surface) }
        .clipShape(surface)
        .background(alignment: .topTrailing) {
            // Behind the island, so what shows is the droplet pulling away and never anything over the activity.
            ActivitySplit(progress: controller.showsActivityBubble ? 1 : 0, side: layout.compactSize.height, gap: IslandLayout.bubbleGap)
                .offset(x: layout.compactSize.height + IslandLayout.bubbleGap)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topTrailing) {
            let parted = controller.showsActivityBubble
            activityBubble
                .scaleEffect(parted ? 1 : 0.6)
                .opacity(parted ? 1 : 0)
                .offset(x: parted ? layout.compactSize.height + IslandLayout.bubbleGap : 0)
                .allowsHitTesting(parted)
                .accessibilityHidden(!parted)
        }
        .opacity(layout.hasHardwareNotch ? 1 : controller.surfaceReveal)
        .foregroundStyle(.white).preferredColorScheme(.dark)
        .contentShape(surface)
        .opacity(!layout.hasHardwareNotch && controller.presentation == .hidden ? 0 : 1)
        .animation(reduceMotion || controller.surfaceAnimationsSuppressed ? nil : surfaceAnimation, value: controller.presentation)
        .animation(reduceMotion ? nil : .smooth(duration: 0.28, extraBounce: 0.04), value: controller.showsNotice)
        .animation(reduceMotion || !controller.expanded ? nil : IslandStyle.resize, value: controller.paneHeight)
        .animation(reduceMotion ? nil : IslandStyle.quick, value: controller.hud)
        .animation(reduceMotion ? nil : IslandStyle.quick, value: controller.hoverSwell)
        .animation(reduceMotion ? nil : IslandStyle.part, value: controller.showsActivityBubble)
        .transaction { transaction in
            if controller.surfaceAnimationsSuppressed { transaction.disablesAnimations = true; transaction.animation = nil }
        }
        .onDrop(of: [.fileURL, .url, .plainText, .image], delegate: ShelfDropDelegate(controller: controller, width: size.width))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityHidden(controller.presentation == .hidden)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Brim island")
        .accessibilityAction(named: controller.expanded ? "Collapse" : "Expand") { controller.setExpanded(!controller.expanded) }
    }

    // MARK: Compact header

    private var header: some View {
        HStack(spacing: 0) {
            Button {
                if dualActivities { controller.clickCompactActivity(.music) }
                else if controller.expanded { controller.setExpanded(false) }
                else { controller.clickCompactActivity(controller.compactLeadingTab) }
            } label: {
                leadingActivity.frame(width: 38, height: layout.headerHeight).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel(!controller.expanded && controller.clickOpensApp(dualActivities ? .music : controller.compactLeadingTab) ? "Open \(media.sourceName)" : dualActivities ? "Open Now Playing" : controller.expanded ? "Collapse island" : "Open \(controller.compactLeadingTab == .timer ? "Clock" : "island")")
            Spacer(minLength: 0)
            if layout.hasHardwareNotch {
                // Keep all controls outside the actual, physically occluded camera region.
                Color.clear.frame(width: layout.cutoutWidth).contentShape(Rectangle())
                    .onTapGesture { toggle() }
            } else {
                // Like the iPhone, the island never names itself: the middle is empty unless a level is changing.
                Text(controller.hud?.label ?? "")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    .contentTransition(.opacity).frame(maxWidth: .infinity).contentShape(Rectangle())
                    .onTapGesture { toggle() }
            }
            Spacer(minLength: 0)
            if controller.expanded {
                // No close button: moving away, clicking outside or Escape closes it, as on iPhone.
                Color.clear.frame(width: 38, height: layout.headerHeight)
            } else {
                Button { controller.clickCompactActivity(dualActivities ? .music : controller.compactTrailingTab) } label: {
                    trailingActivity.frame(width: 38, height: layout.headerHeight).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel(controller.clickOpensApp(dualActivities ? .music : controller.compactTrailingTab) ? "Open \(media.sourceName)" : dualActivities ? "Open Now Playing" : controller.compactTrailingTab == .timer ? "Open timer controls" : "Expand island")
            }
        }.padding(.horizontal, 8)
        .background(alignment: .top) {
            if layout.hasHardwareNotch {
                UnevenRoundedRectangle(bottomLeadingRadius: 9, bottomTrailingRadius: 9)
                    .fill(.black).frame(width: layout.cutoutWidth, height: layout.menuBarHeight)
            }
        }
    }
    @ViewBuilder private var leadingActivity: some View {
        if controller.expanded {
            // The tab bar already says where you are; the corner stays empty rather than repeating it or naming the app.
            Color.clear
        } else if let hud = controller.hud, let battery = hud.battery {
            BatteryGlyph(level: battery, charging: hud.charging, height: 11, tint: hud.tint).accessibilityLabel(hud.label)
        } else if let hud = controller.hud {
            Image(systemName: hud.symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(hud.tint)
                .contentTransition(.symbolEffect(.replace)).accessibilityLabel(hud.label)
        } else if headerTab == .timer && !dualActivities {
            Image(systemName: controller.countdown.focus != nil ? "brain.head.profile" : "timer")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(controller.countdown.focus?.phase == .focus ? Color.red : .orange)
        } else if headerTab == .transfers && !dualActivities {
            Image(systemName: controller.transfers.hasRunning ? "arrow.down.circle.fill" : controller.activities.running.last?.symbol ?? "bolt.fill")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(.blue).contentTransition(.symbolEffect(.replace))
        } else if headerTab == .clipboard && !dualActivities {
            Image(systemName: "pin.fill").font(.system(size: 13)).foregroundStyle(.yellow)
        } else if headerTab == .files && !dualActivities {
            Image(systemName: "tray.full.fill").font(.system(size: 14)).foregroundStyle(.primary)
        } else if mediaOnIsland {
            // The artwork itself is drawn once, above both places it can be, so it can travel between them.
            Color.clear.frame(width: 22, height: 22).matchedGeometryEffect(id: ArtworkSlot.compact, in: artworkSpace)
        } else if controller.feedback != nil {
            Image(systemName: controller.feedbackSymbol).font(.system(size: 14, weight: .medium)).foregroundStyle(controller.feedbackTint)
        } else {
            // Only seen for a moment while the island closes: nothing, rather than the app's logo.
            Color.clear
        }
    }
    @ViewBuilder private var trailingActivity: some View {
        if let hud = controller.hud {
            if let battery = hud.battery {
                Text("\(battery)%").font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(hud.tint).minimumScaleFactor(0.7)
            } else if let level = hud.level { HUDLevel(level: level, tint: hud.tint) }
            else { Circle().fill(hud.tint).frame(width: 7, height: 7) }
        } else if dualActivities {
            PlaybackActivity(playing: media.playing, tint: media.artworkTint)
        } else if controller.countdown.active {
            CompactCountdown(timer: controller.countdown)
        } else if controller.clock.active {
            CompactStopwatch(clock: controller.clock)
        } else if controller.transfers.hasRunning {
            TransferRing(fraction: TransferScan.combinedFraction(controller.transfers.running))
        } else if !controller.activities.running.isEmpty {
            TransferRing(fraction: controller.activities.combinedProgress)
        } else if controller.clipboardHasPins && headerTab == .clipboard {
            CountBadge(count: controller.clipboard.pins.count)
        } else if controller.shelfHasFiles {
            CountBadge(count: controller.shelf.files.count)
        } else if controller.fileDragActive {
            Image(systemName: "plus.circle.fill").font(.system(size: 15)).foregroundStyle(.white, .white.opacity(0.2))
        } else if mediaOnIsland {
            if media.sleepTimer.schedule != nil && !media.playing {
                Image(systemName: "moon.zzz.fill").font(.system(size: 12)).foregroundStyle(.orange)
            } else { PlaybackActivity(playing: media.playing, tint: media.artworkTint) }
        } else if controller.feedback != nil {
            Image(systemName: controller.feedbackSymbol).font(.system(size: 13)).foregroundStyle(controller.feedbackTint.opacity(0.8))
        }
    }
    private func toggle() {
        if controller.expanded { controller.setExpanded(false) } else { controller.clickCompactActivity(controller.compactLeadingTab) }
    }
    @ViewBuilder private var morphingArtwork: some View {
        let expandedArt = expandedShowsArtwork
        if expandedArt || (!controller.expanded && compactShowsArtwork && controller.presentation != .hidden) {
            ArtworkTile(image: media.artwork, appIcon: media.coverOnItsWay ? nil : media.sourceIcon, radius: expandedArt ? 12 : 6)
                .matchedGeometryEffect(id: expandedArt ? ArtworkSlot.expanded : ArtworkSlot.compact, in: artworkSpace, isSource: false)
                .shadow(color: .black.opacity(expandedArt ? 0.45 : 0), radius: 8, y: 3)
                .opacity(expandedArt ? controller.paneOpacity : controller.surfaceReveal)
                .allowsHitTesting(false)
        }
    }
    /// The second activity's own small island: the timer's progress around its symbol.
    private var activityBubble: some View {
        let side = layout.compactSize.height
        let focus = controller.countdown.focus?.phase == .focus
        let tint: Color = focus ? .red : .orange
        return Button { controller.openCompactActivity(.timer) } label: {
            CountdownRing(timer: controller.countdown, tint: tint, symbol: focus ? "brain.head.profile" : "timer", animated: controller.showsActivityBubble)
                .padding(7)
                .frame(width: side, height: side)
                .background(.black, in: Circle())
                .contentShape(Circle())
        }.buttonStyle(IslandPressStyle()).help("Open timer")
    }
    // MARK: Expanded

    private var expandedPane: some View {
        VStack(spacing: 8) {
            if controller.feedback == nil && controller.visibleTabs.count > 1 {
                IslandTabBar(selection: $controller.selectedTab,
                             tabs: IslandTabBar.items(for: controller.visibleTabs, downloads: preferences.liveTransfers || controller.transfers.hasRunning))
            }
            if controller.feedback != nil { feedbackContent }
            else if controller.dropTargeted && controller.dropIsFiles && controller.airDropAvailable {
                DropZonesView(zone: controller.dropZone).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if controller.paneMounted {
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
        case .transfers:
            TransfersPaneView(transfers: controller.transfers, activities: controller.activities, enabled: preferences.liveTransfers, enable: { controller.connectTransfers() },
                              addToShelf: { url in controller.shelf.add([url]); controller.selectedTab = .files })
        case .music:
            if media.source == nil || !preferences.mediaEnabled {
                // Nothing playing: a calm glance at the time, the next event and the battery instead of an empty player.
                IslandOverview(status: status, calendar: controller.calendar, media: media, mediaEnabled: preferences.mediaEnabled,
                               connectMedia: { controller.connectMedia() }, allowPlayers: { controller.allowPlayerAccess() })
            } else {
                VStack(spacing: 6) {
                    IslandPaneHeader {
                        MediaPlayerControls(media: media)
                        Button { controller.openSettings() } label: { Image(systemName: "gearshape").frame(width: 20, height: 20) }
                            .help("Island settings").accessibilityLabel("Open island settings")
                    }
                    nowPlaying
                }
            }
        }
    }
    @ViewBuilder private var feedbackContent: some View {
        if let device = controller.feedbackDevice {
            AccessoryFeedbackView(device: device)
        } else if let feedback = controller.feedback, let image = controller.feedbackImage {
            VStack(spacing: 8) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 104)
                    .clipShape(RoundedRectangle(cornerRadius: IslandStyle.smallRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: IslandStyle.smallRadius, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
                    .onDrag { controller.feedbackURL.flatMap { NSItemProvider(contentsOf: $0) } ?? NSItemProvider() }
                    .help("Drag the screenshot anywhere")
                Text(feedback).font(.system(size: 12, weight: .medium)).foregroundStyle(.primary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let feedback = controller.feedback {
            HStack(spacing: 12) {
                Image(systemName: controller.feedbackSymbol).font(.system(size: 17, weight: .semibold)).symbolRenderingMode(.hierarchical)
                    .foregroundStyle(controller.feedbackTint)
                    .frame(width: 36, height: 36).background(controller.feedbackTint.opacity(0.16), in: Circle())
                    .symbolEffect(.bounce, value: feedback)
                Text(feedback).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                Spacer(minLength: 0)
                if let action = controller.feedbackAction {
                    Button {
                        NSWorkspace.shared.open(action.url); controller.dismissFeedback()
                    } label: {
                        Label(action.title, systemImage: "video.fill").font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 12).padding(.vertical, 6).fixedSize()
                            .background(Color.green, in: Capsule()).foregroundStyle(.black)
                    }.buttonStyle(.plain)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    @ViewBuilder private var nowPlaying: some View {
        if media.source != nil {
            VStack(spacing: 6) {
                HStack(spacing: 12) {
                    Color.clear.frame(width: 52, height: 52).matchedGeometryEffect(id: ArtworkSlot.expanded, in: artworkSpace)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(media.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                            .contentTransition(.opacity)
                        // The player menu above already names the app, so it isn't named again here.
                        if !media.artist.isEmpty {
                            Text(media.artist).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                                .contentTransition(.opacity)
                        }
                        if media.offersArtworkAccess {
                            Button("Show Artwork") { controller.allowPlayerAccess() }.buttonStyle(.plain).foregroundStyle(.secondary)
                                .font(.system(size: 10)).fixedSize().help("macOS asks once for access to Music and Spotify.")
                        }
                    }.animation(reduceMotion ? nil : IslandStyle.quick, value: media.title)
                    Spacer(minLength: 0)
                }
                // Tapping what's playing goes to it, as in the iPhone's expanded island.
                .contentShape(Rectangle())
                .onTapGesture { media.openPlayer() }
                .accessibilityAction(named: "Open \(media.sourceName)") { media.openPlayer() }
                if let message = media.message {
                    Text(message).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        .frame(height: 17).help(message)
                } else { MediaProgress(media: media) }
                HStack(spacing: 28) {
                    playbackButton("backward.fill", label: "Previous track in \(media.sourceName)", help: "Previous track in \(media.sourceName) only", command: "previous track")
                    playControl
                    playbackButton("forward.fill", label: "Next track in \(media.sourceName)", help: "Next track in \(media.sourceName) only", command: "next track")
                }.frame(maxWidth: .infinity)
                .overlay(alignment: .trailing) {
                    AirPlayButton().frame(width: 26, height: 26).help("Choose where audio plays")
                }
            }
            .help(media.message ?? String(localized: "Now Playing from \(media.sourceName)"))
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
                .animation(reduceMotion ? nil : IslandStyle.standard, value: media.playing)
                .font(.system(size: 19, weight: .semibold)).foregroundStyle(.white).frame(width: 38, height: 32)
        }.disabled(media.source == nil || media.commandPending || media.selectionLoading)
            .foregroundStyle(.white.opacity(media.source == nil ? 0.22 : 1))
            .accessibilityLabel(media.playing ? "Pause \(media.sourceName)" : "Play \(media.sourceName)")
            .help(media.playing ? "Pause \(media.sourceName) only" : "Play \(media.sourceName) only")
    }
    private func playbackButton(_ symbol: String, label: LocalizedStringKey, help: LocalizedStringKey, command: String) -> some View {
        Button { media.command(command) } label: {
            Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).frame(width: 34, height: 30).contentShape(Rectangle())
        }.buttonStyle(IslandPressStyle()).disabled(media.source == nil || media.commandPending || media.selectionLoading)
            .foregroundStyle(.white.opacity(media.source == nil ? 0.22 : 0.85)).accessibilityLabel(label).help(help)
    }
}

/// The island's sections as a quiet strip of symbols with one sliding highlight. The island already opens
/// at what's happening, so this is a way to look elsewhere, not the main way in.
struct IslandTabBar: View {
    typealias Item = (tab: IslandTab, symbol: String, title: String)
    @Binding var selection: IslandTab
    let tabs: [Item]
    @Namespace private var highlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    /// The last tab is named for whether it's holding downloads or only a script's activity.
    static func items(for tabs: [IslandTab], downloads: Bool = true) -> [Item] {
        tabs.map { tab in
            switch tab {
            case .music: (tab, "play.fill", String(localized: "Now Playing"))
            case .files: (tab, "tray.fill", String(localized: "Files"))
            case .clipboard: (tab, "pin.fill", String(localized: "Clipboard"))
            case .timer: (tab, "clock.fill", String(localized: "Clock"))
            case .transfers: downloads ? (tab, "arrow.down.circle.fill", String(localized: "Downloads & AirDrop")) : (tab, "gauge.with.dots.needle.33percent", String(localized: "Activity"))
            }
        }
    }
    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs, id: \.tab) { item in
                let selected = selection == item.tab
                Button {
                    withAnimation(reduceMotion ? nil : IslandStyle.quick) { selection = item.tab }
                } label: {
                    Image(systemName: item.symbol).font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(contrast == .increased ? .secondary : .tertiary))
                        .frame(maxWidth: .infinity, minHeight: 20)
                        .background {
                            if selected { Capsule().fill(.white.opacity(contrast == .increased ? 0.28 : 0.14)).matchedGeometryEffect(id: "tab", in: highlight) }
                        }
                        .contentShape(Capsule())
                }.buttonStyle(.plain)
                    .help(item.title).accessibilityLabel(item.title)
                    .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(.white.opacity(contrast == .increased ? 0.1 : 0.04), in: Capsule())
        .accessibilityElement(children: .contain).accessibilityLabel("Island section")
    }
}

/// A shared empty state: one symbol, a title, a line of detail and an optional action.
struct IslandEmptyState<Actions: View>: View {
    let symbol: String
    let title: LocalizedStringKey
    var detail: LocalizedStringKey?
    var minHeight: CGFloat = 100
    @ViewBuilder var actions: () -> Actions
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 24, weight: .light)).foregroundStyle(.tertiary)
            Text(title).font(.system(size: 13, weight: .semibold))
            if let detail {
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).lineLimit(2).padding(.horizontal, 12)
            }
            actions().padding(.top, 2)
        }.frame(maxWidth: .infinity, minHeight: minHeight)
    }
}
extension IslandEmptyState where Actions == EmptyView {
    init(symbol: String, title: LocalizedStringKey, detail: LocalizedStringKey? = nil, minHeight: CGFloat = 100) {
        self.init(symbol: symbol, title: title, detail: detail, minHeight: minHeight) { EmptyView() }
    }
}

/// Scales slightly while pressed, the way Dynamic Island controls respond to touch.
struct IslandPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(IslandStyle.quick, value: configuration.isPressed)
    }
}

private struct CountBadge: View {
    let count: Int
    var body: some View {
        Text("\(count)").font(.system(size: 10, weight: .bold)).monospacedDigit()
            .padding(.horizontal, 5).frame(minWidth: 17, minHeight: 17)
            .background(IslandStyle.raisedFill, in: Capsule())
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
            .animation(IslandStyle.quick, value: level)
            .accessibilityElement().accessibilityLabel("\(Int((level * 100).rounded())) percent")
    }
}

/// Keeps one indicator alive across pause/play so bars settle and grow instead of being replaced. The motion is
/// handed to Core Animation, which plays it on its own, as the iPhone's island does: Brim describes each bar's wave
/// once and isn't woken for every frame.
private struct PlaybackActivity: View {
    var playing: Bool
    var tint: ArtworkTint.RGB
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        PlaybackBarsLayer(playing: playing, tint: tint, reduceMotion: reduceMotion)
            .frame(width: 21, height: 16).accessibilityLabel(playing ? "Media playing" : "Media paused")
    }
}

/// The bars' shape, shared by the live layer and the still picture: five bars on one wave, each a little later.
private enum PlaybackWave {
    static let count = 5
    static let speed = 4.5
    static let spacing = 1.8
    static let width: CGFloat = 2.5
    static let gap: CGFloat = 4.5
    static let rest: CGFloat = 2.5
    static func height(index: Int, time: Double, activity: Double = 1) -> CGFloat {
        let wave = (sin(time * speed + Double(index) * spacing) + 1) * 5
        return rest + CGFloat(activity * (1.5 + wave))
    }
}

/// A still picture of the bars, for previews that render an image rather than a live layer.
private struct PlaybackBars: View {
    var activity: Double
    var time: Double
    var tint: ArtworkTint.RGB
    var body: some View {
        Canvas { context, size in
            for index in 0..<PlaybackWave.count {
                let height = PlaybackWave.height(index: index, time: time, activity: activity)
                let rect = CGRect(x: Double(index) * PlaybackWave.gap, y: (size.height - height) / 2, width: PlaybackWave.width, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: PlaybackWave.width / 2), with: .color(tint.mixed(fromGray: 0.55, by: activity)))
            }
        }
    }
}

private struct PlaybackBarsLayer: NSViewRepresentable {
    var playing: Bool
    var tint: ArtworkTint.RGB
    var reduceMotion: Bool
    func makeNSView(context: Context) -> PlaybackBarsView { PlaybackBarsView() }
    func updateNSView(_ view: PlaybackBarsView, context: Context) {
        let color = playing ? NSColor(red: tint.red, green: tint.green, blue: tint.blue, alpha: 1) : NSColor(white: 0.55, alpha: 1)
        view.update(playing: playing, color: color, reduceMotion: reduceMotion)
    }
}

/// Five layers whose heights Core Animation moves along the wave forever while playing; pausing settles them into
/// dots, and playing grows them back into the wave, each in 0.3 seconds.
final class PlaybackBarsView: NSView {
    private var bars: [CALayer] = []
    private var shown: (playing: Bool, reduceMotion: Bool)?
    private static let settle = 0.3
    private static var period: Double { 2 * .pi / PlaybackWave.speed }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for index in 0..<PlaybackWave.count {
            let bar = CALayer()
            bar.cornerRadius = PlaybackWave.width / 2
            bar.bounds = CGRect(x: 0, y: 0, width: PlaybackWave.width, height: PlaybackWave.rest)
            bar.position = CGPoint(x: CGFloat(index) * PlaybackWave.gap + PlaybackWave.width / 2, y: 8)
            layer?.addSublayer(bar); bars.append(bar)
        }
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (index, bar) in bars.enumerated() {
            bar.position = CGPoint(x: CGFloat(index) * PlaybackWave.gap + PlaybackWave.width / 2, y: bounds.midY)
        }
        CATransaction.commit()
    }
    func update(playing: Bool, color: NSColor, reduceMotion: Bool) {
        CATransaction.begin(); CATransaction.setAnimationDuration(Self.settle)
        for bar in bars { bar.backgroundColor = color.cgColor }
        CATransaction.commit()
        guard shown.map({ $0.playing != playing || $0.reduceMotion != reduceMotion }) ?? true else { return }
        let first = shown == nil
        shown = (playing, reduceMotion)
        for (index, bar) in bars.enumerated() {
            let current = bar.presentation()?.bounds.height ?? bar.bounds.height
            bar.removeAnimation(forKey: "wave")
            let target: CGFloat
            if !playing { target = PlaybackWave.rest } else { target = PlaybackWave.height(index: index, time: 0) }
            setHeight(bar, target, from: first ? nil : current)
            guard playing, !reduceMotion else { continue }
            // One cycle of the wave, starting where this bar's growth ends, repeated by Core Animation forever.
            let loop = CAKeyframeAnimation(keyPath: "bounds.size.height")
            let samples = 24
            loop.values = (0...samples).map { PlaybackWave.height(index: index, time: Self.period * Double($0) / Double(samples)) }
            loop.calculationMode = .cubic
            loop.duration = Self.period
            loop.repeatCount = .infinity
            loop.beginTime = CACurrentMediaTime() + (first ? 0 : Self.settle)
            loop.fillMode = .forwards
            loop.isRemovedOnCompletion = false
            bar.add(loop, forKey: "wave")
        }
    }
    private func setHeight(_ bar: CALayer, _ height: CGFloat, from current: CGFloat?) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        bar.bounds.size.height = height
        CATransaction.commit()
        guard let current, abs(current - height) > 0.1 else { return }
        let move = CABasicAnimation(keyPath: "bounds.size.height")
        move.fromValue = current; move.toValue = height
        move.duration = Self.settle; move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        bar.add(move, forKey: "settle")
    }
}

/// The bubble's way out of the island: a droplet that stretches a neck of black and then lets go, as on iPhone.
/// Blurring the two shapes together and cutting at half opacity is what makes them flow into each other.
private struct ActivitySplit: View, Animatable {
    nonisolated var progress: Double
    let side: CGFloat
    let gap: CGFloat
    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }
    var body: some View {
        Canvas { context, size in
            guard progress > 0.001 else { return }
            context.addFilter(.alphaThreshold(min: 0.5, color: .black))
            context.addFilter(.blur(radius: 3.5))
            context.drawLayer { layer in
                // The canvas starts one bubble inside the island, whose rounded end this repeats.
                layer.fill(Path(roundedRect: CGRect(x: -side, y: 0, width: side * 2, height: side), cornerRadius: side / 2), with: .color(.black))
                let travel = progress * (side + gap)
                layer.fill(Path(ellipseIn: CGRect(x: travel, y: 0, width: side, height: side)), with: .color(.black))
            }
        }
        .frame(width: side + gap + side, height: side)
    }
}

#if DEBUG
/// A moving droplet and live colors can't be judged from one screenshot of a settled island, so the smoke test draws them.
@MainActor enum IslandMotionPreview {
    static func image() -> Data? {
        let side: CGFloat = 32, gap = IslandLayout.bubbleGap
        let content = VStack(alignment: .leading, spacing: 14) {
            ForEach([0.15, 0.3, 0.45, 0.6, 0.8, 1.0], id: \.self) { progress in
                RoundedRectangle(cornerRadius: side / 2, style: .continuous).fill(.black).frame(width: 160, height: side)
                    .background(alignment: .topTrailing) {
                        ActivitySplit(progress: progress, side: side, gap: gap).offset(x: side + gap)
                    }
            }
            HStack(spacing: 14) {
                ForEach(Array([NSColor.systemRed, .systemBlue, .systemYellow, .systemPurple, NSColor(white: 0.5, alpha: 1)].enumerated()), id: \.offset) { _, color in
                    PlaybackBars(activity: 1, time: 1, tint: ArtworkTint.rgb(of: ArtworkTint.swatch(color)))
                        .frame(width: 24, height: 18).padding(8).background(.black, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }.padding(16).padding(.trailing, 60).background(.white)
        let renderer = ImageRenderer(content: content); renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }
}
#endif

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
                        }.font(.system(size: 10, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            } else {
                Color.clear.accessibilityHidden(true)
            }
        }.frame(height: 22)
    }
}

/// While files are dragged over the island: drop on the left to keep them on the shelf, on the right to AirDrop them.
struct DropZonesView: View {
    let zone: DropZone
    var body: some View {
        HStack(spacing: 10) {
            tile(.shelf, symbol: "tray.and.arrow.down.fill", title: String(localized: "Files"), tint: .white)
            tile(.airDrop, symbol: "dot.radiowaves.up.forward", title: "AirDrop", tint: .blue)
        }
        .animation(IslandStyle.quick, value: zone)
    }
    private func tile(_ kind: DropZone, symbol: String, title: String, tint: Color) -> some View {
        let active = zone == kind
        return VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 28, weight: .medium)).foregroundStyle(active ? tint : .white.opacity(0.4))
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(active ? .primary : .secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.white.opacity(active ? 0.12 : 0.04), in: RoundedRectangle(cornerRadius: IslandStyle.largeRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: IslandStyle.largeRadius, style: .continuous)
            .strokeBorder(active ? tint.opacity(0.7) : .white.opacity(0.1), style: StrokeStyle(lineWidth: 1.5, dash: active ? [] : [4, 3])))
        .scaleEffect(active ? 1 : 0.97)
        .accessibilityElement(children: .combine).accessibilityAddTraits(active ? .isSelected : [])
    }
}

// The parts that change every second are views of their own: a tick then redraws just them, not the whole island.

private struct CompactCountdown: View {
    let timer: IslandTimer
    var body: some View {
        CountdownText(timer: timer)
            .font(.system(size: 10, weight: .semibold)).monospacedDigit()
            .foregroundStyle(timer.focus?.phase == .focus ? Color.red : .orange).minimumScaleFactor(0.6)
    }
}

/// Counts up on its own from when the stopwatch started, like the countdown; paused, it's plain text.
private struct CompactStopwatch: View {
    let clock: ClockTools
    var body: some View {
        Group {
            if let start = clock.stopwatchStart, !clock.ringing {
                Text(timerInterval: start...Date.distantFuture, countsDown: false)
            } else {
                Text(clock.label)
            }
        }
        .font(.system(size: 10, weight: .semibold)).monospacedDigit()
        .foregroundStyle(.orange).minimumScaleFactor(0.6)
    }
}

/// The timer's progress around its symbol, in the second activity's small island. It's always there, faded out until
/// a second activity parts from the island, so it only animates while it shows.
private struct CountdownRing: View {
    let timer: IslandTimer
    let tint: Color
    let symbol: String
    var animated = true
    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.25), lineWidth: 2.5)
            CountdownProgress(timer: timer, live: animated) { progress in
                Circle().trim(from: 0, to: 1 - progress)
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round)).rotationEffect(.degrees(-90))
            }
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
        }
        .accessibilityElement(children: .ignore).accessibilityLabel("Timer, \(timer.label) left")
    }
}
