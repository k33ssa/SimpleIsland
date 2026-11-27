import Foundation

// Картинка видео (15.11, пользователь: «нет превью хрома — … либо картинка превью, если это YouTube, либо значок
// видео»). Порядок: обложка от MediaRemote → превью YouTube (id ролика из метаданных MediaRemote или из URL вкладки
// браузера, найденной по заголовку; вкладки — AppleScript с правом «Автоматизация» браузера, без права — пропуск) →
// значок видео (play.rectangle.fill на цвете темы). Сеть — только i.ytimg.com за картинкой, одно скачивание на ролик.

/// Что показать вместо обложки.
enum VideoCover: Equatable {
    case artwork
    case youTubeThumbnail
    case videoIcon

    static func choose(hasArtwork: Bool, hasThumbnail: Bool) -> VideoCover {
        if hasArtwork { return .artwork }
        if hasThumbnail { return .youTubeThumbnail }
        return .videoIcon
    }
}

enum YouTube {
    /// id ролика (11 символов `A–Z a–z 0–9 _ -`) из ссылки: `watch?v=`, `youtu.be/`, `shorts/`, `embed/`, `live/`,
    /// `music.youtube.com/watch?v=`, `m.youtube.com`. Чужие сайты и битые id — nil.
    static func videoId(from s: String) -> String? {
        guard let u = URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines)), let host = u.host?.lowercased() else {
            return nil
        }
        let h = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        var id: String?
        if h == "youtu.be" {
            id = u.pathComponents.dropFirst().first
        } else if h == "youtube.com" || h.hasSuffix(".youtube.com") || h == "youtube-nocookie.com" {
            let parts = Array(u.pathComponents.dropFirst())
            if parts.first == "watch" {
                id = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "v" }?.value
            } else if parts.count >= 2, ["shorts", "embed", "live", "v"].contains(parts[0]) {
                id = parts[1]
            }
        }
        guard let id, isValidId(id) else { return nil }
        return id
    }

    static func isValidId(_ id: String) -> Bool {
        id.count == 11 && id.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "_" || $0 == "-"
        }
    }

    /// Первая ссылка YouTube среди строковых значений метаданных MediaRemote (contentItemIdentifier, URL…).
    static func videoId(inInfo info: [String: Any]) -> String? {
        for (_, v) in info {
            if let s = v as? String, s.contains("youtu"), let id = videoId(from: s) { return id }
        }
        return nil
    }

    static func thumbnailURL(_ id: String) -> URL {
        URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")!
    }

    /// Вкладка браузера с роликом, который играет: среди вкладок YouTube — та, чей заголовок совпадает с названием из
    /// Now Playing («Название - YouTube», «(3) Название - YouTube»). Не совпало — nil (не угадываем).
    static func pickTab(_ tabs: [(url: String, title: String)], nowTitle: String) -> String? {
        let want = normalize(nowTitle)
        guard !want.isEmpty else { return nil }
        for t in tabs {
            guard let id = videoId(from: t.url) else { continue }
            let title = normalize(t.title)
            if title == want || (want.count >= 4 && title.contains(want)) || (title.count >= 4 && want.contains(title)) {
                return id
            }
        }
        return nil
    }

    static func normalize(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in [" - YouTube Music", " - YouTube", " – YouTube"] where t.hasSuffix(suffix) {
            t = String(t.dropLast(suffix.count))
        }
        // «(3) Название» — счётчик уведомлений в заголовке вкладки.
        if t.hasPrefix("("), let close = t.firstIndex(of: ")"), t[t.index(after: t.startIndex)..<close].allSatisfy(\.isNumber) {
            t = String(t[t.index(after: close)...])
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Браузеры, у которых AppleScript отдаёт вкладки (Safari — `name`, Chromium-семейство — `title`).
    static let chromiumBrowsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "com.brave.Browser",
        "com.microsoft.edgemac", "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "org.chromium.Chromium",
        "ru.yandex.desktop.yandex-browser", "com.operasoftware.Opera",
    ]

    /// Скрипт «все вкладки: URL<TAB>заголовок» для браузера; nil — браузер вкладки не отдаёт (Firefox).
    static func tabsScript(bundleId: String) -> String? {
        let titleKey: String
        if bundleId == "com.apple.Safari" || bundleId == "com.apple.SafariTechnologyPreview" {
            titleKey = "name"
        } else if chromiumBrowsers.contains(bundleId) {
            titleKey = "title"
        } else {
            return nil
        }
        return """
        tell application id "\(bundleId)"
            set out to ""
            repeat with w in windows
                repeat with t in tabs of w
                    set u to URL of t
                    if u contains "youtu" then set out to out & u & tab & (\(titleKey) of t) & linefeed
                end repeat
            end repeat
            return out
        end tell
        """
    }

    static func parseTabs(_ s: String) -> [(url: String, title: String)] {
        s.split(separator: "\n").compactMap { line in
            let p = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard p.count == 2 else { return nil }
            return (String(p[0]), String(p[1]))
        }
    }
}
