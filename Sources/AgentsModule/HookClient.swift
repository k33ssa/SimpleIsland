import Darwin
import Foundation

/// Режимы бинарника без GUI: `SimpleIsland --hook <Событие>` и `--selftest-agents`.
/// Зовётся из main.swift до запуска NSApplication.
public enum AgentsCLI {
    /// nil — флаг не наш, запускаемся как обычно.
    public static func handle(_ args: [String]) -> Int32? {
        if args.contains("--hook") { return HookClient.run(args) }
        if args.contains("--selftest-agents") {
            return MainActor.assumeIsolated { AgentsSelfTest.run(args) }
        }
        return nil
    }
}

/// Хук-клиент. Главное правило: **никогда не ломать работу агента**. Остров не запущен, завис, ответил
/// чепухой, таймаут — пустой stdout и exit 0, т.е. обычный диалог в терминале.
enum HookClient {
    static let defaultPermissionTimeout: TimeInterval = 55

    static func run(_ args: [String]) -> Int32 {
        signal(SIGPIPE, SIG_IGN)
        guard let i = args.firstIndex(of: "--hook"), i + 1 < args.count else { return 0 }
        let event = args[i + 1]
        if event == "ping" { return ping(args, after: i + 1) }
        let payload: [String: Any]
        if event == "codex-notify" {
            // Codex передаёт один JSON последним аргументом (argv, не stdin).
            guard i + 2 < args.count, let d = args[args.count - 1].data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return 0 }
            payload = obj
        } else {
            guard let d = readStdin(),
                  let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return 0 }
            payload = obj
        }
        guard var msg = makeMessage(event: event, payload: payload) else { return 0 }
        let isPermission = msg["ev"] as? String == "permission"
        let requestId = UUID().uuidString
        if isPermission { msg["id"] = requestId }

        guard let line = try? JSONSerialization.data(withJSONObject: msg) else { return 0 }
        guard let fd = UnixSocket.connect(path: AgentsPaths.socketPath) else { return 0 }
        defer { close(fd) }
        guard UnixSocket.writeAll(fd, line + Data([0x0A])) else { return 0 }
        guard isPermission else { return 0 }

        let env = ProcessInfo.processInfo.environment
        let timeout = env["SIMPLEISLAND_HOOK_TIMEOUT"].flatMap(Double.init) ?? defaultPermissionTimeout
        guard let reply = UnixSocket.readLine(fd, deadline: Date().addingTimeInterval(timeout)),
              let out = decisionOutput(reply: reply, requestId: requestId, payload: payload) else { return 0 }
        FileHandle.standardOutput.write(out + Data([0x0A]))
        return 0
    }

    /// `--hook ping <метка>` — проверка подключения из острова («Проверить»): тот же путь, что у настоящего хука
    /// (бинарь из settings.json → сокет), но без stdin. Остров ловит событие с этой меткой и меряет время.
    static func ping(_ args: [String], after i: Int) -> Int32 {
        let nonce = i + 1 < args.count ? args[i + 1] : ""
        let msg: [String: Any] = ["v": 1, "ev": "ping", "id": nonce, "agent": "claude", "session": "__ping__",
                                  "ts": Date().timeIntervalSince1970]
        guard let line = try? JSONSerialization.data(withJSONObject: msg),
              let fd = UnixSocket.connect(path: AgentsPaths.socketPath) else { return 3 }
        defer { close(fd) }
        return UnixSocket.writeAll(fd, line + Data([0x0A])) ? 0 : 4
    }

    /// stdin целиком, но не дольше 2 с и не больше 16 МБ. Терминал вместо трубы → ничего не ждём.
    static func readStdin() -> Data? {
        if isatty(0) != 0 { return nil }
        var buf = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        let deadline = Date().addingTimeInterval(2)
        while buf.count < 16 << 20 {
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { break }
            var pfd = pollfd(fd: 0, events: Int16(POLLIN), revents: 0)
            let pr = poll(&pfd, 1, Int32(left * 1000).clamped(1, 2000))
            if pr < 0 { if errno == EINTR { continue }; break }
            if pr == 0 { break }
            let n = read(0, &chunk, chunk.count)
            if n > 0 { buf.append(contentsOf: chunk[0..<n]) } else if n < 0, errno == EINTR { continue } else { break }
        }
        return buf.isEmpty ? nil : buf
    }

    /// Хук-JSON Claude Code / Codex → строка протокола. nil — событие не наше.
    static func makeMessage(event: String, payload p: [String: Any]) -> [String: Any]? {
        var m: [String: Any] = ["v": 1, "ts": Date().timeIntervalSince1970]
        func str(_ k: String, max: Int = 4000) -> String? {
            guard let s = p[k] as? String, !s.isEmpty else { return nil }
            return s.count > max ? String(s.prefix(max)) + "…" : s
        }
        if event == "codex-notify" {
            m["agent"] = "codex"
            let type = (p["type"] as? String) ?? ""
            m["ev"] = type == "agent-turn-complete" ? "stop" : "codex-" + type
            m["session"] = (p["thread-id"] as? String) ?? (p["thread_id"] as? String) ?? "codex"
            m["cwd"] = p["cwd"] as? String ?? FileManager.default.currentDirectoryPath
            if let s = (p["last-assistant-message"] as? String) ?? (p["last_assistant_message"] as? String) {
                m["lastMessage"] = String(s.prefix(600))
            }
            if let inputs = p["input-messages"] as? [String], let last = inputs.last { m["prompt"] = String(last.prefix(300)) }
        } else {
            m["agent"] = "claude"
            let name = (p["hook_event_name"] as? String) ?? event
            m["ev"] = name == "PermissionRequest" ? "permission" : name.lowercased()
            m["session"] = str("session_id") ?? "claude"
            m["cwd"] = str("cwd") ?? FileManager.default.currentDirectoryPath
            m["tool"] = str("tool_name")
            m["toolUseId"] = str("tool_use_id")
            m["agentId"] = str("agent_id")
            if let input = p["tool_input"] { m["input"] = trimmed(input, depth: 0) }
            if let s = p["permission_suggestions"] as? [Any] { m["suggestions"] = s }
            m["message"] = str("message", max: 600) ?? str("error_details", max: 600)
            m["title"] = str("title", max: 200)
            m["kind"] = str("notification_type") ?? str("source") ?? str("reason") ?? str("error") ?? str("agent_type")
            m["prompt"] = str("prompt", max: 300)
            m["lastMessage"] = str("last_assistant_message", max: 600)
            m["permissionMode"] = str("permission_mode")
        }
        if let t = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(TermInfo.current())) { m["term"] = t }
        return m
    }

    /// Огромный `content` у Write не нужен острову целиком — режем строки и массивы.
    static func trimmed(_ v: Any, depth: Int) -> Any {
        if depth > 6 { return NSNull() }
        if let s = v as? String { return s.count > 16000 ? String(s.prefix(16000)) : s }
        if let a = v as? [Any] { return a.prefix(200).map { trimmed($0, depth: depth + 1) } }
        if let o = v as? [String: Any] { return o.mapValues { trimmed($0, depth: depth + 1) } }
        return v
    }

    /// Инструменты, которым одного `allow` мало: Claude Code ждёт `updatedInput` (docs hooks, «allow with updatedInput»).
    /// AskUserQuestion — исходные `questions` + `answers` {вопрос: метка}; ExitPlanMode — исходный вход (план).
    static let needsUpdatedInput: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

    /// Ответ острова → stdout для `PermissionRequest`. nil — «спроси в терминале».
    /// `payload` — исходный JSON хука: `updatedInput` собирается из НЕобрезанного `tool_input` (острову уходит
    /// урезанный, длинный план вернулся бы агенту обрезанным).
    static func decisionOutput(reply: Data, requestId: String, payload: [String: Any] = [:]) -> Data? {
        guard let r = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any],
              r["id"] as? String == requestId, let d = r["decision"] as? String else { return nil }
        var decision: [String: Any]
        switch d {
        case "allow":
            decision = ["behavior": "allow"]
            if let perms = r["updatedPermissions"] as? [Any], !perms.isEmpty { decision["updatedPermissions"] = perms }
            let tool = payload["tool_name"] as? String ?? ""
            if needsUpdatedInput.contains(tool) {
                var input = payload["tool_input"] as? [String: Any] ?? [:]
                if tool == "AskUserQuestion" {
                    // Без ответа «разрешить» вопрос нельзя — отдаём терминалу.
                    guard let answers = r["answers"] as? [String: Any], !answers.isEmpty else { return nil }
                    input["answers"] = answers
                }
                decision["updatedInput"] = input
            }
        case "deny":
            let reason = (r["message"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Пользователь отклонил в SimpleIsland"
            decision = ["behavior": "deny", "message": reason]
        default:
            return nil
        }
        let out: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        return try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
    }
}
