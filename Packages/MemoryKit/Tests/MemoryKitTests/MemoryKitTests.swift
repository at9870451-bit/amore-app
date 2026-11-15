import Foundation
import SwiftData
import Testing

@testable import MemoryKit

@Suite("VectorIndex")
struct VectorIndexTests {
    @Test("ranks by cosine similarity")
    func ranking() async {
        let index = VectorIndex()
        await index.upsert(id: "a", vector: [1, 0, 0])
        await index.upsert(id: "b", vector: [0.9, 0.1, 0])
        await index.upsert(id: "c", vector: [0, 1, 0])

        let hits = await index.search([1, 0, 0], topK: 2)
        #expect(hits.count == 2)
        #expect(hits.first?.id == "a")
        #expect(hits.last?.id == "b")
    }

    @Test("dimension mismatches score zero instead of trapping")
    func dimensionMismatch() {
        #expect(VectorIndex.cosine([1, 0], [1, 0, 0]) == 0)
        #expect(VectorIndex.cosine([0, 0], [0, 0]) == 0)
    }

    @Test("chunked scan returns the same top-k as a single pass")
    func chunking() async {
        var entries: [(id: String, vector: [Float])] = []
        for i in 0..<40 {
            var vector = [Float](repeating: 0, count: 8)
            vector[i % 8] = Float(i + 1)
            entries.append((id: "m\(i)", vector: vector))
        }
        let chunked = VectorIndex(chunkSize: 64, chunkThreshold: 1)
        await chunked.load(entries)

        let hits = await chunked.search([0, 0, 0, 0, 0, 0, 0, 1], topK: 3)
        #expect(hits.count == 3)
        // Highest weight on axis 7 belongs to the largest i with i % 8 == 7.
        #expect(hits.first?.id == "m39")
    }

    @Test("removal drops a vector from results")
    func removal() async {
        let index = VectorIndex()
        await index.upsert(id: "x", vector: [1, 0])
        await index.remove(id: "x")
        let hits = await index.search([1, 0], topK: 5)
        #expect(hits.isEmpty)
    }
}

@Suite("MemoryStore")
struct MemoryStoreTests {
    private func makeStore() throws -> MemoryStore {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Conversation.self, Message.self, MemoryItem.self,
            configurations: configuration
        )
        return MemoryStore(modelContainer: container)
    }

    @Test("deleting a conversation cascades its messages")
    func cascadeDelete() async throws {
        let store = try makeStore()
        let id = try await store.createConversation(title: "Trip")
        try await store.appendMessage(conversationID: id, role: "user", content: "hi")
        try await store.appendMessage(conversationID: id, role: "assistant", content: "hello")

        let before = try await store.messageCount(conversationID: id)
        #expect(before == 2)

        try await store.deleteConversation(id: id)
        let after = try await store.messageCount(conversationID: id)
        #expect(after == 0)
        let remaining = try await store.conversations()
        #expect(remaining.isEmpty)
    }

    @Test("near-duplicates merge, distinct facts insert")
    func dedupe() async throws {
        let store = try makeStore()
        let vector: [Float] = [1, 0, 0]

        let first = try await store.ingest(candidates: [
            (content: "Prefers dark mode", embedding: vector)
        ])
        #expect(first.inserted == 1)
        #expect(first.merged == 0)

        let second = try await store.ingest(candidates: [
            (content: "Prefers dark theme", embedding: [0.999, 0.001, 0]),
            (content: "Lives in Shanghai", embedding: [0, 1, 0])
        ])
        #expect(second.merged == 1)
        #expect(second.inserted == 1)

        let all = try await store.allMemories()
        #expect(all.count == 2)
    }

    @Test("export produces valid JSON")
    func export() async throws {
        let store = try makeStore()
        try await store.insertMemory(content: "fact", embedding: [1, 0], tags: ["t"], source: "manual")
        let data = try await store.exportJSON()
        let object = try JSONSerialization.jsonObject(with: data)
        #expect((object as? [[String: Any]])?.count == 1)
    }

    @Test("vectors round-trip through SwiftData")
    func vectorRoundTrip() async throws {
        let store = try makeStore()
        let id = try await store.insertMemory(content: "v", embedding: [0.25, 0.5], source: "manual")
        let vector = try await store.memoryVector(id: id)
        #expect(vector?.count == 2)
        #expect(vector?[1] == 0.5)
    }
}