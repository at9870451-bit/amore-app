import CoreKit
import Foundation
import Testing

@testable import AgentKit
import LLMKit

// MARK: - Doubles

/// Plays back one scripted event list per `stream` call, in order.
final class ScriptedProvider: LLMProvider, @unchecked Sendable {
    let id = "scripted"
    private let lock = NSLock()
    private var scripts: [[ChatEvent]]

    init(_ scripts: [[ChatEvent]]) { self.scripts = scripts }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        lock.lock()
        let events = scripts.isEmpty ? [] : scripts.removeFirst()
        lock.unlock()
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

/// Records how often it ran; returns a fixed payload.
actor CountingTool: AgentTool {
    nonisolated let name = "get_weather"
    nonisolated let description = "Weather lookup"
    nonisolated let inputSchemaJSON = #"{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}"#
    private(set) var calls = 0

    func execute(argumentsJSON: String) async throws -> String {
        calls += 1
        return "22C sunny"
    }
}

actor SlowTool: AgentTool {
    nonisolated let name = "slow"
    nonisolated let description = "Takes too long"
    nonisolated let inputSchemaJSON = #"{"type":"object","properties":{}}"#

    func execute(argumentsJSON: String) async throws -> String {
        try await Task.sleep(nanoseconds: 1_200_000_000)
        return "late"
    }
}

private func collect(
    _ stream: AsyncThrowingStream<AgentEvent, Error>
) async -> (events: [AgentEvent], error: Error?) {
    var events: [AgentEvent] = []
    do {
        for try await event in stream { events.append(event) }
        return (events, nil)
    } catch {
        return (events, error)
    }
}

// MARK: - Tests

@Suite("AgentLoop")
struct AgentLoopTests {
    @Test("text → tool call → tool result → final answer")
    func fullLoop() async throws {
        let provider = ScriptedProvider([
            [.toolCallComplete(ToolCall(id: "c1", name: "get_weather",
                                        argumentsJSON: #"{"city":"Paris"}"#)),
             .finish(.toolCalls)],
            [.textDelta("It is "), .textDelta("22C and sunny."), .finish(.stop)]
        ])
        let tool = CountingTool()
        let registry = ToolRegistry(initial: [tool])
        let permissions = PermissionGateway(policies: ["get_weather": .alwaysAllow])

        let loop = AgentLoop(provider: provider, tools: registry, permissions: permissions)
        let (events, error) = await collect(loop.events(for: ChatRequest(
            model: "mock",
            messages: [.user("weather in Paris?")]
        )))

        #expect(error == nil)
        #expect(events.contains { if case .toolCallStarted = $0 { return true } else { return false } })
        #expect(events.contains { if case .toolCallFinished(_, let output, _) = $0 { return output == "22C sunny" } else { return false } })
        #expect(events.contains { if case .textDelta(let text) = $0 { return text.contains("sunny") } else { return false } })
        #expect(events.contains { if case .finished(.stop) = $0 { return true } else { return false } })
        let callCount = await tool.calls
        #expect(callCount == 1)
    }

    @Test("denied permission skips execution and tells the model")
    func permissionDenied() async throws {
        let provider = ScriptedProvider([
            [.toolCallComplete(ToolCall(id: "c1", name: "get_weather", argumentsJSON: "{}")),
             .finish(.toolCalls)],
            [.textDelta("I could not check the weather."), .finish(.stop)]
        ])
        let tool = CountingTool()
        let registry = ToolRegistry(initial: [tool])
        let permissions = PermissionGateway(policies: ["get_weather": .deny])

        let loop = AgentLoop(provider: provider, tools: registry, permissions: permissions)
        let (events, error) = await collect(loop.events(for: ChatRequest(
            model: "mock", messages: [.user("weather")]
        )))

        #expect(error == nil)
        #expect(events.contains { if case .toolCallRejected(_, let reason) = $0 { return reason.contains("Blocked") } else { return false } })
        let callCount = await tool.calls
        #expect(callCount == 0)
    }

    @Test("a slow tool times out instead of wedging the run")
    func toolTimeout() async throws {
        let provider = ScriptedProvider([
            [.toolCallComplete(ToolCall(id: "c1", name: "slow", argumentsJSON: "{}")),
             .finish(.toolCalls)],
            [.textDelta("That took too long."), .finish(.stop)]
        ])
        let registry = ToolRegistry(initial: [SlowTool()])
        let permissions = PermissionGateway(policies: ["slow": .alwaysAllow])
        let loop = AgentLoop(
            provider: provider,
            tools: registry,
            permissions: permissions,
            limits: .init(maxRounds: 3, toolTimeoutSeconds: 1)
        )

        let (events, error) = await collect(loop.events(for: ChatRequest(
            model: "mock", messages: [.user("run it")]
        )))

        #expect(error == nil)
        #expect(events.contains { if case .toolCallRejected(_, let reason) = $0 { return reason.lowercased().contains("timed out") || reason.lowercased().contains("did not finish") } else { return false } })
    }

    @Test("exceeding the round limit stops with an error")
    func maxRounds() async throws {
        let callEvent: [ChatEvent] = [
            .toolCallComplete(ToolCall(id: "c1", name: "get_weather", argumentsJSON: "{}")),
            .finish(.toolCalls)
        ]
        let provider = ScriptedProvider([callEvent, callEvent, callEvent])
        let registry = ToolRegistry(initial: [CountingTool()])
        let permissions = PermissionGateway(policies: ["get_weather": .alwaysAllow])
        let loop = AgentLoop(
            provider: provider,
            tools: registry,
            permissions: permissions,
            limits: .init(maxRounds: 2, toolTimeoutSeconds: 5)
        )

        let (events, error) = await collect(loop.events(for: ChatRequest(
            model: "mock", messages: [.user("loop")]
        )))

        #expect(error is AgentError)
        #expect(events.contains { if case .finished(.length) = $0 { return true } else { return false } })
    }
}