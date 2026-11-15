import CoreKit
import Foundation
import LLMKit

/// Assembles what the model sees: system prompt (+ retrieved memories), then as
/// much recent history as the token budget allows.
public struct ContextBudget: Sendable {
    public var maxTokens: Int
    public var keepRecentMessages: Int

    public init(maxTokens: Int = 24_000, keepRecentMessages: Int = 20) {
        self.maxTokens = maxTokens
        self.keepRecentMessages = keepRecentMessages
    }
}

public struct ContextBuilder: Sendable {
    public var budget: ContextBudget

    public init(budget: ContextBudget = ContextBudget()) {
        self.budget = budget
    }

    /// Cheap but conservative: ~4 characters per token for mixed prose/code.
    public static func estimateTokens(_ text: String) -> Int {
        max(1, text.count / 4)
    }

    public func systemMessage(systemPrompt: String, memories: [String]) -> String {
        guard !memories.isEmpty else { return systemPrompt }
        let block = memories.prefix(8).enumerated()
            .map { "- (\($0.offset + 1)) \($0.element)" }
            .joined(separator: "\n")
        return systemPrompt + "\n\nRelevant long-term memory:\n" + block
    }

    /// Drops the oldest turns first; never splits a tool call from its result.
    public func trim(history: [ChatMessage], systemPrompt: String) -> [ChatMessage] {
        let systemCost = Self.estimateTokens(systemPrompt)
        var remaining = max(512, budget.maxTokens - systemCost)
        var kept: [ChatMessage] = []

        for message in history.reversed() {
            if kept.count >= budget.keepRecentMessages { break }
            let cost = Self.estimateTokens(message.content)
            if cost > remaining { break }
            remaining -= cost
            kept.append(message)
        }
        return kept.reversed()
    }

    public func build(
        systemPrompt: String,
        memories: [String] = [],
        history: [ChatMessage]
    ) -> [ChatMessage] {
        let system = systemMessage(systemPrompt: systemPrompt, memories: memories)
        return [ChatMessage.system(system)] + trim(history: history, systemPrompt: system)
    }
}

/// Runs the think → call tools → observe loop and streams the UI-facing events.
public actor AgentLoop {
    public struct Limits: Sendable {
        public var maxRounds: Int
        public var toolTimeoutSeconds: Int

        public init(maxRounds: Int = 10, toolTimeoutSeconds: Int = 30) {
            self.maxRounds = maxRounds
            self.toolTimeoutSeconds = toolTimeoutSeconds
        }
    }

    private let provider: any LLMProvider
    private let tools: ToolRegistry
    private let permissions: PermissionGateway
    private let context: ContextBuilder
    private let clock: any AmoreClock
    private let limits: Limits
    private let logger: AmoreLogger

    public init(
        provider: any LLMProvider,
        tools: ToolRegistry,
        permissions: PermissionGateway,
        context: ContextBuilder = ContextBuilder(),
        clock: any AmoreClock = SystemClock(),
        limits: Limits = Limits(),
        logger: AmoreLogger = AmoreLogger(category: "AgentKit")
    ) {
        self.provider = provider
        self.tools = tools
        self.permissions = permissions
        self.context = context
        self.clock = clock
        self.limits = limits
        self.logger = logger
    }

    public nonisolated func events(for request: ChatRequest) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.run(request: request, continuation: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: AgentError.cancelled)
                } catch let error as AgentError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: AgentError.provider(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        request: ChatRequest,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    ) async throws {
        let specs = await tools.specs()
        var messages = context.build(
            systemPrompt: request.systemPrompt ?? "",
            history: request.messages
        )
        continuation.yield(.started)

        var round = 0
        while round < limits.maxRounds {
            if Task.isCancelled { throw AgentError.cancelled }
            round += 1

            var text = ""
            var calls: [ToolCall] = []
            var finishReason: FinishReason = .unknown

            var streamRequest = request
            streamRequest.messages = messages
            streamRequest.tools = specs

            for try await event in provider.stream(streamRequest) {
                switch event {
                case .textDelta(let delta):
                    text += delta
                    continuation.yield(.textDelta(delta))
                case .toolCallComplete(let call):
                    calls.append(call)
                case .toolCallDelta:
                    break
                case .usage(let usage):
                    continuation.yield(.usage(usage))
                case .finish(let reason):
                    finishReason = reason
                }
            }

            if !text.isEmpty || !calls.isEmpty {
                messages.append(.assistant(text, toolCalls: calls))
            }
            continuation.yield(.roundFinished(round))

            if calls.isEmpty {
                continuation.yield(.finished(finishReason))
                return
            }

            for call in calls {
                if Task.isCancelled { throw AgentError.cancelled }
                continuation.yield(.toolCallStarted(call))

                let decision = await permissions.authorize(tool: call.name,
                                                           argumentsJSON: call.argumentsJSON)
                guard case .allowed = decision else {
                    let reason: String
                    if case .denied(let text) = decision { reason = text } else { reason = "Denied." }
                    continuation.yield(.toolCallRejected(call, reason: reason))
                    messages.append(.tool("Rejected by the user: \(reason)", callID: call.id))
                    continue
                }

                guard let tool = await tools.tool(named: call.name) else {
                    throw AgentError.toolNotFound(call.name)
                }

                let started = clock.now
                do {
                    let output = try await execute(tool: tool, call: call)
                    let elapsed = Int(clock.now.timeIntervalSince(started) * 1000)
                    continuation.yield(.toolCallFinished(call, output: output,
                                                         durationMilliseconds: elapsed))
                    messages.append(.tool(output, callID: call.id))
                } catch let error as AgentError {
                    continuation.yield(.toolCallRejected(call,
                                                         reason: error.localizedDescription))
                    messages.append(.tool("Tool error: \(error.localizedDescription)",
                                          callID: call.id))
                }
            }
        }

        logger.warning("agent stopped at round limit \(limits.maxRounds)")
        continuation.yield(.finished(.length))
        throw AgentError.maxRoundsExceeded(limits.maxRounds)
    }

    /// A tool that never returns must not wedge the run: race it against the
    /// clock and cancel the loser.
    private func execute(tool: any AgentTool, call: ToolCall) async throws -> String {
        let seconds = limits.toolTimeoutSeconds
        let name = call.name
        let arguments = call.argumentsJSON

        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await tool.execute(argumentsJSON: arguments) }
            group.addTask { [clock] in
                try await clock.sleep(seconds: Double(seconds))
                throw AgentError.toolTimeout(name: name, seconds: seconds)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw AgentError.toolTimeout(name: name, seconds: seconds)
            }
            return first
        }
    }
}