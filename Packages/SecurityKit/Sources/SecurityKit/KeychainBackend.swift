import Foundation
import Security

/// Where an item lives. `service` isolates modules (one service per feature),
/// `account` is the key inside that service.
public struct KeychainAddress: Sendable, Hashable {
    public var service: String
    public var account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }
}

public enum KeychainAccessibility: Sendable {
    /// Default: readable after first unlock of this device, never migrated.
    case whenUnlockedThisDeviceOnly
    case whenUnlocked
    case afterFirstUnlockThisDeviceOnly
    case afterFirstUnlock

    var rawValue: CFString {
        switch self {
        case .whenUnlockedThisDeviceOnly:    return kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        case .whenUnlocked:                  return kSecAttrAccessibleWhenUnlocked
        case .afterFirstUnlockThisDeviceOnly: return kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        case .afterFirstUnlock:              return kSecAttrAccessibleAfterFirstUnlock
        }
    }
}

/// Storage abstraction so unit tests never touch the real keychain (which
/// requires a signed host app to work in CI).
public protocol KeychainBackend: Sendable {
    func insert(_ data: Data, at address: KeychainAddress,
                accessibility: KeychainAccessibility) throws
    func update(_ data: Data, at address: KeychainAddress) throws
    func read(at address: KeychainAddress) throws -> Data?
    func remove(at address: KeychainAddress) throws
}

// MARK: - System keychain

public struct SystemKeychainBackend: KeychainBackend {
    public init() {}

    private func baseQuery(_ address: KeychainAddress) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: address.service,
            kSecAttrAccount as String: address.account
        ]
    }

    public func insert(_ data: Data, at address: KeychainAddress,
                       accessibility: KeychainAccessibility) throws {
        var query = baseQuery(address)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = accessibility.rawValue
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            try update(data, at: address)
            return
        }
        guard status == errSecSuccess else {
            throw SecurityError.keychain(status: status)
        }
    }

    public func update(_ data: Data, at address: KeychainAddress) throws {
        let query = baseQuery(address)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard status == errSecSuccess else {
            throw SecurityError.keychain(status: status)
        }
    }

    public func read(at address: KeychainAddress) throws -> Data? {
        var query = baseQuery(address)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw SecurityError.keychain(status: status)
        }
        return item as? Data
    }

    public func remove(at address: KeychainAddress) throws {
        let status = SecItemDelete(baseQuery(address) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecurityError.keychain(status: status)
        }
    }
}

// MARK: - In-memory backend (tests / previews)

public final class InMemoryKeychainBackend: KeychainBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [KeychainAddress: Data] = [:]

    public init() {}

    public func insert(_ data: Data, at address: KeychainAddress,
                       accessibility: KeychainAccessibility) throws {
        lock.lock(); defer { lock.unlock() }
        storage[address] = data
    }

    public func update(_ data: Data, at address: KeychainAddress) throws {
        lock.lock(); defer { lock.unlock() }
        guard storage[address] != nil else { throw SecurityError.itemNotFound }
        storage[address] = data
    }

    public func read(at address: KeychainAddress) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return storage[address]
    }

    public func remove(at address: KeychainAddress) throws {
        lock.lock(); defer { lock.unlock() }
        storage.removeValue(forKey: address)
    }
}