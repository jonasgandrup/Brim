import Foundation
import IOKit
import IOKit.hid

/// Uses public IOKit calls with the community-documented Apple hinge report format.
/// Only the dedicated hinge device is opened; no keyboard, pointer or other sensor is accessed.
actor LidAngleReader {
    private var device: IOHIDDevice?
    func open() -> String? {
        if device != nil { return nil }
        guard let matching = IOServiceMatching("IOHIDDevice") else { return "Hinge sensor unavailable." }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return "Could not inspect hinge hardware." }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            func number(_ key: String) -> Int? {
                (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue
            }
            guard number("VendorID") == 0x05ac, number("ProductID") == 0x8104,
                  number("PrimaryUsagePage") == 0x20, number("PrimaryUsage") == 0x8a,
                  let candidate = IOHIDDeviceCreate(kCFAllocatorDefault, service) else { continue }
            let result = IOHIDDeviceOpen(candidate, IOOptionBits(kIOHIDOptionsTypeNone))
            guard result == kIOReturnSuccess else { return "Hinge sensor access unavailable (\(result))." }
            device = candidate
            return nil
        }
        return "This Mac does not expose a compatible continuous hinge-angle sensor."
    }
    func read() -> Double? {
        guard let device else { return nil }
        var bytes = [UInt8](repeating: 0, count: 8)
        var length = bytes.count
        guard IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &bytes, &length) == kIOReturnSuccess else { return nil }
        return HingeMotion.decode(Array(bytes.prefix(length)))
    }
    func close() {
        if let device { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }
        device = nil
    }
}

struct HingeMotion {
    static func decode(_ report: [UInt8]) -> Double? {
        guard report.count >= 3, report[0] == 1 else { return nil }
        let degrees = Int(report[1]) | (Int(report[2]) << 8)
        guard (0...180).contains(degrees) else { return nil }
        return Double(degrees)
    }
    static func progress(angle: Double, reference: Double) -> Double {
        guard angle.isFinite, reference.isFinite, reference > 20 else { return 0 }
        return min(1, max(0, (reference - angle - 6) / (reference - 18)))
    }
}
