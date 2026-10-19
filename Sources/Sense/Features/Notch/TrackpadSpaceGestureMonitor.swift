import AppKit
import Darwin

private typealias ContactCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?, Int32, Double, Int32) -> Void
private typealias DeviceListFunction = @convention(c) () -> Unmanaged<CFArray>?
private typealias ContactRegistration = @convention(c) (UnsafeMutableRawPointer, ContactCallback) -> Void
private typealias DeviceStartFunction = @convention(c) (UnsafeMutableRawPointer, Int32) -> Int32
private typealias DeviceStopFunction = @convention(c) (UnsafeMutableRawPointer) -> Int32

/// A recognized gesture stays latched through 3 → 2 → 1 contacts. Only a full
/// release on its originating device ends it; other devices cannot clear the hold.
struct SpaceContactLatch {
    private var engagedDevices: Set<UInt> = []
    var active: Bool { !engagedDevices.isEmpty }
    mutating func receive(device: UInt, count: Int32) {
        guard (0...20).contains(count) else { return }
        if count >= 3 { engagedDevices.insert(device) }
        else if count == 0 { engagedDevices.remove(device) }
    }
}

/// Decode only the force field and identity needed to invalidate a tare. The
/// borrowed driver buffer is never retained and touch positions are never read.
struct NativeForceSample: Sendable {
    let grams: Double?
    let touchID: Int32?
    let contactCount: Int
    static func decode(_ buffer: UnsafeRawPointer?, count: Int32) -> Self {
        guard count == 1, let buffer else { return Self(grams: nil, touchID: nil, contactCount: Int(count)) }
        let state = buffer.loadUnaligned(fromByteOffset: 20, as: Int32.self)
        let value = Double(buffer.loadUnaligned(fromByteOffset: 52, as: Float.self))
        guard (state == 3 || state == 4), value.isFinite, (0...5000).contains(value) else {
            return Self(grams: nil, touchID: nil, contactCount: Int(count))
        }
        return Self(grams: value, touchID: buffer.loadUnaligned(fromByteOffset: 16, as: Int32.self), contactCount: 1)
    }
}

private final class ContactDelivery: @unchecked Sendable {
    static let shared = ContactDelivery()
    private let lock = NSLock()
    private var contacts = SpaceContactLatch()
    private var handler: (@Sendable (Bool) -> Void)?
    private var forceHandler: (@Sendable (NativeForceSample) -> Void)?
    private var forceDevice: UInt?
    private var lastTime: Double = 0
    func install(_ handler: (@Sendable (Bool) -> Void)?) {
        lock.withLock { self.handler = handler; contacts = SpaceContactLatch() }
    }
    func installForce(device: UInt?, handler: (@Sendable (NativeForceSample) -> Void)?) {
        lock.withLock { forceDevice = device; forceHandler = handler; lastTime = 0 }
    }
    func receive(device: UInt, buffer: UnsafeRawPointer?, count: Int32, timestamp: Double) {
        guard (0...20).contains(count) else { return }
        lock.lock()
        let previous = contacts.active
        contacts.receive(device: device, count: count)
        let next = contacts.active
        let change = previous != next ? handler : nil
        var sample: NativeForceSample?
        let force = forceHandler
        if force != nil, device == forceDevice,
           count != 1 || timestamp - lastTime >= 1.0 / 30 || timestamp < lastTime {
            sample = NativeForceSample.decode(buffer, count: count); lastTime = timestamp
        }
        lock.unlock()
        change?(next)
        if let sample { force?(sample) }
    }
}

private let spaceContactCallback: ContactCallback = { device, buffer, count, timestamp, _ in
    guard let device else { return }
    ContactDelivery.shared.receive(device: UInt(bitPattern: device), buffer: buffer, count: count, timestamp: timestamp)
}

/// System-reserved Space gestures are absent from ordinary event monitors.
/// This optional, dynamically loaded compatibility interface observes only whether
/// three or more contacts are present. Missing symbols/devices leave metadata
/// and Space-notification detection available. No event is intercepted or changed.
@MainActor final class TrackpadSpaceGestureMonitor {
    static let shared = TrackpadSpaceGestureMonitor()
    private var gestureListening = false
    private var forceListening = false
    private var forceGeneration = 0
    private var forceDevice: UInt?
    var forceAvailable: Bool { forceDevice != nil }
    private var framework: UnsafeMutableRawPointer?
    private var deviceList: CFArray?
    private var unregister: ContactRegistration?
    private var stopDevice: DeviceStopFunction?
    private var generation = 0
    private(set) var deviceCount = 0
    var available: Bool { deviceCount > 0 }
    func start(onChange: @escaping @MainActor (Bool) -> Void) {
        gestureListening = true
        openDevices()
        generation += 1
        let session = generation
        ContactDelivery.shared.install { [weak self] active in
            let runLoop = CFRunLoopGetMain()
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
                MainActor.assumeIsolated {
                    guard let self, self.generation == session, self.gestureListening else { return }
                    onChange(active)
                }
            }
            CFRunLoopWakeUp(runLoop)
        }
    }
    func startForce(onSample: @escaping @MainActor (NativeForceSample) -> Void) -> Bool {
        forceListening = true; openDevices(); forceGeneration += 1
        let session = forceGeneration
        ContactDelivery.shared.installForce(device: forceDevice) { [weak self] sample in
            let runLoop = CFRunLoopGetMain()
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
                MainActor.assumeIsolated {
                    guard let self, self.forceListening, self.forceGeneration == session else { return }
                    onSample(sample)
                }
            }
            CFRunLoopWakeUp(runLoop)
        }
        return forceAvailable
    }
    func stopForce() {
        forceListening = false; forceGeneration += 1
        ContactDelivery.shared.installForce(device: nil, handler: nil); closeIfUnused()
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
        let makeList = unsafeBitCast(makePointer, to: DeviceListFunction.self)
        let register = unsafeBitCast(registerPointer, to: ContactRegistration.self)
        let startDevice = unsafeBitCast(startPointer, to: DeviceStartFunction.self)
        unregister = unsafeBitCast(unregisterPointer, to: ContactRegistration.self)
        stopDevice = unsafeBitCast(stopPointer, to: DeviceStopFunction.self)
        guard let list = makeList()?.takeRetainedValue(), CFArrayGetCount(list) > 0 else { return }
        deviceList = list
        for index in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list, index) else { continue }
            let device = UnsafeMutableRawPointer(mutating: raw)
            typealias Capability = @convention(c) (UnsafeMutableRawPointer) -> Bool
            if forceDevice == nil, let force = dlsym(framework, "MTDeviceSupportsForce"), let builtIn = dlsym(framework, "MTDeviceIsBuiltIn"),
               unsafeBitCast(force, to: Capability.self)(device), unsafeBitCast(builtIn, to: Capability.self)(device) {
                forceDevice = UInt(bitPattern: device)
            }
            register(device, spaceContactCallback); _ = startDevice(device, 0)
            deviceCount += 1
        }
    }
    func stop() {
        gestureListening = false; generation += 1; ContactDelivery.shared.install(nil)
        closeIfUnused()
    }
    private func closeIfUnused() {
        guard !gestureListening, !forceListening else { return }
        if let deviceList {
            for index in 0..<CFArrayGetCount(deviceList) {
                guard let raw = CFArrayGetValueAtIndex(deviceList, index) else { continue }
                let device = UnsafeMutableRawPointer(mutating: raw)
                unregister?(device, spaceContactCallback); _ = stopDevice?(device)
            }
        }
        deviceList = nil; deviceCount = 0; forceDevice = nil
        // Keep the runtime image loaded so an in-flight driver callback stays valid.
    }
}
