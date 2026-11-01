import Foundation
import CoreAudio
import CoreMediaIO

/// Notices when any app turns on the camera or microphone, using the same public "running somewhere"
/// properties macOS uses for its menu-bar privacy dot. No permission is needed, and nothing is captured:
/// Brim only learns *that* a device is in use, never what it records or which app is using it.
@MainActor @Observable final class SensorActivity {
    private(set) var camera = false
    private(set) var microphone = false
    var active: Bool { camera || microphone }
    @ObservationIgnored var onChange: (_ camera: Bool, _ microphone: Bool) -> Void = { _, _ in }
    private var audioListener: AudioObjectPropertyListenerBlock?
    private var cameraListener: CMIOObjectPropertyListenerBlock?
    private var watchedAudio: [AudioObjectID] = []
    private var watchedCameras: [CMIOObjectID] = []
    private var poll: Task<Void, Never>?
    private(set) var running = false

    func start() {
        guard !running else { return }
        running = true
        let audio: AudioObjectPropertyListenerBlock = { [weak self] _, _ in Task { @MainActor in self?.devicesChanged() } }
        let video: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in Task { @MainActor in self?.devicesChanged() } }
        audioListener = audio; cameraListener = video
        var devices = Self.audioAddress(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devices, .main, audio)
        var cameras = Self.cameraAddress(CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))
        CMIOObjectAddPropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &cameras, .main, video)
        devicesChanged()
    }
    func stop() {
        guard running else { return }
        running = false
        poll?.cancel(); poll = nil
        unwatchDevices()
        if let audioListener {
            var devices = Self.audioAddress(kAudioHardwarePropertyDevices)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devices, .main, audioListener)
        }
        if let cameraListener {
            var cameras = Self.cameraAddress(CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))
            CMIOObjectRemovePropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &cameras, .main, cameraListener)
        }
        audioListener = nil; cameraListener = nil
        if camera || microphone { camera = false; microphone = false; onChange(false, false) }
    }

    /// Device lists change when headsets or cameras connect; re-attach the per-device listeners.
    private func devicesChanged() {
        guard running else { return }
        unwatchDevices()
        watchedAudio = Self.audioDevices().filter { Self.hasInput($0) }
        watchedCameras = Self.cameraDevices()
        for device in watchedAudio {
            var address = Self.audioAddress(kAudioDevicePropertyDeviceIsRunningSomewhere)
            if let audioListener { AudioObjectAddPropertyListenerBlock(device, &address, .main, audioListener) }
        }
        for device in watchedCameras {
            var address = Self.cameraAddress(CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere))
            if let cameraListener { CMIOObjectAddPropertyListenerBlock(device, &address, .main, cameraListener) }
        }
        evaluate()
    }
    private func unwatchDevices() {
        for device in watchedAudio {
            var address = Self.audioAddress(kAudioDevicePropertyDeviceIsRunningSomewhere)
            if let audioListener { AudioObjectRemovePropertyListenerBlock(device, &address, .main, audioListener) }
        }
        for device in watchedCameras {
            var address = Self.cameraAddress(CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere))
            if let cameraListener { CMIOObjectRemovePropertyListenerBlock(device, &address, .main, cameraListener) }
        }
        watchedAudio = []; watchedCameras = []
    }
    private func evaluate() {
        let nextCamera = watchedCameras.contains { Self.cameraRunning($0) }
        let anyInputDevice = watchedAudio.contains { Self.audioRunning($0) }
        let nextMicrophone = anyInputDevice && Self.microphoneInUse(devices: watchedAudio)
        // A headset that is already playing audio reports "running" before its microphone starts;
        // check again gently while any input-capable device is busy.
        if anyInputDevice, poll == nil {
            poll = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    self?.evaluate()
                }
            }
        } else if !anyInputDevice { poll?.cancel(); poll = nil }
        guard nextCamera != camera || nextMicrophone != microphone else { return }
        camera = nextCamera; microphone = nextMicrophone
        onChange(camera, microphone)
    }

    /// macOS 14.2+ reports per-process input, which is exact. Earlier systems fall back to input-only devices.
    private static func microphoneInUse(devices: [AudioObjectID]) -> Bool {
        if #available(macOS 14.2, *) {
            let own = getpid()
            return objects(AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyProcessObjectList).contains { process in
                var pid: pid_t = 0
                guard read(process, kAudioProcessPropertyPID, into: &pid), pid != own else { return false }
                var input: UInt32 = 0
                return read(process, kAudioProcessPropertyIsRunningInput, into: &input) && input != 0
            }
        }
        return devices.contains { audioRunning($0) && !hasOutput($0) }
    }

    // MARK: Core Audio and Core Media I/O

    private static func audioAddress(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    private static func cameraAddress(_ selector: CMIOObjectPropertySelector) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: selector, mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }
    private static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, into value: inout T) -> Bool {
        var address = audioAddress(selector)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
    }
    private static func objects(_ object: AudioObjectID, selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = audioAddress(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }
    private static func audioDevices() -> [AudioObjectID] { objects(AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDevices) }
    private static func streamCount(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> UInt32 {
        var address = audioAddress(kAudioDevicePropertyStreams, scope: scope)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr ? size : 0
    }
    private static func hasInput(_ device: AudioObjectID) -> Bool { streamCount(device, scope: kAudioDevicePropertyScopeInput) > 0 }
    private static func hasOutput(_ device: AudioObjectID) -> Bool { streamCount(device, scope: kAudioDevicePropertyScopeOutput) > 0 }
    private static func audioRunning(_ device: AudioObjectID) -> Bool {
        var running: UInt32 = 0
        return read(device, kAudioDevicePropertyDeviceIsRunningSomewhere, into: &running) && running != 0
    }
    private static func cameraDevices() -> [CMIOObjectID] {
        var address = cameraAddress(CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, size, &used, &ids) == noErr else { return [] }
        return ids
    }
    private static func cameraRunning(_ device: CMIOObjectID) -> Bool {
        var address = cameraAddress(CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere))
        var running: UInt32 = 0
        var used: UInt32 = 0
        return CMIOObjectGetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &running) == noErr && running != 0
    }
}
