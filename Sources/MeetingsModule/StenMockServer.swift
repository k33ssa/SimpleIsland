import Foundation
import Network

/// Поддельный Sten для самотеста: HTTP/1.1 на 127.0.0.1 (порт выбирает система), префикс `/sten/api`.
/// Повторяет поведение настоящего API по фронтенду сайта: cookie-сессия, 401 `{"detail":"Нужно войти"}`,
/// 404 `{"detail":"meeting not found"}` для чужой встречи, куски /chunks, /stop, /status с прогрессом, /report, /audio.
final class StenMockServer: @unchecked Sendable {
    struct Meeting {
        var id: Int
        var title: String
        var status = "recording"
        var chunks: [Data] = []
        var audio: Data?
        var statusCalls = 0
    }

    private let lock = NSLock()
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "local.simpleisland.meetings.mock")
    private(set) var port: UInt16 = 0

    // Состояние (под lock)
    private var meetingsById: [Int: Meeting] = [:]
    private var nextId = 140
    private var sessions: Set<String> = []
    private var _requests: [String] = []
    private var _failChunks = false
    private var _lastLoginBody = ""
    /// Последовательность процентов до «ready» (по одному на вызов /status).
    var progressSteps: [Double] = [10, 10, 10, 55, 90]

    let user = "anna"
    let password = "secret-пароль"

    var requests: [String] { lock.withLock { _requests } }
    var failChunks: Bool {
        get { lock.withLock { _failChunks } }
        set { lock.withLock { _failChunks = newValue } }
    }
    var lastLoginBody: String { lock.withLock { _lastLoginBody } }
    func meeting(_ id: Int) -> Meeting? { lock.withLock { meetingsById[id] } }
    func dropSessions() { lock.withLock { sessions.removeAll() } }
    func statusCalls(_ id: Int) -> Int { lock.withLock { meetingsById[id]?.statusCalls ?? 0 } }

    func start() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: 0)
        let l = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        l.stateUpdateHandler = { st in
            if case .ready = st { ready.signal() }
            if case .failed = st { ready.signal() }
        }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        port = l.port?.rawValue ?? 0
        listener = l
    }

    func stop() { listener?.cancel(); listener = nil }

    var root: String { "http://127.0.0.1:\(port)/sten" }

    // MARK: HTTP

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        receive(c, buffer: Data())
    }

    private func receive(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let req = Self.parse(buf) {
                let resp = self.handle(req)
                c.send(content: resp, completion: .contentProcessed { _ in c.cancel() })
                return
            }
            if done || err != nil { c.cancel(); return }
            self.receive(c, buffer: buf)
        }
    }

    struct Request {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data
    }

    static func parse(_ buf: Data) -> Request? {
        guard let headEnd = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buf[..<headEnd.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for l in lines {
            guard let i = l.firstIndex(of: ":") else { continue }
            headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        let len = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headEnd.upperBound
        guard buf.count - bodyStart >= len else { return nil }
        return Request(method: String(first[0]), path: String(first[1]), headers: headers,
                       body: buf.subdata(in: bodyStart..<(bodyStart + len)))
    }

    private func response(_ code: Int, _ json: Any, cookie: String? = nil) -> Data {
        let body = (try? JSONSerialization.data(withJSONObject: json, options: [.fragmentsAllowed])) ?? Data()
        let text = [200: "OK", 401: "Unauthorized", 404: "Not Found", 409: "Conflict", 500: "Internal Server Error"][code] ?? "X"
        var h = "HTTP/1.1 \(code) \(text)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        if let cookie { h += "Set-Cookie: \(cookie)\r\n" }
        h += "\r\n"
        return Data(h.utf8) + body
    }

    private func handle(_ r: Request) -> Data {
        lock.lock(); defer { lock.unlock() }
        var path = r.path
        if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
        _requests.append("\(r.method) \(path)")
        guard path.hasPrefix("/sten/api") else { return response(404, ["detail": "Not Found"]) }
        path = String(path.dropFirst("/sten/api".count))
        let cookie = r.headers["cookie"] ?? ""
        let authed = sessions.contains { cookie.contains("sten_session=\($0)") }

        switch (r.method, path) {
        case ("GET", "/health"): return response(200, ["ok": true])
        case ("POST", "/auth/login"):
            _lastLoginBody = String(decoding: r.body, as: UTF8.self)
            let o = (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any]
            guard o?["name"] as? String == user, o?["password"] as? String == password else {
                return response(401, ["detail": "Неверное имя или пароль"])
            }
            let token = UUID().uuidString
            sessions.insert(token)
            return response(200, ["id": 25, "name": "Анна"], cookie: "sten_session=\(token); Path=/sten; HttpOnly; SameSite=Lax")
        case ("POST", "/auth/logout"):
            sessions = sessions.filter { !cookie.contains($0) }
            return response(200, ["ok": true], cookie: "sten_session=; Path=/sten; Max-Age=0")
        default: break
        }
        guard authed else { return response(401, ["detail": "Нужно войти"]) }
        if path == "/auth/me" { return response(200, ["id": 25, "name": "Анна"]) }
        if path == "/meetings" && r.method == "GET" {
            let list = meetingsById.values.sorted { $0.id > $1.id }.map {
                ["id": $0.id, "title": $0.title, "created_at": "2026-11-16T12:0\($0.id % 10):00", "status": $0.status] as [String: Any]
            }
            return response(200, list)
        }
        if path == "/meetings" && r.method == "POST" {
            let o = (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any]
            nextId += 1
            let m = Meeting(id: nextId, title: (o?["title"] as? String) ?? "Встреча")
            meetingsById[m.id] = m
            return response(200, ["id": m.id, "title": m.title, "status": m.status, "created_at": "2026-11-16T12:00:00Z"])
        }
        let parts = path.split(separator: "/").map(String.init)   // meetings, id, action
        guard parts.count >= 2, parts[0] == "meetings", let id = Int(parts[1]), var m = meetingsById[id] else {
            return response(404, ["detail": "meeting not found"])
        }
        let action = parts.count > 2 ? parts[2] : ""
        defer { meetingsById[id] = m }
        switch (r.method, action) {
        case ("POST", "chunks"):
            if _failChunks { return response(500, ["detail": "disk full"]) }
            m.chunks.append(r.body)
            return response(200, ["ok": true, "bytes": r.body.count])
        case ("POST", "stop"):
            m.status = "processing"
            return response(200, ["ok": true])
        case ("POST", "audio"):
            if !m.chunks.isEmpty { return response(409, ["detail": "already recorded"]) }
            m.audio = r.body
            m.status = "processing"
            return response(200, ["ok": true])
        case ("GET", "status"):
            guard m.status == "processing" else { return response(200, ["status": m.status, "progress": NSNull(), "error": NSNull()]) }
            m.statusCalls += 1
            if m.statusCalls > progressSteps.count {
                m.status = "consensus"
                return response(200, ["status": "consensus", "progress": ["step": 4, "percent": 100], "error": NSNull()])
            }
            let p = progressSteps[m.statusCalls - 1]
            return response(200, ["status": "processing", "progress": ["step": 1, "percent": p, "label": "Распознаю речь…"],
                                  "error": NSNull()])
        case ("GET", "report"):
            return response(200, [
                "available": m.status == "consensus" || m.status == "ready",
                "title": m.title, "summary": "Обсудили релиз.", "outcome": "Релиз в пятницу.",
                "participants": [["speaker": "Анна", "role": "дизайн"], ["speaker": "Илья"], ["speaker": "Максим"]],
                "topics": [["title": "Релиз", "text": "сроки"]],
                "decisions": [["text": "Релиз в пятницу", "initiator": "Максим"]],
                "tasks": [["text": "Макет пустого списка", "assignee": "Анна", "due": "среда"],
                          ["text": "Собрать модуль", "assignee": "илья"],
                          ["text": "Проверить на AirPods", "assignee": "Илья и Анна"],
                          ["text": "Найти место для архива", "assignee": NSNull()]],
            ] as [String: Any])
        case ("GET", ""):
            return response(200, ["id": m.id, "title": m.title, "status": m.status])
        default:
            return response(404, ["detail": "Not Found"])
        }
    }
}
