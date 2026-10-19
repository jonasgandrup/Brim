import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ShelfFile: Identifiable, Equatable {
    let url: URL
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

/// Stores file references only. Adding/removing an item never copies, moves or deletes the source.
@MainActor @Observable
final class FileShelf {
    private(set) var files: [ShelfFile] = []
    var message: String?
    @discardableResult func add(_ urls: [URL]) -> Int {
        var inserted = 0
        for url in urls where url.isFileURL {
            let normalized = url.standardizedFileURL
            guard FileManager.default.fileExists(atPath: normalized.path), !files.contains(where: { $0.url == normalized }) else { continue }
            files.append(ShelfFile(url: normalized)); inserted += 1
        }
        message = inserted > 0 ? nil : "No new accessible files were added."
        return inserted
    }
    func remove(_ file: ShelfFile) { files.removeAll { $0.id == file.id } }
    func clear() { files.removeAll(); message = nil }
    func accept(_ providers: [NSItemProvider]) -> Bool {
        let compatible = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        for provider in compatible {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, _ in
                let url: URL?
                if let value = item as? URL { url = value }
                else if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else if let text = item as? String { url = URL(string: text) }
                else { url = nil }
                guard let url, url.isFileURL else { return }
                Task { @MainActor in _ = self?.add([url]) }
            }
        }
        return !compatible.isEmpty
    }
}

struct ShelfDropDelegate: DropDelegate {
    let controller: NotchController
    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.fileURL]) }
    func dropEntered(info: DropInfo) { controller.setDropTargeted(true) }
    func dropExited(info: DropInfo) { controller.setDropTargeted(false) }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .copy) }
    func performDrop(info: DropInfo) -> Bool {
        let accepted = controller.shelf.accept(info.itemProviders(for: [.fileURL]))
        controller.finishFileDrop()
        return accepted
    }
}

struct FileShelfView: View {
    @Bindable var shelf: FileShelf
    let dropTargeted: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("File shelf", systemImage: "tray").font(.system(size: 13, weight: .medium))
                Spacer()
                if !shelf.files.isEmpty { Button("Clear") { shelf.clear() }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)) }
            }
            if shelf.files.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: "tray.and.arrow.down").font(.system(size: 25, weight: .light))
                    Text(dropTargeted ? "Release to keep files here" : "Drop files here. Drag them out anywhere.").font(.system(size: 12))
                    Text("Switch windows or Spaces while they wait.").font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                }.frame(maxWidth: .infinity, minHeight: 95)
                    .background(.white.opacity(dropTargeted ? 0.1 : 0.035), in: RoundedRectangle(cornerRadius: 15))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(shelf.files) { file in
                            VStack(spacing: 7) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path)).resizable().frame(width: 40, height: 40)
                                Text(file.name).font(.system(size: 10)).lineLimit(2).multilineTextAlignment(.center)
                            }.padding(.vertical, 9).padding(.horizontal, 5).frame(width: 76, height: 95, alignment: .top)
                                .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
                                .onDrag { NSItemProvider(object: file.url as NSURL) }
                                .contextMenu {
                                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                                    Button("Remove from Shelf") { shelf.remove(file) }
                                }
                                .help("Drag \(file.name) into another app. Right-click to remove the reference.")
                        }
                    }
                }
            }
            if let message = shelf.message { Text(message).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)) }
        }.foregroundStyle(.white)
    }
}
