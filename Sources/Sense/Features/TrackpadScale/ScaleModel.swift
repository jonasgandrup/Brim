import AppKit
import SwiftUI

struct ScaleCalibration {
    static func factor(knownGrams: Double, pressure: Double, baseline: Double) -> Double? {
        let delta = pressure - baseline
        guard knownGrams.isFinite, knownGrams > 0, knownGrams <= 500,
              delta.isFinite, delta > 0.01 else { return nil }
        return knownGrams / delta
    }
    static func weight(pressure: Double, baseline: Double, factor: Double) -> Double? {
        guard factor.isFinite, factor > 0, pressure.isFinite, baseline.isFinite else { return nil }
        return max(0, (pressure - baseline) * factor)
    }
}

enum ScaleUnit: String, CaseIterable, Identifiable {
    case pressure = "Trackpad units", grams = "Grams"
    var id: Self { self }
}

@MainActor @Observable
final class ScaleModel {
    let native = NativeWeighing()
    var unit: ScaleUnit = .pressure
    private(set) var lastPressure: Double?
    var pressure: Double = 0
    var baseline: Double = 0
    var receivingPressure = false
    var contact = false
    var stage = 0
    var baselineStage = 0
    var baselineValid = false
    var knownGrams: Double = 50
    var notice: String?
    private(set) var lastGrams: Double?
    private var calibrationFactor: Double = 0
    func receive(pressure: Double, stage: Int, factor: Double = 0) {
        guard pressure.isFinite, (0...1).contains(pressure), stage > 0 else { return }
        lastPressure = pressure
        receivingPressure = true; contact = true; self.stage = stage
        self.pressure = pressure; calibrationFactor = factor
        if let value = liveGrams(factor: factor) { lastGrams = value }
    }
    func liveGrams(factor: Double) -> Double? {
        guard contact, baselineValid, stage == baselineStage else { return nil }
        return ScaleCalibration.weight(pressure: pressure, baseline: baseline, factor: factor)
    }
    func resetCalibration(preferences: Preferences) {
        unit = .pressure
        preferences.gramsPerUnit = 0; calibrationFactor = 0; lastGrams = nil; baselineValid = false
        notice = "Calibration reset. Tare with a light finger, then calibrate with a known mass."
    }
    func release() { contact = false; pressure = 0; baselineValid = false }
    func tare() {
        guard contact else { notice = "Keep your finger on the pad while setting the baseline."; return }
        baseline = pressure; baselineStage = stage; baselineValid = true
        if calibrationFactor > 0 { lastGrams = 0 }
        notice = "Baseline set. Keep the same light finger contact."
    }
    func calibrate(preferences: Preferences) {
        guard contact, baselineValid, stage == baselineStage, let factor = ScaleCalibration.factor(knownGrams: knownGrams, pressure: pressure, baseline: baseline) else {
            notice = "Tare with a light finger, then apply the known mass while maintaining contact. The pressure must increase."; return
        }
        preferences.gramsPerUnit = factor; calibrationFactor = factor
        lastGrams = liveGrams(factor: factor)
        unit = .grams
        notice = "Calibration saved. Estimates apply only to this contact and pressure stage."
    }
}

struct PressureSurface: NSViewRepresentable {
    let model: ScaleModel
    let preferences: Preferences
    func makeNSView(context: Context) -> PressurePad { let view = PressurePad(); view.model = model; view.preferences = preferences; return view }
    func updateNSView(_ nsView: PressurePad, context: Context) { nsView.model = model; nsView.preferences = preferences }
}

final class PressurePad: NSView {
    var model: ScaleModel?
    var preferences: Preferences?
    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { super.keyDown(with: event); return }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "t": model?.tare()
        case "c": if let preferences { model?.calibrate(preferences: preferences) }
        default: super.keyDown(with: event)
        }
    }
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    override func mouseUp(with event: NSEvent) { model?.release() }
    override func pressureChange(with event: NSEvent) {
        if event.stage > 0 { model?.receive(pressure: Double(event.pressure), stage: event.stage, factor: preferences?.gramsPerUnit ?? 0) }
        else { model?.release() }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        pressureConfiguration = NSPressureConfiguration(pressureBehavior: .primaryGeneric)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 20, yRadius: 20).fill()
        NSColor.separatorColor.setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 20, yRadius: 20)
        border.setLineDash([5, 5], count: 2, phase: 0); border.stroke()
    }
}

struct ScaleView: View {
    let model: ScaleModel
    let preferences: Preferences
    var body: some View { NativeScaleView(model: model.native) }
}
