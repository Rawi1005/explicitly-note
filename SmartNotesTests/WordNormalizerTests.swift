import XCTest
@testable import SmartNotes

final class WordNormalizerTests: XCTestCase {

    // MARK: - Cleaning

    func testTrimsSurroundingWhitespace() throws {
        XCTAssertEqual(try WordNormalizer.normalize("  drink \n"), "drink")
    }

    func testStripsPunctuation() throws {
        XCTAssertEqual(try WordNormalizer.normalize("drink!,"), "drink")
    }

    func testLowercases() throws {
        XCTAssertEqual(try WordNormalizer.normalize("Drink"), "drink")
    }

    func testPhraseKeepsInternalSpace() throws {
        XCTAssertEqual(try WordNormalizer.normalize("ice cream"), "ice cream")
    }

    // MARK: - Rejections

    func testEmptyStringThrowsEmptySelection() {
        XCTAssertThrowsError(try WordNormalizer.normalize("")) { error in
            XCTAssertEqual(error as? DictionaryError, .emptySelection)
        }
    }

    func testWhitespaceOnlyThrowsEmptySelection() {
        XCTAssertThrowsError(try WordNormalizer.normalize("   \n\t ")) { error in
            XCTAssertEqual(error as? DictionaryError, .emptySelection)
        }
    }

    func testOverlongSelectionThrowsInvalidSelection() {
        let overlong = String(repeating: "a", count: WordNormalizer.maximumLength + 1)
        XCTAssertThrowsError(try WordNormalizer.normalize(overlong)) { error in
            guard case .invalidSelection = error as? DictionaryError else {
                XCTFail("Expected DictionaryError.invalidSelection, got \(error)")
                return
            }
        }
    }

    func testPunctuationOnlyThrowsInvalidSelection() {
        XCTAssertThrowsError(try WordNormalizer.normalize("!?.,;")) { error in
            guard case .invalidSelection = error as? DictionaryError else {
                XCTFail("Expected DictionaryError.invalidSelection, got \(error)")
                return
            }
        }
    }
}
