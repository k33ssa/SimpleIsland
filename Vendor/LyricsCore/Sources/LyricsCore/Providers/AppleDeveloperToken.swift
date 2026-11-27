import Foundation

/// Developer token веб-плеера music.apple.com. Добывается в рантайме из JS-бандла страницы
/// (в репозиторий и сборку не зашивается), хранится до `exp`. Значение токена никогда не логируется.
public actor AppleDeveloperTokenProvider {
    struct Stored: Codable { var token: String; var exp: TimeInterval }

    private let http: HTTPClient
    private let store: CredentialStore?
    private let now: @Sendable () -> Date
    private let pageURL: URL
    /// Запас до `exp`: токен, до конца которого осталось меньше, считается просроченным.
    private let safetyMargin: TimeInterval = 3600
    private var memory: Stored?
    private var inflight: Task<String, Error>?

    public init(http: HTTPClient, store: CredentialStore? = nil,
                pageURL: URL = URL(string: "https://music.apple.com/us/browse")!,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.http = http
        self.store = store
        self.pageURL = pageURL
        self.now = now
    }

    /// Действующий токен; при необходимости скачивает бандл заново.
    public func token(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh {
            if let m = memory, isValid(m) { return m.token }
            if let s = try? await loadStored(), isValid(s) {
                memory = s
                return s.token
            }
        }
        if let t = inflight { return try await t.value }
        let task = Task<String, Error> { [self] in try await scrape() }
        inflight = task
        defer { inflight = nil }
        let t = try await task.value
        return t
    }

    /// Сбросить кэш (после 401/403).
    public func invalidate() async {
        memory = nil
        try? await store?.set(nil, for: .appleDeveloperToken)
    }

    // MARK: -

    private func isValid(_ s: Stored) -> Bool { s.exp - safetyMargin > now().timeIntervalSince1970 }

    private func loadStored() async throws -> Stored? {
        guard let json = try await store?.value(for: .appleDeveloperToken), let d = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Stored.self, from: d)
    }

    private func scrape() async throws -> String {
        Log.net.info("apple: ищу developer token в бандле веб-плеера")
        let page = try await http.send(.make(pageURL, headers: ["User-Agent": UserAgent.browser, "Accept": "text/html"], timeout: 12))
        try page.requireOK()
        let html = page.text
        let scripts = Self.scriptPaths(inHTML: html)
        guard !scripts.isEmpty else { throw LyricsError.badResponse("в странице music.apple.com нет скриптов") }

        var best: Stored?
        for path in scripts.prefix(8) {
            guard let url = URL(string: path, relativeTo: URL(string: "https://music.apple.com"))?.absoluteURL else { continue }
            let js = try await http.send(.make(url, headers: ["User-Agent": UserAgent.browser, "Accept": "*/*",
                                                              "Referer": "https://music.apple.com/"], timeout: 20))
            guard (200..<300).contains(js.status) else { continue }
            if let found = Self.findToken(inJS: js.text) {
                if best == nil || found.exp > best!.exp { best = found }
                if best != nil { break }
            }
        }
        guard let tok = best else { throw LyricsError.badResponse("developer token в бандле не найден") }
        guard tok.exp > now().timeIntervalSince1970 else { throw LyricsError.badResponse("найденный developer token просрочен") }
        memory = tok
        if let store, let d = try? JSONEncoder().encode(tok), let s = String(data: d, encoding: .utf8) {
            try? await store.set(s, for: .appleDeveloperToken)
        }
        Log.net.info("apple: developer token получен, действует до \(Date(timeIntervalSince1970: tok.exp).formatted(date: .abbreviated, time: .omitted), privacy: .public)")
        return tok.token
    }

    // MARK: разбор (доступно тестам)

    /// Пути `/assets/*.js` из HTML, главный бандл (`index…`) первым.
    static func scriptPaths(inHTML html: String) -> [String] {
        var paths: [String] = []
        for m in html.matches(of: /<script[^>]+src="([^"]+\.js)"/) {
            let p = String(m.output.1)
            if p.hasPrefix("http") && !p.contains("apple.com") { continue }
            if !paths.contains(p) { paths.append(p) }
        }
        return paths.sorted { a, b in
            let ia = a.contains("/index") ? 0 : 1, ib = b.contains("/index") ? 0 : 1
            return ia < ib
        }
    }

    /// Ищет в JS любой JWT с `iss=AMPWebPlay` (имя переменной не важно — оно меняется).
    static func findToken(inJS js: String) -> Stored? {
        var best: Stored?
        for m in js.matches(of: /eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/) {
            let tok = String(m.output)
            guard let payload = decodePayload(tok) else { continue }
            guard (payload["iss"] as? String) == "AMPWebPlay", let exp = (payload["exp"] as? NSNumber)?.doubleValue else { continue }
            if best == nil || exp > best!.exp { best = Stored(token: tok, exp: exp) }
        }
        return best
    }

    static func decodePayload(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let d = Data(base64Encoded: b64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }
}
