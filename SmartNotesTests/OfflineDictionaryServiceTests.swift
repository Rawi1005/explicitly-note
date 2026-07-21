import XCTest
import SQLite3
@testable import SmartNotes

/// These tests build their own tiny SQLite database in `setUp`, matching
/// the `entries` schema from `Tools/build_dictionary.py`, rather than
/// relying on the bundled `dictionary.sqlite` resource. That keeps the
/// tests independent of what words happen to be seeded in the shipped
/// database.
final class OfflineDictionaryServiceTests: XCTestCase {
    private var databaseURL: URL!
    private var service: SQLiteOfflineDictionaryService!

    override func setUp() throws {
        try super.setUp()
        databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-dictionary-tests-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
        try makeTestDatabase(at: databaseURL)
        service = try XCTUnwrap(
            SQLiteOfflineDictionaryService(databaseURL: databaseURL),
            "Failed to open the test database"
        )
    }

    override func tearDown() throws {
        service = nil
        if let databaseURL, FileManager.default.fileExists(atPath: databaseURL.path) {
            try FileManager.default.removeItem(at: databaseURL)
        }
        databaseURL = nil
        try super.tearDown()
    }

    // MARK: - Test database

    /// Creates a fresh SQLite file with the same schema as the production
    /// generator and inserts:
    ///   - "drink": three senses (verb, noun, verb) — multi-sense.
    ///   - "photosynthesis": one sense (noun) — single-sense.
    private func makeTestDatabase(at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let db else {
            XCTFail("Could not create test database")
            return
        }
        defer { sqlite3_close(db) }

        let createSQL = """
            CREATE TABLE entries (
                id INTEGER PRIMARY KEY,
                word TEXT NOT NULL,
                part_of_speech TEXT,
                definition TEXT NOT NULL,
                example TEXT,
                synonyms TEXT,
                antonyms TEXT,
                sense_index INTEGER NOT NULL
            );
            CREATE INDEX idx_entries_word ON entries(word);
            """
        XCTAssertEqual(sqlite3_exec(db, createSQL, nil, nil, nil), SQLITE_OK)

        let insertSQL = """
            INSERT INTO entries (word, part_of_speech, definition, example, synonyms, antonyms, sense_index)
            VALUES
                ('drink', 'verb', 'To take liquid into the mouth and swallow it.', 'She drank a glass of water.', NULL, NULL, 0),
                ('drink', 'noun', 'A liquid that is swallowed to quench thirst.', 'Would you like a drink?', 'beverage|refreshment', NULL, 1),
                ('drink', 'verb', 'To consume alcoholic beverages, especially habitually.', 'He does not drink anymore.', NULL, NULL, 2),
                ('photosynthesis', 'noun', 'The process by which green plants use sunlight to synthesize nutrients.', 'Photosynthesis happens in leaves.', NULL, NULL, 0);
            """
        XCTAssertEqual(sqlite3_exec(db, insertSQL, nil, nil, nil), SQLITE_OK)
    }

    // MARK: - Multi-sense word

    func testMultiSenseWordGroupsByPartOfSpeech() async throws {
        let entries = await service.lookup(word: "drink")

        XCTAssertEqual(entries.count, 1)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.word, "drink")
        XCTAssertNil(entry.phonetic)
        XCTAssertNil(entry.phonetics)
        XCTAssertNil(entry.sourceUrls)

        let meanings = try XCTUnwrap(entry.meanings)
        // verb, noun, verb -> three runs, since grouping is by consecutive
        // sense_index order, not by collecting all rows of a given part of
        // speech together.
        XCTAssertEqual(meanings.count, 3)

        XCTAssertEqual(meanings[0].partOfSpeech, "verb")
        XCTAssertEqual(meanings[0].definitions?.count, 1)
        XCTAssertEqual(meanings[0].definitions?.first?.definition, "To take liquid into the mouth and swallow it.")
        XCTAssertEqual(meanings[0].definitions?.first?.example, "She drank a glass of water.")
        XCTAssertNil(meanings[0].definitions?.first?.synonyms)

        XCTAssertEqual(meanings[1].partOfSpeech, "noun")
        XCTAssertEqual(meanings[1].definitions?.first?.definition, "A liquid that is swallowed to quench thirst.")
        XCTAssertEqual(meanings[1].definitions?.first?.synonyms, ["beverage", "refreshment"])
        XCTAssertNil(meanings[1].definitions?.first?.antonyms)

        XCTAssertEqual(meanings[2].partOfSpeech, "verb")
        XCTAssertEqual(meanings[2].definitions?.first?.definition, "To consume alcoholic beverages, especially habitually.")
    }

    // MARK: - Single-sense word

    func testSingleSenseWordReturnsOneEntryOneDefinition() async throws {
        let entries = await service.lookup(word: "photosynthesis")

        XCTAssertEqual(entries.count, 1)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.word, "photosynthesis")

        let meanings = try XCTUnwrap(entry.meanings)
        XCTAssertEqual(meanings.count, 1)
        XCTAssertEqual(meanings.first?.partOfSpeech, "noun")
        XCTAssertEqual(meanings.first?.definitions?.count, 1)
        XCTAssertEqual(
            meanings.first?.definitions?.first?.definition,
            "The process by which green plants use sunlight to synthesize nutrients."
        )
    }

    // MARK: - Unknown word

    func testUnknownWordReturnsEmptyArray() async {
        let entries = await service.lookup(word: "zzznotarealword")
        XCTAssertEqual(entries, [])
    }

    // MARK: - Normalization

    func testLookupIsCaseAndWhitespaceInsensitive() async throws {
        let entries = await service.lookup(word: "  Drink  ")
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.word, "drink")
    }

    // MARK: - SQL injection safety

    func testSQLInjectionAttemptReturnsEmptyAndDoesNotCorruptDatabase() async throws {
        let maliciousWord = "'; DROP TABLE entries; --"

        let entries = await service.lookup(word: maliciousWord)
        XCTAssertEqual(entries, [], "A malicious lookup should behave like any other miss: no rows found.")

        // If the injection had succeeded, the entries table would be gone
        // and this lookup for a word that definitely exists would also
        // come back empty. Asserting it still succeeds proves the table
        // survived intact.
        let stillWorks = await service.lookup(word: "drink")
        XCTAssertEqual(stillWorks.count, 1, "The entries table should be untouched by the injection attempt.")
        XCTAssertEqual(stillWorks.first?.meanings?.count, 3)
    }
}
