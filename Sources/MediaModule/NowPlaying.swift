import AppKit
import Foundation

/// Откуда брать «что играет» (настройка модуля).
public enum MediaSourcePreference: String, Codable, CaseIterable, Sendable {
    /// MediaRemote (любое приложение); если он недоступен — AppleScript для Музыки и Spotify.
    case auto
    /// Только Музыка (MediaRemote, иначе AppleScript).
    case music
    /// Только Spotify (MediaRemote, иначе AppleScript).
    case spotify
    /// Любое приложение, только MediaRemote (браузеры, плееры), без AppleScript.
    case any

    public var title: String {
        switch self {
        case .auto: return "Авто"
        case .music: return "Музыка"
        case .spotify: return "Spotify"
        case .any: return "Любой"
        }
    }

    /// Bundle id, которым ограничен источник; nil — любое приложение.
    var bundleFilter: String? {
        switch self {
        case .music: return MediaApps.music
        case .spotify: return MediaApps.spotify
        case .auto, .any: return nil
        }
    }
}

enum MediaApps {
    static let music = "com.apple.Music"
    static let spotify = "com.spotify.client"
}

/// Музыка или видео — по признакам из Now Playing (чистая функция, самотест).
enum MediaKind {
    /// Видеоплееры: всё, что они играют, — видео.
    static let videoApps: Set<String> = [
        "com.colliderli.iina", "com.apple.QuickTimePlayerX", "com.apple.TV", "org.videolan.vlc", "io.mpv",
        "com.firecore.infuse", "tv.plex.desktop", "com.netflix.Netflix", "com.apple.FinalCut", "com.apple.iMovieApp",
        "com.movist.MovistPro", "com.elmedia.player",
    ]
    /// Браузеры (bundle id или его начало): без альбома — почти всегда видео (YouTube, Кинопоиск, VK Видео);
    /// музыкальные сайты (YouTube Music, Яндекс Музыка) альбом сообщают.
    static let browserPrefixes = [
        "com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox", "company.thebrowser", "com.microsoft.edgemac",
        "com.brave.Browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "ru.yandex.desktop.yandex-browser",
        "app.zen-browser.zen", "org.chromium.Chromium", "com.kagi.kagimacOS",
    ]

    static func isBrowser(_ b: String?) -> Bool {
        guard let b else { return false }
        return browserPrefixes.contains { b == $0 || b.hasPrefix($0 + ".") || b.hasPrefix($0) }
    }

    static func isVideo(mediaType: String, bundleId: String?, album: String) -> Bool {
        let mt = mediaType.lowercased()
        // MediaRemote: «MRMediaRemoteMediaTypeVideo» / «…Music» / «…Podcast» и т. п. — источник сказал сам.
        if mt.contains("video") || mt.contains("movie") || mt.contains("tvshow") { return true }
        if mt.contains("music") || mt.contains("audio") || mt.contains("podcast") { return false }
        guard let b = bundleId else { return false }
        if b == MediaApps.music || b == MediaApps.spotify { return false }
        if videoApps.contains(b) { return true }
        if isBrowser(b) { return album.trimmingCharacters(in: .whitespaces).isEmpty }
        return false
    }
}

/// Что сейчас играет. Позиция не опрашивается: `elapsed` замерено в `timestamp`, дальше — по `rate`.
struct NowPlaying: Equatable {
    var title: String
    var artist: String = ""
    var album: String = ""
    /// Длительность, с. 0 — неизвестна (радио, прямой эфир).
    var duration: Double = 0
    /// Позиция в момент `timestamp`, с.
    var elapsed: Double = 0
    var timestamp: Date = Date()
    /// Скорость воспроизведения, пока играет (1 — обычная). На паузе MediaRemote отдаёт 0.
    var rate: Double = 1
    var isPlaying: Bool = false
    var bundleId: String?
    var appName: String?
    /// Идентификатор обложки (хеш данных): сменился — перекодировать картинку.
    var artworkId: String?
    /// Бейдж качества («Lossless», «Dolby Atmos»), если известен.
    var badge: String?
    /// Откуда пришло: MediaRemote или AppleScript.
    var viaScript: Bool = false
    /// `MediaType` из MediaRemote («MRMediaRemoteMediaTypeMusic»…), пусто — не сообщили.
    var mediaType: String = ""
    /// pid процесса, который сообщил «что играет» (MediaRemote; у браузера — приложение или его помощник).
    /// Нужен захвату звука (tap только на плеер), nil — неизвестен (AppleScript).
    var pid: Int32?
    /// id ролика YouTube, если MediaRemote отдал ссылку в метаданных (браузер обычно не отдаёт — тогда вкладки).
    var youTubeId: String?
    /// Источник сам сказал «это поток»: MediaRemote `IsAlwaysLive`/`IsLiveStream` или AppleScript Музыки/Spotify
    /// вернул длительность `missing value` (радиостанция, URL-трек).
    var liveFlag: Bool = false

    /// Ключ трека: смена — новый трек (текст песни, волна).
    var trackKey: String { "\(artist)\u{1F}\(title)\u{1F}\(album)" }

    /// Позиция сейчас (или в момент `date`), с — без опроса плеера.
    func position(at date: Date = Date()) -> Double {
        var p = elapsed
        if isPlaying { p += date.timeIntervalSince(timestamp) * (rate > 0 ? rate : 1) }
        if duration > 0 { p = min(p, duration) }
        return max(0, p)
    }

    var isMusicApp: Bool { bundleId == MediaApps.music }
    var isSpotify: Bool { bundleId == MediaApps.spotify }
    /// Музыкальный плеер (Музыка, Spotify) или источник сам назвал это музыкой — искать текст песни.
    /// Песня, для которой ищется текст. Кроме музыкальных плееров — любая запись с исполнителем и альбомом, если это не
    /// видео (21.11: в Chrome играла Яндекс Музыка — «Претендент На Убийство», Aarne, VILLIAN, — а текста не было:
    /// браузер не ставит MediaType «music»). Остальное — настройкой «…и для браузеров и других плееров».
    var isMusicContent: Bool {
        if isMusicApp || isSpotify || mediaType.localizedCaseInsensitiveContains("music") { return true }
        if let b = bundleId, MusicApps.known[b] != nil { return true }
        return !isVideo && !artist.isEmpty && !album.isEmpty && (duration <= 0 || duration < 15 * 60)
    }
    /// Видео, а не песня (15.11: «при проигрывании видео следует указывать не значок ноты»): показываем кадр
    /// (обложку источника) или значок приложения с ▶, без текста песни и волны — просто прогресс.
    var isVideo: Bool { MediaKind.isVideo(mediaType: mediaType, bundleId: bundleId, album: album) }

    /// Шкала времени: обычный трек / прямой эфир / длительность пока неизвестна (`PlaybackTimeline.decide`).
    var timeline: PlaybackTimeline {
        PlaybackTimeline.decide(duration: duration, liveFlag: liveFlag, elapsed: elapsed,
                                musicPlayer: isMusicApp || isSpotify)
    }
    /// Прямой эфир — только настоящий поток (см. `PlaybackTimeline`), не «длительность не пришла».
    var isLive: Bool { timeline == .live }

    /// Подзаголовок: «Исполнитель — «Альбом»».
    var subtitle: String {
        switch (artist.isEmpty, album.isEmpty) {
        case (false, false): return "\(artist) — «\(album)»"
        case (false, true): return artist
        case (true, false): return "«\(album)»"
        case (true, true): return appName ?? ""
        }
    }
}

/// Что показывать под текстом: волну с прогрессом, метку «Прямой эфир» или только прошедшее время.
///
/// До 16.11 «прямым эфиром» считалось всё с `duration <= 0` — и обычная песня Музыки, для которой MediaRemote не
/// прислал `Duration`, показывалась как эфир (скрин пользователя: «College — BenjiCold»). Теперь:
/// * длительность есть хоть из одного источника (MediaRemote, AppleScript того же трека — подмешивает
///   `MediaModel.mergeScript`) → `.timed`;
/// * источник сам сказал «поток» (`liveFlag`) → `.live`;
/// * не Музыка/Spotify, позиция идёт, а длительности нет (радио/стрим в браузере, плеере) → `.live`;
/// * Музыка/Spotify без длительности и без признака потока (MediaRemote не прислал, AppleScript ещё не ответил
///   или нет права «Автоматизация») → `.unknown`: только прошедшее время, без метки эфира.
enum PlaybackTimeline: Equatable {
    case timed, live, unknown

    static func decide(duration: Double, liveFlag: Bool, elapsed: Double, musicPlayer: Bool) -> PlaybackTimeline {
        if duration > 0 { return .timed }
        if liveFlag { return .live }
        if !musicPlayer && elapsed > 0 { return .live }
        return .unknown
    }
}

/// Устройство вывода звука (чип в плеере).
struct OutputDevice: Equatable {
    enum Kind: Equatable { case builtIn, bluetooth, airPlay, display, usb, other }
    var name: String
    var kind: Kind

    var systemImage: String {
        let n = name.lowercased()
        if n.contains("airpods max") { return "airpodsmax" }
        if n.contains("airpods pro") { return "airpodspro" }
        if n.contains("airpods") { return "airpods" }
        if n.contains("науш") || n.contains("headphone") { return "headphones" }
        if n.contains("homepod") { return "homepod" }
        if n.contains("speaker") || n.contains("колонк") || n.contains("boombox") { return "hifispeaker" }
        switch kind {
        case .builtIn: return "laptopcomputer"
        case .bluetooth: return "headphones"
        case .airPlay: return "airplayaudio"
        case .display: return "display"
        case .usb: return "hifispeaker"
        case .other: return "speaker.wave.2"
        }
    }
}

/// Почему плеер не может показать трек.
enum MediaAvailability: Equatable {
    case ok
    /// Нужно разрешение «Автоматизация» для приложения (`bundleId`).
    case needsAutomation(bundleId: String, appName: String)
    /// Нет ни MediaRemote-помощника, ни подходящего плеера.
    case unavailable(String)
}

/// Время «1:48» / «1:02:03».
func formatTime(_ t: Double) -> String {
    guard t.isFinite, t >= 0 else { return "0:00" }
    let s = Int(t.rounded(.down))
    if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) }
    return String(format: "%d:%02d", s / 60, s % 60)
}

/// Имя приложения по bundle id/pid (для подписи «Играет в Chrome»).
@MainActor
func appDisplayName(bundleId: String?, pid: Int32?) -> String? {
    if let pid, pid > 0, let app = NSRunningApplication(processIdentifier: pid), let n = app.localizedName { return n }
    if let b = bundleId {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: b).first, let n = app.localizedName {
            return n
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
    }
    return nil
}
