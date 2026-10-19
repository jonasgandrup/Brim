import SwiftUI

/// All island tools share the same icon, title baseline and trailing action row.
struct IslandPaneHeader<Actions: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var actions: () -> Actions
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 18, height: 20)
            Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Spacer(minLength: 8)
            HStack(spacing: 10, content: actions)
                .font(.system(size: 10)).buttonStyle(.plain)
        }
        .foregroundStyle(.white.opacity(0.75))
        .frame(height: 24)
    }
}
