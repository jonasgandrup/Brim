import Foundation

struct ScaleCalibration {
    static func factor(knownGrams: Double, pressure: Double, baseline: Double) -> Double? {
        let delta = pressure - baseline
        guard knownGrams.isFinite, knownGrams > 0, knownGrams <= 500,
              delta.isFinite, delta > 0.01 else { return nil }
        return knownGrams / delta
    }
}
