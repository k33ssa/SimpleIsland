import Foundation

/// JSON с сохранением порядка ключей и записи чисел — чтобы правка ~/.claude/settings.json меняла только наши
/// строки, а не переставляла весь файл пользователя.
indirect enum OJSON: Equatable {
    case null
    case bool(Bool)
    case number(String)
    case string(String)
    case array([OJSON])
    case object([(String, OJSON)])

    static func == (a: OJSON, b: OJSON) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case (.bool(let x), .bool(let y)): return x == y
        case (.number(let x), .number(let y)): return x == y
        case (.string(let x), .string(let y)): return x == y
        case (.array(let x), .array(let y)): return x == y
        case (.object(let x), .object(let y)):
            return x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: return false
        }
    }

    subscript(key: String) -> OJSON? {
        get { if case .object(let o) = self { return o.first { $0.0 == key }?.1 }; return nil }
        set {
            guard case .object(var o) = self else { return }
            if let i = o.firstIndex(where: { $0.0 == key }) {
                if let newValue { o[i].1 = newValue } else { o.remove(at: i) }
            } else if let newValue {
                o.append((key, newValue))
            }
            self = .object(o)
        }
    }

    var string: String? { if case .string(let s) = self { return s }; return nil }
    var array: [OJSON]? { if case .array(let a) = self { return a }; return nil }
    var isObject: Bool { if case .object = self { return true }; return false }

    // MARK: Разбор

    struct ParseError: Error, CustomStringConvertible {
        var offset: Int
        var description: String { "некорректный JSON (позиция \(offset))" }
    }

    static func parse(_ data: Data) throws -> OJSON {
        var p = Parser(bytes: Array(data))
        p.skipWS()
        let v = try p.value(depth: 0)
        p.skipWS()
        guard p.i == p.bytes.count else { throw ParseError(offset: p.i) }
        return v
    }

    private struct Parser {
        let bytes: [UInt8]
        var i = 0

        mutating func skipWS() {
            while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
        }

        func fail() -> ParseError { ParseError(offset: i) }

        mutating func value(depth: Int) throws -> OJSON {
            guard depth < 200, i < bytes.count else { throw fail() }
            switch bytes[i] {
            case UInt8(ascii: "{"):
                i += 1; skipWS()
                var o: [(String, OJSON)] = []
                if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(o) }
                while true {
                    skipWS()
                    guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw fail() }
                    let k = try string()
                    skipWS()
                    guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw fail() }
                    i += 1; skipWS()
                    o.append((k, try value(depth: depth + 1)))
                    skipWS()
                    guard i < bytes.count else { throw fail() }
                    if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                    if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(o) }
                    throw fail()
                }
            case UInt8(ascii: "["):
                i += 1; skipWS()
                var a: [OJSON] = []
                if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(a) }
                while true {
                    skipWS()
                    a.append(try value(depth: depth + 1))
                    skipWS()
                    guard i < bytes.count else { throw fail() }
                    if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                    if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(a) }
                    throw fail()
                }
            case UInt8(ascii: "\""):
                return .string(try string())
            case UInt8(ascii: "t"): return try literal("true", .bool(true))
            case UInt8(ascii: "f"): return try literal("false", .bool(false))
            case UInt8(ascii: "n"): return try literal("null", .null)
            default:
                let start = i
                while i < bytes.count, "+-0123456789.eE".utf8.contains(bytes[i]) { i += 1 }
                guard i > start, let s = String(bytes: bytes[start..<i], encoding: .utf8), Double(s) != nil else { throw fail() }
                return .number(s)
            }
        }

        mutating func literal(_ word: String, _ v: OJSON) throws -> OJSON {
            let w = Array(word.utf8)
            guard i + w.count <= bytes.count, Array(bytes[i..<i + w.count]) == w else { throw fail() }
            i += w.count
            return v
        }

        mutating func string() throws -> String {
            i += 1   // "
            var out = [UInt8]()
            while i < bytes.count {
                let c = bytes[i]
                if c == UInt8(ascii: "\"") {
                    i += 1
                    guard let s = String(bytes: out, encoding: .utf8) else { throw fail() }
                    return s
                }
                if c == UInt8(ascii: "\\") {
                    i += 1
                    guard i < bytes.count else { throw fail() }
                    let e = bytes[i]
                    switch e {
                    case UInt8(ascii: "\""): out.append(0x22)
                    case UInt8(ascii: "\\"): out.append(0x5C)
                    case UInt8(ascii: "/"): out.append(0x2F)
                    case UInt8(ascii: "b"): out.append(0x08)
                    case UInt8(ascii: "f"): out.append(0x0C)
                    case UInt8(ascii: "n"): out.append(0x0A)
                    case UInt8(ascii: "r"): out.append(0x0D)
                    case UInt8(ascii: "t"): out.append(0x09)
                    case UInt8(ascii: "u"):
                        var code = try hex4()
                        if (0xD800..<0xDC00).contains(code) {
                            // суррогатная пара
                            guard i + 2 < bytes.count, bytes[i + 1] == UInt8(ascii: "\\"), bytes[i + 2] == UInt8(ascii: "u") else { throw fail() }
                            i += 2
                            let low = try hex4()
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        }
                        guard let scalar = Unicode.Scalar(code) else { throw fail() }
                        out += Array(String(Character(scalar)).utf8)
                    default: throw fail()
                    }
                    i += 1
                    continue
                }
                guard c >= 0x20 else { throw fail() }
                out.append(c)
                i += 1
            }
            throw fail()
        }

        mutating func hex4() throws -> UInt32 {
            guard i + 4 < bytes.count, let s = String(bytes: bytes[(i + 1)...(i + 4)], encoding: .ascii),
                  let v = UInt32(s, radix: 16) else { throw fail() }
            i += 4
            return v
        }
    }

    // MARK: Запись (как JSON.stringify(x, null, 2) — так пишет сам Claude Code)

    func serialized(indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent + 1)
        let end = String(repeating: "  ", count: indent)
        switch self {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return n
        case .string(let s): return Self.quote(s)
        case .array(let a):
            if a.isEmpty { return "[]" }
            return "[\n" + a.map { pad + $0.serialized(indent: indent + 1) }.joined(separator: ",\n") + "\n" + end + "]"
        case .object(let o):
            if o.isEmpty { return "{}" }
            return "{\n" + o.map { pad + Self.quote($0.0) + ": " + $0.1.serialized(indent: indent + 1) }
                .joined(separator: ",\n") + "\n" + end + "}"
        }
    }

    static func quote(_ s: String) -> String {
        var r = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": r += "\\\""
            case "\\": r += "\\\\"
            case "\n": r += "\\n"
            case "\r": r += "\\r"
            case "\t": r += "\\t"
            case "\u{08}": r += "\\b"
            case "\u{0C}": r += "\\f"
            default:
                if u.value < 0x20 { r += String(format: "\\u%04x", u.value) } else { r.unicodeScalars.append(u) }
            }
        }
        return r + "\""
    }
}
