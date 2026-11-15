import Foundation

/// One Server-Sent Event.
public struct SSEEvent: Sendable, Equatable {
    public var data: String
    public var event: String?
    public var id: String?
    public var retryMilliseconds: Int?

    public init(data: String, event: String? = nil, id: String? = nil, retryMilliseconds: Int? = nil) {
        self.data = data
        self.event = event
        self.id = id
        self.retryMilliseconds = retryMilliseconds
    }
}

/// Incremental parser. Feed raw bytes as they arrive; it returns every event
/// completed by that chunk. Handles `\r\n`, multi-line `data:`, comments and
/// the `event`/`id`/`retry` fields.
public struct SSEDecoder: Sendable {
    private var buffer = Data()
    private var dataLines: [String] = []
    private var eventName: String?
    private var idValue: String?
    private var retryValue: Int?

    public init() {}

    public mutating func feed(_ chunk: Data) -> [SSEEvent] {
        buffer.append(chunk)
        var events: [SSEEvent] = []
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newlineIndex]
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
            var line = String(decoding: lineData, as: UTF8.self)
            if line.hasSuffix("\r") { line.removeLast() }
            if let event = process(line: line) { events.append(event) }
        }
        return events
    }

    /// Flushes a trailing event that arrived without its terminating blank line.
    public mutating func finish() -> [SSEEvent] {
        var events: [SSEEvent] = []
        if !buffer.isEmpty {
            var line = String(decoding: buffer, as: UTF8.self)
            buffer.removeAll()
            if line.hasSuffix("\r") { line.removeLast() }
            if let event = process(line: line) { events.append(event) }
        }
        if let event = flush() { events.append(event) }
        return events
    }

    private mutating func process(line: String) -> SSEEvent? {
        if line.isEmpty { return flush() }
        if line.hasPrefix(":") { return nil }   // comment / keep-alive

        guard let separator = line.firstIndex(of: ":") else {
            // A bare field name with no colon; ignore unknown ones.
            return nil
        }
        let field = String(line[line.startIndex..<separator])
        var value = String(line[line.index(after: separator)...])
        if value.hasPrefix(" ") { value.removeFirst() }

        switch field {
        case "data":  dataLines.append(value)
        case "event": eventName = value
        case "id":    idValue = value
        case "retry": retryValue = Int(value)
        default:      break
        }
        return nil
    }

    private mutating func flush() -> SSEEvent? {
        guard !dataLines.isEmpty || eventName != nil || idValue != nil else {
            retryValue = nil
            return nil
        }
        let event = SSEEvent(
            data: dataLines.joined(separator: "\n"),
            event: eventName,
            id: idValue,
            retryMilliseconds: retryValue
        )
        dataLines.removeAll()
        eventName = nil
        idValue = nil
        retryValue = nil
        return event
    }
}

public enum SSEParser {
    /// Adapts a chunk stream into an event stream. The source finishing cleanly
    /// flushes any trailing event; an error propagates unchanged.
    public static func events<S: AsyncSequence & Sendable>(
        from source: S
    ) -> AsyncThrowingStream<SSEEvent, Error> where S.Element == Data {
        AsyncThrowingStream { continuation in
            let task = Task {
                var decoder = SSEDecoder()
                do {
                    for try await chunk in source {
                        for event in decoder.feed(chunk) {
                            continuation.yield(event)
                        }
                    }
                    for event in decoder.finish() {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}