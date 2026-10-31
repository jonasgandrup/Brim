import Foundation
import IOKit

/// Everything the battery pane shows beyond the percentage. Values are optional because desktop Macs
/// and some power states don't report them; nothing is invented when a field is missing.
struct BatteryDetails: Equatable, Sendable {
    var charging = false
    var fullyCharged = false
    var minutesToEmpty: Int?
    var minutesToFull: Int?
    var cycleCount: Int?
    var healthPercent: Int?
    var adapterWatts: Int?
    var lowPowerMode = false

    /// Parses the `AppleSmartBattery` registry entry. Health follows System Settings: the battery's
    /// current full-charge capacity relative to its design capacity.
    init(registry: [String: Any]? = nil, charging: Bool = false, minutesToEmpty: Int? = nil, minutesToFull: Int? = nil, lowPowerMode: Bool = false) {
        self.charging = charging
        self.lowPowerMode = lowPowerMode
        self.minutesToEmpty = minutesToEmpty.flatMap { $0 > 0 ? $0 : nil }
        self.minutesToFull = minutesToFull.flatMap { $0 > 0 ? $0 : nil }
        guard let registry else { return }
        func int(_ key: String) -> Int? { (registry[key] as? NSNumber)?.intValue }
        fullyCharged = (registry["FullyCharged"] as? Bool) ?? false
        cycleCount = int("CycleCount")
        let design = int("DesignCapacity")
        let full = int("NominalChargeCapacity") ?? int("AppleRawMaxCapacity")
        if let design, let full, design > 100, full > 100 {
            healthPercent = min(100, Int((Double(full) / Double(design) * 100).rounded()))
        }
        if let adapter = registry["AdapterDetails"] as? [String: Any], let watts = (adapter["Watts"] as? NSNumber)?.intValue, watts > 0 {
            adapterWatts = watts
        }
    }

    static func readRegistry() -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = properties?.takeRetainedValue() as? [String: Any] else { return nil }
        return dictionary
    }

    static func duration(minutes: Int) -> String {
        minutes >= 60 ? (minutes % 60 == 0 ? String(localized: "\(minutes / 60) h") : String(localized: "\(minutes / 60) h \(minutes % 60) min")) : String(localized: "\(minutes) min")
    }

    /// One plain sentence for the pane's subtitle.
    func summary(level: Int?, externalPower: Bool) -> String {
        guard level != nil else { return String(localized: "No battery") }
        if externalPower {
            if fullyCharged || level == 100 { return String(localized: "Fully charged") }
            if charging { return minutesToFull.map { String(localized: "Charging · \(Self.duration(minutes: $0)) until full") } ?? String(localized: "Charging") }
            return String(localized: "Plugged in · not charging")
        }
        return minutesToEmpty.map { String(localized: "On battery · \(Self.duration(minutes: $0)) remaining") } ?? String(localized: "On battery")
    }
}
