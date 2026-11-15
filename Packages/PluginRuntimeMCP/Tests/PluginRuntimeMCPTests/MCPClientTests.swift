import Foundation
import Testing

@testable import PluginRuntimeMCP

@Suite("MCP decoding")
struct MCPDecodingTests {
    @Test("plain JSON-RPC result decodes")
    func plainResult() throws {
        let json = #"{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"echo","description":"d","inputSchema":{"type":"object"}}]}}"#
        let payload = try MCPClient.decode(Data(json.utf8))
        let tools = payload["tools"] as? [[String: Any]]
        #expect(tools?.first?["name"] as? String == "echo")
    }

    @Test("SSE-framed POST response decodes")
    func sseFramed() throws {
        let body = """
        event: message
        data: {"jsonrpc":"2.0","id":2,"result":{"tools":[]}}

        """
        let payload = try MCPClient.decode(Data(body.utf8))
        #expect(payload["tools"] is [[String: Any]])
    }

    @Test("JSON-RPC error becomes MCPError.rpc")
    func rpcError() {
        let json = #"{"jsonrpc":"2.0","id":3,"error":{"code":-32601,"message":"method not found"}}"#
        #expect(throws: MCPError.rpc(code: -32601, message: "method not found")) {
            _ = try MCPClient.decode(Data(json.utf8))
        }
    }

    @Test("text content blocks concatenate")
    func contentText() {
        let content: [[String: Any]] = [
            ["type": "text", "text": "line one"],
            ["type": "image", "data": "…"],
            ["type": "text", "text": "line two"]
        ]
        #expect(MCPClient.text(fromContent: content) == "line one\nline two")
        #expect(MCPClient.text(fromContent: nil) == "")
    }

    @Test("garbage payload is rejected, not silently empty")
    func garbage() {
        #expect(throws: MCPError.self) {
            _ = try MCPClient.decode(Data("<html>nope</html>".utf8))
        }
    }
}