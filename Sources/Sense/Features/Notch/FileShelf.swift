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
    private(set) var selectedURLs: Set<URL> = []
    var systemUIActive = false
    let actions: FileShelfActions
    init() { actions = FileShelfActions(); actions.shelf = self }
    var availableSelection: [URL] {
        let selected = selectedURLs.isEmpty ? files.prefix(1).map(\.url) : files.filter { selectedURLs.contains($0.url) }.map(\.url)
        return selected.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
    func select(_ urls: Set<URL>) { selectedURLs = urls.intersection(Set(files.map(\.url))) }
    func removeSelection() { files.removeAll { selectedURLs.contains($0.url) }; selectedURLs.removeAll() }
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
    func remove(_ file: ShelfFile) { files.removeAll { $0.id == file.id }; selectedURLs.remove(file.url) }
    func clear() { files.removeAll(); selectedURLs.removeAll(); message = nil }
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
    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.fileURL, .url, .plainText, .image]) }
    func dropEntered(info: DropInfo) { controller.setDropTargeted(true, clipboard: !info.hasItemsConforming(to: [.fileURL])) }
    func dropExited(info: DropInfo) { controller.setDropTargeted(false) }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .copy) }
    func performDrop(info: DropInfo) -> Bool {
        let files = info.hasItemsConforming(to: [.fileURL])
        let accepted = files ? controller.shelf.accept(info.itemProviders(for: [.fileURL])) : controller.clipboard.accept(info.itemProviders(for: [.url, .plainText, .image]))
        controller.finishFileDrop(clipboard: !files)
        return accepted
    }
}

struct FileShelfView: View {
    @Bindable var shelf: FileShelf
    let dropTargeted: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            IslandPaneHeader(title: "Files", symbol: "tray") {
                if shelf.selectedURLs.count > 1 {
                    Text("\(shelf.selectedURLs.count) selected").monospacedDigit().foregroundStyle(.white.opacity(0.45))
                }
                Button { shelf.actions.preview() } label: { Image(systemName: "eye").frame(width: 20, height: 20) }
                    .help("Quick Look · Space").disabled(shelf.files.isEmpty)
                FileShareButton(shelf: shelf).frame(width: 20, height: 20)
                Button("Clear") { shelf.clear() }.disabled(shelf.files.isEmpty)
            }
            if shelf.files.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: "tray.and.arrow.down").font(.system(size: 25, weight: .light))
                    Text(dropTargeted ? "Release to keep files here" : "Drop files here. Drag them out anywhere.").font(.system(size: 12))
                    Text("Switch windows or Spaces while they wait.").font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                }.frame(maxWidth: .infinity, minHeight: 95)
                    .background(.white.opacity(dropTargeted ? 0.1 : 0.035), in: RoundedRectangle(cornerRadius: 15))
            } else {
                FileCollection(shelf: shelf).frame(height: 103)
                Text("⌘-click to select · Space to preview · drag selected files together")
                    .font(.system(size: 9)).foregroundStyle(.white.opacity(0.4))
            }
            if let message = shelf.message { Text(message).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)) }
        }.foregroundStyle(.white)
    }
}
