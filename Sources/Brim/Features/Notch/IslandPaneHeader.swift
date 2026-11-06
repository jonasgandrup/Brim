import SwiftUI

/// The row above each island section: its actions on the right. The tab bar already names the section, so a
/// title appears only when it says something the tab can't.
struct IslandPaneHeader<Actions: View>: View {
    var title: LocalizedStringKey? = nil
    var symbol: String? = nil
    @ViewBuilder var actions: () -> Actions
    var body: some View {
        HStack(spacing: 8) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18, height: 20)
            }
            if let title { Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1) }
            Spacer(minLength: 8)
            HStack(spacing: 10, content: actions)
                .font(.system(size: 10)).buttonStyle(.plain)
        }
        .foregroundStyle(.secondary)
        .frame(height: 24)
    }
}
