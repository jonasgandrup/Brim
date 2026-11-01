import Testing
import Foundation
import AppKit
@testable import Brim

// MARK: Calendar

@Test @MainActor func calendarAnnouncesEveryOccurrenceOfARepeatingEventOnce() {
    let peek = CalendarPeek()
    var announced: [Date] = []
    peek.onSoon = { announced.append($0.start) }
    let today = Date(timeIntervalSince1970: 2_000_000)
    let tomorrow = today.addingTimeInterval(86_400)
    // Repeating events share one identifier across occurrences.
    let first = NextEvent(id: "standup", title: "Standup", start: today, end: today + 900)
    let second = NextEvent(id: "standup", title: "Standup", start: tomorrow, end: tomorrow + 900)
    peek.announceIfSoon(first, at: today - 240)
    peek.announceIfSoon(first, at: today - 120)
    peek.announceIfSoon(second, at: tomorrow - 240)
    #expect(announced == [today, tomorrow])
    #expect(first.occurrenceKey != second.occurrenceKey)
}

@Test func meetingLinksComeOnlyFromKnownCallHosts() throws {
    let zoom = try #require(URL(string: "https://acme.zoom.us/j/123456"))
    #expect(MeetingLink.find(url: zoom, location: nil, notes: nil) == zoom)
    let notes = "Agenda: https://example.com/doc\nJoin: https://meet.google.com/abc-defg-hij"
    #expect(MeetingLink.find(url: nil, location: nil, notes: notes)?.host == "meet.google.com")
    #expect(MeetingLink.find(url: URL(string: "https://example.com"), location: "Room 4", notes: "See https://example.com/doc") == nil)
    #expect(MeetingLink.isMeeting(try #require(URL(string: "https://teams.microsoft.com/l/meetup-join/x"))))
    #expect(!MeetingLink.isMeeting(try #require(URL(string: "https://notzoom.us.example.com"))))
}

// MARK: Timer and focus

@Test func focusCycleTakesALongBreakAfterEveryFourthSession() {
    var cycle = FocusCycle()
    var phases: [FocusCycle.Phase] = []
    for _ in 0..<8 { cycle.advance(); phases.append(cycle.phase) }
    #expect(phases == [.shortBreak, .focus, .shortBreak, .focus, .shortBreak, .focus, .longBreak, .focus])
    #expect(cycle.session == 1)
    #expect(cycle.minutes == 25)
}

@Test @MainActor func timerDescribesTheDurationThatIsActuallyRunning() {
    let timer = IslandTimer()
    timer.minutes = 5
    timer.start(seconds: 240)
    #expect(timer.subtitle == "4-minute timer")
    #expect(IslandTimer.label(3_725) == "1:02:05")
    #expect(IslandTimer.label(65) == "1:05")
    timer.cancel()
    #expect(timer.subtitle == "5-minute timer")
}

@Test @MainActor func runningTimerSurvivesARelaunchButAFinishedOneDoesNot() throws {
    let suite = "BrimTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let timer = IslandTimer(defaults: defaults)
    timer.startFocus()
    timer.suspend()
    let restored = IslandTimer(defaults: defaults)
    #expect(restored.state.phase == .running)
    #expect(restored.focus?.phase == .focus)
    #expect(restored.remaining > 24 * 60)
    restored.cancel()
    #expect(IslandTimer(defaults: defaults).state.phase == .idle)
}

// MARK: Power

@Test func lowBatteryWarnsOncePerDischarge() {
    var tracker = PowerFeedbackTracker()
    func sample(_ percent: Int, plugged: Bool = false) -> PowerFeedback? {
        tracker.receive(PowerSample(percent: percent, externalPower: plugged), target: 80, low: 20)
    }
    #expect(sample(40) == nil)
    #expect(sample(21) == nil)
    #expect(sample(20) == .low(20))
    #expect(sample(19) == nil)
    #expect(sample(21) == nil)  // hovering around the threshold doesn't repeat it
    #expect(sample(20) == nil)
    #expect(sample(20, plugged: true) == .connected(20))
    #expect(sample(18) == .low(18))
}

@Test func launchingBelowTheThresholdIsNotAWarning() {
    var tracker = PowerFeedbackTracker()
    #expect(tracker.receive(PowerSample(percent: 12, externalPower: false), target: 80, low: 20) == nil)
    #expect(tracker.receive(PowerSample(percent: 11, externalPower: false), target: 80, low: 20) == nil)
    #expect(tracker.receive(PowerSample(percent: 10, externalPower: false), target: 80, low: 0) == nil)
}

// MARK: System HUD

@Test func brightnessGateShowsKeyPressesButAbsorbsAutoBrightness() {
    var gate = BrightnessChangeGate(baseline: 0.5)
    // Auto-Brightness: small steps seconds apart.
    #expect(gate.receive(0.51, at: 10) == nil)
    #expect(gate.receive(0.52, at: 13) == nil)
    #expect(gate.receive(0.53, at: 16) == nil)
    // A brightness key: a quick animated burst of small steps.
    #expect(gate.receive(0.545, at: 20) == nil)
    #expect(gate.receive(0.56, at: 20.03) == nil)
    #expect(gate.receive(0.58, at: 20.06) == 0.58)
    // While shown, every step follows.
    #expect(gate.receive(0.59, at: 20.09) == 0.59)
}

// MARK: Bluetooth

@Test func bluetoothReportKeepsConnectedDevicesWithBatteryLevels() throws {
    let json = """
    {"SPBluetoothDataType":[{"device_connected":[
      {"Jonas AirPods Pro":{"device_address":"AA:BB","device_minorType":"Headphones","device_batteryLevelLeft":"80%","device_batteryLevelRight":"64%","device_batteryLevelCase":"100%"}},
      {"Magic Keyboard":{"device_address":"CC:DD","device_minorType":"Keyboard","device_batteryLevelMain":"55%"}},
      {"Speaker":{"device_address":"EE:FF","device_minorType":"Speaker"}}],
      "device_not_connected":[{"Old Mouse":{"device_address":"11:22","device_batteryLevelMain":"10%"}}]}]}
    """
    let devices = BluetoothReport.parse(try #require(json.data(using: .utf8)))
    #expect(devices.map(\.name) == ["Jonas AirPods Pro", "Magic Keyboard"])
    #expect(devices[0].level == 64)
    #expect(devices[0].symbol == "airpods.pro")
    #expect(devices[1].level == 55)
    #expect(devices[1].symbol == "keyboard")
    #expect(BluetoothReport.percent("101%") == nil)
}

@Test @MainActor func accessoryConnectionsAreAnnouncedAfterTheFirstReading() {
    let batteries = BluetoothBatteries()
    var connected: [String] = []
    batteries.onConnected = { connected.append($0.name) }
    let keyboard = BluetoothDevice(id: "1", name: "Keyboard", kind: "Keyboard", main: 50)
    let airpods = BluetoothDevice(id: "2", name: "AirPods", kind: "Headphones", left: 90, right: 88)
    batteries.apply([keyboard])
    batteries.apply([keyboard, airpods])
    batteries.apply([keyboard, airpods])
    #expect(connected == ["AirPods"])
}

// MARK: URL commands

@Test func linksParseIntoCommands() throws {
    func command(_ text: String) -> BrimCommand? { URL(string: text).flatMap(BrimCommand.init(url:)) }
    #expect(command("brim://open?tool=battery") == .open(.battery))
    #expect(command("brim://open") == .open(nil))
    #expect(command("brim://timer/start?minutes=2.5") == .startTimer(minutes: 2.5))
    #expect(command("brim://timer/start") == .startTimer(minutes: 5))
    #expect(command("brim://timer/start?minutes=-1") == nil)
    #expect(command("brim://focus/start") == .startFocus)
    #expect(command("brim://presentation?enabled=off") == .presentation(false))
    #expect(command("brim://presentation") == .presentation(nil))
    #expect(command("brim://message?text=Build%20done&symbol=hammer.fill") == .message("Build done", symbol: "hammer.fill"))
    #expect(command("brim://message?text=Hi&symbol=../../etc") == .message("Hi", symbol: "bell.fill"))
    let long = String(repeating: "a", count: 200)
    #expect(command("brim://message?text=\(long)") == .message(String(repeating: "a", count: BrimCommand.maxMessageLength), symbol: "bell.fill"))
    #expect(command("brim://shelf/add?path=/tmp/a.txt") == .addToShelf(URL(fileURLWithPath: "/tmp/a.txt")))
    #expect(command("brim://unknown") == nil)
    #expect(command("https://open") == nil)
}

// MARK: Displays

@Test func activeDisplayPicksTheScreenTheWindowMostlyCovers() {
    // AppKit frames: a 1512×982 laptop below a 2560×1440 display whose top edge is higher.
    let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let external = CGRect(x: -500, y: 982, width: 2560, height: 1440)
    // Quartz window bounds use a top-left origin measured from the primary (laptop) display.
    let onLaptop = CGRect(x: 100, y: 200, width: 800, height: 600)
    let onExternal = CGRect(x: 0, y: -1000, width: 1200, height: 800)
    #expect(ActiveDisplay.frame(for: onLaptop, in: [laptop, external]) == laptop)
    #expect(ActiveDisplay.frame(for: onExternal, in: [laptop, external]) == external)
    #expect(ActiveDisplay.frame(for: CGRect(x: 9000, y: 9000, width: 100, height: 100), in: [laptop, external]) == nil)
}

// MARK: Shelf

@Test func resizingNeverEnlargesAndKeepsTheAspectRatio() {
    #expect(ShelfImageTools.targetSize(width: 4000, height: 3000, longestSide: 1280)! == (1280, 960))
    #expect(ShelfImageTools.targetSize(width: 800, height: 600, longestSide: 1280) == nil)
    #expect(ShelfImageTools.targetSize(width: 801, height: 601, scale: 0.5)! == (401, 301))
}

@Test @MainActor func shelfFilesComeBackAfterRelaunchAsReferences() throws {
    let suite = "BrimTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BrimShelf-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("note.txt")
    try Data("hello".utf8).write(to: file)
    let shelf = FileShelf()
    shelf.persistence = defaults
    shelf.add([file])
    let restored = FileShelf()
    restored.restore(from: defaults)
    #expect(restored.files.map { $0.url.resolvingSymlinksInPath() } == [file.resolvingSymlinksInPath()])
    shelf.persistence = nil
    #expect(defaults.object(forKey: FileShelf.storageKey) == nil)
}

@Test @MainActor func copyPathPutsOnePathPerLineOnThePasteboard() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BrimPaths-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let urls = ["a.txt", "b.txt"].map { directory.appendingPathComponent($0) }
    try urls.forEach { try Data().write(to: $0) }
    let shelf = FileShelf()
    shelf.add(urls); shelf.select(Set(urls.map(\.standardizedFileURL)))
    let board = NSPasteboard(name: NSPasteboard.Name("BrimTests.\(UUID().uuidString)"))
    #expect(shelf.actions.copyPaths(to: board))
    #expect(board.string(forType: .string) == urls.map(\.standardizedFileURL.path).joined(separator: "\n"))
}

// MARK: Processes and media

@Test func processRunnerCollectsOutputAndEnforcesTimeouts() async {
    let echo = await ProcessRunner.run("/bin/echo", arguments: ["hello"], timeout: 5)
    #expect(echo.succeeded && echo.text == "hello")
    let large = await ProcessRunner.run("/bin/sh", arguments: ["-c", "head -c 300000 /dev/zero | tr '\\\\0' 'x'"], timeout: 5)
    #expect(large.output.count == 300_000)
    let slow = await ProcessRunner.run("/bin/sleep", arguments: ["5"], timeout: 0.3)
    #expect(slow.timedOut && !slow.succeeded)
    let missing = await ProcessRunner.run("/nonexistent/tool", arguments: [], timeout: 1)
    #expect(!missing.succeeded)
}

@Test func helperAndOneShotReadsAgreeOnWhatTheIslandShows() {
    let base = SystemMediaSnapshot(available: true, title: "Song", artist: "A", source: "app", sourceName: "App",
                                   rate: 1, duration: 200, position: 10, artwork: nil, identifier: "id")
    var drifted = base; drifted.position = 11.4
    var paused = base; paused.rate = 0
    var otherTrack = base; otherTrack.identifier = "other"
    #expect(SystemMediaBridge.agrees(base, drifted))
    #expect(!SystemMediaBridge.agrees(base, paused))
    #expect(!SystemMediaBridge.agrees(base, otherTrack))
}


@Test func linksWorkUnderBothNames() {
    #expect(BrimCommand(url: URL(string: "brim://settings")!) == .settings)
    #expect(BrimCommand(url: URL(string: "sense://settings")!) == .settings)
    #expect(BrimCommand(url: URL(string: "other://settings")!) == nil)
}
