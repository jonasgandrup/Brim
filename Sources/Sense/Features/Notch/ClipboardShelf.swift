import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ClipboardPin: Identifiable, Equatable {
    enum Payload: Equatable { case text(String), link(URL), image(Data) }
    let id = UUID()
    let payload: Payload
    var title: String {
        switch payload {
        case .text(let text): String(text.prefix(120))
        case .link(let url): url.host ?? url.absoluteString
        case .image: "Image"
        }
    }
    var symbol: String {
        switch payload { case .text: "text.alignleft"; case .link: "link"; case .image: "photo" }
    }
    @MainActor func provider() -> NSItemProvider {
        switch payload {
        case .text(let text): return NSItemProvider(object: text as NSString)
        case .link(let url): return NSItemProvider(object: url as NSURL)
        case .image(let data):
            let provider = NSItemProvider()
            provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
                completion(data, nil); return nil
            }
            return provider
        }
    }
}

@MainActor @Observable final class ClipboardShelf {
    private(set) var pins: [ClipboardPin] = []
    var message: String?
    @discardableResult func add(_ payload: ClipboardPin.Payload) -> Bool {
        guard pins.count < 20 else { message = "Remove a pin to make room. The shelf holds 20 items."; return false }
        guard !pins.contains(where: { $0.payload == payload }) else { message = "Already pinned."; return false }
        switch payload {
        case .text(let text): guard !text.isEmpty, text.utf8.count <= 1_000_000 else { message = "Copy a smaller piece of text."; return false }
        case .link(let url): guard ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") else { message = "This link type isn’t supported."; return false }
        case .image(let data): guard data.count <= 20_000_000, NSImage(data: data) != nil else { message = "Choose an image smaller than 20 MB."; return false }
        }
        pins.append(ClipboardPin(payload: payload)); message = nil; return true
    }
    @discardableResult func pin(from board: NSPasteboard = .general) -> Bool {
        if let urls = board.readObjects(forClasses: [NSURL.self]) as? [URL], let url = urls.first(where: { !$0.isFileURL }) { return add(.link(url)) }
        if let image = NSImage(pasteboard: board), let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) { return add(.image(png)) }
        if let text = board.string(forType: .string) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: trimmed), ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") { return add(.link(url)) }
            return add(.text(text))
        }
        message = "Copy text, a link or an image, then choose Pin Clipboard."; return false
    }
    @discardableResult func copy(_ pin: ClipboardPin, to board: NSPasteboard = .general) -> Bool {
        board.clearContents()
        switch pin.payload {
        case .text(let text): return board.setString(text, forType: .string)
        case .link(let url): return board.writeObjects([url as NSURL])
        case .image(let data): return board.setData(data, forType: .png)
        }
    }
    func remove(_ pin: ClipboardPin) { pins.removeAll { $0.id == pin.id } }
    func clear() { pins.removeAll(); message = nil }
    func accept(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers {
            if provider.canLoadObject(ofClass: NSImage.self) {
                accepted = true
                _ = provider.loadObject(ofClass: NSImage.self) { [weak self] object, _ in
                    guard let image = object as? NSImage, let data = image.tiffRepresentation,
                          let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) else { return }
                    Task { @MainActor in self?.add(.image(png)) }
                }
            } else {
                let type = provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) ? UTType.url.identifier : UTType.plainText.identifier
                guard provider.hasItemConformingToTypeIdentifier(type) else { continue }
                accepted = true
                provider.loadItem(forTypeIdentifier: type, options: nil) { [weak self] value, _ in
                    let text: String?
                    if let url = value as? URL { text = url.absoluteString }
                    else if let string = value as? String { text = string }
                    else if let data = value as? Data { text = String(data: data, encoding: .utf8) }
                    else { text = nil }
                    guard let text else { return }
                    Task { @MainActor in
                        if let url = URL(string: text), ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") { self?.add(.link(url)) }
                        else { self?.add(.text(text)) }
                    }
                }
            }
        }
        return accepted
    }
}

struct ClipboardShelfView: View {
    @Bindable var shelf: ClipboardShelf
    let pinClipboard: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            IslandPaneHeader(title: "Clipboard", symbol: "pin") {
                Button("Pin Clipboard", action: pinClipboard)
                Button("Clear") { shelf.clear() }.disabled(shelf.pins.isEmpty)
            }
            if shelf.pins.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.on.clipboard").font(.system(size: 24, weight: .light))
                    Text("Pin text, links and images.").font(.system(size: 12))
                    Text("Only reads the clipboard when you ask.").font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                }.frame(maxWidth: .infinity, minHeight: 95).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 15))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(shelf.pins) { pin in
                            VStack(alignment: .leading, spacing: 6) {
                                if case .image(let data) = pin.payload, let image = NSImage(data: data) {
                                    Image(nsImage: image).resizable().scaledToFit().frame(width: 94, height: 48)
                                } else {
                                    Image(systemName: pin.symbol).font(.system(size: 15)).foregroundStyle(.white.opacity(0.5))
                                    Text(pin.title).font(.system(size: 10)).lineLimit(pin.symbol == "link" ? 1 : 2).truncationMode(.middle).frame(height: 28, alignment: .topLeading)
                                }
                                Button("Copy", systemImage: "doc.on.doc") { shelf.copy(pin) }.font(.system(size: 9)).buttonStyle(.plain)
                            }.padding(9).frame(width: 112, height: 96, alignment: .topLeading)
                                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                                .onDrag { pin.provider() }
                                .contextMenu {
                                    Button("Copy") { shelf.copy(pin) }
                                    Button("Remove Pin") { shelf.remove(pin) }
                                }.help(pin.title)
                        }
                    }
                }
            }
            if let message = shelf.message { Text(message).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).lineLimit(1) }
        }.foregroundStyle(.white)
    }
}
