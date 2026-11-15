import Foundation

public struct HTTPRequest: Sendable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?
    public var timeout: TimeInterval
    /// When true the client sends `If-None-Match` and stores the ETag on 200.
    public var useETag: Bool

    public init(
        url: URL,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: TimeInterval = 30,
        useETag: Bool = false
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeout = timeout
        self.useETag = useETag
    }

    /// Cache identity: same URL + method share one entry.
    public var cacheKey: String {
        "\(method.uppercased()) \(url.absoluteString)"
    }
}

public struct HTTPResponse: Sendable {
    public var data: Data
    public var statusCode: Int
    public var headers: [String: String]
    /// True when this body was served from the on-disk ETag cache (HTTP 304).
    public var fromCache: Bool

    public init(data: Data, statusCode: Int, headers: [String: String], fromCache: Bool = false) {
        self.data = data
        self.statusCode = statusCode
        self.headers = headers
        self.fromCache = fromCache
    }

    public func value(forHeader name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// One chunk of a download. `data` carries the bytes accumulated since the
/// previous element, so a consumer can write them straight to disk.
public struct DownloadProgress: Sendable {
    public var bytesReceived: Int64
    public var totalBytes: Int64?
    public var data: Data

    public init(bytesReceived: Int64, totalBytes: Int64?, data: Data) {
        self.bytesReceived = bytesReceived
        self.totalBytes = totalBytes
        self.data = data
    }

    public var fraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, Double(bytesReceived) / Double(totalBytes))
    }
}

public struct HTTPCacheEntry: Codable, Sendable {
    public var etag: String
    public var data: Data
    public init(etag: String, data: Data) {
        self.etag = etag
        self.data = data
    }
}