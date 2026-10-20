import AppKit
import UniformTypeIdentifiers

extension FileShelfActions: NSSharingServiceDelegate {
    var canAirDrop: Bool {
        guard let urls = shelf?.availableSelection, !urls.isEmpty,
              let service = NSSharingService(named: .sendViaAirDrop) else { return false }
        return service.canPerform(withItems: urls)
    }
    func airDrop() {
        guard let shelf, !shelf.compressing, airDropService == nil else { return }
        let urls = shelf.availableSelection
        guard !urls.isEmpty, let service = NSSharingService(named: .sendViaAirDrop),
              service.canPerform(withItems: urls) else { shelf.message = "AirDrop isn’t available for these files."; return }
        closePreview()
        airDropService = service; service.delegate = self; shelf.systemUIActive = true
        NSApp.activate(); service.perform(withItems: urls)
    }
    nonisolated func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        let identity = ObjectIdentifier(sharingService)
        MainActor.assumeIsolated { finishAirDrop(identity: identity, message: nil) }
    }
    nonisolated func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: any Error) {
        let identity = ObjectIdentifier(sharingService)
        let message = error.localizedDescription
        MainActor.assumeIsolated { finishAirDrop(identity: identity, message: message) }
    }
    private func finishAirDrop(identity: ObjectIdentifier, message: String?) {
        guard let service = airDropService, ObjectIdentifier(service) == identity else { return }
        service.delegate = nil; airDropService = nil; shelf?.systemUIActive = false; shelf?.message = message
    }
    @discardableResult func copy(to pasteboard: NSPasteboard = .general) -> Bool {
        guard let shelf else { return false }
        let urls = shelf.availableSelection
        guard !urls.isEmpty else { shelf.message = "Select accessible files to copy."; return false }
        pasteboard.clearContents()
        let copied = pasteboard.writeObjects(urls.map { $0 as NSURL })
        shelf.message = copied ? "Copied \(urls.count) \(urls.count == 1 ? "file" : "files")" : "Files couldn’t be copied."
        return copied
    }
    func chooseArchiveDestination() {
        guard let shelf, !shelf.compressing, !shelf.availableSelection.isEmpty, savePanel == nil else { return }
        closePreview()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]; panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Archive.zip"; panel.title = "Compress Selected Files"
        savePanel = panel; shelf.systemUIActive = true
        NSApp.activate()
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.savePanel = nil
                guard response == .OK, let url = panel.url else { self.shelf?.systemUIActive = false; return }
                Task { await self.compress(to: url) }
            }
        }
    }
    func compress(to destination: URL) async {
        guard let shelf, !shelf.compressing else { return }
        let urls = shelf.availableSelection
        guard !urls.isEmpty else { shelf.systemUIActive = false; return }
        shelf.compressing = true; shelf.systemUIActive = true; shelf.message = "Compressing \(urls.count) \(urls.count == 1 ? "file" : "files")…"
        defer { shelf.compressing = false; shelf.systemUIActive = false }
        do {
            try await ShelfArchive.create(urls: urls, destination: destination)
            shelf.add([destination]); shelf.select([destination.standardizedFileURL])
            shelf.message = "Created \(destination.lastPathComponent)"
        } catch { shelf.message = "Couldn’t compress files: \(error.localizedDescription)" }
    }
}

/// Work on links or copies in a private temporary directory. Originals and their names remain untouched.
enum ShelfArchive {
    enum Failure: LocalizedError {
        case invalidDestination, creationFailed
        var errorDescription: String? {
            switch self {
            case .invalidDestination: "Choose a ZIP destination that doesn’t overwrite a selected file."
            case .creationFailed: "The archive couldn’t be created. Check file access and available disk space."
            }
        }
    }
    static func create(urls: [URL], destination: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            let manager = FileManager.default
            let output = destination.standardizedFileURL
            guard output.isFileURL, !urls.isEmpty,
                  !urls.contains(where: { $0.resolvingSymlinksInPath() == output.resolvingSymlinksInPath() }) else { throw Failure.invalidDestination }
            let staging = manager.temporaryDirectory.appendingPathComponent("SenseArchive-\(UUID())", isDirectory: true)
            let temporaryZip = output.deletingLastPathComponent().appendingPathComponent(".SenseArchive-\(UUID()).zip")
            try manager.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? manager.removeItem(at: staging); try? manager.removeItem(at: temporaryZip) }
            var names: Set<String> = []
            for source in urls {
                var name = source.lastPathComponent
                var suffix = 2
                while names.contains(name.lowercased()) {
                    let stem = source.deletingPathExtension().lastPathComponent
                    let ext = source.pathExtension.isEmpty ? "" : "." + source.pathExtension
                    name = "\(stem) (\(suffix))\(ext)"; suffix += 1
                }
                names.insert(name.lowercased())
                let target = staging.appendingPathComponent(name)
                // Hard links avoid duplicating large files on the same volume; fall back to a real copy.
                if (try? manager.linkItem(at: source, to: target)) == nil { try manager.copyItem(at: source, to: target) }
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--sequesterRsrc", staging.path, temporaryZip.path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw Failure.creationFailed }
            if manager.fileExists(atPath: output.path) { _ = try manager.replaceItemAt(output, withItemAt: temporaryZip) }
            else { try manager.moveItem(at: temporaryZip, to: output) }
        }.value
    }
}

/// Image tools write new files beside the originals and never modify the source.
enum ShelfImageTools {
    enum Failure: LocalizedError {
        case unreadable, unsupported, writeFailed
        var errorDescription: String? {
            switch self {
            case .unreadable: "That file isn’t an image Sense can read."
            case .unsupported: "This Mac can’t write that format."
            case .writeFailed: "The new file couldn’t be saved. Check that the folder is writable."
            }
        }
    }
    static func isImage(_ url: URL) -> Bool {
        (UTType(filenameExtension: url.pathExtension)?.conforms(to: .image)) ?? false
    }
    static func uniqueURL(for source: URL, suffix: String, ext: String) -> URL {
        let directory = source.deletingLastPathComponent()
        let stem = source.deletingPathExtension().lastPathComponent
        let dotted = ext.isEmpty ? "" : "." + ext
        var candidate = directory.appendingPathComponent("\(stem)\(suffix)\(dotted)")
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(stem)\(suffix) \(number)\(dotted)"); number += 1
        }
        return candidate
    }
    /// Re-encodes the pixels with orientation applied and every metadata block (EXIF, GPS, TIFF) left out.
    private static func cleanImage(from source: CGImageSource) -> CGImage? {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let height = (properties?[kCGImagePropertyPixelHeight] as? Int) ?? 0
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: max(width, height, 1)]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
    private static func write(_ image: CGImage, as type: UTType, to destination: URL, quality: Double?) throws {
        guard let target = CGImageDestinationCreateWithURL(destination as CFURL, type.identifier as CFString, 1, nil) else { throw Failure.unsupported }
        var options: [CFString: Any] = [:]
        if let quality { options[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(target, image, options as CFDictionary)
        guard CGImageDestinationFinalize(target) else { throw Failure.writeFailed }
    }
    static func convert(_ url: URL, to type: UTType) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = cleanImageKeepingMetadata(source) else { throw Failure.unreadable }
        let output = uniqueURL(for: url, suffix: "", ext: type.preferredFilenameExtension ?? "img")
        try write(image, as: type, to: output, quality: type == .png ? nil : 0.9)
        return output
    }
    /// Conversion keeps the image's own look (orientation baked in) without carrying metadata blocks along.
    private static func cleanImageKeepingMetadata(_ source: CGImageSource) -> CGImage? { cleanImage(from: source) }
    static func stripMetadata(_ url: URL) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = cleanImage(from: source),
              let identifier = CGImageSourceGetType(source), let type = UTType(identifier as String) else { throw Failure.unreadable }
        let output = uniqueURL(for: url, suffix: " (no metadata)", ext: url.pathExtension.isEmpty ? (type.preferredFilenameExtension ?? "img") : url.pathExtension)
        try write(image, as: type, to: output, quality: type == .png ? nil : 0.95)
        return output
    }
}

extension FileShelfActions {
    var selectionHasImages: Bool { shelf?.availableSelection.contains(where: ShelfImageTools.isImage) ?? false }

    func convertImages(to type: UTType) { runImageJob("Converting") { try ShelfImageTools.convert($0, to: type) } }
    func stripImageMetadata() { runImageJob("Removing metadata from") { try ShelfImageTools.stripMetadata($0) } }

    private func runImageJob(_ verb: String, _ work: @escaping @Sendable (URL) throws -> URL) {
        guard let shelf, !shelf.compressing else { return }
        let urls = shelf.availableSelection.filter(ShelfImageTools.isImage)
        guard !urls.isEmpty else { shelf.message = "Select an image first."; return }
        shelf.compressing = true
        shelf.message = "\(verb) \(urls.count) \(urls.count == 1 ? "image" : "images")…"
        Task {
            let results = await Task.detached(priority: .userInitiated) { urls.map { url in Result { try work(url) } } }.value
            shelf.compressing = false
            let created = results.compactMap { try? $0.get() }
            let failure = results.compactMap { result -> String? in if case .failure(let error) = result { error.localizedDescription } else { nil } }.first
            shelf.add(created)
            if !created.isEmpty { shelf.select(Set(created.map(\.standardizedFileURL))) }
            shelf.message = created.isEmpty ? (failure ?? "Nothing was created.") : "Created \(created.count) \(created.count == 1 ? "file" : "files")" + (failure.map { " · \($0)" } ?? "")
        }
    }

    func copyToFolder() {
        guard let shelf, !shelf.availableSelection.isEmpty else { return }
        closePreview()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Copy Here"; panel.title = "Copy Selected Files"
        shelf.systemUIActive = true; NSApp.activate()
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, let shelf = self.shelf else { return }
                shelf.systemUIActive = false
                guard response == .OK, let folder = panel.url else { return }
                var copied = 0
                for source in shelf.availableSelection {
                    let target = ShelfImageTools.uniqueURL(for: folder.appendingPathComponent(source.lastPathComponent), suffix: "", ext: source.pathExtension)
                    if (try? FileManager.default.copyItem(at: source, to: target)) != nil { copied += 1 }
                }
                shelf.message = copied > 0 ? "Copied \(copied) \(copied == 1 ? "file" : "files") to \(folder.lastPathComponent)" : "Nothing could be copied there."
            }
        }
    }

    /// Renames the one selected file on disk, then keeps the shelf pointing at it.
    func rename() {
        guard let shelf else { return }
        let urls = shelf.availableSelection
        guard urls.count == 1, let source = urls.first else { shelf.message = "Select one file to rename."; return }
        closePreview()
        let alert = NSAlert()
        alert.messageText = "Rename “\(source.lastPathComponent)”"
        alert.informativeText = "This renames the file on disk."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = source.lastPathComponent
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename"); alert.addButton(withTitle: "Cancel")
        shelf.systemUIActive = true; NSApp.activate()
        defer { shelf.systemUIActive = false }
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), !name.contains(":"), name != source.lastPathComponent else { return }
        let target = source.deletingLastPathComponent().appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: target.path) else { shelf.message = "A file with that name already exists."; return }
        do {
            try FileManager.default.moveItem(at: source, to: target)
            shelf.replace(source, with: target)
            shelf.message = "Renamed to \(name)"
        } catch { shelf.message = "Couldn’t rename: \(error.localizedDescription)" }
    }
}
