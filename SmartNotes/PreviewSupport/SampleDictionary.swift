#if DEBUG
import Foundation
import SwiftData

/// Offline sample data for SwiftUI previews: a full DictionaryAPI.dev-style
/// response for "drink" plus an in-memory model container pre-seeded with
/// vocabulary items and a cached copy of the sample response.
enum SampleDictionary {
    static let drinkEntries: [DictionaryEntry] = [
        DictionaryEntry(
            word: "drink",
            phonetic: "/drɪŋk/",
            phonetics: [
                Phonetic(
                    text: "/drɪŋk/",
                    audio: "https://api.dictionaryapi.dev/media/pronunciations/en/drink-us.mp3"
                )
            ],
            meanings: [
                Meaning(
                    partOfSpeech: "noun",
                    definitions: [
                        WordDefinition(
                            definition: "A beverage; a liquid intended for drinking.",
                            example: "May I have a drink of water?",
                            synonyms: ["beverage", "refreshment"],
                            antonyms: nil
                        ),
                        WordDefinition(
                            definition: "A type of beverage, especially one containing alcohol.",
                            example: "They went out for drinks after work.",
                            synonyms: nil,
                            antonyms: nil
                        ),
                        WordDefinition(
                            definition: "A (single) act of drinking.",
                            example: "She took a long drink from the bottle.",
                            synonyms: ["sip", "swig", "gulp"],
                            antonyms: nil
                        ),
                        WordDefinition(
                            definition: "(colloquial, with \u{201C}the\u{201D}) Any body of water, such as the sea.",
                            example: "The ball landed in the drink.",
                            synonyms: nil,
                            antonyms: nil
                        )
                    ],
                    synonyms: ["beverage"],
                    antonyms: nil
                ),
                Meaning(
                    partOfSpeech: "verb",
                    definitions: [
                        WordDefinition(
                            definition: "To consume (a liquid) through the mouth.",
                            example: "He drank the whole glass of juice in one go.",
                            synonyms: ["imbibe", "sip", "quaff"],
                            antonyms: nil
                        ),
                        WordDefinition(
                            definition: "To consume alcoholic beverages, especially habitually.",
                            example: "You should never drink and drive.",
                            synonyms: nil,
                            antonyms: ["abstain"]
                        ),
                        WordDefinition(
                            definition: "To take in (information or experiences) eagerly; to absorb.",
                            example: "She stood on the summit, drinking in the view.",
                            synonyms: ["absorb", "soak up"],
                            antonyms: nil
                        )
                    ],
                    synonyms: nil,
                    antonyms: nil
                )
            ],
            sourceUrls: ["https://en.wiktionary.org/wiki/drink"]
        )
    ]

    static var drinkRequest: DefinitionLookupRequest {
        DefinitionLookupRequest(
            rawSelection: "drink",
            context: "Cells need water to function, which is why we drink several litres a day.",
            sourceNoteTitle: "Biology — Hydration"
        )
    }

    @MainActor
    static var sampleVocabulary: [VocabularyItem] {
        [
            VocabularyItem(
                word: "photosynthesis",
                normalizedWord: "photosynthesis",
                shortDefinition: "The process by which plants convert light energy into chemical energy.",
                partOfSpeech: "noun",
                sourceNoteTitle: "Biology — Plants",
                createdAt: .now.addingTimeInterval(-3_600)
            ),
            VocabularyItem(
                word: "entropy",
                normalizedWord: "entropy",
                shortDefinition: "A measure of the disorder or randomness in a system.",
                partOfSpeech: "noun",
                sourceNoteTitle: "Physics — Thermodynamics",
                createdAt: .now.addingTimeInterval(-86_400)
            ),
            VocabularyItem(
                word: "mitigate",
                normalizedWord: "mitigate",
                shortDefinition: "To make less severe, serious, or painful.",
                partOfSpeech: "verb",
                sourceNoteTitle: nil,
                createdAt: .now.addingTimeInterval(-3 * 86_400)
            )
        ]
    }

    /// In-memory container seeded with sample vocabulary and a cached copy
    /// of the "drink" response, so DefinitionSheet previews work offline.
    @MainActor
    static func previewContainer() -> ModelContainer {
        do {
            let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
            let container = try ModelContainer(
                for: Note.self, CachedDictionaryEntry.self, VocabularyItem.self,
                configurations: configuration
            )
            let context = container.mainContext
            for item in sampleVocabulary {
                context.insert(item)
            }
            DictionaryCacheService(modelContext: context)
                .store(entries: drinkEntries, for: "drink")
            try? context.save()
            return container
        } catch {
            fatalError("Failed to create preview model container: \(error)")
        }
    }
}

/// Offline dictionary stand-in for previews/tests: returns the sample
/// "drink" entry and treats every other word as not-in-dictionary, without
/// touching the real bundled SQLite database.
struct MockOfflineDictionaryService: OfflineDictionaryServiceProtocol {
    func lookup(word: String) async -> [DictionaryEntry] {
        word == "drink" ? SampleDictionary.drinkEntries : []
    }
}
#endif
