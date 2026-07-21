import Foundation
import SQLite3

/// Reads word definitions out of the bundled `dictionary.sqlite` database
/// using the C SQLite API directly (`import SQLite3`), so the offline
/// dictionary works with zero third-party dependencies and zero network
/// access. See `Tools/build_dictionary.py` for how that database is built
/// and `SmartNotes/Resources/dictionary.sqlite` for the schema it expects:
///
///     entries(id, word, part_of_speech, definition, example, synonyms,
///              antonyms, sense_index)
///
/// `Sendable` is satisfied with `@unchecked Sendable` rather than
/// `@MainActor`: SQLite connections are not inherently thread-safe, but a
/// single connection accessed only from one dedicated serial
/// `DispatchQueue` is safe by construction, and keeping this off the main
/// actor lets `lookup(word:)` run its (synchronous, C-API) query work
/// without ever blocking UI. `@MainActor` would have been simpler but would
/// force every lookup to compete with UI work on the main thread.
final class SQLiteOfflineDictionaryService: OfflineDictionaryServiceProtocol, @unchecked Sendable {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.smartnotes.sqliteofflinedictionary")

    /// Opens the database at `databaseURL` read-only. Fails (returns nil)
    /// if the file can't be opened as a valid SQLite database, so the
    /// caller can fall back gracefully instead of crashing.
    init?(databaseURL: URL) {
        var handle: OpaquePointer?
        let openResult = sqlite3_open_v2(
            databaseURL.path,
            &handle,
            SQLITE_OPEN_READONLY,
            nil
        )
        guard openResult == SQLITE_OK, let handle else {
            if let handle {
                sqlite3_close(handle)
            }
            return nil
        }
        self.db = handle
    }

    /// Locates the `dictionary.sqlite` resource bundled with the app and
    /// opens it. Returns nil if the resource is missing (e.g. a build
    /// misconfiguration) so callers can degrade gracefully rather than crash.
    static func bundled() -> SQLiteOfflineDictionaryService? {
        guard let url = Bundle.main.url(forResource: "dictionary", withExtension: "sqlite") else {
            return nil
        }
        return SQLiteOfflineDictionaryService(databaseURL: url)
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    func lookup(word: String) async -> [DictionaryEntry] {
        // The coordinator already runs the word through WordNormalizer, but
        // normalize defensively here too, matching the same lowercase+trim
        // rule, since this service can be used standalone.
        let normalized = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return [] }

        return await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                let rows = self?.rows(forWord: normalized) ?? []
                continuation.resume(returning: Self.makeEntry(word: normalized, rows: rows))
            }
        }
    }

    // MARK: - Querying

    private struct Row {
        let partOfSpeech: String?
        let definition: String
        let example: String?
        let synonyms: String?
        let antonyms: String?
    }

    /// Runs the bound-parameter SELECT for `word` and reads every matching
    /// row, in `sense_index` order. Must be called on `queue`.
    private func rows(forWord word: String) -> [Row] {
        guard let db else { return [] }

        let sql = """
            SELECT part_of_speech, definition, example, synonyms, antonyms
            FROM entries
            WHERE word = ?
            ORDER BY sense_index ASC
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        // SQLITE_TRANSIENT (rather than SQLITE_STATIC) tells SQLite to make
        // its own private copy of the bound string immediately. `word` is a
        // Swift value that could be deallocated/mutated before the step
        // loop below runs, so the transient copy is required for safety.
        // Binding through sqlite3_bind_text (never string interpolation)
        // is also what makes this SQL-injection-safe: the word is passed
        // purely as data, never parsed as SQL text.
        let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, 1, word, -1, sqliteTransient) == SQLITE_OK else {
            return []
        }

        var results: [Row] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let definitionCString = sqlite3_column_text(statement, 1) else {
                // definition is NOT NULL in the schema; skip a row that
                // somehow lacks one rather than crash.
                continue
            }
            let partOfSpeech = sqlite3_column_text(statement, 0).map { String(cString: $0) }
            let definition = String(cString: definitionCString)
            let example = sqlite3_column_text(statement, 2).map { String(cString: $0) }
            let synonyms = sqlite3_column_text(statement, 3).map { String(cString: $0) }
            let antonyms = sqlite3_column_text(statement, 4).map { String(cString: $0) }
            results.append(
                Row(
                    partOfSpeech: partOfSpeech,
                    definition: definition,
                    example: example,
                    synonyms: synonyms,
                    antonyms: antonyms
                )
            )
        }
        return results
    }

    // MARK: - Row -> display model grouping

    /// Groups flat DB rows into a single `DictionaryEntry`: consecutive rows
    /// sharing the same `part_of_speech` (DB order, which is `sense_index`
    /// order) become one `Meaning`, and each row within that run becomes a
    /// `WordDefinition`. Grouping by run (rather than sorting by part of
    /// speech) preserves the DB author's intended sense ordering.
    private static func makeEntry(word: String, rows: [Row]) -> [DictionaryEntry] {
        guard !rows.isEmpty else { return [] }

        var meanings: [Meaning] = []
        var currentPartOfSpeech: String?
        var currentDefinitions: [WordDefinition] = []
        var hasOpenGroup = false

        func flush() {
            guard hasOpenGroup else { return }
            meanings.append(
                Meaning(
                    partOfSpeech: currentPartOfSpeech,
                    definitions: currentDefinitions,
                    synonyms: nil,
                    antonyms: nil
                )
            )
            currentDefinitions = []
        }

        for row in rows {
            if !hasOpenGroup {
                currentPartOfSpeech = row.partOfSpeech
                hasOpenGroup = true
            } else if currentPartOfSpeech != row.partOfSpeech {
                flush()
                currentPartOfSpeech = row.partOfSpeech
            }
            currentDefinitions.append(
                WordDefinition(
                    definition: row.definition,
                    example: row.example,
                    synonyms: splitPipeDelimited(row.synonyms),
                    antonyms: splitPipeDelimited(row.antonyms)
                )
            )
        }
        flush()

        let entry = DictionaryEntry(
            word: word,
            phonetic: nil,
            phonetics: nil,
            meanings: meanings,
            sourceUrls: nil
        )
        return [entry]
    }

    /// Splits a pipe-delimited "a|b|c" string into an array, or nil for an
    /// absent/empty string, matching the nullable `synonyms`/`antonyms`
    /// columns in the schema.
    private static func splitPipeDelimited(_ value: String?) -> [String]? {
        guard let value, !value.isEmpty else { return nil }
        let parts = value.split(separator: "|").map(String.init)
        return parts.isEmpty ? nil : parts
    }
}
