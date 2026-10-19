import SwiftUI

struct IslandView: View {
    @Bindable var controller: NotchController
    let preferences: Preferences
    let status: SystemStatus
    let media: MediaService
    @Namespace private var artworkNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var layout: IslandLayout { controller.layout }
    private var headerTab: IslandTab { controller.expanded ? controller.selectedTab : controller.compactTab }
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
        let size = controller.presentation == .hidden && layout.hasHardwareNotch
            ? CGSize(width: layout.cutoutWidth, height: layout.menuBarHeight)
            : (controller.expanded ? layout.expandedSize : layout.compactSize)
        header
            .opacity(controller.presentation == .hidden ? 0 : 1)
            .frame(width: size.width, height: layout.headerHeight)
            .frame(width: size.width, height: size.height, alignment: .top)
            .overlay(alignment: .top) {
                // An overlay keeps expanded content from changing the compact header's layout.
                expandedPane
                    .frame(width: layout.expandedSize.width - 48, height: 174, alignment: .top)
                    .padding(.top, layout.headerHeight + 6)
                    .opacity(controller.expanded ? 1 : 0)
                    .allowsHitTesting(controller.expanded)
                    .accessibilityHidden(!controller.expanded)
            }
        .background { IslandGlass(shape: surface, expanded: controller.expanded, opaqueBody: layout.hasHardwareNotch) }
        .clipShape(surface)
        .foregroundStyle(.white).preferredColorScheme(.dark)
        .contentShape(surface)
        .opacity(!layout.hasHardwareNotch && controller.presentation == .hidden ? 0 : 1)
        .animation(reduceMotion ? nil : .smooth(duration: controller.expanded ? 0.22 : 0.14, extraBounce: 0.04), value: controller.presentation)
        .onDrop(of: [.fileURL, .url, .plainText, .image], delegate: ShelfDropDelegate(controller: controller))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityHidden(controller.presentation == .hidden)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sense Dynamic Island")
        .accessibilityAction(named: controller.expanded ? "Collapse" : "Expand") { controller.setExpanded(!controller.expanded) }
    }
    private var header: some View {
        HStack(spacing: 0) {
            Button { controller.setExpanded(!controller.expanded) } label: {
                Group {
                    if headerTab == .timer {
                        Image(systemName: "timer").font(.system(size: 15)).foregroundStyle(.orange)
                    } else if headerTab == .clipboard {
                        Image(systemName: "pin.fill").font(.system(size: 14))
                    } else if headerTab == .files {
                        Image(systemName: "tray.fill").font(.system(size: 15)).foregroundStyle(.white.opacity(0.85))
                    } else if let artwork = media.artwork ?? media.sourceIcon, preferences.mediaEnabled {
                        Image(nsImage: artwork).resizable().scaledToFill()
                            .id(media.title).transition(.opacity)
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: media.title)
                            .frame(width: 22, height: 22).clipShape(RoundedRectangle(cornerRadius: 6))
                            .matchedGeometryEffect(id: "artwork", in: artworkNamespace, isSource: !controller.expanded)
                            .opacity(controller.expanded ? 0 : 1)
                    } else {
                        Image(systemName: controller.feedback != nil ? controller.feedbackSymbol : "waveform.path")
                            .font(.system(size: 15, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                    }
                }.frame(width: 38, height: layout.headerHeight)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(controller.expanded ? "Collapse island" : "Expand island")
            Spacer(minLength: 0)
            if layout.hasHardwareNotch {
                // Keep all controls outside the actual, physically occluded camera region.
                Color.clear.frame(width: layout.cutoutWidth).contentShape(Rectangle())
                    .onTapGesture { controller.setExpanded(!controller.expanded) }
            } else {
                Text(media.playing ? "Now Playing" : "Sense").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75)).frame(maxWidth: .infinity)
                    .onTapGesture { controller.setExpanded(!controller.expanded) }
            }
            Spacer(minLength: 0)
            if controller.expanded {
                collapseControl.frame(width: 38, height: layout.headerHeight)
            } else {
            Button { controller.setExpanded(!controller.expanded) } label: {
                Group {
                    if controller.countdown.active {
                        Text(controller.countdown.state.phase == .finished ? "✓" : controller.countdown.label)
                            .font(.system(size: 9, weight: .semibold)).monospacedDigit().foregroundStyle(.orange).minimumScaleFactor(0.7)
                    } else if !controller.clipboard.pins.isEmpty && headerTab == .clipboard {
                        Text("\(controller.clipboard.pins.count)").font(.system(size: 11, weight: .semibold))
                    } else if !controller.shelf.files.isEmpty {
                        Text("\(controller.shelf.files.count)").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    } else if controller.fileDragActive {
                        Image(systemName: "plus").font(.system(size: 13, weight: .semibold))
                    } else if media.source != nil && preferences.mediaEnabled {
                        PlaybackActivity(playing: media.playing)
                    } else if controller.feedback != nil {
                        Image(systemName: controller.feedbackSymbol).font(.system(size: 14)).foregroundStyle(.white.opacity(0.7))
                    }
                }.frame(width: 38, height: layout.headerHeight).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(controller.expanded ? "Collapse island" : "Expand island")
            }
        }.padding(.horizontal, 8)
        .background(alignment: .top) {
            if layout.hasHardwareNotch {
                UnevenRoundedRectangle(bottomLeadingRadius: 9, bottomTrailingRadius: 9)
                    .fill(.black).frame(width: layout.cutoutWidth, height: layout.menuBarHeight)
            }
        }
    }
    @ViewBuilder private var collapseControl: some View {
        let button = Button { controller.setExpanded(false) } label: {
            Image(systemName: "chevron.up").font(.system(size: 10, weight: .semibold))
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
    private var expandedPane: some View {
        VStack(spacing: 8) {
            if controller.feedback == nil {
                HStack(spacing: 0) {
                    tab("Media", .music)
                    tab("Files", .files, count: controller.shelf.files.count)
                    tab("Clipboard", .clipboard)
                    tab("Timer", .timer)
                }.font(.system(size: 10, weight: .medium)).buttonStyle(.plain).frame(height: 20)
            }
            if controller.feedback != nil { expandedContent }
            else {
                ZStack(alignment: .topLeading) {
                    selectedPane
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .id(controller.selectedTab).transition(.opacity)
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: controller.selectedTab)
            }
        }
    }
    @ViewBuilder private var selectedPane: some View {
        switch controller.selectedTab {
        case .files: FileShelfView(shelf: controller.shelf, dropTargeted: controller.dropTargeted)
        case .clipboard: ClipboardShelfView(shelf: controller.clipboard, pinClipboard: { controller.pinClipboard() })
        case .timer: IslandTimerView(timer: controller.countdown)
        case .music:
            VStack(spacing: 6) {
                IslandPaneHeader(title: "Now Playing", symbol: "waveform") {
                    if media.source != nil {
                        Button { media.openPlayer() } label: {
                            HStack(spacing: 4) {
                                if let icon = media.sourceIcon { Image(nsImage: icon).resizable().frame(width: 13, height: 13) }
                                Text(media.sourceName).lineLimit(1).frame(maxWidth: 90, alignment: .leading)
                            }
                        }.help("Open \(media.sourceName)").accessibilityLabel("Open \(media.sourceName)")
                    }
                    Button { controller.openSettings() } label: { Image(systemName: "gearshape").frame(width: 20, height: 20) }
                        .help("Dynamic Island settings").accessibilityLabel("Open island settings")
                }
                expandedContent
            }
        }
    }
    private func tab(_ title: String, _ tab: IslandTab, count: Int = 0) -> some View {
        Button { controller.selectedTab = tab } label: {
            Text(title).frame(maxWidth: .infinity, minHeight: 20)
                .background(controller.selectedTab == tab ? .white.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .trailing) {
                    if count > 0 {
                        Text("\(count)").font(.system(size: 8, weight: .medium)).monospacedDigit()
                            .frame(width: 17, height: 14).background(.white.opacity(0.09), in: Capsule())
                    }
                }.contentShape(Rectangle())
        }
        .foregroundStyle(controller.selectedTab == tab ? .white : .white.opacity(0.4))
        .accessibilityLabel(count > 0 ? "\(title), \(count) items" : title)
    }
    @ViewBuilder private var expandedContent: some View {
        if let feedback = controller.feedback {
            VStack(spacing: 13) {
                Image(systemName: controller.feedbackSymbol).font(.system(size: 30, weight: .light)).symbolRenderingMode(.hierarchical)
                    .foregroundStyle(controller.feedbackSymbol == "timer" ? Color.orange : .green)
                    .symbolEffect(.bounce, value: feedback)
                Text(feedback).font(.system(size: 17, weight: .medium))
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if media.source == nil {
            VStack(spacing: 7) {
                Image(systemName: "play.rectangle.on.rectangle").font(.system(size: 24, weight: .light))
                    .foregroundStyle(.white.opacity(0.35))
                Text("Nothing playing").font(.system(size: 13, weight: .medium))
                if preferences.mediaEnabled {
                    Text(media.message ?? "Play audio or video in an app to see it here.")
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.45)).multilineTextAlignment(.center).lineLimit(2)
                } else {
                    Button("Enable Now Playing") { controller.connectMedia() }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }.frame(maxWidth: .infinity, minHeight: 104)
        } else {
            VStack(spacing: 6) {
                HStack(spacing: 12) {
                    artwork
                    VStack(alignment: .leading, spacing: 4) {
                        Text(media.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                            .contentTransition(.opacity)
                        Text(media.artist.isEmpty ? media.sourceName : media.artist)
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                            .contentTransition(.opacity)
                    }.animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: media.title)
                    Spacer(minLength: 0)
                }
                if let message = media.message {
                    Text(message).font(.system(size: 9)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                        .frame(height: 17).help(message)
                } else { MediaProgress(timeline: media.timeline) }
                HStack(spacing: 24) {
                    playbackButton("backward.fill", label: "Previous", command: "previous track")
                    playControl
                    playbackButton("forward.fill", label: "Next", command: "next track")
                }.frame(maxWidth: .infinity)
            }
            .help(media.message ?? "Now Playing from \(media.sourceName)")
        }
    }
    private var artwork: some View {
        Group {
            if let artwork = media.artwork, preferences.mediaEnabled {
                Image(nsImage: artwork).resizable().scaledToFill().id(media.title).transition(.opacity)
            }
            else {
                ZStack {
                    Color.white.opacity(0.09)
                    if let icon = media.sourceIcon {
                        Image(nsImage: icon).resizable().scaledToFit().padding(8)
                    } else {
                        Image(systemName: "play.fill").font(.system(size: 21, weight: .light)).foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
        }.animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: media.title)
            .frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .matchedGeometryEffect(id: "artwork", in: artworkNamespace, isSource: controller.expanded)
            .animation(reduceMotion ? nil : .smooth(duration: controller.expanded ? 0.22 : 0.14), value: controller.expanded)
            // Tab changes fade the pane; only expansion should move the shared artwork.
            .animation(nil, value: controller.selectedTab)
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
        }.disabled(media.source == nil)
            .foregroundStyle(.white.opacity(media.source == nil ? 0.22 : 1))
            .accessibilityLabel(media.playing ? "Pause" : "Play")
    }
    private func playbackButton(_ symbol: String, label: String, command: String) -> some View {
        Button { media.command(command) } label: {
            Image(systemName: symbol).font(.system(size: 15, weight: .medium)).frame(width: 34, height: 30)
        }.buttonStyle(.plain).disabled(media.source == nil)
            .foregroundStyle(.white.opacity(media.source == nil ? 0.22 : 0.8)).accessibilityLabel(label)
    }

}

/// Keeps one indicator alive across pause/play so bars settle and grow instead of being replaced.
private struct PlaybackActivity: View {
    var playing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || !playing)) { timeline in
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
    let timeline: MediaTimeline?
    var body: some View {
        Group {
            if let timeline, timeline.usable {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let elapsed = timeline.elapsed(at: context.date)
                    VStack(spacing: 3) {
                        GeometryReader { geometry in
                            Capsule().fill(.white.opacity(0.12))
                                .overlay(alignment: .leading) {
                                    Capsule().fill(.white.opacity(0.55)).frame(width: geometry.size.width * elapsed / timeline.duration)
                                        .animation(.linear(duration: 1), value: elapsed)
                                }
                        }.frame(height: 3)
                        HStack {
                            Text(MediaTimeline.label(elapsed))
                            Spacer()
                            Text("−" + MediaTimeline.label(timeline.duration - elapsed))
                        }.font(.system(size: 8, weight: .medium)).monospacedDigit().foregroundStyle(.white.opacity(0.4))
                    }.accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(MediaTimeline.label(elapsed)) of \(MediaTimeline.label(timeline.duration))")
                }
            } else {
                Color.clear.accessibilityHidden(true)
            }
        }.frame(height: 17)
    }
}
