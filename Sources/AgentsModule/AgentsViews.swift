import AppKit
import IslandCore
import SwiftUI

// Вкладка «Агенты» — по макету design/mockups/05-agents.html. Цвета — из темы; статусы — IslandPalette
// с тёмными вариантами на светлых темах (paper, sakura).

struct AgentsTabView: View {
    @ObservedObject var controller: AgentsController
    @ObservedObject var store: AgentsStore
    @Environment(\.islandTheme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot

    init(controller: AgentsController) {
        self.controller = controller
        store = controller.store
    }

    var body: some View {
        Group {
            if store.sessions.isEmpty {
                VStack(alignment: .leading, spacing: AgentsLayout.spacing) {
                    banners
                    AgentsEmptyView(controller: controller, store: store)
                }
            } else {
                let plan = AgentsLayout.plan(store)
                VStack(alignment: .leading, spacing: AgentsLayout.spacing) {
                    banners
                    if let card = plan.card { PermissionCard(controller: controller, store: store, session: card) }
                    ForEach(plan.rows) { s in SessionRow(controller: controller, session: s) }
                    if plan.hidden > 0 {
                        Text("и ещё \(plan.hidden) " + plural(plan.hidden, "сессия", "сессии", "сессий"))
                            .font(theme.font(11.5, .semibold)).foregroundStyle(theme.tertiary)
                            .frame(height: AgentsLayout.moreLineHeight).padding(.leading, 14)
                    }
                    AgentsFooter(controller: controller, store: store)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        // Горячие клавиши работают, когда панель ключевая: ввод берём, пока курсор над вкладкой с вопросом,
        // и отдаём приложению пользователя, когда курсор ушёл (кроме набора причины отказа).
        .onHover { inside in if inside { controller.wantKeyboard(true) } else { controller.hoverEnded() } }
        .background {
            if !isSnapshot { WindowReader { controller.hostWindow = $0 } }
        }
    }

    @ViewBuilder private var banners: some View {
        if let p = store.serverProblem {
            ProblemBanner(text: p, button: nil, action: {})
        }
        if let j = store.jumpProblem {
            ProblemBanner(text: j.message, button: "Разрешить…", action: { TerminalJumper.openAutomationSettings() },
                          onClose: { store.jumpProblem = nil })
        }
    }
}

/// Окно, в котором показана вьюха (для подписки на «перестало быть ключевым»). Только вне снимков.
struct WindowReader: NSViewRepresentable {
    var onWindow: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView { Probe(onWindow) }
    func updateNSView(_ v: NSView, context: Context) {}
    final class Probe: NSView {
        let onWindow: (NSWindow?) -> Void
        init(_ f: @escaping (NSWindow?) -> Void) { onWindow = f; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let w = window
            DispatchQueue.main.async { [onWindow] in onWindow(w) }
        }
    }
}

// MARK: - Статус

struct StatusMark: View {
    var status: SessionStatus
    @Environment(\.islandTheme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.islandMotion) private var motion

    var body: some View {
        switch status {
        // Крутится только при полном движении: «Уменьшить движение», энергосбережение, скрытое окно — стоит.
        case .working: Spinner(animated: !isSnapshot && motion.allowsContinuousAnimation).frame(width: 14, height: 14)
        case .waiting: StatusDot(IslandPalette.warn, size: 9).frame(width: 14)
        case .done: Circle().fill(IslandPalette.ok).frame(width: 9, height: 9).frame(width: 14)
        case .error: StatusDot(IslandPalette.err, size: 9).frame(width: 14)
        case .idle, .ended:
            Circle().strokeBorder(theme.tertiary, lineWidth: 1.5).frame(width: 9, height: 9).frame(width: 14)
        }
    }
}

/// Кольцо «работает» (`.spin`): крутится, только пока вкладка на экране.
struct Spinner: View {
    var animated: Bool
    @Environment(\.islandTheme) private var theme
    @Environment(\.islandMotion) private var motion
    var body: some View {
        // Только при полном движении: окно не видно/сон/«Уменьшить движение» — стоит (было без проверки, 14.11).
        // Вращение — Core Animation (`SpinningRing`): в процессе ни кадра (было TimelineView 20 к/с).
        if animated && motion.allowsContinuousAnimation {
            SpinningRing(track: theme.primary.opacity(theme.isLight ? 0.3 : 0.15), arc: IslandPalette.ok, lineWidth: 2,
                         fraction: 0.25, period: 1)
        } else {
            ring.rotationEffect(.degrees(-30))
        }
    }
    private var ring: some View {
        ZStack {
            Circle().stroke(theme.primary.opacity(theme.isLight ? 0.3 : 0.15), lineWidth: 2)
            Circle().trim(from: 0, to: 0.25).stroke(IslandPalette.ok, style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
        .padding(1)
    }
}

/// Сколько прошло: «0:41», «6 мин», «2 ч». Общие часы `AgentsClock` (SharedTicker раз в секунду, только пока
/// вкладка или раздел настроек на экране).
struct Elapsed: View {
    var since: Date
    var prefix: String = ""
    var compact = false
    @ObservedObject private var clock = AgentsClock.shared
    @Environment(\.isSnapshot) private var isSnapshot

    init(since: Date, prefix: String = "", compact: Bool = false) {
        self.since = since; self.prefix = prefix; self.compact = compact
    }

    var body: some View {
        let now = isSnapshot ? Date() : max(clock.now, since)
        Text(prefix + Self.format(now.timeIntervalSince(since), compact: compact))
    }

    /// «12 с назад», «3 мин назад», «2 ч назад».
    static func ago(_ t: TimeInterval) -> String {
        t < 5 ? "только что" : format(t, compact: true) + " назад"
    }

    static func format(_ t: TimeInterval, compact: Bool) -> String {
        let s = max(0, Int(t))
        if compact {
            if s < 60 { return "\(s) с" }
            if s < 3600 { return "\(s / 60) мин" }
            return "\(s / 3600) ч"
        }
        if s < 3600 { return String(format: "%d:%02d", s / 60, s % 60) }
        return "\(s / 3600) ч \(s % 3600 / 60) мин"
    }
}

/// Цвета текста статусов под тему.
enum AgentColors {
    static func ok(_ t: Theme) -> Color { IslandPalette.okText(t) }
    static func warm(_ t: Theme) -> Color { IslandPalette.warmText(t) }
    static func err(_ t: Theme) -> Color { t.isLight ? Color(hex: "#C0223F") : Color(hex: "#FF8AA0") }
    static func added(_ t: Theme) -> Color { t.isLight ? Color(hex: "#13804F") : Color(hex: "#7CF0B4") }
    static func removed(_ t: Theme) -> Color { t.isLight ? Color(hex: "#C0223F") : Color(hex: "#FF8AA0") }
    /// Подложка карточки сессии (`rgba(255,255,255,.055)` в макете).
    static func card(_ t: Theme) -> Color { t.controlFillColor }
    /// Подложка diff (`rgba(0,0,0,.55)`), на светлом — лёгкая тень.
    static func diffBackground(_ t: Theme) -> Color { t.isLight ? Color.black.opacity(0.055) : Color.black.opacity(0.5) }
}

// MARK: - Строка сессии

struct SessionTitle: View {
    var session: AgentSession
    @Environment(\.islandTheme) private var theme
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(session.project).font(theme.font(14, .bold)).foregroundStyle(theme.primary).lineLimit(1)
            Text(session.subtitle).font(theme.font(12, .semibold)).foregroundStyle(theme.tertiary).lineLimit(1)
        }
        .layoutPriority(1)
    }
}

struct SessionRow: View {
    @ObservedObject var controller: AgentsController
    var session: AgentSession
    @Environment(\.islandTheme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            StatusMark(status: session.status)
            SessionTitle(session: session)
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                detail
                trailing
            }
            .font(theme.font(12.5, .medium))
        }
        .padding(.horizontal, 14)
        .frame(height: AgentsLayout.rowHeight)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(AgentColors.card(theme)))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture { controller.jump(session) }
        .help(session.term?.canJump == true ? "Перейти в терминал" : session.cwd)
    }

    @ViewBuilder private var detail: some View {
        switch session.status {
        case .working:
            HStack(spacing: 0) {
                Text(session.activity).lineLimit(1).truncationMode(.tail)
                Elapsed(since: session.statusSince, prefix: " · ", compact: true)
            }
            .foregroundStyle(theme.secondary)
        case .waiting:
            HStack(spacing: 0) {
                Text(session.activity).lineLimit(1).truncationMode(.tail)
                Elapsed(since: session.statusSince, prefix: " · ")
            }
            .foregroundStyle(AgentColors.warm(theme))
        case .done:
            Text(session.activity).lineLimit(1).truncationMode(.tail).foregroundStyle(AgentColors.ok(theme))
        case .error:
            Text(session.activity).lineLimit(1).truncationMode(.tail).foregroundStyle(AgentColors.err(theme))
        case .idle, .ended:
            Text(session.activity).lineLimit(1).foregroundStyle(theme.tertiary)
        }
    }

    @ViewBuilder private var trailing: some View {
        if !session.prompts.isEmpty {
            AgentButton("Ответить", style: .plain, height: 24) { controller.store.focusedSessionId = session.id }
        } else if session.status == .done, session.term?.canJump == true {
            AgentButton("Открыть", style: .plain, height: 24) { controller.jump(session) }
        } else if session.term?.canJump == true {
            Image(systemName: "apple.terminal").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.tertiary)
        }
    }
}

// MARK: - Карточка разрешения

struct PermissionCard: View {
    @ObservedObject var controller: AgentsController
    @ObservedObject var store: AgentsStore
    var session: AgentSession
    @Environment(\.islandTheme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @FocusState private var reasonFocused: Bool

    var body: some View {
        let prompt = session.prompts.first
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                StatusMark(status: .waiting)
                SessionTitle(session: session)
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    Elapsed(since: prompt?.receivedAt ?? session.statusSince, prefix: "ждёт ")
                        .foregroundStyle(theme.secondary)
                    // Явная кнопка «ответить в терминале»: хук отпускается, Claude показывает свой диалог.
                    AgentButton("В терминал · esc", systemImage: "apple.terminal", style: .hint, height: 22) {
                        controller.answerInTerminal(session)
                    }
                    .help("Ответить в терминале (Esc): остров отпустит запрос, Claude Code спросит в своём окне")
                    .fixedSize()
                }
                .font(theme.font(12.5, .medium))
            }
            .frame(height: AgentsLayout.headerHeight)
            if let prompt {
                AskTitleRow(store: store, prompt: prompt)
                if prompt.isQuestion { QuestionBox(store: store, prompt: prompt) }
                // «Подробнее» показывает сырой запрос вместо превью (карточка не перерастает вкладку).
                if store.rawShownFor == prompt.id { RawBox(text: prompt.rawJSON) }
                else if AgentsLayout.showsPreview(prompt) { DiffBox(preview: prompt.preview) }
            }
            if store.denyEditing { denyRow } else if let prompt { actionsRow(prompt) }
            if session.prompts.count > 1 {
                Text("ещё \(session.prompts.count - 1) " + plural(session.prompts.count - 1, "запрос", "запроса", "запросов") + " после этого")
                    .font(theme.font(11.5, .semibold)).foregroundStyle(theme.tertiary)
                    .frame(height: AgentsLayout.moreLineHeight)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(colors: [IslandPalette.warn.opacity(theme.isLight ? 0.16 : 0.13),
                                              IslandPalette.warn.opacity(theme.isLight ? 0.06 : 0.04)],
                                     startPoint: .top, endPoint: .bottom))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(IslandPalette.warn.opacity(theme.isLight ? 0.45 : 0.28), lineWidth: 1)
        )
        .background(escapeKey)
    }

    /// Главная кнопка по типу запроса: «Разрешить» / «Утвердить план» / «Ответить» (вопрос с отметками).
    /// Один вопрос без мультивыбора отвечается щелчком по варианту — главной кнопки нет.
    @ViewBuilder private func primaryButton(_ p: PermissionPrompt, partial: Bool) -> some View {
        switch p.presentation.kind {
        case .question:
            let qs = p.questions
            if qs.count > 1 || qs.first?.multiSelect == true {
                let answers = store.pickedAnswers(p)
                AgentButton("Ответить", systemImage: "checkmark", style: answers == nil ? .plain : .ok) {
                    if let a = answers { controller.decide(.answer(a)) }
                }
                .keyboardShortcut(answers == nil ? nil : KeyboardShortcut(.return, modifiers: .command))
                .opacity(answers == nil ? 0.55 : 1)
                .help(answers == nil ? "Выбери вариант в каждом вопросе" : "⌘↩")
                .fixedSize()
            }
        case .plan:
            AgentButton("Утвердить план", systemImage: "checkmark", style: .ok) { controller.decide(.allow) }
                .keyboardShortcut(.return, modifiers: .command)
                .help("⌘↩ — агент начнёт делать по плану")
                .fixedSize()
        case .permission:
            AgentButton("Разрешить", systemImage: "checkmark", style: .ok) { controller.decide(.allow) }
                .keyboardShortcut(partial ? nil : KeyboardShortcut(.return, modifiers: .command))
                .help(partial ? "Команда показана не целиком — проверь её в терминале" : "⌘↩")
                .fixedSize()
        }
    }

    private func actionsRow(_ p: PermissionPrompt) -> some View {
        // Команда видна не целиком — «Разрешить» только щелчком, не вслепую по ⌘↩.
        let partial = p.preview.commandTruncated
        let kind = p.presentation.kind
        return HStack(spacing: 8) {
            primaryButton(p, partial: partial)
            if let always = p.alwaysOption {
                AgentButton(always.label, style: .plain) { controller.decide(.always) }
                    .help(always.permissions.first?["destination"]?.stringValue == "session"
                          ? "До конца этой сессии" : "Claude Code запомнит правило")
            }
            AgentButton(kind == .plan ? "Доработать план…" : kind == .question ? "Ответить своими словами…" : "Отклонить с причиной…",
                        systemImage: kind == .permission ? "xmark" : "text.bubble", style: kind == .permission ? .destructive : .plain) {
                controller.beginDeny()
            }
                .keyboardShortcut(.delete, modifiers: .command)
                .help("⌘⌫")
                .fixedSize()
            Spacer(minLength: 0)
            // Подсказка, а не кнопка (как в макете): ⌘↩ — разрешить, ⌘⌫ — отклонить.
            Text(kind == .question
                 ? (p.questions.count == 1 && p.questions.first?.multiSelect == false
                    ? "⌘1…⌘\(min(9, p.questions.first?.options.count ?? 1)) / esc" : "⌘↩ / esc")
                 : partial ? "⌘⌫ · команда длиннее" : "⌘↩ / ⌘⌫")
                .font(theme.font(AgentsLayout.buttonsHeight * 0.43, .semibold))
                .foregroundStyle(theme.tertiary)
                .lineLimit(1)
                .padding(.horizontal, AgentsLayout.buttonsHeight * 0.45)
                .frame(height: AgentsLayout.buttonsHeight)
                .background(Capsule().strokeBorder(theme.primary.opacity(theme.isLight ? 0.14 : 0.1), lineWidth: 1))
                .help("⌘↩ — разрешить, ⌘⌫ — отклонить с причиной, Esc — ответить в терминале")
                .fixedSize()
        }
        .frame(height: AgentsLayout.buttonsHeight)
    }

    /// Подсказка поля по типу запроса: отказ с причиной / свой ответ на вопрос / что поменять в плане.
    private var denyPlaceholder: String {
        switch session.prompts.first?.presentation.kind {
        case .question?: return "Твой ответ агенту…"
        case .plan?: return "Что поменять в плане…"
        default: return "Причина для агента…"
        }
    }

    private var denyRow: some View {
        let permission = session.prompts.first?.presentation.kind == .permission
        return HStack(spacing: 8) {
            ZStack(alignment: .leading) {
                Capsule().fill(theme.controlFillColor)
                Capsule().strokeBorder(AgentColors.err(theme).opacity(0.5), lineWidth: 1)
                if isSnapshot {
                    Text(store.denyReason.isEmpty ? denyPlaceholder : store.denyReason)
                        .foregroundStyle(store.denyReason.isEmpty ? theme.tertiary : theme.primary)
                        .padding(.horizontal, 12)
                } else {
                    TextField("", text: $store.denyReason, prompt: Text(denyPlaceholder).foregroundStyle(theme.tertiary))
                        .textFieldStyle(.plain)
                        .foregroundStyle(theme.primary)
                        .padding(.horizontal, 12)
                        .focused($reasonFocused)
                        .onSubmit { controller.decide(.deny(store.denyReason)) }
                        .onAppear { DispatchQueue.main.async { reasonFocused = true } }
                }
            }
            .font(theme.font(12.5, .medium))
            .frame(height: AgentsLayout.buttonsHeight)
            AgentButton(permission ? "Отклонить" : "Отправить", systemImage: permission ? "xmark" : "paperplane.fill",
                        style: permission ? .destructive : .ok) { controller.decide(.deny(store.denyReason)) }
                .keyboardShortcut(.return, modifiers: .command)
            AgentButton("Отмена", style: .plain) { store.denyEditing = false }
        }
        .frame(height: AgentsLayout.buttonsHeight)
    }

    /// Esc: при открытой причине — закрыть поле, иначе ответить в терминале.
    private var escapeKey: some View {
        Button("") {
            if store.denyEditing { store.denyEditing = false } else { controller.answerInTerminal(session) }
        }
        .keyboardShortcut(.cancelAction)
        .buttonStyle(.plain)
        .opacity(0)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
    }
}

/// Превью diff/команды (`.diff` в макете): моно 11,5, строки по 18 pt.
struct DiffBox: View {
    var preview: ToolPreview
    @Environment(\.islandTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !preview.header.isEmpty { line(preview.header, theme.tertiary) }
            ForEach(Array(preview.lines.enumerated()), id: \.offset) { _, l in
                switch l.kind {
                case .removed: line("− " + l.text, AgentColors.removed(theme))
                case .added: line("+ " + l.text, AgentColors.added(theme))
                case .context: line("  " + l.text, theme.secondary.opacity(0.75))
                case .gap: line("  ⋯", theme.tertiary)
                case .command:
                    BashHighlight.text(l.text, theme: theme)
                        .font(.system(size: 11.5, weight: .regular, design: .monospaced))
                        .lineLimit(1).truncationMode(.tail)
                        .frame(height: AgentsLayout.lineHeight, alignment: .leading)
                case .plain: line(l.text, theme.secondary)
                }
            }
            if preview.commandTruncated {
                line("  … ещё \(preview.hiddenCount) " + plural(preview.hiddenCount, "строка", "строки", "строк")
                     + " — полный текст в терминале и по наведению", AgentColors.warm(theme))
            } else if preview.hiddenCount > 0 {
                line("  … ещё \(preview.hiddenCount) " + plural(preview.hiddenCount, "строка", "строки", "строк"), theme.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AgentColors.diffBackground(theme)))
        .help(preview.fullCommand.map { ToolPreview.clip($0, 4000) } ?? "")
    }

    private func line(_ s: String, _ c: Color) -> some View {
        Text(s.isEmpty ? " " : s)
            .font(.system(size: 11.5, weight: .regular, design: .monospaced))
            .foregroundStyle(c)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(height: AgentsLayout.lineHeight, alignment: .leading)
    }
}

// MARK: - Кнопка с цветами под тему

/// Как `IslandButton`, но «Отклонить» читается и на светлых темах, плюс стиль-подсказка.
struct AgentButton: View {
    enum Style { case plain, ok, destructive, accent, hint }
    var title: String
    var systemImage: String?
    var style: Style
    var height: CGFloat
    var action: () -> Void
    @Environment(\.islandTheme) private var theme

    init(_ title: String, systemImage: String? = nil, style: Style = .plain, height: CGFloat = AgentsLayout.buttonsHeight,
         action: @escaping () -> Void) {
        self.title = title; self.systemImage = systemImage; self.style = style; self.height = height; self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let s = systemImage { Image(systemName: s).font(.system(size: height * 0.4, weight: .bold)) }
                Text(title).font(theme.font(height * 0.43, .semibold)).lineLimit(1)
            }
            .padding(.horizontal, height * 0.45)
            .frame(height: height)
            .foregroundStyle(fg)
            .background(Capsule().fill(bg))
            .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
    }

    private var fg: Color {
        switch style {
        case .plain: return theme.primary
        case .ok: return Color(hex: "#03140B")
        case .destructive: return AgentColors.err(theme)
        case .accent: return .white
        case .hint: return theme.tertiary
        }
    }
    private var bg: Color {
        switch style {
        case .plain, .hint: return theme.controlFillColor
        case .ok: return IslandPalette.ok
        case .destructive: return IslandPalette.err.opacity(theme.isLight ? 0.12 : 0.16)
        case .accent: return theme.accentColor
        }
    }
}

// MARK: - Подвал: сводка, подключение, звук

struct AgentsFooter: View {
    @ObservedObject var controller: AgentsController
    @ObservedObject var store: AgentsStore
    @Environment(\.islandTheme) private var theme

    var body: some View {
        // Сводка «N работают · M ждёт» — в правом верху вкладки (AgentsHeaderSummary, макет 05).
        HStack(spacing: 10) {
            if controller.confirmInstall {
                tile {
                    HStack(spacing: 6) {
                        Text("Хуки в ~/.claude?").foregroundStyle(theme.secondary)
                        Spacer(minLength: 0)
                        AgentButton("Да", style: .ok, height: 22) { controller.confirmInstall = false; controller.installClaude() }
                        AgentButton("Нет", style: .plain, height: 22) { controller.confirmInstall = false }
                    }
                }
                .help("Добавить хуки SimpleIsland в ~/.claude/settings.json (чужие записи не трогаются, рядом — резервная копия)")
            } else {
                tile {
                    HStack(spacing: 4) {
                        connection("Claude Code", store.integration.claude)
                        Text("·").foregroundStyle(theme.tertiary)
                        connection("Codex", store.integration.codex)
                        if let last = store.lastHookEventAt.values.max() {
                            Text("·").foregroundStyle(theme.tertiary)
                            Elapsed(since: last, prefix: "событие ", compact: true).foregroundStyle(theme.tertiary)
                        }
                    }
                }
                .onTapGesture { if store.integration.claude != .installed, !isUnavailable { controller.confirmInstall = true } }
                .help(store.integration.claude == .installed ? "Хуки на месте. Проверить и отключить — в настройках модуля"
                      : store.integration.claude.needsReinstall ? "Переподключить Claude Code…" : "Подключить Claude Code…")
            }
            tile {
                HStack(spacing: 0) {
                    Text("Звук на «ждёт»: ").foregroundStyle(theme.tertiary)
                    Text(AgentsPrefs.soundTitle(controller.prefs.sound)).foregroundStyle(theme.primary)
                }
            }
            .onTapGesture { controller.cycleSound() }
            .help("Щёлкни, чтобы сменить звук")
        }
        .font(theme.font(11.5, .semibold))
        .frame(height: AgentsLayout.footerHeight)
    }

    private var isUnavailable: Bool {
        if case .unavailable = store.integration.claude { return true }
        return false
    }

    private func connection(_ name: String, _ st: Installer.Status) -> some View {
        HStack(spacing: 4) {
            Text(name).foregroundStyle(theme.tertiary)
            switch st {
            case .installed: Image(systemName: "checkmark").foregroundStyle(AgentColors.ok(theme))
            case .outdated, .otherPath: Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(AgentColors.warm(theme))
            default: Text("—").foregroundStyle(theme.tertiary)
            }
        }
    }

    private func tile<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        c()
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.primary.opacity(0.04)))
            .contentShape(Rectangle())
    }
}

// MARK: - Пусто

struct AgentsEmptyView: View {
    @ObservedObject var controller: AgentsController
    @ObservedObject var store: AgentsStore
    @Environment(\.islandTheme) private var theme

    var body: some View {
        let claude = store.integration.claude
        HStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(colors: [IslandPalette.warn, IslandPalette.ok], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "apple.terminal.fill").font(.system(size: 26, weight: .semibold)).foregroundStyle(.white)
            }
            .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 6) {
                Text("Агентов пока нет").font(theme.font(19, .bold)).foregroundStyle(theme.primary)
                Text(note(claude)).font(theme.font(12.5, .medium)).foregroundStyle(theme.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if !claude.isInstalled {
                        AgentButton("Подключить Claude Code", systemImage: "link", style: .ok) { controller.installClaude() }
                    } else if claude.needsReinstall {
                        AgentButton("Переподключить Claude Code", systemImage: "arrow.triangle.2.circlepath", style: .ok) {
                            controller.installClaude()
                        }
                    }
                    if claude.isInstalled {
                        AgentButton(controller.probe == .running ? "Проверяю…" : "Проверить", systemImage: "dot.radiowaves.left.and.right",
                                    style: .plain) { controller.checkHooks() }
                            .help("Отправить тестовое событие тем же путём, что и хук Claude Code, и посмотреть, дошло ли")
                    }
                    switch store.integration.codex {
                    case .notInstalled:
                        AgentButton("Подключить Codex", style: .plain) { controller.installCodex() }
                    case .outdated:
                        AgentButton("Переподключить Codex", style: .plain) { controller.installCodex() }
                    default:
                        EmptyView()
                    }
                }
                .padding(.top, 4)
                if let m = controller.installMessage {
                    Text(m).font(theme.font(11, .medium)).foregroundStyle(theme.tertiary).lineLimit(1)
                }
                HookCheckLine(controller: controller, store: store)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: AgentsLayout.emptyHeight - 10, alignment: .leading)
    }

    private func note(_ s: Installer.Status) -> String {
        switch s {
        case .installed: return "Хуки на месте. Запусти claude в терминале — сессия, вопросы и разрешения появятся здесь."
        case .outdated: return "Хуки стоят старого вида или не все — переподключи."
        case .otherPath: return "Хуки ведут к SimpleIsland по другому пути — переподключи к этой копии."
        case .unavailable(let why): return why
        case .notInstalled:
            return "Подключи Claude Code: сессии, статусы и запросы разрешений будут здесь, отвечать — не переключаясь."
        }
    }
}

/// Строка проверки подключения: статус по ~/.claude/settings.json, последнее событие от хука, итог «Проверить».
struct HookCheckLine: View {
    @ObservedObject var controller: AgentsController
    @ObservedObject var store: AgentsStore
    @ObservedObject private var clock = AgentsClock.shared
    @Environment(\.islandTheme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        let now = isSnapshot ? Date() : clock.now
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                StatusDot(color, size: 6)
                Text(HookCheckText.status(store.integration.claude)).foregroundStyle(theme.secondary)
                    .truncationMode(.middle).layoutPriority(1)
                if let last = store.lastHookEventAt[.claude] {
                    Text("· событие \(Elapsed.ago(now.timeIntervalSince(last)))").foregroundStyle(theme.tertiary)
                } else if store.integration.claude.isInstalled, !isOtherPath {
                    // При «другом пути» строка занята путём, а событий нет как раз из-за него — не дописываем.
                    Text("· событий от хука ещё не было").foregroundStyle(theme.tertiary)
                }
            }
            // Итог «Проверить» — отдельной строкой, чтобы причина читалась целиком.
            if let p = HookCheckText.probe(controller.probe) {
                Text(p).foregroundStyle(probeColor).padding(.leading, 12)
            }
        }
        .font(theme.font(11, .semibold))
        .lineLimit(1)
    }

    private var isOtherPath: Bool {
        if case .otherPath = store.integration.claude { return true }
        return false
    }

    private var color: Color {
        switch store.integration.claude {
        case .installed: return IslandPalette.ok
        case .outdated, .otherPath: return IslandPalette.warn
        default: return theme.tertiary
        }
    }

    private var probeColor: Color {
        switch controller.probe {
        case .ok: return AgentColors.ok(theme)
        case .failed: return AgentColors.err(theme)
        default: return theme.tertiary
        }
    }
}

/// Тексты проверки подключения (остров и окно настроек).
enum HookCheckText {
    static func status(_ s: Installer.Status) -> String {
        switch s {
        case .installed: return "подключено"
        case .outdated: return "устарело — переподключи"
        case .otherPath(let p): return "приложение по другому пути: " + shortPath(p)
        case .notInstalled: return "не подключено"
        case .unavailable(let why): return why
        }
    }

    static func probe(_ p: HookProbe) -> String? {
        switch p {
        case .idle: return nil
        case .running: return "проверяю…"
        case .ok(let ms, _): return "дошло за \(ms) мс"
        case .failed(let why): return "не дошло: " + why
        }
    }

    /// `/Applications/SimpleIsland.app/Contents/MacOS/SimpleIsland` → `/Applications/SimpleIsland.app`, `~` вместо дома.
    static func shortPath(_ p: String) -> String {
        var s = p
        if let r = s.range(of: ".app/Contents/MacOS/") { s = String(s[..<r.lowerBound]) + ".app" }
        let home = NSHomeDirectory()
        if s.hasPrefix(home + "/") { s = "~" + s.dropFirst(home.count) }
        return s
    }
}

/// Сводка в правом верху раскрытой вкладки (макет 05): «2 работают  1 ждёт». Ухо делят кнопки ядра (и
/// «Добавить виджет» ветки catalog): не влезает полная — короткая «● 2  ● 1» (точки цвета статуса), не влезает и
/// она — сжимается до 0,8. Ядро ставит сводку с приоритетом раскладки 1 — не больше места, чем оставили кнопки.
struct AgentsHeaderSummary: View {
    @ObservedObject var store: AgentsStore
    @Environment(\.islandTheme) private var theme

    var body: some View {
        let w = store.workingCount, q = store.waitingCount
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                if w > 0 {
                    Text("\(w) " + plural(w, "работает", "работают", "работают")).foregroundStyle(AgentColors.ok(theme))
                }
                if q > 0 { Text("\(q) ждёт").foregroundStyle(AgentColors.warm(theme)) }
                if w == 0 && q == 0 && !store.sessions.isEmpty {
                    Text("все свободны").foregroundStyle(theme.tertiary)
                }
            }
            .fixedSize()
            HStack(spacing: 10) {
                if w > 0 { HStack(spacing: 5) { StatusDot(AgentColors.ok(theme)); Text("\(w)").foregroundStyle(AgentColors.ok(theme)) } }
                if q > 0 { HStack(spacing: 5) { StatusDot(AgentColors.warm(theme)); Text("\(q)").foregroundStyle(AgentColors.warm(theme)) } }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
        .font(theme.font(12.5, .bold))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(w, q))
    }

    private func accessibilityText(_ w: Int, _ q: Int) -> String {
        var parts: [String] = []
        if w > 0 { parts.append("\(w) " + plural(w, "работает", "работают", "работают")) }
        if q > 0 { parts.append("\(q) ждёт") }
        if parts.isEmpty && !store.sessions.isEmpty { parts.append("все свободны") }
        return "Агенты: " + (parts.isEmpty ? "нет сессий" : parts.joined(separator: ", "))
    }
}

struct ProblemBanner: View {
    var text: String
    var button: String?
    var action: () -> Void
    /// «×» — убрать плашку (напр. право уже выдано, а удачного прыжка ещё не было).
    var onClose: (() -> Void)? = nil
    @Environment(\.islandTheme) private var theme
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(AgentColors.warm(theme))
            Text(text).font(theme.font(12, .semibold)).foregroundStyle(theme.secondary).lineLimit(1)
            Spacer(minLength: 0)
            if let button { AgentButton(button, style: .plain, height: 24, action: action) }
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(theme.tertiary)
                        .frame(width: 22, height: 22).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Скрыть")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: AgentsLayout.bannerHeight)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(IslandPalette.warn.opacity(0.1)))
    }
}

// MARK: - Настройки модуля (окно настроек)

struct AgentsSettingsView: View {
    @ObservedObject var controller: AgentsController
    @ObservedObject var store: AgentsStore
    @ObservedObject private var clock = AgentsClock.shared
    /// Пока вьюха жива — часы тикают (см. `AgentsSettingsPresence`).
    @StateObject private var presence: AgentsSettingsPresence

    init(controller: AgentsController) {
        self.controller = controller
        store = controller.store
        _presence = StateObject(wrappedValue: AgentsSettingsPresence(controller))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            group("Подключение") {
                integrationRow("Claude Code", "~/.claude/settings.json", store.integration.claude,
                               install: controller.installClaude, remove: controller.uninstallClaude)
                integrationRow("Codex", "~/.codex/config.toml (notify)", store.integration.codex,
                               install: controller.installCodex, remove: controller.uninstallCodex)
                if controller.binaryLooksTemporary {
                    Text("SimpleIsland запущен не из .app — путь к хуку: \(AgentsPaths.executablePath). После переноса приложения переподключи.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let m = controller.installMessage { Text(m).font(.caption).foregroundStyle(.secondary) }
                checkRow
                Text("Подключение добавляет только свои записи (помечены #simpleisland) и кладёт рядом резервную копию файла. Чужие хуки не трогаются.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            group("Когда агент ждёт") {
                Toggle("Раскрывать остров на вкладке «Агенты»", isOn: $controller.prefs.autoExpand)
                Toggle("Сразу забирать клавиатуру для ⌘↩ / ⌘⌫ / Esc", isOn: $controller.prefs.grabKeyboard)
                Picker("Звук", selection: $controller.prefs.sound) {
                    ForEach(AgentsPrefs.sounds, id: \.self) { s in Text(AgentsPrefs.soundName(s)).tag(s) }
                }
                .frame(maxWidth: 260)
            }
            group("Список") {
                Stepper("Убирать закрытые сессии через \(controller.prefs.keepMinutes) мин",
                        value: $controller.prefs.keepMinutes, in: 1...120)
            }
            group("Права") {
                Text("Прыжок в нужную вкладку Терминала/iTerm2 по клику на сессию просит «Автоматизацию». Без неё остров просто поднимет приложение-терминал.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Открыть «Автоматизацию»…") { TerminalJumper.openAutomationSettings() }
            }
        }
        .onAppear { controller.refreshIntegration() }
    }

    /// Проверка по факту: последнее событие от хука и «Проверить» (тестовое событие тем же путём, что у хука).
    private var checkRow: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Проверка")
                Text(lastEventText).font(.caption).foregroundStyle(.secondary)
                if let p = HookCheckText.probe(controller.probe) {
                    Text(p).font(.caption).foregroundStyle(probeIsError ? Color.red : .secondary)
                }
            }
            Spacer()
            Button(controller.probe == .running ? "Проверяю…" : "Проверить") { controller.checkHooks() }
                .disabled(controller.probe == .running)
                .help("Отправить тестовое событие тем же бинарём, что прописан в хуках, и посмотреть, дошло ли до острова")
        }
    }

    private var lastEventText: String {
        guard let last = store.lastHookEventAt.values.max() else { return "событий от хуков с запуска SimpleIsland не было" }
        return "последнее событие от хука: " + Elapsed.ago(clock.now.timeIntervalSince(last))
    }

    private var probeIsError: Bool { if case .failed = controller.probe { return true }; return false }

    private func group<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            c()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    private func integrationRow(_ name: String, _ file: String, _ st: Installer.Status,
                                install: @escaping () -> Void, remove: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                Text(statusText(st) + " · " + file).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            switch st {
            case .installed: Button("Отключить", action: remove)
            case .outdated, .otherPath:
                Button("Переподключить", action: install)
                Button("Отключить", action: remove)
            case .notInstalled: Button("Подключить", action: install)
            case .unavailable: EmptyView()
            }
        }
    }

    private func statusText(_ s: Installer.Status) -> String { HookCheckText.status(s) }
}
