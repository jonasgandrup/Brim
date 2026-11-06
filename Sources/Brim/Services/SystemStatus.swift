import AppKit
import IOKit.ps
import CoreAudio

/// A sound output as Control Center lists it.
struct AudioOutput: Identifiable, Equatable, Sendable {
    let id: AudioDeviceID
    let name: String
    let transport: UInt32
    var symbol: String {
        let lower = name.lowercased()
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            if lower.contains("airpods max") { return "airpods.max" }
            if lower.contains("airpods pro") { return "airpods.pro" }
            if lower.contains("airpods") { return "airpods" }
            return "headphones"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "tv"
        case kAudioDeviceTransportTypeBuiltIn: return lower.contains("headphone") ? "headphones" : "laptopcomputer"
        case kAudioDeviceTransportTypeUSB: return "hifispeaker.fill"
        default: return "speaker.wave.2.fill"
        }
    }
}

@MainActor @Observable
final class SystemStatus {
    var battery: Int?
    var charging = false
    private(set) var details = BatteryDetails()
    /// Every device that can play sound, to name the one sound moves to.
    private(set) var outputs: [AudioOutput] = []
    private(set) var outputID = AudioDeviceID(0)
    @ObservationIgnored var onPowerSample: (PowerSample) -> Void = { _ in }
    /// The system's sound output moved to another device (AirPlay, headphones, a display), not at startup.
    @ObservationIgnored var onOutputChange: (AudioOutput) -> Void = { _ in }
    private var powerSource: CFRunLoopSource?
    var powerNotificationsActive: Bool { powerSource != nil }
    private var timer: Timer?
    private var started = false
    private var lowPowerObserver: NSObjectProtocol?
    /// macOS says when the battery, the charger or Low Power Mode changes, so nothing is read in between. Only if
    /// the power notifications aren't available is the battery checked every 15 seconds instead.
    func start() {
        guard !started else { return }
        started = true
        refresh(); watchDefaultDevice()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            MainActor.assumeIsolated { Unmanaged<SystemStatus>.fromOpaque(context).takeUnretainedValue().refresh() }
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue() {
            powerSource = source; CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        lowPowerObserver = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        guard powerSource == nil else { return }
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 3
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }
    func stop() {
        started = false
        timer?.invalidate(); timer = nil
        if let lowPowerObserver { NotificationCenter.default.removeObserver(lowPowerObserver) }
        lowPowerObserver = nil
        unwatchDefaultDevice()
        if let powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .commonModes) }
        powerSource = nil; onPowerSample = { _ in }; onOutputChange = { _ in }
    }
    func refresh() {
        var level: Int?, onPower = false, isCharging = false
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for source in sources {
                guard let details = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                      let current = details[kIOPSCurrentCapacityKey] as? Int,
                      let maximum = details[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
                level = Int(Double(current) / Double(maximum) * 100)
                onPower = (details[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
                isCharging = (details[kIOPSIsChargingKey] as? Bool) ?? false
                break
            }
        }
        // Assign once so observers never see a momentary "no battery".
        if battery != level { battery = level }
        if charging != onPower { charging = onPower }
        let next = BatteryDetails(charging: isCharging, lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
        if details != next { details = next }
        onPowerSample(PowerSample(percent: level, externalPower: onPower))
    }
    private func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }
    private func read<T>(_ device: AudioObjectID, _ address: AudioObjectPropertyAddress, as value: inout T) -> Bool {
        var address = address
        guard AudioObjectHasProperty(device, &address) else { return false }
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr
    }
    /// Which device plays sound now. When it moves to another (AirPlay, headphones, a display), the island says so.
    private func refreshOutput() {
        var device = AudioDeviceID(0)
        guard read(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDefaultOutputDevice), as: &device), device != 0 else {
            outputID = 0; return
        }
        guard outputID != device else { return }
        let previous = outputID
        outputID = device
        if previous != 0, let output = outputs.first(where: { $0.id == device }) { onOutputChange(output) }
    }
    private func refreshOutputs() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var list = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &list, 0, nil, &size) == noErr, size > 0 else { if !outputs.isEmpty { outputs = [] }; return }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &list, 0, nil, &size, &ids) == noErr else { return }
        let next: [AudioOutput] = ids.compactMap { device in
            var streams = address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &streamSize) == noErr, streamSize > 0 else { return nil }
            var hidden: UInt32 = 0
            if read(device, address(kAudioDevicePropertyIsHidden), as: &hidden), hidden != 0 { return nil }
            var name: Unmanaged<CFString>?
            var nameAddress = address(kAudioObjectPropertyName)
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(device, &nameAddress, 0, nil, &nameSize, &name) == noErr,
                  let title = name?.takeRetainedValue() as String?, !title.isEmpty else { return nil }
            var transport: UInt32 = 0
            _ = read(device, address(kAudioDevicePropertyTransportType), as: &transport)
            return AudioOutput(id: device, name: title, transport: transport)
        }
        if next != outputs { outputs = next }
    }
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private func watchDefaultDevice() {
        guard deviceListener == nil else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refreshOutputs(); self?.refreshOutput() }
        }
        deviceListener = listener
        var a = address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main, listener)
        var devices = address(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devices, .main, listener)
        refreshOutputs(); refreshOutput()
    }
    private func unwatchDefaultDevice() {
        guard let listener = deviceListener else { return }
        var a = address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main, listener)
        var devices = address(kAudioHardwarePropertyDevices)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devices, .main, listener)
        deviceListener = nil
    }
}
