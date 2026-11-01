import SwiftUI

/// Match the hardware cutout exactly. Glass remains on controls, never the island body.
struct IslandGlass<S: Shape>: View {
    let shape: S
    var body: some View {
        shape.fill(Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 1))
    }
}
