import Foundation

/// Locks the Mac exactly as Control–Command–Q does: macOS handles the password and Touch ID, and Brim never
/// sees them. The function is private to login.framework, so it's looked up at runtime and needs no permission.
@MainActor
final class LockScreenService {
    private typealias LockNow = @convention(c) () -> Int32
    private static let lockNow: LockNow? = {
        guard let framework = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
              let symbol = dlsym(framework, "SACLockScreenImmediate") else { return nil }
        return unsafeBitCast(symbol, to: LockNow.self)
    }()
    static var available: Bool { lockNow != nil }
    func lock() { _ = Self.lockNow?() }
}
