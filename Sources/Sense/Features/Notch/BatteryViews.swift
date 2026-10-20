import SwiftUI

/// Battery colors follow the system: green while charging, yellow in Low Power Mode, red when nearly empty.
enum BatteryTint {
    static func color(level: Int, charging: Bool, lowPower: Bool) -> Color {
        if charging { return Color(red: 0.19, green: 0.82, blue: 0.35) }
        if lowPower { return Color(red: 1.0, green: 0.84, blue: 0.04) }
        return level <= 10 ? Color(red: 1.0, green: 0.27, blue: 0.23) : .white
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
    var body: some View {
        let details = status.details
        VStack(alignment: .leading, spacing: 6) {
            IslandPaneHeader(title: "Battery", symbol: "battery.100") {
                if details.lowPowerMode { Label("Low Power", systemImage: "leaf.fill").font(.system(size: 10)).foregroundStyle(Color(red: 1, green: 0.84, blue: 0.04)) }
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
                HStack(spacing: 8) {
                    if let health = details.healthPercent { stat("Health", "\(health)%") }
                    if let cycles = details.cycleCount { stat("Cycles", "\(cycles)") }
                    if let watts = details.adapterWatts, status.charging { stat("Adapter", "\(watts) W") }
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "powerplug").font(.system(size: 24, weight: .light)).foregroundStyle(.white.opacity(0.35))
                    Text("This Mac has no battery").font(.system(size: 12))
                }.frame(maxWidth: .infinity, minHeight: 95)
            }
        }.foregroundStyle(.white)
    }
    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 13, weight: .medium)).monospacedDigit()
            Text(title).font(.system(size: 9)).foregroundStyle(.white.opacity(0.45))
        }.frame(maxWidth: .infinity).padding(.vertical, 7)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
