import Foundation
import os

/// How this process was launched. Read once, so feature code never parses launch arguments itself.
enum AppEnvironment {
    /// The DEBUG smoke test renders previews; it must not beep, notify or touch the user's real settings.
    static let isSmokeTest = CommandLine.arguments.contains("--smoke-test")
    /// Unit tests and `swift run` load the code outside an app bundle, where notifications and login items don't apply.
    static let isBundledApp = Bundle.main.bundleURL.pathExtension == "app"
    /// Real alerts (sounds, notifications, charging feedback) only in the bundled app's normal run.
    static var allowsAlerts: Bool { isBundledApp && !isSmokeTest }
    static let smokeSuite = "dk.jonasgandrup.Sense.SmokeTest"
    /// Settings storage: the user's defaults, or a throwaway suite during the smoke test.
    static var defaults: UserDefaults { isSmokeTest ? (UserDefaults(suiteName: smokeSuite) ?? .standard) : .standard }
    /// Feature state that persists (pinned player, shelf, timer). Unit tests get none unless they inject a suite.
    static var persistentDefaults: UserDefaults? { isBundledApp ? defaults : nil }
}

/// Unified logging. View with `log stream --predicate 'subsystem == "dk.jonasgandrup.Sense"'`.
enum Log {
    private static let subsystem = "dk.jonasgandrup.Sense"
    static let media = Logger(subsystem: subsystem, category: "media")
    static let island = Logger(subsystem: subsystem, category: "island")
    static let system = Logger(subsystem: subsystem, category: "system")
    static let calendar = Logger(subsystem: subsystem, category: "calendar")
    static let shelf = Logger(subsystem: subsystem, category: "shelf")
    static let app = Logger(subsystem: subsystem, category: "app")
}
