import CoreKit
import Foundation
import NetworkKit

/// One row of `index.json` from the official registry.
public struct RegistryEntry: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var repo: String
    public var latestVersion: String
    public var downloadURL: URL
    public var sha256: String
    public var publicKey: String
    public var verified: Bool
    public var tags: [String]
    public var stars: Int?

    public init(id: String, name: String, repo: String, latestVersion: String,
                downloadURL: URL, sha256: String, publicKey: String,
                verified: Bool = true, tags: [String] = [], stars: Int? = nil) {
        self.id = id
        self.name = name
        self.repo = repo
        self.latestVersion = latestVersion
        self.downloadURL = downloadURL
        self.sha256 = sha256
        self.publicKey = publicKey
        self.verified = verified
        self.tags = tags
        self.stars = stars
    }
}

public struct GitHubRateLimit: Sendable, Equatable {
    public var limit: Int
    public var remaining: Int
    public var reset: Date?

    public init(limit: Int, remaining: Int, reset: Date? = nil) {
        self.limit = limit
        self.remaining = remaining
        self.reset = reset
    }

    public var isExhausted: Bool { remaining <= 0 }
}

public enum MarketplaceError: LocalizedError, Sendable, Equatable {
    case registryUnavailable(String)
    case malformedIndex(String)
    case checksumMismatch(expected: String, actual: String)
    case signatureInvalid
    case missingSignature
    case rateLimited(reset: Date?)
    case installFailed(String)
    case rollbackFailed(String)

    public var errorDescription: String? {
        switch self {
        case .registryUnavailable(let detail): return "Registry unavailable. \(detail)"
        case .malformedIndex(let detail):       return "Registry index is malformed. \(detail)"
        case .checksumMismatch(let expected, let actual):
            return "Checksum mismatch (expected \(expected.prefix(12))…, got \(actual.prefix(12))…)."
        case .signatureInvalid:                 return "The plugin signature could not be verified."
        case .missingSignature:                 return "The release has no signature asset."
        case .rateLimited(let reset):
            let text = reset.map { DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .short) } ?? "later"
            return "GitHub rate limit reached. Try again \(text)."
        case .installFailed(let detail):        return "Install failed. \(detail)"
        case .rollbackFailed(let detail):       return "Rollback failed. \(detail)"
        }
    }
}

/// Reads registry data with ETag caching, and reports GitHub quota honestly.
public actor RegistryClient {
    public static let officialIndexURL = URL(string: "https://raw.githubusercontent.com/amore-plugins/registry/main/index.json")
    public static let communitySearchURL = URL(string: "https://api.github.com/search/repositories?q=topic:amore-plugin&sort=stars")

    private let http: HTTPClient
    private let logger: AmoreLogger
    private var lastRateLimit: GitHubRateLimit?

    public init(http: HTTPClient, logger: AmoreLogger = AmoreLogger(category: "Marketplace")) {
        self.http = http
        self.logger = logger
    }

    public var rateLimit: GitHubRateLimit? { lastRateLimit }

    public func fetchIndex(url: URL = RegistryClient.officialIndexURL) async throws -> [RegistryEntry] {
        let request = HTTPRequest(url: url, useETag: true)
        let response: HTTPResponse
        do {
            response = try await http.send(request)
        } catch {
            throw MarketplaceError.registryUnavailable(error.localizedDescription)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw MarketplaceError.registryUnavailable("HTTP \(response.statusCode)")
        }
        do {
            return try JSONDecoder().decode([RegistryEntry].self, from: response.data)
        } catch {
            throw MarketplaceError.malformedIndex(error.localizedDescription)
        }
    }

    /// Community search results are always marked unverified.
    public func searchCommunity(_ query: String) async throws -> [RegistryEntry] {
        guard var components = URLComponents(url: RegistryClient.communitySearchURL,
                                             resolvingAgainstBaseURL: true) else {
            throw MarketplaceError.registryUnavailable("bad search url")
        }
        components.queryItems?.append(URLQueryItem(name: "q", value: "topic:amore-plugin \(query)"))
        guard let url = components.url else {
            throw MarketplaceError.registryUnavailable("bad search url")
        }

        let response: HTTPResponse
        do {
            response = try await http.send(HTTPRequest(url: url))
        } catch {
            throw MarketplaceError.registryUnavailable(error.localizedDescription)
        }
        updateRateLimit(from: response.headers)
        if response.statusCode == 403, let limit = lastRateLimit, limit.isExhausted {
            throw MarketplaceError.rateLimited(reset: limit.reset)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw MarketplaceError.registryUnavailable("HTTP \(response.statusCode)")
        }
        return try decodeSearch(response.data)
    }

    private func decodeSearch(_ data: Data) throws -> [RegistryEntry] {
        struct Envelope: Decodable {
            struct Item: Decodable {
                let full_name: String
                let name: String
                let description: String?
                let stargazers_count: Int?
                let html_url: String
            }
            let items: [Item]
        }
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            return envelope.items.compactMap { item in
                guard let url = URL(string: item.html_url) else { return nil }
                return RegistryEntry(
                    id: item.full_name.replacingOccurrences(of: "/", with: "."),
                    name: item.name,
                    repo: item.full_name,
                    latestVersion: "0.0.0",
                    downloadURL: url,
                    sha256: "",
                    publicKey: "",
                    verified: false,
                    tags: ["community"],
                    stars: item.stargazers_count
                )
            }
        } catch {
            throw MarketplaceError.malformedIndex(error.localizedDescription)
        }
    }

    private func updateRateLimit(from headers: [String: String]) {
        func value(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
        guard let limit = value("X-RateLimit-Limit").flatMap(Int.init),
              let remaining = value("X-RateLimit-Remaining").flatMap(Int.init) else { return }
        let reset = value("X-RateLimit-Reset").flatMap(TimeInterval.init).map { Date(timeIntervalSince1970: $0) }
        lastRateLimit = GitHubRateLimit(limit: limit, remaining: remaining, reset: reset)
        logger.debug("github quota \(remaining)/\(limit)")
    }
}