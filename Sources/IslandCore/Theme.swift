import AppKit
import SwiftUI

/// Тема острова. Один JSON-файл на тему; схема одинакова для макетов (design/themes) и кода.
/// Отсутствующие поля берутся из встроенной «obsidian», неизвестные игнорируются (см. `Theme.decode`).
public struct Theme: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var subtitle: String
    public var background: Background
    public var rim: Rim
    public var glow: Glow
    public var text: TextColors
    public var accent: String
    public var accent2: String
    public var controlFill: String
    public var font: FontSpec
    public var shape: ShapeSpec
    public var effects: Effects
    public var spring: SpringSpec

    public enum BackgroundType: String, LenientStringEnum, Sendable {
        case solid, gradient, glass
        public static let fallback = BackgroundType.solid
    }
    public struct Background: Codable, Equatable, Sendable {
        public var type: BackgroundType
        public var colors: [String]
        /// Угол градиента в градусах, как в CSS (180 — сверху вниз).
        public var angle: Double
        /// Для glass — сила размытия подложки (0 — системная по умолчанию).
        public var blur: Double
        /// Верхние ~высота выреза всегда #000, чтобы остров сливался с железом.
        public var coreBlack: Bool
        // --- media2 ---
        /// `artwork` — фон из цветов обложки играющего (тема «Хамелеон»): ядро кладёт их в окружение
        /// `islandArtworkColors`, `IslandBackground` рисует из них тёмный градиент с подсветкой снизу. Нет обложки —
        /// обычный фон темы.
        public var source: BackgroundSource = .theme
        // --- /media2 ---
    }

    // --- media2 ---
    public enum BackgroundSource: String, LenientStringEnum, Sendable {
        case theme, artwork
        public static let fallback = BackgroundSource.theme
    }
    // --- /media2 ---

    public enum RimType: String, LenientStringEnum, Sendable {
        case none, solid, conic
        public static let fallback = RimType.none
    }
    public struct Rim: Codable, Equatable, Sendable {
        public var type: RimType
        public var colors: [String]
        public var width: Double
        public var animated: Bool
    }

    public enum GlowSource: String, LenientStringEnum, Sendable {
        case artwork, fixed, none
        public static let fallback = GlowSource.none
    }
    public struct Glow: Codable, Equatable, Sendable {
        public var source: GlowSource
        public var colors: [String]
        public var opacity: Double
        public var radius: Double
    }

    public struct TextColors: Codable, Equatable, Sendable {
        public var primary: String
        public var secondary: String
        public var tertiary: String
    }

    public enum FontFamily: String, LenientStringEnum, Sendable {
        case system, Inter, mono
        public static let fallback = FontFamily.system
    }
    public enum FontDesign: String, LenientStringEnum, Sendable {
        case `default`, rounded, monospaced, serif
        public static let fallback = FontDesign.default
    }
    public struct FontSpec: Codable, Equatable, Sendable {
        public var family: FontFamily
        public var design: FontDesign
    }

    public struct ShapeSpec: Codable, Equatable, Sendable {
        /// Радиус нижних углов раскрытого острова.
        public var cornerRadius: Double
        /// Радиус вогнутых «ушей» — сопряжения с верхним краем экрана.
        public var earRadius: Double
        /// Радиус нижних углов в компакте.
        public var compactCornerRadius: Double
    }

    public struct Effects: Codable, Equatable, Sendable {
        public var scanlines: Bool
        public var noise: Double
        public var highlight: Bool
        public var pixelated: Bool
    }

    public struct SpringSpec: Codable, Equatable, Sendable {
        public var response: Double
        public var damping: Double
    }
}

// MARK: - Встроенная тема и загрузка

public extension Theme {
    /// «Обсидиан» — встроенный фолбэк, всегда есть.
    static let obsidian = Theme(
        id: "obsidian", name: "Обсидиан", subtitle: "по умолчанию",
        background: .init(type: .solid, colors: ["#000000"], angle: 180, blur: 0, coreBlack: true),
        rim: .init(type: .none, colors: [], width: 1.5, animated: false),
        glow: .init(source: .artwork, colors: ["#FF7A45", "#FF3D7F", "#7B2CFF"], opacity: 0.55, radius: 60),
        text: .init(primary: "#FFFFFF", secondary: "#FFFFFFB8", tertiary: "#FFFFFF7A"),
        accent: "#FF7A45", accent2: "#FF3D7F",
        controlFill: "#FFFFFF12",
        font: .init(family: .system, design: .default),
        shape: .init(cornerRadius: 38, earRadius: 16, compactCornerRadius: 14),
        effects: .init(scanlines: false, noise: 0, highlight: false, pixelated: false),
        spring: .init(response: 0.42, damping: 0.78)
    )

    /// Разбор JSON темы поверх obsidian. `fallbackId` — имя файла без расширения, если в JSON нет "id".
    static func decode(_ data: Data, fallbackId: String? = nil) throws -> Theme {
        try MergedJSON.decode(Theme.self, from: data, base: .obsidian) { dict in
            if dict["id"] == nil, let fid = fallbackId { dict["id"] = fid }
            if dict["name"] == nil, let fid = fallbackId { dict["name"] = fid }
            if dict["subtitle"] == nil { dict["subtitle"] = "" }
        }
    }

    func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }
}

// MARK: - Готовые значения для SwiftUI

public extension Theme {
    var primary: Color { Color(hex: text.primary, fallback: .white) }
    var secondary: Color { Color(hex: text.secondary, fallback: .white.opacity(0.72)) }
    var tertiary: Color { Color(hex: text.tertiary, fallback: .white.opacity(0.48)) }
    var accentColor: Color { Color(hex: accent, fallback: .orange) }
    var accent2Color: Color { Color(hex: accent2, fallback: .pink) }
    var controlFillColor: Color { Color(hex: controlFill, fallback: .white.opacity(0.07)) }
    var backgroundColors: [Color] { background.colors.map { Color(hex: $0, fallback: .black) } }
    var rimColors: [Color] { rim.colors.map { Color(hex: $0, fallback: .white) } }
    var glowColors: [Color] { glow.colors.map { Color(hex: $0, fallback: .clear) } }

    /// Тема «чистый чёрный» (сплошной #000 с чёрным ядром, как Обсидиан): остров должен быть неотличим от
    /// выреза — никаких светлых кромок и ореолов вокруг, иначе глаз читает его как тёмно-серый (14.11, пользователь:
    /// «недостаточно чёрный для реальной шторки»).
    var isPureBlack: Bool {
        guard background.type == .solid, background.coreBlack, rim.type == .none,
              let first = background.colors.first, let c = NSColor(hex: first) else { return false }
        return c.luminance < 0.01
    }

    /// Светлая тема (фон острова светлый) — для превью и контраста.
    var isLight: Bool {
        guard let first = background.colors.last, let c = NSColor(hex: first) else { return false }
        return c.luminance > 0.6 && background.type != .glass
    }

    /// Цвет отдельной поверхности рядом с островом («капля» второй активности): у верхней кромки остров
    /// чёрный при `coreBlack`, иначе — первый цвет фона (у светлых тем — светлый).
    var surfaceColor: Color {
        if background.coreBlack { return .black }
        if background.type == .glass { return Color.black.opacity(0.85) }
        return backgroundColors.first ?? .black
    }

    /// Пружина морфинга — одна на все размеры.
    var springAnimation: Animation {
        .spring(response: spring.response, dampingFraction: spring.damping)
    }

    /// Шрифт темы.
    func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        switch font.family {
        case .mono:
            return .system(size: size, weight: weight, design: .monospaced)
        case .Inter:
            if NSFont(name: "Inter", size: size) != nil {
                return .custom("Inter", size: size).weight(weight)
            }
            return .system(size: size, weight: weight, design: swiftUIDesign)
        case .system:
            return .system(size: size, weight: weight, design: swiftUIDesign)
        }
    }

    var swiftUIDesign: Font.Design {
        switch font.design {
        case .default: return .default
        case .rounded: return .rounded
        case .monospaced: return .monospaced
        case .serif: return .serif
        }
    }
}

// MARK: - Окружение

private struct IslandThemeKey: EnvironmentKey {
    static let defaultValue = Theme.obsidian
}
private struct SnapshotModeKey: EnvironmentKey {
    static let defaultValue = false
}

public extension EnvironmentValues {
    /// Текущая тема (уже с поправками формы/физики из настроек).
    var islandTheme: Theme {
        get { self[IslandThemeKey.self] }
        set { self[IslandThemeKey.self] = newValue }
    }
    /// true при рендере `--snapshot`: без анимаций по времени и без NSView-обёрток (ImageRenderer их не рисует).
    var isSnapshot: Bool {
        get { self[SnapshotModeKey.self] }
        set { self[SnapshotModeKey.self] = newValue }
    }
}
