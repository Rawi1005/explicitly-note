import XCTest
@testable import Gloss

final class DictionaryServiceTests: XCTestCase {
    private var service: DictionaryService!

    override func setUp() {
        super.setUp()
        service = DictionaryService(session: MockURLProtocol.makeSession())
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        service = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func fixtureData() throws -> Data {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "drink", withExtension: "json"),
            "drink.json fixture missing from test bundle"
        )
        return try Data(contentsOf: url)
    }

    private static func response(statusCode: Int, for request: URLRequest) throws -> HTTPURLResponse {
        let url = try XCTUnwrap(request.url)
        return try XCTUnwrap(
            HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: nil)
        )
    }

    // MARK: - Success

    func testLookupSuccessReturnsDecodedEntries() async throws {
        let data = try fixtureData()
        MockURLProtocol.handler = { request in
            (try Self.response(statusCode: 200, for: request), data)
        }

        let entries = try await service.lookup(word: "drink")

        XCTAssertEqual(entries.count, 2)
        let first = try XCTUnwrap(entries.first)
        XCTAssertEqual(first.word, "drink")
        XCTAssertEqual(first.meanings?.count, 2)
    }

    // MARK: - 404

    func testLookup404ThrowsWordNotFound() async throws {
        let notFoundBody = Data("""
        {
          "title": "No Definitions Found",
          "message": "Sorry pal, we couldn't find definitions for the word you were looking for.",
          "resolution": "You can try the search again at later time or head to the web instead."
        }
        """.utf8)
        MockURLProtocol.handler = { request in
            (try Self.response(statusCode: 404, for: request), notFoundBody)
        }

        do {
            _ = try await service.lookup(word: "asdfghjkl")
            XCTFail("Expected DictionaryError.wordNotFound")
        } catch let error as DictionaryError {
            XCTAssertEqual(error, .wordNotFound(word: "asdfghjkl"))
        }
    }

    // MARK: - Decoding failure

    func testLookupInvalidJSONThrowsDecodingFailed() async throws {
        MockURLProtocol.handler = { request in
            (try Self.response(statusCode: 200, for: request), Data("not json at all".utf8))
        }

        do {
            _ = try await service.lookup(word: "drink")
            XCTFail("Expected DictionaryError.decodingFailed")
        } catch let error as DictionaryError {
            XCTAssertEqual(error, .decodingFailed)
        }
    }

    // MARK: - Server error

    func testLookup500ThrowsServerError() async throws {
        MockURLProtocol.handler = { request in
            (try Self.response(statusCode: 500, for: request), Data())
        }

        do {
            _ = try await service.lookup(word: "drink")
            XCTFail("Expected DictionaryError.serverError")
        } catch let error as DictionaryError {
            XCTAssertEqual(error, .serverError(statusCode: 500))
        }
    }

    // MARK: - URL construction

    func testLookupPercentEncodesWordWithSpace() async throws {
        final class RequestCapture {
            var url: URL?
        }
        let capture = RequestCapture()
        let data = Data("[]".utf8)
        MockURLProtocol.handler = { request in
            capture.url = request.url
            return (try Self.response(statusCode: 200, for: request), data)
        }

        _ = try await service.lookup(word: "ice cream")

        let url = try XCTUnwrap(capture.url)
        XCTAssertEqual(url.host, "api.dictionaryapi.dev")
        XCTAssertTrue(
            url.absoluteString.contains("/api/v2/entries/en/ice%20cream"),
            "Expected percent-encoded path, got \(url.absoluteString)"
        )
    }
}
