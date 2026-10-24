import Foundation
import CoreGraphics

/// Built-in display brightness changes. macOS has no public brightness API, so this uses the
/// DisplayServices change notification (the one System Settings' slider produces), loaded at runtime.
/// When it's missing, the monitor is simply unavailable.
@MainActor final class BrightnessMonitor {
    private typealias Register = @convention(c) (CGDirectDisplayID, UnsafeRawPointer?, CFNotificationCallback) -> Int32
    private typealias Unregister = @convention(c) (CGDirectDisplayID, UnsafeRawPointer?) -> Int32
    private typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private static let framework = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY | RTLD_LOCAL)
    var onChange: (Double) -> Void = { _ in }
    private var display: CGDirectDisplayID?
    private var gate = BrightnessChangeGate()

    static var available: Bool { framework.map { dlsym($0, "DisplayServicesRegisterForBrightnessChangeNotifications") != nil } ?? false }

    func start() {
        guard display == nil, let framework = Self.framework, let symbol = dlsym(framework, "DisplayServicesRegisterForBrightnessChangeNotifications") else { return }
        // The built-in panel is the one brightness keys control on a laptop.
        let target = Self.builtInDisplay() ?? CGMainDisplayID()
        gate = BrightnessChangeGate(baseline: Self.read(target))
        let observer = Unmanaged.passUnretained(self).toOpaque()
        let result = unsafeBitCast(symbol, to: Register.self)(target, observer) { _, observer, _, _, info in
            // The value arrives as a string on current macOS; accept a number too.
            let raw = (info as NSDictionary?)?["value"]
            guard let observer, let level = (raw as? NSNumber)?.doubleValue ?? (raw as? String).flatMap(Double.init) else { return }
            let pointer = UInt(bitPattern: observer)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let raw = UnsafeRawPointer(bitPattern: pointer) else { return }
                    Unmanaged<BrightnessMonitor>.fromOpaque(raw).takeUnretainedValue().receive(level)
                }
            }
        }
        if result == 0 { display = target } else { Log.system.notice("Brightness notifications unavailable (\(result))") }
    }
    func stop() {
        guard let display, let framework = Self.framework, let symbol = dlsym(framework, "DisplayServicesUnregisterForBrightnessChangeNotifications") else { self.display = nil; return }
        _ = unsafeBitCast(symbol, to: Unregister.self)(display, Unmanaged.passUnretained(self).toOpaque())
        self.display = nil
    }
    private func receive(_ level: Double) {
        guard display != nil, let shown = gate.receive(level, at: ProcessInfo.processInfo.systemUptime) else { return }
        onChange(shown)
    }
    private static func read(_ display: CGDirectDisplayID) -> Double? {
        guard let framework, let symbol = dlsym(framework, "DisplayServicesGetBrightness") else { return nil }
        var value: Float = 0
        return unsafeBitCast(symbol, to: Get.self)(display, &value) == 0 ? Double(value) : nil
    }
    private static func builtInDisplay() -> CGDirectDisplayID? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return nil }
        return ids.first { CGDisplayIsBuiltin($0) != 0 }
    }
}

/// Auto-Brightness nudges the panel in tiny steps all day. Only a deliberate change, a few percent within
/// one quick burst of steps as from the brightness keys, should appear in the island.
struct BrightnessChangeGate {
    private var lastLevel: Double?
    private var burstBase: Double?
    private var lastShown: TimeInterval = -.infinity
    private var lastEvent: TimeInterval = -.infinity
    static let threshold = 0.04
    /// Steps further apart than this start a new burst.
    static let burstGap = 0.8
    init(baseline: Double? = nil) { lastLevel = baseline }
    mutating func receive(_ level: Double, at time: TimeInterval) -> Double? {
        guard level.isFinite else { return nil }
        defer { lastLevel = level; lastEvent = time }
        // While the HUD is already showing, follow every step so the bar tracks the keys smoothly.
        if time - lastShown < 1.2 { lastShown = time; return level }
        if time - lastEvent > Self.burstGap { burstBase = lastLevel ?? level }
        guard let base = burstBase, abs(level - base) >= Self.threshold else { return nil }
        lastShown = time
        return level
    }
}
