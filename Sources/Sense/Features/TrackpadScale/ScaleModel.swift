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

struct ScaleView: View {
    let model: NativeWeighing
    var body: some View { NativeScaleView(model: model) }
}
