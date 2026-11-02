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
    private(set) var files: [ShelfFile] = [] { didSet { if files != oldValue { save() } } }
    /// When set, the shelf remembers its files across relaunches as bookmarks (references that follow a
    /// moved or renamed file), never as copies. Clearing it forgets the saved list.
    @ObservationIgnored var persistence: UserDefaults? {
        didSet { if persistence == nil { oldValue?.removeObject(forKey: Self.storageKey) } else { save() } }
    }
    static let storageKey = "fileShelfBookmarks"
    var message: String?
    private(set) var selectedURLs: Set<URL> = []
    var systemUIActive = false
    var compressing = false
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
        message = inserted > 0 ? nil : String(localized: "No new accessible files were added.")
        return inserted
    }
    func remove(_ file: ShelfFile) { files.removeAll { $0.id == file.id }; selectedURLs.remove(file.url) }
    /// Points an existing shelf entry at a renamed file, keeping its place and selection.
    func replace(_ old: URL, with new: URL) {
        let normalized = new.standardizedFileURL
        guard let index = files.firstIndex(where: { $0.url == old.standardizedFileURL }) else { return }
        files[index] = ShelfFile(url: normalized)
        if selectedURLs.remove(old.standardizedFileURL) != nil { selectedURLs.insert(normalized) }
    }
    func clear() { files.removeAll(); selectedURLs.removeAll(); message = nil }
    private func save() {
        guard let persistence else { return }
        let bookmarks = files.compactMap { try? $0.url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) }
        if bookmarks.isEmpty { persistence.removeObject(forKey: Self.storageKey) } else { persistence.set(bookmarks, forKey: Self.storageKey) }
    }
    /// Brings back the files saved by an earlier session that still exist.
    func restore(from defaults: UserDefaults) {
        guard files.isEmpty, let bookmarks = defaults.array(forKey: Self.storageKey) as? [Data] else { return }
        var urls: [URL] = []
        for bookmark in bookmarks {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale) else { continue }
            urls.append(url)
        }
        if !urls.isEmpty { add(urls); message = nil }
        Log.shelf.debug("Restored \(urls.count) of \(bookmarks.count) shelf files")
    }
    /// Collects every dropped provider first, so the shelf reports one result for the whole drop.
    @MainActor private final class DropBatch {
        var urls: [URL] = []
        var remaining: Int
        init(count: Int) { remaining = count }
    }
    func accept(_ providers: [NSItemProvider], then completion: @escaping @MainActor ([URL]) -> Void = { _ in }) -> Bool {
        let compatible = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        let batch = DropBatch(count: compatible.count)
        for provider in compatible {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, _ in
                let url: URL?
                if let value = item as? URL { url = value }
                else if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else if let text = item as? String { url = URL(string: text) }
                else { url = nil }
                Task { @MainActor in
                    if let url, url.isFileURL { batch.urls.append(url) }
                    batch.remaining -= 1
                    if batch.remaining == 0, !batch.urls.isEmpty { _ = self?.add(batch.urls); completion(batch.urls) }
                }
            }
        }
        return !compatible.isEmpty
    }
}

struct ShelfDropDelegate: DropDelegate {
    let controller: NotchController
    /// The island's width, to tell the shelf half from the AirDrop half.
    let width: CGFloat
    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL]) ? controller.shows(.files) : controller.shows(.clipboard) && info.hasItemsConforming(to: [.url, .plainText, .image])
    }
    func dropEntered(info: DropInfo) {
        controller.setDropTargeted(true, clipboard: !info.hasItemsConforming(to: [.fileURL]))
        controller.updateDropZone(x: info.location.x, width: width)
    }
    func dropExited(info: DropInfo) { controller.setDropTargeted(false) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        controller.updateDropZone(x: info.location.x, width: width)
        return DropProposal(operation: .copy)
    }
    func performDrop(info: DropInfo) -> Bool {
        let files = info.hasItemsConforming(to: [.fileURL])
        if files, controller.dropZone == .airDrop {
            let accepted = controller.airDrop(info.itemProviders(for: [.fileURL]))
            controller.finishFileDrop()
            return accepted
        }
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
            if !shelf.files.isEmpty { IslandPaneHeader {
                if shelf.selectedURLs.count > 1 {
                    Text("\(shelf.selectedURLs.count)").monospacedDigit().foregroundStyle(.tertiary)
                }
                Menu {
                    Button("AirDrop…", systemImage: "dot.radiowaves.up.forward") { shelf.actions.airDrop() }
                        .disabled(!shelf.actions.canAirDrop)
                    Button("Compress…", systemImage: "doc.zipper") { shelf.actions.chooseArchiveDestination() }
                    Button("Copy Files", systemImage: "doc.on.doc") { shelf.actions.copy() }
                    Button("Copy Path", systemImage: "link") { shelf.actions.copyPaths() }
                    Button("Reveal in Finder", systemImage: "folder") { shelf.actions.reveal() }
                    Button("Copy to Folder…", systemImage: "folder.badge.plus") { shelf.actions.copyToFolder() }
                    Button("Rename…", systemImage: "pencil") { shelf.actions.rename() }
                    Menu("Image Tools", systemImage: "photo") {
                        Button("Convert to PNG") { shelf.actions.convertImages(to: .png) }
                        Button("Convert to JPEG") { shelf.actions.convertImages(to: .jpeg) }
                        Button("Convert to HEIC") { shelf.actions.convertImages(to: .heic) }
                        Divider()
                        Menu("Resize") {
                            ForEach(ShelfImageTools.resizeOptions, id: \.self) { side in
                                Button("Longest Side \(side) px") { shelf.actions.resizeImages(longestSide: side) }
                            }
                            Button("Half Size") { shelf.actions.resizeImages(scale: 0.5) }
                        }
                        Divider()
                        Button("Remove Metadata") { shelf.actions.stripImageMetadata() }
                    }.disabled(!shelf.actions.selectionHasImages)
                } label: {
                    Image(systemName: shelf.compressing ? "hourglass" : "ellipsis.circle").frame(width: 20, height: 20)
                }.menuStyle(.borderlessButton).fixedSize()
                    .disabled(shelf.availableSelection.isEmpty || shelf.compressing)
                    .help("Actions for selected files").accessibilityLabel("File actions")
                Button { shelf.actions.preview() } label: { Image(systemName: "eye").frame(width: 20, height: 20) }
                    .help("Quick Look · Space").disabled(shelf.files.isEmpty)
                FileShareButton(shelf: shelf).frame(width: 20, height: 20)
                Button("Clear") { shelf.clear() }.disabled(shelf.compressing)
            } }
            if shelf.files.isEmpty {
                IslandEmptyState(symbol: dropTargeted ? "tray.and.arrow.down.fill" : "tray.and.arrow.down",
                                 title: dropTargeted ? "Release to Keep Files Here" : "Drop Files Here",
                                 detail: "Drag them out anywhere. They wait while you switch windows or Spaces.", minHeight: 140)
                    .background(.white.opacity(dropTargeted ? 0.12 : 0.04), in: RoundedRectangle(cornerRadius: IslandStyle.largeRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: IslandStyle.largeRadius, style: .continuous)
                        .strokeBorder(dropTargeted ? Color.accentColor : .white.opacity(0.1), style: StrokeStyle(lineWidth: 1, dash: dropTargeted ? [] : [4, 3])))
                    .animation(IslandStyle.quick, value: dropTargeted)
            } else {
                FileCollection(shelf: shelf).frame(height: 103)
            }
            if let message = shelf.message { Text(message).font(.system(size: 10)).foregroundStyle(.secondary) }
        }.foregroundStyle(.white)
    }
}
