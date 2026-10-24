import SwiftUI

/// A small progress ring for the island's compact side; a spinner when nothing reports how far along it is.
struct TransferRing: View {
    let fraction: Double?
    var body: some View {
        Group {
            if let fraction {
                ZStack {
                    Circle().stroke(.white.opacity(0.18), lineWidth: 2.5)
                    Circle().trim(from: 0, to: max(0.03, min(1, fraction)))
                        .stroke(Color.blue, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }.frame(width: 16, height: 16)
            } else {
                ProgressView().controlSize(.mini).frame(width: 16, height: 16)
            }
        }.accessibilityLabel(fraction.map { "Transfer \(Int($0 * 100)) percent" } ?? "Transfer in progress")
    }
}

struct TransfersPaneView: View {
    let transfers: TransferTracker
    let enabled: Bool
    let enable: () -> Void
    let addToShelf: (URL) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            IslandPaneHeader(title: "Transfers", symbol: "arrow.down.circle") {
                if !transfers.recent.isEmpty { Button("Clear") { transfers.clearRecent() } }
            }
            if !enabled {
                IslandEmptyState(symbol: "arrow.down.circle", title: "Watch Downloads and AirDrops",
                                 detail: "Files still arriving in Downloads, and AirDrops you send from the shelf.") {
                    Button("Turn On Live Transfers", action: enable)
                        .buttonStyle(.borderedProminent).controlSize(.small).tint(.blue)
                }
            } else if transfers.running.isEmpty && transfers.recent.isEmpty {
                IslandEmptyState(symbol: "arrow.down.circle", title: transfers.accessProblem ?? "No Transfers",
                                 detail: transfers.accessProblem == nil ? "Downloads from Safari, Chrome and Firefox appear here while they arrive." : nil)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 6) {
                        ForEach(transfers.running) { row($0) }
                        ForEach(transfers.recent) { row($0) }
                    }
                }.frame(maxHeight: 138)
            }
        }.foregroundStyle(.white)
    }
    private func row(_ activity: TransferActivity) -> some View {
        HStack(spacing: 10) {
            Image(systemName: activity.symbol).font(.system(size: 17)).foregroundStyle(Color.blue).frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(activity.name).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
                switch activity.state {
                case .running:
                    if let fraction = activity.fraction { ProgressView(value: fraction).controlSize(.mini).tint(Color.blue) }
                    else { ProgressView().progressViewStyle(.linear).controlSize(.mini) }
                    Text(detail(activity)).font(.system(size: 9)).foregroundStyle(.white.opacity(0.5))
                case .finished: Label("Done", systemImage: "checkmark.circle.fill").font(.system(size: 9)).foregroundStyle(.green)
                case .failed(let message): Text(message).font(.system(size: 9)).foregroundStyle(.orange).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if activity.state == .finished, let url = activity.url, FileManager.default.fileExists(atPath: url.path) {
                Button { addToShelf(url) } label: { Image(systemName: "tray.and.arrow.down") }
                    .buttonStyle(IslandPressStyle()).help("Add to the shelf").accessibilityLabel("Add to shelf")
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(IslandPressStyle()).help("Reveal in Finder").accessibilityLabel("Reveal in Finder")
            }
        }.padding(.horizontal, 10).padding(.vertical, 7)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    private func detail(_ activity: TransferActivity) -> String {
        var parts: [String] = []
        if let fraction = activity.fraction { parts.append("\(Int(fraction * 100))%") }
        if let bytes = activity.bytes { parts.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) }
        return parts.isEmpty ? "In progress" : parts.joined(separator: " · ")
    }
}
