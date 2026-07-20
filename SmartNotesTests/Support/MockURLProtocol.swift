import Foundation

/// URLProtocol mock that intercepts every request made through a session
/// built with `makeSession()` and answers it with the static `handler`.
/// Tests set the handler, then inject the session into `DictionaryService`.
final class MockURLProtocol: URLProtocol {
    /// Set by each test to produce a response (or throw) for a request.
    /// Tests run serially, so unsynchronized access is safe here.
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    /// A URLSession whose only protocol class is this mock, so no request
    /// ever reaches the real network.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = MockURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        // Nothing to cancel: responses are delivered synchronously.
    }
}
