import Foundation
import Observation
import SwiftData

/// Drives the definition sheet: normalizes the selection, orchestrates
/// cache-first lookup with an offline stale fallback, and tracks
/// vocabulary-saved state and pronunciation playback.
@MainActor
@Observable
final class DictionaryLookupViewModel {
    enum State {
        case idle
        case loading
        case loaded([DictionaryEntry], fromCache: Bool, isStale: Bool)
        case failed(DictionaryError)
    }

    private(set) var state: State = .idle
    private(set) var isSaved = false
    /// Fetch date of the stale cached result shown while offline,
    /// used by the "Offline — showing a cached result from …" banner.
    private(set) var staleResultDate: Date?

    let audioPlayer = AudioPlayerService()

    private let dictionaryService: DictionaryServiceProtocol
    private var cacheService: DictionaryCacheService?
    private var vocabularyService: VocabularyService?
    private var normalizedWord: String?

    init(dictionaryService: DictionaryServiceProtocol = DictionaryService()) {
        self.dictionaryService = dictionaryService
    }

    /// The model context is only available once the view appears, so the
    /// SwiftData-backed services are built lazily here. Safe to call again;
    /// subsequent calls are ignored.
    func configure(modelContext: ModelContext) {
        guard cacheService == nil else { return }
        cacheService = DictionaryCacheService(modelContext: modelContext)
        vocabularyService = VocabularyService(modelContext: modelContext)
    }

    func lookup(raw: String) async {
        state = .loading
        staleResultDate = nil

        let normalized: String
        do {
            normalized = try WordNormalizer.normalize(raw)
        } catch let error as DictionaryError {
            state = .failed(error)
            return
        } catch {
            state = .failed(.invalidSelection(reason: error.localizedDescription))
            return
        }
        normalizedWord = normalized
        refreshSavedState()

        // 1. Fresh cache hit: show immediately, no network request.
        let cached = cacheService?.cachedResult(for: normalized)
        if let cached, !cached.isExpired {
            state = .loaded(cached.entries, fromCache: true, isStale: false)
            return
        }

        // 2. Miss or expired: go to the network.
        do {
            let entries = try await dictionaryService.lookup(word: normalized)
            cacheService?.store(entries: entries, for: normalized)
            state = .loaded(entries, fromCache: false, isStale: false)
        } catch let error as DictionaryError {
            // 3. Network failed but an expired copy exists: show it stale
            //    rather than an error — an old definition beats no definition.
            if let cached, isNetworkFailure(error) {
                staleResultDate = cached.fetchedAt
                state = .loaded(cached.entries, fromCache: true, isStale: true)
            } else {
                state = .failed(error)
            }
        } catch {
            state = .failed(.network(description: error.localizedDescription))
        }
    }

    // MARK: - Vocabulary

    func refreshSavedState() {
        guard let normalizedWord, let vocabularyService else {
            isSaved = false
            return
        }
        isSaved = vocabularyService.isSaved(normalizedWord: normalizedWord)
    }

    /// Saves the first entry's word with its first definition as the short
    /// definition. Duplicate-safe: the service returns the existing item.
    func saveToVocabulary(entries: [DictionaryEntry], sourceNoteTitle: String?) {
        guard let vocabularyService, let first = entries.first else { return }
        let primary = primaryDefinition(in: entries)
        do {
            try vocabularyService.saveWord(
                word: first.word,
                shortDefinition: primary?.definition ?? "",
                partOfSpeech: primary?.partOfSpeech,
                sourceNoteTitle: sourceNoteTitle
            )
            isSaved = true
        } catch {
            // A failed save just leaves the button in its unsaved state.
            isSaved = false
        }
    }

    // MARK: - Insert into note

    /// Compact "word (partOfSpeech): first definition" string for the
    /// Insert into Note action. Nil when there is nothing to insert.
    func insertText(from entries: [DictionaryEntry]) -> String? {
        guard let first = entries.first, let primary = primaryDefinition(in: entries) else {
            return nil
        }
        if let partOfSpeech = primary.partOfSpeech, !partOfSpeech.isEmpty {
            return "\(first.word) (\(partOfSpeech)): \(primary.definition)"
        }
        return "\(first.word): \(primary.definition)"
    }

    /// Failures where showing an expired cached copy is better than an
    /// error. `wordNotFound` and selection errors are excluded: the cache
    /// can't fix a misspelled or unknown word.
    private func isNetworkFailure(_ error: DictionaryError) -> Bool {
        switch error {
        case .noConnection, .network, .serverError, .invalidResponse, .decodingFailed:
            true
        case .emptySelection, .invalidSelection, .invalidURL, .wordNotFound:
            false
        }
    }

    /// First non-empty definition across all entries and meanings,
    /// paired with the part of speech it belongs to.
    private func primaryDefinition(in entries: [DictionaryEntry]) -> (definition: String, partOfSpeech: String?)? {
        for entry in entries {
            for meaning in entry.meanings ?? [] {
                for definition in meaning.definitions ?? [] {
                    if let text = definition.definition, !text.isEmpty {
                        return (text, meaning.partOfSpeech)
                    }
                }
            }
        }
        return nil
    }
}
