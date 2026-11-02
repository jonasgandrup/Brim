import SwiftUI

/// Where the artwork can sit: beside the camera in the compact island, or in the player when expanded.
enum ArtworkSlot: Hashable { case compact, expanded }

/// Album art that fills whatever frame it's given, so one view can grow from the compact island into the player.
struct ArtworkTile: View {
    let image: NSImage?
    let radius: CGFloat
    var body: some View {
        Color.white.opacity(0.07)
            .overlay {
                if let image { Image(nsImage: image).resizable().scaledToFill() }
                else { Image(systemName: "waveform").font(.system(size: 14, weight: .light)).foregroundStyle(.tertiary) }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// What the island shows when nothing is playing: the time, the next event and the battery, then the player's state.
struct IslandOverview: View {
    let status: SystemStatus
    let calendar: CalendarPeek
    let media: MediaService
    let mediaEnabled: Bool
    let connectMedia: () -> Void
    var allowPlayers: () -> Void = {}
    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(context.date, format: .dateTime.hour().minute())
                            .font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text(context.date, format: .dateTime.weekday(.wide).month(.wide).day())
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if let level = status.battery {
                        HStack(spacing: 6) {
                            Text("\(level)%").font(.system(size: 13, weight: .semibold)).monospacedDigit()
                                .foregroundStyle(BatteryTint.color(level: level, charging: status.details.charging, lowPower: status.details.lowPowerMode))
                            BatteryGlyph(level: level, charging: status.details.charging, lowPower: status.details.lowPowerMode, height: 13)
                        }.padding(.top, 8)
                        .accessibilityElement(children: .ignore).accessibilityLabel("Battery \(level) percent")
                    }
                }
                if let event = calendar.next {
                    HStack(spacing: 6) {
                        Image(systemName: "calendar").foregroundStyle(.red)
                        Text(event.title).lineLimit(1)
                        Text(event.relative(at: context.date)).foregroundStyle(.secondary).fixedSize()
                        Spacer(minLength: 4)
                        if let link = event.meetingURL {
                            Button("Join") { NSWorkspace.shared.open(link) }
                                .buttonStyle(.plain).font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 9).padding(.vertical, 2)
                                .background(Color.green, in: Capsule()).foregroundStyle(.black)
                                .help("Join \(link.host ?? "the meeting")")
                        }
                    }.font(.system(size: 12))
                }
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Image(systemName: "play.circle")
                    Text(mediaEnabled ? (media.message ?? String(localized: "Nothing playing")) : String(localized: "Now Playing is off")).lineLimit(1)
                    Spacer(minLength: 4)
                    if !mediaEnabled {
                        Button("Turn On", action: connectMedia).buttonStyle(.plain).font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 9).padding(.vertical, 2).background(IslandStyle.raisedFill, in: Capsule())
                    } else if media.offersPlayerAccess {
                        Button("Use Music & Spotify", action: allowPlayers).buttonStyle(.plain).font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 9).padding(.vertical, 2).background(IslandStyle.raisedFill, in: Capsule()).fixedSize()
                    } else if media.pinnedPlayer != nil {
                        // A pinned player that stopped publishing can be unpinned right here.
                        MediaPlayerControls(media: media)
                    }
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}
