import AppKit
import SwiftUI
import QuickLookUI

@MainActor final class FileShelfActions: NSObject, NSWindowDelegate {
    weak var shelf: FileShelf?
    private var previewWindow: NSWindow?
    private var previewView: QLPreviewView?
    private var previewURLs: [URL] = []
    private var previewIndex = 0
    private var keyMonitor: Any?
    var previewItemCount: Int { previewURLs.count }
    var previewVisible: Bool { previewWindow?.isVisible == true }
    func preview() {
        guard let shelf else { return }
        let urls = shelf.availableSelection
        guard !urls.isEmpty else { shelf.message = "Select an accessible file to preview."; return }
        previewURLs = urls; previewIndex = 0
        if previewWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.delegate = self
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 520))
            let preview = QLPreviewView(frame: NSRect(x: 0, y: 35, width: 720, height: 485), style: .normal)!
            preview.autoresizingMask = [.width, .height]; content.addSubview(preview)
            let previous = NSButton(title: "Previous", target: self, action: #selector(previousItem))
            previous.frame = NSRect(x: 12, y: 5, width: 90, height: 25); content.addSubview(previous)
            let next = NSButton(title: "Next", target: self, action: #selector(nextItem))
            next.frame = NSRect(x: 110, y: 5, width: 90, height: 25); content.addSubview(next)
            window.contentView = content; window.center()
            previewWindow = window; previewView = preview
        }
        shelf.systemUIActive = true
        updatePreview()
        NSApp.activate(); previewWindow?.makeKeyAndOrderFront(nil)
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = MainActor.assumeIsolated {
                    guard let self, event.window === self.previewWindow else { return false }
                    switch event.keyCode {
                    case 49, 53: self.closePreview(); return true
                    case 123: self.previousItem(); return true
                    case 124: self.nextItem(); return true
                    default: return false
                    }
                }
                return handled ? nil : event
            }
        }
    }
    private func updatePreview() {
        guard previewURLs.indices.contains(previewIndex) else { return }
        let url = previewURLs[previewIndex]
        previewWindow?.title = "\(url.lastPathComponent) · \(previewIndex + 1) of \(previewURLs.count)"
        previewView?.previewItem = url as NSURL
    }
    @objc private func previousItem() { guard !previewURLs.isEmpty else { return }; previewIndex = (previewIndex + previewURLs.count - 1) % previewURLs.count; updatePreview() }
    @objc private func nextItem() { guard !previewURLs.isEmpty else { return }; previewIndex = (previewIndex + 1) % previewURLs.count; updatePreview() }
    func closePreview() { previewWindow?.close() }
    func windowWillClose(_ notification: Notification) {
        previewView?.previewItem = nil; previewURLs.removeAll(); shelf?.systemUIActive = false
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }; keyMonitor = nil
    }
}

struct FileCollection: NSViewRepresentable {
    let shelf: FileShelf
    func makeCoordinator() -> Coordinator { Coordinator(shelf: shelf) }
    func makeNSView(context: Context) -> NSScrollView {
        let collection = ShelfCollectionView()
        collection.shelf = shelf
        collection.frame = NSRect(x: 0, y: 0, width: 360, height: 103)
        collection.autoresizingMask = [.height]
        collection.isSelectable = true; collection.allowsMultipleSelection = true
        collection.backgroundColors = [.clear]
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 76, height: 94); layout.minimumInteritemSpacing = 10; layout.minimumLineSpacing = 10
        layout.scrollDirection = .horizontal; collection.collectionViewLayout = layout
        collection.register(ShelfCollectionItem.self, forItemWithIdentifier: NSUserInterfaceItemIdentifier("file"))
        collection.dataSource = context.coordinator; collection.delegate = context.coordinator
        collection.setDraggingSourceOperationMask(.copy, forLocal: true)
        collection.setDraggingSourceOperationMask(.copy, forLocal: false)
        let scroll = NSScrollView()
        scroll.scrollerStyle = .overlay
        scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false; scroll.contentView.drawsBackground = false
        scroll.documentView = collection
        context.coordinator.collection = collection
        updateNSView(scroll, context: context)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let collection = scroll.documentView as? ShelfCollectionView else { return }
        let urls = shelf.files.map(\.url)
        if context.coordinator.urls != urls {
            context.coordinator.urls = urls; collection.reloadData()
        }
        let paths = Set(urls.enumerated().compactMap { shelf.selectedURLs.contains($0.element) ? IndexPath(item: $0.offset, section: 0) : nil })
        if collection.selectionIndexPaths != paths { collection.selectionIndexPaths = paths }
    }
    @MainActor final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        let shelf: FileShelf
        var urls: [URL] = []
        weak var collection: NSCollectionView?
        init(shelf: FileShelf) { self.shelf = shelf }
        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { urls.count }
        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: NSUserInterfaceItemIdentifier("file"), for: indexPath) as! ShelfCollectionItem
            item.tile.url = urls[indexPath.item]; return item
        }
        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { updateSelection(collectionView) }
        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { updateSelection(collectionView) }
        private func updateSelection(_ view: NSCollectionView) { shelf.select(Set(view.selectionIndexPaths.compactMap { urls.indices.contains($0.item) ? urls[$0.item] : nil })) }
        func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
            guard urls.indices.contains(indexPath.item), FileManager.default.fileExists(atPath: urls[indexPath.item].path) else { return nil }
            return urls[indexPath.item] as NSURL
        }
    }
}

final class ShelfCollectionView: NSCollectionView {
    weak var shelf: FileShelf?
    override var needsPanelToBecomeKey: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 { shelf?.actions.preview() }
        else { super.keyDown(with: event) }
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeKey(); window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if let path = indexPathForItem(at: point), !selectionIndexPaths.contains(path) {
            selectionIndexPaths = [path]
            if let shelf, shelf.files.indices.contains(path.item) { shelf.select([shelf.files[path.item].url]) }
        }
        let menu = NSMenu()
        for (title, action) in [("Quick Look", #selector(previewFiles)), ("Reveal in Finder", #selector(revealFiles)), ("Remove from Shelf", #selector(removeFiles))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        return menu
    }
    @objc private func previewFiles() { shelf?.actions.preview() }
    @objc private func revealFiles() { if let urls = shelf?.availableSelection { NSWorkspace.shared.activateFileViewerSelecting(urls) } }
    @objc private func removeFiles() { shelf?.removeSelection() }
}

final class ShelfCollectionItem: NSCollectionViewItem {
    let tile = ShelfFileTile()
    override func loadView() { view = tile }
    override var isSelected: Bool { didSet { tile.selected = isSelected } }
}

final class ShelfFileTile: NSView {
    var url: URL? { didSet { toolTip = url?.lastPathComponent; needsDisplay = true } }
    var selected = false { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        (selected ? NSColor.controlAccentColor.withAlphaComponent(0.35) : NSColor.white.withAlphaComponent(0.06)).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 12, yRadius: 12).fill()
        guard let url else { return }
        NSWorkspace.shared.icon(forFile: url.path).draw(in: NSRect(x: (bounds.width - 38) / 2, y: 8, width: 38, height: 38), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center; paragraph.lineBreakMode = .byTruncatingMiddle
        (url.lastPathComponent as NSString).draw(in: NSRect(x: 4, y: 54, width: bounds.width - 8, height: 30), withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.white, .paragraphStyle: paragraph])
    }
}

struct FileShareButton: NSViewRepresentable {
    let shelf: FileShelf
    func makeCoordinator() -> Coordinator { Coordinator(shelf: shelf) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Share selected files")!, target: context.coordinator, action: #selector(Coordinator.share(_:)))
        button.sendAction(on: .leftMouseDown)
        button.identifier = NSUserInterfaceItemIdentifier("Sense.FileShare")
        button.appearance = NSAppearance(named: .darkAqua)
        button.contentTintColor = .white
        button.bezelStyle = .inline; button.isBordered = false; button.toolTip = "Share selected files"
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) { button.isEnabled = !shelf.files.isEmpty }
    static func dismantleNSView(_ button: NSButton, coordinator: Coordinator) {
        coordinator.close()
    }
    @MainActor final class Coordinator: NSObject, NSSharingServicePickerDelegate {
        let shelf: FileShelf
        var picker: NSSharingServicePicker?
        var servicesPrepared = false
        init(shelf: FileShelf) { self.shelf = shelf }
        @objc func share(_ sender: NSButton) {
            let urls = shelf.availableSelection
            guard !urls.isEmpty else { shelf.message = "Select accessible files to share."; return }
            shelf.actions.closePreview()
            close()
            servicesPrepared = false; shelf.systemUIActive = true
            let picker = NSSharingServicePicker(items: urls); self.picker = picker; picker.delegate = self
            picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
        func close() {
            let current = picker; picker = nil
            current?.delegate = nil; current?.close()
            shelf.systemUIActive = false
        }
        nonisolated func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, sharingServicesForItems items: [Any], proposedSharingServices: [NSSharingService]) -> [NSSharingService] {
            MainActor.assumeIsolated { servicesPrepared = true }
            return proposedSharingServices
        }
        nonisolated func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
            MainActor.assumeIsolated { shelf.systemUIActive = false; picker = nil }
        }
    }
}
