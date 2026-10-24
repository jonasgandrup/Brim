import AppKit
import IOKit.ps
import CoreAudio

@MainActor @Observable
final class SystemStatus {
    var battery: Int?
    var charging = false
    var volume: Double?
    var muted = false
    private(set) var details = BatteryDetails()
    @ObservationIgnored var onPowerSample: (PowerSample) -> Void = { _ in }
    /// Volume or mute changed on the current output device (not on a routine refresh or device switch).
    @ObservationIgnored var onVolumeChange: (_ volume: Double?, _ muted: Bool) -> Void = { _, _ in }
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
        powerSource = nil; onPowerSample = { _ in }; onVolumeChange = { _, _ in }
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
            volume = nil; muted = false; return
        }
        if device != volumeDevice { watchVolume(of: device) }
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
            Task { @MainActor in self?.refreshVolume() }
        }
        deviceListener = listener
        var a = address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main, listener)
    }
    private func unwatchDefaultDevice() {
        guard let listener = deviceListener else { return }
        var a = address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main, listener)
        deviceListener = nil
    }
}
