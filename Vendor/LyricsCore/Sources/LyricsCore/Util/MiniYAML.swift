import Foundation

/// Минимальный разбор YAML — только то подмножество, которое нужно для `lyricsfile` LRCLIB:
/// отображения, последовательности (в том числе на уровне ключа), скаляры (простые, в одинарных и двойных кавычках,
/// многострочные с переносом по ширине, блочные `|` и `>`).
indirect enum YAMLValue: Equatable {
    case null
    case string(String)
    case map([(key: String, value: YAMLValue)])
    case seq([YAMLValue])

    static func == (l: YAMLValue, r: YAMLValue) -> Bool {
        switch (l, r) {
        case (.null, .null): return true
        case (.string(let a), .string(let b)): return a == b
        case (.seq(let a), .seq(let b)): return a == b
        case (.map(let a), .map(let b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        default: return false
        }
    }

    subscript(_ key: String) -> YAMLValue? {
        if case .map(let m) = self { return m.first { $0.key == key }?.value }
        return nil
    }
    var string: String? { if case .string(let s) = self { return s } else { return nil } }
    var array: [YAMLValue]? { if case .seq(let a) = self { return a } else { return nil } }
    var double: Double? { string.flatMap { Double($0) } }
    var bool: Bool? { string.map { $0.lowercased() == "true" } }
}

struct MiniYAML {
    private struct Line { var indent: Int; var text: String }
    private var lines: [Line] = []
    private var pos = 0

    static func parse(_ text: String) throws -> YAMLValue {
        var p = MiniYAML()
        p.load(text)
        guard !p.lines.isEmpty else { return .null }
        return try p.parseBlock()
    }

    private mutating func load(_ text: String) {
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            var s = String(raw)
            if s.hasSuffix("\r") { s.removeLast() }
            let trimmedLeft = s.drop(while: { $0 == " " })
            if trimmedLeft.isEmpty || trimmedLeft.hasPrefix("#") || s == "---" || s == "..." { continue }
            lines.append(Line(indent: s.count - trimmedLeft.count, text: String(trimmedLeft)))
        }
    }

    private mutating func parseBlock() throws -> YAMLValue {
        let l = lines[pos]
        if l.text == "-" || l.text.hasPrefix("- ") { return try parseSeq(indent: l.indent) }
        if Self.splitKey(l.text) != nil { return try parseMap(indent: l.indent) }
        pos += 1
        return Self.scalar(l.text)
    }

    private mutating func parseSeq(indent: Int) throws -> YAMLValue {
        var items: [YAMLValue] = []
        while pos < lines.count, lines[pos].indent == indent, lines[pos].text == "-" || lines[pos].text.hasPrefix("- ") {
            let line = lines[pos]
            let rest = line.text == "-" ? "" : String(line.text.dropFirst(2))
            let lead = rest.prefix(while: { $0 == " " }).count
            let content = String(rest.dropFirst(lead))
            if content.isEmpty {
                pos += 1
                if pos < lines.count, lines[pos].indent > indent { items.append(try parseBlock()) } else { items.append(.null) }
            } else {
                // Превращаем «- ключ: значение» в виртуальную строку с отступом содержимого.
                lines[pos] = Line(indent: indent + 2 + lead, text: content)
                items.append(try parseBlock())
            }
        }
        return .seq(items)
    }

    private mutating func parseMap(indent: Int) throws -> YAMLValue {
        var entries: [(key: String, value: YAMLValue)] = []
        while pos < lines.count, lines[pos].indent == indent, let (key, rest) = Self.splitKey(lines[pos].text) {
            pos += 1
            if rest.isEmpty {
                if pos < lines.count, lines[pos].indent > indent {
                    entries.append((key, try parseBlock()))
                } else if pos < lines.count, lines[pos].indent == indent, lines[pos].text == "-" || lines[pos].text.hasPrefix("- ") {
                    entries.append((key, try parseSeq(indent: indent)))   // последовательность на уровне ключа
                } else {
                    entries.append((key, .null))
                }
                continue
            }
            if rest == "|" || rest == ">" || rest.hasPrefix("|-") || rest.hasPrefix(">-") || rest.hasPrefix("|+") || rest.hasPrefix(">+") {
                var parts: [String] = []
                while pos < lines.count, lines[pos].indent > indent { parts.append(lines[pos].text); pos += 1 }
                entries.append((key, .string(parts.joined(separator: rest.hasPrefix("|") ? "\n" : " "))))
                continue
            }
            var value = rest
            // многострочный скаляр: продолжение — строки глубже ключа, которые не являются ключом/элементом того же уровня
            if value.hasPrefix("'") && !Self.isClosedSingle(value) || value.hasPrefix("\"") && !Self.isClosedDouble(value) {
                while pos < lines.count, lines[pos].indent > indent {
                    value += " " + lines[pos].text
                    pos += 1
                    if value.hasPrefix("'") ? Self.isClosedSingle(value) : Self.isClosedDouble(value) { break }
                }
            } else if !value.hasPrefix("'") && !value.hasPrefix("\"") {
                while pos < lines.count, lines[pos].indent > indent {
                    value += " " + lines[pos].text
                    pos += 1
                }
            }
            entries.append((key, Self.scalar(value)))
        }
        return .map(entries)
    }

    // MARK: скаляры

    static func isClosedSingle(_ s: String) -> Bool {
        var i = s.index(after: s.startIndex)
        while i < s.endIndex {
            if s[i] == "'" {
                let n = s.index(after: i)
                if n < s.endIndex, s[n] == "'" { i = s.index(after: n); continue }
                return true
            }
            i = s.index(after: i)
        }
        return false
    }

    static func isClosedDouble(_ s: String) -> Bool {
        var i = s.index(after: s.startIndex)
        while i < s.endIndex {
            if s[i] == "\\" { i = s.index(after: i); if i < s.endIndex { i = s.index(after: i) }; continue }
            if s[i] == "\"" { return true }
            i = s.index(after: i)
        }
        return false
    }

    static func scalar(_ raw: String) -> YAMLValue {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("'") {
            var body = String(s.dropFirst())
            // отрезать закрывающую кавычку (последнюю не удвоенную)
            if let last = body.lastIndex(of: "'") { body = String(body[..<last]) }
            return .string(body.replacingOccurrences(of: "''", with: "'"))
        }
        if s.hasPrefix("\"") {
            var body = String(s.dropFirst())
            if let last = body.lastIndex(of: "\"") { body = String(body[..<last]) }
            return .string(unescapeDouble(body))
        }
        if s == "~" || s == "null" || s.isEmpty { return .null }
        // комментарий « #…» у простого скаляра
        if let r = s.range(of: " #") { return .string(String(s[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)) }
        return .string(s)
    }

    private static func unescapeDouble(_ s: String) -> String {
        var out = ""
        var it = s.makeIterator()
        while let c = it.next() {
            guard c == "\\" else { out.append(c); continue }
            guard let n = it.next() else { break }
            switch n {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            case "\"": out.append("\"")
            case "\\": out.append("\\")
            case "/": out.append("/")
            case "u":
                var hex = ""
                for _ in 0..<4 { if let h = it.next() { hex.append(h) } }
                if let v = UInt32(hex, radix: 16), let u = Unicode.Scalar(v) { out.unicodeScalars.append(u) }
            default: out.append(n)
            }
        }
        return out
    }

    /// Делит «ключ: значение». Ключ может быть в кавычках.
    static func splitKey(_ text: String) -> (String, String)? {
        if text.hasPrefix("'") || text.hasPrefix("\"") {
            let q = text.first!
            var i = text.index(after: text.startIndex)
            while i < text.endIndex {
                if text[i] == q {
                    let n = text.index(after: i)
                    if q == "'", n < text.endIndex, text[n] == "'" { i = text.index(after: n); continue }
                    if n < text.endIndex, text[n] == ":" {
                        let key = String(text[text.index(after: text.startIndex)..<i]).replacingOccurrences(of: "''", with: "'")
                        let rest = String(text[text.index(after: n)...]).trimmingCharacters(in: .whitespaces)
                        return (key, rest)
                    }
                    return nil
                }
                i = text.index(after: i)
            }
            return nil
        }
        if let r = text.range(of: ": ") {
            return (String(text[..<r.lowerBound]), String(text[r.upperBound...]).trimmingCharacters(in: .whitespaces))
        }
        if text.hasSuffix(":") { return (String(text.dropLast()), "") }
        return nil
    }
}
