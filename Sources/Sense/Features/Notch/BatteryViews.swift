import SwiftUI

/// Battery colors follow iPhone: green while charging, yellow in Low Power Mode, red at 20% and below.
/// Only the fill is tinted; the island and its text stay black and white.
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
    var body: some View {
        let tint = BatteryTint.color(level: level, charging: charging, lowPower: lowPower)
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
                        .foregroundStyle(.black.opacity(0.7)).frame(maxWidth: .infinity)
                }
            }.frame(width: width, height: height)
            RoundedRectangle(cornerRadius: height * 0.06).fill(.white.opacity(0.35)).frame(width: height * 0.09, height: height * 0.3)
        }
        .accessibilityElement().accessibilityLabel(charging ? "Battery \(level) percent, charging" : "Battery \(level) percent")
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
            Spacer(minLength: 0)
        }.padding(.horizontal, 10).frame(maxWidth: .infinity, maxHeight: .infinity)
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

/// Battery at a glance, then the controls you reach for most: volume, output and brightness,
/// like Control Center's Sound and Display modules.
struct BatteryPaneView: View {
    let status: SystemStatus
    var bluetooth: BluetoothBatteries?
    var brightness: BrightnessControl?
    var body: some View {
        let details = status.details
        VStack(alignment: .leading, spacing: 7) {
            if let level = status.battery {
                HStack(spacing: 10) {
                    BatteryGlyph(level: level, charging: details.charging, lowPower: details.lowPowerMode, height: 18)
                    Text("\(level)%").font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit().contentTransition(.numericText())
                    Text(details.summary(level: level, externalPower: status.charging))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    if details.lowPowerMode { Image(systemName: "leaf.fill").font(.system(size: 11)).foregroundStyle(.yellow).help("Low Power Mode") }
                }.frame(height: 26)
            }
            QuickControls(status: status, brightness: brightness)
            let devices = bluetooth?.devices ?? []
            if status.battery != nil || !devices.isEmpty { tiles(details: details) }
        }.foregroundStyle(.white)
        .onAppear { bluetooth?.refreshIfStale(); brightness?.refresh() }
    }
    /// Battery facts first, then each connected accessory, in one row that scrolls if it runs long.
    private func tiles(details: BatteryDetails) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let health = details.healthPercent { stat(String(localized: "Health"), "\(health)%") }
                if let cycles = details.cycleCount { stat(String(localized: "Cycles"), "\(cycles)") }
                if let watts = details.adapterWatts, status.charging { stat(String(localized: "Adapter"), "\(watts) W") }
                ForEach(bluetooth?.devices ?? []) { device($0) }
            }
        }
    }
    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 13, weight: .semibold)).monospacedDigit()
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
        }.frame(minWidth: 72).padding(.vertical, 7).padding(.horizontal, 6)
            .background(IslandStyle.tileFill, in: RoundedRectangle(cornerRadius: IslandStyle.smallRadius, style: .continuous))
    }
    private func device(_ device: BluetoothDevice) -> some View {
        let level = device.level ?? 0
        return VStack(spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: device.symbol).font(.system(size: 11))
                Text("\(level)%").font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(level <= 20 ? Color.red : .white)
            }
            Text(device.name).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }.frame(minWidth: 72, maxWidth: 110).padding(.vertical, 7).padding(.horizontal, 6)
            .background(IslandStyle.tileFill, in: RoundedRectangle(cornerRadius: IslandStyle.smallRadius, style: .continuous))
            .help(deviceDetail(device))
            .accessibilityElement(children: .combine)
    }
    private func deviceDetail(_ device: BluetoothDevice) -> String {
        var parts: [String] = []
        if let left = device.left { parts.append(String(localized: "Left \(left)%")) }
        if let right = device.right { parts.append(String(localized: "Right \(right)%")) }
        if let batteryCase = device.batteryCase { parts.append(String(localized: "Case \(batteryCase)%")) }
        if parts.isEmpty, let main = device.main { parts.append("\(main)%") }
        return device.name + " · " + parts.joined(separator: " · ")
    }
}

/// Volume with mute and an output picker, and built-in display brightness. Each row is a capsule slider.
struct QuickControls: View {
    let status: SystemStatus
    var brightness: BrightnessControl?
    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Button { status.setMuted(!status.muted) } label: {
                    Image(systemName: volumeSymbol).font(.system(size: 12, weight: .semibold)).frame(width: 20, height: 20)
                        .contentTransition(.symbolEffect(.replace)).contentShape(Rectangle())
                }.buttonStyle(IslandPressStyle()).help(status.muted ? "Unmute" : "Mute").accessibilityLabel(status.muted ? "Unmute" : "Mute")
                    .disabled(status.outputID == 0)
                if status.volumeSettable, let volume = status.volume {
                    IslandSlider(value: status.muted ? 0 : volume, label: String(localized: "Volume")) { status.setVolume($0) }
                } else {
                    Text(status.outputID == 0 ? "No sound output" : "Volume is set on the device")
                        .font(.system(size: 10)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
                outputMenu
            }
            if let brightness, brightness.available, let level = brightness.level {
                HStack(spacing: 8) {
                    Image(systemName: level < 0.5 ? "sun.min.fill" : "sun.max.fill").font(.system(size: 12, weight: .semibold)).frame(width: 20, height: 20)
                    IslandSlider(value: level, label: String(localized: "Brightness")) { brightness.set($0) }
                    Color.clear.frame(width: 26, height: 20)
                }
            }
        }
    }
    private var volumeSymbol: String {
        let level = status.muted ? 0 : (status.volume ?? 0)
        return status.muted || level == 0 ? "speaker.slash.fill" : level < 0.34 ? "speaker.wave.1.fill" : level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }
    private var outputMenu: some View {
        let current = status.outputs.first { $0.id == status.outputID }
        return Menu {
            Section("Sound Output") {
                ForEach(status.outputs) { output in
                    Button { status.selectOutput(output.id) } label: {
                        Label(output.name, systemImage: output.id == status.outputID ? "checkmark" : output.symbol)
                    }
                }
            }
        } label: {
            Image(systemName: current?.symbol ?? "speaker.wave.2.fill").font(.system(size: 11, weight: .semibold)).frame(width: 18, height: 18)
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(width: 26)
            .disabled(status.outputs.count < 2)
            .help(current.map { "Output: \($0.name)" } ?? "Sound output").accessibilityLabel("Sound output")
    }
}

/// A Control Center–style capsule: the fill is the value, and clicking or dragging anywhere sets it.
struct IslandSlider: View {
    let value: Double
    let label: String
    let onChange: (Double) -> Void
    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            Capsule().fill(IslandStyle.raisedFill)
                .overlay(alignment: .leading) {
                    Capsule().fill(.white).frame(width: max(8, width * min(1, max(0, value))))
                }
                .contentShape(Capsule())
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    onChange(min(1, max(0, drag.location.x / width)))
                })
        }
        .frame(height: 8).padding(.vertical, 6)
        .animation(IslandStyle.quick, value: value)
        .accessibilityElement().accessibilityLabel(label)
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onChange(min(1, value + 0.0625))
            case .decrement: onChange(max(0, value - 0.0625))
            @unknown default: break
            }
        }
    }
}
