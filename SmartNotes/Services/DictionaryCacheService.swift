import Foundation
import SwiftData

/// SwiftData-backed cache of dictionary responses.
///
/// Lookup flow (orchestrated by `DictionaryLookupViewModel`):
/// 1. Check the cache; a fresh hit is shown immediately with no request.
/// 2. Otherwise call the API and store the successful response.
/// 3. Entries expire after 7 days, but expired entries are still
///    returned (marked `isExpired`) so they can serve as a fallback
///    when the network request fails.
@MainActor
final class DictionaryCacheService {
    nonisolated static let expirationInterval: TimeInterval = 7 * 24 * 60 * 60

    struct CachedResult {
        let entries: [DictionaryEntry]
        let fetchedAt: Date

        var isExpired: Bool {
            Date.now.timeIntervalSince(fetchedAt) > DictionaryCacheService.expirationInterval
        }
    }

    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Returns the cached response for a normalized word, updating its
    /// last-accessed date. Returns nil on a cache miss or if the stored
    /// data can no longer be decoded.
    func cachedResult(for normalizedWord: String) -> CachedResult? {
        guard let entry = fetchEntry(for: normalizedWord) else { return nil }
        guard let decoded = try? JSONDecoder().decode([DictionaryEntry].self, from: entry.responseData) else {
            // Corrupt cache row: drop it rather than fail every lookup.
            modelContext.delete(entry)
            try? modelContext.save()
            return nil
        }
        entry.lastAccessedAt = .now
        try? modelContext.save()
        return CachedResult(entries: decoded, fetchedAt: entry.fetchedAt)
    }

    /// Stores (or refreshes) the response for a normalized word.
    func store(entries: [DictionaryEntry], for normalizedWord: String) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        if let existing = fetchEntry(for: normalizedWord) {
            existing.responseData = data
            existing.fetchedAt = .now
            existing.lastAccessedAt = .now
        } else {
            modelContext.insert(CachedDictionaryEntry(normalizedWord: normalizedWord, responseData: data))
        }
        try? modelContext.save()
    }

    func clearAll() throws {
        try modelContext.delete(model: CachedDictionaryEntry.self)
        try modelContext.save()
    }

    func entryCount() -> Int {
        (try? modelContext.fetchCount(FetchDescriptor<CachedDictionaryEntry>())) ?? 0
    }

    private func fetchEntry(for normalizedWord: String) -> CachedDictionaryEntry? {
        var descriptor = FetchDescriptor<CachedDictionaryEntry>(
            predicate: #Predicate { $0.normalizedWord == normalizedWord }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }
}
