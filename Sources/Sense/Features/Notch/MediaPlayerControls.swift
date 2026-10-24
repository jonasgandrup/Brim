import SwiftUI

struct MediaPlayerControls: View {
    @Bindable var media: MediaService
    var body: some View {
        Menu {
            Section("Player") {
                Button { media.selectPlayer(nil) } label: {
                    Label("Automatic", systemImage: media.pinnedPlayer == nil ? "checkmark" : "waveform")
                }
                ForEach(media.players) { player in
                    Button { media.selectPlayer(player) } label: {
                        Label(player.name, systemImage: media.pinnedPlayer?.source == player.source ? "pin.fill" : "play.rectangle")
                    }
                }
                if let pin = media.pinnedPlayer, !media.players.contains(where: { $0.source == pin.source }) {
                    Text("\(pin.name) · unavailable")
                }
                Button("Refresh players") { Task { await media.refreshPlayers() } }
            }
            if media.source != nil {
                Divider()
                Button("Open \(media.sourceName)") { media.openPlayer() }
            }
        } label: {
            HStack(spacing: 4) {
                if media.selectionLoading { ProgressView().controlSize(.mini).frame(width: 12, height: 12) }
                else if media.pinnedPlayer != nil { Image(systemName: "pin.fill").font(.system(size: 9)) }
                else if let icon = media.sourceIcon { Image(nsImage: icon).resizable().frame(width: 13, height: 13) }
                Text(media.pinnedPlayer?.name ?? (media.source == nil ? "Automatic" : media.sourceName)).lineLimit(1).frame(maxWidth: 82, alignment: .leading)
            }
        }.menuStyle(.borderlessButton).fixedSize().disabled(media.commandPending)
            .help(media.pinnedPlayer == nil ? "Choose and pin a player" : "Player pinned · choose Automatic to follow macOS")
            .accessibilityLabel("Player picker")
        Menu {
            if let schedule = media.sleepTimer.schedule {
                Text(schedule.endOfTrack ? "Pause \(schedule.player.name) at end of track" : "Pause \(schedule.player.name) in \(MediaTimeline.label(media.sleepTimer.remaining))")
                Button("Cancel sleep timer") { media.sleepTimer.cancel() }
            } else {
                if let status = media.sleepTimer.status { Text(status) }
                Button("End of Current Track") { media.startTrackEndSleepTimer() }
                    .disabled(!media.canSleepAtTrackEnd || media.sleepTimer.firing)
                if !media.canSleepAtTrackEnd { Text("Requires track duration and playback information") }
                Divider()
                ForEach([15, 30, 45, 60, 90], id: \.self) { minutes in
                    Button("Pause \(media.sourceName) after \(minutes) min") { media.startSleepTimer(minutes: minutes) }
                        .disabled(media.currentPlayer == nil || media.selectionLoading || media.sleepTimer.firing)
                }
                Text("Keep Sense running · pauses on wake if asleep")
            }
        } label: {
            Image(systemName: media.sleepTimer.schedule == nil ? "moon" : "moon.zzz.fill").frame(width: 20, height: 20)
                .foregroundStyle(media.sleepTimer.schedule == nil ? Color.white.opacity(0.7) : .orange)
        }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Media sleep timer")
            .help(media.sleepTimer.schedule.map { $0.endOfTrack ? "Pauses \($0.player.name) at end of track" : "Pauses \($0.player.name) in \(MediaTimeline.label(media.sleepTimer.remaining))" } ?? "Set a sleep timer for this player")
    }
}

struct MediaCover: View {
    let image: NSImage?
    let size: CGFloat
    let radius: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            Color.white.opacity(0.07)
            if let image { Image(nsImage: image).resizable().scaledToFill().transition(.opacity) }
            else { Image(systemName: "waveform").font(.system(size: size * 0.36, weight: .light)).foregroundStyle(.white.opacity(0.35)) }
        }.frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: image != nil)
            .accessibilityHidden(true)
    }
}
