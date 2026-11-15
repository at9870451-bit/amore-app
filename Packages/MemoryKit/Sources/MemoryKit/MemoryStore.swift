import CoreKit
import Foundation
import LLMKit
import SwiftData

public struct MemorySnapshot: Sendable, Equatable, Identifiable {
    public let id: String
    public let content: String
    public let tags: [String]
    public let source: String
    public let createdAt: Date
}

public struct ConversationSnapshot: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let updatedAt: Date
    public let messageCount: Int
}

public struct DedupeResult: Sendable, Equatable {
    public var inserted: Int
    public var merged: Int

    public init(inserted: Int = 0, merged: Int = 0) {
        self.inserted = inserted
        self.merged = merged
    }
}

/// SwiftData façade. All model access happens on the actor's own context, so no
/// `PersistentModel` instance ever escapes to a view.
@ModelActor
public actor MemoryStore {
    public static let dedupeThreshold: Float = 0.92

    // MARK: Conversations

    public func createConversation(title: String = "New Chat") throws -> String {
        let conversation = Conversation(title: title)
        modelContext.insert(conversation)
        try modelContext.save()
        return conversation.id
    }

    public func appendMessage(conversationID: String, role: String, content: String) throws {
        let descriptor = FetchDescriptor<Conversation>(
            predicate: #Predicate { $0.id == conversationID }
        )
        guard let conversation = try modelContext.fetch(descriptor).first else { return }
        let message = Message(role: role, content: content, conversationID: conversationID)
        message.conversation = conversation
        modelContext.insert(message)
        conversation.updatedAt = Date()
        try modelContext.save()
    }

    public func conversations() throws -> [ConversationSnapshot] {
        let descriptor = FetchDescriptor<Conversation>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor).map {
            ConversationSnapshot(id: $0.id, title: $0.title,
                                 updatedAt: $0.updatedAt,
                                 messageCount: $0.messages.count)
        }
    }

    /// Deleting the conversation removes its messages through the cascade rule.
    public func deleteConversation(id: String) throws {
        let descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })
        guard let conversation = try modelContext.fetch(descriptor).first else { return }
        modelContext.delete(conversation)
        try modelContext.save()
    }

    public func messageCount(conversationID: String) throws -> Int {
        let descriptor = FetchDescriptor<Message>(
            predicate: #Predicate { $0.conversationID == conversationID }
        )
        return try modelContext.fetchCount(descriptor)
    }

    // MARK: Memories

    public func allMemories() throws -> [MemorySnapshot] {
        let descriptor = FetchDescriptor<MemoryItem>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor).map {
            MemorySnapshot(id: $0.id, content: $0.content, tags: $0.tags,
                           source: $0.source, createdAt: $0.createdAt)
        }
    }

    public func memoryVector(id: String) throws -> [Float]? {
        let descriptor = FetchDescriptor<MemoryItem>(predicate: #Predicate { $0.id == id })
        return try modelContext.fetch(descriptor).first?.embedding
    }

    public func allVectors() throws -> [(id: String, vector: [Float])] {
        let descriptor = FetchDescriptor<MemoryItem>()
        return try modelContext.fetch(descriptor).compactMap { item in
            let vector = item.embedding
            return vector.isEmpty ? nil : (item.id, vector)
        }
    }

    @discardableResult
    public func insertMemory(content: String, embedding: [Float],
                             tags: [String] = [], source: String = "auto") throws -> String {
        let item = MemoryItem(content: content, embedding: embedding,
                              tags: tags, source: source)
        modelContext.insert(item)
        try modelContext.save()
        return item.id
    }

    public func updateMemory(id: String, content: String?, tags: [String]?) throws {
        let descriptor = FetchDescriptor<MemoryItem>(predicate: #Predicate { $0.id == id })
        guard let item = try modelContext.fetch(descriptor).first else { return }
        if let content { item.content = content }
        if let tags { item.tags = tags }
        item.updatedAt = Date()
        try modelContext.save()
    }

    public func deleteMemory(id: String) throws {
        let descriptor = FetchDescriptor<MemoryItem>(predicate: #Predicate { $0.id == id })
        guard let item = try modelContext.fetch(descriptor).first else { return }
        modelContext.delete(item)
        try modelContext.save()
    }

    /// Near-duplicate candidates merge into the existing row instead of adding a
    /// second copy. Similarity is measured on the caller-supplied vectors so the
    /// store never needs an embedding provider of its own.
    @discardableResult
    public func ingest(
        candidates: [(content: String, embedding: [Float])],
        threshold: Float = MemoryStore.dedupeThreshold,
        source: String = "auto"
    ) throws -> DedupeResult {
        let existing = try modelContext.fetch(FetchDescriptor<MemoryItem>())
        var result = DedupeResult()

        for candidate in candidates {
            var mergedInto: MemoryItem?
            for item in existing {
                let vector = item.embedding
                guard !vector.isEmpty else { continue }
                if VectorIndex.cosine(candidate.embedding, vector) >= threshold {
                    mergedInto = item
                    break
                }
            }
            if let mergedInto {
                mergedInto.updatedAt = Date()
                result.merged += 1
            } else {
                modelContext.insert(MemoryItem(content: candidate.content,
                                               embedding: candidate.embedding,
                                               source: source))
                result.inserted += 1
            }
        }
        try modelContext.save()
        return result
    }

    public func exportJSON() throws -> Data {
        let snapshot = try allMemories().map { memory -> [String: Any] in
            [
                "id": memory.id,
                "content": memory.content,
                "tags": memory.tags,
                "source": memory.source,
                "createdAt": ISO8601DateFormatter().string(from: memory.createdAt)
            ]
        }
        return try JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted])
    }
}