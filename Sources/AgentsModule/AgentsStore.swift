import Foundation
import IslandCore
import SwiftUI

enum AgentKind: String, Codable, Sendable {
    case claude, codex
    var title: String { self == .claude ? "Claude Code" : "Codex" }
}

enum SessionStatus: Equatable {
    /// Сессия открыта, задачи нет.
    case idle
    case working
    /// Ждёт пользователя: разрешение, вопрос, ввод.
    case waiting
    case done
    case error
    /// SessionEnd — пропадёт через N минут.
    case ended

    /// Порядок в списке: ждёт → работает → ошибка → готово → прочее.
    var rank: Int {
        switch self {
        case .waiting: return 0
        case .working: return 1
        case .error: return 2
        case .done: return 3
        case .idle: return 4
        case .ended: return 5
        }
    }
}

/// Запрос разрешения, ждущий ответа в острове.
struct PermissionPrompt: Identifiable, Equatable {
    var id: String
    /// Соединение хука (nil — мок для снимков).
    var connection: Int?
    var tool: String
    /// `tool_use_id` запроса: по нему PostToolUse того же вызова закрывает карточку (ответили в терминале).
    var toolUseId: String? = nil
    var input: JSONValue?
    var suggestions: [JSONValue]
    var preview: ToolPreview
    var receivedAt: Date
    /// Человеческий заголовок («Изменить MediaViews.swift», «Claude спрашивает»). nil — посчитать по инструменту.
    var ask: AskPresentation? = nil

    /// Что показать про запрос (заголовок, подпись компакта).
    var presentation: AskPresentation { ask ?? AskPresentation.make(tool: tool, input: input, cwd: nil) }
    /// Вопросы AskUserQuestion (пусто у прочих инструментов).
    var questions: [AgentQuestion] { tool == "AskUserQuestion" ? AgentQuestion.parse(input) : [] }
    /// Вопрос с вариантами — отвечаем кнопками, «Разрешить» не показываем.
    var isQuestion: Bool { tool == "AskUserQuestion" }
    /// Сырой вход для «Подробнее»: JSON с отступами, ключи по алфавиту.
    var rawJSON: String {
        var o: [String: Any] = ["tool_name": tool]
        if let input { o["tool_input"] = input.foundation }
        guard let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let s = String(data: d, encoding: .utf8) else { return tool }
        return ToolPreview.sanitize(s)
    }

    /// Что предложить на «Всегда…». nil — кнопку не показывать.
    var alwaysOption: (label: String, permissions: [JSONValue])? {
        // Вопрос и план — разовые по смыслу: «Всегда…» не предлагаем.
        if tool == "AskUserQuestion" || tool == "ExitPlanMode" { return nil }
        if let first = suggestions.first, let label = Self.label(for: first, tool: tool) {
            return (label, suggestions)
        }
        // Без подсказки Claude — только узкие правила и только на эту сессию. Правило на инструмент целиком
        // (WebFetch на любой домен, Edit любых файлов, Bash) не даём: это канал утечки при prompt injection.
        switch tool {
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            // Режим «принимать правки»: только в рабочих папках сессии, не по всему диску.
            let mode: JSONValue = .object(["type": .string("setMode"), "mode": .string("acceptEdits"),
                                           "destination": .string("session")])
            return ("Всегда для правок", [mode])
        case "WebFetch":
            guard let host = input?["url"]?.stringValue.flatMap({ URL(string: $0)?.host }), !host.isEmpty else { return nil }
            let rule: JSONValue = .object(["type": .string("addRules"),
                                           "rules": .array([.object(["toolName": .string("WebFetch"),
                                                                     "ruleContent": .string("domain:" + host)])]),
                                           "behavior": .string("allow"),
                                           "destination": .string("session")])
            return ("Всегда: " + ToolPreview.clip(host, 22), [rule])
        default:
            return nil
        }
    }

    static func label(for s: JSONValue, tool: String) -> String? {
        switch s["type"]?.stringValue {
        case "addRules":
            guard s["behavior"]?.stringValue == "allow" else { return nil }
            let rules = s["rules"]?.arrayValue ?? []
            if let r = rules.first, let content = r["ruleContent"]?.stringValue, !content.isEmpty {
                return "Всегда: " + ToolPreview.clip(content, 22)
            }
            return "Всегда для \(rules.first?["toolName"]?.stringValue ?? tool)"
        case "setMode":
            return s["mode"]?.stringValue == "acceptEdits" ? "Всегда для правок" : nil
        case "addDirectories":
            return "Всегда в этой папке"
        default:
            return nil
        }
    }

    static func == (a: PermissionPrompt, b: PermissionPrompt) -> Bool { a.id == b.id && a.connection == b.connection }

    /// Это событие — результат того же вызова инструмента (на вопрос ответили в терминале)?
    /// Есть `tool_use_id` у обоих — сравниваем его, иначе — инструмент и вход (хук режет вход одинаково).
    /// Время уже учтено раньше: результат, чей хук стартовал до запроса, отбрасывается как опоздавший
    /// (`ts` < `lastEventTs`, запрос его сдвинул). Остаётся неразличимым только параллельный вызов с тем же
    /// входом, закончившийся после запроса; есть ли `tool_use_id` у PermissionRequest, вживую не проверено.
    func isAnswered(by m: WireMessage) -> Bool {
        if let a = toolUseId, let b = m.toolUseId { return a == b }
        return m.tool == tool && m.input == input
    }
}

struct AgentSession: Identifiable, Equatable {
    var id: String { agent.rawValue + ":" + sessionId }
    var agent: AgentKind
    var sessionId: String
    var cwd: String
    var project: String
    var term: TermInfo?
    var status: SessionStatus
    /// «делает X»: «правит Island.swift», «думает…», «готово · PR открыт».
    var activity: String
    var statusSince: Date
    var updatedAt: Date
    var endedAt: Date?
    var prompts: [PermissionPrompt] = []
    /// `ts` последнего применённого события: фоновые (async) хуки могут прийти не по порядку.
    var lastEventTs: Double = 0
    /// Ход завершён (Stop / StopFailure / SessionEnd) — поглощающее состояние (грабли AG1, CI#98): запоздалые
    /// PostToolUse фонового Bash, события субагентов (`agent_id`) и SubagentStop статус не трогают; снимают его
    /// UserPromptSubmit, SessionStart, живой запрос разрешения и PreToolUse основного агента, начатый после Stop
    /// (ход продолжился без нового запроса: Stop заблокирован чужим хуком или агента разбудила фоновая задача).
    var turnEnded = false
    /// Субагенты (`agent_id`), уже приславшие SubagentStop: их запоздалые события игнорируются.
    var endedSubagents: [String] = []

    /// Имя проекта: хвост пути (у рабочих копий и общих имён — с родителем), см. `ProjectName.pretty`.
    static func projectName(_ cwd: String) -> String { ProjectName.pretty(cwd: cwd) }

    /// Чем занят пользователь по этой сессии: вопрос в карточке, иначе уведомление/статус. nil — ничего не ждёт.
    var waitingSummary: String? {
        if let p = prompts.first { return p.presentation.statusText }
        return status == .waiting ? activity.prefix(1).uppercased() + activity.dropFirst() : nil
    }

    /// «Claude Code · вкладка 2», «Claude Code · ssh devbox».
    var subtitle: String {
        [agent.title, term?.placeLabel].compactMap { $0 }.joined(separator: " · ")
    }

    /// Ждёт пользователя: статус или висящая карточка разрешения.
    var isWaiting: Bool { status == .waiting || !prompts.isEmpty }
}

/// Решение пользователя по запросу разрешения.
enum PermissionDecision: Equatable {
    case allow
    case always
    case deny(String)
    /// Ответ на AskUserQuestion: {текст вопроса: метка варианта} (мультивыбор — метки через запятую).
    case answer([String: String])
    /// Отдать решение терминалу (обычный диалог Claude Code).
    case terminal
}

/// Подключены ли хуки (для пустого состояния и подвала).
struct IntegrationState: Equatable {
    var claude: Installer.Status = .notInstalled
    var codex: Installer.Status = .notInstalled
    var lastMessage: String?
}

/// Состояние модуля: сессии, запросы, ошибки. Всё на главном потоке.
@MainActor
final class AgentsStore: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []
    @Published var integration = IntegrationState()
    /// Прыжок в терминал упёрся в права Automation.
    @Published var jumpProblem: JumpProblem?
    /// Сервер сокета не поднялся (текст причины).
    @Published var serverProblem: String?
    /// Сессия, чей запрос сейчас показан карточкой (по умолчанию — первая ждущая).
    @Published var focusedSessionId: String?
    /// Открыто поле «причина отказа» у текущего запроса.
    @Published var denyEditing = false
    @Published var denyReason = ""
    /// У какого запроса раскрыт сырой JSON («Подробнее»). nil — ни у какого.
    @Published var rawShownFor: String?
    /// Выбранные варианты вопросов AskUserQuestion: текст вопроса → метки (мультивыбор, несколько вопросов).
    @Published var questionPicks: [String: [String]] = [:]

    /// Отметить вариант. Один вопрос без мультивыбора — сразу ответ (true: ответ ушёл).
    @discardableResult
    func pick(_ label: String, in q: AgentQuestion, of p: PermissionPrompt) -> Bool {
        let all = p.questions
        if all.count == 1, !q.multiSelect {
            decide(.answer([q.question: label]), promptId: p.id)
            return true
        }
        var cur = questionPicks[q.question] ?? []
        if q.multiSelect {
            if let i = cur.firstIndex(of: label) { cur.remove(at: i) } else { cur.append(label) }
        } else {
            cur = cur == [label] ? [] : [label]
        }
        questionPicks[q.question] = cur
        return false
    }

    /// Ответы на все вопросы готовы (у каждого выбран хоть один вариант)? Тогда — словарь для ответа.
    func pickedAnswers(_ p: PermissionPrompt) -> [String: String]? {
        let qs = p.questions
        guard !qs.isEmpty else { return nil }
        var out: [String: String] = [:]
        for q in qs {
            // Порядок меток — как у вариантов вопроса (не порядок нажатий).
            let chosen = q.options.map(\.label).filter { (questionPicks[q.question] ?? []).contains($0) }
            guard !chosen.isEmpty else { return nil }
            out[q.question] = chosen.joined(separator: ", ")
        }
        return out
    }

    /// Ответ хуку: (соединение, JSON-строка).
    var reply: ((Int, Data) -> Void)?
    /// Появился новый повод позвать пользователя (запрос разрешения / агент ждёт ввода).
    var onAttention: ((AgentSession) -> Void)?
    /// Закрыт последний запрос — модуль может свернуть остров, если сам его раскрыл.
    var onPromptsCleared: (() -> Void)?

    /// Через сколько убирать завершённые сессии.
    var keepAfterEnd: TimeInterval = 5 * 60
    /// Сессии без событий дольше этого (агент убит без SessionEnd) — убрать.
    var staleAfter: TimeInterval = 6 * 3600
    /// Codex не шлёт «сессия закончилась» — убираем «готово» через это время.
    var codexKeep: TimeInterval = 30 * 60

    private var expiryWork: DispatchWorkItem?
    /// Сколько моноширинных символов влезает в строку превью (от ширины острова) — для переноса команд Bash.
    var wrapColumns: @MainActor () -> Int = { ToolPreview.defaultColumns }

    struct JumpProblem: Equatable {
        var app: String
        var message: String
    }

    init() {}

    // MARK: - Производные

    var ordered: [AgentSession] {
        sessions.sorted { a, b in
            if a.status.rank != b.status.rank { return a.status.rank < b.status.rank }
            return a.updatedAt > b.updatedAt
        }
    }

    var focusedPromptSession: AgentSession? {
        let withPrompts = ordered.filter { !$0.prompts.isEmpty }
        if let f = focusedSessionId, let s = withPrompts.first(where: { $0.id == f }) { return s }
        return withPrompts.first
    }

    var currentPrompt: PermissionPrompt? { focusedPromptSession?.prompts.first }
    var hasPrompts: Bool { sessions.contains { !$0.prompts.isEmpty } }
    var workingCount: Int { sessions.filter { $0.status == .working }.count }
    /// «Ждёт» — и по статусу, и по висящей карточке (карточка без «ждёт» не бывает, но считаем надёжно).
    var waitingCount: Int { sessions.filter(\.isWaiting).count }

    // --- проверка подключения (AG2) ---
    /// Когда последний раз пришло событие от настоящего хука (не «Проверить»), по агенту.
    @Published private(set) var lastHookEventAt: [AgentKind: Date] = [:]
    /// Пришёл `--hook ping <метка>` (кнопка «Проверить»).
    var onPing: ((String) -> Void)?

    // MARK: - Сообщения хука

    func receive(_ line: Data, connection: Int?) {
        guard let msg = try? JSONDecoder().decode(WireMessage.self, from: line) else { return }
        handle(msg, connection: connection)
    }

    /// События, которые после завершения хода статус не трогают (AG1): их шлют фоновые задачи и субагенты.
    /// Исключение — PreToolUse основного агента, начатый после Stop (`resumesTurn` в `handle`).
    static let lateTurnEvents: Set<String> = ["pretooluse", "posttooluse", "posttoolusefailure", "permissiondenied",
                                              "subagentstop"]

    func handle(_ m: WireMessage, connection: Int?, now: Date = Date()) {
        if m.ev == "ping" { onPing?(m.id ?? ""); return }
        let agent = AgentKind(rawValue: m.agent ?? "claude") ?? .claude
        if lastHookEventAt[agent].map({ now.timeIntervalSince($0) >= 1 }) ?? true { lastHookEventAt[agent] = now }
        let sid = m.session ?? "?"
        let key = agent.rawValue + ":" + sid
        var s = sessions.first { $0.id == key } ?? AgentSession(
            agent: agent, sessionId: sid, cwd: m.cwd ?? "", project: AgentSession.projectName(m.cwd ?? ""),
            term: m.term, status: .idle, activity: "сессия открыта", statusSince: now, updatedAt: now)
        if let cwd = m.cwd, !cwd.isEmpty, cwd != s.cwd { s.cwd = cwd; s.project = AgentSession.projectName(cwd) }
        if let t = m.term { s.term = t }
        var attention = false
        // Опоздавшее фоновое событие (async-хук стартовал раньше, а дошёл позже) статус не трогает.
        // Ход завершён — запоздалые инструментальные события фоновых задач тоже (AG1); событие закончившегося
        // субагента — тоже.
        let fromEndedSubagent = m.agentId.map { s.endedSubagents.contains($0) } ?? false
        // PreToolUse основного агента (без `agent_id`), чей хук стартовал позже всего применённого (Stop в том
        // числе), — новая работа, а не хвост: фоновый Bash после Stop шлёт только PostToolUse, субагенты — с `agent_id`.
        let resumesTurn = s.turnEnded && m.ev == "pretooluse" && m.agentId == nil
            && (m.ts.map { $0 > s.lastEventTs } ?? false)
        let stale = m.ev != "permission"
            && ((m.ts ?? .infinity) < s.lastEventTs
                || (s.turnEnded && Self.lateTurnEvents.contains(m.ev) && !resumesTurn)
                || (fromEndedSubagent && m.ev != "subagentstop"))
        if let ts = m.ts, !stale { s.lastEventTs = max(s.lastEventTs, ts) }
        if !stale { s.updatedAt = now; s.endedAt = nil }

        func set(_ st: SessionStatus, _ text: String) {
            if s.status != st { s.statusSince = now }
            s.status = st; s.activity = text
        }

        switch stale ? "" : m.ev {
        case "sessionstart":
            s.turnEnded = false
            s.endedSubagents = []
            set(.idle, m.kind == "resume" ? "сессия продолжена" : "сессия открыта")
        case "userpromptsubmit":
            s.turnEnded = false
            s.endedSubagents = []
            dropPrompts(&s)
            set(.working, "думает…")
        case "pretooluse":
            if resumesTurn { s.turnEnded = false }
            // Карточку не трогаем: PreToolUse идёт до PermissionRequest, а параллельные вызовы спрашивают по очереди.
            // Хук, которого Claude отменил, закрывает соединение — карточка уходит в connectionClosed.
            if s.prompts.isEmpty { set(.working, Self.activityText(tool: m.tool ?? "", input: m.input, cwd: s.cwd)) }
        case "posttooluse", "posttoolusefailure", "permissiondenied":
            // Инструмент отработал (или отказ) — значит, на вопрос ответили (в том числе в терминале): «ждёт» снять.
            // Карточку закрывает только результат ТОГО ЖЕ вызова (tool_use_id): параллельный вызов её не трогает.
            closeAnswered(&s, by: m)
            if s.prompts.isEmpty, s.status != .ended {
                set(.working, m.ev == "permissiondenied" ? "отказано, думает…" : "думает…")
            }
        case "permission":
            let tool = m.tool ?? "?"
            // Живой запрос держит хук агента — значит, ход идёт (Stop мог быть заблокирован чужим Stop-хуком).
            s.turnEnded = false
            let p = PermissionPrompt(id: m.id ?? UUID().uuidString, connection: connection, tool: tool, toolUseId: m.toolUseId,
                                     input: m.input,
                                     suggestions: m.suggestions ?? [],
                                     preview: ToolPreview.make(tool: tool, input: m.input, cwd: s.cwd, columns: wrapColumns()),
                                     receivedAt: now,
                                     ask: AskPresentation.make(tool: tool, input: m.input, cwd: s.cwd, agent: agent))
            s.prompts.append(p)
            set(.waiting, Self.lowerFirst(p.presentation.statusText))
            attention = true
        case "notification":
            if m.kind == "idle_prompt" {
                // Агент стоит на вводе задачи: вопрос в терминале (если был) уже закрыт. Ошибку не затираем.
                if s.prompts.isEmpty, s.status != .error { set(.done, s.status == .done ? s.activity : "ждёт задачу") }
            } else if let n = AgentNotice.make(kind: m.kind, message: m.message, title: m.title), n.waiting {
                // permission_prompt при живой карточке — эхо того же вопроса (карточка уже всё показывает).
                if !(m.kind == "permission_prompt" && !s.prompts.isEmpty) {
                    set(.waiting, Self.lowerFirst(n.text)); attention = true
                }
            }
        case "stop":
            s.turnEnded = true
            dropPrompts(&s)
            let last = m.lastMessage.map { ToolPreview.clip(ToolPreview.firstLine($0), 80) }
            set(.done, (last?.isEmpty == false) ? "готово · " + last! : "готово")
        case "stopfailure":
            s.turnEnded = true
            dropPrompts(&s)
            set(.error, "ошибка: " + ToolPreview.clip(m.message ?? m.lastMessage ?? m.kind ?? "API", 70))
        case "subagentstop":
            if let a = m.agentId, !s.endedSubagents.contains(a) {
                s.endedSubagents.append(a)
                if s.endedSubagents.count > 64 { s.endedSubagents.removeFirst() }
            }
            if s.status == .working { s.activity = "субагент закончил" + (m.kind.map { $0.isEmpty ? "" : ": " + $0 } ?? "") }
        case "sessionend":
            s.turnEnded = true
            dropPrompts(&s)
            set(.ended, "сессия закрыта")
            s.endedAt = now
        default:
            break
        }

        if let i = sessions.firstIndex(where: { $0.id == key }) { sessions[i] = s } else { sessions.append(s) }
        if attention { onAttention?(s) }
        scheduleExpiry(now: now)
    }

    /// Хук отключился (Claude отменил ожидание или сам хук упал по таймауту) — карточку убрать.
    func connectionClosed(_ connection: Int) {
        for i in sessions.indices {
            let before = sessions[i].prompts.count
            sessions[i].prompts.removeAll { $0.connection == connection }
            if before != sessions[i].prompts.count, sessions[i].prompts.isEmpty, sessions[i].status == .waiting {
                sessions[i].activity = "ждёт ответа в терминале"
            }
        }
        afterPromptChange()
    }

    /// Закрыть карточки, на которые ответили в терминале (пришёл результат того же вызова). Хуку — «ask»: он,
    /// скорее всего, уже снят агентом, ответ просто уйдёт в закрытое соединение.
    private func closeAnswered(_ s: inout AgentSession, by m: WireMessage) {
        let answered = s.prompts.filter { $0.isAnswered(by: m) }
        guard !answered.isEmpty else { return }
        for p in answered { if let c = p.connection { reply?(c, Self.replyData(id: p.id, decision: .terminal, prompt: p)) } }
        s.prompts.removeAll { p in answered.contains { $0.id == p.id } }
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.afterPromptChange() } }
    }

    private func dropPrompts(_ s: inout AgentSession) {
        guard !s.prompts.isEmpty else { return }
        for p in s.prompts { if let c = p.connection { reply?(c, Self.replyData(id: p.id, decision: .terminal, prompt: p)) } }
        s.prompts.removeAll()
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.afterPromptChange() } }
    }

    // MARK: - Решения

    func decide(_ decision: PermissionDecision, promptId: String? = nil) {
        guard let si = sessions.firstIndex(where: { s in s.prompts.contains { $0.id == (promptId ?? currentPrompt?.id) } }),
              let pi = sessions[si].prompts.firstIndex(where: { $0.id == (promptId ?? currentPrompt?.id) }) else { return }
        let p = sessions[si].prompts.remove(at: pi)
        if let c = p.connection { reply?(c, Self.replyData(id: p.id, decision: decision, prompt: p)) }
        let now = Date()
        if sessions[si].prompts.isEmpty {
            switch decision {
            case .allow, .always:
                sessions[si].status = .working; sessions[si].activity = Self.activityText(tool: p.tool, input: p.input, cwd: sessions[si].cwd)
            case .deny:
                sessions[si].status = .working; sessions[si].activity = "отказ принят, думает…"
            case .answer:
                sessions[si].status = .working; sessions[si].activity = "ответ получен, думает…"
            case .terminal:
                sessions[si].status = .waiting; sessions[si].activity = "ждёт ответа в терминале"
            }
            sessions[si].statusSince = now
        }
        sessions[si].updatedAt = now
        denyEditing = false
        denyReason = ""
        rawShownFor = nil
        questionPicks = [:]
        afterPromptChange()
    }

    static func replyData(id: String, decision: PermissionDecision, prompt: PermissionPrompt) -> Data {
        var r: [String: Any] = ["id": id]
        switch decision {
        case .allow: r["decision"] = "allow"
        case .always:
            r["decision"] = "allow"
            if let perms = prompt.alwaysOption?.permissions { r["updatedPermissions"] = perms.map(\.foundation) }
        case .deny(let reason):
            r["decision"] = "deny"
            r["message"] = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        case .answer(let answers):
            r["decision"] = "allow"
            r["answers"] = answers
        case .terminal: r["decision"] = "ask"
        }
        return (try? JSONSerialization.data(withJSONObject: r)) ?? Data()
    }

    private func afterPromptChange() {
        if let f = focusedSessionId, !sessions.contains(where: { $0.id == f && !$0.prompts.isEmpty }) { focusedSessionId = nil }
        if !hasPrompts { denyEditing = false; onPromptsCleared?() }
    }

    func remove(_ id: String) {
        guard let s = sessions.first(where: { $0.id == id }) else { return }
        var copy = s
        dropPrompts(&copy)
        sessions.removeAll { $0.id == id }
    }

    // MARK: - Истечение (один таймер на ближайшее, без опроса)

    func expiry(of s: AgentSession) -> Date {
        if let e = s.endedAt { return e.addingTimeInterval(keepAfterEnd) }
        if s.agent == .codex, s.status == .done { return s.updatedAt.addingTimeInterval(codexKeep) }
        return s.updatedAt.addingTimeInterval(staleAfter)
    }

    /// Модуль остановлен: таймер истечения снять, сессии забыть (сокет уже закрыт — хуки ушли в терминал).
    func shutdown() {
        expiryWork?.cancel()
        expiryWork = nil
        sessions = []
        focusedSessionId = nil
        denyEditing = false
        denyReason = ""
        jumpProblem = nil
    }

    func scheduleExpiry(now: Date = Date()) {
        expiryWork?.cancel()
        let expired = sessions.filter { $0.prompts.isEmpty && expiry(of: $0) <= now }.map(\.id)
        if !expired.isEmpty { sessions.removeAll { expired.contains($0.id) } }
        guard let next = sessions.filter({ $0.prompts.isEmpty }).map({ expiry(of: $0) }).min() else { return }
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.scheduleExpiry() } }
        expiryWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.5, next.timeIntervalSince(now)), execute: w)
    }

    // MARK: - Текст «что делает»

    nonisolated static func lowerFirst(_ s: String) -> String { s.prefix(1).lowercased() + s.dropFirst() }

    static func activityText(tool: String, input: JSONValue?, cwd: String) -> String {
        func s(_ k: String) -> String? { input?[k]?.stringValue }
        let file = (s("file_path") ?? s("notebook_path")).map { ($0 as NSString).lastPathComponent }
        switch tool {
        case "Edit", "MultiEdit", "NotebookEdit": return "правит " + (file ?? "файл")
        case "Write": return "пишет " + (file ?? "файл")
        case "Read": return "читает " + (file ?? "файл")
        case "Grep", "Glob": return "ищет " + ToolPreview.clip(s("pattern") ?? "", 40)
        case "Bash":
            if let d = s("description"), !d.isEmpty { return ToolPreview.clip(d.prefix(1).lowercased() + d.dropFirst(), 60) }
            let cmd = ToolPreview.firstLine(s("command") ?? "")
            if cmd.contains("test") { return "гоняет тесты" }
            return "запускает " + ToolPreview.clip(cmd, 50)
        case "WebFetch": return "читает " + (URL(string: s("url") ?? "")?.host ?? "страницу")
        case "WebSearch": return "ищет в сети"
        case "Task", "Agent": return "субагент: " + ToolPreview.clip(s("description") ?? "", 40)
        case "TodoWrite": return "планирует"
        default:
            return tool.hasPrefix("mcp__") ? ToolPreview.prettyMCP(tool) : tool
        }
    }

    // MARK: - Моки для снимков и самотеста

    func loadMock(_ list: [AgentSession]) { sessions = list }
    func noteHookEvent(_ agent: AgentKind, at date: Date) { lastHookEventAt[agent] = date }
    func resetHookEvents() { lastHookEventAt = [:] }
}
