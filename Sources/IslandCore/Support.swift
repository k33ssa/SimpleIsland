import AppKit
import SwiftUI

// MARK: - Цвета из строк темы

public extension Color {
    /// `#RGB`, `#RRGGBB`, `#RRGGBBAA` (альфа в конце). Ошибка разбора → `fallback`.
    init(hex: String, fallback: Color = .gray) {
        if let c = NSColor(hex: hex) { self.init(nsColor: c) } else { self = fallback }
    }
}

public extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let rgba: UInt64 = s.count == 8 ? v : (v << 8 | 0xFF)
        func ch(_ shift: UInt64) -> CGFloat { CGFloat((rgba >> shift) & 0xFF) / 255.0 }
        self.init(srgbRed: ch(24), green: ch(16), blue: ch(8), alpha: ch(0))
    }

    /// Относительная яркость (0…1) — чтобы понять, светлая ли тема.
    var luminance: CGFloat {
        guard let c = usingColorSpace(.sRGB) else { return 0 }
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
    }
}

// MARK: - Произвольный JSON (настройки модулей)

public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    /// Любое Encodable → JSONValue (через JSONEncoder).
    public static func from<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }

    /// JSONValue → любой Decodable.
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(self))
    }
}

// MARK: - Декодирование «поверх значений по умолчанию»

public enum MergedJSON {
    /// Декодирует `data` поверх `base`: отсутствующие поля берутся из `base`, неизвестные игнорируются.
    /// Принимает JSON5 (комментарии `//`, хвостовые запятые).
    public static func decode<T: Codable>(_ type: T.Type, from data: Data, base: T,
                                          patch: (inout [String: Any]) -> Void = { _ in }) throws -> T {
        let baseObj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(base))
        var over = try JSONSerialization.jsonObject(with: data, options: [.json5Allowed])
        if var dict = over as? [String: Any] { patch(&dict); over = dict }
        let merged = deepMerge(baseObj, over)
        return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: merged))
    }

    static func deepMerge(_ base: Any, _ over: Any) -> Any {
        guard var b = base as? [String: Any], let o = over as? [String: Any] else {
            return over is NSNull ? base : over
        }
        for (k, v) in o { b[k] = b[k].map { deepMerge($0, v) } ?? v }
        return b
    }
}

/// Перечисление, которое при неизвестном значении в JSON берёт `fallback`, а не роняет весь файл.
public protocol LenientStringEnum: RawRepresentable, Codable, CaseIterable where RawValue == String {
    static var fallback: Self { get }
}

public extension LenientStringEnum {
    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = Self(rawValue: raw) ?? Self.fallback
    }
}

// MARK: - Пути

public enum SimpleIslandPaths {
    /// ~/Library/Application Support/SimpleIsland
    public static var appSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("SimpleIsland", isDirectory: true)
    }
    public static var userThemes: URL { appSupport.appendingPathComponent("Themes", isDirectory: true) }
    public static var settingsFile: URL { appSupport.appendingPathComponent("settings.json") }
    /// Contents/Resources/Themes внутри .app (если запущено из бандла).
    public static var bundledThemes: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("Themes", isDirectory: true)
    }
    /// `design/themes` репозитория для самотестов: текущий каталог, затем вверх от исполняемого файла
    /// (`.build-*/debug/SimpleIsland` → корень проекта), чтобы самотест не зависел от каталога запуска.
    /// В установленном .app такого каталога нет — nil.
    public static var repoThemes: URL? {
        let fm = FileManager.default
        var candidates = [URL(fileURLWithPath: fm.currentDirectoryPath)]
        if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            var d = exe.deletingLastPathComponent()
            for _ in 0..<5 {
                candidates.append(d)
                d = d.deletingLastPathComponent()
            }
        }
        for c in candidates {
            let dir = c.appendingPathComponent("design/themes", isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue { return dir }
        }
        return nil
    }
}
