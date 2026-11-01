import SwiftUI

extension LocalizedStringKey {
    /// Text that was already translated where it was made (with `String(localized:)`), shown as is.
    static func verbatim(_ text: String) -> LocalizedStringKey { "\(text)" }
}

/// Brim's symbol: the island with three playback bars cut out of it. The menu bar draws the same proportions
/// (`StatusBarController`), and so does the app icon (`scripts/make-icon.swift`).
struct BrimSymbol: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = rect.width / 17
        var path = Path(CGPath(roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil))
        for (index, height) in [3.0, 6, 4].enumerated() {
            path.addRoundedRect(in: CGRect(x: rect.minX + (5.75 + CGFloat(index) * 2.25) * unit, y: rect.midY - height * unit / 2, width: 1.25 * unit, height: height * unit),
                                cornerSize: CGSize(width: 0.625 * unit, height: 0.625 * unit))
        }
        return path
    }
}

struct BrimMark: View {
    var size: CGFloat = 62
    var body: some View {
        BrimSymbol().fill(.black, style: FillStyle(eoFill: true))
            .frame(width: size * 0.74, height: size * 0.74 * 10 / 17)
            .frame(width: size, height: size)
            .background(
                LinearGradient(colors: [Color(red: 0.99, green: 0.99, blue: 1), Color(red: 0.82, green: 0.84, blue: 0.89)], startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous))
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
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
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
    let title: LocalizedStringKey
    var detail: LocalizedStringKey?
    var info: LocalizedStringKey?
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
    let text: LocalizedStringKey
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
