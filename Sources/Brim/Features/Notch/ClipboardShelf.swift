import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ClipboardPin: Identifiable, Equatable {
    enum Payload: Equatable { case text(String), link(URL), image(Data) }
    let id: UUID
    let payload: Payload
    init(id: UUID = UUID(), payload: Payload) { self.id = id; self.payload = payload }
    var title: String {
        switch payload {
        case .text(let text): String(text.prefix(120))
        case .link(let url): url.host ?? url.absoluteString
        case .image: String(localized: "Image")
        }
    }
    var searchText: String {
        switch payload { case .text(let text): text; case .link(let url): url.absoluteString; case .image: "image" }
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

/// Pinned clips on disk: a small index plus one PNG per image pin, in a folder only Brim uses.
/// Text and links are only written here because you pinned them; clipboard history never is.
struct ClipboardPinStore: Sendable {
    let directory: URL
    static var standard: ClipboardPinStore? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            // Still under the app's old name, so pins saved before the rename stay where they are.
            .map { ClipboardPinStore(directory: $0.appendingPathComponent("Sense/Clipboard Pins", isDirectory: true)) }
    }
    private var index: URL { directory.appendingPathComponent("pins.json") }
    private struct Entry: Codable { let id: UUID; let kind: String; let value: String }

    func save(_ pins: [ClipboardPin]) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var entries: [Entry] = []
        var images: Set<String> = []
        for pin in pins {
            switch pin.payload {
            case .text(let text): entries.append(Entry(id: pin.id, kind: "text", value: text))
            case .link(let url): entries.append(Entry(id: pin.id, kind: "link", value: url.absoluteString))
            case .image(let data):
                let name = pin.id.uuidString + ".png"
                images.insert(name)
                let file = directory.appendingPathComponent(name)
                // Images never change once pinned, so each is written only once.
                if !manager.fileExists(atPath: file.path) { try data.write(to: file, options: .atomic) }
                entries.append(Entry(id: pin.id, kind: "image", value: name))
            }
        }
        try JSONEncoder().encode(entries).write(to: index, options: .atomic)
        for name in (try? manager.contentsOfDirectory(atPath: directory.path)) ?? [] where name.hasSuffix(".png") && !images.contains(name) {
            try? manager.removeItem(at: directory.appendingPathComponent(name))
        }
    }
    func load() -> [ClipboardPin] {
        guard let data = try? Data(contentsOf: index), let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return entries.compactMap { entry in
            switch entry.kind {
            case "text": return ClipboardPin(id: entry.id, payload: .text(entry.value))
            case "link": return URL(string: entry.value).map { ClipboardPin(id: entry.id, payload: .link($0)) }
            case "image":
                // Only a plain file name inside the store; never follow a path out of it.
                guard !entry.value.contains("/"), let image = try? Data(contentsOf: directory.appendingPathComponent(entry.value)) else { return nil }
                return ClipboardPin(id: entry.id, payload: .image(image))
            default: return nil
            }
        }
    }
    func erase() { try? FileManager.default.removeItem(at: directory) }
}

@MainActor @Observable final class ClipboardShelf {
    static let linkSchemes: Set<String> = ["https", "http", "mailto"]
    static func isSupportedLink(_ url: URL) -> Bool { linkSchemes.contains(url.scheme?.lowercased() ?? "") }
    private static let totalImageBytes = 60_000_000
    private(set) var pins: [ClipboardPin] = [] { didSet { if pins != oldValue { try? persistence?.save(pins) } } }
    /// When set, pins survive relaunches in Application Support. History never does.
    @ObservationIgnored var persistence: ClipboardPinStore? {
        didSet {
            if persistence == nil { oldValue?.erase() } else { try? persistence?.save(pins) }
        }
    }
    /// Brings back pins saved by an earlier session, without saving over them first.
    func restore(from store: ClipboardPinStore) {
        guard pins.isEmpty else { return }
        let saved = store.load()
        if !saved.isEmpty { pins = saved }
    }
    /// Optional, in-memory only: text and links copied recently. Never written to disk.
    private(set) var history: [ClipboardPin] = []
    var showingHistory = false
    var historyFilter = ""
    private(set) var historyActive = false
    private var historyTimer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var ignoredChangeCount = -1
    static let defaultBlockedApps: Set<String> = ["com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
        "com.apple.keychainaccess", "com.apple.Passwords", "com.dashlane.dashlanephonefinal", "com.lastpass.LastPass", "org.keepassxc.keepassxc"]
    var filteredHistory: [ClipboardPin] {
        let words = historyFilter.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return history }
        return history.filter { pin in words.allSatisfy { pin.searchText.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil } }
    }
    func startHistory() {
        guard historyTimer == nil else { return }
        historyActive = true; lastChangeCount = NSPasteboard.general.changeCount
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollPasteboard() }
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common); historyTimer = timer
    }
    func stopHistory() {
        historyTimer?.invalidate(); historyTimer = nil; historyActive = false
        history.removeAll(); showingHistory = false; historyFilter = ""
    }
    func clearHistory() { history.removeAll() }
    private func pollPasteboard() {
        let board = NSPasteboard.general
        guard board.changeCount != lastChangeCount else { return }
        lastChangeCount = board.changeCount
        guard board.changeCount != ignoredChangeCount else { return }
        recordCopy(from: board, frontmost: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }
    /// Honors the pasteboard conventions password managers use, and skips known secret-holding apps.
    func recordCopy(from board: NSPasteboard, frontmost: String?, blocked: Set<String> = ClipboardShelf.defaultBlockedApps) {
        if let frontmost, blocked.contains(frontmost) { return }
        let markers = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType", "com.agilebits.onepassword"]
        if board.types?.contains(where: { markers.contains($0.rawValue) }) == true { return }
        guard let text = board.string(forType: .string), !text.isEmpty, text.utf8.count <= 20_000 else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let payload: ClipboardPin.Payload
        if let url = URL(string: trimmed), Self.isSupportedLink(url) { payload = .link(url) } else { payload = .text(text) }
        history.removeAll { $0.payload == payload }
        history.insert(ClipboardPin(payload: payload), at: 0)
        if history.count > 40 { history.removeLast() }
    }
    func pinFromHistory(_ pin: ClipboardPin) { add(pin.payload) }
    var message: String?
    @discardableResult func add(_ payload: ClipboardPin.Payload) -> Bool {
        guard pins.count < 20 else { message = String(localized: "Remove a pin to make room. Clipboard holds 20 pins."); return false }
        guard !pins.contains(where: { $0.payload == payload }) else { message = String(localized: "Already pinned."); return false }
        switch payload {
        case .text(let text): guard !text.isEmpty, text.utf8.count <= 1_000_000 else { message = String(localized: "Copy a smaller piece of text."); return false }
        case .link(let url): guard Self.isSupportedLink(url) else { message = String(localized: "This link type isn’t supported."); return false }
        case .image(let data):
            guard data.count <= 20_000_000, NSImage(data: data) != nil else { message = String(localized: "Choose an image smaller than 20 MB."); return false }
            let held = pins.reduce(0) { total, pin in if case .image(let other) = pin.payload { total + other.count } else { total } }
            guard held + data.count <= Self.totalImageBytes else { message = String(localized: "Remove an image pin to make room."); return false }
        }
        pins.append(ClipboardPin(payload: payload)); message = nil; return true
    }
    @discardableResult func pin(from board: NSPasteboard = .general) -> Bool {
        if let urls = board.readObjects(forClasses: [NSURL.self]) as? [URL], let url = urls.first(where: { !$0.isFileURL }) { return add(.link(url)) }
        if let image = NSImage(pasteboard: board), let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) { return add(.image(png)) }
        if let text = board.string(forType: .string) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: trimmed), Self.isSupportedLink(url) { return add(.link(url)) }
            return add(.text(text))
        }
        message = String(localized: "Copy text, a link or an image, then choose Pin Clipboard."); return false
    }
    private(set) var justCopied: ClipboardPin.ID?
    private var copiedTask: Task<Void, Never>?
    /// A click on a pin shows a moment's checkmark, since nothing else on screen changes.
    func copyConfirming(_ pin: ClipboardPin, to board: NSPasteboard = .general) {
        guard copy(pin, to: board) else { return }
        justCopied = pin.id
        copiedTask?.cancel()
        copiedTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            self?.justCopied = nil
        }
    }
    @discardableResult func copy(_ pin: ClipboardPin, to board: NSPasteboard = .general) -> Bool {
        board.clearContents()
        // Copying from the shelf shouldn't reorder the history it came from.
        defer { if board === NSPasteboard.general { ignoredChangeCount = board.changeCount } }
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
                        if let url = URL(string: text), ClipboardShelf.isSupportedLink(url) { self?.add(.link(url)) }
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
    private var items: [ClipboardPin] { shelf.showingHistory ? shelf.filteredHistory : shelf.pins }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            IslandPaneHeader(title: shelf.showingHistory ? "Recent" : nil, symbol: shelf.showingHistory ? "clock.arrow.circlepath" : nil) {
                if shelf.historyActive {
                    Picker("Clipboard view", selection: $shelf.showingHistory) {
                        Text("Pinned").tag(false); Text("Recent").tag(true)
                    }.pickerStyle(.segmented).labelsHidden().controlSize(.mini).frame(width: 118)
                }
                if !shelf.showingHistory { Button("Pin Clipboard", action: pinClipboard) }
                Button("Clear") { shelf.showingHistory ? shelf.clearHistory() : shelf.clear() }
                    .disabled(shelf.showingHistory ? shelf.history.isEmpty : shelf.pins.isEmpty)
            }
            if shelf.showingHistory {
                TextField("Filter recent copies", text: $shelf.historyFilter).textFieldStyle(.roundedBorder).controlSize(.small)
            }
            if items.isEmpty {
                IslandEmptyState(symbol: shelf.showingHistory ? "clock.arrow.circlepath" : "doc.on.clipboard",
                                 title: shelf.showingHistory ? "Nothing Copied Yet" : "Pin Text, Links and Images",
                                 detail: shelf.showingHistory ? "Recent text and links stay in memory only. Password managers are skipped." : "Brim reads the clipboard only when you ask.",
                                 minHeight: shelf.showingHistory ? 74 : 95)
                    .background(IslandStyle.tileFill, in: RoundedRectangle(cornerRadius: IslandStyle.largeRadius, style: .continuous))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(items) { pin in card(pin) }
                    }
                }
            }
            if let message = shelf.message { Text(message).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
        }.foregroundStyle(.white)
    }
    /// The pin itself is the button, so it needn't say "Copy": a click copies, and a checkmark says it worked.
    private func card(_ pin: ClipboardPin) -> some View {
        let copied = shelf.justCopied == pin.id
        return VStack(alignment: .leading, spacing: 6) {
            if case .image(let data) = pin.payload, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFit().frame(width: 94, height: 54).opacity(copied ? 0.35 : 1)
                    .overlay { if copied { Image(systemName: "checkmark").font(.system(size: 18, weight: .semibold)).foregroundStyle(.green) } }
            } else {
                Image(systemName: copied ? "checkmark" : pin.symbol).font(.system(size: 14, weight: .medium))
                    .foregroundStyle(copied ? Color.green : pin.symbol == "link" ? Color.blue : .white.opacity(0.55))
                    .contentTransition(.symbolEffect(.replace))
                Text(pin.title).font(.system(size: 10)).lineLimit(pin.symbol == "link" ? 1 : 2).truncationMode(.middle).frame(height: 28, alignment: .topLeading)
            }
        }.padding(9).frame(width: 112, height: 72, alignment: .topLeading)
            .background(IslandStyle.tileFill, in: RoundedRectangle(cornerRadius: IslandStyle.smallRadius, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if shelf.showingHistory {
                    Button { shelf.pinFromHistory(pin) } label: { Image(systemName: "pin").font(.system(size: 10)).frame(width: 22, height: 22).contentShape(Rectangle()) }
                        .buttonStyle(.plain).padding(3).help("Pin").accessibilityLabel("Pin")
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: IslandStyle.smallRadius, style: .continuous))
            .onTapGesture { shelf.copyConfirming(pin) }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Copy \(pin.title)")
            .onDrag { pin.provider() }
            .contextMenu {
                Button("Copy") { shelf.copyConfirming(pin) }
                if shelf.showingHistory { Button("Pin") { shelf.pinFromHistory(pin) } }
                else { Button("Remove Pin") { shelf.remove(pin) } }
            }.help(pin.title)
    }
}
