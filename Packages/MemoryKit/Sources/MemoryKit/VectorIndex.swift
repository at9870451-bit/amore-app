import Foundation

public struct VectorHit: Sendable, Equatable {
    public let id: String
    public let score: Float

    public init(id: String, score: Float) {
        self.id = id
        self.score = score
    }
}

/// In-memory cosine index. Vectors are held contiguously and scanned in chunks
/// so a very large memory set cannot monopolise the executor for one query.
public actor VectorIndex {
    private var vectors: [String: [Float]] = [:]
    private let chunkSize: Int
    private let chunkThreshold: Int

    public init(chunkSize: Int = 2_048, chunkThreshold: Int = 10_000) {
        self.chunkSize = max(64, chunkSize)
        self.chunkThreshold = max(1, chunkThreshold)
    }

    public var count: Int { vectors.count }

    public func upsert(id: String, vector: [Float]) {
        guard !vector.isEmpty else { return }
        vectors[id] = vector
    }

    public func remove(id: String) {
        vectors.removeValue(forKey: id)
    }

    public func removeAll() {
        vectors.removeAll()
    }

    public func load(_ entries: [(id: String, vector: [Float])]) {
        vectors.removeAll()
        for entry in entries where !entry.vector.isEmpty {
            vectors[entry.id] = entry.vector
        }
    }

    /// Top-k by cosine similarity. Ties break by id so results are stable.
    public func search(_ query: [Float], topK: Int) -> [VectorHit] {
        guard topK > 0, !query.isEmpty, !vectors.isEmpty else { return [] }
        let limit = min(topK, vectors.count)

        var best: [VectorHit] = []
        best.reserveCapacity(limit)

        let entries = vectors.map { ($0.key, $0.value) }
        let chunked = entries.count > chunkThreshold

        var start = 0
        while start < entries.count {
            let end = chunked ? min(start + chunkSize, entries.count) : entries.count
            for entry in entries[start..<end] {
                let score = Self.cosine(query, entry.1)
                guard score > 0 else { continue }
                if best.count < limit {
                    best.append(VectorHit(id: entry.0, score: score))
                } else if let worst = best.last, score > worst.score ||
                            (score == worst.score && entry.0 < worst.id) {
                    best.removeLast()
                    best.append(VectorHit(id: entry.0, score: score))
                } else {
                    continue
                }
                best.sort { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }
            }
            if !chunked { break }
            start = end
            if Task.isCancelled { break }
        }
        return best
    }

    /// Cosine similarity. Dimension mismatch returns 0 rather than trapping —
    /// a provider that changes model should simply stop matching old vectors.
    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for index in a.indices {
            let x = a[index]
            let y = b[index]
            dot += x * y
            normA += x * x
            normB += y * y
        }
        guard normA > 0, normB > 0 else { return 0 }
        return dot / (sqrt(normA) * sqrt(normB))
    }
}