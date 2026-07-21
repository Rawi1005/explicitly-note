import Foundation
import Observation
import SwiftData

/// Drives the definition sheet with an offline-first flow:
///
///   1. Resolve the selection against the bundled offline dictionary via
///      `LookupCoordinator` — this is instant, free, and needs no network.
///   2. If found, show it immediately, then try to enrich it (audio,
///      phonetics, source links) from the online dictionary in the
///      background. Enrichment is best-effort and never blocks or replaces
///      the offline definitions themselves.
///   3. If the word isn't in the offline dictionary, surface the
///      "Explain with AI" escalation instead of an error.
///
/// Also tracks vocabulary-saved state and pronunciation playback.
@MainActor
@Observable
final class DictionaryLookupViewModel {
    enum State {
        case idle
        case loading
        case dictionary([DictionaryEntry], source: DefinitionSource)
        case notInDictionary(word: String)
        case failed(DictionaryError)   // invalid selection only
    }

    private(set) var state: State = .idle
    private(set) var isSaved = false

    let audioPlayer = AudioPlayerService()

    private let coordinator: LookupCoordinator
    private let onlineService: DictionaryServiceProtocol
    private var cacheService: DictionaryCacheService?
    private var vocabularyService: VocabularyService?
    private var normalizedWord: String?

    /// `offline` defaults to the bundled SQLite dictionary; if that resource
    /// is missing (e.g. a build misconfiguration) it falls back to an
    /// always-empty offline service so every lookup still resolves — it
    /// just always escalates to "not in dictionary" rather than crashing or
    /// hanging. `offline` is injectable so tests/previews can supply a mock.
    init(
        offline: OfflineDictionaryServiceProtocol? = SQLiteOfflineDictionaryService.bundled(),
        onlineService: DictionaryServiceProtocol = DictionaryService()
    ) {
        self.coordinator = LookupCoordinator(offline: offline ?? EmptyOfflineDictionaryService())
        self.onlineService = onlineService
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

        let outcome = await coordinator.resolve(selection: raw)
        switch outcome {
        case .invalid(let error):
            normalizedWord = nil
            state = .failed(error)

        case .notInDictionary(let word):
            normalizedWord = word
            refreshSavedState()
            state = .notInDictionary(word: word)

        case .found(let entries):
            // The offline service stores/returns the normalized word.
            normalizedWord = entries.first?.word
            refreshSavedState()
            state = .dictionary(entries, source: .offlineDictionary)
            await enrich(base: entries, word: entries.first?.word)
        }
    }

    // MARK: - Online enrichment

    /// Best-effort enrichment of an already-shown offline result with
    /// online audio/phonetics/source links. Never required: a missing or
    /// failing network simply leaves the offline result on screen as-is.
    /// Definitions themselves always stay the trusted offline ones — only
    /// `phonetic`/`phonetics`/`sourceUrls` come from the online response.
    private func enrich(base: [DictionaryEntry], word: String?) async {
        guard let word else { return }
        // If the user has since looked up something else, don't clobber it.
        guard isStillShowing(word: word) else { return }

        if let cached = cacheService?.cachedResult(for: word) {
            applyEnrichment(base: base, online: cached.entries)
            return
        }

        do {
            let online = try await onlineService.lookup(word: word)
            cacheService?.store(entries: online, for: word)
            applyEnrichment(base: base, online: online)
        } catch {
            // Silent: stay on the offline result.
        }
    }

    private func applyEnrichment(base: [DictionaryEntry], online: [DictionaryEntry]) {
        guard let o = online.first else { return }
        let merged = base.map { e in
            DictionaryEntry(
                word: e.word,
                phonetic: o.displayPhonetic,
                phonetics: o.phonetics,
                meanings: e.meanings,
                sourceUrls: o.sourceUrls
            )
        }
        guard isStillShowing(word: base.first?.word) else { return }
        state = .dictionary(merged, source: .onlineDictionary)
    }

    /// True when `state` is still `.dictionary` for the given word, i.e. the
    /// user hasn't navigated away to a different lookup in the meantime.
    private func isStillShowing(word: String?) -> Bool {
        guard let word, case .dictionary(let entries, _) = state else { return false }
        return entries.first?.word == word
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
    func saveToVocabulary(
        entries: [DictionaryEntry],
        sourceNoteTitle: String?,
        details: VocabularySaveDetails = VocabularySaveDetails()
    ) {
        guard let vocabularyService, let first = entries.first else { return }
        let primary = primaryDefinition(in: entries)
        var enriched = details
        if enriched.phonetic == nil {
            enriched.phonetic = first.displayPhonetic
        }
        if enriched.exampleSentence == nil {
            enriched.exampleSentence = firstExample(in: entries)
        }
        do {
            try vocabularyService.saveWord(
                word: first.word,
                shortDefinition: primary?.definition ?? "",
                partOfSpeech: primary?.partOfSpeech,
                sourceNoteTitle: sourceNoteTitle,
                details: enriched
            )
            isSaved = true
        } catch {
            // A failed save just leaves the button in its unsaved state.
            isSaved = false
        }
    }

    /// Compact "word: definition" line used when storing a definition.
    func shortDefinitionText(from entries: [DictionaryEntry]) -> String {
        primaryDefinition(in: entries)?.definition ?? ""
    }

    private func firstExample(in entries: [DictionaryEntry]) -> String? {
        for entry in entries {
            for meaning in entry.meanings ?? [] {
                for definition in meaning.definitions ?? [] {
                    if let example = definition.example, !example.isEmpty {
                        return example
                    }
                }
            }
        }
        return nil
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

/// Always-empty offline dictionary, used only as a fallback when the
/// bundled SQLite database can't be opened, so lookups still resolve
/// (as `.notInDictionary`) instead of crashing or being unavailable.
private struct EmptyOfflineDictionaryService: OfflineDictionaryServiceProtocol {
    func lookup(word: String) async -> [DictionaryEntry] { [] }
}
