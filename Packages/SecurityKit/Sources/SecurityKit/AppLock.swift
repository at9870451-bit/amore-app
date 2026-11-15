import CoreKit
import Foundation

/// App-level Face ID gate. Kept in SecurityKit so both the app and previews can
/// inject the same behaviour; the UI only ever asks `isLocked`.
public actor AppLockController {
    public struct Settings: Sendable {
        public var isEnabled: Bool
        public var idleSecondsBeforeLock: Int

        public init(isEnabled: Bool = false, idleSecondsBeforeLock: Int = 300) {
            self.isEnabled = isEnabled
            self.idleSecondsBeforeLock = max(0, idleSecondsBeforeLock)
        }
    }

    private var settings: Settings
    private var locked: Bool
    private var lastActivity: Date
    private let authenticator: any BiometricAuthenticating
    private let clock: any AmoreClock

    public init(settings: Settings = Settings(),
                authenticator: any BiometricAuthenticating = LocalAuthenticationService(),
                clock: any AmoreClock = SystemClock()) {
        self.settings = settings
        self.authenticator = authenticator
        self.clock = clock
        self.locked = settings.isEnabled
        self.lastActivity = clock.now
    }

    public var isLocked: Bool { locked }

    public func update(settings: Settings) {
        self.settings = settings
        if !settings.isEnabled { locked = false }
    }

    /// Called on any user interaction; starts (or resets) the idle countdown.
    public func noteActivity() {
        lastActivity = clock.now
    }

    /// Called when the app returns to the foreground.
    public func handleForeground() {
        guard settings.isEnabled else { return }
        let idle = clock.now.timeIntervalSince(lastActivity)
        if idle >= Double(settings.idleSecondsBeforeLock) {
            locked = true
        }
    }

    public func handleBackground() {
        guard settings.isEnabled else { return }
        locked = true
    }

    /// Unlocks after a successful biometric check. Returns false when the user
    /// cancelled — the caller keeps showing the lock screen.
    @discardableResult
    public func unlock(reason: String = "Unlock Amore") async throws -> Bool {
        guard settings.isEnabled else {
            locked = false
            return true
        }
        let ok = try await authenticator.authenticate(reason: reason)
        if ok {
            locked = false
            lastActivity = clock.now
        }
        return ok
    }
}