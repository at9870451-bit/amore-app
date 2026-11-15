import Foundation
import NaturalLanguage

public enum EmbeddingError: LocalizedError, Sendable {
    case unavailable(String)
    case emptyInput
    case dimensionMismatch(expected: Int, got: Int)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let detail): return "Embeddings are unavailable. \(detail)"
        case .emptyInput:              return "Nothing to embed."
        case .dimensionMismatch(let expected, let got):
            return "Expected a \(expected)-dimension vector, got \(got)."
        }
    }
}

public protocol EmbeddingProvider: Sendable {
    var dimensions: Int { get }
    func embed(_ texts: [String]) async throws -> [[Float]]
}

// MARK: - On-device

/// Apple's sentence embeddings. English-only on most systems, so callers pair
/// it with a fallback when `embed` throws.
/// `NLEmbedding` is not declared `Sendable`, but the model is immutable once
/// loaded and `vector(for:)` performs no mutation, so sharing one instance
/// across tasks is safe. The unchecked conformance records that judgement
/// instead of hiding it behind a lock we do not need.
public struct NLEmbeddingProvider: EmbeddingProvider, @unchecked Sendable {
    public let dimensions: Int
    private let embedding: NLEmbedding

    public init(language: NLLanguage = .english) throws {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: language) else {
            throw EmbeddingError.unavailable("NLEmbedding has no model for \(language.rawValue)")
        }
        self.embedding = embedding
        self.dimensions = embedding.dimension
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { throw EmbeddingError.emptyInput }
        return texts.map { text in
            guard let vector = embedding.vector(for: text) else { return [Float](repeating: 0, count: dimensions) }
            return vector.map { Float($0) }
        }
    }
}

/// Deterministic hashing embedder. Not semantic, but keeps search working when
/// no model is available — and makes tests reproducible.
public struct HashingEmbeddingProvider: EmbeddingProvider {
    public let dimensions: Int

    public init(dimensions: Int = 256) {
        self.dimensions = dimensions
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { throw EmbeddingError.emptyInput }
        return texts.map { text in
            var vector = [Float](repeating: 0, count: dimensions)
            for token in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
                var hash: UInt64 = 5381
                for byte in token.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
                let index = Int(hash % UInt64(dimensions))
                let sign: Float = (hash & 1) == 0 ? 1 : -1
                vector[index] += sign
            }
            return vector
        }
    }
}

/// Tries the primary provider and falls back per call.
public struct FallbackEmbeddingProvider: EmbeddingProvider {
    private let primary: any EmbeddingProvider
    private let fallback: any EmbeddingProvider

    public init(primary: any EmbeddingProvider, fallback: any EmbeddingProvider) {
        self.primary = primary
        self.fallback = fallback
    }

    public var dimensions: Int { primary.dimensions }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        do {
            return try await primary.embed(texts)
        } catch {
            return try await fallback.embed(texts)
        }
    }
}