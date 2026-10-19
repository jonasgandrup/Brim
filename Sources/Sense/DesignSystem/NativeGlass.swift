import SwiftUI

/// The system renders the refraction, highlights and accessibility adaptations.
struct IslandGlass<S: Shape>: View {
    let shape: S
    let expanded: Bool
    var opaqueBody = false
    var body: some View {
        ZStack {
            if opaqueBody {
                // Hardware black must stay indistinguishable from the island during every frame.
                shape.fill(.black)
            } else if #available(macOS 26.0, *) {
                Color.clear.glassEffect(.regular.tint(.black.opacity(0.35)), in: shape)
            } else {
                shape.fill(.ultraThinMaterial)
            }
            shape.fill(.black).opacity(expanded ? 0 : 1)
            if opaqueBody && expanded {
                shape.stroke(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .clear, location: 0.45), .init(color: .white.opacity(0.12), location: 1)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
                    .padding(0.5)
            }
        }
    }
}
