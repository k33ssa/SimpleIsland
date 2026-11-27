import AppKit
import IslandCore
import SwiftUI

// --- keys --- Медиаклавиши ⏯ ⏭ ⏮ — музыке (15.11: «сделай клавиши чисто для музыки в приоритете всегда, причём для
// последнего приложения, где играла»). macOS отдаёт их «последнему Now Playing»: поставленное на паузу видео в Chrome
// перехватывает их у Музыки. Tap — в HUD (Универсальный доступ), сюда нажатия приходят через `MediaKeyRouter` ядра.
// Решение — чистая функция `MediaKeyRouting.decide` (самотест), исполнение — `MediaKeyController`.

/// Куда отдают медиаклавиши (настройка «Медиа»).
enum MediaKeysTarget: String, Codable, CaseIterable, Sendable {
    /// Последнее приложение, где реально играла музыка.
    case lastMusicApp
    /// Как в системе (последний Now Playing).
    case system

    var title: String {
        switch self {
        case .lastMusicApp: return "Последнее музыкальное приложение"
        case .system: return "Как в системе"
        }
    }
}

/// Какие приложения — «музыкальные» (запоминаются как цель медиаклавиш).
enum MusicApps {
    /// Известные плееры музыки. Кроме Музыки и Spotify bundle id — по документации/памяти, на этой машине не
    /// установлены [не проверено 15.11]; лишний id ничего не ломает, недостающий — помогает эвристика `qualifies`.
    static let known: [String: String] = [
        MediaApps.music: "Музыка",
        MediaApps.spotify: "Spotify",
        "ru.yandex.desktop.music": "Яндекс Музыка",
        "ru.yandex.music": "Яндекс Музыка",
        "com.vk.vkmusic": "VK Музыка",
        "com.vk.music": "VK Музыка",
        "com.deezer.deezer-desktop": "Deezer",
        "com.tidal.desktop": "TIDAL",
        "com.audirvana.Audirvana-Studio": "Audirvana",
        "com.audirvana.Audirvana-Plus": "Audirvana",
        "com.audirvana.Audirvana-Origin": "Audirvana",
        "com.audirvana.Audirvana": "Audirvana",
        "com.swinsian.Swinsian": "Swinsian",
        "com.coppertino.Vox": "VOX",
        "co.brushedtype.doppler-macos": "Doppler",
        "tv.plex.plexamp": "Plexamp",
        "com.qobuz.QobuzDesktop": "Qobuz",
        "com.amazon.music": "Amazon Music",
        "com.github.th-ch.youtube-music": "YouTube Music",
        "org.cogx.cog": "Cog",
        "com.roon.Roon": "Roon",
        "com.foobar2000.mac": "foobar2000",
    ]

    /// Управляются AppleScript (`playpause`, `next track`…), остальные — через MediaRemote помощника.
    static func scriptable(_ b: String) -> Bool { b == MediaApps.music || b == MediaApps.spotify }

    /// Это музыка, а не видео: известный плеер; иначе — не браузер (вкладку с видео от вкладки с музыкой не отличить, и
    /// команда ушла бы тому же браузеру), не видеоплеер и источник сам назвал это музыкой.
    static func qualifies(_ n: NowPlaying) -> Bool {
        guard let b = n.bundleId, !b.isEmpty else { return false }
        if known[b] != nil { return true }
        // Песня в браузере (Яндекс Музыка, YouTube Music, SoundCloud: исполнитель + альбом, не видео) — тоже музыка
        // (23.11: «музыка в Яндексе, а по клавише играет Apple»: после паузы браузера macOS отдавала Now Playing
        // Музыке, и клавиша уходила ей).
        if MediaKind.isBrowser(b) { return !n.isVideo && n.isMusicContent }
        if MediaKind.videoApps.contains(b) || n.isVideo { return false }
        let mt = n.mediaType.lowercased()
        return mt.contains("music")
    }
}

/// Что сделать с нажатием.
enum MediaKeyRoute: Equatable {
    /// Отдать системе (не глотать). `reason` — для журнала и самотеста.
    case system(String)
    /// Система и так отдаст клавишу музыкальному приложению (оно — текущий Now Playing): не глотаем, только вспышка.
    case passThrough(String)
    /// Глотаем, команду — AppleScript (Музыка, Spotify).
    case script(String)
    /// Глотаем, команду — помощнику MediaRemote с bundle id (`sendto`).
    case remote(String)
    /// Глотаем и просим «Автоматизацию» (Музыка/Spotify), после разрешения — команда.
    case needsPermission(String)

    var swallows: Bool {
        switch self {
        case .system, .passThrough: return false
        case .script, .remote, .needsPermission: return true
        }
    }

    var bundle: String? {
        switch self {
        case .system: return nil
        case .passThrough(let b), .script(let b), .remote(let b), .needsPermission(let b): return b
        }
    }
}

enum MediaKeyRouting {
    struct Inputs {
        var enabled: Bool
        /// Последнее музыкальное приложение (bundle id).
        var lastMusic: String?
        var lastMusicRunning: Bool
        /// Текущий системный Now Playing (MediaRemote) — ему система отдаст клавишу.
        var current: NowPlaying?
        /// MediaRemote работает (знаем, что играет в системе). Нет — не знаем, не играет ли видео: не вмешиваемся.
        var systemKnown: Bool
        /// Право «Автоматизация» для `lastMusic` (nil — ещё не проверяли).
        var automation: PermissionStatus?
        /// Помощник умеет `sendto` (MRMediaRemoteSendCommandToApp нашёлся и не ломался).
        var canSendToApp: Bool
        /// Клавишей ⏯ недавно поставили на паузу НЕ музыку (видео, другой звук) — bundle id (18.11: «жму стоп на
        /// видео, а повторный стоп включает музыку»). Пока это приложение — текущий Now Playing на паузе, ⏯ — ему.
        var pausedOther: String? = nil
    }

    static func decide(_ i: Inputs) -> MediaKeyRoute {
        guard i.enabled else { return .system("выключено") }
        guard i.systemKnown else { return .system("MediaRemote недоступен") }
        guard let last = i.lastMusic, !last.isEmpty else { return .system("музыка ещё не играла") }
        guard i.lastMusicRunning else { return .system("музыкальное приложение закрыто") }
        if let c = i.current, c.bundleId == last { return .passThrough(last) }
        if let c = i.current, c.isPlaying {
            // Реально ИГРАЕТ что-то другое (видео — прямо по просьбе; и любой другой звук): пауза должна остановить его,
            // а не запустить музыку поверх.
            return .system(c.isVideo ? "играет видео" : "играет другое приложение")
        }
        if let c = i.current, let p = i.pausedOther, c.bundleId == p, !c.isPlaying {
            return .system("продолжить то, что поставили на паузу клавишей")
        }
        if MusicApps.scriptable(last) {
            switch i.automation {
            case .granted?: return .script(last)
            case .denied?: return .system("нет права «Автоматизация»")
            default: return .needsPermission(last)
            }
        }
        return i.canSendToApp ? .remote(last) : .system("помощник не умеет команду приложению")
    }
}

/// Команда цели.
enum MediaKeyCommand: Equatable {
    case toggle, next, previous
    /// Начать/закончить перемотку (Музыка: `fast forward`/`rewind` → `resume`; MediaRemote: begin/end FF/RW).
    case seekBegin(forward: Bool), seekEnd(forward: Bool)
    /// Шаг позиции (Spotify при удержании: своей перемотки у него нет).
    case step(Double)
}

/// Нажатия → команды. Короткое ⏭/⏮ — трек (по отпусканию), удержание дольше `holdDelay` — перемотка до отпускания.
@MainActor
final class MediaKeyController {
    /// Удержание: столько держать ⏭/⏮, чтобы началась перемотка.
    static let holdDelay: TimeInterval = 0.45
    /// Шаг Spotify при удержании и период шага.
    static let spotifyStep: Double = 10
    static let spotifyStepPeriod: TimeInterval = 0.5
    /// Страховка: отпускания не было (tap пересоздали во время удержания) — закончить перемотку.
    static let holdLimit: TimeInterval = 30

    /// Входы для решения (модель подставляет живые, самотест — свои).
    var inputs: () -> MediaKeyRouting.Inputs = {
        .init(enabled: false, lastMusic: nil, lastMusicRunning: false, current: nil, systemKnown: false,
              automation: nil, canSendToApp: false)
    }
    /// Исполнить команду (модель: AppleScript / помощник; самотест — заглушка).
    var perform: (MediaKeyCommand, MediaKeyRoute) -> Void = { _, _ in }
    /// Показать отклик (модель: вспышка с обложкой).
    var feedback: (MediaKeyCommand, String) -> Void = { _, _ in }
    /// Попросить «Автоматизацию»; `done(true)` — разрешили.
    var requestPermission: (String, @escaping @MainActor (Bool) -> Void) -> Void = { _, done in done(false) }

    private struct Press {
        var route: MediaKeyRoute
        var seeking = false
        /// Нажатие ушло на запрос права: отпускание ничего не шлёт (команда — после разрешения).
        var permissionOnly = false
        var work: DispatchWorkItem?
        var limit: DispatchWorkItem?
    }
    private var presses: [MediaTransportKey: Press] = [:]
    /// Последнее решение (самотест, журнал).
    private(set) var lastRoute: MediaKeyRoute?
    /// ⏯ поставил на паузу не музыку (`.system` при играющем другом приложении): кому и когда. Живёт 30 мин;
    /// снимается, как только ⏯ ушёл музыке.
    private(set) var pausedOther: (bundle: String, at: Date)?
    static let pausedOtherTTL: TimeInterval = 30 * 60
    func forgetPausedOtherForTest() { pausedOther = nil }

    /// Отложенные дела (в покое — 0).
    var pendingWork: Int { presses.values.reduce(0) { $0 + ($1.work != nil ? 1 : 0) + ($1.limit != nil ? 1 : 0) } }

    func handle(_ p: MediaTransportPress) -> Bool {
        switch p.phase {
        case .down: return down(p.key)
        case .repeating: return presses[p.key] != nil
        case .up: up(p.key); return presses[p.key] == nil
        }
    }

    private func down(_ key: MediaTransportKey) -> Bool {
        if presses[key] != nil { finish(key) }   // нажатие без отпускания (потерянное событие) — закрыть прежнее
        var inp = inputs()
        if let po = pausedOther, Date().timeIntervalSince(po.at) < Self.pausedOtherTTL { inp.pausedOther = po.bundle }
        else { pausedOther = nil }
        let route = MediaKeyRouting.decide(inp)
        lastRoute = route
        if key == .playPause {
            switch route {
            case .system:
                // ⏯ ушёл системе, пока играло другое приложение, — оно встаёт на паузу: запомнить, чтобы следующее
                // ⏯ продолжило его, а не включило музыку. «Продолжить» — продлить запоминание.
                if let c = inp.current, let b = c.bundleId, c.bundleId != inp.lastMusic { pausedOther = (b, Date()) }
            case .script, .remote, .passThrough, .needsPermission:
                pausedOther = nil
            }
        }
        switch route {
        case .system:
            return false
        case .passThrough(let b):
            // Система сама сделает трек/перемотку; отклик — только на ⏯ и короткие ⏭/⏮ (удержания не видим).
            feedback(command(for: key), b)
            return false
        case .needsPermission(let b):
            let cmd = command(for: key)
            requestPermission(b) { [weak self] ok in
                guard let self, ok else { return }
                self.feedback(cmd, b)   // отклик — до команды: подпись «Пауза/Играет» по состоянию ДО нажатия
                self.perform(cmd, .script(b))
            }
            presses[key] = Press(route: route, permissionOnly: true)
            return true
        case .script, .remote:
            var press = Press(route: route)
            if key == .playPause {
                feedback(.toggle, route.bundle ?? "")
                perform(.toggle, route)
            } else {
                let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.beginSeek(key) } }
                press.work = w
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdDelay, execute: w)
            }
            let limit = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.finish(key) } }
            press.limit = limit
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdLimit, execute: limit)
            presses[key] = press
            return true
        }
    }

    private func up(_ key: MediaTransportKey) {
        guard let p = presses[key] else { return }
        if key != .playPause, !p.seeking, !p.permissionOnly {
            let cmd = command(for: key)
            feedback(cmd, p.route.bundle ?? "")
            perform(cmd, p.route)
        }
        finish(key)
    }

    /// Закончить нажатие: снять отложенное, остановить перемотку.
    private func finish(_ key: MediaTransportKey) {
        guard let p = presses.removeValue(forKey: key) else { return }
        p.work?.cancel(); p.limit?.cancel()
        if p.seeking, !isSpotify(p.route) { perform(.seekEnd(forward: key == .next), p.route) }
    }

    private func beginSeek(_ key: MediaTransportKey) {
        guard var p = presses[key] else { return }
        p.seeking = true
        p.work = nil
        let forward = key == .next
        if isSpotify(p.route) {
            presses[key] = p
            stepSpotify(key)
        } else {
            perform(.seekBegin(forward: forward), p.route)
            presses[key] = p
        }
        feedback(.seekBegin(forward: forward), p.route.bundle ?? "")
    }

    private func stepSpotify(_ key: MediaTransportKey) {
        guard var p = presses[key], p.seeking else { return }
        perform(.step(key == .next ? Self.spotifyStep : -Self.spotifyStep), p.route)
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.stepSpotify(key) } }
        p.work = w
        presses[key] = p
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.spotifyStepPeriod, execute: w)
    }

    private func isSpotify(_ r: MediaKeyRoute) -> Bool {
        if case .script(let b) = r { return b == MediaApps.spotify }
        return false
    }

    private func command(for key: MediaTransportKey) -> MediaKeyCommand {
        switch key {
        case .playPause: return .toggle
        case .next: return .next
        case .previous: return .previous
        }
    }

    /// Остановка модуля: отложенное снять, начатую перемотку закончить.
    func reset() {
        for k in Array(presses.keys) { finish(k) }
    }
}

// MARK: - Отклик в острове

enum MediaKeyFlash {
    static let labelChars = 18
    static let trailingChars = 20

    /// Подпись действия: «Пауза» / «Играет» / «Следующий трек»…
    static func label(_ c: MediaKeyCommand, wasPlaying: Bool?) -> String {
        switch c {
        case .toggle: return wasPlaying == true ? "Пауза" : "Играет"
        case .next: return "Следующий трек"
        case .previous: return "Предыдущий трек"
        case .seekBegin(let f), .seekEnd(let f): return f ? "Перемотка вперёд" : "Перемотка назад"
        case .step(let s): return s >= 0 ? "Перемотка вперёд" : "Перемотка назад"
        }
    }

    static func systemImage(_ c: MediaKeyCommand, wasPlaying: Bool?) -> String {
        switch c {
        case .toggle: return wasPlaying == true ? "pause.fill" : "play.fill"
        case .next: return "forward.end.fill"
        case .previous: return "backward.end.fill"
        case .seekBegin(let f), .seekEnd(let f): return f ? "forward.fill" : "backward.fill"
        case .step(let s): return s >= 0 ? "forward.fill" : "backward.fill"
        }
    }

    /// Вспышка: слева обложка + действие, справа — трек (для ⏯) или приложение.
    static func event(label: String, symbol: String, trailing: String, cover: NSImage?) -> HUDEvent {
        let l = ToolClip.clip(label, labelChars)
        let t = ToolClip.clip(trailing, trailingChars)
        let side = min(190, max(120, CGFloat(max(l.count * 7 + 27, t.count * 7)) + 30))
        var e = HUDEvent(kind: "media.key", sideWidth: side,
                         customLeading: AnyView(MediaKeyFlashLeading(cover: cover, symbol: symbol, title: l)),
                         customTrailing: t.isEmpty ? nil : AnyView(TrackFlashTrailing(text: t)))
        e.accessibilityLabel = [l, t].filter { !$0.isEmpty }.joined(separator: ": ")
        return e
    }
}

struct MediaKeyFlashLeading: View {
    var cover: NSImage?
    var symbol: String
    var title: String
    @Environment(\.islandTheme) private var theme
    var body: some View {
        HStack(spacing: 7) {
            if let cover {
                Image(nsImage: cover).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 20, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: theme.mediaRadius(5), style: .continuous))
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: symbol).font(.system(size: 7, weight: .bold)).foregroundStyle(.white)
                            .padding(2).background(Circle().fill(.black.opacity(0.6))).offset(x: 3, y: 3)
                    }
            } else {
                Image(systemName: symbol).font(.system(size: 12, weight: .bold)).foregroundStyle(theme.primary)
                    .frame(width: 20, height: 20)
            }
            Text(title).font(theme.font(12.5, .bold)).foregroundStyle(theme.primary).lineLimit(1)
        }
        .accessibilityHidden(true)
    }
}
