import Foundation
import SwiftUI

/// Composition root handed to every feature through the SwiftUI environment.
/// A value type on purpose: passing it across isolation domains is free, and a
/// preview/test build simply constructs a different one.
public struct DependencyContainer: Sendable {
    public var logger: AmoreLogger
    public var clock: any AmoreClock
    public var uuid: any UUIDProviding
    public var enabledFlags: Set<FeatureFlag>

    public init(
        logger: AmoreLogger = AmoreLogger(category: "app"),
        clock: any AmoreClock = SystemClock(),
        uuid: any UUIDProviding = SystemUUIDProvider(),
        enabledFlags: Set<FeatureFlag> = Set(FeatureFlag.allCases.filter(\.defaultEnabled))
    ) {
        self.logger = logger
        self.clock = clock
        self.uuid = uuid
        self.enabledFlags = enabledFlags
    }

    /// Module-scoped logger without mutating the shared container.
    public func logger(_ category: String) -> AmoreLogger {
        AmoreLogger(category: category)
    }

    public func isEnabled(_ flag: FeatureFlag) -> Bool {
        enabledFlags.contains(flag)
    }

    // MARK: - Standard configurations

    public static let live = DependencyContainer()

    public static let preview = DependencyContainer(
        logger: AmoreLogger(category: "preview"),
        clock: SystemClock(),
        uuid: SystemUUIDProvider()
    )

    public static let test = DependencyContainer(
        logger: AmoreLogger(category: "test"),
        clock: FixedClock(),
        uuid: SystemUUIDProvider(),
        enabledFlags: Set(FeatureFlag.allCases)
    )
}

extension EnvironmentValues {
    /// Injected once at the root: `.environment(\.dependencies, .live)`.
    @Entry public var dependencies: DependencyContainer = .live
}