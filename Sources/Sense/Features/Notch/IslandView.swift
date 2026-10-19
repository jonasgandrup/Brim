import SwiftUI

struct IslandView: View {
    @Bindable var controller: NotchController
    let preferences: Preferences
    let status: SystemStatus
    let media: MediaService
    @Namespace private var artworkNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var layout: IslandLayout { controller.layout }
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
        .onDrop(of: [.fileURL], delegate: ShelfDropDelegate(controller: controller))
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
                    if controller.shelfSelected {
                        Image(systemName: "tray.fill").font(.system(size: 15)).foregroundStyle(.white.opacity(0.85))
                    } else if let artwork = media.artwork, preferences.mediaEnabled {
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
                    if !controller.shelf.files.isEmpty {
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
                HStack(spacing: 14) {
                    Button("Music") { controller.shelfSelected = false }.foregroundStyle(controller.shelfSelected ? .white.opacity(0.4) : .white)
                    Button(controller.shelf.files.isEmpty ? "Files" : "Files · \(controller.shelf.files.count)") { controller.shelfSelected = true }
                        .foregroundStyle(controller.shelfSelected ? .white : .white.opacity(0.4))
                    Spacer()
                }.font(.system(size: 10, weight: .medium)).buttonStyle(.plain)
            }
            if controller.shelfSelected && controller.feedback == nil {
                FileShelfView(shelf: controller.shelf, dropTargeted: controller.dropTargeted)
            } else { expandedContent }
        }
    }
    @ViewBuilder private var expandedContent: some View {
        if let feedback = controller.feedback {
            VStack(spacing: 13) {
                Image(systemName: controller.feedbackSymbol).font(.system(size: 30, weight: .light)).symbolRenderingMode(.hierarchical)
                Text(feedback).font(.system(size: 17, weight: .medium))
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if media.source == nil {
            VStack(spacing: 20) {
                HStack {
                    if let battery = status.battery {
                        Label("\(battery)%", systemImage: batterySymbol(battery))
                    }
                    Spacer()
                    Label(status.volume.map { "\(Int(($0 * 100).rounded()))%" } ?? "Unavailable",
                          systemImage: status.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }.font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                Button(preferences.mediaEnabled ? "Music & Spotify settings" : "Connect Music or Spotify") {
                    if preferences.mediaEnabled { controller.openSettings() } else { controller.connectMedia() }
                }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                Button("Settings", systemImage: "gearshape") { controller.openSettings() }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
            }.padding(.top, 16)
        } else {
            VStack(spacing: 17) {
                HStack(spacing: 13) {
                    artwork
                    VStack(alignment: .leading, spacing: 5) {
                        Text(preferences.mediaEnabled ? media.title : "")
                            .contentTransition(.opacity)
                            .animation(.easeInOut(duration: 0.18), value: media.title)
                            .font(.system(size: 15, weight: .semibold)).lineLimit(1)
                        if !preferences.mediaEnabled {
                            Button("Connect Music or Spotify") { controller.connectMedia() }
                                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55)).buttonStyle(.plain)
                        } else {
                            Text(media.message == nil ? media.artist : "Player access unavailable")
                                .contentTransition(.opacity)
                                .animation(.easeInOut(duration: 0.18), value: media.artist)
                                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    Button { controller.openSettings() } label: {
                        Image(systemName: "gearshape").font(.system(size: 13)).foregroundStyle(.white.opacity(0.45)).frame(width: 26, height: 30)
                    }.buttonStyle(.plain).help("Dynamic Island settings").accessibilityLabel("Open island settings")
                }
                HStack(spacing: 27) {
                    playbackButton("backward.fill", label: "Previous track", command: "previous track")
                    playControl
                    playbackButton("forward.fill", label: "Next track", command: "next track")
                }.frame(maxWidth: .infinity)
                HStack(spacing: 6) {
                    Image(systemName: status.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    Text(status.volume.map { "\(Int(($0 * 100).rounded()))%" } ?? "Unavailable").monospacedDigit()
                    Spacer()
                    PlaybackActivity(playing: media.playing)
                    Spacer()
                    if let battery = status.battery {
                        Text("\(battery)%").monospacedDigit()
                        Image(systemName: batterySymbol(battery)).foregroundStyle(status.charging ? Color.green : Color.white.opacity(0.45))
                    } else { Label("AC power", systemImage: "powerplug") }
                }.font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.45))
            }.padding(.top, 4)
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
                    Image(systemName: preferences.mediaEnabled ? "music.note" : "waveform.path")
                        .font(.system(size: 23, weight: .light)).foregroundStyle(.white.opacity(0.65))
                }
            }
        }.animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: media.title)
            .frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .matchedGeometryEffect(id: "artwork", in: artworkNamespace, isSource: controller.expanded)
            .animation(reduceMotion ? nil : .smooth(duration: controller.expanded ? 0.22 : 0.14), value: controller.expanded)
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
                .font(.system(size: 18, weight: .semibold)).frame(width: 34, height: 31)
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
    private func batterySymbol(_ battery: Int) -> String {
        if status.charging { return "battery.100percent.bolt" }
        switch battery {
        case ..<15: return "battery.0percent"
        case ..<40: return "battery.25percent"
        case ..<65: return "battery.50percent"
        case ..<90: return "battery.75percent"
        default: return "battery.100percent"
        }
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
        }.frame(width: 21, height: 16).accessibilityLabel(playing ? "Music playing" : "Music paused")
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
