import AppKit
import Foundation
import IslandCore

/// Превью того, что агент хочет сделать: diff для правок, команда для Bash, путь/URL для прочих.
struct ToolPreview: Equatable {
    enum Kind: Equatable { case context, added, removed, command, plain, gap }
    struct Line: Equatable {
        var kind: Kind
        var text: String
    }
    /// Строка над превью (серым): путь файла и счётчик правок/строк. Пусто — строки нет (что делает инструмент —
    /// в заголовке карточки, `AskPresentation`).
    var header: String
    var lines: [Line]
    /// Сколько строк не влезло.
    var hiddenCount: Int
    /// Команда Bash показана не целиком (длиннее `maxCommandLines` строк после переноса): «Разрешить» по ⌘↩
    /// не даём, полный текст — подсказкой и в терминале.
    var commandTruncated = false
    /// Полный текст команды Bash (для подсказки по наведению).
    var fullCommand: String?

    static let maxLines = 8
    /// Команду Bash не обрезаем по ширине, а переносим; строк после переноса — не больше этого.
    static let maxCommandLines = 12
    static let maxLineLength = 140
    /// Колонок моноширинного 11,5 pt при ширине острова 720 (см. `columns(forIslandWidth:)`).
    static let defaultColumns = 85

    /// Ширина знака шрифта превью (системный моноширинный 11,5 — 7,11 pt, измерено 14.11.2026).
    @MainActor static let charAdvance: CGFloat = {
        let f = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        let w = (String(repeating: "0", count: 100) as NSString).size(withAttributes: [.font: f]).width / 100
        return w > 3 ? w : 7.11
    }()

    /// Сколько знаков влезает в строку превью при ширине острова `w`: поля вкладки 2 × 22, карточки 2 × 14,
    /// превью 2 × 12, запас 10 (чтобы `lineLimit(1)` не съел последний знак).
    @MainActor static func columns(forIslandWidth w: CGFloat) -> Int {
        max(40, Int((w - 44 - 28 - 24 - 10) / charAdvance))
    }

    /// Короткое описание для строки статуса и компакта: «Edit Island.swift», «Bash: npm test».
    var short: String

    static func make(tool: String, input: JSONValue?, cwd: String?, maxLines: Int = maxLines,
                     columns: Int = defaultColumns) -> ToolPreview {
        let inp = input ?? .object([:])
        func s(_ k: String) -> String? { inp[k]?.stringValue }
        let path = s("file_path") ?? s("notebook_path") ?? s("path")
        let rel = path.map { relative($0, to: cwd) }
        let file = path.map { ($0 as NSString).lastPathComponent }

        var lines: [Line] = []
        var header = tool
        var short = tool
        var fullCommand: String?
        switch tool {
        case "Edit":
            header = rel ?? ""
            short = "Edit " + (file ?? "")
            lines = diff(old: s("old_string") ?? "", new: s("new_string") ?? "")
        case "MultiEdit":
            let edits = inp["edits"]?.arrayValue ?? []
            header = (rel ?? "") + " · \(edits.count) " + plural(edits.count, "правка", "правки", "правок")
            short = "MultiEdit " + (file ?? "")
            for (i, e) in edits.enumerated() {
                if i > 0 { lines.append(Line(kind: .gap, text: "⋯")) }
                lines += diff(old: e["old_string"]?.stringValue ?? "", new: e["new_string"]?.stringValue ?? "")
            }
        case "Write":
            let content = s("content") ?? ""
            let n = content.isEmpty ? 0 : content.split(separator: "\n", omittingEmptySubsequences: false).count
            header = (rel ?? "") + " · \(n) " + plural(n, "строка", "строки", "строк")
            short = "Write " + (file ?? "")
            lines = content.split(separator: "\n", omittingEmptySubsequences: false).map { Line(kind: .added, text: String($0)) }
        case "NotebookEdit":
            header = rel ?? ""
            short = "NotebookEdit " + (file ?? "")
            lines = (s("new_source") ?? "").split(separator: "\n", omittingEmptySubsequences: false)
                .map { Line(kind: .added, text: String($0)) }
        case "Bash":
            let cmd = sanitize(s("command") ?? "")
            header = ""   // описание — заголовок карточки
            short = "Bash: " + firstLine(cmd)
            fullCommand = cmd
            // Переносим, а не режем: хвост вида «… && curl x | sh» должен быть виден до «Разрешить».
            for (i, raw) in cmd.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let text = String(raw).replacingOccurrences(of: "\t", with: "    ")
                let chunks = wrap(text, width: max(10, columns - 2))
                for (j, c) in chunks.enumerated() {
                    lines.append(Line(kind: .command, text: (i == 0 && j == 0 ? "$ " : "  ") + c))
                }
            }
        case "WebFetch":
            header = ""
            short = "WebFetch " + (URL(string: s("url") ?? "")?.host ?? "")
            lines = [Line(kind: .plain, text: s("url") ?? "")]
            if let p = s("prompt") { lines.append(Line(kind: .context, text: p)) }
        case "WebSearch":
            header = ""
            short = "WebSearch: " + (s("query") ?? "")
            lines = [Line(kind: .plain, text: s("query") ?? "")]
        case "Read":
            header = ""
            short = "Read " + (file ?? "")
            lines = [Line(kind: .plain, text: rel ?? "")]
        case "Grep", "Glob":
            header = ""
            short = tool + ": " + (s("pattern") ?? "")
            lines = [Line(kind: .plain, text: s("pattern") ?? "")]
            if let rel { lines.append(Line(kind: .context, text: rel)) }
        case "Task", "Agent":
            header = s("subagent_type") ?? ""
            short = "субагент: " + (s("description") ?? "")
            lines = [Line(kind: .plain, text: s("description") ?? s("prompt") ?? "")]
        case "AskUserQuestion":
            // Вопрос и варианты рисует карточка вопроса (`QuestionBox`), не превью: сырого JSON нет.
            header = ""
            short = "вопрос"
        case "ExitPlanMode":
            // План (Markdown) — строками без разметки заголовков.
            header = ""
            short = "план"
            var raw = (s("plan") ?? "").split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            // Первый заголовок «# …» уже стоит подзаголовком карточки — второй раз не показываем.
            if raw.first?.trimmingCharacters(in: .whitespaces).hasPrefix("#") == true { raw.removeFirst() }
            lines = raw.map { Line(kind: .plain, text: planLine($0)) }
        default:
            // MCP и прочие: путь/URL, если есть, иначе строковые поля входа «Имя поля: значение» (вложенные
            // объекты — только по «Подробнее», сырым JSON превью не забиваем).
            header = ""   // сервер и инструмент — в заголовке карточки
            short = tool.hasPrefix("mcp__") ? prettyMCP(tool) : tool
            if let url = s("url") { lines = [Line(kind: .plain, text: url)] }
            else if let rel { lines = [Line(kind: .plain, text: rel)] }
            else if let o = inp.objectValue {
                for k in o.keys.sorted() where lines.count < 4 {
                    guard let v = o[k]?.stringValue, !v.isEmpty else { continue }
                    lines.append(Line(kind: .plain, text: humanKey(k) + ": " + firstLine(v)))
                }
                let rest = o.count - lines.count
                if rest > 0, lines.isEmpty || o.values.contains(where: { $0.stringValue == nil }) {
                    lines.append(Line(kind: .context, text: "ещё \(rest) " + plural(rest, "поле", "поля", "полей") + " — «Подробнее»"))
                }
            }
        }
        lines = dedent(lines.map { Line(kind: $0.kind, text: sanitize($0.text.replacingOccurrences(of: "\t", with: "    "))) })
        if fullCommand == nil { lines = lines.map { Line(kind: $0.kind, text: clip($0.text)) } }
        let limit = fullCommand != nil ? max(maxLines, maxCommandLines) : maxLines
        let hidden = max(0, lines.count - limit)
        if hidden > 0 { lines = Array(lines.prefix(limit)) }
        var p = ToolPreview(header: clip(sanitize(header)), lines: lines, hiddenCount: hidden, short: clip(sanitize(short), 60))
        p.fullCommand = fullCommand
        p.commandTruncated = fullCommand != nil && hidden > 0
        return p
    }

    /// Жёсткий перенос по `width` знаков (моноширинный шрифт — ширина знака одна).
    static func wrap(_ s: String, width: Int) -> [String] {
        guard s.count > width else { return [s] }
        var out: [String] = []
        var rest = Substring(s)
        while rest.count > width {
            out.append(String(rest.prefix(width)))
            rest = rest.dropFirst(width)
        }
        out.append(String(rest))
        return out
    }

    /// Управляющие знаки (\r, ESC-последовательности, NUL) и невидимые «переворачиватели» направления текста
    /// (U+202A–202E, U+2066–2069, U+200E/F) могут спрятать часть команды на экране — показываем их явно.
    static func sanitize(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: isHiddenScalar) else { return s }
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            if u == "\n" || u == "\t" { out.append(u); continue }
            if isHiddenScalar(u) {
                out.append(contentsOf: (u == "\r" ? "␍" : u.value == 0x1B ? "␛" : "�").unicodeScalars)
            } else {
                out.append(u)
            }
        }
        return String(out)
    }

    static func isHiddenScalar(_ u: Unicode.Scalar) -> Bool {
        if u == "\n" || u == "\t" { return false }
        let v = u.value
        return v < 0x20 || v == 0x7F || (0x80...0x9F).contains(v) || (0x202A...0x202E).contains(v)
            || (0x2066...0x2069).contains(v) || v == 0x200E || v == 0x200F
    }

    // MARK: diff по строкам (LCS), неизменённое — контекстом по одной строке вокруг правок

    static func diff(old: String, new: String) -> [Line] {
        let a = old.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let b = new.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if a.count * b.count > 250_000 {
            // Огромная правка — без LCS: всё старое минусом, всё новое плюсом.
            return a.map { Line(kind: .removed, text: $0) } + b.map { Line(kind: .added, text: $0) }
        }
        let n = a.count, m = b.count
        var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
                }
            }
        }
        var raw: [Line] = []
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, a[i] == b[j] { raw.append(Line(kind: .context, text: a[i])); i += 1; j += 1 }
            else if j < m, i == n || dp[i][j + 1] >= dp[i + 1][j] { raw.append(Line(kind: .added, text: b[j])); j += 1 }
            else { raw.append(Line(kind: .removed, text: a[i])); i += 1 }
        }
        // Удалённые — перед добавленными внутри блока правки.
        var out: [Line] = []
        var block: [Line] = []
        func flush() {
            out += block.filter { $0.kind == .removed } + block.filter { $0.kind == .added }
            block = []
        }
        for l in raw { if l.kind == .context { flush(); out.append(l) } else { block.append(l) } }
        flush()
        // Контекст: по одной строке вокруг изменений, длинные куски — «⋯».
        let changed = out.indices.filter { out[$0].kind != .context }
        guard !changed.isEmpty else { return [] }
        var keep = Set<Int>()
        for c in changed { keep.formUnion([c - 1, c, c + 1].filter { out.indices.contains($0) }) }
        var result: [Line] = []
        var last = -1
        for idx in out.indices where keep.contains(idx) {
            if last >= 0, idx > last + 1 { result.append(Line(kind: .gap, text: "⋯")) }
            var l = out[idx]
            if l.kind == .context, l.text.trimmingCharacters(in: .whitespaces).isEmpty { l.text = "" }
            result.append(l)
            last = idx
        }
        return result
    }

    // MARK: помощники

    /// Общий отступ строк кода (правка внутри функции) убираем — в острове мало места.
    static func dedent(_ lines: [Line]) -> [Line] {
        let code: Set<Kind> = [.added, .removed, .context]
        let indents = lines.filter { code.contains($0.kind) && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.text.prefix { $0 == " " }.count }
        guard let cut = indents.min(), cut > 0 else { return lines }
        return lines.map { l in
            guard code.contains(l.kind) else { return l }
            return Line(kind: l.kind, text: String(l.text.dropFirst(min(cut, l.text.prefix { $0 == " " }.count))))
        }
    }

    static func relative(_ path: String, to cwd: String?) -> String {
        if let cwd, !cwd.isEmpty {
            let base = cwd.hasSuffix("/") ? cwd : cwd + "/"
            if path.hasPrefix(base) { return String(path.dropFirst(base.count)) }
        }
        let home = NSHomeDirectory()
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    static func clip(_ s: String, _ n: Int = maxLineLength) -> String {
        s.count > n ? String(s.prefix(n - 1)) + "…" : s
    }

    static func firstLine(_ s: String) -> String {
        String(s.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first ?? "")
    }

    /// `mcp__<сервер>__<инструмент>` → «сервер · инструмент». Разделитель — двойное подчёркивание:
    /// одинарное бывает в именах сервера (`claude_ai_Gmail`) и инструмента (`create_pr`).
    static func prettyMCP(_ tool: String) -> String {
        let parts = tool.components(separatedBy: "__")   // mcp, server, tool…
        guard parts.count >= 3, parts[0] == "mcp", !parts[1].isEmpty else { return tool }
        return parts[1] + " · " + parts[2...].joined(separator: "__")
    }

    /// `## Шаг 1` → `Шаг 1`, `- [ ] пункт` → `• пункт`.
    static func planLine(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespaces)
        while t.hasPrefix("#") { t.removeFirst() }
        t = t.trimmingCharacters(in: .whitespaces)
        for p in ["- [ ] ", "- [x] ", "- ", "* "] where t.hasPrefix(p) { t = "• " + t.dropFirst(p.count); break }
        return t.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
    }

    /// `file_path` → «File path», `repo_name` → «Repo name».
    static func humanKey(_ k: String) -> String {
        let w = k.replacingOccurrences(of: "_", with: " ")
        return w.prefix(1).uppercased() + w.dropFirst()
    }

    static func compactJSON(_ v: JSONValue?) -> String {
        guard let v, let d = try? JSONSerialization.data(withJSONObject: v.foundation, options: [.fragmentsAllowed]),
              let s = String(data: d, encoding: .utf8) else { return "" }
        return s
    }
}

/// 1 правка, 2 правки, 5 правок.
func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
    let n10 = n % 10, n100 = n % 100
    if n10 == 1 && n100 != 11 { return one }
    if (2...4).contains(n10) && !(12...14).contains(n100) { return few }
    return many
}
