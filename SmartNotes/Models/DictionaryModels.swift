import Foundation

// MARK: - DictionaryAPI.dev response models
//
// Every field except `word` is optional: the API frequently omits
// phonetics, audio, examples, synonyms, and antonyms, and the models
// must tolerate any of them being absent.

struct DictionaryEntry: Codable, Hashable {
    let word: String
    let phonetic: String?
    let phonetics: [Phonetic]?
    let meanings: [Meaning]?
    let sourceUrls: [String]?
}

struct Phonetic: Codable, Hashable {
    let text: String?
    let audio: String?
}

struct Meaning: Codable, Hashable {
    let partOfSpeech: String?
    let definitions: [WordDefinition]?
    let synonyms: [String]?
    let antonyms: [String]?
}

struct WordDefinition: Codable, Hashable {
    let definition: String?
    let example: String?
    let synonyms: [String]?
    let antonyms: [String]?
}

/// Body the API returns with a 404 when a word has no entry.
struct DictionaryNotFoundResponse: Codable {
    let title: String?
    let message: String?
    let resolution: String?
}

extension DictionaryEntry {
    /// First non-empty audio URL across the entry's phonetics, if any.
    var bestAudioURL: URL? {
        guard let phonetics else { return nil }
        for phonetic in phonetics {
            if let audio = phonetic.audio, !audio.isEmpty, let url = URL(string: audio) {
                return url
            }
        }
        return nil
    }

    /// Best phonetic text: top-level `phonetic`, else first phonetics entry with text.
    var displayPhonetic: String? {
        if let phonetic, !phonetic.isEmpty { return phonetic }
        return phonetics?.first(where: { !($0.text ?? "").isEmpty })?.text
    }
}

// MARK: - Lookup request passed from the editor to the definition sheet

struct DefinitionLookupRequest: Identifiable, Hashable {
    let id = UUID()
    /// The raw selected text, before normalization.
    let rawSelection: String
    /// One or two sentences surrounding the selection. Used only for the
    /// AI explanation feature — never sent to the dictionary API.
    let context: String
    /// Title of the note the selection came from, for vocabulary provenance.
    let sourceNoteTitle: String?
}
