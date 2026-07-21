import Foundation

/// The bundled, offline-first dictionary. This is the PRIMARY source for
/// every definition — it must return results with zero internet.
///
/// It reuses the existing `DictionaryEntry`/`Meaning`/`WordDefinition`
/// display models (the same ones the API path produces) so the existing
/// `DefinitionSheet` UI and the "Insert into Note" feature keep working
/// unchanged, regardless of where a definition came from.
protocol OfflineDictionaryServiceProtocol: Sendable {
    /// Looks up a normalized word in the bundled dictionary.
    ///
    /// Returns an empty array when the word is absent. Absence is a normal,
    /// expected outcome — not an error — because it is exactly what drives
    /// the "not in dictionary → escalate to AI" path in `LookupCoordinator`.
    func lookup(word: String) async -> [DictionaryEntry]
}
