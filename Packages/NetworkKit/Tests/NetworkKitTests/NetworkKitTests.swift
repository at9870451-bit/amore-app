import CoreKit
import Foundation
import Testing

@testable import NetworkKit

// MARK: - Mock transport

final class MockURLProtocol: URLProtocol {
    struct Reply {
        var status: Int
        var headers: [String: String]
        var body: Data
        var error: Error?
    }

    final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var queues: [String: [Reply]] = [:]
        private(set) var requests: [URLRequest] = []

        func enqueue(_ replies: [Reply], for url: String) {
            lock.lock(); defer { lock.unlock() }
            queues[url, default: []].append(contentsOf: replies)
        }

        func next(for request: URLRequest) -> Reply? {
            lock.lock(); defer { lock.unlock() }
            requests.append(request)
            guard let url = request.url?.absoluteString else { return nil }
            guard var queue = queues[url], !queue.isEmpty else { return nil }
            let reply = queue.removeFirst()
            queues[url] = queue
            return reply
        }

        func requestsFor(_ url: String) -> [URLRequest] {
            lock.lock(); defer { lock.unlock() }
            return requests.filter { $0.url?.absoluteString == url }
        }
    }

    static let registry = Registry()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let reply = MockURLProtocol.registry.next(for: request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        if let error = reply.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: reply.status,
                httpVersion: "HTTP/1.1",
                headerFields: reply.headers
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !reply.body.isEmpty {
            client?.urlProtocol(self, didLoad: reply.body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func makeClient(
    clock: any AmoreClock,
    cache: any HTTPCache,
    policy: HTTPClient.RetryPolicy = .init()
) -> HTTPClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    let session = URLSession(configuration: configuration)
    return HTTPClient(session: session, cache: cache, clock: clock, policy: policy)
}

// MARK: - Tests

@Suite("HTTPClient", .serialized)
struct HTTPClientTests {
    @Test("retries a 503 and returns the following 200")
    func retryThenSuccess() async throws {
        let url = URL(string: "https://mock.amore.test/retry")!
        MockURLProtocol.registry.enqueue([
            .init(status: 503, headers: [:], body: Data("busy".utf8), error: nil),
            .init(status: 200, headers: [:], body: Data("ok".utf8), error: nil)
        ], for: url.absoluteString)

        let clock = FixedClock()
        let client = makeClient(clock: clock, cache: InMemoryHTTPCache())
        let response = try await client.send(HTTPRequest(url: url))

        #expect(response.statusCode == 200)
        #expect(String(decoding: response.data, as: UTF8.self) == "ok")
        #expect(MockURLProtocol.registry.requestsFor(url.absoluteString).count == 2)
        #expect(clock.now > Date(timeIntervalSince1970: 0))
    }

    @Test("honours Retry-After seconds on 429")
    func retryAfterHeader() async throws {
        let url = URL(string: "https://mock.amore.test/429")!
        MockURLProtocol.registry.enqueue([
            .init(status: 429, headers: ["Retry-After": "2"], body: Data(), error: nil),
            .init(status: 200, headers: [:], body: Data("done".utf8), error: nil)
        ], for: url.absoluteString)

        let clock = FixedClock()
        let client = makeClient(clock: clock, cache: InMemoryHTTPCache())
        _ = try await client.send(HTTPRequest(url: url))

        #expect(clock.now.timeIntervalSince1970 >= 2)
    }

    @Test("second request sends If-None-Match and a 304 serves the cached body")
    func etagCaching() async throws {
        let url = URL(string: "https://mock.amore.test/etag")!
        MockURLProtocol.registry.enqueue([
            .init(status: 200, headers: ["ETag": "\"v1\""], body: Data("payload".utf8), error: nil),
            .init(status: 304, headers: ["ETag": "\"v1\""], body: Data(), error: nil)
        ], for: url.absoluteString)

        let client = makeClient(clock: FixedClock(), cache: InMemoryHTTPCache())
        let request = HTTPRequest(url: url, useETag: true)

        let first = try await client.send(request)
        #expect(first.statusCode == 200)
        #expect(!first.fromCache)

        let second = try await client.send(request)
        #expect(second.statusCode == 304)
        #expect(second.fromCache)
        #expect(String(decoding: second.data, as: UTF8.self) == "payload")

        let sent = MockURLProtocol.registry.requestsFor(url.absoluteString)
        #expect(sent.count == 2)
        #expect(sent.last?.value(forHTTPHeaderField: "If-None-Match") == "\"v1\"")
    }

    @Test("exhausted retries surface the last HTTP error")
    func retriesExhausted() async throws {
        let url = URL(string: "https://mock.amore.test/fail")!
        MockURLProtocol.registry.enqueue([
            .init(status: 500, headers: [:], body: Data("e1".utf8), error: nil),
            .init(status: 500, headers: [:], body: Data("e2".utf8), error: nil)
        ], for: url.absoluteString)

        let client = makeClient(clock: FixedClock(), cache: InMemoryHTTPCache(),
                                policy: .init(maxAttempts: 2))
        await #expect(throws: NetworkError.self) {
            _ = try await client.send(HTTPRequest(url: url))
        }
        #expect(MockURLProtocol.registry.requestsFor(url.absoluteString).count == 2)
    }

    @Test("Retry-After parses both seconds and HTTP dates")
    func retryAfterParsing() {
        #expect(HTTPClient.retryAfterSeconds("3") == 3)
        #expect(HTTPClient.retryAfterSeconds("later") == nil)
        let date = Date().addingTimeInterval(30)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let parsed = HTTPClient.retryAfterSeconds(formatter.string(from: date))
        #expect(parsed != nil)
    }
}

@Suite("SSEDecoder")
struct SSEDecoderTests {
    @Test("reassembles a payload split across chunks")
    func fragmented() {
        var decoder = SSEDecoder()
        #expect(decoder.feed(Data("da".utf8)).isEmpty)
        #expect(decoder.feed(Data("ta: hel".utf8)).isEmpty)
        let events = decoder.feed(Data("lo\n\n".utf8))
        #expect(events.count == 1)
        #expect(events.first?.data == "hello")
    }

    @Test("multi-line data joins with a newline")
    func multiline() {
        var decoder = SSEDecoder()
        let events = decoder.feed(Data("data: line1\ndata: line2\n\n".utf8))
        #expect(events.first?.data == "line1\nline2")
    }

    @Test("event, id and retry fields are captured")
    func fields() {
        var decoder = SSEDecoder()
        let events = decoder.feed(Data("event: delta\nid: 42\nretry: 1500\ndata: {}\n\n".utf8))
        #expect(events.count == 1)
        #expect(events.first?.event == "delta")
        #expect(events.first?.id == "42")
        #expect(events.first?.retryMilliseconds == 1500)
    }

    @Test("comments and keep-alives produce no events")
    func comments() {
        var decoder = SSEDecoder()
        #expect(decoder.feed(Data(": keep-alive\n\n".utf8)).isEmpty)
    }

    @Test("a trailing event without a blank line flushes on finish")
    func finishFlush() {
        var decoder = SSEDecoder()
        #expect(decoder.feed(Data("data: tail".utf8)).isEmpty)
        let events = decoder.finish()
        #expect(events.first?.data == "tail")
    }

    @Test("CRLF line endings parse identically")
    func crlf() {
        var decoder = SSEDecoder()
        let events = decoder.feed(Data("data: windows\r\n\r\n".utf8))
        #expect(events.first?.data == "windows")
    }
}