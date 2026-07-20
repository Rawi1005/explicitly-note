import Foundation

// MARK: - Errors

enum DictionaryError: Error, LocalizedError, Equatable {
    case emptySelection
    case invalidSelection(reason: String)
    case invalidURL
    case wordNotFound(word: String)
    case serverError(statusCode: Int)
    case invalidResponse
    case decodingFailed
    case noConnection
    case network(description: String)

    var errorDescription: String? {
        switch self {
        case .emptySelection:
            "Select a word first, then tap Define."
        case .invalidSelection(let reason):
            reason
        case .invalidURL:
            "That selection can't be turned into a dictionary search."
        case .wordNotFound(let word):
            "No definition found for “\(word)”. Check the spelling or try a simpler form of the word."
        case .serverError(let statusCode):
            "The dictionary service returned an error (code \(statusCode)). Please try again later."
        case .invalidResponse:
            "The dictionary service returned an unexpected response."
        case .decodingFailed:
            "The dictionary response couldn't be read."
        case .noConnection:
            "No internet connection. Previously looked-up words are still available from the cache."
        case .network(let description):
            "Network error: \(description)"
        }
    }
}

// MARK: - Word normalization

enum WordNormalizer {
    static let maximumLength = 50

    /// Cleans a raw text selection into a dictionary-searchable term:
    /// trims whitespace, strips punctuation, lowercases, and rejects
    /// empty or over-long selections with a user-facing error.
    static func normalize(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DictionaryError.emptySelection
        }
        guard trimmed.count <= maximumLength else {
            throw DictionaryError.invalidSelection(
                reason: "Selections longer than \(maximumLength) characters can't be looked up. Select a single word or a short phrase."
            )
        }
        let scalars = trimmed.unicodeScalars.filter { !CharacterSet.punctuationCharacters.contains($0) }
        let cleaned = String(String.UnicodeScalarView(scalars))
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw DictionaryError.invalidSelection(
                reason: "The selection only contains punctuation. Select a word instead."
            )
        }
        return cleaned
    }
}

// MARK: - Service

protocol DictionaryServiceProtocol: Sendable {
    /// Looks up an already-normalized word. Throws `DictionaryError`.
    func lookup(word: String) async throws -> [DictionaryEntry]
}

struct DictionaryService: DictionaryServiceProtocol {
    private let session: URLSession

    /// Session is injected so tests can substitute a `URLProtocol` mock.
    init(session: URLSession = .shared) {
        self.session = session
    }

    func lookup(word: String) async throws -> [DictionaryEntry] {
        // URLComponents percent-encodes the path segment for us,
        // so words with spaces or diacritics build a valid URL.
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.dictionaryapi.dev"
        components.path = "/api/v2/entries/en/\(word)"
        guard let url = components.url else {
            throw DictionaryError.invalidURL
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch let urlError as URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                throw DictionaryError.noConnection
            default:
                throw DictionaryError.network(description: urlError.localizedDescription)
            }
        } catch {
            throw DictionaryError.network(description: error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw DictionaryError.invalidResponse
        }

        switch http.statusCode {
        case 200:
            do {
                return try JSONDecoder().decode([DictionaryEntry].self, from: data)
            } catch {
                throw DictionaryError.decodingFailed
            }
        case 404:
            // The 404 body has a different JSON shape (title/message/resolution);
            // it is intentionally not decoded as [DictionaryEntry].
            throw DictionaryError.wordNotFound(word: word)
        default:
            throw DictionaryError.serverError(statusCode: http.statusCode)
        }
    }
}
