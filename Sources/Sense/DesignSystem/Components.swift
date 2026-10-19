import SwiftUI

struct SenseMark: View {
    var size: CGFloat = 62
    var body: some View {
        Image(systemName: "waveform.path")
            .font(.system(size: size * 0.48, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color(red: 0.12, green: 0.14, blue: 0.15), in: RoundedRectangle(cornerRadius: size * 0.24))
            .overlay(RoundedRectangle(cornerRadius: size * 0.24).strokeBorder(.white.opacity(0.14)))
    }
}

struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.primary.opacity(0.07)))
    }
}
struct SettingRow<Control: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder var control: Control
    var body: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 10)
            control
        }.padding(16)
    }
}
struct FeatureHeader: View {
    let title: String
    let detail: String
    @Binding var enabled: Bool
    var body: some View {
        SettingsCard {
            SettingRow(title: title, detail: detail) {
                Toggle(title, isOn: $enabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
        }
    }
}
struct Footnote: View {
    let text: String
    var symbol = "info.circle"
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).padding(.top, 1)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }.font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3).padding(.horizontal, 4)
    }
}
