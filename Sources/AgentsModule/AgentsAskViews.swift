import IslandCore
import SwiftUI

// Части карточки запроса: человеческий заголовок, вопрос с вариантами, сырой JSON по «Подробнее»,
// подсветка команды Bash. Высоты — `AgentsLayout` (одна формула для вьюхи и `expandedHeight`).

/// Заголовок запроса: значок категории, «Изменить MediaViews.swift», серым — папка/описание; справа «Подробнее».
struct AskTitleRow: View {
    @ObservedObject var store: AgentsStore
    var prompt: PermissionPrompt
    @Environment(\.islandTheme) private var theme

    var body: some View {
        let a = prompt.presentation
        let raw = store.rawShownFor == prompt.id
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: a.symbol).font(.system(size: 12, weight: .bold)).foregroundStyle(AgentColors.warm(theme))
            Text(a.title).font(theme.font(14, .bold)).foregroundStyle(theme.primary).lineLimit(1).truncationMode(.middle)
                .layoutPriority(1)
            if let sub = a.subtitle {
                Text(sub).font(theme.font(12, .medium)).foregroundStyle(theme.tertiary).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 6)
            Button {
                store.rawShownFor = raw ? nil : prompt.id
            } label: {
                HStack(spacing: 3) {
                    Text(raw ? "Скрыть" : "Подробнее")
                    Image(systemName: raw ? "chevron.up" : "chevron.down").font(.system(size: 8.5, weight: .bold))
                }
                .font(theme.font(11.5, .semibold))
                .foregroundStyle(theme.tertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Сырой запрос агента (JSON)")
            .fixedSize()
        }
        .frame(height: AgentsLayout.titleHeight)
    }
}

/// Сырой JSON запроса — только по «Подробнее».
struct RawBox: View {
    var text: String
    @Environment(\.islandTheme) private var theme

    var body: some View {
        let lines = AgentsLayout.rawLines(text)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.shown.enumerated()), id: \.offset) { _, l in
                Text(l.isEmpty ? " " : l)
                    .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(theme.secondary.opacity(0.8))
                    .lineLimit(1).truncationMode(.tail)
                    .frame(height: AgentsLayout.rawLineHeight, alignment: .leading)
            }
            if lines.hidden > 0 {
                Text("… ещё \(lines.hidden) " + plural(lines.hidden, "строка", "строки", "строк"))
                    .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(theme.tertiary)
                    .frame(height: AgentsLayout.rawLineHeight, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AgentColors.diffBackground(theme)))
        .help(ToolPreview.clip(text, 4000))
    }
}

/// Вопрос AskUserQuestion: текст вопроса, короткий заголовок-метка и варианты кнопками.
/// Один вопрос без мультивыбора — щелчок по варианту сразу отвечает; иначе — отметить и «Ответить».
struct QuestionBox: View {
    @ObservedObject var store: AgentsStore
    var prompt: PermissionPrompt
    @Environment(\.islandTheme) private var theme

    var body: some View {
        let qs = prompt.questions
        VStack(alignment: .leading, spacing: AgentsLayout.questionGap) {
            ForEach(Array(qs.enumerated()), id: \.offset) { i, q in
                VStack(alignment: .leading, spacing: AgentsLayout.optionSpacing) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if qs.count > 1 { Text("\(i + 1).").foregroundStyle(theme.tertiary) }
                        if let h = q.header {
                            Text(h.uppercased()).font(theme.font(10, .bold)).foregroundStyle(AgentColors.warm(theme))
                                .padding(.horizontal, 6).padding(.vertical, 1.5)
                                .background(Capsule().fill(IslandPalette.warn.opacity(theme.isLight ? 0.16 : 0.14)))
                                .fixedSize()
                        }
                        Text(q.question).foregroundStyle(theme.primary)
                            .lineLimit(AgentsLayout.questionLines(q)).fixedSize(horizontal: false, vertical: true)
                        if q.multiSelect { Text("можно несколько").foregroundStyle(theme.tertiary).fixedSize() }
                    }
                    .font(theme.font(13, .semibold))
                    .frame(height: CGFloat(AgentsLayout.questionLines(q)) * AgentsLayout.questionLineHeight, alignment: .topLeading)
                    ForEach(Array(q.options.enumerated()), id: \.offset) { n, o in
                        option(o, number: qs.count == 1 ? n + 1 : nil, q: q)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func option(_ o: AgentQuestion.Option, number: Int?, q: AgentQuestion) -> some View {
        let picked = (store.questionPicks[q.question] ?? []).contains(o.label)
        let instant = prompt.questions.count == 1 && !q.multiSelect
        return Button {
            store.pick(o.label, in: q, of: prompt)
        } label: {
            HStack(spacing: 8) {
                if instant {
                    Text(number.map(String.init) ?? "•").font(theme.font(11, .bold)).foregroundStyle(theme.tertiary)
                        .frame(width: 14)
                } else {
                    Image(systemName: q.multiSelect ? (picked ? "checkmark.square.fill" : "square")
                                                    : (picked ? "largecircle.fill.circle" : "circle"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(picked ? IslandPalette.ok : theme.tertiary)
                        .frame(width: 14)
                }
                Text(o.label).font(theme.font(12.5, .bold)).foregroundStyle(theme.primary).lineLimit(1).layoutPriority(1)
                if let d = o.description {
                    Text(d).font(theme.font(12, .medium)).foregroundStyle(theme.tertiary).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 0)
                if instant {
                    Image(systemName: "arrow.turn.down.left").font(.system(size: 10, weight: .bold)).foregroundStyle(theme.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: AgentsLayout.optionHeight)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(picked ? IslandPalette.ok.opacity(theme.isLight ? 0.16 : 0.14) : theme.controlFillColor))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
        .keyboardShortcut(instant && (number ?? 0) <= 9 ? KeyboardShortcut(KeyEquivalent(Character(String(number ?? 0))), modifiers: .command) : nil)
        .help((o.description ?? o.label) + (instant && (number ?? 0) <= 9 ? " (⌘\(number ?? 0))" : ""))
    }
}

/// Подсветка команды Bash: программа — акцентом, флаги — приглушённо, строки в кавычках — тёплым, связки
/// (`&&`, `|`, `;`) — серым, опасное (`rm -rf`, `sudo`, `| sh`, `curl`/`wget` в трубе) — красным.
enum BashHighlight {
    enum Role: Equatable { case program, flag, string, op, danger, plain, prompt }
    struct Token: Equatable {
        var text: String
        var role: Role
    }

    static let operators: Set<String> = ["&&", "||", "|", ";", "&", ">", ">>", "<", "2>", "2>&1", "|&"]
    static let dangerous: Set<String> = ["rm", "sudo", "dd", "mkfs", "chmod", "chown", "shutdown", "reboot", "kill", "killall",
                                         "launchctl", "diskutil", "defaults", "osascript"]
    static let shells: Set<String> = ["sh", "bash", "zsh", "python", "python3", "perl", "ruby", "node"]

    /// Разбить строку превью (`$ …` или продолжение `  …`) на куски с ролями. Пробелы сохраняются в токенах.
    static func tokens(_ line: String) -> [Token] {
        var out: [Token] = []
        var rest = Substring(line)
        var expectProgram = false
        var afterPipe = false
        if rest.hasPrefix("$ ") { out.append(Token(text: "$ ", role: .prompt)); rest = rest.dropFirst(2); expectProgram = true }
        while !rest.isEmpty {
            // Пробелы — как есть.
            let spaces = rest.prefix { $0 == " " }
            if !spaces.isEmpty { out.append(Token(text: String(spaces), role: .plain)); rest = rest.dropFirst(spaces.count); continue }
            var word: Substring
            if let q = rest.first, q == "\"" || q == "'" {
                // Строка в кавычках — до парной кавычки (или до конца строки превью).
                let body = rest.dropFirst()
                if let end = body.firstIndex(of: q) { word = rest[rest.startIndex...end] } else { word = rest }
            } else {
                word = rest.prefix { $0 != " " }
            }
            rest = rest.dropFirst(word.count)
            let w = String(word)
            let role: Role
            if operators.contains(w) {
                role = .op
                expectProgram = true
                afterPipe = w == "|" || w == "|&"
            } else if w.hasPrefix("\"") || w.hasPrefix("'") {
                role = .string
            } else if expectProgram, !w.contains("=") || w.hasPrefix("-") {
                let name = (w as NSString).lastPathComponent
                role = dangerous.contains(name) || (afterPipe && shells.contains(name)) ? .danger : .program
                expectProgram = false
                afterPipe = false
            } else if w == "-rf" || w == "-fr" || w == "--force" || w == "--hard" {
                role = .danger
            } else if w.hasPrefix("-") {
                role = .flag
            } else {
                role = .plain
            }
            out.append(Token(text: w, role: role))
        }
        return out
    }

    static func text(_ line: String, theme: Theme) -> Text {
        tokens(line).reduce(Text("")) { acc, t in
            let c: Color
            switch t.role {
            case .program: c = theme.accentColor
            case .flag: c = theme.secondary
            case .string: c = AgentColors.warm(theme)
            case .op, .prompt: c = theme.tertiary
            case .danger: c = AgentColors.err(theme)
            case .plain: c = theme.primary
            }
            let piece = Text(t.text).foregroundStyle(c)
            return acc + (t.role == .program || t.role == .danger ? piece.bold() : piece)
        }
    }
}
