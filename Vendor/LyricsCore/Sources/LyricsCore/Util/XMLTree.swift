import Foundation

/// Лёгкое DOM-дерево поверх `XMLParser` с сохранением пробелов (в TTML они значимы).
/// Имена элементов — локальные (без префикса); имена атрибутов нормализуются по пространству имён:
/// `ttm:*`, `itunes:*`, `tts:*`, `xml:*`, `amll:*`, остальные — как есть.
final class XMLNode {
    enum Child {
        case text(String)
        case element(XMLNode)
    }
    let name: String
    let namespace: String
    var attributes: [String: String]
    var children: [Child] = []

    init(name: String, namespace: String, attributes: [String: String]) {
        self.name = name
        self.namespace = namespace
        self.attributes = attributes
    }

    var elements: [XMLNode] {
        children.compactMap { if case .element(let n) = $0 { return n } else { return nil } }
    }

    func elements(named n: String) -> [XMLNode] { elements.filter { $0.name == n } }
    func first(named n: String) -> XMLNode? { elements.first { $0.name == n } }

    /// Вся текстовая часть поддерева.
    var textContent: String {
        var s = ""
        for c in children {
            switch c {
            case .text(let t): s += t
            case .element(let e): s += e.textContent
            }
        }
        return s
    }

    /// Рекурсивный обход в глубину.
    func descendants(named n: String) -> [XMLNode] {
        var out: [XMLNode] = []
        for e in elements {
            if e.name == n { out.append(e) }
            out.append(contentsOf: e.descendants(named: n))
        }
        return out
    }
}

enum XMLTree {
    static let canonicalPrefixes: [String: String] = [
        "http://www.w3.org/ns/ttml": "tt",
        "http://www.w3.org/ns/ttml#metadata": "ttm",
        "http://www.w3.org/ns/ttml#styling": "tts",
        "http://music.apple.com/lyric-ttml-internal": "itunes",
        "http://www.example.com/ns/amll": "amll",
        "http://www.w3.org/XML/1998/namespace": "xml",
    ]

    static func parse(_ data: Data) throws -> XMLNode {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = builder
        guard parser.parse() else {
            let err = parser.parserError?.localizedDescription ?? "неизвестная ошибка"
            throw LyricsError.parse("XML: \(err) (строка \(parser.lineNumber))")
        }
        guard let root = builder.root else { throw LyricsError.parse("XML: пустой документ") }
        return root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: XMLNode?
        var stack: [XMLNode] = []
        var prefixToURI: [String: String] = ["xml": "http://www.w3.org/XML/1998/namespace"]

        func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) {
            prefixToURI[prefix] = namespaceURI
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String]) {
            var attrs: [String: String] = [:]
            for (k, v) in attributeDict {
                if let colon = k.firstIndex(of: ":") {
                    let prefix = String(k[..<colon])
                    let local = String(k[k.index(after: colon)...])
                    if let uri = prefixToURI[prefix], let canon = XMLTree.canonicalPrefixes[uri] {
                        attrs["\(canon):\(local)"] = v
                    } else {
                        attrs[k] = v
                    }
                } else {
                    attrs[k] = v
                }
            }
            // С включённой обработкой пространств имён elementName — локальное имя, но на всякий случай срежем префикс.
            let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
            let node = XMLNode(name: local, namespace: namespaceURI ?? "", attributes: attrs)
            if let parent = stack.last { parent.children.append(.element(node)) } else { root = node }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            _ = stack.popLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { append(string) }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            append(String(decoding: CDATABlock, as: UTF8.self))
        }
        func parser(_ parser: XMLParser, foundIgnorableWhitespace whitespaceString: String) { append(whitespaceString) }

        private func append(_ s: String) {
            guard let top = stack.last else { return }
            if case .text(let prev)? = top.children.last {
                top.children[top.children.count - 1] = .text(prev + s)
            } else {
                top.children.append(.text(s))
            }
        }
    }
}
