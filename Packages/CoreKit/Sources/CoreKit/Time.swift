import Foundation

/// Injectable current-time source so stores and tests never call `Date()`
/// directly (which makes time-dependent tests flaky).
public protocol AmoreClock: Sendable {
    var now: Date { get }
    func sleep(seconds: Double) async throws
}

public struct SystemClock: AmoreClock {
    public init() {}

    public var now: Date { Date() }

    public func sleep(seconds: Double) async throws {
        let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

/// Deterministic clock for tests and previews.
public final class FixedClock: AmoreClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var offset: TimeInterval = 0

    public init(_ start: Date = Date(timeIntervalSince1970: 0)) {
        self.current = start
    }

    public var now: Date {
        lock.lock(); defer { lock.unlock() }
        return current.addingTimeInterval(offset)
    }

    public func advance(by seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        offset += seconds
    }

    public func sleep(seconds: Double) async throws {
        advance(by: seconds)
    }
}

/// UUID source, injectable so tests can produce stable identifiers.
public protocol UUIDProviding: Sendable {
    func makeUUID() -> UUID
}

public struct SystemUUIDProvider: UUIDProviding {
    public init() {}
    public func makeUUID() -> UUID { UUID() }
}

public final class CountingUUIDProvider: UUIDProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var counter: Int

    public init(startingAt value: Int = 1) {
        self.counter = value
    }

    public func makeUUID() -> UUID {
        lock.lock()
        let next = counter
        counter += 1
        lock.unlock()
        let suffix = String(format: "%012d", next)
        return UUID(uuidString: "00000000-0000-0000-0000-" + suffix) ?? UUID()
    }
}
