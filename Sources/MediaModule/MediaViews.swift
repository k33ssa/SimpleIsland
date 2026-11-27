import AppKit
import AVKit
import Combine
import IslandCore
import SwiftUI

// Вкладка «Медиа» по макету 01 (design/mockups/01-media.html): обложка 148 pt, название/исполнитель, строка
// текста-караоке, волна-перемотка, время, ряд кнопок. Цвета и шрифт — из темы.

/// Цвета плеера под тему: в «Хамелеоне» акцент — из обложки.
@MainActor
struct MediaColors {
    var theme: Theme
    var palette: [ArtworkPalette.RGB]

    /// Тема берёт цвета из обложки («Хамелеон»: `background.source = artwork`).
    var usesArtwork: Bool { theme.background.source == .artwork && !palette.isEmpty }

    /// Кнопка «играть» в «Хамелеоне» — акцент обложки (макет 09: `.cham .pl`), значок — тёмный оттенок фона.
    var playFill: Color? {
        guard usesArtwork, let a = ArtworkPalette.accent(palette) else { return nil }
        let (h, s, _) = a.hsb
        return ArtworkPalette.RGB.hsb(h, min(1, max(0.45, s)), 0.95).color
    }
    var playIcon: Color? {
        guard usesArtwork, let a = ArtworkPalette.accent(palette) else { return nil }
        let (h, s, _) = a.hsb
        return ArtworkPalette.RGB.hsb(h, min(1, s + 0.2), 0.18).color
    }

    /// Заливка проигранной части волны / эквалайзера.
    var played: [Color] {
        if usesArtwork {
            let a = ArtworkPalette.glow(palette)
            return [a[0], a.count > 1 ? a[1] : a[0]]
        }
        if theme.id == "obsidian" { return [Color(hex: "#FFD36E"), theme.accent2Color] }   // как в макете 01
        return [theme.accentColor, theme.accent2Color]
    }

    var unplayed: Color { theme.primary.opacity(0.18) }
    /// Соседние строки текста (`--ink4` в макете). На светлых темах (paper, sakura) плотнее — иначе сливаются.
    var dimLine: Color { theme.primary.opacity(theme.isLight ? 0.45 : 0.32) }
}

extension Theme {
    /// Тема «8 бит» (`effects.pixelated`): вместо скруглений — почти прямые углы, как у контура острова.
    func mediaRadius(_ r: CGFloat) -> CGFloat { effects.pixelated ? min(r, 4) : r }
}

/// Круг или, в пиксельной теме, квадрат с углом 4 pt.
struct MediaRoundShape: Shape {
    var pixelated: Bool
    func path(in rect: CGRect) -> Path {
        pixelated ? RoundedRectangle(cornerRadius: 4, style: .continuous).path(in: rect) : Circle().path(in: rect)
    }
}

struct MediaExpandedView: View {
    @ObservedObject var model: MediaModel
    @Environment(\.islandTheme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        Group {
            if let n = model.now {
                PlayerView(model: model, now: n)
            } else {
                EmptyPlayerView(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // NSView в снимке (ImageRenderer) не рисуется — там и не нужен.
        .background { if !isSnapshot { ViewRef { model.tabView = $0 } } }
        .onAppear { model.expandedDidAppear() }
    }
}

/// Ссылка на NSView вкладки (где она на экране — для «курсор над островом»).
private struct ViewRef: NSViewRepresentable {
    var set: (NSView) -> Void
    func makeNSView(context: Context) -> NSView { let v = NSView(); DispatchQueue.main.async { set(v) }; return v }
    func updateNSView(_ v: NSView, context: Context) {}
}

// MARK: - Плеер

private struct PlayerView: View {
    @ObservedObject var model: MediaModel
    var now: NowPlaying
    @Environment(\.islandTheme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.islandMotion) private var motion

    var body: some View {
        let colors = MediaColors(theme: theme, palette: model.palette)
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 22) {
                CoverView(image: model.coverImage, placeholder: model.placeholderArtwork, size: 148, radius: theme.mediaRadius(22),
                          shadow: model.glowColors?.first, appBadge: appSymbol, videoIcon: now.isVideo)
                    .contentShape(Rectangle())
                    .onTapGesture { model.revealSource() }
                    .help("Открыть трек в приложении")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("Открыть трек в приложении")
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 10) {
                        Text(now.title)
                            .font(theme.font(22, .bold))
                            .foregroundStyle(theme.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if let b = now.badge { Chip(b).fixedSize() }
                        Spacer(minLength: 0)
                    }
                    Text(now.subtitle)
                        .font(theme.font(14, .medium))
                        .foregroundStyle(theme.tertiary)
                        .lineLimit(1)
                        .padding(.top, 3)
                    // Строка текста, волна и время меняются со временем — только они в TimelineView,
                    // и только пока играет и видно (вкладка существует лишь в раскрытом острове), и только при
                    // `islandMotion == .full`. «Уменьшить движение»/батарея — раз в секунду от SharedTicker (время и
                    // волна идут, караоке-заливка шагает по секундам); окно не видно (`.off`) — ни одного кадра.
                    // Кадры — только в моменты, когда видимое меняется (`PlaybackSchedule`: секунда времени, граница
                    // полоски волны, начало строки текста), ~1 раз в секунду; плавную заливку караоке ведёт Core
                    // Animation (`KaraokeSweep`), без кадров SwiftUI. Было 15 к/с всей секции: 12–13 % CPU,
                    // 160 пробуждений/с в раскрытом «Медиа» (замер 14.11, debug).
                    if now.isPlaying && !isSnapshot && motion.allowsContinuousAnimation {
                        TimelineView(PlaybackSchedule(now: now, lyrics: model.lyrics,
                                                      bars: WaveformScrubber.barCount)) { tl in
                            TimedSection(model: model, now: now, colors: colors, date: tl.date, smoothKaraoke: true)
                        }
                    } else if now.isPlaying && !isSnapshot && motion == .reduced {
                        SecondTicking { date in
                            TimedSection(model: model, now: now, colors: colors, date: date)
                        }
                    } else {
                        TimedSection(model: model, now: now, colors: colors, date: Date())
                    }
                }
                .frame(height: 168)
            }
            // Кнопка «играть» с кольцом — 64 pt: ряд такой же высоты, иначе кольцо срезается краем вкладки.
            ControlsRow(model: model, now: now)
                .padding(.top, 8)
        }
    }

    private var appSymbol: String {
        if now.isVideo { return "play.rectangle.fill" }
        if now.isSpotify { return "dot.radiowaves.left.and.right" }
        if now.isMusicApp || now.bundleId == nil { return "music.note" }
        if let b = now.bundleId, b.contains("Chrome") || b.contains("Safari") || b.contains("firefox") || b.contains("Arc") {
            return "globe"
        }
        return "music.note"
    }
}

/// Перерисовка раз в секунду от общего тикера (`SharedTicker`), пока вьюха на экране.
struct SecondTicking<Content: View>: View {
    @ViewBuilder var content: (Date) -> Content
    @StateObject private var clock = SecondClock()

    var body: some View {
        content(clock.now)
            .onAppear { clock.start() }
            .onDisappear { clock.stop() }
    }
}

@MainActor
final class SecondClock: ObservableObject {
    @Published private(set) var now = Date()
    private var tick: AnyCancellable?

    func start() {
        now = Date()
        guard tick == nil else { return }
        tick = SharedTicker.shared.subscribe(every: 1) { [weak self] d in self?.now = d }
    }

    func stop() { tick = nil }
}

/// Текст-караоке + волна + время (то, что зависит от позиции).
private struct TimedSection: View {
    @ObservedObject var model: MediaModel
    @ObservedObject private var apple = AppleMusicAccount.shared
    var now: NowPlaying
    var colors: MediaColors
    var date: Date
    /// Плавная заливка текущей строки (`KaraokeSweep`, Core Animation, пока строка допевается) — только при полном
    /// движении; иначе заливка шагает с перерисовкой секции.
    var smoothKaraoke = false
    @Environment(\.islandTheme) private var theme

    /// Кнопка подключения Apple Music под простым текстом (только «Музыка», источник Apple включён, токена нет).
    private var showAppleConnect: Bool {
        guard now.isMusicApp, !now.isVideo, let l = model.lyrics, !l.synced, model.prefs.lyricsEnabled,
              model.prefs.lyricsSources.contains(.apple) else { return false }
        if apple.hasToken == nil { DispatchQueue.main.async { apple.refreshLocal(model.lyricsService) } }
        return apple.hasToken == false
    }

    /// Место для кнопки входа в Яндекс Музыку под простым текстом (любой плеер, источник включён, кнопки Apple нет);
    /// есть ли вход — смотрит сама кнопка (`YandexConnectButton`): подписка на учётку только пока она на экране.
    private var maybeYandexConnect: Bool {
        guard !now.isVideo, let l = model.lyrics, !l.synced, model.prefs.lyricsEnabled,
              model.prefs.lyricsSources.contains(.yandex) else { return false }
        return !showAppleConnect
    }

    var body: some View {
        let pos = model.scrubPosition ?? now.position(at: date)
        // На паузе часов нет — текст стоит (18.11: «на паузе текст дальше идёт»: rate 0 превращался в 1).
        let live: KaraokeClock? = smoothKaraoke && model.scrubPosition == nil && now.isPlaying
            ? KaraokeClock(timestamp: now.timestamp, elapsed: now.elapsed, rate: now.rate > 0 ? now.rate : 1) : nil
        VStack(alignment: .leading, spacing: 0) {
            // Видео: без текста песни и волны-формы — строка источника и простой прогресс.
            LyricsBlock(lyrics: now.isVideo ? nil : model.lyrics, position: pos, duration: now.duration, colors: colors,
                        fallback: fallbackLine, clock: live)
                .padding(.top, 12)
            if showAppleConnect {
                // Трек «Музыки» с текстом без синхронизации, Apple не подключена — пословный текст есть у подписки.
                IslandButton("Подключить Apple Music", systemImage: "music.note", height: 26) {
                    apple.connectSystem(model: model)
                }
                .padding(.top, 8)
            }
            if maybeYandexConnect {
                // Текст без синхронизации, Яндекс не подключён — построчный часто есть в каталоге Яндекса (21.11, «utopi»).
                YandexConnectButton(model: model)
            }
            if now.isVideo, model.browserAccessNeeded != nil, model.coverImage == nil {
                // Превью YouTube: id ролика берём из URL вкладки — нужно право «Автоматизация» браузера (по кнопке).
                IslandButton("Показать превью…", systemImage: "photo", height: 26) { model.requestBrowserAccess() }
                    .padding(.top, 8)
            }
            if !now.isVideo && model.lyrics == nil && model.prefs.liveVisualizer {
                // Текста нет — спектр по настоящему звуку (24 полосы, Core Animation; нет звука — псевдополоски).
                Visualizer(bars: AudioLevelsFeed.wideCount, animated: now.isPlaying, height: 30, colors: colors.played,
                           feed: model.audioFeed)
                    .opacity(now.isPlaying ? 1 : 0.55)
                    .padding(.top, 10)
            }
            Spacer(minLength: 4)
            if now.isLive {
                // Прямой эфир (настоящий поток, `PlaybackTimeline`): ни волны, ни «осталось», только метка.
                HStack(spacing: 6) {
                    Circle().fill(Color(hex: "#FF453A")).frame(width: 7, height: 7)
                    Text("Прямой эфир")
                }
                .font(theme.font(12, .semibold))
                .foregroundStyle(theme.tertiary)
                .padding(.bottom, 4)
            } else {
                Group {
                    if now.isVideo {
                        VideoScrubber(model: model, position: pos, duration: now.duration, colors: colors)
                    } else {
                        WaveformScrubber(model: model, key: now.trackKey, position: pos, duration: now.duration, colors: colors)
                    }
                }
                .frame(height: 26)
                HStack {
                    Text(formatTime(pos))
                    Spacer()
                    // Длительность ещё неизвестна (`.unknown`) — только прошедшее время.
                    if now.duration > 0 { Text("−" + formatTime(max(0, now.duration - pos).rounded(.up))) }
                }
                .font(theme.font(11, .semibold).monospacedDigit())
                .foregroundStyle(theme.tertiary)
                .padding(.top, 6)
            }
        }
    }

    private var fallbackLine: String? {
        if now.isVideo { return now.appName.map { "Видео · \($0)" } ?? "Видео" }
        if model.lyricsNotFound { return "Текста этой песни нет ни в одном источнике" }
        if let app = now.appName, !now.isMusicApp { return "Играет в \(app)" }
        return nil
    }
}

/// Расписание кадров секции времени: только моменты, когда на экране что-то меняется — следующая целая секунда
/// позиции и «осталось» (время), граница полоски волны (92 на трек), начало строки текста. Между ними — ни кадра.
struct PlaybackSchedule: TimelineSchedule {
    var timestamp: Date
    var elapsed: Double
    var rate: Double
    var duration: Double
    var clock: Bool
    var lineTimes: [Double]
    var barStep: Double

    init(now: NowPlaying, lyrics: Lyrics?, bars: Int) {
        timestamp = now.timestamp
        elapsed = now.elapsed
        rate = now.rate > 0 ? now.rate : 1
        duration = now.duration
        clock = !now.isLive
        lineTimes = lyrics?.synced == true ? lyrics!.lines.map(\.time) : []
        barStep = !now.isLive && now.duration > 0 ? now.duration / Double(bars) : 0
    }

    func entries(from start: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var last: Date? = nil
        return AnyIterator {
            guard let prev = last else { last = start; return start }
            guard let n = next(after: prev) else { return nil }
            last = n
            return n
        }
    }

    /// Ближайший момент после `date`, когда меняется видимое (nil — до конца трека ничего).
    func next(after date: Date) -> Date? {
        let pos = elapsed + date.timeIntervalSince(timestamp) * rate
        if duration > 0 && pos >= duration { return nil }
        let eps = 1e-3
        var target = Double.infinity
        if clock {
            target = floor(pos + eps) + 1                                     // «0:41» → «0:42»
            if duration > 0 {                                                 // «−2:13» (округление вверх)
                let f = duration - floor(duration)
                target = min(target, floor(pos - f + eps) + 1 + f)
            }
        }
        if barStep > 0 { target = min(target, (floor(pos / barStep - 0.5 + eps) + 1.5) * barStep) }   // played = round
        if let m = lineTimes.first(where: { $0 > pos + eps }) { target = min(target, m) }
        if duration > 0 { target = min(target, duration) }
        guard target.isFinite else { return nil }
        return timestamp.addingTimeInterval((target - elapsed) / rate + 0.002)
    }
}

/// Текст: синхронный — строки «как в Apple Music» (`LyricsStack`), простой — начало тусклым.
struct LyricsBlock: View {
    var lyrics: Lyrics?
    var position: Double
    var duration: Double
    var colors: MediaColors
    var fallback: String?
    /// Играет и полное движение: заливку строки ведёт Core Animation по этим часам (в процессе — ни кадра).
    var clock: KaraokeClock? = nil
    @Environment(\.islandTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let l = lyrics, !l.synced, !l.plainExcerpt(1).isEmpty {
                // Текст без таймингов: начало песни тусклым, без заливки и без смены строк — не делаем вид, что синхронно.
                let ex = l.plainExcerpt(2)
                Text("Текст без синхронизации" + (l.source.map { " · \($0)" } ?? ""))
                    .font(theme.font(11, .semibold)).foregroundStyle(colors.dimLine).lineLimit(1)
                ForEach(Array(ex.enumerated()), id: \.offset) { _, s in
                    Text(s).font(theme.font(15, .semibold)).foregroundStyle(colors.dimLine).lineLimit(1)
                }
            } else if let l = lyrics, l.synced, !l.lines.isEmpty {
                // Как экран «Текст» Apple Music (`LyricsStack`): активная строка по центру с заливкой-фронтом,
                // соседние мельче, прозрачнее и размыты, смена строки — прокрутка пружиной с каскадом.
                LyricsStackRep(lyrics: l, position: position, clock: clock)
                    .frame(height: 60)
                    .help(l.source.map { "Текст: \($0)" + (l.wordSynced ? ", по словам" : ", по строкам") } ?? "")
            } else if let f = fallback {
                Text(f).font(theme.font(13, .semibold)).foregroundStyle(colors.dimLine).lineLimit(1)
            }
        }
    }
}

/// Часы играющего трека для заливки караоке: позиция `elapsed` в момент `timestamp`, дальше — со скоростью `rate`.
struct KaraokeClock {
    var timestamp: Date
    var elapsed: Double
    var rate: Double
    /// Когда (по часам) позиция трека будет `p`.
    func date(atPosition p: Double) -> Date { timestamp.addingTimeInterval((p - elapsed) / rate) }
}

/// Перемотка по псевдоволне: проигранное — цветом акцента/обложки, перетаскивание = seek.
struct WaveformScrubber: View {
    static let barCount = 92
    @ObservedObject var model: MediaModel
    var key: String
    var position: Double
    var duration: Double
    var colors: MediaColors

    var body: some View {
        GeometryReader { g in
            // Как в макете 01: ровно 92 полосы на всю ширину.
            let count = Self.barCount
            let bars = Waveform.bars(seed: key, count: count)
            let frac = duration > 0 ? min(1, max(0, position / duration)) : 0
            let played = Int((Double(count) * frac).rounded())
            // Одна Canvas вместо 92 вью: пересчёт раз в секунду дешёвый, граф SwiftUI маленький.
            let gradient = Gradient(colors: colors.played)
            let unplayed = colors.unplayed
            Canvas { ctx, size in
                let gap: CGFloat = 2
                let w = max(0, (size.width - gap * CGFloat(count - 1)) / CGFloat(count))
                for k in 0..<count {
                    let h = max(3, size.height * bars[k])
                    let r = CGRect(x: CGFloat(k) * (w + gap), y: (size.height - h) / 2, width: w, height: h)
                    let path = Path(roundedRect: r, cornerRadius: 1)
                    if k < played {
                        ctx.fill(path, with: .linearGradient(gradient, startPoint: CGPoint(x: r.midX, y: r.minY),
                                                             endPoint: CGPoint(x: r.midX, y: r.maxY)))
                    } else {
                        ctx.fill(path, with: .color(unplayed))
                    }
                }
            }
            .frame(width: g.size.width, height: g.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        guard duration > 0 else { return }
                        model.scrubPosition = duration * min(1, max(0, v.location.x / max(1, g.size.width)))
                    }
                    .onEnded { v in
                        guard duration > 0 else { return }
                        let t = duration * min(1, max(0, v.location.x / max(1, g.size.width)))
                        model.scrubPosition = nil
                        model.seek(to: t)
                    }
            )
        }
    }
}

/// Простой прогресс видео (вместо волны-формы песни): перетаскивание = seek.
struct VideoScrubber: View {
    @ObservedObject var model: MediaModel
    var position: Double
    var duration: Double
    var colors: MediaColors

    var body: some View {
        GeometryReader { g in
            let frac = duration > 0 ? min(1, max(0, position / duration)) : 0
            ProgressTrack(value: frac, height: 6,
                          tint: AnyShapeStyle(LinearGradient(colors: colors.played, startPoint: .leading, endPoint: .trailing)))
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            guard duration > 0 else { return }
                            model.scrubPosition = duration * min(1, max(0, v.location.x / max(1, g.size.width)))
                        }
                        .onEnded { v in
                            guard duration > 0 else { return }
                            let t = duration * min(1, max(0, v.location.x / max(1, g.size.width)))
                            model.scrubPosition = nil
                            model.seek(to: t)
                        }
                )
        }
        .accessibilityLabel("Позиция видео")
    }
}

/// Обложка: картинка (обложка / превью YouTube), мок-градиент, значок видео (видео без картинки) или плитка «нет обложки».
struct CoverView: View {
    var image: NSImage?
    var placeholder: ArtworkView.Placeholder?
    var size: CGFloat
    var radius: CGFloat
    var shadow: Color?
    var appBadge: String?
    /// Видео без картинки: значок видео на цвете темы вместо ноты (не голый значок браузера).
    var videoIcon = false
    @Environment(\.islandTheme) private var theme

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if image == nil, placeholder == nil, videoIcon {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(LinearGradient(colors: [theme.accentColor, theme.accent2Color],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay {
                        Image(systemName: "play.rectangle.fill")
                            .font(.system(size: size * 0.42, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.95))
                    }
                    .accessibilityLabel("Видео")
            } else if image != nil || placeholder != nil {
                // ArtworkView заполняет картинкой и обрезает по СВОЕМУ размеру: у неквадратной обложки (Chrome
                // отдаёт 150×83) этот размер шире рамки. Рамка + обрезка здесь держат её в квадрате.
                ArtworkView(image: image, cornerRadius: radius, placeholder: placeholder ?? .warm)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(theme.controlFillColor)
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: size * 0.3, weight: .semibold))
                            .foregroundStyle(theme.tertiary)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(theme.primary.opacity(0.08), lineWidth: 1)
                    }
            }
            if let s = appBadge, size >= 60, image != nil || placeholder != nil {
                Image(systemName: s)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: theme.mediaRadius(8), style: .continuous).fill(Color.black.opacity(0.35)))
                    .padding(12)
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .background {
            // Мягкая тень цвета обложки (`.cover` box-shadow в макете). Сужена по бокам: вкладка обрезается ядром
            // по краю контента, и обычная .shadow давала бы резкую границу слева.
            if let shadow, size >= 60 {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(shadow.opacity(theme.isLight ? 0.3 : 0.45))
                    .padding(.horizontal, size * 0.16)
                    .padding(.top, size * 0.3)
                    .offset(y: size * 0.1)
                    .blur(radius: size * 0.1)
            }
        }
    }
}

// MARK: - Кнопки

private struct ControlsRow: View {
    @ObservedObject var model: MediaModel
    var now: NowPlaying
    @Environment(\.islandTheme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                if model.canLike {
                    RoundIconButton(systemImage: model.liked == true ? "heart.fill" : "heart", size: 34,
                                    tint: model.liked == true ? Color(hex: "#FF3D7F") : nil) { model.toggleLike() }
                        .help("Нравится")
                }
                // Устройство вывода и AirPlay — один чип справа (16.11). Скорость — по `MediaModel.speedSupported`.
                if model.canChangeSpeed {
                    IslandButton(speedText, height: 34) { model.cycleSpeed() }.help("Скорость")
                }
                Spacer(minLength: 0)
            }
            .frame(width: 200, alignment: .leading)

            Spacer(minLength: 0)
            HStack(spacing: 26) {
                TransportButton(systemImage: "backward.end.fill") { model.previous() }.help("Предыдущий")
                PlayButton(isPlaying: now.isPlaying, colors: MediaColors(theme: theme, palette: model.palette)) { model.togglePlay() }
                TransportButton(systemImage: "forward.end.fill") { model.next() }.help("Следующий")
            }
            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                if case .needsAutomation(let b, let app) = model.availability {
                    IslandButton("Разрешить «\(app)»…", systemImage: "lock.open", height: 30) { model.requestPermission(b) }
                        .help("Нужно разрешение «Автоматизация»: позиция, обложка и управление")
                } else if let next = model.nextTitle {
                    // «Далее: «…»» (макет 01) — щелчок переключает на него. Устройство — значком рядом (то же меню).
                    if let d = model.device { DeviceChip(model: model, device: d, iconOnly: true) }
                    NextUpButton(title: next) { model.next() }
                } else if let d = model.device {
                    DeviceChip(model: model, device: d)
                }
            }
            .frame(width: 236, alignment: .trailing)
        }
        .frame(height: 64)
    }

    private var speedText: String {
        let s = model.speed
        return (abs(s - s.rounded()) < 0.01 ? String(format: "%.1f", s) : String(format: "%.2g", s))
            .replacingOccurrences(of: ".", with: ",") + "×"
    }
}

/// «Далее: «Название»» — капсула приглушённым текстом, как `.side2 .btn` в макете 01.
private struct NextUpButton: View {
    var title: String
    var action: () -> Void
    @Environment(\.islandTheme) private var theme
    var body: some View {
        Button(action: action) {
            Text("Далее: «\(title)»")
                .font(theme.font(12.5, .semibold))
                .foregroundStyle(theme.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Capsule().fill(theme.controlFillColor))
                .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
        .help("Следующий: \(title)")
        .accessibilityLabel("Следующий трек: \(title)")
    }
}

/// Круглая кнопка-иконка с подложкой темы и своим цветом значка (лайк).
private struct RoundIconButton: View {
    var systemImage: String
    var size: CGFloat
    var tint: Color?
    var action: () -> Void
    @Environment(\.islandTheme) private var theme
    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(tint ?? theme.primary)
                .frame(width: size, height: size)
                .background(MediaRoundShape(pixelated: theme.effects.pixelated).fill(theme.controlFillColor))
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
    }
}

private struct TransportButton: View {
    var systemImage: String
    var action: () -> Void
    @Environment(\.islandTheme) private var theme
    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(theme.primary)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
    }
}

/// Большая круглая кнопка: белая на тёмном острове, чёрная на светлом (`.ctl .play`).
private struct PlayButton: View {
    var isPlaying: Bool
    var colors: MediaColors
    var action: () -> Void
    @Environment(\.islandTheme) private var theme
    var body: some View {
        let fill = colors.playFill ?? theme.primary
        Button(action: action) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(colors.playIcon ?? (theme.isLight ? Color.white : Color.black))
                .offset(x: isPlaying ? 0 : 1.5)
                .frame(width: 52, height: 52)
                .background(MediaRoundShape(pixelated: theme.effects.pixelated).fill(fill))
                .padding(6)
                .background(MediaRoundShape(pixelated: theme.effects.pixelated).fill(fill.opacity(0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
        .help(isPlaying ? "Пауза" : "Играть")
    }
}

/// Чип устройства вывода: значок по типу + имя («Динамики MacBook Pro»). Щелчок — меню устройств CoreAudio с
/// галочкой у текущего и «AirPlay…» (`MediaModel.showOutputMenu`). Под чипом — невидимый системный
/// `AVRoutePickerView` для пункта «AirPlay…». В снимках NSView не рисуются — там только чип.
struct DeviceChip: View {
    @ObservedObject var model: MediaModel
    var device: OutputDevice
    var iconOnly = false
    @Environment(\.islandTheme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var anchor: NSView?

    var body: some View {
        let tint = device.kind == .bluetooth ? IslandPalette.okText(theme) : theme.secondary
        Button {
            if let a = anchor { model.showOutputMenu(from: a) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: device.systemImage).font(.system(size: iconOnly ? 12 : 10, weight: .semibold))
                if !iconOnly {
                    Text(device.name).font(theme.font(11, .semibold)).lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold)).opacity(0.7)
                }
            }
            .padding(.horizontal, iconOnly ? 0 : 9)
            .frame(width: iconOnly ? 30 : nil, height: iconOnly ? 30 : 22)
            .foregroundStyle(tint)
            .background(Capsule().fill(device.kind == .bluetooth ? tint.opacity(0.14) : theme.controlFillColor))
            .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
        .background {
            if !isSnapshot {
                ZStack {
                    ViewRef { anchor = $0 }
                    RoutePicker { model.airPlayPicker = $0 }.allowsHitTesting(false)
                }
            }
        }
        .help("Вывод звука: \(device.name)")
        .accessibilityLabel("Вывод звука: \(device.name)")
        .accessibilityHint("Выбрать другое устройство")
    }
}

private struct RoutePicker: NSViewRepresentable {
    var set: (NSView) -> Void
    func makeNSView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        DispatchQueue.main.async { set(v) }
        v.isRoutePickerButtonBordered = false
        // Свой значок рисуем сами (под ним) — системный делаем невидимым, но кликабельным.
        v.setRoutePickerButtonColor(.clear, for: .normal)
        v.setRoutePickerButtonColor(.clear, for: .normalHighlighted)
        v.setRoutePickerButtonColor(.clear, for: .active)
        v.setRoutePickerButtonColor(.clear, for: .activeHighlighted)
        return v
    }
    func updateNSView(_ v: AVRoutePickerView, context: Context) {}
}

// MARK: - Пусто / нужно разрешение

private struct EmptyPlayerView: View {
    @ObservedObject var model: MediaModel
    @Environment(\.islandTheme) private var theme

    var body: some View {
        HStack(spacing: 22) {
            CoverView(image: nil, placeholder: nil, size: 148, radius: theme.mediaRadius(22), shadow: nil, appBadge: nil)
            VStack(alignment: .leading, spacing: 6) {
                switch model.availability {
                case .needsAutomation(let b, let app):
                    Text("Нужно разрешение").font(theme.font(22, .bold)).foregroundStyle(theme.primary)
                    Text("Чтобы показывать и переключать треки в приложении «\(app)», разрешите SimpleIsland управлять им: Системные настройки → Конфиденциальность и безопасность → Автоматизация.")
                        .font(theme.font(13, .medium)).foregroundStyle(theme.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    IslandButton("Разрешить…", systemImage: "lock.open", style: .solid, height: 32) { model.requestPermission(b) }
                        .padding(.top, 8)
                case .unavailable(let why):
                    Text("Источник недоступен").font(theme.font(22, .bold)).foregroundStyle(theme.primary)
                    Text(why).font(theme.font(13, .medium)).foregroundStyle(theme.tertiary)
                case .ok:
                    Text("Ничего не играет").font(theme.font(22, .bold)).foregroundStyle(theme.primary)
                    Text("Включите музыку в Музыке, Spotify или в браузере — она появится здесь.")
                        .font(theme.font(13, .medium)).foregroundStyle(theme.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                // Чип устройства — только на «Ничего не играет»: в тексте про разрешение ему не хватает места.
                if model.availability == .ok, let d = model.device {
                    DeviceChip(model: model, device: d)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 148, alignment: .topLeading)
        }
    }
}

// MARK: - Компакт

/// Левое ухо: обложка 24 pt (+ строка текста, если включено).
struct MediaCompactLeading: View {
    @ObservedObject var model: MediaModel
    @Environment(\.islandTheme) private var theme
    @Environment(\.islandMotion) private var motion

    var body: some View {
        HStack(spacing: 8) {
            CoverView(image: model.coverImage, placeholder: model.placeholderArtwork, size: 24, radius: theme.mediaRadius(7),
                      shadow: nil, appBadge: nil, videoIcon: model.now?.isVideo == true)
            if model.prefs.compactLyrics, let cur = model.currentLyricLine {
                let line = cur.text
                Group {
                    if cur.isWordSynced, let n = model.now {
                        // Пословно и в компакте: заливка — Core Animation (≤ 20 к/с), только пока играет при полном движении.
                        LyricsStackRep(lyrics: Lyrics(lines: [cur]), position: n.position(),
                                       clock: n.isPlaying && motion.allowsContinuousAnimation
                                           ? KaraokeClock(timestamp: n.timestamp, elapsed: n.elapsed, rate: n.rate > 0 ? n.rate : 1)
                                           : nil,
                                       fontSize: 12, compact: true, secondaryColor: true)
                            .frame(height: 18)
                    } else {
                        Text(line)
                            .font(theme.font(12, .semibold))
                            .foregroundStyle(theme.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                    .id(line)
                    .transition(.opacity)
                    // Не впритык к вырезу.
                    .padding(.trailing, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Смена строки — мягкое затухание; «Уменьшить движение» — короче, окно не видно — без анимации.
        .animation(motion.animation(.easeOut(duration: 0.25)), value: model.currentLyricText)
    }
}

/// Правое ухо: эквалайзер (анимируется только пока играет). «Эквалайзер по реальному звуку» включён — полосы по
/// захвату звука (`model.audioFeed`, Core Animation без кадров SwiftUI); нет захвата — псевдополоски.
struct MediaCompactTrailing: View {
    @ObservedObject var model: MediaModel
    @Environment(\.islandTheme) private var theme

    var body: some View {
        let colors = MediaColors(theme: theme, palette: model.palette)
        let st = model.prefs.eqStyle
        // Варианты №1/№3/№8 — цвет обложки (приглушённый: светлота ~75 %, насыщенность ~60 %); нет обложки — тема.
        let cover: [Color]? = ArtworkPalette.accent(model.palette).map { a -> [Color] in
            let (h, sat, _) = a.hsb
            let c = ArtworkPalette.RGB.hsb(h, min(0.6, sat), 0.88).color
            return [c, c]
        }
        Visualizer(bars: 5, animated: model.now?.isPlaying ?? false, height: 16,
                   colors: st == .classic ? colors.played : (cover ?? colors.played),
                   feed: model.prefs.liveVisualizer ? model.audioFeed : nil,
                   barWidth: 3, gap: st == .classic ? 2 : 3, style: st, flat: model.now?.isPlaying != true)
            .opacity(model.now?.isPlaying == false ? 0.55 : 1)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// «Капля», когда музыка — вторая активность: обложка.
struct MediaBubbleView: View {
    @ObservedObject var model: MediaModel
    @Environment(\.islandTheme) private var theme
    var body: some View {
        CoverView(image: model.coverImage, placeholder: model.placeholderArtwork, size: 22, radius: theme.mediaRadius(11),
                  shadow: nil, appBadge: nil, videoIcon: model.now?.isVideo == true)
    }
}

/// «Подключить Яндекс Музыку» в острове — только если входа нет (проверка локальная, без сети).
private struct YandexConnectButton: View {
    @ObservedObject var model: MediaModel
    @ObservedObject private var yandex = YandexMusicAccount.shared

    var body: some View {
        Group {
            if yandex.hasToken == false {
                IslandButton("Подключить Яндекс Музыку", systemImage: "music.note", height: 26) {
                    yandex.openLogin(model: model)
                }
                .padding(.top, 8)
            }
        }
        .onAppear { if yandex.hasToken == nil { yandex.refreshLocal() } }
    }
}
