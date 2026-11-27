import AppKit
import EventKit

/// Событие для вкладки (без EventKit-типов — удобно для моков и тестов).
struct TodayEvent: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var colorHex: String?
    var attendees: [String] = []
    var link: MeetingLink?
    var location: String?

    func isOngoing(at now: Date) -> Bool { start <= now && now < end }
}

enum CalendarAccess: Equatable, Sendable {
    case granted
    /// Ещё не спрашивали — кнопка «Разрешить календарь» покажет системный запрос.
    case notDetermined
    /// Отказано / только запись / ограничено — кнопка откроет Системные настройки.
    case denied
}

/// EventKit: доступ, события сегодня–завтра, наблюдение за изменениями. Только главный поток.
@MainActor
final class CalendarService {
    private var store: EKEventStore?
    private var observer: NSObjectProtocol?
    var onChange: (@MainActor () -> Void)?

    // Запрос права — через ядро (`ensurePermission`, TodayModel.requestCalendar/ensureCalendarAccess), не здесь.

    static var access: CalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    /// В Info.plist есть строка-описание — без неё системный запрос убивает процесс (голый бинарь из swift build).
    static var canAskSystem: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSCalendarsFullAccessUsageDescription") != nil
    }

    /// Повторный вызов ничего не делает. Зовётся и из `reloadEvents()`: доступ могли выдать позже в Системных настройках.
    func start() {
        guard Self.access == .granted, observer == nil else { return }
        // Хранилище, созданное до выдачи права (запрос с отказом), событий может не видеть — берём новое.
        let store = EKEventStore()
        self.store = store
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onChange?() }
        }
    }

    func stop() {
        if let o = observer { NotificationCenter.default.removeObserver(o) }
        observer = nil
        store = nil
    }

    /// Не целодневные события с начала сегодняшнего дня до конца завтрашнего.
    func events(now: Date = Date()) -> [TodayEvent] {
        guard Self.access == .granted, let store else { return [] }
        let cal = Calendar.current
        let from = cal.startOfDay(for: now)
        guard let to = cal.date(byAdding: .day, value: 2, to: from) else { return [] }
        let pred = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        return store.events(matching: pred)
            .filter { !$0.isAllDay && $0.status != .canceled && !Self.declined($0) }
            .sorted { $0.startDate < $1.startDate }
            .map(Self.convert)
    }

    private static func declined(_ e: EKEvent) -> Bool {
        e.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false
    }

    private static func convert(_ e: EKEvent) -> TodayEvent {
        let people = (e.attendees ?? [])
            .filter { !$0.isCurrentUser && $0.participantType != .room && $0.participantType != .resource }
            .compactMap { p -> String? in
                if let n = p.name, !n.isEmpty, !n.contains("@") { return n.split(separator: " ").first.map(String.init) }
                return p.url.absoluteString.replacingOccurrences(of: "mailto:", with: "").split(separator: "@").first.map(String.init)
            }
        var hex: String?
        if let c = e.calendar?.color?.usingColorSpace(.sRGB) {
            hex = String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
        }
        return TodayEvent(id: (e.eventIdentifier ?? UUID().uuidString) + "@\(e.startDate.timeIntervalSince1970)",
                          title: e.title?.isEmpty == false ? e.title! : "Без названия",
                          start: e.startDate, end: e.endDate, colorHex: hex, attendees: people,
                          link: MeetingLinks.find(url: e.url, location: e.location, notes: e.notes),
                          location: e.location)
    }
}

/// Логика выбора и подписей — отдельно от EventKit (самотест).
enum EventLogic {
    /// Что показать в плитке: главное событие и (необязательно) идущее, которое уступило ему место.
    struct Featured: Equatable {
        var main: TodayEvent
        /// Идущее событие без ссылки (или с ссылкой, когда скоро начнётся другое) — второй строкой «Сейчас: …».
        var ongoing: TodayEvent?
    }

    /// Выбор для плитки. Длинное идущее событие («Работа 9–18») не прячет ближайшую встречу:
    /// 1) встреча начнётся в пределах `lead` — она главная;
    /// 2) идёт событие со ссылкой — оно (можно подключиться с опозданием);
    /// 3) идёт событие без ссылки, а сегодня будет ещё — главное следующее, идущее — второй строкой;
    /// 4) иначе идущее или ближайшее будущее.
    static func featured(_ events: [TodayEvent], now: Date, lead: TimeInterval = 5 * 60) -> Featured? {
        let ongoing = events.filter { $0.isOngoing(at: now) }.sorted { $0.start > $1.start }   // свежее начатое — первым
        let future = events.filter { $0.start > now }.sorted { $0.start < $1.start }
        if let f = future.first, f.start.timeIntervalSince(now) <= lead { return Featured(main: f, ongoing: ongoing.first) }
        if let o = ongoing.first(where: { $0.link != nil }) { return Featured(main: o) }
        if let o = ongoing.first {
            if let n = future.first(where: { Calendar.current.isDate($0.start, inSameDayAs: now) }) {
                return Featured(main: n, ongoing: o)
            }
            return Featured(main: o)
        }
        return future.first.map { Featured(main: $0) }
    }

    /// Ближайшее по началу — ещё не началось или началось не раньше `grace` назад. Для напоминания
    /// (компакт за 5 мин) и таймера: идущие события на него не влияют.
    static func upcoming(_ events: [TodayEvent], now: Date, grace: TimeInterval) -> TodayEvent? {
        events.filter { $0.start > now.addingTimeInterval(-grace) }.min { $0.start < $1.start }
    }

    /// События сегодняшнего дня для полосы.
    static func today(_ events: [TodayEvent], now: Date) -> [TodayEvent] {
        let cal = Calendar.current
        return events.filter { cal.isDate($0.start, inSameDayAs: now) || ($0.start < now && $0.end > now) }
    }

    /// Окно полосы дня: 8:00–20:00, расширяется под события.
    static func dayWindow(_ events: [TodayEvent], now: Date) -> (start: Date, end: Date) {
        let cal = Calendar.current
        let day = cal.startOfDay(for: now)
        var s = cal.date(bySettingHour: 8, minute: 0, second: 0, of: day) ?? day
        var e = cal.date(bySettingHour: 20, minute: 0, second: 0, of: day) ?? day.addingTimeInterval(86400)
        for ev in events {
            if ev.start < s { s = max(day, cal.dateInterval(of: .hour, for: ev.start)?.start ?? ev.start) }
            if ev.end > e { e = min(day.addingTimeInterval(86400), ev.end) }
        }
        if now < s { s = cal.dateInterval(of: .hour, for: now)?.start ?? now }
        if now > e { e = now }
        return (s, e)
    }

    /// Обратный отсчёт до начала: («12», «мин»), («2:05», «ч»), («сейчас», «»). Для идущего — («идёт», «»).
    static func countdown(to start: Date, end: Date, now: Date) -> (value: String, unit: String) {
        if now >= start { return now < end ? ("идёт", "") : ("", "") }
        let mins = Int(ceil(start.timeIntervalSince(now) / 60))
        if mins <= 0 { return ("сейчас", "") }
        if mins < 60 { return ("\(mins)", " мин") }
        if mins < 24 * 60 { return (String(format: "%d:%02d", mins / 60, mins % 60), " ч") }
        let days = mins / (24 * 60)
        return ("\(days)", days == 1 ? " день" : (days < 5 ? " дня" : " дней"))
    }

    // Форматтеры создаются один раз (вызовы — только с главного потока).
    private static let hmFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.dateFormat = "HH:mm"; return f
    }()
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.dateFormat = "d MMM"; return f
    }()

    static func hm(_ d: Date) -> String { hmFormatter.string(from: d) }

    /// «15:00», «вчера 15:00», «12 нояб. 15:00» — для отметок времени (погода без сети).
    static func stamp(_ d: Date, now: Date) -> String {
        let cal = Calendar.current
        if cal.isDate(d, inSameDayAs: now) { return hm(d) }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(d, inSameDayAs: y) { return "вчера \(hm(d))" }
        return "\(dayFormatter.string(from: d)) \(hm(d))"
    }

    static func timeRange(_ e: TodayEvent, now: Date) -> String {
        var s = "\(hm(e.start)) – \(hm(e.end))"
        if !Calendar.current.isDate(e.start, inSameDayAs: now) {
            let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now).map { Calendar.current.isDate(e.start, inSameDayAs: $0) } ?? false
            s = "\(tomorrow ? "завтра" : dayFormatter.string(from: e.start)), " + s
        }
        return s
    }

    static func people(_ names: [String], max n: Int = 3) -> String {
        guard !names.isEmpty else { return "" }
        if names.count <= n { return names.joined(separator: ", ") }
        return names.prefix(n).joined(separator: ", ") + " и ещё \(names.count - n)"
    }
}
