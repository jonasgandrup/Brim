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
    #expect(preferences.gramsPerUnit == 0)
    preferences.notchEnabled = false; preferences.shortcut = "option"; preferences.gramsPerUnit = 123
    let restored = Preferences(defaults: defaults)
    #expect(!restored.notchEnabled)
    #expect(restored.shortcut == "option")
    #expect(restored.gramsPerUnit == 123)
}
@Test @MainActor func scaleNeverInventsContactOrMass() {
    let model = ScaleModel()
    #expect(!model.receivingPressure)
    #expect(!model.contact)
    model.tare()
    #expect(model.baseline == 0)
    model.receive(pressure: 0.3, stage: 1)
    model.tare()
    #expect(model.baseline == 0.3)
    model.release()
    #expect(!model.contact)
    #expect(model.pressure == 0)
}

@Test func islandKeepsCameraClearAndAnchorsExpansionToTopCenter() {
    let layout = IslandLayout(cutoutWidth: 190, menuBarHeight: 32, hasHardwareNotch: true)
    let display = CGRect(x: -1512, y: 200, width: 1512, height: 982)
    let compact = layout.frame(on: display, expanded: false)
    let expanded = layout.frame(on: display, expanded: true)
    #expect(compact.width > layout.cutoutWidth)
    #expect(compact.height == 37)
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

@Test @MainActor func scaleShowsDerivedGramsAndHoldsLastMeasurement() throws {
    let suite = "SenseScaleTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = Preferences(defaults: defaults)
    let scale = ScaleModel()
    #expect(scale.lastGrams == nil)
    scale.receive(pressure: 0.1, stage: 1)
    scale.tare()
    scale.receive(pressure: 0.6, stage: 1)
    scale.knownGrams = 50
    scale.calibrate(preferences: preferences)
    #expect(scale.lastGrams == 50)
    scale.receive(pressure: 0.35, stage: 1, factor: preferences.gramsPerUnit)
    let reading = try #require(scale.lastGrams)
    #expect(abs(reading - 25) < 0.001)
    scale.release()
    #expect(scale.liveGrams(factor: preferences.gramsPerUnit) == nil)
    #expect(scale.lastGrams == reading)
    scale.resetCalibration(preferences: preferences)
    #expect(scale.lastGrams == nil)
    #expect(preferences.gramsPerUnit == 0)
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

@Test @MainActor func rawTrackpadUnitsNeedNoMassCalibration() {
    let model = ScaleModel()
    #expect(model.unit == .pressure)
    #expect(model.lastPressure == nil)
    model.receive(pressure: 0.375, stage: 1)
    #expect(model.lastPressure == 0.375)
    #expect(model.lastGrams == nil)
    model.release()
    #expect(model.lastPressure == 0.375)
    #expect(!model.contact)
    model.receive(pressure: .nan, stage: 1)
    model.receive(pressure: 4, stage: 1)
    #expect(!model.contact)
    #expect(model.lastPressure == 0.375)
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
