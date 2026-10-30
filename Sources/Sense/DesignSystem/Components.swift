import SwiftUI

struct SenseMark: View {
    var size: CGFloat = 62
    var body: some View {
        Image(systemName: "waveform.path")
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(colors: [Color(white: 0.24), Color(white: 0.06)], startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous).strokeBorder(.white.opacity(0.16), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.18), radius: size * 0.06, y: size * 0.03)
            .accessibilityHidden(true)
    }
}

/// The translucent material System Settings uses behind its sidebar.
struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar; view.blendingMode = .behindWindow; view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// A white symbol on a colored rounded square, as in the System Settings sidebar and rows.
struct SettingsIcon: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 20
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.56, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            // A hairline keeps dark tiles (the island's black) visible on a dark sidebar.
            .overlay(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}

/// The large centered icon, title and one-line description at the top of each settings page.
struct SettingsPageHeader: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 8) {
            SettingsIcon(symbol: symbol, tint: tint, size: 54)
                .shadow(color: tint.opacity(0.3), radius: 8, y: 3)
            Text(title).font(.system(size: 20, weight: .bold))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

/// A title with an optional explanatory line beneath it, for use as a Form row's label.
/// Longer explanations sit behind an ⓘ beside the title, so each row reads in a glance.
struct SettingsLabel: View {
    let title: String
    var detail: String?
    var info: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(title)
                if let info {
                    Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(.secondary)
                        .help(info).accessibilityLabel(info)
                }
            }
            if let detail {
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct Footnote: View {
    let text: String
    var symbol = "info.circle"
    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
    }
}
