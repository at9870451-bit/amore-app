import CoreKit
import Foundation

/// Async HTTP client. One actor per app; requests are independent and safe to
/// run concurrently.
public actor HTTPClient {
    public struct RetryPolicy: Sendable {
        public var maxAttempts: Int
        public var baseDelay: TimeInterval
        public var maxDelay: TimeInterval
        public var retryStatusCodes: Set<Int>

        public init(
            maxAttempts: Int = 3,
            baseDelay: TimeInterval = 0.5,
            maxDelay: TimeInterval = 8,
            retryStatusCodes: Set<Int> = [429, 500, 502, 503, 504]
        ) {
            self.maxAttempts = max(1, maxAttempts)
            self.baseDelay = baseDelay
            self.maxDelay = maxDelay
            self.retryStatusCodes = retryStatusCodes
        }
    }

    private let session: URLSession
    private let cache: any HTTPCache
    private let clock: any AmoreClock
    private let policy: RetryPolicy
    private let logger: AmoreLogger

    public init(
        session: URLSession = .shared,
        cache: any HTTPCache = DiskHTTPCache(),
        clock: any AmoreClock = SystemClock(),
        policy: RetryPolicy = RetryPolicy(),
        logger: AmoreLogger = AmoreLogger(category: "NetworkKit")
    ) {
        self.session = session
        self.cache = cache
        self.clock = clock
        self.policy = policy
        self.logger = logger
    }

    // MARK: - Request

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var attempt = 1
        var lastError: NetworkError = .invalidResponse

        while attempt <= policy.maxAttempts {
            if Task.isCancelled { throw NetworkError.cancelled }

            do {
                let cached = request.useETag ? try await cache.entry(for: request.cacheKey) : nil
                var urlRequest = URLRequest(url: request.url)
                urlRequest.httpMethod = request.method
                urlRequest.timeoutInterval = request.timeout
                urlRequest.httpBody = request.body
                for (name, value) in request.headers {
                    urlRequest.setValue(value, forHTTPHeaderField: name)
                }
                if let cached, request.useETag {
                    urlRequest.setValue(cached.etag, forHTTPHeaderField: "If-None-Match")
                }

                let (data, response) = try await session.data(for: urlRequest)
                guard let http = response as? HTTPURLResponse else {
                    throw NetworkError.invalidResponse
                }
                let headers = Self.headerDictionary(http)

                if http.statusCode == 304, let cached {
                    logger.debug("304 served from cache \(request.url.path)")
                    return HTTPResponse(data: cached.data, statusCode: 304,
                                        headers: headers, fromCache: true)
                }

                if policy.retryStatusCodes.contains(http.statusCode),
                   attempt < policy.maxAttempts {
                    lastError = .httpStatus(code: http.statusCode,
                                            body: String(decoding: data, as: UTF8.self))
                    try await backoff(attempt: attempt, response: http)
                    attempt += 1
                    continue
                }

                guard (200..<300).contains(http.statusCode) || http.statusCode == 304 else {
                    throw NetworkError.httpStatus(code: http.statusCode,
                                                  body: String(decoding: data, as: UTF8.self))
                }

                if request.useETag, let etag = http.value(forHTTPHeaderField: "ETag") {
                    try? await cache.store(HTTPCacheEntry(etag: etag, data: data),
                                           for: request.cacheKey)
                }
                return HTTPResponse(data: data, statusCode: http.statusCode,
                                    headers: headers, fromCache: false)
            } catch let error as NetworkError {
                lastError = error
                guard error.isRetryable, attempt < policy.maxAttempts else { throw error }
                try await backoff(attempt: attempt, response: nil)
                attempt += 1
            } catch let error as URLError {
                if error.code == .cancelled { throw NetworkError.cancelled }
                lastError = error.code == .timedOut ? .timeout : .transport(error.localizedDescription)
                guard attempt < policy.maxAttempts else { throw lastError }
                try await backoff(attempt: attempt, response: nil)
                attempt += 1
            }
        }
        throw lastError
    }

    // MARK: - Download

    /// Streams a download as chunks. Cancelling the consuming task cancels the
    /// underlying URLSession task.
    public nonisolated func download(
        _ url: URL,
        headers: [String: String] = [:]
    ) -> AsyncThrowingStream<DownloadProgress, Error> {
        let session = self.session
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: url)
                    for (name, value) in headers {
                        request.setValue(value, forHTTPHeaderField: name)
                    }
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw NetworkError.invalidResponse
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        throw NetworkError.httpStatus(code: http.statusCode, body: "")
                    }
                    let total = http.expectedContentLength > 0 ? http.expectedContentLength : nil

                    var buffer = Data()
                    buffer.reserveCapacity(64 * 1024)
                    var received: Int64 = 0
                    for try await byte in bytes {
                        buffer.append(byte)
                        received += 1
                        if buffer.count >= 64 * 1024 {
                            continuation.yield(DownloadProgress(bytesReceived: received,
                                                                totalBytes: total, data: buffer))
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    continuation.yield(DownloadProgress(bytesReceived: received,
                                                        totalBytes: total, data: buffer))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Streaming

    /// Raw byte stream for an arbitrary request (used by SSE/LLM clients).
    /// Bytes arrive as they are received; cancelling the consumer cancels the
    /// underlying task.
    public nonisolated func byteStream(
        _ request: HTTPRequest
    ) -> AsyncThrowingStream<Data, Error> {
        let session = self.session
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var urlRequest = URLRequest(url: request.url)
                    urlRequest.httpMethod = request.method
                    urlRequest.timeoutInterval = request.timeout
                    urlRequest.httpBody = request.body
                    for (name, value) in request.headers {
                        urlRequest.setValue(value, forHTTPHeaderField: name)
                    }
                    let (bytes, response) = try await session.bytes(for: urlRequest)
                    guard let http = response as? HTTPURLResponse else {
                        throw NetworkError.invalidResponse
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        throw NetworkError.httpStatus(code: http.statusCode, body: "")
                    }
                    var buffer = Data()
                    buffer.reserveCapacity(4096)
                    for try await byte in bytes {
                        buffer.append(byte)
                        if buffer.count >= 2048 {
                            continuation.yield(buffer)
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    if !buffer.isEmpty { continuation.yield(buffer) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Helpers

    private func backoff(attempt: Int, response: HTTPURLResponse?) async throws {
        if let retryAfter = response?.value(forHTTPHeaderField: "Retry-After"),
           let seconds = Self.retryAfterSeconds(retryAfter) {
            try await clock.sleep(seconds: min(seconds, policy.maxDelay))
            return
        }
        let exponential = policy.baseDelay * pow(2, Double(attempt - 1))
        try await clock.sleep(seconds: min(exponential, policy.maxDelay))
    }

    static func retryAfterSeconds(_ value: String) -> TimeInterval? {
        if let seconds = TimeInterval(value.trimmingCharacters(in: .whitespaces)) {
            return max(0, seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }

    static func headerDictionary(_ response: HTTPURLResponse) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, let value = value as? String {
                result[key] = value
            }
        }
        return result
    }
}