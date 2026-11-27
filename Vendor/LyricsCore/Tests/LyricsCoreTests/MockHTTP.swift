import Foundation
@testable import LyricsCore

/// Заглушка транспорта: ответы по подстроке URL, запись запросов.
final class MockHTTP: HTTPClient, @unchecked Sendable {
    struct Route {
        var match: @Sendable (URLRequest) -> Bool
        var respond: @Sendable (URLRequest) throws -> HTTPResponse
    }
    private let lock = NSLock()
    private var routes: [Route] = []
    private(set) var requests: [URLRequest] = []

    func on(_ substring: String, method: String? = nil, status: Int = 200, body: String = "", headers: [String: String] = [:]) {
        on(substring, method: method) { _ in HTTPResponse(data: Data(body.utf8), status: status, headers: headers) }
    }

    func on(_ substring: String, method: String? = nil, _ handler: @escaping @Sendable (URLRequest) throws -> HTTPResponse) {
        lock.lock(); defer { lock.unlock() }
        routes.insert(Route(match: { r in
            (r.url?.absoluteString.contains(substring) ?? false) && (method == nil || r.httpMethod == method)
        }, respond: handler), at: 0)   // более поздние правила приоритетнее
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        lock.lock()
        requests.append(request)
        let route = routes.first { $0.match(request) }
        lock.unlock()
        guard let route else { return HTTPResponse(data: Data("no route".utf8), status: 599) }
        return try route.respond(request)
    }

    func requests(containing s: String) -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests.filter { $0.url?.absoluteString.contains(s) ?? false }
    }
}

func json(_ obj: Any) -> String {
    String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
}
