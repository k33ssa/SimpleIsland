import Foundation

/// Мок-состояния для `--snapshot` (имена людей вымышленные). Систему не трогают.
@MainActor
enum TodayMocks {
    enum Scenario { case fullDay, noCalendar, offline, needsAutomation, overlap }

    /// Сегодня, 14:48 — как в макете.
    static func mockNow() -> Date {
        Calendar.current.date(bySettingHour: 14, minute: 48, second: 0, of: Date()) ?? Date()
    }

    private static func at(_ h: Int, _ m: Int, _ base: Date, dayOffset: Int = 0) -> Date {
        let cal = Calendar.current
        let d = cal.date(byAdding: .day, value: dayOffset, to: base) ?? base
        return cal.date(bySettingHour: h, minute: m, second: 0, of: d) ?? d
    }

    static func events(now: Date) -> [TodayEvent] {
        [
            TodayEvent(id: "m1", title: "Пара: матанализ", start: at(9, 30, now), end: at(11, 0, now), colorHex: "#4AA8FF"),
            TodayEvent(id: "m2", title: "Созвон по проекту", start: at(15, 0, now), end: at(15, 40, now), colorHex: "#FFB36E",
                       attendees: ["Дима", "Лёша", "Настя"],
                       link: MeetingLinks.find(in: "Ссылка: https://telemost.yandex.ru/j/12345678901234")),
            TodayEvent(id: "m3", title: "Спортзал", start: at(17, 30, now), end: at(18, 30, now), colorHex: "#A879FF",
                       location: "Фитнес на Ваське"),
            TodayEvent(id: "m4", title: "Стендап", start: at(10, 0, now, dayOffset: 1), end: at(10, 15, now, dayOffset: 1),
                       colorHex: "#4AA8FF", link: MeetingLinks.find(in: "https://meet.google.com/abc-defg-hij")),
        ]
    }

    static func meeting(now: Date) -> TodayEvent? { events(now: now).first { $0.id == "m2" } }

    static func weather(now: Date, fetched: Date) -> WeatherSnapshot {
        let hour = Calendar.current.dateInterval(of: .hour, for: now)?.start ?? now
        let temps: [(Double, Int)] = [(-2, 3), (-3, 3), (-3, 71), (-4, 73), (-4, 73), (-5, 3)]
        return WeatherSnapshot(latitude: 59.94, longitude: 30.31, fetchedAt: fetched, temperature: -2.3, apparent: -6,
                               code: 3, isDay: true,
                               hours: temps.enumerated().map { i, t in
                                   .init(time: hour.addingTimeInterval(Double(i + 1) * 3600), temperature: t.0, code: t.1)
                               })
    }

    static func clips(now: Date) -> [ClipItem] {
        [
            ClipItem(kind: .code, text: "swift build -c release\n--arch arm64", source: "Терминал", date: now.addingTimeInterval(-120)),
            ClipItem(kind: .url, text: "https://github.com/simpleisland-app/island-kit", source: "Safari", date: now.addingTimeInterval(-540)),
            ClipItem(kind: .color, text: "#FF7A45", source: "Figma", date: now.addingTimeInterval(-840), colorHex: "#FF7A45"),
            ClipItem(kind: .text, text: "Встречаемся у главного входа в 19:00", source: "Telegram", date: now.addingTimeInterval(-1800)),
        ]
    }

    static func apply(_ s: Scenario, to m: TodayModel) {
        let now = mockNow()
        m.nowOverride = now
        m.calendarAccess = .granted
        m.events = events(now: now)
        m.weather = weather(now: now, fetched: now.addingTimeInterval(-600))
        m.weatherProblem = nil
        m.system = SystemSample(cpu: 0.34, memory: 0.71, memoryUsedGB: 11.4, memoryTotalGB: 16, thermal: .nominal)
        m.batteries = [
            BatteryItem(id: "mac", name: "MacBook", kind: .mac, level: 0.78, charging: true),
            BatteryItem(id: "bt.1", name: "AirPods", kind: .headphones, level: 0.82),
            BatteryItem(id: "bt.2", name: "Мышь", kind: .mouse, level: 0.18),
        ]
        m.clips = clips(now: now)
        m.focusShortcutName = "Не беспокоить"
        m.focusOn = true
        m.awake = true
        m.dark = true
        m.micOff = false
        m.desktopHidden = false
        m.permissionPrompt = nil

        switch s {
        case .fullDay: break
        case .noCalendar:
            m.calendarAccess = .notDetermined
            m.events = []
        case .offline:
            m.weather = weather(now: now, fetched: now.addingTimeInterval(-85 * 60))
            m.weatherProblem = .offline
            m.clips = []
            m.batteries = [BatteryItem(id: "mac", name: "MacBook", kind: .mac, level: 0.41)]
            m.focusShortcutName = nil
        case .needsAutomation:
            m.permissionPrompt = .automation
        case .overlap:
            // Длинное идущее событие без ссылки не прячет созвон: главный — созвон, «Сейчас: …» второй строкой.
            m.events.append(TodayEvent(id: "m5", title: "Практикум по Swift", start: at(13, 0, now), end: at(17, 0, now),
                                       colorHex: "#39D98A"))
            m.events.sort { $0.start < $1.start }
            m.weatherProblem = .service
        }
    }
}
