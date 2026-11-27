import SwiftUI
import IslandCore

/// Модуль «Медиа»: что играет (MediaRemote через свой помощник в /usr/bin/perl, запасной путь — AppleScript
/// Музыки и Spotify), обложка и её цвета → свечение, текст-караоке из LRCLIB, волна-перемотка, AirPlay.
/// Макет — design/mockups/01-media.html, контракт — docs/ARCHITECTURE.md, способы — docs/TECH.md §1.
@MainActor
public final class MediaIslandModule: IslandModule {
    public let id = "media"
    public let title = "Медиа"
    public let systemImage = "music.note"
    public var providesTab: Bool { true }
    /// Плеер — 240; пустые экраны («Ничего не играет», «Нужно разрешение») — по своему контенту 148 pt.
    /// Смена — `invalidateLayout()` из модели.
    public var expandedHeight: CGFloat { model.now == nil ? 150 : 240 }

    let model = MediaModel()

    /// Виджет «Эквалайзер» — отдельная вкладка на той же модели (общий захват звука). Регистрируется рядом
    /// (`ModuleRegistry`), по умолчанию выключен.
    public private(set) lazy var equalizerModule: IslandModule = EqualizerIslandModule(model: model)

    public init() {}

    public func start(context: ModuleContext) {
        guard !context.isSnapshot else { model.context = context; model.isSnapshot = true; return }
        model.start(context: context)
    }

    public func stop() {
        model.stop()
        model.context?.activities.removeAll(moduleId: id)
    }

    public func expandedView() -> AnyView? { AnyView(MediaExpandedView(model: model)) }

    public func settingsView() -> AnyView? { AnyView(MediaSettingsView(model: model)) }

    public func snapshotStates() -> [ModuleSnapshot] {
        let lyrics = MediaMocks.lyrics
        return [
            ModuleSnapshot("playing", presentation: .expanded) { ctx in
                self.prepare(ctx)
                self.model.applyMock(MediaMocks.track(playing: true), placeholder: .warm, lyrics: lyrics, liked: true,
                                     next: "Сигнал из окна")
            },
            // Другая обложка (сине-зелёная) — «Хамелеон» перекрашивает остров под неё (макет 09).
            ModuleSnapshot("playing-cover2", presentation: .expanded) { ctx in
                self.prepare(ctx)
                var t = MediaMocks.track(playing: true)
                t.title = "Зелёная волна"; t.artist = "Лесопарк"; t.album = "Тропинки"; t.badge = nil; t.elapsed = 100
                self.model.applyMock(t, placeholder: .sea, lyrics: lyrics, liked: false,
                                     device: OutputDevice(name: "Динамики MacBook Pro", kind: .builtIn))
            },
            ModuleSnapshot("paused", presentation: .expanded) { ctx in
                self.prepare(ctx)
                var t = MediaMocks.track(playing: false); t.elapsed = 61
                self.model.applyMock(t, placeholder: .sea, lyrics: lyrics)
            },
            ModuleSnapshot("no-artwork", presentation: .expanded) { ctx in
                self.prepare(ctx)
                var t = MediaMocks.track(playing: true)
                t.title = "Радио «Волна»"; t.artist = "Утреннее шоу"; t.album = ""; t.duration = 0; t.elapsed = 37
                t.bundleId = "com.google.Chrome"; t.appName = "Google Chrome"; t.badge = nil
                self.model.applyMock(t, placeholder: nil, lyrics: nil,
                                     device: OutputDevice(name: "Динамики MacBook Pro", kind: .builtIn))
            },
            ModuleSnapshot("long-title", presentation: .expanded) { ctx in
                self.prepare(ctx)
                var t = MediaMocks.track(playing: true)
                t.title = "Очень длинное название песни, которое никак не помещается в одну строку острова"
                t.artist = "Оркестр районного дома культуры и все-все-все"
                t.album = "Полное собрание записей 1987–2026 (расширенное издание)"
                t.badge = "Dolby Atmos"
                self.model.applyMock(t, placeholder: .violet, lyrics: lyrics, liked: false)
            },
            // Видео без обложки в браузере (15.11): значок видео вместо ноты, без текста и волны — просто прогресс.
            ModuleSnapshot("video", presentation: .expanded) { ctx in
                self.prepare(ctx)
                self.model.applyMock(MediaMocks.video(), placeholder: nil, lyrics: nil,
                                     device: OutputDevice(name: "Динамики MacBook Pro", kind: .builtIn))
            },
            ModuleSnapshot("video-compact", presentation: .compact) { ctx in
                self.prepare(ctx)
                self.model.applyMock(MediaMocks.video(), placeholder: nil, lyrics: nil)
            },
            ModuleSnapshot("nothing", presentation: .expanded) { ctx in
                self.prepare(ctx)
                self.model.applyMock(nil, placeholder: nil, lyrics: nil)
            },
            ModuleSnapshot("permission", presentation: .expanded) { ctx in
                self.prepare(ctx)
                self.model.applyMock(nil, placeholder: nil, lyrics: nil,
                                     availability: .needsAutomation(bundleId: MediaApps.music, appName: "Музыка"))
            },
            // Вспышка «новый трек» (по настройке, по умолчанию выкл.): обложка + название, справа исполнитель.
            ModuleSnapshot("track-flash", presentation: .automatic) { ctx in
                self.prepare(ctx)
                let t = MediaMocks.track(playing: true)
                self.model.applyMock(t, placeholder: .warm, lyrics: nil)
                ctx.hud.show(MediaTrackFlash.event(model: self.model, track: t))
            },
            ModuleSnapshot("compact", presentation: .compact) { ctx in
                self.prepare(ctx)
                self.model.applyMock(MediaMocks.track(playing: true), placeholder: .warm, lyrics: lyrics)
            },
            ModuleSnapshot("compact-lyrics", presentation: .compact) { ctx in
                self.prepare(ctx)
                self.model.prefs.compactLyrics = true
                self.model.applyMock(MediaMocks.track(playing: true), placeholder: .warm, lyrics: lyrics)
            },
        ]
    }

    private func prepare(_ ctx: ModuleContext) {
        model.context = ctx
        model.isSnapshot = true
    }
}

/// Мок-данные снимков (имена и текст вымышленные, как в макете 01).
enum MediaMocks {
    static func track(playing: Bool) -> NowPlaying {
        var n = NowPlaying(title: "Полуночный трамвай")
        n.artist = "Северные огни"
        n.album = "Тёплый асфальт"
        n.duration = 207
        n.elapsed = 108.3   // середина выделенного слова «везёт» (снимок: фронт заливки внутри букв)
        n.timestamp = Date()
        n.isPlaying = playing
        n.bundleId = MediaApps.music
        n.appName = "Музыка"
        n.badge = "Lossless"
        n.artworkId = "mock"
        return n
    }

    static func video() -> NowPlaying {
        var n = NowPlaying(title: "Как устроен остров: разбор за 10 минут")
        n.artist = "Мастерская"
        n.duration = 612
        n.elapsed = 205
        n.timestamp = Date()
        n.isPlaying = true
        n.bundleId = "com.google.Chrome"
        n.appName = "Google Chrome"
        return n
    }

    /// Мок-текст пословный (как у QQ/NetEase/AMLL): слова поровну делят время строки, у третьей — фон-вокал.
    static let lyrics: Lyrics = {
        var l = lineLyrics
        for i in l.lines.indices {
            let start = l.lines[i].time
            let end = i + 1 < l.lines.count ? l.lines[i + 1].time - 0.5 : start + 6
            let parts = l.lines[i].text.split(separator: " ").map(String.init)
            let step = (end - start) / Double(max(1, parts.count))
            l.lines[i].words = parts.enumerated().map { k, w in
                LyricWord(text: w, begin: start + Double(k) * step, end: start + Double(k + 1) * step - 0.05)
            }
            l.lines[i].end = end
            if i == 2 { l.lines[i].background = [LyricWord(text: "в никуда", begin: end - 0.4, end: end)] }
        }
        return l
    }()

    static let lineLyrics = Lyrics(lines: LRC.parse("""
    [01:31.00]мы выходим из дома в полночь
    [01:38.50]и фонари считают нас по одному
    [01:45.00]пока трамвай везёт нас в никуда
    [01:53.00]а город спит, и нам не нужно спать
    [02:01.00]на последней остановке — море
    """))
}
