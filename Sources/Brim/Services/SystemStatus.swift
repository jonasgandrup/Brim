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
    var volume: Double?
    var muted = false
    private(set) var details = BatteryDetails()
    /// Every device that can play sound, for the island's output picker.
    private(set) var outputs: [AudioOutput] = []
    private(set) var outputID = AudioDeviceID(0)
    /// False for outputs whose volume is fixed by the device (some HDMI and USB DACs).
    private(set) var volumeSettable = false
    @ObservationIgnored var onPowerSample: (PowerSample) -> Void = { _ in }
    /// Volume or mute changed on the current output device (not on a routine refresh or device switch).
    @ObservationIgnored var onVolumeChange: (_ volume: Double?, _ muted: Bool) -> Void = { _, _ in }
    /// The system's sound output moved to another device (AirPlay, headphones, a display), not at startup.
    @ObservationIgnored var onOutputChange: (AudioOutput) -> Void = { _ in }
    private var powerSource: CFRunLoopSource?
    var powerNotificationsActive: Bool { powerSource != nil }
    private var timer: Timer?
    func start() {
        guard timer == nil else { return }
        refresh(); watchDefaultDevice()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            MainActor.assumeIsolated { Unmanaged<SystemStatus>.fromOpaque(context).takeUnretainedValue().refresh() }
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue() {
            powerSource = source; CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 3
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }
    func stop() {
        timer?.invalidate(); timer = nil
        unwatchVolume(); unwatchDefaultDevice()
        if let powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .commonModes) }
        powerSource = nil; onPowerSample = { _ in }; onVolumeChange = { _, _ in }; onOutputChange = { _ in }
    }
    func refresh() {
        var level: Int?, onPower = false, isCharging = false, toEmpty: Int?, toFull: Int?
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for source in sources {
                guard let details = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                      let current = details[kIOPSCurrentCapacityKey] as? Int,
                      let maximum = details[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
                level = Int(Double(current) / Double(maximum) * 100)
                onPower = (details[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
                isCharging = (details[kIOPSIsChargingKey] as? Bool) ?? false
                toEmpty = details[kIOPSTimeToEmptyKey] as? Int
                toFull = details[kIOPSTimeToFullChargeKey] as? Int
                break
            }
        }
        // Assign once so observers never see a momentary "no battery".
        if battery != level { battery = level }
        if charging != onPower { charging = onPower }
        let next = BatteryDetails(registry: level == nil ? nil : BatteryDetails.readRegistry(), charging: isCharging,
                                  minutesToEmpty: toEmpty, minutesToFull: toFull, lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
        if details != next { details = next }
        onPowerSample(PowerSample(percent: level, externalPower: onPower))
        refreshVolume()
    }
    private var volumeDevice = AudioDeviceID(0)
    private var volumeListener: AudioObjectPropertyListenerBlock?
    private func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }
    private func read<T>(_ device: AudioObjectID, _ address: AudioObjectPropertyAddress, as value: inout T) -> Bool {
        var address = address
        guard AudioObjectHasProperty(device, &address) else { return false }
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr
    }
    private func refreshVolume(announce: Bool = false) {
        var device = AudioDeviceID(0)
        guard read(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDefaultOutputDevice), as: &device), device != 0 else {
            volume = nil; muted = false; outputID = 0; volumeSettable = false; return
        }
        if device != volumeDevice { watchVolume(of: device) }
        if outputID != device {
            let previous = outputID
            outputID = device
            if previous != 0, let output = outputs.first(where: { $0.id == device }) { onOutputChange(output) }
        }
        let settable = volumeElements(device).contains { element in
            var a = address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: element)
            var flag: DarwinBoolean = false
            return AudioObjectHasProperty(device, &a) && AudioObjectIsPropertySettable(device, &a, &flag) == noErr && flag.boolValue
        }
        if volumeSettable != settable { volumeSettable = settable }
        // Many HDMI/USB outputs have no master volume; average the first two channels instead.
        var levels: [Double] = []
        for element in [kAudioObjectPropertyElementMain, 1, 2] as [AudioObjectPropertyElement] {
            var scalar = Float32(0)
            if read(device, address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: element), as: &scalar) {
                levels.append(Double(scalar))
                if element == kAudioObjectPropertyElementMain { break }
            }
        }
        let next = levels.isEmpty ? nil : levels.reduce(0, +) / Double(levels.count)
        var mute: UInt32 = 0
        let isMuted = read(device, address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput), as: &mute) && mute != 0
        let changed = volume != next || muted != isMuted
        if volume != next { volume = next }
        if muted != isMuted { muted = isMuted }
        if announce && changed { onVolumeChange(next, isMuted) }
    }
    private func write<T>(_ device: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: T) -> Bool {
        var address = address
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(device, &address),
              AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else { return false }
        var value = value
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<T>.size), &value) == noErr
    }
    /// The elements that carry volume: the master if the device has one, otherwise the first two channels.
    private func volumeElements(_ device: AudioDeviceID) -> [AudioObjectPropertyElement] {
        var master = address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput)
        var settable: DarwinBoolean = false
        if AudioObjectHasProperty(device, &master), AudioObjectIsPropertySettable(device, &master, &settable) == noErr, settable.boolValue {
            return [kAudioObjectPropertyElementMain]
        }
        return [1, 2]
    }

    // MARK: Quick controls

    /// Sets the current output's volume. Raising it from zero unmutes, as the volume keys do.
    func setVolume(_ level: Double) {
        let device = outputID
        guard device != 0, level.isFinite else { return }
        let scalar = Float32(min(1, max(0, level)))
        var wrote = false
        for element in volumeElements(device) {
            wrote = write(device, address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: element), scalar) || wrote
        }
        if wrote, muted, scalar > 0 { _ = write(device, address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput), UInt32(0)) }
        refreshVolume()
    }
    func setMuted(_ mute: Bool) {
        guard outputID != 0 else { return }
        _ = write(outputID, address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput), UInt32(mute ? 1 : 0))
        refreshVolume()
    }
    /// Makes a device the system's sound output, as choosing it in Control Center does.
    func selectOutput(_ device: AudioDeviceID) {
        guard device != outputID, outputs.contains(where: { $0.id == device }) else { return }
        _ = write(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDefaultOutputDevice), device)
        refreshVolume()
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
    /// Listen for volume/mute changes on the current output device, and for the device itself changing.
    private func watchVolume(of device: AudioDeviceID) {
        unwatchVolume()
        volumeDevice = device
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refreshVolume(announce: true) }
        }
        volumeListener = listener
        for element in [kAudioObjectPropertyElementMain, 1, 2] as [AudioObjectPropertyElement] {
            var a = address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: element)
            AudioObjectAddPropertyListenerBlock(device, &a, .main, listener)
        }
        var mute = address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        AudioObjectAddPropertyListenerBlock(device, &mute, .main, listener)
    }
    private func unwatchVolume() {
        guard let listener = volumeListener, volumeDevice != 0 else { return }
        for element in [kAudioObjectPropertyElementMain, 1, 2] as [AudioObjectPropertyElement] {
            var a = address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: element)
            AudioObjectRemovePropertyListenerBlock(volumeDevice, &a, .main, listener)
        }
        var mute = address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        AudioObjectRemovePropertyListenerBlock(volumeDevice, &mute, .main, listener)
        volumeListener = nil; volumeDevice = 0
    }
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private func watchDefaultDevice() {
        guard deviceListener == nil else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refreshOutputs(); self?.refreshVolume() }
        }
        deviceListener = listener
        var a = address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main, listener)
        var devices = address(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devices, .main, listener)
        refreshOutputs()
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
