import XCTest
import SwiftData
@testable import SmartNotes

@MainActor
final class VocabularyServiceTests: XCTestCase {
    private var container: ModelContainer!
    private var service: VocabularyService!

    override func setUp() async throws {
        try await super.setUp()
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: VocabularyItem.self, configurations: configuration)
        service = VocabularyService(modelContext: container.mainContext)
    }

    override func tearDown() async throws {
        service = nil
        container = nil
        try await super.tearDown()
    }

    private func itemCount() throws -> Int {
        try container.mainContext.fetchCount(FetchDescriptor<VocabularyItem>())
    }

    // MARK: - Saving

    func testSaveWordCreatesNewItemWithPersistedFields() throws {
        let (item, isNew) = try service.saveWord(
            word: "drink",
            shortDefinition: "A beverage.",
            partOfSpeech: "noun",
            sourceNoteTitle: "Cooking Notes"
        )

        XCTAssertTrue(isNew)
        XCTAssertEqual(item.word, "drink")
        XCTAssertEqual(item.normalizedWord, "drink")
        XCTAssertEqual(item.shortDefinition, "A beverage.")
        XCTAssertEqual(item.partOfSpeech, "noun")
        XCTAssertEqual(item.sourceNoteTitle, "Cooking Notes")
        XCTAssertEqual(try itemCount(), 1)
    }

    func testSavingSameWordWithDifferentCasingAndWhitespaceIsNotDuplicated() throws {
        let (original, firstIsNew) = try service.saveWord(
            word: "drink",
            shortDefinition: "A beverage.",
            partOfSpeech: "noun",
            sourceNoteTitle: nil
        )
        XCTAssertTrue(firstIsNew)

        let (existing, secondIsNew) = try service.saveWord(
            word: " Drink ",
            shortDefinition: "A different definition.",
            partOfSpeech: "verb",
            sourceNoteTitle: "Other Note"
        )

        XCTAssertFalse(secondIsNew)
        XCTAssertEqual(existing.id, original.id)
        XCTAssertEqual(existing.shortDefinition, "A beverage.")
        XCTAssertEqual(try itemCount(), 1)
    }

    // MARK: - isSaved

    func testIsSavedReflectsStoredWords() throws {
        XCTAssertFalse(service.isSaved(normalizedWord: "drink"))

        try service.saveWord(
            word: "Drink",
            shortDefinition: "A beverage.",
            partOfSpeech: nil,
            sourceNoteTitle: nil
        )

        XCTAssertTrue(service.isSaved(normalizedWord: "drink"))
        XCTAssertFalse(service.isSaved(normalizedWord: "quaff"))
    }

    // MARK: - Deleting

    func testDeleteRemovesItem() throws {
        let (item, _) = try service.saveWord(
            word: "drink",
            shortDefinition: "A beverage.",
            partOfSpeech: nil,
            sourceNoteTitle: nil
        )
        XCTAssertEqual(try itemCount(), 1)

        try service.delete(item)

        XCTAssertEqual(try itemCount(), 0)
        XCTAssertFalse(service.isSaved(normalizedWord: "drink"))
    }
}
