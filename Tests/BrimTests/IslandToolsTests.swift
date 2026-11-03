import Foundation
import AppKit
import Testing
import UniformTypeIdentifiers
@testable import Brim

/// Runs scripts/brim against a stand-in for `open`, and reads back the links it would have sent to the app.
private func runBrimCommand(_ arguments: [String]) throws -> (status: Int32, links: [String]) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("brim-cli-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let log = folder.appendingPathComponent("links"), stub = folder.appendingPathComponent("open")
    try "#!/bin/sh\nprintf '%s %s\\n' \"$1\" \"$2\" >> \"\(log.path)\"\n".write(to: stub, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
    let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/brim")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [script.path] + arguments
    process.environment = ["PATH": "\(folder.path):/usr/bin:/bin"]
    process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
    try process.run(); process.waitUntilExit()
    let lines = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    // Always in the background, so the app you're working in keeps the front.
    #expect(lines.allSatisfy { $0.hasPrefix("-g brim://") })
    return (process.terminationStatus, lines.map { String($0.dropFirst(3)) })
}

@Test func brimRunShowsACommandAndKeepsItsExitCode() throws {
    let done = try runBrimCommand(["run", "/usr/bin/true"])
    #expect(done.status == 0 && done.links.count == 2)
    let start = try #require(URL(string: done.links[0])), end = try #require(URL(string: done.links[1]))
    guard case .activity(let id, let title, let symbol, nil)? = BrimCommand(url: start) else { Issue.record("Not an activity: \(start)"); return }
    #expect(title == "true" && symbol == "terminal.fill")
    #expect(BrimCommand(url: end) == .endActivity(id: id, title: "true", finished: true))

    // Spaces, quotes and accents survive the trip through the link.
    let named = try runBrimCommand(["run", "--title", "Sikkerhedskopi \"nat\" & co", "--", "/usr/bin/true"])
    let namedStart = try #require(URL(string: named.links[0]))
    guard case .activity(_, let name, _, _)? = BrimCommand(url: namedStart) else { Issue.record("Not an activity"); return }
    #expect(name == "Sikkerhedskopi \"nat\" & co")

    // A failure keeps its own exit code, ends the activity quietly and says so with a cross.
    let failed = try runBrimCommand(["run", "/bin/sh", "-c", "exit 3"])
    #expect(failed.status == 3 && failed.links.count == 3)
    let cancelled = try #require(URL(string: failed.links[1])), cross = try #require(URL(string: failed.links[2]))
    guard case .endActivity(_, nil, false)? = BrimCommand(url: cancelled) else { Issue.record("Not a quiet end"); return }
    guard case .message(let text, "xmark.circle.fill")? = BrimCommand(url: cross) else { Issue.record("Not a cross"); return }
    #expect(text.hasPrefix("sh"))

    // Stopping it on purpose isn't a failure, so there's no cross.
    let stopped = try runBrimCommand(["run", "/bin/sh", "-c", "exit 130"])
    #expect(stopped.status == 130 && stopped.links.count == 2)

    // Missing commands fail normally, and misuse shows the usage without running anything.
    #expect(try runBrimCommand(["run", "/no/such/command"]).status == 127)
    let misuse = try runBrimCommand(["run"])
    #expect(misuse.status == 2 && misuse.links.isEmpty)
    #expect(try runBrimCommand(["help"]).status == 0)
}

@Test func countdownPreservesRemainingTimeWhilePausedAndFinishesAcrossSleep() {
    let start = Date(timeIntervalSince1970: 1000)
    var timer = CountdownState()
    timer.start(seconds: 300, at: start)
    #expect(timer.remaining(at: start.addingTimeInterval(100)) == 200)
    timer.pause(at: start.addingTimeInterval(100))
    #expect(timer.phase == .paused)
    #expect(timer.remaining(at: start.addingTimeInterval(3600)) == 200)
    timer.resume(at: start.addingTimeInterval(3600))
    #expect(timer.remaining(at: start.addingTimeInterval(3700)) == 100)
    let didFinish = timer.update(at: start.addingTimeInterval(4000))
    #expect(didFinish)
    #expect(timer.phase == .finished)
    #expect(timer.remaining(at: start.addingTimeInterval(4000)) == 0)
    let repeatedFinish = timer.update(at: start.addingTimeInterval(5000))
    #expect(!repeatedFinish)
    timer.cancel()
    #expect(timer.phase == .idle)
    for seconds in [0, -1, Double.infinity, Double.nan, 86401] {
        timer.start(seconds: seconds, at: start)
        #expect(timer.phase == .idle)
    }
}

@Test func pausingExpiredTimerDoesNotResurrectIt() {
    let date = Date()
    var timer = CountdownState()
    timer.start(seconds: 1, at: date)
    timer.pause(at: date.addingTimeInterval(2))
    #expect(timer.phase == .finished)
    timer.resume(at: date.addingTimeInterval(3))
    #expect(timer.phase == .finished)
}

@Test @MainActor func timerTaskFinishesOnceAndCancelStopsCallbacks() async throws {
    let timer = IslandTimer()
    var finishes = 0
    timer.onFinish = { finishes += 1 }
    timer.start(seconds: 0.05)
    for _ in 0..<100 {
        if finishes > 0 { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(finishes == 1)
    #expect(timer.state.phase == .finished)
    #expect(timer.label == "0:00")
    timer.pause(); timer.resume()
    try await Task.sleep(for: .milliseconds(300))
    #expect(finishes == 1)
    timer.start(seconds: 0.05); timer.cancel()
    try await Task.sleep(for: .milliseconds(300))
    #expect(finishes == 1)
    #expect(!timer.active)
}

@Test @MainActor func clipboardRoundTripsOnlyExplicitlyPinnedItems() throws {
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    let shelf = ClipboardShelf()
    #expect(shelf.pins.isEmpty)
    board.setString("A note\nwith two lines", forType: .string)
    #expect(shelf.pins.isEmpty)
    #expect(shelf.pin(from: board))
    #expect(!shelf.pin(from: board))
    let note = try #require(shelf.pins.first)
    board.clearContents()
    #expect(shelf.copy(note, to: board))
    #expect(board.string(forType: .string) == "A note\nwith two lines")
    board.clearContents()
    board.setString("https://example.com/a?q=hello", forType: .string)
    #expect(shelf.pin(from: board))
    let link = try #require(shelf.pins.last)
    #expect(link.payload == .link(URL(string: "https://example.com/a?q=hello")!))
    #expect(shelf.copy(link, to: board))
    #expect((board.readObjects(forClasses: [NSURL.self]) as? [URL])?.first == URL(string: "https://example.com/a?q=hello"))
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 16, bitsPerPixel: 32))
    for x in 0..<4 { for y in 0..<4 { bitmap.setColor(NSColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1), atX: x, y: y) } }
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    board.clearContents(); board.setData(png, forType: .png)
    #expect(shelf.pin(from: board))
    let image = try #require(shelf.pins.last)
    #expect(image.provider().hasItemConformingToTypeIdentifier(UTType.png.identifier))
    #expect(shelf.copy(image, to: board))
    #expect(NSImage(pasteboard: board) != nil)
    shelf.remove(note)
    #expect(shelf.pins.count == 2)
    shelf.clear()
    #expect(shelf.pins.isEmpty)
    #expect(!shelf.add(.link(URL(fileURLWithPath: "/tmp/example"))))
    #expect(!shelf.add(.text("")))
    #expect(!shelf.add(.image(Data([0, 1]))))
    for index in 0..<20 { #expect(shelf.add(.text("Note \(index)"))) }
    #expect(!shelf.add(.text("Overflow")))
}

@Test @MainActor func clipboardAcceptsNativeDropProviders() async throws {
    let shelf = ClipboardShelf()
    #expect(shelf.accept([NSItemProvider(object: "Dropped note" as NSString), NSItemProvider(object: URL(string: "https://example.com")! as NSURL)]))
    for _ in 0..<100 {
        if shelf.pins.count == 2 { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(Set(shelf.pins.map(\.title)) == ["Dropped note", "example.com"])
}

@Test @MainActor func fileShelfMultipleSelectionUsesNativeFileURLsAndKeepsOriginals() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BrimSelection-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let urls = ["one.txt", "two.txt", "three.txt"].map { directory.appendingPathComponent($0).standardizedFileURL }
    for url in urls { try Data(url.lastPathComponent.utf8).write(to: url) }
    let shelf = FileShelf()
    #expect(shelf.add(urls) == 3)
    shelf.select(Set(urls.prefix(2)))
    #expect(shelf.availableSelection == Array(urls.prefix(2)))
    let coordinator = FileCollection.Coordinator(shelf: shelf)
    coordinator.urls = urls
    let collection = ShelfCollectionView()
    let writers = (0..<2).compactMap { coordinator.collectionView(collection, pasteboardWriterForItemAt: IndexPath(item: $0, section: 0)) }
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    #expect(board.writeObjects(writers))
    #expect((board.readObjects(forClasses: [NSURL.self]) as? [URL]) == Array(urls.prefix(2)))
    try FileManager.default.removeItem(at: urls[0])
    #expect(shelf.availableSelection == [urls[1]])
    shelf.removeSelection()
    #expect(shelf.files.map(\.url) == [urls[2]])
    #expect(FileManager.default.fileExists(atPath: urls[1].path))
    shelf.clear()
    #expect(FileManager.default.fileExists(atPath: urls[2].path))
}

@Test func chargingFeedbackIsSilentAtStartupAndAnnouncesOncePerPowerCycle() {
    var tracker = PowerFeedbackTracker()
    #expect(tracker.receive(.init(percent: 70, externalPower: false), target: 80) == nil)
    #expect(tracker.receive(.init(percent: 70, externalPower: true), target: 80) == .connected(70))
    #expect(tracker.receive(.init(percent: 79, externalPower: true), target: 80) == nil)
    #expect(tracker.receive(.init(percent: 80, externalPower: true), target: 80) == .targetReached(80))
    #expect(tracker.receive(.init(percent: 81, externalPower: true), target: 80) == nil)
    #expect(tracker.receive(.init(percent: 79, externalPower: true), target: 80) == nil)
    #expect(tracker.receive(.init(percent: 80, externalPower: true), target: 80) == nil)
    #expect(tracker.receive(.init(percent: 80, externalPower: false), target: 80) == nil)
    #expect(tracker.receive(.init(percent: 80, externalPower: true), target: 80) == .connected(80))
    #expect(tracker.receive(.init(percent: 80, externalPower: true), target: 90) == nil)
    #expect(tracker.receive(.init(percent: nil, externalPower: false), target: 90) == nil)
    #expect(tracker.receive(.init(percent: 90, externalPower: true), target: 90) == .targetReached(90))
    var alreadyCharged = PowerFeedbackTracker()
    #expect(alreadyCharged.receive(.init(percent: 95, externalPower: true), target: 80) == nil)
    #expect(alreadyCharged.receive(.init(percent: 96, externalPower: true), target: 80) == nil)
}

@Test @MainActor func batchCopyUsesOnlySelectedFilesAndPreservesSources() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BrimCopy-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let urls = ["one.txt", "two.txt", "three.txt"].map { directory.appendingPathComponent($0).standardizedFileURL }
    for url in urls { try Data(url.lastPathComponent.utf8).write(to: url) }
    let shelf = FileShelf(); shelf.add(urls); shelf.select(Set(urls.suffix(2)))
    let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
    #expect(shelf.actions.copy(to: board))
    #expect(board.readObjects(forClasses: [NSURL.self]) as? [URL] == Array(urls.suffix(2)))
    for url in urls { #expect(try String(contentsOf: url, encoding: .utf8) == url.lastPathComponent) }
}

@Test @MainActor func compressionIncludesSelectionAndHandlesDuplicateNamesWithoutChangingOriginals() async throws {
    let manager = FileManager.default
    let directory = manager.temporaryDirectory.appendingPathComponent("BrimZipTest-\(UUID())")
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: directory) }
    let first = directory.appendingPathComponent("a/report.txt")
    let second = directory.appendingPathComponent("b/report.txt")
    let omitted = directory.appendingPathComponent("omit.txt")
    for url in [first, second, omitted] {
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(url.path.utf8).write(to: url)
    }
    let shelf = FileShelf(); shelf.add([first, second, omitted]); shelf.select([first, second])
    let zip = directory.appendingPathComponent("Archive.zip")
    await shelf.actions.compress(to: zip)
    #expect(!shelf.compressing); #expect(!shelf.systemUIActive)
    #expect(manager.fileExists(atPath: zip.path))
    #expect(shelf.selectedURLs == [zip.standardizedFileURL])
    let unpack = directory.appendingPathComponent("unpack")
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = ["-x", "-k", zip.path, unpack.path]
    try process.run(); process.waitUntilExit(); #expect(process.terminationStatus == 0)
    #expect(try String(contentsOf: unpack.appendingPathComponent("report.txt"), encoding: .utf8) == first.path)
    #expect(try String(contentsOf: unpack.appendingPathComponent("report (2).txt"), encoding: .utf8) == second.path)
    #expect(!manager.fileExists(atPath: unpack.appendingPathComponent("omit.txt").path))
    for url in [first, second, omitted] { #expect(try String(contentsOf: url, encoding: .utf8) == url.path) }
}

@Test func archiveRejectsOverwritingAnOriginal() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("BrimOriginal-\(UUID()).zip")
    try Data("Original".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    do { try await ShelfArchive.create(urls: [file], destination: file); Issue.record("Overwrote source") }
    catch { #expect(try String(contentsOf: file, encoding: .utf8) == "Original") }
}

@Test func batteryFillIsGreenChargingYellowInLowPowerAndRedAtTwentyPercent() {
    #expect(BatteryTint.color(level: 15, charging: true, lowPower: true) == .green)
    #expect(BatteryTint.color(level: 15, charging: false, lowPower: true) == .yellow)
    #expect(BatteryTint.color(level: 20, charging: false, lowPower: false) == .red)
    #expect(BatteryTint.color(level: 21, charging: false, lowPower: false) == .white)
}
