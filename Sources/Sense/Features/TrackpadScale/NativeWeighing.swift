import AppKit
import SwiftUI

@MainActor @Observable final class NativeWeighing {
    private(set) var available = false
    private(set) var listening = false
    private(set) var rawGrams: Double?
    private(set) var baseline: Double?
    private(set) var touchID: Int32?
    private(set) var heldGrams: Double?
    private(set) var receivedSamples = 0
    /// Set when sensor frames stop matching the expected layout, so the scale says so instead of guessing.
    private(set) var formatUnrecognized = false
    private var implausibleRun = 0
    var knownGrams = 50.0
    var notice: String?
    private let defaults: UserDefaults
    private(set) var factor: Double
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.double(forKey: "nativeGramsFactor")
        factor = saved.isFinite && saved > 0 ? saved : 1
    }
    var grams: Double? {
        guard let rawGrams, let baseline else { return nil }
        return max(0, (rawGrams - baseline) * factor)
    }
    func start() {
        guard !listening else { return }
        listening = true
        available = TrackpadSpaceGestureMonitor.shared.startForce { [weak self] in self?.receive($0) }
    }
    func stop() {
        guard listening else { return }
        TrackpadSpaceGestureMonitor.shared.stopForce(); listening = false
        rawGrams = nil; baseline = nil; touchID = nil
    }
    func receive(_ sample: NativeForceSample) {
        receivedSamples += 1
        if sample.contactCount == 1 {
            implausibleRun = sample.plausible ? 0 : implausibleRun + 1
            formatUnrecognized = implausibleRun >= 30
        }
        guard !formatUnrecognized, sample.contactCount == 1, let value = sample.grams, value.isFinite, (0...5000).contains(value), let identity = sample.touchID else {
            rawGrams = nil; baseline = nil; touchID = nil; return
        }
        if touchID != identity { baseline = nil }
        touchID = identity; rawGrams = value
        if let grams { heldGrams = grams }
    }
    func tare() {
        guard let rawGrams else { notice = String(localized: "Rest one fingertip lightly on the trackpad first."); return }
        baseline = rawGrams; heldGrams = 0
        notice = String(localized: "Zero set. Keep that fingertip still and add your object beside it.")
    }
    func calibrate() {
        guard let rawGrams, let baseline,
              let conversion = ScaleCalibration.factor(knownGrams: knownGrams, pressure: rawGrams, baseline: baseline) else {
            notice = String(localized: "Set zero first, then add a known mass while keeping the same fingertip contact."); return
        }
        factor = conversion; defaults.set(conversion, forKey: "nativeGramsFactor")
        heldGrams = grams; notice = String(localized: "Calibration saved. Tare again for each new contact.")
    }
    func reset() {
        factor = 1; defaults.removeObject(forKey: "nativeGramsFactor")
        baseline = nil; heldGrams = nil; notice = String(localized: "Using the sensor’s native gram estimate. Set zero to begin.")
    }
}

final class ScaleWindow: NSWindow {
    weak var weighing: NativeWeighing?
    override func close() { weighing?.stop(); super.close() }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty, event.charactersIgnoringModifiers?.lowercased() == "t" {
            weighing?.tare()
        } else { super.keyDown(with: event) }
    }
}

struct NativeScaleView: View {
    @Bindable var model: NativeWeighing
    private var status: String {
        if !model.available { return String(localized: "A built-in Force Touch trackpad is required") }
        if model.formatUnrecognized { return String(localized: "This macOS version’s trackpad data isn’t recognized. Readings are paused.") }
        if model.grams != nil { return String(localized: "Live estimate") }
        if model.heldGrams != nil { return String(localized: "Held reading · set zero for a new measurement") }
        return model.rawGrams == nil ? String(localized: "Rest one fingertip lightly on the trackpad") : String(localized: "Set zero, then place your object beside your finger")
    }
    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Label("Trackpad Scale", systemImage: "scalemass").font(.headline)
                Spacer()
                Text("EXPERIMENTAL").font(.system(size: 9, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text((model.grams ?? model.heldGrams).map { String(format: "%.1f", $0) } ?? "—")
                    .font(.system(size: 84, weight: .light, design: .rounded)).monospacedDigit()
                Text("g").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
            }
            Text(status).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 16) {
                Label("Rest one fingertip lightly on the trackpad.", systemImage: "hand.point.up.left")
                Label("Press T or Set Zero without lifting your finger.", systemImage: "arrow.counterclockwise")
                Label("Place a small object beside your finger.", systemImage: "cube.transparent")
            }.font(.callout).padding(20).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 20))
            Button("Set Zero", systemImage: "arrow.counterclockwise") { model.tare() }
                .buttonStyle(.borderedProminent).controlSize(.large).disabled(model.rawGrams == nil)
            HStack {
                Text("Known mass").font(.caption).foregroundStyle(.secondary)
                TextField("Grams", value: $model.knownGrams, format: .number).frame(width: 55).accessibilityLabel("Known calibration mass in grams")
                Text("g").foregroundStyle(.secondary)
                Button("Calibrate") { model.calibrate() }.disabled(model.grams == nil)
                Button("Reset") { model.reset() }
            }.controlSize(.small)
            if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center) }
            Spacer(minLength: 0)
            Text("Uses the built-in Force Touch sensor. Keep one fingertip in contact; objects alone may not register. Lifting or changing contact requires a new zero. This is an estimate, not a precision scale.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(28).frame(width: 520, height: 680).background(.background)
    }
}
