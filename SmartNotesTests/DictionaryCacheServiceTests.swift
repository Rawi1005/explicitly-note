import XCTest
import SwiftData
@testable import Gloss

@MainActor
final class DictionaryCacheServiceTests: XCTestCase {
    private var container: ModelContainer!
    private var service: DictionaryCacheService!

    override func setUp() async throws {
        try await super.setUp()
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: CachedDictionaryEntry.self, configurations: configuration)
        service = DictionaryCacheService(modelContext: container.mainContext)
    }

    override func tearDown() async throws {
        service = nil
        container = nil
        try await super.tearDown()
    }

    private func makeEntries(word: String = "drink") -> [DictionaryEntry] {
        [
            DictionaryEntry(
                word: word,
                phonetic: "/drɪŋk/",
                phonetics: [Phonetic(text: "/drɪŋk/", audio: nil)],
                meanings: [
                    Meaning(
                        partOfSpeech: "noun",
                        definitions: [
                            WordDefinition(
                                definition: "A beverage.",
                                example: "Would you like a drink?",
                                synonyms: ["beverage"],
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
    }

    // MARK: - Hit and miss

    func testStoreThenCachedResultRoundTrips() throws {
        let entries = makeEntries()
        service.store(entries: entries, for: "drink")

        let result = try XCTUnwrap(service.cachedResult(for: "drink"))

        XCTAssertEqual(result.entries, entries)
        XCTAssertFalse(result.isExpired)
    }

    func testCachedResultMissReturnsNil() {
        XCTAssertNil(service.cachedResult(for: "unstored"))
    }

    // MARK: - Expiration

    func testEntryOlderThanSevenDaysIsReturnedAsExpired() throws {
        let entries = makeEntries()
        let data = try JSONEncoder().encode(entries)
        let eightDaysAgo = Date.now.addingTimeInterval(-8 * 24 * 60 * 60)
        container.mainContext.insert(
            CachedDictionaryEntry(
                normalizedWord: "drink",
                responseData: data,
                fetchedAt: eightDaysAgo,
                lastAccessedAt: eightDaysAgo
            )
        )
        try container.mainContext.save()

        let result = try XCTUnwrap(service.cachedResult(for: "drink"))

        XCTAssertTrue(result.isExpired)
        XCTAssertEqual(result.entries, entries)
        XCTAssertEqual(
            result.fetchedAt.timeIntervalSince1970,
            eightDaysAgo.timeIntervalSince1970,
            accuracy: 1
        )
    }

    // MARK: - Refresh

    func testStoringSameWordTwiceRefreshesExistingRow() throws {
        let staleDate = Date.now.addingTimeInterval(-60 * 60)
        let staleData = try JSONEncoder().encode(makeEntries())
        container.mainContext.insert(
            CachedDictionaryEntry(
                normalizedWord: "drink",
                responseData: staleData,
                fetchedAt: staleDate,
                lastAccessedAt: staleDate
            )
        )
        try container.mainContext.save()

        let refreshed = makeEntries(word: "drink refreshed")
        service.store(entries: refreshed, for: "drink")

        XCTAssertEqual(service.entryCount(), 1)
        let result = try XCTUnwrap(service.cachedResult(for: "drink"))
        XCTAssertEqual(result.entries, refreshed)
        XCTAssertGreaterThan(result.fetchedAt, staleDate)
        XCTAssertFalse(result.isExpired)
    }

    // MARK: - Clearing

    func testClearAllRemovesAllEntries() throws {
        service.store(entries: makeEntries(), for: "drink")
        service.store(entries: makeEntries(word: "quaff"), for: "quaff")
        XCTAssertEqual(service.entryCount(), 2)

        try service.clearAll()

        XCTAssertEqual(service.entryCount(), 0)
        XCTAssertNil(service.cachedResult(for: "drink"))
    }
}
