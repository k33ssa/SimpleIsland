import Foundation

/// Ссылка на видеовстречу, найденная в событии календаря.
struct MeetingLink: Equatable, Sendable {
    var service: String
    var url: URL
}

/// Поиск ссылки на встречу регэкспами по url / location / notes (первое совпадение в этом порядке полей;
/// внутри поля — по порядку сервисов). Регэкспы — заготовки по докам сервисов (docs/TECH.md §7), на реальных
/// приглашениях проверить.
enum MeetingLinks {
    private static let tail = #"[^\s"'<>\)\]]*"#

    static let patterns: [(service: String, regex: NSRegularExpression)] = {
        let raw: [(String, String)] = [
            ("Zoom", #"https://[\w.-]*zoom\.us/(?:j|my|w|wc/join|s)/"# + tail),
            ("Zoom", #"zoommtg://"# + tail),
            ("Google Meet", #"https://meet\.google\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}"# + tail),
            ("Teams", #"https://teams\.(?:microsoft|live)\.com/(?:l/meetup-join|meet|v2)/"# + tail),
            ("Teams", #"msteams://"# + tail),
            ("Телемост", #"https://telemost\.(?:yandex\.(?:ru|com)|360\.yandex\.(?:ru|com))/j/\d+"# + tail),
            ("Яндекс", #"https://(?:[\w-]+\.)?yandex\.(?:ru|com)/(?:telemost|meet)/"# + tail),
            ("Контур.Толк", #"https://[\w-]+\.ktalk\.ru/"# + tail),
            ("Jitsi", #"https://(?:meet\.jit\.si|jitsi\.[\w.-]+|[\w.-]+/jitsi)/[\w-]+"# + tail),
        ]
        return raw.compactMap { s, p in
            (try? NSRegularExpression(pattern: p, options: [.caseInsensitive])).map { (s, $0) }
        }
    }()

    /// Первая ссылка встречи в полях события.
    static func find(url: URL?, location: String?, notes: String?) -> MeetingLink? {
        for field in [url?.absoluteString, location, notes] {
            guard let text = field, !text.isEmpty else { continue }
            if let m = find(in: text) { return m }
        }
        return nil
    }

    static func find(in text: String) -> MeetingLink? {
        let ns = text as NSString
        var best: (loc: Int, link: MeetingLink)?
        for (service, re) in patterns {
            guard let r = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { continue }
            var s = ns.substring(with: r.range)
            while let last = s.last, ".,;:!?".contains(last) { s.removeLast() }
            guard let url = URL(string: s) else { continue }
            // В тексте берём самую раннюю ссылку, а не первую по списку сервисов.
            if best == nil || r.range.location < best!.loc { best = (r.range.location, MeetingLink(service: service, url: url)) }
        }
        return best?.link
    }

    /// Для Zoom — схема приложения, если оно стоит (открывает сразу клиент, без страницы в браузере).
    static func preferredOpenURL(_ link: MeetingLink, zoomAppInstalled: Bool) -> URL {
        guard link.service == "Zoom", zoomAppInstalled, link.url.scheme == "https",
              let comps = URLComponents(url: link.url, resolvingAgainstBaseURL: false) else { return link.url }
        let parts = comps.path.split(separator: "/")
        guard parts.count >= 2, parts[0] == "j" else { return link.url }
        var out = URLComponents()
        out.scheme = "zoommtg"; out.host = comps.host; out.path = "/join"
        var q = [URLQueryItem(name: "action", value: "join"), URLQueryItem(name: "confno", value: String(parts[1]))]
        if let pwd = comps.queryItems?.first(where: { $0.name == "pwd" })?.value { q.append(URLQueryItem(name: "pwd", value: pwd)) }
        out.queryItems = q
        return out.url ?? link.url
    }
}
