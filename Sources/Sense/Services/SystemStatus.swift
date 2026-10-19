import AppKit
import IOKit.ps
import CoreAudio

@MainActor @Observable
final class SystemStatus {
    var battery: Int?
    var charging = false
    var volume: Double?
    var muted = false
    private var timer: Timer?
    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer?.tolerance = 3
    }
    func stop() { timer?.invalidate(); timer = nil }
    func refresh() {
        battery = nil
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for source in sources {
                guard let details = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                      let current = details[kIOPSCurrentCapacityKey] as? Int,
                      let maximum = details[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
                battery = Int(Double(current) / Double(maximum) * 100)
                charging = (details[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
                break
            }
        }
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { volume = nil; return }
        address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var scalar = Float32(0)
        size = UInt32(MemoryLayout<Float32>.size)
        volume = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &scalar) == noErr ? Double(scalar) : nil
        var mute: UInt32 = 0
        address.mSelector = kAudioDevicePropertyMute
        size = UInt32(MemoryLayout<UInt32>.size)
        muted = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &mute) == noErr && mute != 0
    }
}
