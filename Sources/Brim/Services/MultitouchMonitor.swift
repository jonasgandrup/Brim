import AppKit
import Darwin

private typealias ContactCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?, Int32, Double, Int32) -> Void
private typealias DeviceListFunction = @convention(c) () -> Unmanaged<CFArray>?
private typealias ContactRegistration = @convention(c) (UnsafeMutableRawPointer, ContactCallback) -> Void
private typealias DeviceStartFunction = @convention(c) (UnsafeMutableRawPointer, Int32) -> Int32
private typealias DeviceStopFunction = @convention(c) (UnsafeMutableRawPointer) -> Int32
private typealias DeviceCapability = @convention(c) (UnsafeMutableRawPointer) -> Bool

/// How many fingers the system's own desktop gestures (Spaces, Mission Control) take: three, unless
/// three-finger drag or the Trackpad settings leave them to four. Unset keys are the system defaults.
enum SystemGestureFingers {
    static func minimum(threeFingerHorizontal: Int?, threeFingerVertical: Int?, threeFingerDrag: Bool) -> Int {
        !threeFingerDrag && ((threeFingerHorizontal ?? 2) == 2 || (threeFingerVertical ?? 2) == 2) ? 3 : 4
    }
    static func current() -> Int {
        let domain = "com.apple.AppleMultitouchTrackpad" as CFString
        func value(_ key: String) -> Int? { CFPreferencesCopyAppValue(key as CFString, domain) as? Int }
        return minimum(threeFingerHorizontal: value("TrackpadThreeFingerHorizSwipeGesture"),
                       threeFingerVertical: value("TrackpadThreeFingerVertSwipeGesture"),
                       threeFingerDrag: value("TrackpadThreeFingerDrag") == 1)
    }
}

/// A desktop gesture stays latched as fingers lift one by one. Only a full release on the device
/// that started it ends it; another trackpad can't clear the hold.
struct GestureContactLatch {
    var fingers = 3
    private var engagedDevices: Set<UInt> = []
    var active: Bool { !engagedDevices.isEmpty }
    mutating func receive(device: UInt, count: Int32) {
        guard (0...20).contains(count) else { return }
        if count >= fingers { engagedDevices.insert(device) }
        else if count == 0 { engagedDevices.remove(device) }
    }
}

/// Decode only the force field and identity needed to invalidate a tare. The
/// borrowed driver buffer is never retained and touch positions are never read.
struct NativeForceSample: Sendable {
    let grams: Double?
    let touchID: Int32?
    let contactCount: Int
    /// False when single-contact data doesn't look like the layout this decoder expects,
    /// e.g. after a macOS update changes the private structure.
    var plausible = true
    static func decode(_ buffer: UnsafeRawPointer?, count: Int32) -> Self {
        guard count == 1, let buffer else { return Self(grams: nil, touchID: nil, contactCount: Int(count)) }
        let state = buffer.loadUnaligned(fromByteOffset: 20, as: Int32.self)
        let value = Double(buffer.loadUnaligned(fromByteOffset: 52, as: Float.self))
        guard (0...16).contains(state), value.isFinite, abs(value) < 1_000_000 else {
            return Self(grams: nil, touchID: nil, contactCount: Int(count), plausible: false)
        }
        guard (state == 3 || state == 4), (0...5000).contains(value) else {
            return Self(grams: nil, touchID: nil, contactCount: Int(count))
        }
        return Self(grams: value, touchID: buffer.loadUnaligned(fromByteOffset: 16, as: Int32.self), contactCount: 1)
    }
}

/// Runs on the driver's thread for every touch frame, so it does as little as possible and only
/// reaches the main thread when a gesture starts or ends, or for a throttled force sample.
private final class ContactDelivery: @unchecked Sendable {
    static let shared = ContactDelivery()
    private let lock = NSLock()
    private var latch = GestureContactLatch()
    private var gestureHandler: (@Sendable (Bool) -> Void)?
    private var forceHandler: (@Sendable (NativeForceSample) -> Void)?
    private var forceDevice: UInt?
    private var lastForceTime: Double = 0
    func installGestures(fingers: Int, _ handler: (@Sendable (Bool) -> Void)?) {
        lock.withLock { gestureHandler = handler; latch = GestureContactLatch(fingers: fingers) }
    }
    func installForce(device: UInt?, _ handler: (@Sendable (NativeForceSample) -> Void)?) {
        lock.withLock { forceDevice = device; forceHandler = handler; lastForceTime = 0 }
    }
    func receive(device: UInt, buffer: UnsafeRawPointer?, count: Int32, timestamp: Double) {
        guard (0...20).contains(count) else { return }
        lock.lock()
        var change: (@Sendable (Bool) -> Void)?
        if let gestureHandler {
            let previous = latch.active
            latch.receive(device: device, count: count)
            if latch.active != previous { change = gestureHandler }
        }
        let active = latch.active
        var sample: NativeForceSample?
        let force = forceHandler
        if force != nil, device == forceDevice, count != 1 || timestamp - lastForceTime >= 1.0 / 30 || timestamp < lastForceTime {
            sample = NativeForceSample.decode(buffer, count: count); lastForceTime = timestamp
        }
        lock.unlock()
        change?(active)
        if let sample { force?(sample) }
    }
}

private let contactCallback: ContactCallback = { device, buffer, count, timestamp, _ in
    guard let device else { return }
    ContactDelivery.shared.receive(device: UInt(bitPattern: device), buffer: buffer, count: count, timestamp: timestamp)
}

private func performOnMain(_ block: @escaping @Sendable @MainActor () -> Void) {
    let runLoop = CFRunLoopGetMain()
    CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { MainActor.assumeIsolated { block() } }
    CFRunLoopWakeUp(runLoop)
}

/// The trackpads' touch frames, through the private MultitouchSupport framework loaded at runtime. Two
/// readers share it: whether a desktop gesture's fingers are down (for the island), and the built-in
/// trackpad's force (for the scale). Devices are open only while one of them listens; missing symbols
/// or devices leave both unavailable. No event is intercepted or changed.
@MainActor final class MultitouchMonitor {
    static let shared = MultitouchMonitor()
    private var gestureGeneration = 0
    private var forceGeneration = 0
    private var gesturesListening = false
    private var forceListening = false
    private var framework: UnsafeMutableRawPointer?
    private var deviceList: CFArray?
    private var devices: [UnsafeMutableRawPointer] = []
    private var forceDevice: UnsafeMutableRawPointer?
    private var unregister: ContactRegistration?
    private var stopDevice: DeviceStopFunction?
    var forceAvailable: Bool { forceDevice != nil }

    func watchGestures(fingers: Int, onChange: @escaping @MainActor (Bool) -> Void) {
        gesturesListening = true; gestureGeneration += 1
        let session = gestureGeneration
        ContactDelivery.shared.installGestures(fingers: fingers) { [weak self] active in
            performOnMain {
                guard let self, self.gesturesListening, self.gestureGeneration == session else { return }
                onChange(active)
            }
        }
        openDevices()
    }
    func stopGestures() {
        gesturesListening = false; gestureGeneration += 1
        ContactDelivery.shared.installGestures(fingers: 3, nil); closeIfUnused()
    }
    func startForce(onSample: @escaping @MainActor (NativeForceSample) -> Void) -> Bool {
        forceListening = true; forceGeneration += 1
        openDevices()
        let session = forceGeneration
        forceSink = { [weak self] sample in
            performOnMain {
                guard let self, self.forceListening, self.forceGeneration == session else { return }
                onSample(sample)
            }
        }
        installForce()
        return forceAvailable
    }
    func stopForce() {
        forceListening = false; forceGeneration += 1; forceSink = nil
        installForce(); closeIfUnused()
    }
    private var forceSink: (@Sendable (NativeForceSample) -> Void)?
    private func installForce() {
        ContactDelivery.shared.installForce(device: forceSink == nil ? nil : forceDevice.map { UInt(bitPattern: $0) }, forceSink)
    }
    /// Picks up a trackpad connected or removed since listening began. Cheap enough to call on a Space change.
    func refreshDevices() {
        guard gesturesListening || forceListening, let framework, let pointer = dlsym(framework, "MTDeviceCreateList") else { return }
        let count = (unsafeBitCast(pointer, to: DeviceListFunction.self)()?.takeRetainedValue()).map { CFArrayGetCount($0) } ?? 0
        guard count != devices.count else { return }
        closeDevices(); openDevices(); installForce()
    }
    private func openDevices() {
        guard deviceList == nil else { return }
        if framework == nil {
            framework = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY | RTLD_LOCAL)
        }
        guard let framework,
              let makePointer = dlsym(framework, "MTDeviceCreateList"),
              let registerPointer = dlsym(framework, "MTRegisterContactFrameCallback"),
              let unregisterPointer = dlsym(framework, "MTUnregisterContactFrameCallback"),
              let startPointer = dlsym(framework, "MTDeviceStart"),
              let stopPointer = dlsym(framework, "MTDeviceStop") else { return }
        let register = unsafeBitCast(registerPointer, to: ContactRegistration.self)
        let startDevice = unsafeBitCast(startPointer, to: DeviceStartFunction.self)
        unregister = unsafeBitCast(unregisterPointer, to: ContactRegistration.self)
        stopDevice = unsafeBitCast(stopPointer, to: DeviceStopFunction.self)
        guard let list = unsafeBitCast(makePointer, to: DeviceListFunction.self)()?.takeRetainedValue(), CFArrayGetCount(list) > 0 else { return }
        let supportsForce = dlsym(framework, "MTDeviceSupportsForce").map { unsafeBitCast($0, to: DeviceCapability.self) }
        let builtIn = dlsym(framework, "MTDeviceIsBuiltIn").map { unsafeBitCast($0, to: DeviceCapability.self) }
        // The list owns the devices; it stays alive for as long as they're in use.
        deviceList = list
        for index in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list, index) else { continue }
            let device = UnsafeMutableRawPointer(mutating: raw)
            if forceDevice == nil, supportsForce?(device) == true, builtIn?(device) == true { forceDevice = device }
            register(device, contactCallback); _ = startDevice(device, 0)
            devices.append(device)
        }
    }
    private func closeIfUnused() {
        guard !gesturesListening, !forceListening else { return }
        closeDevices()
    }
    private func closeDevices() {
        for device in devices { unregister?(device, contactCallback); _ = stopDevice?(device) }
        devices = []; deviceList = nil; forceDevice = nil
        // Keep the runtime image loaded so an in-flight driver callback stays valid.
    }
}
