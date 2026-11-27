import Foundation

/// Подключение хуков: ~/.claude/settings.json и notify в ~/.codex/config.toml. Бережно: резервная копия,
/// идемпотентно, наши записи помечены `#simpleisland`, чужие не трогаем, неразборчивый файл не правим.
/// HOME для тестов — `SIMPLEISLAND_HOME` или параметр `home`.
enum Installer {
    enum Status: Equatable {
        case notInstalled
        case installed
        /// Наши записи есть, но не все или старого вида — нужно переподключить.
        case outdated
        /// Записи полные, но ведут к SimpleIsland по другому пути (приложение перенесли, запущена другая копия).
        case otherPath(String)
        /// Нельзя: нет каталога агента, файл не разобрать, чужой notify…
        case unavailable(String)

        var isInstalled: Bool {
            switch self {
            case .installed, .outdated, .otherPath: return true
            default: return false
            }
        }

        /// Нужно переподключить (кнопка «Переподключить»).
        var needsReinstall: Bool {
            switch self {
            case .outdated, .otherPath: return true
            default: return false
            }
        }
    }

    struct Outcome: Equatable {
        var changed: Bool
        var backup: URL?
        var message: String
    }

    struct Failure: Error, CustomStringConvertible { var description: String }

    static let marker = "#simpleisland"

    /// Событие → таймаут хука (с) и `async` (Claude не ждёт хук). Синхронны только PermissionRequest (ждёт ответа
    /// острова до 55 с) и SessionEnd (агент выходит — фоновый хук могут не дождаться). PostToolUse*/PermissionDenied
    /// снимают «ждёт», когда на запрос ответили в терминале.
    static let claudeEvents: [(name: String, timeout: Int, async: Bool)] = [
        ("SessionStart", 5, true), ("SessionEnd", 5, false), ("UserPromptSubmit", 5, true), ("PreToolUse", 5, true),
        ("PermissionRequest", 60, false), ("PermissionDenied", 5, true), ("PostToolUse", 5, true),
        ("PostToolUseFailure", 5, true), ("Notification", 5, true), ("Stop", 5, true), ("StopFailure", 5, true),
        ("SubagentStop", 5, true),
    ]

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func command(bin: String, event: String) -> String {
        "\(shellQuote(bin)) --hook \(event) \(marker)"
    }

    /// Путь к бинарю из нашей команды `'<путь>' --hook <Событие> #simpleisland`.
    static func binary(ofCommand c: String) -> String? {
        guard c.hasPrefix("'"), let end = c.range(of: "' --hook ") else { return nil }
        return String(c[c.index(after: c.startIndex)..<end.lowerBound]).replacingOccurrences(of: "'\\''", with: "'")
    }

    /// Путь, по которому сейчас вызываются хуки Claude Code (nil — не подключено или пути разные).
    static func claudeHookBinary(home: URL) -> String? {
        guard let data = try? Data(contentsOf: claudeSettings(home: home)), let root = try? OJSON.parse(data) else { return nil }
        var bins = Set<String>()
        for e in claudeEvents {
            for entry in root["hooks"]?[e.name]?.array ?? [] {
                for h in entry["hooks"]?.array ?? [] {
                    if let c = h["command"]?.string, isOurs(c), let b = binary(ofCommand: c) { bins.insert(b) }
                }
            }
        }
        return bins.count == 1 ? bins.first : nil
    }

    static func isOurs(_ command: String?) -> Bool {
        guard let c = command else { return false }
        return c.contains(marker)
    }

    /// Наш обработчик события в settings.json (по нему же статус «подключён / устарел»).
    static func handler(bin: String, event e: (name: String, timeout: Int, async: Bool)) -> OJSON {
        var fields: [(String, OJSON)] = [("type", .string("command")),
                                         ("command", .string(command(bin: bin, event: e.name))),
                                         ("timeout", .number(String(e.timeout)))]
        if e.async { fields.append(("async", .bool(true))) }
        return .object(fields)
    }

    static func claudeSettings(home: URL) -> URL { home.appendingPathComponent(".claude/settings.json") }
    static func codexConfig(home: URL) -> URL { home.appendingPathComponent(".codex/config.toml") }

    static func backupURL(for url: URL, now: Date) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        var u = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".simpleisland-backup-" + f.string(from: now))
        var n = 2
        while FileManager.default.fileExists(atPath: u.path) {
            u = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".simpleisland-backup-" + f.string(from: now) + "-\(n)")
            n += 1
        }
        return u
    }

    /// Записать с резервной копией прежнего содержимого; правим цель симлинка. Права: файл — как был (новый — 0600),
    /// копия — 0600 (в settings.json бывают токены в `env`). Файлы сразу создаются с нужными правами, без окна 0644.
    static func write(_ text: String, to url: URL, original: Data?, now: Date) throws -> URL? {
        let target = url.resolvingSymlinksInPath()
        var backup: URL?
        if let original {
            let b = backupURL(for: url, now: now)
            try createFile(b.path, data: original, mode: 0o600)
            backup = b
        } else {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let perms = ((try? FileManager.default.attributesOfItem(atPath: target.path))?[.posixPermissions] as? NSNumber)
            .map { mode_t($0.intValue) & 0o777 } ?? 0o600
        // Атомарно: временный файл рядом (с правами оригинала) → rename.
        let tmp = target.path + ".simpleisland-tmp-\(getpid())"
        unlink(tmp)
        do {
            try createFile(tmp, data: Data(text.utf8), mode: perms)
            guard rename(tmp, target.path) == 0 else { throw Failure(description: "rename: \(String(cString: strerror(errno)))") }
        } catch {
            unlink(tmp)
            throw error
        }
        return backup
    }

    /// Новый файл (O_EXCL) сразу с правами `mode` (umask не мешает — права ставятся fchmod).
    static func createFile(_ path: String, data: Data, mode: mode_t) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, mode)
        guard fd >= 0 else { throw Failure(description: "\(path): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        _ = fchmod(fd, mode)
        let ok = data.withUnsafeBytes { raw -> Bool in
            var off = 0
            while off < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + off, raw.count - off)
                if n < 0 { if errno == EINTR { continue }; return false }
                off += n
            }
            return true
        }
        guard ok, fsync(fd) == 0 || errno == EINVAL else { throw Failure(description: "\(path): запись не удалась") }
    }

    // MARK: - Claude Code

    static func claudeStatus(home: URL, bin: String) -> Status {
        let url = claudeSettings(home: home)
        guard let data = try? Data(contentsOf: url) else { return .notInstalled }
        guard let root = try? OJSON.parse(data), root.isObject else {
            return .unavailable("~/.claude/settings.json не разобрать — не трогаю")
        }
        var ours = 0, exact = 0
        for e in claudeEvents {
            for entry in root["hooks"]?[e.name]?.array ?? [] {
                for h in entry["hooks"]?.array ?? [] where isOurs(h["command"]?.string) {
                    ours += 1
                    if h == handler(bin: bin, event: e) { exact += 1 }
                }
            }
        }
        if ours == 0 { return .notInstalled }
        if exact == claudeEvents.count && ours == exact { return .installed }
        // Полный набор, но с другим путём — «приложение по другому пути», а не «устарело».
        if let other = claudeHookBinary(home: home), other != bin,
           claudeStatus(home: home, bin: other) == .installed { return .otherPath(other) }
        return .outdated
    }

    /// Убрать наши обработчики из `hooks`: пустые записи и события — тоже (только если опустели из-за нас).
    static func strippingOurs(_ root: OJSON) -> OJSON {
        guard case .object(let hooksObj)? = root["hooks"] else { return root }
        var newHooks: [(String, OJSON)] = []
        for (event, value) in hooksObj {
            guard case .array(let entries) = value else { newHooks.append((event, value)); continue }
            var kept: [OJSON] = []
            var removedAny = false
            for entry in entries {
                guard case .array(let hs)? = entry["hooks"] else { kept.append(entry); continue }
                let left = hs.filter { !isOurs($0["command"]?.string) }
                if left.count == hs.count { kept.append(entry); continue }
                removedAny = true
                if !left.isEmpty { var e = entry; e["hooks"] = .array(left); kept.append(e) }
            }
            if removedAny && kept.isEmpty { continue }
            newHooks.append((event, .array(kept)))
        }
        var r = root
        r["hooks"] = newHooks.isEmpty ? nil : .object(newHooks)
        return r
    }

    static func installClaude(home: URL, bin: String, now: Date = Date()) throws -> Outcome {
        let url = claudeSettings(home: home)
        let original = try? Data(contentsOf: url)
        var root: OJSON = .object([])
        if let original, !original.isEmpty {
            guard let r = try? OJSON.parse(original), r.isObject else {
                throw Failure(description: "~/.claude/settings.json не разобрать — не трогаю, поправь файл вручную")
            }
            root = r
        }
        var next = strippingOurs(root)
        var hooks = next["hooks"] ?? .object([])
        guard hooks.isObject else { throw Failure(description: "в settings.json поле hooks — не объект, не трогаю") }
        for e in claudeEvents {
            var list = hooks[e.name]?.array ?? []
            list.append(.object([("hooks", .array([handler(bin: bin, event: e)]))]))
            hooks[e.name] = .array(list)
        }
        next["hooks"] = hooks
        if next == root { return Outcome(changed: false, backup: nil, message: "Claude Code уже подключён") }
        let backup = try write(next.serialized() + "\n", to: url, original: original, now: now)
        return Outcome(changed: true, backup: backup, message: "Claude Code подключён: \(claudeEvents.count) хуков")
    }

    static func uninstallClaude(home: URL, now: Date = Date()) throws -> Outcome {
        let url = claudeSettings(home: home)
        guard let original = try? Data(contentsOf: url) else { return Outcome(changed: false, backup: nil, message: "нечего отключать") }
        guard let root = try? OJSON.parse(original), root.isObject else {
            throw Failure(description: "~/.claude/settings.json не разобрать — не трогаю")
        }
        let next = strippingOurs(root)
        if next == root { return Outcome(changed: false, backup: nil, message: "хуков SimpleIsland нет") }
        let backup = try write(next.serialized() + "\n", to: url, original: original, now: now)
        return Outcome(changed: true, backup: backup, message: "Claude Code отключён, чужие хуки на месте")
    }

    // MARK: - Codex (notify в config.toml — один на всех, чужой не перезаписываем)

    static func tomlString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func codexLine(bin: String) -> String {
        "notify = [\(tomlString(bin)), \"--hook\", \"codex-notify\"] \(marker)"
    }

    /// Строки верхнего уровня (до первой таблицы `[…]`).
    static func topLevelEnd(_ lines: [String]) -> Int {
        lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") } ?? lines.count
    }

    static func notifyLines(_ lines: [String]) -> Range<Int>? {
        let end = topLevelEnd(lines)
        guard let i = lines[0..<end].firstIndex(where: {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("notify") && t.dropFirst("notify".count).trimmingCharacters(in: .whitespaces).hasPrefix("=")
        }) else { return nil }
        // Многострочный массив: до строки с закрывающей «]».
        var j = i
        let opens = lines[i].filter { $0 == "[" }.count, closes = lines[i].filter { $0 == "]" }.count
        if opens > closes {
            j = lines.count - 1
            for k in (i + 1)..<lines.count where lines[k].contains("]") { j = k; break }
        }
        return i..<(j + 1)
    }

    static func codexStatus(home: URL, bin: String) -> Status {
        let dir = home.appendingPathComponent(".codex")
        guard FileManager.default.fileExists(atPath: dir.path) else { return .unavailable("Codex не найден (~/.codex нет)") }
        let text = (try? String(contentsOf: codexConfig(home: home), encoding: .utf8)) ?? ""
        let lines = text.components(separatedBy: "\n")
        guard let r = notifyLines(lines) else { return .notInstalled }
        let joined = lines[r].joined(separator: "\n")
        if !isOurs(joined) { return .unavailable("в config.toml уже свой notify — не трогаю") }
        if joined == codexLine(bin: bin) { return .installed }
        if let other = codexBinary(joined), other != bin, joined == codexLine(bin: other) { return .otherPath(other) }
        return .outdated
    }

    /// Первая строка TOML-массива notify — путь к бинарю.
    static func codexBinary(_ line: String) -> String? {
        guard let open = line.firstIndex(of: "\"") else { return nil }
        var out = "", escaped = false
        for ch in line[line.index(after: open)...] {
            if escaped { out.append(ch); escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if ch == "\"" { return out }
            out.append(ch)
        }
        return nil
    }

    static func installCodex(home: URL, bin: String, now: Date = Date()) throws -> Outcome {
        let dir = home.appendingPathComponent(".codex")
        guard FileManager.default.fileExists(atPath: dir.path) else {
            throw Failure(description: "Codex не найден (~/.codex нет) — сначала установи и запусти Codex")
        }
        let url = codexConfig(home: home)
        let original = try? Data(contentsOf: url)
        let text = original.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        var lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        let line = codexLine(bin: bin)
        if let r = notifyLines(lines) {
            let joined = lines[r].joined(separator: "\n")
            guard isOurs(joined) else { throw Failure(description: "в ~/.codex/config.toml уже есть свой notify — не перезаписываю") }
            if joined == line { return Outcome(changed: false, backup: nil, message: "Codex уже подключён") }
            lines.replaceSubrange(r, with: [line])
        } else {
            // После последней непустой строки верхнего уровня: так отключение вернёт файл байт в байт.
            let end = topLevelEnd(lines)
            let lastNonBlank = lines[0..<end].lastIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let at = lastNonBlank.map { $0 + 1 } ?? 0
            lines.insert(line, at: at)
            if lines.count == 1 { lines.append("") }   // новый файл — с переводом строки в конце
        }
        let backup = try write(lines.joined(separator: "\n"), to: url, original: original, now: now)
        return Outcome(changed: true, backup: backup, message: "Codex подключён (notify)")
    }

    static func uninstallCodex(home: URL, now: Date = Date()) throws -> Outcome {
        let url = codexConfig(home: home)
        guard let original = try? Data(contentsOf: url), let text = String(data: original, encoding: .utf8) else {
            return Outcome(changed: false, backup: nil, message: "нечего отключать")
        }
        var lines = text.components(separatedBy: "\n")
        guard let r = notifyLines(lines), isOurs(lines[r].joined(separator: "\n")) else {
            return Outcome(changed: false, backup: nil, message: "notify SimpleIsland нет")
        }
        lines.removeSubrange(r)
        let backup = try write(lines.joined(separator: "\n"), to: url, original: original, now: now)
        return Outcome(changed: true, backup: backup, message: "Codex отключён")
    }
}
