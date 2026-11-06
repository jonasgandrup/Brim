import Foundation

/// How the battery is doing beyond its percentage, as far as the island shows it: whether it's charging and
/// whether Low Power Mode is on.
struct BatteryDetails: Equatable, Sendable {
    var charging = false
    var lowPowerMode = false

    static func duration(minutes: Int) -> String {
        minutes >= 60 ? (minutes % 60 == 0 ? String(localized: "\(minutes / 60) h") : String(localized: "\(minutes / 60) h \(minutes % 60) min")) : String(localized: "\(minutes) min")
    }
}
