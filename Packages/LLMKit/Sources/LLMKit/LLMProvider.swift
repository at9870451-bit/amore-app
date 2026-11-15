import CoreKit
import Foundation

public enum LLMError: LocalizedError, Sendable, Equatable {
    case missingAPIKey(provider: String)
    case invalidConfiguration(String)
    case httpStatus(code: Int, body: String)
    case streamEndedEarly
    case malformedEvent(String)
    case cancelled
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            return "No API key stored for \(provider). Add one in Settings."
        case .invalidConfiguration(let detail):
            return "Invalid provider configuration. \(detail)"
        case .httpStatus(let code, let body):
            let trimmed = body.count > 200 ? String(body.prefix(200)) + "…" : body
            return "The provider returned HTTP \(code). \(trimmed)"
        case .streamEndedEarly:
            return "The stream ended before the model finished."
        case .malformedEvent(let detail):
            return "Unexpected stream payload. \(detail)"
        case .cancelled:
            return "Generation stopped."
        case .transport(let detail):
            return "Could not reach the provider. \(detail)"
        }
    }
}

/// Provider identity and credentials. The API key itself is never stored here —
/// only the keychain account name, so configs can be logged safely.
public struct ProviderConfig: Sendable, Identifiable, Equatable {
    public enum Kind: String, Sendable, Codable {
        case openAI
        case anthropic
        case compatible
    }

    public var id: String
    public var kind: Kind
    public var displayName: String
    public var model: String
    public var baseURL: URL
    public var keychainAccount: String
    public var keychainService: String
    public var defaultMaxTokens: Int

    public init(
        id: String,
        kind: Kind,
        displayName: String,
        model: String,
        baseURL: URL,
        keychainAccount: String,
        keychainService: String = "app.amore.llm",
        defaultMaxTokens: Int = 4096
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.model = model
        self.baseURL = baseURL
        self.keychainAccount = keychainAccount
        self.keychainService = keychainService
        self.defaultMaxTokens = defaultMaxTokens
    }
}

public protocol LLMProvider: Sendable {
    var id: String { get }
    /// Events are delivered in order; any failure ends the stream with an error.
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error>
}

/// Config-driven registry. Holding configs (not sessions) means switching model
/// mid-conversation never rebuilds the network stack.
public actor ProviderRegistry {
    private var configs: [String: ProviderConfig]
    private let http: HTTPClient
    private let keychain: KeychainStore
    private let logger: AmoreLogger

    public init(
        configs: [ProviderConfig] = ProviderRegistry.defaultConfigs,
        http: HTTPClient,
        keychain: KeychainStore,
        logger: AmoreLogger = AmoreLogger(category: "LLMKit")
    ) {
        self.configs = Dictionary(uniqueKeysWithValues: configs.map { ($0.id, $0) })
        self.http = http
        self.keychain = keychain
        self.logger = logger
    }

    public func allConfigs() -> [ProviderConfig] {
        configs.values.sorted { $0.displayName < $1.displayName }
    }

    public func config(id: String) -> ProviderConfig? { configs[id] }

    public func upsert(_ config: ProviderConfig) { configs[config.id] = config }

    public func remove(id: String) { configs.removeValue(forKey: id) }

    /// Builds the provider for a config, reading the key lazily at request time.
    public func provider(for config: ProviderConfig) -> any LLMProvider {
        switch config.kind {
        case .openAI:
            return OpenAIProvider(config: config, http: http, keychain: keychain)
        case .anthropic:
            return AnthropicProvider(config: config, http: http, keychain: keychain)
        case .compatible:
            return OpenAICompatibleProvider(config: config, http: http, keychain: keychain)
        }
    }

    public func provider(id: String) throws -> any LLMProvider {
        guard let config = configs[id] else {
            throw LLMError.invalidConfiguration("unknown provider id \(id)")
        }
        return provider(for: config)
    }

    /// Never force-unwraps: a malformed constant degrades to a harmless file URL.
    static func url(_ string: String) -> URL {
        URL(string: string) ?? URL(fileURLWithPath: "/")
    }

    public static let defaultConfigs: [ProviderConfig] = [
        ProviderConfig(
            id: "openai-gpt",
            kind: .openAI,
            displayName: "OpenAI",
            model: "gpt-4o-mini",
            baseURL: Self.url("https://api.openai.com"),
            keychainAccount: "openai"
        ),
        ProviderConfig(
            id: "anthropic-claude",
            kind: .anthropic,
            displayName: "Anthropic",
            model: "claude-sonnet-4-20250514",
            baseURL: Self.url("https://api.anthropic.com"),
            keychainAccount: "anthropic"
        ),
        ProviderConfig(
            id: "ollama-local",
            kind: .compatible,
            displayName: "Ollama (local)",
            model: "llama3.1",
            baseURL: Self.url("http://127.0.0.1:11434"),
            keychainAccount: "ollama"
        )
    ]
}