import AppKit
import IslandCore

/// Раскладка вкладок верхней строки раскрытого острова. Центр строки (вырез + отступы) не занимается никогда.
/// С 16.11 у каждой вкладки своя сторона (`TabSetting.side`, «Раскладка» в настройках):
/// 1. вкладки левой стороны — слева от выреза, правой — справа, перед «+» и настройками;
/// 2. в свою сторону не влезли — последние уходят в меню «⋯» (в конце правой стороны), на чужую сторону не
///    перескакивают; выбранная всегда остаётся на виду (на своей стороне, вытесняя соседей в «⋯»);
/// 3. без выреза (капля) — обе группы подряд слева, между ними разделитель; «⋯» — справа, как с вырезом.
/// Подпись выбранной: полное имя → сокращение («Экв.») → только значок, — берётся первая, при которой влезает
/// больше вкладок без «⋯». Чистая функция — `--selftest-core tabs`.
enum TabBarLayout {
    struct Plan: Equatable {
        var left: [String]
        var right: [String]
        var overflow: [String]
        /// Какая подпись у выбранной поместилась: 0 — полное имя, 1 — сокращение, 2 — только значок.
        var selectedVariant: Int
        /// Без выреза: `left` и `right` стоят подряд слева, между ними разделитель (если обе непусты).
        var inline = false
    }

    static let iconWidth: CGFloat = Pill.height
    static let spacing: CGFloat = 4
    static let moreWidth: CGFloat = Pill.height
    /// Разделитель групп без выреза: черта 1 pt и по зазору `spacing` с каждой стороны (один зазор — уже у ряда).
    static let dividerWidth: CGFloat = 1 + spacing

    /// Отступ строки от края острова и служебные кнопки справа — как в `IslandView.ExpandedContent`.
    static let edgePadding: CGFloat = 22
    static let trailingButtonsWidth: CGFloat = 24 + 10 + 24

    /// Сколько pt под вкладки слева от выреза и справа (до «+» и настроек) при ширине острова `width` и вырезе `gap`.
    static func capacities(width: CGFloat, gap: CGFloat) -> (left: CGFloat, right: CGFloat) {
        let side = max(0, (width - gap) / 2)
        let sideWidth = max(0, side - edgePadding - 8)
        return (sideWidth, max(0, sideWidth - trailingButtonsWidth - 10))
    }

    /// Влезет ли слева ещё одна вкладка, когда там уже `count` включённых (каталог: «новый — в конец левой, если
    /// есть место»). Одна из вкладок считается выбранной с короткой подписью (~60 pt).
    static func leftHasRoom(count: Int, width: CGFloat, gap: CGFloat) -> Bool {
        let cap = capacities(width: width, gap: gap).left
        let n = count + 1
        return 60 + CGFloat(n - 1) * iconWidth + spacing * CGFloat(n - 1) <= cap + 0.5
    }

    /// Прежняя раскладка (до 16.11, без сторон): сколько вкладок по порядку стояло слева от выреза, остальные
    /// уезжали направо. Выбранная — первая (так остров открывается по умолчанию), вариант подписи — первый, при
    /// котором всё влезает без «⋯», иначе — с наименьшим «⋯». Для миграции старого settings.json.
    static func legacyLeftCount(ids: [String], selectedWidths: [CGFloat], left: CGFloat, right: CGFloat) -> Int {
        guard let sel = ids.first else { return 0 }
        var best: (count: Int, overflow: Int)?
        for sw in selectedWidths {
            let r = Row(selected: sel, selectedWidth: sw)
            let l = r.greedy(ids, capacity: left)
            let rr = r.greedy(l.rest, capacity: right)
            if rr.rest.isEmpty { return l.taken.count }
            let over = r.greedy(l.rest, capacity: max(0, right - moreWidth - spacing)).rest.count
            if best == nil || over < best!.overflow { best = (l.taken.count, over) }
        }
        return best?.count ?? ids.count
    }

    /// Ширина выбранной вкладки с подписью `title` (значок 12 pt + 5 + текст + отступы `Pill.inset`).
    @MainActor static func labeledWidth(_ title: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        let text = ceil((title as NSString).size(withAttributes: [.font: font]).width)
        return Pill.inset * 2 + 14 + 5 + text + 2   // +2 — запас на шрифт темы (Inter, моно) шире системного
    }

    /// Варианты ширины выбранной по убыванию.
    @MainActor static func selectedWidths(title: String) -> [CGFloat] {
        let short = Pill.abbreviation(title)
        var w = [labeledWidth(title)]
        if short != title { w.append(labeledWidth(short)) } else { w.append(w[0]) }
        w.append(iconWidth)
        return w
    }

    /// `leftIds`/`rightIds` — вкладки сторон по порядку; `left`/`right` — сколько pt доступно под вкладки слева от
    /// выреза и справа (до служебных кнопок). `inline` — экран без выреза: обе группы в `left` pt подряд.
    static func plan(leftIds: [String], rightIds: [String], selected: String?, selectedWidths: [CGFloat],
                     left: CGFloat, right: CGFloat, inline: Bool = false) -> Plan {
        var best: Plan?
        for (variant, sw) in selectedWidths.enumerated() {
            let p = inline
                ? fillInline(leftIds, rightIds, selected: selected, selectedWidth: sw, capacity: left, variant: variant)
                : fill(leftIds, rightIds, selected: selected, selectedWidth: sw, left: left, right: right, variant: variant)
            if p.overflow.isEmpty { return p }
            if best == nil || p.overflow.count < best!.overflow.count { best = p }
        }
        return best ?? fill(leftIds, rightIds, selected: selected, selectedWidth: iconWidth, left: left, right: right,
                            variant: 2)
    }

    // MARK: Внутреннее

    private struct Row {
        let selected: String?
        let selectedWidth: CGFloat
        func width(_ id: String) -> CGFloat { id == selected ? selectedWidth : iconWidth }
        func width(_ row: [String]) -> CGFloat {
            row.isEmpty ? 0 : row.map(width).reduce(0, +) + spacing * CGFloat(row.count - 1)
        }
        func greedy(_ items: [String], capacity: CGFloat) -> (taken: [String], rest: [String]) {
            var taken: [String] = []
            var i = 0
            while i < items.count, width(taken + [items[i]]) <= capacity + 0.5 { taken.append(items[i]); i += 1 }
            return (taken, Array(items[i...]))
        }
        /// Выбранная ушла в «⋯» — встаёт последней видимой, вытесняя соседей в меню, пока не влезет.
        func keepSelected(_ row: inout [String], _ overflow: inout [String], capacity: CGFloat,
                          extra: (([String]) -> CGFloat)? = nil) {
            guard let sel = selected, let k = overflow.firstIndex(of: sel) else { return }
            overflow.remove(at: k)
            func w(_ r: [String]) -> CGFloat { width(r) + (extra?(r) ?? 0) }
            while true {
                if w(row + [sel]) <= capacity + 0.5 { row.append(sel); return }
                if let last = row.popLast() { overflow.insert(last, at: 0); continue }
                row.append(sel); return   // не влезает и одна — всё равно на виду
            }
        }
    }

    private static func ordered(_ ids: [String], by order: [String]) -> [String] {
        ids.sorted { (order.firstIndex(of: $0) ?? 0) < (order.firstIndex(of: $1) ?? 0) }
    }

    private static func fill(_ leftIds: [String], _ rightIds: [String], selected: String?, selectedWidth: CGFloat,
                             left: CGFloat, right: CGFloat, variant: Int) -> Plan {
        let r = Row(selected: selected, selectedWidth: selectedWidth)
        let l = r.greedy(leftIds, capacity: left)
        let rr = r.greedy(rightIds, capacity: right)
        if l.rest.isEmpty && rr.rest.isEmpty {
            return Plan(left: l.taken, right: rr.taken, overflow: [], selectedVariant: variant)
        }
        // Есть лишние — «⋯» в конце правой стороны отнимает у неё место.
        let rightCap = max(0, right - moreWidth - spacing)
        var (leftRow, leftOver) = l
        var (rightRow, rightOver) = r.greedy(rightIds, capacity: rightCap)
        r.keepSelected(&leftRow, &leftOver, capacity: left)
        r.keepSelected(&rightRow, &rightOver, capacity: rightCap)
        return Plan(left: leftRow, right: rightRow, overflow: ordered(leftOver, by: leftIds) + ordered(rightOver, by: rightIds),
                    selectedVariant: variant)
    }

    /// Без выреза: [левые] | [правые] в одном ряду шириной `capacity`; лишние — с конца, в «⋯».
    private static func fillInline(_ leftIds: [String], _ rightIds: [String], selected: String?, selectedWidth: CGFloat,
                                   capacity: CGFloat, variant: Int) -> Plan {
        let r = Row(selected: selected, selectedWidth: selectedWidth)
        let all = leftIds + rightIds
        let leftSet = Set(leftIds)
        // Разделитель — когда в ряду есть обе группы.
        func extra(_ row: [String]) -> CGFloat {
            row.contains(where: leftSet.contains) && row.contains(where: { !leftSet.contains($0) }) ? dividerWidth : 0
        }
        var row: [String] = []
        var i = 0
        while i < all.count, r.width(row + [all[i]]) + extra(row + [all[i]]) <= capacity + 0.5 { row.append(all[i]); i += 1 }
        var overflow = Array(all[i...])
        r.keepSelected(&row, &overflow, capacity: capacity, extra: extra)
        // Выбранная могла встать последней в ряд, хотя она из левой группы, — порядок групп сохраняем.
        let visibleLeft = leftIds.filter { row.contains($0) }
        let visibleRight = rightIds.filter { row.contains($0) }
        return Plan(left: visibleLeft, right: visibleRight, overflow: ordered(overflow, by: all), selectedVariant: variant,
                    inline: true)
    }
}
