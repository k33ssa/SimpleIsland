import Foundation
import CoreGraphics

/// Плитки вкладки «Сегодня». Порядок и включённость — в настройках модуля.
public enum TodayTile: String, Codable, CaseIterable, Identifiable, Sendable {
    case event, weather, system, batteries, clipboard, toggles

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .event: return "Следующее событие"
        case .weather: return "Погода"
        case .system: return "Система"
        case .batteries: return "Батареи"
        case .clipboard: return "Буфер обмена"
        case .toggles: return "Быстрые тумблеры"
        }
    }

    var systemImage: String {
        switch self {
        case .event: return "video"
        case .weather: return "cloud"
        case .system: return "cpu"
        case .batteries: return "battery.75percent"
        case .clipboard: return "clipboard"
        case .toggles: return "bolt"
        }
    }

    /// Доля ширины ряда (макет 03: сетка 1.25fr 1fr .9fr 1fr; ряд вмещает `TodayLayout.rowCapacity`).
    var weight: CGFloat {
        switch self {
        case .event: return 2.2
        case .weather: return 0.9
        case .system: return 1.05
        case .batteries: return 1.15
        case .clipboard: return 1.8
        case .toggles: return 1.2
        }
    }
}

struct TodayTileSetting: Codable, Equatable, Identifiable, Sendable {
    var tile: TodayTile
    var enabled: Bool
    var id: String { tile.rawValue }
}

/// Настройки модуля (settings.json → moduleSettings["today"]). Отсутствующие поля — по умолчанию.
struct TodayPrefs: Codable, Equatable, Sendable {
    var tiles: [TodayTileSetting] = TodayTile.allCases.map { TodayTileSetting(tile: $0, enabled: true) }
    var cityName = "Санкт-Петербург"
    var latitude = 59.94
    var longitude = 30.31
    /// Хранить историю буфера между запусками (файл 0600). По умолчанию — только в памяти.
    var rememberClipboard = false
    /// Имя ярлыка «Быстрых команд» для «Не беспокоить». Пусто — искать среди стандартных имён.
    var focusShortcut = ""
    /// Скрытые быстрые тумблеры (27.11: «как будто что-то лишнее») — по умолчанию «Стрим» и «Зеркало»: редкие и
    /// тяжёлые (перезапуск Finder, камера). Включаются в настройках «Сегодня».
    var hiddenToggles: [String] = ["cleanDesk", "mirror"]
    /// Громкость входа до выключения микрофона тумблером (переживает перезапуск).
    var micSavedVolume: Float?
    /// Микрофон сейчас выключен тумблером (а не пользователем в обход).
    var micMutedByUs = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TodayPrefs()
        tiles = Self.reconciled((try? c.decodeIfPresent([TodayTileSetting].self, forKey: .tiles)) ?? d.tiles)
        cityName = (try? c.decodeIfPresent(String.self, forKey: .cityName)) ?? d.cityName
        latitude = (try? c.decodeIfPresent(Double.self, forKey: .latitude)) ?? d.latitude
        longitude = (try? c.decodeIfPresent(Double.self, forKey: .longitude)) ?? d.longitude
        rememberClipboard = (try? c.decodeIfPresent(Bool.self, forKey: .rememberClipboard)) ?? d.rememberClipboard
        focusShortcut = (try? c.decodeIfPresent(String.self, forKey: .focusShortcut)) ?? d.focusShortcut
        hiddenToggles = (try? c.decodeIfPresent([String].self, forKey: .hiddenToggles)) ?? d.hiddenToggles
        micSavedVolume = (try? c.decodeIfPresent(Float.self, forKey: .micSavedVolume)) ?? nil
        micMutedByUs = (try? c.decodeIfPresent(Bool.self, forKey: .micMutedByUs)) ?? d.micMutedByUs
    }

    /// Без дублей, все плитки на месте (новые — в конец, включёнными).
    static func reconciled(_ list: [TodayTileSetting]) -> [TodayTileSetting] {
        var seen = Set<TodayTile>()
        var out: [TodayTileSetting] = []
        for s in list where !seen.contains(s.tile) { seen.insert(s.tile); out.append(s) }
        for t in TodayTile.allCases where !seen.contains(t) { out.append(TodayTileSetting(tile: t, enabled: true)) }
        return out
    }

    var enabledTiles: [TodayTile] { tiles.filter(\.enabled).map(\.tile) }
    func isEnabled(_ t: TodayTile) -> Bool { tiles.contains { $0.tile == t && $0.enabled } }
}

/// Раскладка плиток рядами: жадно по весам, ряд растягивается на всю ширину.
enum TodayLayout {
    static let rowCapacity: CGFloat = 4.15
    static let rowHeight: CGFloat = 132
    static let gap: CGFloat = 10

    static func rows(_ tiles: [TodayTile]) -> [[TodayTile]] {
        var rows: [[TodayTile]] = []
        var cur: [TodayTile] = []
        var used: CGFloat = 0
        for t in tiles {
            if !cur.isEmpty && used + t.weight > rowCapacity + 0.001 {
                rows.append(cur); cur = []; used = 0
            }
            cur.append(t); used += t.weight
        }
        if !cur.isEmpty { rows.append(cur) }
        return rows
    }

    static func height(rows n: Int) -> CGFloat {
        n == 0 ? 120 : CGFloat(n) * rowHeight + CGFloat(n - 1) * gap
    }
}
