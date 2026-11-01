import SwiftUI

/// The island's few shared values. Everything inside the island picks from these, so radii, fills and motion
/// stay consistent; the island's own open/close spring and the pane cross-fade are tuned separately.
enum IslandStyle {
    /// Buttons, tiles and cards.
    static let smallRadius: CGFloat = 12
    /// Large panels such as the drop zones and the empty shelf.
    static let largeRadius: CGFloat = 18
    /// Resting tiles and tracks.
    static let tileFill = Color.white.opacity(0.07)
    /// Selected or raised elements on a tile.
    static let raisedFill = Color.white.opacity(0.14)
    /// Hairline borders.
    static let hairline = Color.white.opacity(0.1)
    /// Selection, hover and small state changes.
    static let quick = Animation.snappy(duration: 0.18)
    /// Content that changes in place (a new track title, a different symbol).
    static let standard = Animation.smooth(duration: 0.3)
    /// Progress that should move at an even pace.
    static let progress = Animation.linear(duration: 0.25)
}
