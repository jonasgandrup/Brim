import SwiftUI
import AppKit

/// Tells a pointer resting on the island from one passing through or brushing its edge on the way to a tab.
/// The rest timer restarts whenever the pointer really moves, and once the island has opened and closed
/// it takes leaving and coming back to open it again.
struct HoverIntent {
    static let dwell = Duration.milliseconds(300)
    static let stillRadius: CGFloat = 10
    private var anchor: CGPoint?
    private var spent = false
    /// True when the rest timer should start over from this point.
    mutating func moved(to point: CGPoint) -> Bool {
        guard !spent else { return false }
        if let anchor, hypot(point.x - anchor.x, point.y - anchor.y) <= Self.stillRadius { return false }
        anchor = point
        return true
    }
    mutating func spend() { anchor = nil; spent = true }
    mutating func left() { anchor = nil; spent = false }
}

enum IslandPresentation: Equatable {
    case hidden, compact, expanded
    static func resolve(expanded: Bool, mediaEnabled: Bool, playing: Bool, hasSource: Bool, hasFeedback: Bool) -> Self {
        if expanded { return .expanded }
        return hasFeedback || (mediaEnabled && playing && hasSource) ? .compact : .hidden
    }
}

/// Why the island is tucked into the camera: the desktop is sliding or zooming under it (a system gesture,
/// Mission Control), or Brim's switcher is up. Scrolling and swiping inside apps never count.
enum IslandAwayReason: Hashable {
    case desktopMoving, switcher
}

/// Where the island is in tucking into the camera and growing back out. One value instead of separate flags,
/// so "tucked" and "preparing" can never both be true.
enum DesktopTransitionPhase: Equatable {
    /// Normal operation.
    case settled
    /// Retracting into the camera, then out of sight; the window leaves once the island is in.
    case tucked
    /// Still tucked; SwiftUI lays out the compact island before it grows back out.
    case preparing
    /// Visible again at camera size; the grow-out spring runs once surface animations resume.
    case revealing
}

/// A brief compact-only readout, like the iPhone's volume indicator: an icon on one side, a level on the other.
struct IslandHUD: Equatable {
    var symbol: String
    var tint: Color = .white
    var label: String
    /// Draws a battery and its percentage instead of the symbol.
    var battery: Int?
    var charging = false
    /// What VoiceOver says.
    var announcement: String { battery.map { String(localized: "\(label), \($0)%") } ?? label }
}

/// Trackpad gestures on the compact island, in the direction the fingers move whatever the scrolling setting.
/// A swipe hides what's on the island, as on iPhone, until something it wasn't showing arrives. What was hidden
/// may come and go without bringing the island back; once nothing is left, the next thing to start shows as usual.
struct ActivityDismissal: Equatable {
    private var hidden: Set<String>?
    var active: Bool { hidden != nil }
    mutating func dismiss(_ current: Set<String>) { hidden = current }
    mutating func update(_ current: Set<String>) {
        guard let hidden else { return }
        if current.isEmpty || !current.isSubset(of: hidden) { self.hidden = nil }
    }
    mutating func reset() { hidden = nil }
}

/// Like a tap on iPhone, a click goes to the app that's playing, and hovering is the long press that opens the island.
/// With hover turned off, a click is the only way in, so it keeps opening the island.
enum IslandClick {
    static func opensApp(tab: IslandTab, hoverOpensIsland: Bool, hasPlayer: Bool) -> Bool {
        tab == .music && hoverOpensIsland && hasPlayer
    }
}

enum IslandGesture {
    /// Natural scrolling flips the deltas; this undoes that so "up" and "left" mean the fingers.
    static func fingers(dx: CGFloat, dy: CGFloat, inverted: Bool) -> (right: CGFloat, up: CGFloat) {
        inverted ? (dx, -dy) : (-dx, dy)
    }
    /// How far a sideways swipe travels before it counts, in either direction.
    static let hideTravel: CGFloat = 50
}
