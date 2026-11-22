import Foundation
import CoreAudio

/// A connected Bluetooth accessory that reports its battery: AirPods (each bud and the case),
/// headphones, and Magic Keyboard, Mouse and Trackpad.
struct BluetoothDevice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let kind: String
    var main: Int?
    var left: Int?
    var right: Int?
    var batteryCase: Int?
    /// The level that matters most: the emptier bud for AirPods, otherwise the device itself.
    var level: Int? { [left, right].compactMap { $0 }.min() ?? main ?? batteryCase }
    var symbol: String {
        let lower = name.lowercased()
        if lower.contains("airpods max") { return "airpods.max" }
        if lower.contains("airpods pro") { return "airpods.pro" }
        if lower.contains("airpods") { return "airpods" }
        if lower.contains("beats") || kind == "Headphones" { return "headphones" }
        if kind == "Keyboard" || lower.contains("keyboard") { return "keyboard" }
        if lower.contains("trackpad") { return "rectangle.and.hand.point.up.left" }
        if kind == "Mouse" || lower.contains("mouse") { return "magicmouse" }
        return "wave.3.right"
    }
}

enum BluetoothReport {
    /// Reads `system_profiler SPBluetoothDataType -json`: only connected devices that publish a battery level.
    static func parse(_ data: Data) -> [BluetoothDevice] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]] else { return [] }
        var devices: [BluetoothDevice] = []
        for controller in controllers {
            for entry in (controller["device_connected"] as? [[String: Any]]) ?? [] {
                for (name, value) in entry {
                    guard let info = value as? [String: Any] else { continue }
                    let device = BluetoothDevice(
                        id: (info["device_address"] as? String) ?? name, name: name, kind: (info["device_minorType"] as? String) ?? "",
                        main: percent(info["device_batteryLevelMain"]), left: percent(info["device_batteryLevelLeft"]),
                        right: percent(info["device_batteryLevelRight"]), batteryCase: percent(info["device_batteryLevelCase"]))
                    if device.level != nil { devices.append(device) }
                }
            }
        }
        return devices.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    static func percent(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return (0...100).contains(number.intValue) ? number.intValue : nil }
        guard let text = value as? String, let number = Int(text.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) else { return nil }
        return (0...100).contains(number) ? number : nil
    }
}

/// Battery levels come from System Information's own report, which needs no Bluetooth permission.
/// It's read at start and when audio devices change (headphones connecting), never on a timer.
@MainActor @Observable final class BluetoothBatteries {
    private(set) var devices: [BluetoothDevice] = []
    @ObservationIgnored var onConnected: (BluetoothDevice) -> Void = { _ in }
    @ObservationIgnored var reader: @Sendable () async -> Data? = {
        let result = await ProcessRunner.run("/usr/sbin/system_profiler", arguments: ["SPBluetoothDataType", "-json"], timeout: 10)
        return result.succeeded ? result.output : nil
    }
    private var started = false
    private var refreshTask: Task<Void, Never>?
    private var known: Set<String>?
    private var listener: AudioObjectPropertyListenerBlock?

    /// Read once at start, then when an audio accessory connects: that's the moment the island shows its levels,
    /// so nothing runs in between.
    func start() {
        guard !started else { return }
        started = true
        refreshSoon(after: .zero)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // Battery levels show up a moment after an accessory connects.
            Task { @MainActor in self?.refreshSoon(after: .seconds(3)) }
        }
        self.listener = listener
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
    }
    func stop() {
        started = false; refreshTask?.cancel(); refreshTask = nil
        if let listener {
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        }
        listener = nil; devices = []; known = nil
    }
    private func refreshSoon(after delay: Duration) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }
    func refresh() async {
        guard let data = await reader(), started || known == nil else { return }
        apply(BluetoothReport.parse(data))
    }
    func apply(_ next: [BluetoothDevice]) {
        if next != devices { devices = next }
        let ids = Set(next.map(\.id))
        if let known { next.filter { !known.contains($0.id) }.forEach(onConnected) }
        known = ids
    }
}
