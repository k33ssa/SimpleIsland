import Foundation
import IslandCore

/// Раскладка вкладки: что показать и какой высоты. Одна функция и для вьюхи, и для `expandedHeight`,
/// чтобы остров вырастал ровно под diff.
enum AgentsLayout {
    static let rowHeight: CGFloat = 44
    static let spacing: CGFloat = 8
    static let footerHeight: CGFloat = 38
    static let bannerHeight: CGFloat = 34
    static let lineHeight: CGFloat = 18
    static let buttonsHeight: CGFloat = 30
    /// Пусто: значок, текст, кнопки, строка проверки подключения и итог «Проверить».
    static let emptyHeight: CGFloat = 166
    static let maxHeight: CGFloat = 440
    static let moreLineHeight: CGFloat = 16
    /// Шапка карточки запроса: проект, «ждёт 0:41», кнопка «В терминал».
    static let headerHeight: CGFloat = 22
    /// Человеческий заголовок запроса («Изменить MediaViews.swift» + «Подробнее»).
    static let titleHeight: CGFloat = 20
    /// Сырой JSON по «Подробнее»: строка и предел строк.
    static let rawLineHeight: CGFloat = 15
    static let rawMaxLines = 14
    /// Вопрос AskUserQuestion: строка текста вопроса, вариант-кнопка, промежутки.
    static let questionLineHeight: CGFloat = 17
    static let optionHeight: CGFloat = 28
    static let optionSpacing: CGFloat = 5
    static let questionGap: CGFloat = 10
    /// Знаков в строке текста вопроса (13 pt при ширине острова 720) — оценка для высоты.
    static let questionColumns = 70

    static func questionLines(_ q: AgentQuestion) -> Int {
        let n = q.question.count + (q.header?.count ?? 0) + (q.multiSelect ? 16 : 0) + 4
        return min(3, max(1, Int((Double(n) / Double(questionColumns)).rounded(.up))))
    }

    static func questionsHeight(_ qs: [AgentQuestion]) -> CGFloat {
        guard !qs.isEmpty else { return 0 }
        let each = qs.map { q in
            CGFloat(questionLines(q)) * questionLineHeight + CGFloat(q.options.count) * (optionHeight + optionSpacing)
        }
        return each.reduce(0, +) + CGFloat(qs.count - 1) * questionGap
    }

    static func rawLines(_ text: String) -> (shown: [String], hidden: Int) {
        let all = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if all.count <= rawMaxLines { return (all, 0) }
        return (Array(all.prefix(rawMaxLines - 1)), all.count - (rawMaxLines - 1))
    }

    static func rawHeight(_ text: String) -> CGFloat {
        let l = rawLines(text)
        return 6 + CGFloat(l.shown.count + (l.hidden > 0 ? 1 : 0)) * rawLineHeight + 6
    }

    /// Есть ли что показать превью (у вопроса — нет, его рисует `QuestionBox`).
    static func showsPreview(_ p: PermissionPrompt) -> Bool {
        !p.isQuestion && (!p.preview.lines.isEmpty || !p.preview.header.isEmpty)
    }

    struct Plan {
        /// Сессия с карточкой разрешения (первая ждущая с запросом).
        var card: AgentSession?
        var rows: [AgentSession]
        var hidden: Int
        var banners: Int
    }

    @MainActor static func banners(_ store: AgentsStore) -> Int {
        (store.serverProblem != nil ? 1 : 0) + (store.jumpProblem != nil ? 1 : 0)
    }

    static func diffHeight(_ p: ToolPreview) -> CGFloat {
        8 + (p.header.isEmpty ? 0 : lineHeight) + CGFloat(p.lines.count) * lineHeight + (p.hiddenCount > 0 ? lineHeight : 0) + 8
    }

    /// Высота карточки. `rawShown` — раскрыт ли сырой JSON у её запроса.
    static func cardHeight(_ s: AgentSession, rawShown: Bool = false) -> CGFloat {
        guard let p = s.prompts.first else { return rowHeight }
        var h: CGFloat = 12 + headerHeight + 10 + titleHeight + 10 + buttonsHeight + 12
        if p.isQuestion { h += questionsHeight(p.questions) + 10 }
        if rawShown { h += rawHeight(p.rawJSON) + 10 } else if showsPreview(p) { h += diffHeight(p.preview) + 10 }
        if s.prompts.count > 1 { h += 6 + moreLineHeight }
        return h
    }

    @MainActor static func plan(_ store: AgentsStore) -> Plan {
        let all = store.ordered
        let card = store.focusedPromptSession
        let b = banners(store)
        var used = CGFloat(b) * (bannerHeight + spacing) + footerHeight
        if let card { used += cardHeight(card, rawShown: store.rawShownFor == card.prompts.first?.id) + spacing }
        var rows: [AgentSession] = []
        let rest = all.filter { $0.id != card?.id }
        for (i, s) in rest.enumerated() {
            let needsMore = i < rest.count - 1
            let add = rowHeight + spacing + (needsMore ? moreLineHeight + spacing : 0)
            if used + add > maxHeight && !rows.isEmpty { break }
            rows.append(s)
            used += rowHeight + spacing
        }
        return Plan(card: card, rows: rows, hidden: rest.count - rows.count, banners: b)
    }

    @MainActor static func height(store: AgentsStore) -> CGFloat {
        if store.sessions.isEmpty { return emptyHeight + CGFloat(banners(store)) * (bannerHeight + spacing) }
        let p = plan(store)
        var h = CGFloat(p.banners) * (bannerHeight + spacing)
        if let c = p.card { h += cardHeight(c, rawShown: store.rawShownFor == c.prompts.first?.id) + spacing }
        h += CGFloat(p.rows.count) * (rowHeight + spacing)
        if p.hidden > 0 { h += moreLineHeight + spacing }
        h += footerHeight
        return min(maxHeight, ceil(h))
    }
}
