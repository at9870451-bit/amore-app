import Foundation
import SwiftData

/// A chat thread. Messages cascade-delete with it, which is what the memory
/// feature relies on when a conversation is removed.
@Model
public final class Conversation {
    @Attribute(.unique) public var id: String
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \Message.conversation)
    public var messages: [Message]

    public init(id: String = UUID().uuidString,
                title: String = "New Chat",
                createdAt: Date = Date(),
                updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = []
    }
}

@Model
public final class Message {
    @Attribute(.unique) public var id: String
    public var role: String
    public var content: String
    public var createdAt: Date
    /// Denormalised so predicates can filter without traversing an optional
    /// relationship (`#Predicate` cannot express `$0.conversation?.id`).
    public var conversationID: String?
    public var conversation: Conversation?

    public init(id: String = UUID().uuidString,
                role: String,
                content: String,
                createdAt: Date = Date(),
                conversationID: String? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.conversationID = conversationID
    }
}

/// One durable fact about the user. `embedding` is stored inline so a cold
/// launch can rebuild the vector index without a network round trip.
@Model
public final class MemoryItem {
    @Attribute(.unique) public var id: String
    public var content: String
    public var tagsRaw: String
    public var source: String
    public var createdAt: Date
    public var updatedAt: Date
    public var embeddingData: Data?
    /// Normalised vector, decoded on demand.
    public var embedding: [Float] {
        get {
            guard let embeddingData else { return [] }
            return embeddingData.withUnsafeBytes { buffer in
                Array(buffer.bindMemory(to: Float.self))
            }
        }
        set {
            embeddingData = newValue.withUnsafeBytes { Data($0) }
        }
    }

    public var tags: [String] {
        get { tagsRaw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        set { tagsRaw = newValue.joined(separator: ",") }
    }

    public init(id: String = UUID().uuidString,
                content: String,
                embedding: [Float] = [],
                tags: [String] = [],
                source: String = "manual",
                createdAt: Date = Date()) {
        self.id = id
        self.content = content
        self.tagsRaw = tags.joined(separator: ",")
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.embeddingData = nil
        if !embedding.isEmpty { self.embedding = embedding }
    }
}

/// Schema version marker: changing models requires a migration plan.
public enum MemorySchema {
    public static let models: [any PersistentModel.Type] = [
        Conversation.self, Message.self, MemoryItem.self
    ]
}