import CoreKit
import Foundation
import NetworkKit
import PluginKit

public enum MCPError: LocalizedError, Sendable, Equatable {
    case notInitialized
    case httpStatus(Int)
    case rpc(code: Int, message: String)
    case malformedResponse(String)
    case missingSession
    case transportsUnavailable

    public var errorDescription: String? {
        switch self {
        case .notInitialized:            return "MCP client is not initialized."
        case .httpStatus(let code):      return "MCP server returned HTTP \(code)."
        case .rpc(let code, let message): return "MCP error \(code): \(message)"
        case .malformedResponse(let d):  return "MCP response is malformed. \(d)"
        case .missingSession:            return "MCP server did not return a session id."
        case .transportsUnavailable:     return "Could not reach the MCP server."
        }
    }
}

public struct MCPToolDescriptor: Sendable, Equatable {
    public var name: String
    public var description: String
    public var inputSchemaJSON: String

    public init(name: String, description: String, inputSchemaJSON: String) {
        self.name = name
        self.description = description
        self.inputSchemaJSON = inputSchemaJSON
    }
}

/// Minimal MCP client: initialize → tools/list → tools/call, over JSON-RPC 2.0
/// carried by Streamable HTTP. One actor per server; the session id is threaded
/// through every request.
public actor MCPClient {
    public let serverURL: URL
    private let http: HTTPClient
    private let tokenProvider: @Sendable () async throws -> String?
    private let logger: AmoreLogger
    private var sessionID: String?
    private var nextID = 1
    private var initialized = false

    public init(serverURL: URL, http: HTTPClient,
                tokenProvider: @escaping @Sendable () async throws -> String?,
                logger: AmoreLogger = AmoreLogger(category: "MCP")) {
        self.serverURL = serverURL
        self.http = http
        self.tokenProvider = tokenProvider
        self.logger = logger
    }

    public var isInitialized: Bool { initialized }

    // MARK: Lifecycle

    public func initialize(protocolVersion: String = "2025-06-18") async throws {
        let params: [String: Any] = [
            "protocolVersion": protocolVersion,
            "capabilities": [String: Any](),
            "clientInfo": ["name": "Amore", "version": "1.0.0"]
        ]
        let response = try await send(method: "initialize", params: params, allowInit: true)
        // The session id arrives in a header, which `send` captures.
        _ = response
        initialized = true
        logger.info("mcp initialized session=\(sessionID == nil ? "none" : "present")")
    }

    public func listTools() async throws -> [MCPToolDescriptor] {
        let response = try await send(method: "tools/list", params: [:])
        guard let tools = response["tools"] as? [[String: Any]] else {
            throw MCPError.malformedResponse("tools is missing")
        }
        return tools.compactMap { item in
            guard let name = item["name"] as? String else { return nil }
            let description = (item["description"] as? String) ?? ""
            let schema = item["inputSchema"] as? [String: Any] ?? [:]
            let schemaData = (try? JSONSerialization.data(withJSONObject: schema)) ?? Data("{}".utf8)
            return MCPToolDescriptor(name: name, description: description,
                                     inputSchemaJSON: String(decoding: schemaData, as: UTF8.self))
        }
    }

    public func callTool(_ name: String, argumentsJSON: String) async throws -> String {
        let arguments = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) ?? [:]
        let response = try await send(method: "tools/call",
                                      params: ["name": name, "arguments": arguments])
        return Self.text(fromContent: response["content"])
    }

    // MARK: Transport

    private func send(method: String, params: [String: Any],
                      allowInit: Bool = false) async throws -> [String: Any] {
        guard initialized || allowInit else { throw MCPError.notInitialized }

        var payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": nextID,
            "method": method,
            "params": params
        ]
        nextID += 1

        var headers: [String: String] = [
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream"
        ]
        if let sessionID { headers["Mcp-Session-Id"] = sessionID }
        // Since SE-0230 `try?` flattens an already-optional result, so this is
        // one level of optional, not two.
        if let token = try? await tokenProvider(), !token.isEmpty {
            headers["Authorization"] = "Bearer \(token)"
        }

        guard JSONSerialization.isValidJSONObject(payload) else {
            throw MCPError.malformedResponse("request is not valid JSON")
        }
        let body = try JSONSerialization.data(withJSONObject: payload)

        let response: HTTPResponse
        do {
            response = try await http.send(HTTPRequest(url: serverURL, method: "POST",
                                                       headers: headers, body: body,
                                                       timeout: 60))
        } catch {
            throw MCPError.transportsUnavailable
        }

        if let session = response.value(forHeader: "Mcp-Session-Id") { sessionID = session }
        guard (200..<300).contains(response.statusCode) else {
            throw MCPError.httpStatus(response.statusCode)
        }
        return try Self.decode(response.data)
    }

    // MARK: Decoding

    /// Accepts both a plain JSON body and an SSE-framed body (some servers
    /// answer a POST with `event: message\ndata: {...}`).
    static func decode(_ data: Data) throws -> [String: Any] {
        if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            return try payload(from: object)
        }
        var decoder = SSEDecoder()
        let events = decoder.feed(data) + decoder.finish()
        for event in events {
            guard let eventData = event.data.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: eventData)) as? [String: Any]
            else { continue }
            return try payload(from: object)
        }
        throw MCPError.malformedResponse("no JSON payload found")
    }

    private static func payload(from object: [String: Any]) throws -> [String: Any] {
        if let error = object["error"] as? [String: Any] {
            let code = (error["code"] as? Int) ?? -1
            let message = (error["message"] as? String) ?? "unknown error"
            throw MCPError.rpc(code: code, message: message)
        }
        return (object["result"] as? [String: Any]) ?? object
    }

    /// MCP returns content blocks; text blocks are concatenated.
    static func text(fromContent content: Any?) -> String {
        guard let blocks = content as? [[String: Any]] else { return "" }
        let parts = blocks.compactMap { block -> String? in
            guard (block["type"] as? String) == "text" else { return nil }
            return block["text"] as? String
        }
        return parts.joined(separator: "\n")
    }
}