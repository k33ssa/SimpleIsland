import Foundation

public struct HTTPResponse: Sendable {
    public var data: Data
    public var status: Int
    public var headers: [String: String]

    public init(data: Data, status: Int, headers: [String: String] = [:]) {
        self.data = data
        self.status = status
        self.headers = headers
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.key.lowercased() == name.lowercased() }?.value
    }

    public var text: String { String(decoding: data, as: UTF8.self) }

    /// Секунды из `Retry-After`, если число.
    public var retryAfter: TimeInterval? { header("Retry-After").flatMap { Double($0) } }
}

/// Транспорт. В тестах подменяется заглушкой.
public protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession
    private let timeout: TimeInterval
    private let retries: Int

    /// `retries` — сколько раз повторить GET после быстрого временного сбоя (обрыв соединения, HTTP 502/503/504,
    /// 429 с `Retry-After` ≤ 2 с). Таймауты не повторяются: это удвоило бы ожидание.
    public init(timeout: TimeInterval = 10, session: URLSession? = nil, retries: Int = 1) {
        self.timeout = timeout
        self.retries = max(0, retries)
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = timeout
            cfg.timeoutIntervalForResource = timeout * 2
            cfg.waitsForConnectivity = false
            cfg.httpCookieStorage = nil
            cfg.httpShouldSetCookies = false
            cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: cfg)
        }
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        var req = request
        if req.timeoutInterval == 60 { req.timeoutInterval = timeout }  // 60 — значение по умолчанию у URLRequest
        let idempotent = (req.httpMethod ?? "GET") == "GET"
        var attempt = 0
        while true {
            do {
                let r = try await sendOnce(req)
                if idempotent, attempt < retries, let wait = Self.retryDelay(status: r.status, retryAfter: r.retryAfter) {
                    attempt += 1
                    try await pause(wait)
                    continue
                }
                return r
            } catch let e as LyricsError where idempotent && attempt < retries && e == .network("соединение прервано") {
                attempt += 1
                try await pause(0.3)
            }
        }
    }

    /// Пауза перед повтором или `nil`, если повторять не надо.
    static func retryDelay(status: Int, retryAfter: TimeInterval?) -> TimeInterval? {
        switch status {
        case 502, 503, 504: return 0.4
        case 429:
            guard let r = retryAfter else { return 0.8 }
            return r <= 2 ? max(0.2, r) : nil
        default: return nil
        }
    }

    private func sendOnce(_ req: URLRequest) async throws -> HTTPResponse {
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw LyricsError.badResponse("не HTTP") }
            var headers: [String: String] = [:]
            for (k, v) in http.allHeaderFields { headers[String(describing: k)] = String(describing: v) }
            return HTTPResponse(data: data, status: http.statusCode, headers: headers)
        } catch is CancellationError {
            throw LyricsError.cancelled
        } catch let e as URLError where e.code == .cancelled {
            throw LyricsError.cancelled
        } catch let e as LyricsError {
            throw e
        } catch let e as URLError {
            // В описание кладём только код: URL и заголовки (там могут быть токены) не попадают в ошибку.
            throw LyricsError.from(e)
        } catch {
            throw LyricsError.network("\(type(of: error))")
        }
    }
}

extension URLRequest {
    /// Запрос с заголовками. Значения заголовков в логи не пишем.
    static func make(_ url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil,
                     timeout: TimeInterval = 10) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.timeoutInterval = timeout
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        r.httpBody = body
        return r
    }
}

enum URLBuilder {
    static func url(_ base: String, query: [(String, String)]) -> URL? {
        var c = URLComponents(string: base)
        c?.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        // URLComponents не кодирует «+» и «&» внутри значения как надо — доделаем вручную.
        if let items = c?.queryItems {
            let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=#;"))
            c?.percentEncodedQueryItems = items.map {
                URLQueryItem(name: $0.name.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.name,
                             value: $0.value?.addingPercentEncoding(withAllowedCharacters: allowed))
            }
        }
        return c?.url
    }
}

/// Проверка статуса с единым отображением в `LyricsError`.
extension HTTPResponse {
    /// Тело похоже на HTML (страница-заглушка, капча, блокировка провайдера) — вместо ожидаемого JSON/XML.
    var looksLikeHTML: Bool {
        let head = data.prefix(256)
        guard let s = String(data: head, encoding: .utf8) ?? String(data: head, encoding: .isoLatin1) else { return false }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return t.hasPrefix("<!doctype html") || t.hasPrefix("<html") || t.contains("<head") || t.contains("<body")
    }

    /// `requireOK` + проверка, что пришёл не HTML. `who` — для текста ошибки.
    func requireJSON(_ who: String, allowNotFound: Bool = false) throws {
        try requireOK(allowNotFound: allowNotFound)
        if looksLikeHTML { throw LyricsError.badResponse("\(who): HTML вместо JSON (капча/блокировка?)") }
    }

    func requireOK(allowNotFound: Bool = false) throws {
        switch status {
        case 200..<300: return
        case 404 where allowNotFound: throw LyricsError.notFound
        case 401, 403: throw LyricsError.unauthorized
        case 429: throw LyricsError.rateLimited(retryAfter: retryAfter)
        default: throw LyricsError.badStatus(status)
        }
    }
}
