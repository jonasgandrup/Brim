import SwiftUI

/// Battery colors follow iPhone: green while charging, yellow in Low Power Mode, red at 20% and below.
/// The fill and the percentage beside it share the color; everything else in the island stays black and white.
enum BatteryTint {
    static func color(level: Int, charging: Bool, lowPower: Bool) -> Color {
        if charging { return .green }
        if lowPower { return .yellow }
        return level <= 20 ? .red : .white
    }
}

/// A drawn battery, scaled by its height, with a bolt while charging.
struct BatteryGlyph: View {
    var level: Int
    var charging: Bool
    var lowPower = false
    var height: CGFloat = 26
    /// Overrides the usual color, for a warning that fires above the usual red level.
    var tint: Color?
    var body: some View {
        let tint = tint ?? BatteryTint.color(level: level, charging: charging, lowPower: lowPower)
        let width = height * 2
        let inset = height * 0.1
        HStack(spacing: height * 0.05) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height * 0.3, style: .continuous).fill(IslandStyle.raisedFill)
                RoundedRectangle(cornerRadius: height * 0.3, style: .continuous).strokeBorder(.white.opacity(0.35), lineWidth: max(1, height * 0.05))
                RoundedRectangle(cornerRadius: height * 0.2, style: .continuous).fill(tint)
                    .frame(width: max(height * 0.2, (width - inset * 2) * CGFloat(min(100, max(0, level))) / 100))
                    .padding(inset)
                if charging {
                    Image(systemName: "bolt.fill").font(.system(size: height * 0.5, weight: .bold))
                        // Black on the fill, white where a low charge leaves the middle of the battery empty.
                        .foregroundStyle(level >= 60 ? Color.black.opacity(0.75) : .white).frame(maxWidth: .infinity)
                }
            }.frame(width: width, height: height)
            RoundedRectangle(cornerRadius: height * 0.06).fill(.white.opacity(0.35)).frame(width: height * 0.09, height: height * 0.3)
        }
        .accessibilityElement().accessibilityLabel(charging ? "Battery \(level) percent, charging" : "Battery \(level) percent")
    }
}

/// An accessory that just connected: its symbol and a ring per part that reports a level (each bud and the case).
struct AccessoryFeedbackView: View {
    let device: BluetoothDevice
    private var readings: [(label: String, level: Int)] {
        let parts = [(String(localized: "Left"), device.left), (String(localized: "Right"), device.right), (String(localized: "Case"), device.batteryCase)].compactMap { label, level in level.map { (label, $0) } }
        if !parts.isEmpty { return parts }
        return device.main.map { [("", $0)] } ?? []
    }
    var body: some View {
        HStack(spacing: 20) {
            Image(systemName: device.symbol).font(.system(size: 44, weight: .light)).symbolRenderingMode(.hierarchical)
                .frame(width: 70)
            VStack(alignment: .leading, spacing: 10) {
                Text(device.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                HStack(spacing: 14) {
                    ForEach(readings, id: \.label) { reading in
                        VStack(spacing: 4) {
                            LevelRing(level: reading.level)
                            if !reading.label.isEmpty { Text(reading.label).font(.system(size: 11)).foregroundStyle(.secondary) }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(reading.label.isEmpty ? device.name : reading.label) \(reading.level) percent")
                    }
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A battery level as a ring with the number inside, like the Batteries widget.
struct LevelRing: View {
    let level: Int
    var body: some View {
        let tint: Color = level <= 20 ? .red : .green
        ZStack {
            Circle().stroke(.white.opacity(0.15), lineWidth: 3)
            Circle().trim(from: 0, to: Double(min(100, max(0, level))) / 100)
                .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
            Text("\(level)").font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
        }.frame(width: 36, height: 36)
    }
}
