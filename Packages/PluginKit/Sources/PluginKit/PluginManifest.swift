import Foundation

public struct PluginAuthor: Sendable, Codable, Equatable {
    public var name: String
    public var github: String?
}

public struct PluginToolDefinition: Sendable, Codable, Equatable {
    public var name: String
    public var description: String
    public var inputSchema: [String: JSONValue]
}

public struct PluginSettingDefinition: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable {
        case string, secret, number, boolean, `enum`
    }
    public var key: String
    public var type: Kind
    public var options: [String]?
    public var `default`: JSONValue?
    public var title: String?
}

public struct MCPServerConfig: Sendable, Codable, Equatable {
    public enum Auth: String, Sendable, Codable {
        case none, bearer, oauth
    }
    public var url: URL
    public var auth: Auth
}

public struct PromptTemplate: Sendable, Codable, Equatable {
    public var name: String
    public var prompt: String
    public var variables: [String]?
}

/// `manifest.json` schemaVersion 1.
public struct PluginManifest: Sendable, Codable, Equatable {
    public var schemaVersion: Int
    public var id: String
    public var name: String
    public var version: String
    public var minHostVersion: String
    public var type: PluginKind
    public var entry: String?
    public var author: PluginAuthor
    public var description: String
    public var icon: String?
    public var permissions: [String]
    public var tools: [PluginToolDefinition]
    public var settings: [PluginSettingDefinition]?
    public var server: MCPServerConfig?
    public var templates: [PromptTemplate]?

    public init(
        schemaVersion: Int = 1,
        id: String,
        name: String,
        version: String,
        minHostVersion: String = "1.0.0",
        type: PluginKind,
        entry: String? = nil,
        author: PluginAuthor,
        description: String,
        icon: String? = nil,
        permissions: [String] = [],
        tools: [PluginToolDefinition] = [],
        settings: [PluginSettingDefinition]? = nil,
        server: MCPServerConfig? = nil,
        templates: [PromptTemplate]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.version = version
        self.minHostVersion = minHostVersion
        self.type = type
        self.entry = entry
        self.author = author
        self.description = description
        self.icon = icon
        self.permissions = permissions
        self.tools = tools
        self.settings = settings
        self.server = server
        self.templates = templates
    }
}

public enum PluginKind: String, Sendable, Codable, CaseIterable {
    case js
    case mcp
    case prompt
}

/// Minimal JSON value so manifests can carry arbitrary schema objects without
/// losing fidelity.
public enum JSONValue: Sendable, Codable, Equatable {
    case string(String)
    case number(Double)
    case integer(Int)
    case boolean(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .boolean(value); return }
        if let value = try? container.decode(Int.self) { self = .integer(value); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([JSONValue].self) { self = .array(value); return }
        if let value = try? container.decode([String: JSONValue].self) { self = .object(value); return }
        self = .null
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):  try container.encode(value)
        case .number(let value):  try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        case .object(let value):  try container.encode(value)
        case .array(let value):   try container.encode(value)
        case .null:               try container.encodeNil()
        }
    }

    /// Converts to Foundation objects for `JSONSerialization`.
    public var foundationValue: Any {
        switch self {
        case .string(let v):  return v
        case .number(let v):  return v
        case .integer(let v): return v
        case .boolean(let v): return v
        case .object(let v):  return v.mapValues(\.foundationValue)
        case .array(let v):   return v.map(\.foundationValue)
        case .null:           return NSNull()
        }
    }
}