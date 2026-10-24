import UniformTypeIdentifiers
import ImageIO
import CoreAudio

import Foundation
import AppKit
import Testing
@testable import Sense

@Test func calibrationRequiresRealPositiveDelta() {
    #expect(ScaleCalibration.factor(knownGrams: 50, pressure: 0.2, baseline: 0.2) == nil)
    #expect(ScaleCalibration.factor(knownGrams: 0, pressure: 0.8, baseline: 0.1) == nil)
    #expect(ScaleCalibration.factor(knownGrams: .infinity, pressure: 0.8, baseline: 0.1) == nil)
    #expect(ScaleCalibration.factor(knownGrams: 50, pressure: .nan, baseline: 0.1) == nil)
    #expect(ScaleCalibration.factor(knownGrams: 501, pressure: 0.8, baseline: 0.1) == nil)
}
@Test func calibratedMassAndTare() throws {
    let factor = try #require(ScaleCalibration.factor(knownGrams: 50, pressure: 0.6, baseline: 0.1))
    #expect(abs(factor - 100) < 0.0001)
    let weight = try #require(ScaleCalibration.weight(pressure: 0.35, baseline: 0.1, factor: factor))
    #expect(abs(weight - 25) < 0.0001)
    #expect(ScaleCalibration.weight(pressure: 0.05, baseline: 0.1, factor: factor) == 0)
    #expect(ScaleCalibration.weight(pressure: 0.6, baseline: 0.1, factor: 0) == nil)
}
@Test func switcherWrapsBothDirections() {
    #expect(SwitcherSelection.next(2, count: 3, backwards: false) == 0)
    #expect(SwitcherSelection.next(0, count: 3, backwards: true) == 2)
    #expect(SwitcherSelection.next(0, count: 0, backwards: false) == 0)
    #expect(SwitcherSelection.next(0, count: 1, backwards: true) == 0)
}
@Test @MainActor func preferencesPersistAndHaveConservativeDefaults() throws {
    let suite = "SenseTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = Preferences(defaults: defaults)
    #expect(!preferences.switcherEnabled)
    #expect(!preferences.mediaEnabled)
    preferences.notchEnabled = false; preferences.shortcut = .option
    let restored = Preferences(defaults: defaults)
    #expect(!restored.notchEnabled)
    #expect(restored.shortcut == .option)
    // Keys are the property names, so values written by earlier versions still load.
    #expect(defaults.string(forKey: "shortcut") == "option")
    #expect(defaults.object(forKey: "notchEnabled") as? Bool == false)
}
@Test @MainActor func preferencesClampOnWriteAndIgnoreUnknownValues() throws {
    let suite = "SenseTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("sepia", forKey: "appearance")
    let preferences = Preferences(defaults: defaults)
    #expect(preferences.appearance == .system)
    preferences.chargeTarget = 140
    #expect(preferences.chargeTarget == 100)
    #expect(defaults.integer(forKey: "chargeTarget") == 100)
    preferences.lowBatteryAlert = 2
    #expect(preferences.lowBatteryAlert == 5)
    preferences.lowBatteryAlert = 0
    #expect(preferences.lowBatteryAlert == 0)
    #expect(Preferences(defaults: defaults).lowBatteryAlert == 0)
}
@Test func islandKeepsCameraClearAndAnchorsExpansionToTopCenter() {
    let layout = IslandLayout(cutoutWidth: 190, menuBarHeight: 32, hasHardwareNotch: true)
    let display = CGRect(x: -1512, y: 200, width: 1512, height: 982)
    let compact = layout.frame(on: display, expanded: false)
    let expanded = layout.frame(on: display, expanded: true)
    #expect(compact.width > layout.cutoutWidth)
    #expect(compact.height == layout.menuBarHeight)
    #expect(compact.midX == display.midX)
    #expect(compact.maxY == display.maxY)
    #expect(expanded.midX == compact.midX)
    #expect(expanded.maxY == compact.maxY)
    #expect(expanded.minY < compact.minY)
}

@Test func islandOnUnnotchedDisplayUsesFloatingPill() {
    let layout = IslandLayout(cutoutWidth: 190, menuBarHeight: 28, hasHardwareNotch: false)
    let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let frame = layout.frame(on: display, expanded: false)
    #expect(frame.width == 196)
    #expect(frame.height == 38)
    #expect(frame.maxY == display.maxY - 8)
    #expect(frame.midX == display.midX)
}

@Test func idleIslandDoesNotShowPlaceholderActivity() {
    #expect(IslandPresentation.resolve(expanded: false, mediaEnabled: false, playing: false, hasSource: false, hasFeedback: false) == .hidden)
    #expect(IslandPresentation.resolve(expanded: false, mediaEnabled: true, playing: false, hasSource: true, hasFeedback: false) == .hidden)
    #expect(IslandPresentation.resolve(expanded: false, mediaEnabled: true, playing: true, hasSource: false, hasFeedback: false) == .hidden)
    #expect(IslandPresentation.resolve(expanded: false, mediaEnabled: false, playing: true, hasSource: true, hasFeedback: false) == .hidden)
}

@Test func islandAppearsOnlyForPlaybackFeedbackOrAnExplicitOpen() {
    #expect(IslandPresentation.resolve(expanded: false, mediaEnabled: true, playing: true, hasSource: true, hasFeedback: false) == .compact)
    #expect(IslandPresentation.resolve(expanded: false, mediaEnabled: false, playing: false, hasSource: false, hasFeedback: true) == .compact)
    #expect(IslandPresentation.resolve(expanded: true, mediaEnabled: false, playing: false, hasSource: false, hasFeedback: false) == .expanded)
}

@Test func hingeReportAndPhysicalClosingProgress() {
    #expect(HingeMotion.decode([1, 99, 0]) == 99)
    #expect(HingeMotion.decode([1, 181, 0]) == nil)
    #expect(HingeMotion.decode([2, 99, 0]) == nil)
    #expect(HingeMotion.decode([1, 99]) == nil)
    #expect(HingeMotion.progress(angle: 99, reference: 99) == 0)
    #expect(HingeMotion.progress(angle: 95, reference: 99) == 0)
    #expect(HingeMotion.progress(angle: 60, reference: 99) > 0)
    #expect(HingeMotion.progress(angle: 10, reference: 99) == 1)
    #expect(HingeMotion.progress(angle: 130, reference: 99) == 0)
    #expect(HingeMotion.progress(angle: .nan, reference: 99) == 0)
}

@Test @MainActor func shelfAcceptsNativeFileProvidersWithoutMovingSourceFiles() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SenseShelfTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("sample.txt")
    try Data("File shelf test".utf8).write(to: source)
    let shelf = FileShelf()
    #expect(shelf.accept([NSItemProvider(object: source as NSURL)]))
    for _ in 0..<100 {
        if !shelf.files.isEmpty { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    let file = try #require(shelf.files.first)
    #expect(file.url == source.standardizedFileURL)
    #expect(shelf.add([source, directory.appendingPathComponent("missing.txt")]) == 0)
    #expect(shelf.files.count == 1)
    shelf.remove(file)
    #expect(shelf.files.isEmpty)
    #expect(try String(contentsOf: source, encoding: .utf8) == "File shelf test")
    #expect(shelf.add([source]) == 1)
    shelf.clear()
    #expect(shelf.files.isEmpty)
    #expect(FileManager.default.fileExists(atPath: source.path))
}

@Test func duoFoldsVerticallyAndKeepsHorizontalHingeConnected() {
    let size = CGSize(width: 1000, height: 600)
    for progress in [0.0, 0.2, 0.5, 0.8, 1] {
        let fold = DesktopFold(progress: progress)
        let top = fold.corners(size: size, bottom: false)
        let bottom = fold.corners(size: size, bottom: true)
        #expect(top[2].x == bottom[1].x)
        #expect(top[3].x == bottom[0].x)
        #expect(top[2].y == bottom[1].y + size.height / 2)
        #expect(top[0].y < top[3].y)
        #expect(bottom[0].y < bottom[3].y)
        if progress > 0 {
            #expect(top[0].y > 0)
            #expect(top[3].x > top[0].x)
            #expect(bottom[3].y < size.height / 2)
        }
        for corners in [top, bottom] {
            let matrix = FoldProjection.matrix(size: CGSize(width: 1000, height: 300), corners: corners)
            for (index, point) in [CGPoint(x: 0, y: 0), CGPoint(x: 1000, y: 0), CGPoint(x: 1000, y: 300), CGPoint(x: 0, y: 300)].enumerated() {
                let denominator = matrix.m14 * point.x + matrix.m24 * point.y + matrix.m44
                let x = (matrix.m11 * point.x + matrix.m21 * point.y + matrix.m41) / denominator
                let y = (matrix.m12 * point.x + matrix.m22 * point.y + matrix.m42) / denominator
                #expect(abs(x - corners[index].x) < 0.0001)
                #expect(abs(y - corners[index].y) < 0.0001)
            }
        }
    }
    #expect(DesktopFold(progress: 0).corners(size: size, bottom: false)[0] == .zero)
    #expect(DesktopFold(progress: 0.8).opacity == 1)
    #expect(abs(DesktopFold(progress: 1).opacity) < 0.00001)
}

@Test func idleHoverTargetExistsWithoutDrawingSoftwareNotch() {
    let layout = IslandLayout(cutoutWidth: 185, menuBarHeight: 32, hasHardwareNotch: true)
    let display = CGRect(x: -1728, y: 200, width: 1728, height: 1117)
    let target = layout.idleHoverFrame(on: display)
    #expect(target.contains(CGPoint(x: display.midX, y: display.maxY - 35)))
    #expect(!target.contains(CGPoint(x: display.midX, y: display.maxY - 90)))
    #expect(target.midX == display.midX)
}

@Test func pointerLeavingRoundedCornerCountsAsLeavingIsland() {
    let frame = CGRect(x: 0, y: 0, width: 408, height: 239)
    #expect(!IslandHitRegion.contains(CGPoint(x: 1, y: 1), frame: frame, radius: 34, roundedTop: false))
    #expect(IslandHitRegion.contains(CGPoint(x: 204, y: 1), frame: frame, radius: 34, roundedTop: false))
    #expect(IslandHitRegion.contains(CGPoint(x: 1, y: 238), frame: frame, radius: 34, roundedTop: false))
    #expect(!IslandHitRegion.contains(CGPoint(x: 1, y: 238), frame: frame, radius: 34, roundedTop: true))
}

@Test func desktopOverlayDetectionIgnoresOrdinaryDockAndWallpaper() {
    let dock = DesktopOverlay(layer: 20, bounds: CGRect(x: 300, y: 900, width: 1000, height: 80))
    let wallpaper = DesktopOverlay(layer: -1, bounds: CGRect(x: 0, y: 0, width: 1728, height: 1117))
    let missionControl = DesktopOverlay(layer: 18, bounds: CGRect(x: 0, y: 0, width: 1728, height: 1117))
    let switcher = DesktopOverlay(layer: 20, bounds: CGRect(x: 300, y: 400, width: 800, height: 200))
    let dockBackdrop = DesktopOverlay(layer: 20, bounds: CGRect(x: 0, y: 0, width: 1728, height: 1117), fillsDisplay: true)
    #expect(!DesktopOverlayDetection.containsSwitcher([dock, wallpaper, dockBackdrop]))
    #expect(DesktopOverlayDetection.containsSwitcher([dock, missionControl]))
    #expect(DesktopOverlayDetection.containsSwitcher([switcher]))
}

@Test func spaceSlideStaysHiddenWithOneStillSurfaceUntilCompletion() {
    var tracker = SpaceSlideTracker()
    var active = tracker.update(surfaces: [10], at: 0)
    #expect(!active)
    active = tracker.update(surfaces: [11], at: 0.1)
    #expect(active)
    active = tracker.update(surfaces: [11], at: 3)
    #expect(active)
    tracker.spaceDidChange(at: 3.1)
    active = tracker.update(surfaces: [11], at: 3.3)
    #expect(active)
    active = tracker.update(surfaces: [11], at: 3.8)
    #expect(!active)
    active = tracker.update(surfaces: [11, 12], at: 4)
    #expect(active)
    active = tracker.update(surfaces: [11], at: 4.2)
    #expect(active)
    active = tracker.update(surfaces: [11], at: 4.9)
    #expect(!active)
}

@Test func desktopSurfaceTrackingRecoversFromStaleSystemSurfaces() {
    var tracker = SpaceSlideTracker()
    let samples: [(Set<UInt32>, Double, Bool)] = [
        ([], 0, false), ([1], 0.1, true), ([1], 3, true), ([1], 12.5, false),
        ([1, 2], 13, true), ([1, 2], 25.1, false)
    ]
    for (surfaces, time, expected) in samples {
        let active = tracker.update(surfaces: surfaces, at: time)
        #expect(active == expected)
    }
}

@Test func missionControlBackdropIsNotLeftLatchedAsASpaceSlide() {
    var tracker = SpaceSlideTracker()
    var active = tracker.update(surfaces: [1], at: 0)
    #expect(!active)
    active = tracker.update(surfaces: [1, 2, 3], at: 1, overviewActive: true)
    #expect(!active) // Mission Control itself owns hiding while present.
    active = tracker.update(surfaces: [4], at: 2)
    #expect(active)
    active = tracker.update(surfaces: [4], at: 2.7)
    #expect(!active)
}

@Test func lidFoldSetupIdentifiesTheActualBlocker() {
    #expect(LidFoldReadiness.resolve(enabled: true, screenRecording: false, reduceMotion: false, angle: 99) == .permissionNeeded)
    #expect(LidFoldReadiness.resolve(enabled: false, screenRecording: true, reduceMotion: false, angle: 99) == .disabled)
    #expect(LidFoldReadiness.resolve(enabled: true, screenRecording: true, reduceMotion: true, angle: 99) == .reduceMotion)
    #expect(LidFoldReadiness.resolve(enabled: true, screenRecording: true, reduceMotion: false, angle: nil) == .sensorUnavailable)
    #expect(LidFoldReadiness.resolve(enabled: true, screenRecording: true, reduceMotion: false, angle: 10) == .openLid)
    #expect(LidFoldReadiness.resolve(enabled: true, screenRecording: true, reduceMotion: false, angle: 99) == .ready)
}

@Test func completedSpaceDoesNotWaitForPersistentDockBackgroundsToDisappear() {
    var tracker = SpaceSlideTracker()
    var active = tracker.update(surfaces: [1], at: 0)
    #expect(!active)
    active = tracker.update(surfaces: [2, 3], at: 1)
    #expect(active)
    tracker.spaceDidChange(at: 1.1)
    active = tracker.update(surfaces: [2, 3], at: 1.8)
    #expect(!active)
}

@Test func movingSpaceSurfaceKeepsIslandHiddenEvenWhenItsIDDoesNotChange() {
    var tracker = SpaceSlideTracker()
    let original = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    var active = tracker.update(surfaces: [1], at: 0, geometry: [1: original])
    #expect(!active)
    active = tracker.update(surfaces: [1], at: 0.1, geometry: [1: original.offsetBy(dx: 100, dy: 0)])
    #expect(active)
    tracker.spaceDidChange(at: 0.2)
    active = tracker.update(surfaces: [1], at: 0.8, geometry: [1: original.offsetBy(dx: 700, dy: 0)])
    #expect(active)
    active = tracker.update(surfaces: [1], at: 1.2, geometry: [1: original.offsetBy(dx: 1000, dy: 0)])
    #expect(active)
    active = tracker.update(surfaces: [1], at: 1.6, geometry: [1: original])
    #expect(active)
    active = tracker.update(surfaces: [1], at: 2.1, geometry: [1: original])
    #expect(active)
    active = tracker.update(surfaces: [1], at: 2.3, geometry: [1: original])
    #expect(!active)
}

@Test func overlappingDesktopNotificationsCannotRestoreTheIslandEarly() {
    var gate = DesktopRestoreGate()
    gate.extend(at: 10, delay: 0.9)
    gate.extend(at: 10.1, delay: 0.18)
    #expect(abs(gate.remaining(at: 10.3) - 0.6) < 0.0001)
    gate.extend(at: 10.8, delay: 0.3)
    #expect(abs(gate.remaining(at: 10.9) - 0.2) < 0.0001)
    #expect(gate.remaining(at: 11.2) == 0)
    gate.reset()
    #expect(gate.remaining(at: 0) == 0)
}

@Test func threeFingerSpaceGestureStaysLatchedUntilEveryFingerIsReleased() {
    var contacts = SpaceContactLatch()
    contacts.receive(device: 1, count: 2)
    #expect(!contacts.active)
    contacts.receive(device: 1, count: 3)
    #expect(contacts.active)
    contacts.receive(device: 1, count: 2)
    #expect(contacts.active)
    contacts.receive(device: 1, count: 1)
    #expect(contacts.active)
    contacts.receive(device: 2, count: 0)
    #expect(contacts.active)
    contacts.receive(device: 1, count: 0)
    #expect(!contacts.active)
}

@Test func simultaneousSpaceGesturesReleaseIndependentlyAndIgnoreInvalidFrames() {
    var contacts = SpaceContactLatch()
    contacts.receive(device: 1, count: 3)
    contacts.receive(device: 2, count: 4)
    contacts.receive(device: 1, count: 0)
    #expect(contacts.active)
    contacts.receive(device: 2, count: -1)
    contacts.receive(device: 2, count: 100)
    #expect(contacts.active)
    contacts.receive(device: 2, count: 0)
    #expect(!contacts.active)
}

@Test func stopwatchUsesElapsedTimeAndPreservesPausedLaps() {
    var state = StopwatchState()
    #expect(state.value(at: 10) == 0)
    state.start(at: 10); state.start(at: 12)
    state.lap(at: 15)
    state.pause(at: 17)
    #expect(state.value(at: 100) == 7)
    #expect(state.laps == [5])
    state.start(at: 100); state.pause(at: 103)
    #expect(state.value(at: 200) == 10)
    state.reset(); #expect(state.value(at: 300) == 0)
}

@Test func alarmRollsToTomorrowAndHandlesMissingDSTTime() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "Europe/Copenhagen"))
    let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 10, minute: 30)))
    let time = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 9, minute: 0)))
    let next = try #require(AlarmSchedule.next(time: time, after: now, calendar: calendar))
    #expect(calendar.component(.day, from: next) == 20)
    #expect(calendar.component(.hour, from: next) == 9)
    let beforeDST = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 28, hour: 23)))
    let missingTime = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 28, hour: 2, minute: 30)))
    let dstAlarm = try #require(AlarmSchedule.next(time: missingTime, after: beforeDST, calendar: calendar))
    #expect(dstAlarm > beforeDST)
    #expect(calendar.component(.day, from: dstAlarm) == 29)
}

@Test @MainActor func alarmFiresOnceAndCancelsCleanly() {
    let suite = "SenseClockTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let clock = ClockTools(defaults: defaults, notificationsEnabled: false)
    var count = 0
    clock.onAlarm = { count += 1 }
    let date = Date().addingTimeInterval(3600)
    clock.arm(at: date)
    clock.checkAlarm(at: date.addingTimeInterval(-1)); #expect(count == 0)
    clock.checkAlarm(at: date); clock.checkAlarm(at: date.addingTimeInterval(60))
    #expect(count == 1); #expect(clock.ringing); #expect(clock.alarmDate == nil)
    clock.cancelAlarm(); #expect(!clock.ringing); clock.stop()
}

@Test func nativeForceDecodesOnlyValidSingleContact() {
    var bytes = [UInt8](repeating: 0, count: 96)
    bytes.withUnsafeMutableBytes { buffer in
        buffer.storeBytes(of: Int32(42), toByteOffset: 16, as: Int32.self)
        buffer.storeBytes(of: Int32(4), toByteOffset: 20, as: Int32.self)
        buffer.storeBytes(of: Float(72.5), toByteOffset: 52, as: Float.self)
        let sample = NativeForceSample.decode(buffer.baseAddress, count: 1)
        #expect(sample.grams == 72.5); #expect(sample.touchID == 42)
        #expect(NativeForceSample.decode(buffer.baseAddress, count: 2).grams == nil)
        buffer.storeBytes(of: Float.nan, toByteOffset: 52, as: Float.self)
        #expect(NativeForceSample.decode(buffer.baseAddress, count: 1).grams == nil)
    }
    #expect(NativeForceSample.decode(nil, count: 0).grams == nil)
}

@Test @MainActor func nativeWeighingRequiresZeroAndInvalidatesChangedContact() {
    let suite = "SenseNativeScaleTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let scale = NativeWeighing(defaults: defaults)
    #expect(scale.grams == nil)
    scale.receive(.init(grams: 25, touchID: 1, contactCount: 1))
    #expect(scale.grams == nil)
    scale.tare()
    scale.receive(.init(grams: 75, touchID: 1, contactCount: 1))
    #expect(scale.grams == 50)
    scale.receive(.init(grams: nil, touchID: nil, contactCount: 0))
    #expect(scale.grams == nil); #expect(scale.heldGrams == 50)
    scale.receive(.init(grams: 100, touchID: 2, contactCount: 1))
    #expect(scale.grams == nil)
    scale.tare(); scale.receive(.init(grams: 150, touchID: 3, contactCount: 1))
    #expect(scale.grams == nil)
}

@Test func islandRestorationGrowsFromThePhysicalCameraWithoutFadingIt() {
    let layout = IslandLayout(cutoutWidth: 190, menuBarHeight: 32, hasHardwareNotch: true)
    #expect(layout.surfaceSize(for: .compact, reveal: 0) == CGSize(width: 190, height: 32))
    #expect(layout.surfaceSize(for: .compact, reveal: 1) == layout.compactSize)
    #expect(layout.surfaceSize(for: .expanded, reveal: 1) == layout.expandedSize)
    for step in 0...20 {
        let size = layout.surfaceSize(for: .compact, reveal: Double(step) / 20)
        #expect(size.width >= layout.cutoutWidth)
        #expect(size.height == layout.menuBarHeight)
        let expanded = layout.surfaceSize(for: .expanded, reveal: Double(step) / 20)
        #expect(expanded.width >= layout.cutoutWidth)
        #expect(expanded.height >= layout.menuBarHeight)
        #expect(layout.surfaceSize(for: .hidden, reveal: Double(step) / 20) == CGSize(width: 190, height: 32))
    }
}

@Test func hingeCalibrationFollowsOpeningAfterWakeAndHoldsDuringClosing() {
    var reference: Double? = nil
    for angle in [35.0, 50, 70, 100, 110] {
        reference = HingeMotion.openReference(angle: angle, previous: reference)
        #expect(reference == angle)
        #expect(HingeMotion.progress(angle: angle, reference: reference!) == 0)
    }
    reference = HingeMotion.openReference(angle: 90, previous: reference)
    #expect(reference == 110)
    #expect(HingeMotion.progress(angle: 90, reference: reference!) > 0)
    #expect(HingeMotion.openReference(angle: 100, previous: .nan) == 100)
}

@Test func lidSetupOnlySaysReadyAfterActualDesktopCaptureSucceeds() {
    for check in [LidCaptureCheck.unverified, .checking, .failed("Denied")] {
        let state = LidSetupStatus(readiness: .ready, capture: check)
        #expect(!state.ready); #expect(state.title != "Ready")
    }
    #expect(LidSetupStatus(readiness: .ready, capture: .verified).ready)
    for readiness in [LidFoldReadiness.disabled, .permissionNeeded, .reduceMotion, .sensorUnavailable, .openLid] {
        #expect(!LidSetupStatus(readiness: readiness, capture: .verified).ready)
    }
    #expect(LidSetupStatus(readiness: .ready, capture: .failed("Capture failed")).detail == "Capture failed")
}

@Test func lidRebaselinesOnlyAfterRestingAtAWorkingAngle() {
    #expect(HingeMotion.settledReference(angle: 100, reference: 120, stillFor: 0.5) == 120)
    #expect(HingeMotion.settledReference(angle: 100, reference: 120, stillFor: 2.5) == 100)
    #expect(HingeMotion.settledReference(angle: 20, reference: 120, stillFor: 5) == 120)
    #expect(HingeMotion.settledReference(angle: 130, reference: 120, stillFor: 5) == 120)
}

@Test func switcherOrdersFrontmostThenMostRecentlyUsed() {
    let recent: [pid_t] = [10, 30, 20]
    let order = [20, 40, 30, 10].sorted { WindowSwitcher.rank($0, frontmost: 10, recent: recent) < WindowSwitcher.rank($1, frontmost: 10, recent: recent) }
    #expect(order == [10, 30, 20, 40])
}

@Test func stopwatchClockKeepsRunningMonotonically() {
    let a = ClockTools.continuousNow
    #expect(ClockTools.continuousNow >= a)
}

@Test @MainActor func scalePausesWhenSensorFramesLookUnrecognized() {
    let weighing = NativeWeighing(defaults: UserDefaults(suiteName: "SenseTests.\(UUID().uuidString)")!)
    for _ in 0..<29 { weighing.receive(NativeForceSample(grams: nil, touchID: nil, contactCount: 1, plausible: false)) }
    #expect(!weighing.formatUnrecognized)
    weighing.receive(NativeForceSample(grams: nil, touchID: nil, contactCount: 1, plausible: true))
    for _ in 0..<30 { weighing.receive(NativeForceSample(grams: nil, touchID: nil, contactCount: 1, plausible: false)) }
    #expect(weighing.formatUnrecognized)
}

@Test func doorsFoldIsFlatAtRestAndMeetsAtTheHinge() {
    let size = CGSize(width: 1000, height: 600)
    let flat = DesktopFold(progress: 0).corners(size: size, panel: .leading)
    #expect(flat == [CGPoint(x: 0, y: 0), CGPoint(x: 500, y: 0), CGPoint(x: 500, y: 600), CGPoint(x: 0, y: 600)])
    for progress in [0.3, 0.7, 1.0] {
        let fold = DesktopFold(progress: progress)
        let left = fold.corners(size: size, panel: .leading)
        let right = fold.corners(size: size, panel: .trailing)
        // Both panels end on the shared vertical hinge, in their own frames.
        #expect(abs(left[1].x - 500) < 0.001 && abs(left[2].x - 500) < 0.001)
        #expect(abs(right[0].x) < 0.001 && abs(right[3].x) < 0.001)
        // The hinge edge is recessed vertically; the outer edge stays nearer the viewer.
        #expect(left[1].y > left[0].y && left[2].y < left[3].y)
    }
}

@Test func batteryDetailsReportOnlyWhatTheMacProvides() {
    let registry: [String: Any] = ["CycleCount": 214, "DesignCapacity": 6000, "NominalChargeCapacity": 5460,
                                   "FullyCharged": false, "AdapterDetails": ["Watts": 67]]
    let details = BatteryDetails(registry: registry, charging: true, minutesToEmpty: -1, minutesToFull: 72)
    #expect(details.cycleCount == 214 && details.healthPercent == 91 && details.adapterWatts == 67)
    #expect(details.minutesToEmpty == nil)
    #expect(details.summary(level: 80, externalPower: true) == "Charging · 1 h 12 min until full")
    #expect(BatteryDetails().healthPercent == nil)
    #expect(BatteryDetails().summary(level: nil, externalPower: false) == "No battery")
    #expect(BatteryDetails(minutesToEmpty: 45).summary(level: 40, externalPower: false) == "On battery · 45 min remaining")
    #expect(BatteryDetails(registry: ["FullyCharged": true]).summary(level: 100, externalPower: true) == "Fully charged")
}

@Test func menuAndShortcutsIncludeBattery() {
    #expect(ToolShortcuts.Tool.allCases.map(\.title).contains("Battery"))
    #expect(Set(ToolShortcuts.Tool.allCases.map(\.keyCode)).count == ToolShortcuts.Tool.allCases.count)
}

@Test func switcherSearchMatchesEveryWordAcrossTitleAndApp() {
    #expect(SwitcherFilter.matches(query: "", title: "Inbox", app: "Mail"))
    #expect(SwitcherFilter.matches(query: "mail inb", title: "Inbox", app: "Mail"))
    #expect(SwitcherFilter.matches(query: "RESUME", title: "Résumé.pdf", app: "Preview"))
    #expect(!SwitcherFilter.matches(query: "mail budget", title: "Inbox", app: "Mail"))
}

@Test func imageToolsConvertAndStripMetadataWithoutTouchingTheOriginal() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SenseImageTools-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    let image = try #require(context.makeImage())
    let original = directory.appendingPathComponent("photo.jpg")
    let destination = try #require(CGImageDestinationCreateWithURL(original as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, [kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "secret place"]] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    let before = try Data(contentsOf: original)

    let stripped = try ShelfImageTools.stripMetadata(original)
    #expect(stripped.lastPathComponent == "photo (no metadata).jpg")
    let strippedSource = try #require(CGImageSourceCreateWithURL(stripped as CFURL, nil))
    let properties = try #require(CGImageSourceCopyPropertiesAtIndex(strippedSource, 0, nil) as? [CFString: Any])
    let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
    #expect(exif?[kCGImagePropertyExifUserComment] == nil)

    let png = try ShelfImageTools.convert(original, to: .png)
    #expect(png.pathExtension == "png" && ShelfImageTools.isImage(png))
    #expect(try Data(contentsOf: original) == before)
    #expect(ShelfImageTools.uniqueURL(for: directory.appendingPathComponent("README"), suffix: "", ext: "").lastPathComponent == "README")
}

@Test func calendarPickIgnoresAllDayAndFinishedEvents() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let hour: TimeInterval = 3600
    let event = NextEvent.pick(from: [
        (id: "a", title: "Holiday", start: now - hour, end: now + 10 * hour, allDay: true, meetingURL: nil),
        (id: "b", title: "Done", start: now - 2 * hour, end: now - hour, allDay: false, meetingURL: nil),
        (id: "c", title: "Standup", start: now + 12 * 60, end: now + hour, allDay: false, meetingURL: nil),
        (id: "d", title: "Later", start: now + 5 * hour, end: now + 6 * hour, allDay: false, meetingURL: nil)], now: now)
    #expect(event?.title == "Standup")
    #expect(event?.relative(at: now) == "in 12 min")
}

@Test func weekdayAlarmsSkipTheWeekend() throws {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
    let friday = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 20)))
    let eight = try #require(calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 7, minute: 30)))
    let daily = try #require(AlarmSchedule.next(time: eight, after: friday, repeat: .daily, calendar: calendar))
    let weekdays = try #require(AlarmSchedule.next(time: eight, after: friday, repeat: .weekdays, calendar: calendar))
    #expect(calendar.component(.weekday, from: daily) == 7)      // Saturday
    #expect(calendar.component(.weekday, from: weekdays) == 2)   // Monday
}

@Test @MainActor func clipboardHistorySkipsConcealedCopiesAndPasswordManagers() {
    let shelf = ClipboardShelf()
    let board = NSPasteboard(name: NSPasteboard.Name("SenseTests.\(UUID().uuidString)"))
    board.clearContents(); board.setString("hello world", forType: .string)
    shelf.recordCopy(from: board, frontmost: "com.apple.TextEdit")
    shelf.recordCopy(from: board, frontmost: "com.1password.1password")
    #expect(shelf.history.count == 1)
    board.clearContents(); board.declareTypes([.string, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")], owner: nil)
    board.setString("hunter2", forType: .string)
    shelf.recordCopy(from: board, frontmost: "com.apple.TextEdit")
    #expect(shelf.history.count == 1)
    board.clearContents(); board.setString("https://example.com", forType: .string)
    shelf.recordCopy(from: board, frontmost: nil)
    #expect(shelf.history.first?.symbol == "link")
    shelf.historyFilter = "hello"
    #expect(shelf.filteredHistory.count == 1)
}

@Test func partialDownloadNamesMapToTheirFinalFiles() {
    let found = TransferScan.partials(in: ["a.zip.crdownload", "movie.mp4.download", "notes.txt", ".hidden.crdownload", "x.part", ".crdownload"])
    #expect(found.map(\.final).sorted() == ["a.zip", "movie.mp4", "x"])
    #expect(TransferScan.safariProgress(["DownloadEntryProgressBytesSoFar": 25, "DownloadEntryProgressTotalToLoad": 100]).fraction == 0.25)
    #expect(TransferScan.safariProgress(["DownloadEntryProgressBytesSoFar": 25]).fraction == nil)
    #expect(TransferScan.safariProgress([:]).bytes == nil)
    #expect(TransferScan.quarantineAgent("0083;5f8e8f1a;sharingd;1234") == "sharingd")
    #expect(TransferScan.quarantineAgent("junk") == nil)
    let known = TransferActivity(id: "1", kind: .download, name: "a", fraction: 0.5)
    let unknown = TransferActivity(id: "2", kind: .download, name: "b", fraction: nil)
    #expect(TransferScan.combinedFraction([known]) == 0.5)
    #expect(TransferScan.combinedFraction([known, unknown]) == nil)
}

@Test @MainActor func downloadsAppearWhileArrivingAndFinishOnce() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SenseDownloads-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let tracker = TransferTracker()
    var finished: [String] = []
    tracker.onFinished = { finished.append($0.name) }
    try Data(repeating: 1, count: 2048).write(to: directory.appendingPathComponent("big.zip.crdownload"))
    tracker.start(directory: directory)
    #expect(tracker.running.map(\.name) == ["big.zip"])
    #expect(tracker.running.first?.bytes == 2048 && tracker.running.first?.fraction == nil)
    try FileManager.default.moveItem(at: directory.appendingPathComponent("big.zip.crdownload"), to: directory.appendingPathComponent("big.zip"))
    tracker.scan(); tracker.scan()
    #expect(tracker.running.isEmpty && finished == ["big.zip"] && tracker.recent.count == 1)
    // A download cancelled before finishing leaves nothing behind.
    try Data([1]).write(to: directory.appendingPathComponent("gone.part"))
    tracker.scan()
    try FileManager.default.removeItem(at: directory.appendingPathComponent("gone.part"))
    tracker.scan()
    #expect(tracker.running.isEmpty && finished == ["big.zip"])
    tracker.stop()
}

@Test func sharingIsDetectedFromMirroringOrShareHelpers() {
    #expect(SharingDetection.isSharing(processNames: ["Safari"], displaysMirrored: true))
    #expect(SharingDetection.isSharing(processNames: ["CptHost", "Finder"], displaysMirrored: false))
    #expect(!SharingDetection.isSharing(processNames: ["zoom.us", "Safari"], displaysMirrored: false))
}

@Test @MainActor func autoHideAndPresentationModeAreIndependent() {
    let controller = NotchController()
    controller.setAutoHide(reason: "Focus is on")
    #expect(controller.presentationMode && !controller.manualPresentation)
    controller.setPresentationMode(true)
    controller.setAutoHide(reason: nil)
    #expect(controller.presentationMode)
    controller.setPresentationMode(false)
    #expect(!controller.presentationMode)
}

@Test @MainActor func clipboardPinsSurviveARelaunchAndForgetWhenTurnedOff() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SensePins-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ClipboardPinStore(directory: directory)
    let context = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let cgImage = try #require(context.makeImage())
    let png = try #require(NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]))

    let first = ClipboardShelf()
    first.persistence = store
    first.add(.text("Remember me")); first.add(.link(URL(string: "https://example.com")!)); first.add(.image(png))
    let second = ClipboardShelf()
    second.restore(from: store)
    #expect(second.pins.map(\.payload) == first.pins.map(\.payload))
    #expect(second.pins.map(\.id) == first.pins.map(\.id))

    // Removing an image pin deletes its file; turning persistence off deletes everything.
    second.persistence = store
    if let image = second.pins.last { second.remove(image) }
    let pngs = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".png") }
    #expect(pngs.isEmpty)
    second.persistence = nil
    #expect(!FileManager.default.fileExists(atPath: directory.path))
}

@Test func islandTabsShowTransfersOnlyWhenUseful() {
    let off = IslandTabBar.visible(showsTransfers: false, hasBattery: true)
    #expect(!off.map(\.tab).contains(.transfers) && off.count == 5)
    #expect(IslandTabBar.visible(showsTransfers: true, hasBattery: true).map(\.tab).last == .transfers)
    #expect(IslandTabBar.visible(showsTransfers: false, hasBattery: false).first { $0.tab == .battery }?.title == "Controls")
}

@Test func soundOutputsUseTheirDeviceSymbol() {
    #expect(AudioOutput(id: 1, name: "AirPods Pro", transport: kAudioDeviceTransportTypeBluetooth).symbol == "airpods.pro")
    #expect(AudioOutput(id: 2, name: "MacBook Pro Speakers", transport: kAudioDeviceTransportTypeBuiltIn).symbol == "laptopcomputer")
    #expect(AudioOutput(id: 3, name: "Living Room", transport: kAudioDeviceTransportTypeAirPlay).symbol == "airplayaudio")
}

@Test @MainActor func welcomePageIsReachableButNotInTheSidebar() {
    #expect(SettingsPage.allCases.contains(.welcome))
    #expect(!SettingsPage.sidebar.contains(.welcome))
}

@Test func duoTipsTheScreenBackFromTheBottomHinge() {
    let size = CGSize(width: 1000, height: 600)
    #expect(DesktopFold(progress: 0).pushBackCorners(size: size) == [CGPoint(x: 0, y: 0), CGPoint(x: 1000, y: 0), CGPoint(x: 1000, y: 600), CGPoint(x: 0, y: 600)])
    let closing = DesktopFold(progress: 0.8).pushBackCorners(size: size)
    #expect(closing[2].y == 600 && closing[3].y == 600)                       // the hinge edge stays put
    #expect(closing[1].x - closing[0].x < closing[2].x - closing[3].x)        // the top recedes: narrower
    #expect(closing[0].y > 0)                                                  // and lower
    #expect(FoldProjection.matrix(size: size, corners: closing).m14 != 0 || FoldProjection.matrix(size: size, corners: closing).m24 != 0)
    #expect(LidFoldStyle.allCases.first == .duo)
}

@Test func switcherPreviewsMatchByWindowNumberThenByBounds() {
    let frame = CGRect(x: 100, y: 80, width: 900, height: 600)
    let candidates: [ThumbnailMatch.Candidate] = [
        .init(windowID: 11, pid: 7, title: "Inbox", frame: frame),
        .init(windowID: 12, pid: 7, title: "Other", frame: frame.offsetBy(dx: 400, dy: 0)),
        .init(windowID: 13, pid: 8, title: "Inbox", frame: frame),
    ]
    #expect(ThumbnailMatch.pick(windowID: 12, pid: 7, title: "Inbox", frame: frame, from: candidates) == 12)
    // Without a number, a differing title no longer blocks the match; bounds decide.
    #expect(ThumbnailMatch.pick(windowID: nil, pid: 7, title: "Inbox — Mail", frame: frame.offsetBy(dx: 2, dy: 1), from: candidates) == 11)
    // Two equally close windows of the same app are ambiguous, so no preview rather than the wrong one.
    let twins = [ThumbnailMatch.Candidate(windowID: 1, pid: 7, title: nil, frame: frame), .init(windowID: 2, pid: 7, title: nil, frame: frame)]
    #expect(ThumbnailMatch.pick(windowID: nil, pid: 7, title: "A", frame: frame, from: twins) == nil)
}
