import Foundation

// Клиент Sten («протокол встреч»): тот же API, что у веб-приложения (`/sten/api/...`), сессия — cookie.
// Схема ответов взята из фронтенда сайта (16.11.2026, бандл /sten/assets): живых протоколов у аккаунта на тот момент
// не было, поэтому разбор терпимый — нет поля, пришло число вместо строки, лишние поля — не ошибка.

/// Адрес сервера: то, что ввёл пользователь, приведённое к корню приложения (`https://host/sten`).
public struct StenServer: Equatable, Sendable {
    /// Адрес по умолчанию: ключ `SimpleIslandStenServer` в Info.plist (build.sh --meetings-server), иначе пусто.
    public static var defaultAddress: String {
        (Bundle.main.object(forInfoDictionaryKey: "SimpleIslandStenServer") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    /// Подсказка в поле адреса.
    public static let placeholderAddress = "https://sten.example.com/sten"

    /// Корень веб-приложения без завершающего `/` (`https://host/sten`).
    public let root: URL

    /// «host/sten/m/138/consensus», «https://host/sten/», «https://host/sten/api» → `https://host/sten`.
    /// Без схемы — https. Пусто или мусор — nil.
    public init?(_ text: String) {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "https://" + s }
        guard var c = URLComponents(string: s), let scheme = c.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = c.host, !host.isEmpty else { return nil }
        c.query = nil; c.fragment = nil
        var path = c.path
        // Ссылка на страницу встречи/процесса/приглашения — отрезать до корня приложения.
        for marker in ["/m/", "/p/", "/api/"] {
            if let r = path.range(of: marker) { path = String(path[..<r.lowerBound]) }
        }
        if path.hasSuffix("/api") { path = String(path.dropLast(4)) }
        while path.hasSuffix("/") { path.removeLast() }
        c.path = path
        guard let url = c.url else { return nil }
        root = url
    }

    public var display: String { root.absoluteString }
    /// Ключ сессии в Keychain: хост + путь (туннель сменился — старый cookie к новому адресу не подставляется).
    public var account: String { (root.host ?? "") + root.path }

    public func api(_ path: String) -> URL { URL(string: root.absoluteString + "/api" + path)! }
    /// Страница протокола на сайте.
    public func consensusPage(_ id: Int) -> URL { URL(string: root.absoluteString + "/m/\(id)/consensus")! }
}

public enum StenError: Error, Equatable, LocalizedError {
    /// 401: сессии нет или истекла — снова форма входа.
    case unauthorized(String)
    /// 404: встречи нет или она чужая.
    case notFound
    /// 409: уже загружено / сервер занят.
    case conflict(String)
    case http(Int, String)
    case network(String)
    case badResponse

    public var errorDescription: String? {
        switch self {
        case .unauthorized(let d): return d.isEmpty ? "Нужно войти" : d
        case .notFound: return "Встреча не найдена или нет доступа"
        case .conflict(let d): return d.isEmpty ? "Сервер занят" : d
        case .http(let code, let d): return d.isEmpty ? "Ошибка сервера \(code)" : "\(d) (\(code))"
        case .network(let d): return "Нет связи с сервером: \(d)"
        case .badResponse: return "Непонятный ответ сервера"
        }
    }
}

// MARK: - Модели (терпимый разбор)

public struct StenMeeting: Identifiable, Equatable, Sendable {
    public var id: Int
    public var title: String
    public var createdAt: Date?
    /// recording / processing / ready / consensus / error; в списке может не прийти.
    public var status: String?

    public init(id: Int, title: String, createdAt: Date? = nil, status: String? = nil) {
        self.id = id; self.title = title; self.createdAt = createdAt; self.status = status
    }

    init?(json: Any) {
        guard let o = json as? [String: Any], let id = J.int(o["id"]) else { return nil }
        self.id = id
        title = J.str(o["title"]) ?? "Встреча \(id)"
        createdAt = J.date(o["created_at"] ?? o["createdAt"])
        status = J.str(o["status"])
    }
}

public struct StenStatus: Equatable, Sendable {
    public var status: String
    /// 0…100.
    public var percent: Double?
    public var label: String?
    public var step: Int?
    public var error: String?

    public init(status: String, percent: Double? = nil, label: String? = nil, step: Int? = nil, error: String? = nil) {
        self.status = status; self.percent = percent; self.label = label; self.step = step; self.error = error
    }

    init?(json: Any) {
        guard let o = json as? [String: Any], let s = J.str(o["status"]) else { return nil }
        status = s
        error = J.str(o["error"])
        if let p = o["progress"] as? [String: Any] {
            percent = J.double(p["percent"])
            label = J.str(p["label"])
            step = J.int(p["step"])
        } else {
            // Вдруг прогресс — просто число (0…1 или 0…100).
            percent = J.double(o["progress"]).map { $0 <= 1 ? $0 * 100 : $0 }
        }
    }

    public var isReady: Bool { status == "ready" || status == "consensus" }
    public var isError: Bool { status == "error" }
    /// Идёт обработка (опрашивать дальше).
    public var isWorking: Bool { !isReady && !isError && status != "recording" }
}

public struct StenParticipant: Equatable, Sendable {
    public var speaker: String
    /// Что ещё сервер сказал о человеке (роль, вклад) — первое текстовое поле кроме имени.
    public var note: String?
}

public struct StenTopic: Equatable, Sendable { public var title: String; public var text: String }
public struct StenDecision: Equatable, Sendable { public var text: String; public var initiator: String? }
public struct StenTask: Equatable, Sendable {
    public var text: String
    public var assignee: String?
    public var due: String?
}

public struct StenReport: Equatable, Sendable {
    public var available = false
    public var title = ""
    public var summary = ""
    public var outcome = ""
    public var participants: [StenParticipant] = []
    public var topics: [StenTopic] = []
    public var decisions: [StenDecision] = []
    public var tasks: [StenTask] = []

    public init() {}

    public init(json: Any) {
        let o = (json as? [String: Any]) ?? [:]
        title = J.str(o["title"]) ?? ""
        summary = J.str(o["summary"]) ?? ""
        outcome = J.str(o["outcome"]) ?? ""
        participants = J.arr(o["participants"]).compactMap { p in
            if let s = p as? String { return StenParticipant(speaker: s, note: nil) }
            guard let d = p as? [String: Any] else { return nil }
            let name = J.str(d["speaker"]) ?? J.str(d["name"]) ?? ""
            guard !name.isEmpty else { return nil }
            let note = ["role", "summary", "contribution", "position", "text", "description"]
                .lazy.compactMap { J.str(d[$0]) }.first { !$0.isEmpty }
            return StenParticipant(speaker: name, note: note)
        }
        topics = J.arr(o["topics"]).compactMap { t in
            if let s = t as? String { return StenTopic(title: "", text: s) }
            guard let d = t as? [String: Any] else { return nil }
            let tt = J.str(d["title"]) ?? "", tx = J.str(d["text"]) ?? ""
            return tt.isEmpty && tx.isEmpty ? nil : StenTopic(title: tt, text: tx)
        }
        decisions = J.arr(o["decisions"]).compactMap { x in
            if let s = x as? String { return StenDecision(text: s, initiator: nil) }
            guard let d = x as? [String: Any], let t = J.str(d["text"]), !t.isEmpty else { return nil }
            return StenDecision(text: t, initiator: J.str(d["initiator"]).flatMap { $0.isEmpty ? nil : $0 })
        }
        tasks = J.arr(o["tasks"]).compactMap { x in
            if let s = x as? String { return StenTask(text: s, assignee: nil, due: nil) }
            guard let d = x as? [String: Any], let t = J.str(d["text"]), !t.isEmpty else { return nil }
            return StenTask(text: t, assignee: J.str(d["assignee"]).flatMap { $0.isEmpty ? nil : $0 },
                            due: J.str(d["due"]).flatMap { $0.isEmpty ? nil : $0 })
        }
        let hasContent = !title.isEmpty || !summary.isEmpty || !outcome.isEmpty || !participants.isEmpty
            || !topics.isEmpty || !decisions.isEmpty || !tasks.isEmpty
        available = (J.bool(o["available"]) ?? true) && hasContent
    }
}

/// Помощники разбора JSON: число строкой, строка числом, отсутствие — nil.
enum J {
    static func str(_ v: Any?) -> String? {
        switch v {
        case let s as String: return s.trimmingCharacters(in: .whitespacesAndNewlines)
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }
    static func int(_ v: Any?) -> Int? {
        switch v {
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }
    static func double(_ v: Any?) -> Double? {
        switch v {
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }
    static func bool(_ v: Any?) -> Bool? {
        switch v {
        case let n as NSNumber: return n.boolValue
        case let s as String: return ["true", "1", "yes"].contains(s.lowercased())
        default: return nil
        }
    }
    static func arr(_ v: Any?) -> [Any] { (v as? [Any]) ?? [] }

    static func date(_ v: Any?) -> Date? {
        if let n = v as? NSNumber {
            let t = n.doubleValue
            return Date(timeIntervalSince1970: t > 1e12 ? t / 1000 : t)
        }
        guard var s = v as? String, !s.isEmpty else { return nil }
        s = s.replacingOccurrences(of: " ", with: "T")
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: s) { return d }
        f1.formatOptions = [.withInternetDateTime]
        if let d = f1.date(from: s) { return d }
        // Без зоны — время сервера считаем UTC (как делает Python `datetime.utcnow().isoformat()`).
        let base = s.split(separator: ".").first.map(String.init) ?? s
        let f2 = DateFormatter()
        f2.locale = Locale(identifier: "en_US_POSIX")
        f2.timeZone = TimeZone(identifier: "UTC")
        f2.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f2.date(from: base)
    }

    static func object(_ data: Data) -> Any? { try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }

    /// `{"detail": "..."}` → текст; иначе — тело как есть (обрезано).
    static func detail(_ data: Data) -> String {
        if let o = object(data) as? [String: Any] {
            if let d = o["detail"] as? String { return d }
            if let arr = o["detail"] as? [[String: Any]], let m = arr.first?["msg"] as? String { return m }
        }
        let s = String(decoding: data.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.hasPrefix("<") ? "" : s
    }
}

// MARK: - Задачи по людям

/// Человек и всё, что на нём: задачи (ответственный), решения (инициатор), заметка участника.
public struct StenPersonGroup: Identifiable, Equatable, Sendable {
    public var name: String
    public var note: String?
    public var tasks: [StenTask]
    public var decisions: [StenDecision]
    /// Группа «Без ответственного».
    public var isUnassigned: Bool
    public var id: String { isUnassigned ? "\u{0}unassigned" : StenGrouping.key(name) }
}

public enum StenGrouping {
    public static let unassignedTitle = "Без ответственного"

    static func key(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: "ё", with: "е")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// «Анна, Илья», «Анна и Илья», «Анна / Илья» → два человека.
    static func names(_ s: String?) -> [String] {
        guard let s, !s.isEmpty else { return [] }
        var parts = [s]
        for sep in [",", ";", "/", "&", " и ", " and "] {
            parts = parts.flatMap { $0.components(separatedBy: sep) }
        }
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// Порядок: участники как в отчёте, потом ответственные/инициаторы, которых нет среди участников, в конце —
    /// задачи без ответственного. Задача на двоих видна у обоих.
    public static func group(_ r: StenReport) -> [StenPersonGroup] {
        var order: [String] = []
        var groups: [String: StenPersonGroup] = [:]
        func ensure(_ name: String, note: String? = nil) -> String {
            let k = key(name)
            if groups[k] == nil {
                order.append(k)
                groups[k] = StenPersonGroup(name: name, note: note, tasks: [], decisions: [], isUnassigned: false)
            } else if groups[k]?.note == nil, let note {
                groups[k]?.note = note
            }
            return k
        }
        for p in r.participants { _ = ensure(p.speaker, note: p.note) }
        var unassigned: [StenTask] = []
        for t in r.tasks {
            let who = names(t.assignee)
            if who.isEmpty { unassigned.append(t); continue }
            for n in who { groups[ensure(n)]?.tasks.append(t) }
        }
        for d in r.decisions {
            for n in names(d.initiator) { groups[ensure(n)]?.decisions.append(d) }
        }
        var out = order.compactMap { groups[$0] }
        // Люди с задачами — выше молчавших; внутри — как в отчёте (сортировка устойчивая).
        out = out.enumerated().sorted { a, b in
            let wa = a.element.tasks.isEmpty && a.element.decisions.isEmpty ? 1 : 0
            let wb = b.element.tasks.isEmpty && b.element.decisions.isEmpty ? 1 : 0
            return wa != wb ? wa < wb : a.offset < b.offset
        }.map(\.element)
        if !unassigned.isEmpty {
            out.append(StenPersonGroup(name: unassignedTitle, note: nil, tasks: unassigned, decisions: [], isUnassigned: true))
        }
        return out
    }

    /// Текст «Копировать итог»: название, итог, резюме, решения, задачи по людям.
    public static func plainText(_ r: StenReport, meetingTitle: String, link: URL?) -> String {
        var lines: [String] = []
        lines.append(r.title.isEmpty ? meetingTitle : r.title)
        if !r.outcome.isEmpty { lines += ["", "Итог: " + r.outcome] }
        if !r.summary.isEmpty { lines += ["", "Кратко: " + r.summary] }
        if !r.decisions.isEmpty {
            lines += ["", "Решения:"]
            lines += r.decisions.map { "• " + $0.text + ($0.initiator.map { " — \($0)" } ?? "") }
        }
        let people = group(r).filter { !$0.tasks.isEmpty }
        if !people.isEmpty {
            lines += ["", "Задачи:"]
            for p in people {
                lines.append(p.name + ":")
                lines += p.tasks.map { "  • " + $0.text + ($0.due.map { " (срок: \($0))" } ?? "") }
            }
        }
        if let link { lines += ["", link.absoluteString] }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Клиент

/// Запросы к Sten. Сессия — один cookie, его держит и сохраняет модель (Keychain). Свой URLSession без хранилища
/// cookie: заголовок `Cookie` ставится руками, `Set-Cookie` из ответа отдаётся в `onCookie`.
@MainActor
public final class StenClient {
    public var server: StenServer
    /// «name=value; name2=value2» — то, что уходит в заголовке Cookie.
    public var cookie: String?
    /// Сервер выдал/обновил cookie (вход, продление сессии).
    public var onCookie: ((String) -> Void)?
    /// Счётчик запросов (самотест: «вкладка закрыта — запросов нет»).
    public private(set) var requestCount = 0
    let session: URLSession

    public init(server: StenServer, cookie: String? = nil, timeout: TimeInterval = 20) {
        self.server = server; self.cookie = cookie
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = 6 * 3600
        cfg.waitsForConnectivity = false
        session = URLSession(configuration: cfg)
    }

    deinit { session.invalidateAndCancel() }

    func makeRequest(_ method: String, _ path: String, contentType: String? = nil) -> URLRequest {
        var r = URLRequest(url: server.api(path))
        r.httpMethod = method
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let contentType { r.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if let cookie, !cookie.isEmpty { r.setValue(cookie, forHTTPHeaderField: "Cookie") }
        return r
    }

    /// Запрос с телом из памяти. Ошибки HTTP → `StenError`.
    func send(_ method: String, _ path: String, json: [String: Any]? = nil, body: Data? = nil,
              contentType: String? = nil) async throws -> Data {
        var r = makeRequest(method, path, contentType: json != nil ? "application/json" : contentType)
        if let json { r.httpBody = try JSONSerialization.data(withJSONObject: json) } else { r.httpBody = body }
        requestCount += 1
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await session.data(for: r) }
        catch { throw StenError.network((error as NSError).localizedDescription) }
        return try check(data, resp)
    }

    /// Загрузка файла (multipart, поле `file`) — тело уже лежит в файле, в память целиком не читается.
    func upload(_ path: String, multipartFile: URL, boundary: String) async throws -> Data {
        let r = makeRequest("POST", path, contentType: "multipart/form-data; boundary=\(boundary)")
        requestCount += 1
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await session.upload(for: r, fromFile: multipartFile) }
        catch { throw StenError.network((error as NSError).localizedDescription) }
        return try check(data, resp)
    }

    private func check(_ data: Data, _ resp: URLResponse) throws -> Data {
        guard let http = resp as? HTTPURLResponse else { throw StenError.badResponse }
        absorbCookies(http)
        switch http.statusCode {
        case 200..<300: return data
        case 401, 403: throw StenError.unauthorized(J.detail(data))
        case 404: throw StenError.notFound
        case 409: throw StenError.conflict(J.detail(data))
        default: throw StenError.http(http.statusCode, J.detail(data))
        }
    }

    /// `Set-Cookie` → обновить наш cookie (имена, которых нет в ответе, остаются). `Max-Age=0`/пустое — убрать.
    func absorbCookies(_ http: HTTPURLResponse) {
        var fields: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            if let k = k as? String, let v = v as? String { fields[k] = v }
        }
        guard fields.keys.contains(where: { $0.lowercased() == "set-cookie" }), let url = http.url else { return }
        let fresh = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
        guard !fresh.isEmpty else { return }
        var jar = Self.parse(cookie)
        for c in fresh {
            let expired = c.expiresDate.map { $0 < Date() } ?? false
            if c.value.isEmpty || expired { jar.removeAll { $0.0 == c.name } }
            else if let i = jar.firstIndex(where: { $0.0 == c.name }) { jar[i].1 = c.value }
            else { jar.append((c.name, c.value)) }
        }
        let joined = jar.map { "\($0.0)=\($0.1)" }.joined(separator: "; ")
        if joined != (cookie ?? "") {
            cookie = joined
            onCookie?(joined)
        }
    }

    static func parse(_ header: String?) -> [(String, String)] {
        (header ?? "").split(separator: ";").compactMap { part in
            let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2, !kv[0].isEmpty else { return nil }
            return (kv[0], kv[1])
        }
    }

    // MARK: Методы API (как в веб-приложении)

    public func health() async throws -> Bool {
        let d = try await send("GET", "/health")
        return J.bool((J.object(d) as? [String: Any])?["ok"]) ?? false
    }

    /// Вход. Пароль уходит только в этом запросе и нигде не хранится.
    public func login(name: String, password: String) async throws -> String {
        let d = try await send("POST", "/auth/login", json: ["name": name, "password": password])
        let o = J.object(d) as? [String: Any]
        return J.str(o?["name"]) ?? name
    }

    /// Кто вошёл (nil — ответ без имени). 401 → `unauthorized`.
    public func me() async throws -> String? {
        let d = try await send("GET", "/auth/me")
        return J.str((J.object(d) as? [String: Any])?["name"])
    }

    public func logout() async throws { _ = try await send("POST", "/auth/logout") }

    public func meetings() async throws -> [StenMeeting] {
        let d = try await send("GET", "/meetings")
        let o = J.object(d)
        let arr = (o as? [Any]) ?? J.arr((o as? [String: Any])?["meetings"] ?? (o as? [String: Any])?["items"])
        return arr.compactMap { StenMeeting(json: $0) }
    }

    public func createMeeting(title: String) async throws -> StenMeeting {
        let d = try await send("POST", "/meetings", json: ["title": title])
        guard let o = J.object(d), var m = StenMeeting(json: o) else { throw StenError.badResponse }
        if m.title.hasPrefix("Встреча ") && m.title == "Встреча \(m.id)" { m.title = title }
        return m
    }

    public func uploadChunk(_ id: Int, _ data: Data) async throws {
        _ = try await send("POST", "/meetings/\(id)/chunks", body: data, contentType: "application/octet-stream")
    }

    public func stop(_ id: Int) async throws { _ = try await send("POST", "/meetings/\(id)/stop") }

    public func status(_ id: Int) async throws -> StenStatus {
        let d = try await send("GET", "/meetings/\(id)/status")
        guard let o = J.object(d), let s = StenStatus(json: o) else { throw StenError.badResponse }
        return s
    }

    public func report(_ id: Int) async throws -> StenReport {
        StenReport(json: J.object(try await send("GET", "/meetings/\(id)/report")) ?? [:])
    }

    /// Сырые ответы (отладочная загрузка печатает их как есть).
    public func raw(_ path: String) async throws -> Data { try await send("GET", path) }

    /// POST /audio: файл записи целиком (multipart `file`). Тело собирается во временный файл на фоне.
    public func uploadAudio(_ id: Int, file: URL, mime: String = "audio/mp4") async throws {
        let boundary = "sten-" + UUID().uuidString
        let body = try await Task.detached(priority: .utility) {
            try Multipart.write(file: file, field: "file", mime: mime, boundary: boundary)
        }.value
        defer { try? FileManager.default.removeItem(at: body) }
        _ = try await upload("/meetings/\(id)/audio", multipartFile: body, boundary: boundary)
    }
}

/// Тело multipart/form-data во временном файле (файл записи до 2 ГБ — кусками по 1 МБ).
enum Multipart {
    static func write(file: URL, field: String, mime: String, boundary: String) throws -> URL {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("sten-upload-\(UUID().uuidString).bin")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let w = try FileHandle(forWritingTo: out)
        defer { try? w.close() }
        let name = file.lastPathComponent.replacingOccurrences(of: "\"", with: "")
        try w.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field)\"; filename=\"\(name)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8))
        let r = try FileHandle(forReadingFrom: file)
        defer { try? r.close() }
        while let chunk = try r.read(upToCount: 1 << 20), !chunk.isEmpty { try w.write(contentsOf: chunk) }
        try w.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        return out
    }

    static func mime(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "m4a": return "audio/mp4"
        case "mp4": return "audio/mp4"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "webm": return "audio/webm"
        case "ogg", "opus": return "audio/ogg"
        default: return "application/octet-stream"
        }
    }
}
