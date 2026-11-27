import Foundation
import SwiftUI

// MARK: - Живые активности

/// Живая активность в компактном острове: что показывать в левом и правом «ушах» по бокам выреза.
/// Самая важная (priority) — в ушах острова; вторая, если несёт информацию (priority > 0), — маленьким значком
/// внутри правого уха (за остров ничего не выносится, UX 15.11).
public struct IslandActivity: Identifiable {
    public var id: String
    public var moduleId: String
    /// Выше — важнее. Ориентиры: 0 — фон (музыка), 50 — таймер/загрузка, 100 — агент ждёт ответа.
    public var priority: Int
    /// Ширина каждого «уха» в pt (сколько места занимает контент слева и справа от выреза).
    public var sideWidth: CGFloat
    public var leading: AnyView
    public var trailing: AnyView
    /// Что рисовать в значке второй активности (кружок 18 pt в правом ухе). nil → значок модуля.
    public var bubble: AnyView?
    /// Цвета свечения под островом (тема с glow.source = artwork). Напр. цвета обложки.
    public var glowColors: [Color]?
    /// Когда активность сама исчезнет. nil — пока модуль не уберёт.
    public var expiresAt: Date?
    /// Какую вкладку открыть по клику на остров. nil → вкладка модуля.
    public var opensTab: String?
    /// Что озвучит VoiceOver про компакт («Играет: Исполнитель — Трек»). nil — имя вкладки модуля.
    /// Задать: `IslandActivity(…).accessibility("Играет: …")`.
    public var accessibilityLabel: String?

    public init<L: View, T: View>(id: String, moduleId: String, priority: Int = 0, sideWidth: CGFloat = 56,
                                  glowColors: [Color]? = nil,
                                  expiresAt: Date? = nil, opensTab: String? = nil,
                                  bubble: AnyView? = nil,
                                  @ViewBuilder leading: () -> L, @ViewBuilder trailing: () -> T) {
        self.id = id; self.moduleId = moduleId; self.priority = priority; self.sideWidth = sideWidth
        self.leading = AnyView(leading()); self.trailing = AnyView(trailing()); self.bubble = bubble
        self.glowColors = glowColors; self.expiresAt = expiresAt; self.opensTab = opensTab
    }
}

public extension IslandActivity {
    /// Подпись для VoiceOver (цепочкой после init).
    func accessibility(_ label: String) -> IslandActivity { var c = self; c.accessibilityLabel = label; return c }
}

/// «Живая точка» покоя одного модуля.
public struct StatusDotState: Equatable {
    public var color: Color
    /// Выше — важнее: в покое видна одна точка — с наибольшим приоритетом (при равенстве — более свежая).
    /// Ориентиры: 0 — «работает» (зелёная), 50 — «ждёт тебя» (жёлтая), 100 — ошибка (красная).
    public var priority: Int
    var seq: Int
}

/// Событие, о котором стоит сказать даже в полноэкранном (остров спрятан): точка у выреза (`FullscreenBeacon`).
/// Цвет — тот же, что у живой точки покоя (`IslandPalette`), чтобы «жёлтый — ждёт» значил одно и то же везде.
public enum AttentionKind: Int, Comparable, Sendable, CaseIterable {
    /// Агент закончил ход — зелёная.
    case done = 0
    /// Входящее важное уведомление (по политике: с действием) — синяя.
    case info = 1
    /// Ошибка: агент упал, Vafa сработала — красная.
    case error = 2
    /// Агент спрашивает / ждёт разрешения — оранжевая (жёлтая).
    case ask = 3

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public var color: Color {
        switch self {
        case .done: return IslandPalette.ok
        case .info: return IslandPalette.blue
        case .error: return IslandPalette.err
        case .ask: return IslandPalette.warn
        }
    }

    /// «Новость», а не состояние: гаснет, когда её увидели, и не тянется в полноэкранный из прошлого.
    public var isNews: Bool { self == .done || self == .info }

    public var spokenName: String {
        switch self {
        case .done: return "готово"
        case .info: return "новое уведомление"
        case .error: return "ошибка"
        case .ask: return "ждёт ответа"
        }
    }
}

/// Одно событие внимания модуля.
public struct AttentionState: Equatable {
    public var kind: AttentionKind
    /// Что сказать подсказкой у точки: «Агент ждёт ответа · SimpleIsland».
    public var text: String
    /// Какую вкладку открыть по клику (nil — вкладка модуля).
    public var opensTab: String?
    public var seq: Int
    public init(kind: AttentionKind, text: String, opensTab: String? = nil, seq: Int = 0) {
        self.kind = kind; self.text = text; self.opensTab = opensTab; self.seq = seq
    }
}

@MainActor
public final class ActivityCenter: ObservableObject {
    @Published public private(set) var activities: [IslandActivity] = []
    /// «Живые точки» покоя: moduleId → точка. В покое показывается одна — самая важная (`idleDot`).
    @Published public private(set) var statusDots: [String: StatusDotState] = [:]
    /// Свечение, которое модули задают без активности (напр. цвет обложки в раскрытом плеере): moduleId → цвета.
    @Published public private(set) var ambientGlows: [String: [Color]] = [:]
    // --- media2 ---
    /// Цвета обложки играющего (для темы с `background.source = artwork`, «Хамелеон») — отдельный канал, не
    /// свечение: свечение задают и другие модули (полка, агенты), а фон должен краситься только обложкой.
    /// Последний задавший модуль — `artworkOwner`; nil — обложки нет.
    @Published public private(set) var artworkColors: [Color]?
    public private(set) var artworkOwner: String?
    // --- /media2 ---
    /// Активность, которую пользователь поднял кликом по значку второй активности.
    @Published public private(set) var pinnedPrimaryId: String?

    /// События внимания: moduleId → событие. В полноэкранном — точка у выреза (одна, самая важная).
    @Published public private(set) var attention: [String: AttentionState] = [:]

    private var order: [String: Int] = [:]
    private var seq = 0
    private var dotSeq = 0
    private var attentionSeq = 0
    private var expiryWork: DispatchWorkItem?

    public init() {}

    /// Добавить или обновить (по id).
    public func post(_ activity: IslandActivity) {
        if let i = activities.firstIndex(where: { $0.id == activity.id }) {
            activities[i] = activity
        } else {
            seq += 1; order[activity.id] = seq
            activities.append(activity)
        }
        scheduleExpiry()
    }

    public func remove(id: String) {
        activities.removeAll { $0.id == id }
        order[id] = nil
        if pinnedPrimaryId == id { pinnedPrimaryId = nil }
        scheduleExpiry()
    }

    /// Убрать всё модуля: активности, точку, свечение.
    public func removeAll(moduleId: String) {
        for a in activities where a.moduleId == moduleId { remove(id: a.id) }
        statusDots[moduleId] = nil
        ambientGlows[moduleId] = nil
        attention[moduleId] = nil
        if artworkOwner == moduleId { setArtworkColors(nil, for: moduleId) }   // --- media2 ---
    }

    // --- media2 ---
    /// Цвета обложки (`artworkColors`). nil/пусто — снять (только своё: чужие цвета модуль не снимает).
    public func setArtworkColors(_ colors: [Color]?, for moduleId: String) {
        let v = (colors?.isEmpty ?? true) ? nil : colors
        if v == nil, let owner = artworkOwner, owner != moduleId { return }
        artworkOwner = v == nil ? nil : moduleId
        guard artworkColors != v else { return }   // без публикации того же (E4)
        artworkColors = v
    }
    // --- /media2 ---

    public func setStatusDot(_ color: Color?, priority: Int = 0, for moduleId: String) {
        guard let color else { statusDots[moduleId] = nil; return }
        if let cur = statusDots[moduleId], cur.color == color, cur.priority == priority { return }
        dotSeq += 1
        statusDots[moduleId] = StatusDotState(color: color, priority: priority, seq: dotSeq)
    }

    // MARK: Внимание (точка у выреза в полноэкранном)

    /// Поставить/снять событие модуля. То же самое ещё раз — без публикации (и без новой пульсации).
    public func setAttention(_ kind: AttentionKind?, text: String = "", opensTab: String? = nil, for moduleId: String) {
        guard let kind else { if attention[moduleId] != nil { attention[moduleId] = nil }; return }
        if let cur = attention[moduleId], cur.kind == kind, cur.text == text, cur.opensTab == opensTab { return }
        attentionSeq += 1
        attention[moduleId] = AttentionState(kind: kind, text: text, opensTab: opensTab, seq: attentionSeq)
    }

    /// Самое важное событие: вид (ask > error > info > done), при равенстве — более свежее.
    public var topAttention: (moduleId: String, state: AttentionState)? {
        attention.max { a, b in a.value.kind != b.value.kind ? a.value.kind < b.value.kind : a.value.seq < b.value.seq }
            .map { ($0.key, $0.value) }
    }

    /// Пользователь увидел событие модуля (клик по точке, открыл его вкладку) — погасить.
    public func acknowledgeAttention(moduleId: String) {
        if attention[moduleId] != nil { attention[moduleId] = nil }
    }

    /// Вход в полноэкранный: «новости» (готово, уведомление), случившиеся до него, не показывать — их видели
    /// на обычном столе или они уже не новость. Состояния (ждёт, ошибка) остаются.
    public func dropAttentionNews() {
        let left = attention.filter { !$0.value.kind.isNews }
        if left.count != attention.count { attention = left }
    }

    public func setAmbientGlow(_ colors: [Color]?, for moduleId: String) {
        let v = (colors?.isEmpty ?? true) ? nil : colors
        // Без публикации, если не поменялось: модуль может звать это на каждое обновление трека (грабли E4).
        guard ambientGlows[moduleId] != v else { return }
        ambientGlows[moduleId] = v
    }

    /// Отсортированные: закреплённая кликом → приоритет → порядок появления.
    public var sorted: [IslandActivity] {
        activities.sorted { a, b in
            if a.id == pinnedPrimaryId { return true }
            if b.id == pinnedPrimaryId { return false }
            if a.priority != b.priority { return a.priority > b.priority }
            return (order[a.id] ?? 0) < (order[b.id] ?? 0)
        }
    }
    public var primary: IslandActivity? { sorted.first }
    public var secondary: IslandActivity? { let s = sorted; return s.count > 1 ? s[1] : nil }

    /// Вторая становится главной (клик по её значку).
    public func swapPrimary() {
        guard let s = secondary else { return }
        pinnedPrimaryId = s.id
    }

    // --- settings: клик по значку при назначенных ушах поднимает ту активность, что в нём
    /// Закрепить главной активность `id` (nil — снять закрепление). Неизвестный id — ничего не делает.
    public func pin(id: String?) {
        guard id == nil || activities.contains(where: { $0.id == id }) else { return }
        if pinnedPrimaryId != id { pinnedPrimaryId = id }
    }

    /// Цвет точки покоя: точка с наибольшим приоритетом, при равенстве — самая свежая.
    public var idleDot: Color? {
        statusDots.values.max { a, b in a.priority != b.priority ? a.priority < b.priority : a.seq < b.seq }?.color
    }

    /// Цвета свечения. Раскрытый остров (`tab` — открытая вкладка): свечение модуля вкладки → главной активности.
    /// Компакт (`tab == nil`): главная активность → свечение её модуля.
    public func glow(tab: String?) -> [Color]? {
        if let tab { return ambientGlows[tab] ?? primary?.glowColors }
        guard let p = primary else { return nil }
        return p.glowColors ?? ambientGlows[p.moduleId]
    }

    /// Один таймер на ближайшее истечение — никакого опроса.
    private func scheduleExpiry() {
        expiryWork?.cancel()
        guard let next = activities.compactMap(\.expiresAt).min() else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = Date()
                for a in self.activities where (a.expiresAt ?? .distantFuture) <= now { self.remove(id: a.id) }
                self.scheduleExpiry()
            }
        }
        expiryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.05, next.timeIntervalSinceNow), execute: work)
    }
}

// MARK: - HUD-вспышки

/// Короткая вспышка по бокам выреза: громкость, яркость, подсветка, зарядка, раскладка…
public struct HUDEvent: Identifiable {
    public var id = UUID()
    /// Вид события: "volume", "brightness", "keyboard", "battery", "layout", … Повтор того же вида
    /// обновляет вспышку, а не ставит новую.
    public var kind: String
    public var systemImage: String?
    /// Подпись слева (напр. "AirPods Pro", "авто").
    public var label: String?
    /// Значение 0…1 для полосы. nil — без полосы (только текст).
    public var value: Double?
    /// Текст справа вместо числа (напр. "78% · 34 мин", "RU").
    public var valueText: String?
    public var tint: Color?
    /// nil — стиль из настроек.
    public var style: HUDBarStyle?
    public var segments: Int
    /// Ширина каждого «уха» в pt.
    public var sideWidth: CGFloat
    /// Свой вид (полностью заменяет стандартную раскладку). Слева и справа от выреза.
    public var customLeading: AnyView?
    public var customTrailing: AnyView?
    /// Что озвучит VoiceOver. nil — собирается из вида, подписи и значения («Громкость, AirPods Pro, 62 %»).
    public var accessibilityLabel: String?

    public init(kind: String, systemImage: String? = nil, label: String? = nil, value: Double? = nil,
                valueText: String? = nil, tint: Color? = nil, style: HUDBarStyle? = nil,
                segments: Int = 16, sideWidth: CGFloat = 120,
                customLeading: AnyView? = nil, customTrailing: AnyView? = nil) {
        self.kind = kind; self.systemImage = systemImage; self.label = label; self.value = value
        self.valueText = valueText; self.tint = tint; self.style = style; self.segments = segments
        self.sideWidth = sideWidth; self.customLeading = customLeading; self.customTrailing = customTrailing
    }
}

public extension HUDEvent {
    /// Озвучка вспышки для VoiceOver.
    var spokenDescription: String {
        if let accessibilityLabel { return accessibilityLabel }
        let names = ["volume": "Громкость", "brightness": "Яркость", "keyboard": "Подсветка клавиатуры",
                     "battery": "Батарея", "layout": "Раскладка", "mute": "Звук выключен"]
        var parts = [names[kind] ?? kind]
        if let label { parts.append(label) }
        if let valueText { parts.append(valueText) } else if let value { parts.append("\(Int((value * 100).rounded())) %") }
        return parts.joined(separator: ", ")
    }
}

public extension HUDEvent {
    /// Несёт ли вспышка информацию: подпись, значение, текст или свой вид. «Значок без текста» — нет
    /// (политика уведомлений, docs/ARCHITECTURE.md): такие ядро не показывает.
    var isInformative: Bool {
        if customLeading != nil || customTrailing != nil || value != nil { return true }
        let l = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let v = valueText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !l.isEmpty || !v.isEmpty
    }
}

public extension IslandNotification {
    /// Есть ли что прочитать: заголовок или текст. Пустую карточку (значок без слов) ядро не показывает.
    var isInformative: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Озвучка карточки для VoiceOver.
    var spokenDescription: String {
        var s = "Уведомление"
        if let source { s += " от \(source)" }
        // --- hud2 --- озвучка правой части карточки.
        if let t = trailingAccessibilityLabel, !t.isEmpty { return "\(s): \(title). \(body). \(t)" }
        return "\(s): \(title). \(body)"
    }
}

@MainActor
public final class HUDCenter: ObservableObject {
    @Published public private(set) var current: HUDEvent?
    public var defaultDuration: TimeInterval = 1.2
    private var hideWork: DispatchWorkItem?

    public init() {}

    /// Показать вспышку; через `duration` (по умолчанию 1,2 с) погаснет.
    public func flash(_ event: HUDEvent, duration: TimeInterval? = nil) {
        // Пустая вспышка («значок без текста») ни о чём не говорит — не показываем (политика уведомлений).
        guard event.isInformative else { return }
        current = event
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.current = nil }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (duration ?? defaultDuration), execute: work)
    }

    /// Показать без автогашения (для снимков).
    public func show(_ event: HUDEvent) { hideWork?.cancel(); current = event }

    public func dismiss() { hideWork?.cancel(); current = nil }
}

// MARK: - Уведомления острова (не системные)

public struct IslandNotificationAction: Identifiable {
    public enum Role: Sendable { case normal, primary, destructive }
    public let id = UUID()
    public var title: String
    public var role: Role
    public var handler: @MainActor () -> Void
    public init(_ title: String, role: Role = .normal, handler: @escaping @MainActor () -> Void = {}) {
        self.title = title; self.role = role; self.handler = handler
    }
}

/// Карточка уведомления: остров вытягивается вниз на одну строку (макет 02-states, состояние 05).
public struct IslandNotification: Identifiable {
    public var id: String
    public var moduleId: String
    public var title: String
    /// Источник после точки: "Telegram", "Claude Code"…
    public var source: String?
    public var body: String
    /// Буквы в кружке-аватаре (если нет `systemImage`/`icon`).
    public var avatarText: String?
    public var avatarColors: [Color]
    public var systemImage: String?
    public var icon: AnyView?
    public var actions: [IslandNotificationAction]
    /// Через сколько секунд исчезнет само. nil — пока не закроют.
    public var duration: TimeInterval?
    /// Какую вкладку открыть по клику на карточку.
    public var opensTab: String?
    // --- hud2 --- правая часть карточки перед кнопками (напр. заряд наушников в две строки) и её озвучка.
    /// Свой вид справа (nil — нет). Задаётся после `init`: `n.trailing = AnyView(…)`.
    public var trailing: AnyView?
    /// Что VoiceOver скажет про `trailing` (добавится к озвучке карточки).
    public var trailingAccessibilityLabel: String?
    /// Сколько строк текста (1–3). Больше одной — карточка шире и выше на 16 pt за строку (подсказка «где
    /// включить право»). Задаётся после `init`: `n.bodyLines = 3`.
    public var bodyLines = 1

    public init(id: String = UUID().uuidString, moduleId: String, title: String, source: String? = nil,
                body: String, avatarText: String? = nil,
                avatarColors: [Color] = [Color(hex: "#4AA8FF"), Color(hex: "#A879FF")],
                systemImage: String? = nil, icon: AnyView? = nil,
                actions: [IslandNotificationAction] = [], duration: TimeInterval? = 6, opensTab: String? = nil) {
        self.id = id; self.moduleId = moduleId; self.title = title; self.source = source; self.body = body
        self.avatarText = avatarText; self.avatarColors = avatarColors; self.systemImage = systemImage
        self.icon = icon; self.actions = actions; self.duration = duration; self.opensTab = opensTab
    }
}

@MainActor
public final class IslandNotifications: ObservableObject {
    @Published public private(set) var current: IslandNotification?
    /// true — остров раскрыт: карточка не показывается и её таймер стоит; после сворачивания
    /// она появится и пробудет полный `duration`.
    public private(set) var isSuspended = false
    private var queue: [IslandNotification] = []
    private var hideWork: DispatchWorkItem?

    public init() {}

    /// Ставит ядро: раскрыт ли остров.
    public func setSuspended(_ suspended: Bool) {
        guard suspended != isSuspended else { return }
        isSuspended = suspended
        if suspended { hideWork?.cancel() } else if let c = current { scheduleHide(c) }
    }

    /// Показать (если уже что-то показано — в очередь).
    public func post(_ n: IslandNotification) {
        guard n.isInformative else { return }   // пустая карточка — не показываем (политика уведомлений)
        if current == nil { present(n) } else { queue.append(n) }
    }

    /// Показать сейчас, вне очереди: показанная карточка уходит в начало очереди (ответ на нажатие пользователя —
    /// напр. «где включить право» — не должен ждать чужих карточек). Тот же `id` уже в очереди — убрать дубль.
    public func postFront(_ n: IslandNotification) {
        guard n.isInformative else { return }
        queue.removeAll { $0.id == n.id }
        if let c = current, c.id != n.id { queue.insert(c, at: 0) }
        present(n)
    }

    /// Показать без таймера (для снимков).
    public func show(_ n: IslandNotification) { hideWork?.cancel(); current = n }

    // --- hud2 --- обновить карточку на месте (тот же `id`): показана — заменить и дать ей полный `duration`
    // заново (новое содержимое надо успеть прочитать); ждёт в очереди — заменить там. Уже ушла или её закрыли —
    // ничего (false): заново не показываем. Напр. заряд AirPods, узнанный позже самой карточки.
    @discardableResult
    public func replace(_ n: IslandNotification) -> Bool {
        if current?.id == n.id {
            current = n
            if !isSuspended { scheduleHide(n) }
            return true
        }
        guard let i = queue.firstIndex(where: { $0.id == n.id }) else { return false }
        queue[i] = n
        return true
    }

    public func dismiss(id: String? = nil) {
        if let id, current?.id != id { queue.removeAll { $0.id == id }; return }
        hideWork?.cancel()
        current = nil
        if !queue.isEmpty { present(queue.removeFirst()) }
    }

    private func present(_ n: IslandNotification) {
        current = n
        scheduleHide(n)
    }

    private func scheduleHide(_ n: IslandNotification) {
        hideWork?.cancel()
        guard !isSuspended, let d = n.duration else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.dismiss(id: n.id) }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + d, execute: work)
    }
}

// MARK: - Состояние острова (для модулей)

/// Что сейчас показывает остров.
public enum IslandPresentation: Int, Comparable, Sendable {
    case idle, compact, hud, notification, expanded
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// Что видно на экране и что делает пользователь — чтобы модуль включал анимации и работу только при показе,
/// а Полка узнавала о перетаскивании файлов. Публикует ядро (по всем экранам сразу), модули только читают.
/// В SwiftUI-вьюхе модуля: `@ObservedObject var island = context.island`.
@MainActor
public final class IslandStateCenter: ObservableObject {
    /// Самое «крупное» состояние среди островов на всех экранах.
    @Published public private(set) var presentation: IslandPresentation = .idle
    /// Открытая вкладка раскрытого острова. nil — остров не раскрыт.
    @Published public private(set) var expandedTab: String?
    /// Пользователь тащит файлы (из Finder, браузера…) — где угодно на экране.
    @Published public private(set) var isFileDragActive = false
    /// Перетаскиваемые файлы сейчас над островом.
    @Published public private(set) var isDropTargeted = false
    /// Кто из модулей просит клавиатуру (поле ввода). Пусто — панель не становится ключевой.
    @Published public private(set) var keyboardOwners: Set<String> = []
    // --- misc2 ---
    /// Кто держит остров раскрытым (`ModuleContext.holdExpanded`: открыто меню «Поделиться»/«Действия» модуля).
    /// Пока не пусто, уход курсора остров не сворачивает; явное сворачивание (клик, свайп, сон) — сворачивает.
    @Published public private(set) var expandHolds: Set<String> = []
    // --- /misc2 ---
    // --- shelfbar ---
    /// Кто держит остров «в покое» (`ModuleContext.holdCollapsed`: идёт режим уборки строки меню). Пока не пусто,
    /// остров на всех экранах — ровно размер выреза: без ушей, компакта, HUD, уведомлений, раскрытия и наведения.
    @Published public private(set) var collapseHolds: Set<String> = []
    // --- /shelfbar ---

    private var perIsland: [ObjectIdentifier: (IslandPresentation, String?)] = [:]

    public init() {}

    public var isExpanded: Bool { expandedTab != nil }
    public var wantsKeyboard: Bool { !keyboardOwners.isEmpty }

    /// Видна ли вкладка модуля прямо сейчас.
    public func isTabVisible(_ moduleId: String) -> Bool { expandedTab == moduleId }

    // MARK: Для ядра

    /// SimpleIsland на одном экране сообщает своё состояние (`island` — его модель).
    public func report(_ island: AnyObject, presentation p: IslandPresentation, tab: String?) {
        perIsland[ObjectIdentifier(island)] = (p, p == .expanded ? tab : nil)
        recompute()
    }

    public func forget(_ island: AnyObject) {
        perIsland[ObjectIdentifier(island)] = nil
        recompute()
    }

    public func setFileDrag(active: Bool) {
        if isFileDragActive != active { isFileDragActive = active }
        if !active, isDropTargeted { isDropTargeted = false }
    }

    public func setDropTargeted(_ v: Bool) { if isDropTargeted != v { isDropTargeted = v } }

    public func setKeyboard(_ wants: Bool, owner: String) {
        // Публикация только при изменении (вставка в @Published-множество публикует всегда).
        guard keyboardOwners.contains(owner) != wants else { return }
        if wants { keyboardOwners.insert(owner) } else { keyboardOwners.remove(owner) }
    }

    public func releaseAllKeyboard() { if !keyboardOwners.isEmpty { keyboardOwners = [] } }

    // --- misc2 ---
    public var isExpandHeld: Bool { !expandHolds.isEmpty }

    /// Держать раскрытым (`token` — «модуль.что»). Публикация только при изменении.
    public func holdExpanded(_ token: String) {
        guard !expandHolds.contains(token) else { return }
        expandHolds.insert(token)
    }

    public func releaseExpanded(_ token: String) {
        guard expandHolds.contains(token) else { return }
        expandHolds.remove(token)
    }

    /// Держит ли остров раскрытым модуль `moduleId` (токены — «модуль.что»). Ядро сверяет с вкладкой своего
    /// острова: меню Полки на одном мониторе не мешает свернуться острову на другом, открытому на другой вкладке.
    public func isExpandHeld(by moduleId: String) -> Bool {
        let prefix = moduleId + "."
        return expandHolds.contains { $0.hasPrefix(prefix) }
    }

    /// Снять все удержания с префиксом (модуль остановлен).
    public func releaseExpandHolds(prefix: String) {
        let left = expandHolds.filter { !$0.hasPrefix(prefix) }
        if left != expandHolds { expandHolds = left }
    }
    // --- /misc2 ---

    // --- shelfbar ---
    public var isCollapseHeld: Bool { !collapseHolds.isEmpty }

    /// Держать остров в покое (`token` — «модуль.что»). Публикация только при изменении.
    public func holdCollapsed(_ token: String) {
        guard !collapseHolds.contains(token) else { return }
        collapseHolds.insert(token)
    }

    public func releaseCollapsed(_ token: String) {
        guard collapseHolds.contains(token) else { return }
        collapseHolds.remove(token)
    }

    /// Снять все удержания покоя с префиксом (модуль остановлен).
    public func releaseCollapseHolds(prefix: String) {
        let left = collapseHolds.filter { !$0.hasPrefix(prefix) }
        if left != collapseHolds { collapseHolds = left }
    }
    // --- /shelfbar ---

    private func recompute() {
        let p = perIsland.values.map(\.0).max() ?? .idle
        let tab = perIsland.values.compactMap(\.1).first
        if presentation != p { presentation = p }
        if expandedTab != tab { expandedTab = tab }
    }
}
