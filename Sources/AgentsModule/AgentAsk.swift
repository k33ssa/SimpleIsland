import Foundation
import IslandCore

// Человеческое представление того, о чём агент спрашивает (UX 15.11: «в острове сырое тело запроса»).
// Сырые поля хука (tool_name, tool_input, notification_type) → заголовок по смыслу, короткая подпись для компакта и
// озвучка. Сырой JSON — только по кнопке «Подробнее» в карточке. Схема полей — docs/TECH.md §6.

/// Вопрос `AskUserQuestion` (tool_input.questions[]): вопрос, короткий заголовок, варианты, мультивыбор.
struct AgentQuestion: Equatable {
    struct Option: Equatable {
        var label: String
        var description: String?
    }
    var question: String
    var header: String?
    var options: [Option]
    var multiSelect: Bool

    /// Из `tool_input` AskUserQuestion. Пусто — вопросов нет (или формат не тот).
    static func parse(_ input: JSONValue?) -> [AgentQuestion] {
        guard let list = input?["questions"]?.arrayValue else { return [] }
        return list.prefix(4).compactMap { q in
            guard let text = q["question"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
            else { return nil }
            let options = (q["options"]?.arrayValue ?? []).prefix(8).compactMap { o -> Option? in
                guard let l = (o["label"]?.stringValue ?? o.stringValue)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !l.isEmpty else { return nil }
                let d = o["description"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                return Option(label: ToolPreview.sanitize(l), description: d.flatMap { $0.isEmpty ? nil : ToolPreview.sanitize($0) })
            }
            let header = q["header"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            let multi: Bool = { if case .bool(let b)? = q["multiSelect"] { return b }; return false }()
            return AgentQuestion(question: ToolPreview.sanitize(text),
                                 header: header.flatMap { $0.isEmpty ? nil : ToolPreview.sanitize($0) },
                                 options: Array(options), multiSelect: multi)
        }
    }
}

/// Что показать про запрос: заголовок карточки, подпись компакта, озвучка.
struct AskPresentation: Equatable {
    enum Kind: Equatable {
        /// Разрешение на инструмент (Edit, Bash, MCP…).
        case permission
        /// AskUserQuestion: агент задаёт вопрос с вариантами.
        case question
        /// ExitPlanMode: план готов, нужно утвердить.
        case plan
    }
    var kind: Kind
    /// Заголовок карточки: «Изменить MediaViews.swift», «Запустить команду», «Claude спрашивает».
    var title: String
    /// Строка под заголовком (серым): папка файла, описание команды, хост. nil — нет.
    var subtitle: String?
    /// Категория для компакта: «правка файла», «команда», «вопрос», «план».
    var category: String
    /// SF Symbol категории для компакта и заголовка.
    var symbol: String

    /// Полная фраза для статуса и озвучки: «Нужно разрешение: правка файла».
    var statusText: String {
        switch kind {
        case .permission: return "Нужно разрешение: " + category
        case .question: return "Спрашивает"
        case .plan: return "План готов — утвердить?"
        }
    }

    static func make(tool: String, input: JSONValue?, cwd: String?, agent: AgentKind = .claude) -> AskPresentation {
        func s(_ k: String) -> String? {
            guard let v = input?[k]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
            return ToolPreview.sanitize(v)
        }
        let path = s("file_path") ?? s("notebook_path") ?? s("path")
        let file = path.map { ($0 as NSString).lastPathComponent }
        // Папка файла относительно проекта: «Sources/MediaModule».
        let folder: String? = path.flatMap { p in
            let rel = ToolPreview.relative(p, to: cwd)
            let dir = (rel as NSString).deletingLastPathComponent
            return dir.isEmpty ? nil : dir
        }
        func p(_ title: String, _ sub: String?, _ cat: String, _ sym: String) -> AskPresentation {
            AskPresentation(kind: .permission, title: ToolPreview.clip(title, 90), subtitle: sub.map { ToolPreview.clip($0, 120) },
                            category: cat, symbol: sym)
        }
        switch tool {
        case "Edit":
            return p("Изменить " + (file ?? "файл"), folder, "правка файла", "pencil")
        case "MultiEdit":
            let n = input?["edits"]?.arrayValue?.count ?? 0
            let sub = [folder, n > 0 ? "\(n) " + plural(n, "правка", "правки", "правок") : nil].compactMap { $0 }.joined(separator: " · ")
            return p("Изменить " + (file ?? "файл"), sub.isEmpty ? nil : sub, "правка файла", "pencil")
        case "Write":
            let exists = path.map { FileManager.default.fileExists(atPath: $0) } ?? false
            return p((exists ? "Перезаписать " : "Создать ") + (file ?? "файл"), folder, exists ? "перезапись файла" : "новый файл",
                     "doc.badge.plus")
        case "NotebookEdit":
            return p("Изменить блокнот " + (file ?? ""), folder, "правка блокнота", "pencil")
        case "Read":
            return p("Прочитать " + (file ?? "файл"), folder, "чтение файла", "doc.text")
        case "Bash":
            // Описание команды от агента — человеческий заголовок; сама команда — в превью с подсветкой.
            let cmd = ToolPreview.firstLine(s("command") ?? "")
            let program = cmd.split(separator: " ").first.map(String.init)
            if let d = s("description") {
                return p(d, program.map { "команда " + $0 }, "команда", "terminal")
            }
            return p("Запустить команду" + (program.map { ": " + $0 } ?? ""), nil, "команда", "terminal")
        case "WebFetch":
            let host = s("url").flatMap { URL(string: $0)?.host }
            return p("Открыть страницу " + (host ?? ""), s("prompt").map { ToolPreview.firstLine($0) }, "веб-запрос", "globe")
        case "WebSearch":
            return p("Искать в сети", s("query").map { "«" + $0 + "»" }, "поиск в сети", "magnifyingglass")
        case "Grep", "Glob":
            return p("Искать по файлам", s("pattern"), "поиск", "magnifyingglass")
        case "Task", "Agent":
            return p("Запустить субагента", s("description") ?? s("subagent_type"), "субагент", "person.2")
        case "AskUserQuestion":
            let qs = AgentQuestion.parse(input)
            let who = agent == .codex ? "Codex" : "Claude"
            return AskPresentation(kind: .question, title: who + " спрашивает",
                                   subtitle: qs.count > 1 ? "\(qs.count) " + plural(qs.count, "вопрос", "вопроса", "вопросов") : nil,
                                   category: "вопрос", symbol: "questionmark.bubble")
        case "ExitPlanMode":
            let heading = s("plan").flatMap { plan in
                plan.split(separator: "\n").lazy.map { $0.trimmingCharacters(in: .whitespaces) }
                    .first { !$0.isEmpty }.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) }
            }
            return AskPresentation(kind: .plan, title: "Утвердить план", subtitle: heading.map { ToolPreview.clip($0, 120) },
                                   category: "план", symbol: "list.bullet.clipboard")
        default:
            if tool.hasPrefix("mcp__") {
                let parts = tool.components(separatedBy: "__")
                let server = parts.count > 1 ? parts[1] : "MCP"
                let name = parts.count > 2 ? parts[2...].joined(separator: "__") : tool
                return p(humanize(name), "сервер " + server, "инструмент " + server, "puzzlepiece.extension")
            }
            return p("Инструмент " + tool, nil, "инструмент", "wrench.and.screwdriver")
        }
    }

    /// `create_pull_request` → «Create pull request».
    static func humanize(_ name: String) -> String {
        let words = name.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
            .split(separator: " ").map(String.init)
        guard let first = words.first else { return name }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst()).joined(separator: " ")
    }
}

/// Уведомление агента (`Notification`): что показать вместо сырого `message`/`notification_type`.
struct AgentNotice: Equatable {
    /// Ждёт ли агент пользователя (жёлтое «ждёт», звук, раскрытие).
    var waiting: Bool
    /// Текст статуса сессии: «Ждёт ответа в терминале», «MCP-сервер просит данные».
    var text: String

    /// nil — уведомление не меняет статус (служебное: вход, квоты, плагин).
    static func make(kind: String?, message: String?, title: String?) -> AgentNotice? {
        let msg = message.map { ToolPreview.sanitize(ToolPreview.firstLine($0)).trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 }
        switch kind ?? "" {
        case "permission_prompt":
            return AgentNotice(waiting: true, text: "Ждёт разрешения в терминале")
        case "agent_needs_input":
            return AgentNotice(waiting: true, text: msg.map(cleanMessage) ?? "Ждёт ответа")
        case "elicitation_dialog":
            return AgentNotice(waiting: true, text: "MCP-сервер просит данные — ответь в терминале")
        case "elicitation_url_dialog":
            return AgentNotice(waiting: true, text: "Нужно войти по ссылке — открой терминал")
        default:
            return nil
        }
    }

    /// Английские шаблоны Claude Code → по-русски; прочее — как есть, без служебного «Claude Code:».
    static func cleanMessage(_ m: String) -> String {
        let low = m.lowercased()
        if low.contains("waiting for your input") || low.contains("needs your input") { return "Ждёт ответа" }
        if low.contains("needs your permission") { return "Ждёт разрешения" }
        var s = m
        for prefix in ["Claude Code: ", "Claude: ", "Codex: "] where s.hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)) }
        return ToolPreview.clip(s, 80)
    }
}

/// Имя проекта для острова: хвост пути, без обрезки посреди слова.
enum ProjectName {
    /// Имена папок, по которым проект не узнать: берём ещё и родителя («SimpleIsland-wt/ux3», «weather-api/src»).
    static let generic: Set<String> = ["src", "app", "apps", "code", "repo", "main", "work", "dev", "project", "projects",
                                       "frontend", "backend", "server", "client", "web", "ios", "macos", "packages", "tmp"]

    static func pretty(cwd: String) -> String {
        let trimmed = cwd.hasSuffix("/") && cwd.count > 1 ? String(cwd.dropLast()) : cwd
        let name = (trimmed as NSString).lastPathComponent
        guard !name.isEmpty, name != "/" else { return cwd.isEmpty ? "проект" : cwd }
        if trimmed == NSHomeDirectory() { return "~" }
        let parent = ((trimmed as NSString).deletingLastPathComponent as NSString).lastPathComponent
        // Рабочие копии веток (`<проект>-wt/<ветка>`, `.worktrees/<ветка>`) и общие имена — с родителем.
        let isWorktree = parent.hasSuffix("-wt") || parent == "worktrees" || parent == ".worktrees"
        if !parent.isEmpty, parent != "/", isWorktree || generic.contains(name.lowercased()) || name.count <= 3 {
            let p = parent.hasSuffix("-wt") ? String(parent.dropLast(3)) : parent
            if p == ".worktrees" || p == "worktrees" {
                let grand = (((trimmed as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent as NSString)
                    .lastPathComponent
                return grand.isEmpty ? name : grand + "/" + name
            }
            return p + "/" + name
        }
        return name
    }

    /// Уложить в `max` знаков: убираем слова из середины («apple-music-native-player» → «apple-music…player»),
    /// обрезать посреди слова — только если и так не влезает (одно длинное слово).
    static func fit(_ name: String, max: Int) -> String {
        guard name.count > max, max >= 4 else { return name }
        let seps: Set<Character> = ["-", "_", " ", ".", "/"]
        // Слова вместе с разделителем после них.
        var words: [String] = []
        var cur = ""
        for ch in name {
            cur.append(ch)
            if seps.contains(ch) { words.append(cur); cur = "" }
        }
        if !cur.isEmpty { words.append(cur) }
        if words.count >= 2, let last = words.last {
            // Начало + «…» + последнее слово, сколько влезает слов сначала.
            var head = ""
            for w in words.dropLast() {
                // Разделитель в конце слова уступает место «…»: «apple-music-» + «…player» = «apple-music…player».
                let cand = head + w
                let bare = cand.last.map { seps.contains($0) } == true ? cand.count - 1 : cand.count
                if bare + 1 + last.count > max { break }
                head = cand
            }
            if !head.isEmpty {
                let h = head.last.map { seps.contains($0) } == true ? String(head.dropLast()) : head
                return h + "…" + last
            }
            if last.count + 1 <= max { return "…" + last }
        }
        return String(name.prefix(max - 1)) + "…"
    }
}
