import XCTest
@testable import SmartNotes

final class DictionaryDecodingTests: XCTestCase {

    // MARK: - Fixture loading

    private func loadFixtureEntries() throws -> [DictionaryEntry] {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "drink", withExtension: "json"),
            "drink.json fixture missing from test bundle"
        )
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([DictionaryEntry].self, from: data)
    }

    // MARK: - Fixture decoding

    func testDecodesFixtureWordAndMeaningCounts() throws {
        let entries = try loadFixtureEntries()

        XCTAssertEqual(entries.count, 2)

        let first = try XCTUnwrap(entries.first)
        XCTAssertEqual(first.word, "drink")
        XCTAssertEqual(first.phonetic, "/drɪŋk/")
        XCTAssertEqual(first.phonetics?.count, 2)
        XCTAssertEqual(first.meanings?.count, 2)
        XCTAssertEqual(first.sourceUrls, ["https://en.wiktionary.org/wiki/drink"])

        let noun = try XCTUnwrap(first.meanings?.first)
        XCTAssertEqual(noun.partOfSpeech, "noun")
        XCTAssertEqual(noun.definitions?.count, 3)
        XCTAssertEqual(noun.definitions?.first?.example, "Would you like a drink of water?")
        XCTAssertEqual(noun.definitions?.first?.synonyms, ["beverage"])

        let verb = try XCTUnwrap(first.meanings?.last)
        XCTAssertEqual(verb.partOfSpeech, "verb")
        XCTAssertEqual(verb.definitions?.count, 2)
    }

    func testFixtureToleratesMissingOptionalFields() throws {
        let entries = try loadFixtureEntries()

        // Second entry omits phonetic and sourceUrls entirely.
        let second = try XCTUnwrap(entries.last)
        XCTAssertEqual(second.word, "drink")
        XCTAssertNil(second.phonetic)
        XCTAssertNil(second.sourceUrls)

        // Its only phonetic has no text; its only definition has no example.
        let phonetic = try XCTUnwrap(second.phonetics?.first)
        XCTAssertNil(phonetic.text)
        let definition = try XCTUnwrap(second.meanings?.first?.definitions?.first)
        XCTAssertNil(definition.example)
        XCTAssertNil(definition.synonyms)

        // First entry's third noun definition omits example; verb's second
        // definition omits example and synonyms.
        let first = try XCTUnwrap(entries.first)
        let thirdNounDefinition = try XCTUnwrap(first.meanings?.first?.definitions?.last)
        XCTAssertNil(thirdNounDefinition.example)
        let secondVerbDefinition = try XCTUnwrap(first.meanings?.last?.definitions?.last)
        XCTAssertNil(secondVerbDefinition.example)
        XCTAssertNil(secondVerbDefinition.synonyms)
    }

    func testDecodesMinimalEntryWithOnlyWord() throws {
        let json = #"[{"word":"terse"}]"#
        let data = try XCTUnwrap(json.data(using: .utf8))

        let entries = try JSONDecoder().decode([DictionaryEntry].self, from: data)

        XCTAssertEqual(entries.count, 1)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.word, "terse")
        XCTAssertNil(entry.phonetic)
        XCTAssertNil(entry.phonetics)
        XCTAssertNil(entry.meanings)
        XCTAssertNil(entry.sourceUrls)
    }

    // MARK: - bestAudioURL

    func testBestAudioURLSkipsEmptyAudioStrings() throws {
        let entry = DictionaryEntry(
            word: "drink",
            phonetic: nil,
            phonetics: [
                Phonetic(text: "/drɪŋk/", audio: ""),
                Phonetic(text: nil, audio: nil),
                Phonetic(text: nil, audio: "https://example.com/drink.mp3")
            ],
            meanings: nil,
            sourceUrls: nil
        )

        let url = try XCTUnwrap(entry.bestAudioURL)
        XCTAssertEqual(url.absoluteString, "https://example.com/drink.mp3")
    }

    func testBestAudioURLIsNilWhenNoUsableAudio() {
        let entry = DictionaryEntry(
            word: "drink",
            phonetic: nil,
            phonetics: [Phonetic(text: "/drɪŋk/", audio: "")],
            meanings: nil,
            sourceUrls: nil
        )
        XCTAssertNil(entry.bestAudioURL)

        let entryWithoutPhonetics = DictionaryEntry(
            word: "drink",
            phonetic: nil,
            phonetics: nil,
            meanings: nil,
            sourceUrls: nil
        )
        XCTAssertNil(entryWithoutPhonetics.bestAudioURL)
    }

    // MARK: - displayPhonetic

    func testDisplayPhoneticPrefersTopLevelPhonetic() {
        let entry = DictionaryEntry(
            word: "drink",
            phonetic: "/drɪŋk/",
            phonetics: [Phonetic(text: "/dɹɪŋk/", audio: nil)],
            meanings: nil,
            sourceUrls: nil
        )
        XCTAssertEqual(entry.displayPhonetic, "/drɪŋk/")
    }

    func testDisplayPhoneticFallsBackToFirstPhoneticsEntryWithText() {
        let entry = DictionaryEntry(
            word: "drink",
            phonetic: nil,
            phonetics: [
                Phonetic(text: nil, audio: "https://example.com/a.mp3"),
                Phonetic(text: "", audio: nil),
                Phonetic(text: "/dɹɪŋk/", audio: nil)
            ],
            meanings: nil,
            sourceUrls: nil
        )
        XCTAssertEqual(entry.displayPhonetic, "/dɹɪŋk/")
    }

    func testDisplayPhoneticFallsBackWhenTopLevelPhoneticIsEmpty() {
        let entry = DictionaryEntry(
            word: "drink",
            phonetic: "",
            phonetics: [Phonetic(text: "/dɹɪŋk/", audio: nil)],
            meanings: nil,
            sourceUrls: nil
        )
        XCTAssertEqual(entry.displayPhonetic, "/dɹɪŋk/")
    }

    func testDisplayPhoneticIsNilWhenNothingUsable() {
        let entry = DictionaryEntry(
            word: "drink",
            phonetic: nil,
            phonetics: nil,
            meanings: nil,
            sourceUrls: nil
        )
        XCTAssertNil(entry.displayPhonetic)
    }
}
