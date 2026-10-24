import SwiftUI

/// Battery colors follow the system: green while charging, yellow in Low Power Mode, red when nearly empty.
enum BatteryTint {
    static func color(level: Int, charging: Bool, lowPower: Bool) -> Color {
        if charging { return .green }
        if lowPower { return .yellow }
        return level <= 10 ? .red : .white
    }
}

/// A drawn battery, scaled by its height, with a bolt while charging.
struct BatteryGlyph: View {
    var level: Int
    var charging: Bool
    var lowPower = false
    var height: CGFloat = 26
    var body: some View {
        let tint = BatteryTint.color(level: level, charging: charging, lowPower: lowPower)
        let width = height * 2
        let inset = height * 0.1
        HStack(spacing: height * 0.05) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height * 0.3, style: .continuous).fill(.white.opacity(0.14))
                RoundedRectangle(cornerRadius: height * 0.3, style: .continuous).strokeBorder(.white.opacity(0.35), lineWidth: max(1, height * 0.05))
                RoundedRectangle(cornerRadius: height * 0.2, style: .continuous).fill(tint)
                    .frame(width: max(height * 0.2, (width - inset * 2) * CGFloat(min(100, max(0, level))) / 100))
                    .padding(inset)
                if charging {
                    Image(systemName: "bolt.fill").font(.system(size: height * 0.5, weight: .bold))
                        .foregroundStyle(.black.opacity(0.7)).frame(maxWidth: .infinity)
                }
            }.frame(width: width, height: height)
            RoundedRectangle(cornerRadius: height * 0.06).fill(.white.opacity(0.35)).frame(width: height * 0.09, height: height * 0.3)
        }
        .accessibilityElement().accessibilityLabel("Battery \(level) percent\(charging ? ", charging" : "")")
    }
}

/// The brief expanded content shown when power connects or the battery target is reached.
struct ChargeFeedbackView: View {
    let level: Int
    let charging: Bool
    let title: String
    var body: some View {
        VStack(spacing: 10) {
            BatteryGlyph(level: level, charging: charging, height: 34)
            Text(title).font(.system(size: 17, weight: .medium))
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct BatteryPaneView: View {
    let status: SystemStatus
    var bluetooth: BluetoothBatteries?
    var body: some View {
        let details = status.details
        VStack(alignment: .leading, spacing: 6) {
            IslandPaneHeader(title: "Battery", symbol: "battery.100percent") {
                if details.lowPowerMode { Label("Low Power", systemImage: "leaf.fill").font(.system(size: 10)).foregroundStyle(.yellow) }
            }
            if let level = status.battery {
                HStack(spacing: 18) {
                    BatteryGlyph(level: level, charging: details.charging, lowPower: details.lowPowerMode, height: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(level)%").font(.system(size: 34, weight: .light, design: .rounded)).monospacedDigit().contentTransition(.numericText())
                        Text(details.summary(level: level, externalPower: status.charging))
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }.padding(.top, 4)
                tiles(details: details)
            } else if let devices = bluetooth?.devices, !devices.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) { ForEach(devices) { device($0) } }
                }.padding(.top, 4)
            } else {
                IslandEmptyState(symbol: "powerplug", title: "This Mac has no battery", detail: "Connected AirPods and Magic accessories appear here.", minHeight: 95)
            }
        }.foregroundStyle(.white)
        .onAppear { bluetooth?.refreshIfStale() }
    }
    /// Battery facts first, then each connected accessory, in one row that scrolls if it runs long.
    private func tiles(details: BatteryDetails) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let health = details.healthPercent { stat("Health", "\(health)%") }
                if let cycles = details.cycleCount { stat("Cycles", "\(cycles)") }
                if let watts = details.adapterWatts, status.charging { stat("Adapter", "\(watts) W") }
                ForEach(bluetooth?.devices ?? []) { device($0) }
            }
        }
    }
    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 13, weight: .semibold)).monospacedDigit()
            Text(title).font(.system(size: 9)).foregroundStyle(.white.opacity(0.5))
        }.frame(minWidth: 72).padding(.vertical, 7).padding(.horizontal, 6)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    private func device(_ device: BluetoothDevice) -> some View {
        let level = device.level ?? 0
        return VStack(spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: device.symbol).font(.system(size: 11))
                Text("\(level)%").font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(level <= 20 ? Color.red : .white)
            }
            Text(device.name).font(.system(size: 9)).foregroundStyle(.white.opacity(0.5)).lineLimit(1).truncationMode(.middle)
        }.frame(minWidth: 72, maxWidth: 110).padding(.vertical, 7).padding(.horizontal, 6)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .help(deviceDetail(device))
            .accessibilityElement(children: .combine)
    }
    private func deviceDetail(_ device: BluetoothDevice) -> String {
        var parts: [String] = []
        if let left = device.left { parts.append("Left \(left)%") }
        if let right = device.right { parts.append("Right \(right)%") }
        if let batteryCase = device.batteryCase { parts.append("Case \(batteryCase)%") }
        if parts.isEmpty, let main = device.main { parts.append("\(main)%") }
        return device.name + " · " + parts.joined(separator: " · ")
    }
}
