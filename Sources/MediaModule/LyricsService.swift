import Foundation
import LyricsCore
import IslandCore

/// Источник текстов — звено каскада LyricsCore (порядок `allCases` — порядок по умолчанию; свой — в настройках
/// «Тексты», `MediaPrefs.lyricsSourceOrder`). Все включены по умолчанию; Apple Music работает, только если пользователь
/// вставил свой media-user-token (Keychain). Deezer — наш провайдер (`DeezerLyricsProvider`) через протокол LyricsCore.
enum LyricsSourceKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case apple, amll, yandex, musixmatch, netease, qq, kugou, deezer, lrclib

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple: return "Apple Music"
        case .amll: return "AMLL TTML DB"
        case .yandex: return "Яндекс Музыка"
        case .musixmatch: return "Musixmatch"
        case .netease: return "NetEase Cloud Music"
        case .qq: return "QQ Музыка"
        case .kugou: return "KuGou"
        case .deezer: return "Deezer"
        case .lrclib: return "LRCLIB"
        }
    }

    var note: String {
        switch self {
        case .apple: return "Пословный текст из вашей подписки (нужен токен)"
        case .amll: return "Открытая база пословных TTML (с бэк-вокалом)"
        case .yandex: return "Построчный LRC из каталога Яндекса (нужен вход)"
        case .musixmatch: return "Самый большой каталог: пословный, построчный или простой; без входа"
        case .netease: return "Пословный YRC"
        case .qq: return "Пословный QRC"
        case .kugou: return "Пословный KRC"
        case .deezer: return "Построчный, иногда пословный; без входа (анонимный доступ)"
        case .lrclib: return "Построчный LRC, открытая база"
        }
    }

    fileprivate var providerID: LyricsProviderID {
        switch self {
        case .apple: return .appleMusic
        case .amll: return .amll
        case .yandex: return YandexMusicLyricsProvider.providerID
        case .musixmatch: return MusixmatchLyricsProvider.providerID
        case .netease: return .netease
        case .qq: return .qq
        case .kugou: return .kugou
        case .deezer: return DeezerLyricsProvider.providerID
        case .lrclib: return .lrclib
        }
    }

    /// Порядок опроса: сохранённый пользователем (незнакомые имена — мимо), недостающие — на свои места по умолчанию.
    static func ordered(_ saved: [String]) -> [LyricsSourceKind] {
        var out = saved.compactMap(LyricsSourceKind.init(rawValue:))
        out = out.enumerated().filter { i, k in !out[..<i].contains(k) }.map(\.element)
        for k in allCases where !out.contains(k) {
            // Недостающий (новый) источник встаёт сразу за своим соседом по умолчанию (Deezer — за KuGou); нет соседа — в начало.
            let prev = allCases[..<allCases.firstIndex(of: k)!].last { out.contains($0) }
            if let p = prev, let j = out.firstIndex(of: p) { out.insert(k, at: j + 1) } else { out.insert(k, at: 0) }
        }
        return out
    }

    fileprivate init?(_ id: LyricsProviderID) {
        switch id {
        case .appleMusic: self = .apple
        case .amll: self = .amll
        case .netease: self = .netease
        case .qq: self = .qq
        case .kugou: self = .kugou
        case .lrclib: self = .lrclib
        case .local: self = .deezer          // DeezerLyricsProvider.providerID (Яндекс различается по тексту — `of`)
        }
    }

    /// Чей текст: у наших источников один id `.local` — Яндекс и Musixmatch узнаём по `source.format` (`yandex-…`, `musixmatch-…`).
    static func of(_ s: LyricsSource) -> LyricsSourceKind? {
        if s.provider == .local {
            let f = s.format ?? ""
            if f.hasPrefix(YandexMusicLyricsProvider.formatPrefix) { return .yandex }
            if f.hasPrefix(MusixmatchLyricsProvider.formatPrefix) { return .musixmatch }
            return .deezer
        }
        return LyricsSourceKind(s.provider)
    }

    /// Чей провайдер (для подмены в самотесте и сборки составного `.local`).
    static func of(_ p: any LyricsProvider) -> LyricsSourceKind? {
        if p is YandexMusicLyricsProvider { return .yandex }
        if p is MusixmatchLyricsProvider { return .musixmatch }
        if p is OwnLyricsProviders { return nil }
        return LyricsSourceKind(p.id)
    }

    /// Наши источники — идут в каскад одним составным провайдером `.local` (`OwnLyricsProviders`).
    static let own: [LyricsSourceKind] = [.yandex, .musixmatch, .deezer]
}

/// Тексты песен через движок LyricsCore (каскад Apple → AMLL → Яндекс → Musixmatch → NetEase → QQ → KuGou → Deezer → LRCLIB, порядок меняется в
/// настройках; пословный текст важнее
/// построчного) с кешем на диске `~/Library/Caches/SimpleIsland/lyrics-v3` (`LyricsCache` с пределами 200 треков / 5 МБ /
/// 30 дней — чистит сам при превышении). Поверх выбора движка — наш фильтр `LyricsMatch` (версия, название, исполнитель,
/// длительность ±3 с): «почти совпадения» (другая версия записи) не показываем никогда — лучше без текста, чем чужой (15.11).
/// Поиск потоковый (`updates`): первый подходящий текст показывается сразу (~0,4 с), дальше заменяется, только если
/// синхронизация стала лучше (простой → построчный → пословный) — 15.11, LyricsCore cd4c949.
/// Сеть — только к источникам каскада; Apple — только с токеном пользователя из Keychain.
actor LyricsService {
    static let shared = LyricsService()
    static let cacheVersion = 3
    /// Keychain: служба для токена Apple Music (и developer token, который LyricsCore добывает сам).
    static let keychainService = "local.simpleisland.lyrics"

    struct Query: Sendable, Hashable {
        var artist: String
        var title: String
        var album: String
        var duration: Double
    }

    /// Разбор одного поиска — для сетевого самотеста и отладки.
    struct Lookup: Sendable {
        var lyrics: Lyrics?
        var provider: LyricsSourceKind?
        var fromCache = false
        /// По источникам: «qq: word ×3», «kugou: notFound (кандидатов: 0)».
        var outcomes: [String] = []
        /// Что движок предложил, а наш фильтр отверг (с причиной).
        var rejected: [String] = []
        /// От начала поиска до первого показанного текста, с (nil — текста нет).
        var firstTextAfter: TimeInterval?
        /// Весь поиск, с.
        var seconds: TimeInterval = 0
        /// Сколько раз показанный текст заменён лучшим (по синхронизации).
        var upgrades = 0
        /// Хотя бы один источник упал — «не найдено» не доказано.
        var hadFailures = false
        /// Все опрошенные источники — «нет сети»: молчим, ничего не запоминаем.
        var offline = false
        /// Поиск дошёл до итога движка (не отменён на середине).
        var complete = false

        /// Качество синхронизации показанного: −1 — нет текста, 0 — простой, 1 — построчный, 2 — пословный.
        var rank: Int { lyrics.map(Self.rank) ?? -1 }
        static func rank(_ l: Lyrics) -> Int { l.wordSynced ? 2 : (l.synced ? 1 : 0) }
    }

    private let cacheDir: URL
    /// Дисковый кеш (для самотеста — доступ к записи/чтению напрямую).
    nonisolated let cache: LyricsCache
    private let http: HTTPClient
    let credentials: CredentialStore
    /// Подмена провайдеров (самотест без сети): тогда `sources` фильтрует её по `id`.
    private let providersOverride: [any LyricsProvider]?
    /// Один экземпляр AMLL на всё время работы: индексы, разобранные `prefetchIndexes()`, живут в нём (новый движок
    /// при смене набора источников берёт тот же).
    private let amll: AMLLProvider
    /// Каталог индексов AMLL (nil — поиск по индексу выключен, только по id из NetEase/QQ).
    nonisolated let amllIndexDir: URL?
    private var engine: LyricsEngine?
    private var engineSources: [LyricsSourceKind] = []
    /// Подпись составного `.local` в разборе: какие наши источники в нём на самом деле («yandex+musixmatch+deezer»).
    private var engineOwn = "deezer"
    private var memory: [String: Lyrics?] = [:]
    private var prefetched = false

    /// - `amllIndexDir`: где держать индексы AMLL (~10 МБ, обновляются не чаще раза в сутки — `AMLLProvider.Options.indexTTL`).
    ///   По умолчанию (кеш приложения) — `Caches/SimpleIsland/amll-index`; с чужим `cacheDir` (самотест) — без индекса,
    ///   если не передан явно.
    init(cacheDir: URL? = nil, credentials: CredentialStore? = nil, http: HTTPClient? = nil,
         providers: [any LyricsProvider]? = nil, amllIndexDir: URL? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let root = base.appendingPathComponent("SimpleIsland", isDirectory: true)
        let dir = cacheDir ?? root.appendingPathComponent("lyrics-v\(Self.cacheVersion)", isDirectory: true)
        if cacheDir == nil {
            // Кеши прежних версий (v1 — без проверки совпадения, v2 — только LRCLIB) — убрать один раз.
            let fm = FileManager.default
            for old in ["lyrics", "lyrics-v2"] { try? fm.removeItem(at: root.appendingPathComponent(old, isDirectory: true)) }
        }
        self.cacheDir = dir
        var ttl = LyricsCache.TTL()
        ttl.word = Self.maxAge; ttl.line = 14 * 86400; ttl.plain = 7 * 86400
        ttl.negative = 3 * 86400        // «не найдено» — 3 дня (при сбое источника не кешируется вовсе)
        ttl.approximate = 6 * 3600
        cache = LyricsCache(directory: dir, ttl: ttl, maxEntries: Self.maxEntries, maxBytes: Self.maxBytes, now: now)
        let http = http ?? URLSessionHTTPClient(timeout: 8, retries: 1)
        self.http = http
        self.credentials = credentials ?? AppleMusicCredentialStore(base: FileCredentialStore(service: Self.keychainService))
        providersOverride = providers
        let idx = amllIndexDir ?? (cacheDir == nil ? root.appendingPathComponent("amll-index", isDirectory: true) : nil)
        self.amllIndexDir = idx
        var o = AMLLProvider.Options()
        // Поиск по индексу AMLL выключен (15.11): индекс +~31 МБ памяти при бюджете покоя 40 МБ; AMLL находит текст по id
        // из NetEase/QQ и без индекса. Включить — `useAMLLIndex = true`.
        o.useIndexSearch = idx != nil && Self.useAMLLIndex
        o.indexDownload = .background   // поиск не ждёт скачивания: индекс докачивается сам и пригодится со следующего трека
        if let idx { try? FileManager.default.createDirectory(at: idx, withIntermediateDirectories: true) }
        amll = AMLLProvider(http: http, cacheDirectory: idx, options: o)
    }

    // MARK: Поиск

    func lyrics(for q: Query, sources: Set<LyricsSourceKind> = Set(LyricsSourceKind.allCases)) async -> Lyrics? {
        await lookup(q, sources: sources).lyrics
    }

    /// Поток текстов для показа: первый подходящий — сразу, дальше — только лучше по синхронизации (простой → построчный
    /// → пословный). Пустой поток — текста нет. Прекращение чтения (отмена задачи-читателя при смене трека) отменяет
    /// поиск в движке; недослушанный поиск ничего не кеширует.
    nonisolated func updates(_ q: Query, sources: Set<LyricsSourceKind> = Set(LyricsSourceKind.allCases),
                             order: [LyricsSourceKind] = LyricsSourceKind.allCases) -> AsyncStream<Lookup> {
        AsyncStream { cont in
            let t = Task {
                _ = await self.lookup(q, sources: sources, order: order) { cont.yield($0) }
                cont.finish()
            }
            cont.onTermination = { _ in t.cancel() }
        }
    }

    /// Поиск целиком (итог — то, что показано последним). `onUpdate` — каждый раз, когда показанный текст сменился на лучший.
    /// `order` — порядок опроса (приоритет при равной синхронизации), из настроек «Тексты».
    func lookup(_ q: Query, sources: Set<LyricsSourceKind> = Set(LyricsSourceKind.allCases),
                order: [LyricsSourceKind] = LyricsSourceKind.allCases,
                onUpdate: (@Sendable (Lookup) -> Void)? = nil) async -> Lookup {
        guard !q.title.isEmpty, !q.artist.isEmpty, !sources.isEmpty else { return Lookup() }
        let start = Date()
        let tq = Self.trackQuery(q)
        let order = LyricsSourceKind.ordered(order.map(\.rawValue)).filter(sources.contains)
        let memKey = tq.cacheKey + "|" + order.map(\.rawValue).joined(separator: ",")
        if let m = memory[memKey] {
            var hit = Lookup(lyrics: m, provider: nil, fromCache: true)
            hit.complete = true
            if m != nil { hit.firstTextAfter = 0; onUpdate?(hit) }
            return hit
        }
        let engine = engine(for: order)
        var opts = FetchOptions()
        opts.allowApproximate = false           // приблизительное (другая версия записи) не показываем
        opts.providerTimeout = 10
        opts.overallTimeout = 20
        // wordGracePeriod — по умолчанию LyricsCore (2 с): пословный у менее приоритетного не ждёт зависшие источники.
        let own = engineOwn
        var (shown, last) = await Self.consume(engine.lyricsUpdates(for: tq, options: opts), query: q, sources: sources,
                                               order: order, own: own, start: start, onUpdate: onUpdate)
        // В кеше лучший — из выключенного теперь источника: один раз заново, только по включённым.
        if shown.lyrics == nil, !Task.isCancelled, let r = last, r.fromCache, let b = r.best,
           let k = LyricsSourceKind.of(b.source), !sources.contains(k) {
            opts.forceRefresh = true
            let before = shown.rejected
            (shown, last) = await Self.consume(engine.lyricsUpdates(for: tq, options: opts), query: q, sources: sources,
                                               order: order, own: own, start: start, onUpdate: onUpdate)
            shown.rejected = before + shown.rejected.filter { !before.contains($0) }
        }
        shown.seconds = Date().timeIntervalSince(start)
        // Разбор составного `.local` по частям (Яндекс, Deezer) — для отладки (`--lyrics-lookup`).
        if last?.fromCache == false { shown.outcomes += OwnLyricsReport.shared.take(tq.cacheKey).map { "  · " + $0 } }
        guard !Task.isCancelled, let r = last, r.isFinal else { shown.complete = false; return shown }
        // Сбой сети (ничего не узнали), «нет сети», упавший источник при пустом итоге — не запоминаем: спросим в следующий раз.
        let anyAnswer = r.fromCache || r.outcomes.contains {
            if case .found = $0.status { return true }; if case .notFound = $0.status { return true }; return false
        }
        if shown.lyrics == nil && (r.hadFailures || r.isOffline) {
            // Движок не кеширует пустой итог при сбое, но мог записать текст, который отверг наш фильтр, — а упавший
            // источник мог дать подходящий. Убираем, чтобы следующий поиск спросил всех заново.
            if !r.fromCache { cache.remove(key: tq.cacheKey) }
        } else if anyAnswer {
            remember(memKey, shown.lyrics)
        }
        return shown
    }

    /// Разбор потока результатов движка (промежуточные + итог): показанный текст меняется, только если прошёл наш фильтр
    /// и синхронизация лучше уже показанной. Отдельно от движка — для самотеста на заглушке.
    static func consume(_ results: AsyncStream<LyricsResult>, query q: Query, sources: Set<LyricsSourceKind>,
                        order: [LyricsSourceKind] = LyricsSourceKind.allCases, own: String = "deezer",
                        start: Date = Date(), onUpdate: (@Sendable (Lookup) -> Void)? = nil) async -> (Lookup, LyricsResult?) {
        var shown = Lookup()
        var last: LyricsResult?
        for await r in results {
            last = r
            let pick = choose(r, query: q, sources: sources, order: order, own: own)
            for x in pick.rejected where !shown.rejected.contains(x) { shown.rejected.append(x) }
            guard !Task.isCancelled, let l = pick.lyrics, pick.rank > shown.rank else { continue }
            if shown.lyrics == nil { shown.firstTextAfter = Date().timeIntervalSince(start) } else { shown.upgrades += 1 }
            shown.lyrics = l
            shown.provider = pick.provider
            shown.fromCache = r.fromCache
            var u = shown
            u.outcomes = pick.outcomes
            onUpdate?(u)
        }
        if let r = last {
            shown.outcomes = r.outcomes.map { describe($0, own: own) }
            shown.hadFailures = r.hadFailures
            shown.offline = r.isOffline
            if shown.lyrics == nil { shown.fromCache = r.fromCache }
            shown.complete = r.isFinal && !Task.isCancelled
        }
        shown.seconds = Date().timeIntervalSince(start)
        return (shown, last)
    }

    /// Выбор из ответа движка: среди лучшего и альтернатив (только включённые источники, не near-miss, прошедшие наш фильтр
    /// совпадения) — с лучшей синхронизацией, при равной — выше в порядке пользователя `order` (у Яндекса и Deezer в
    /// движке одно место — составной `.local`, поэтому порядок решается здесь), дальше — порядок движка.
    static func choose(_ r: LyricsResult, query q: Query, sources: Set<LyricsSourceKind>,
                       order: [LyricsSourceKind] = LyricsSourceKind.allCases, own: String = "deezer") -> Lookup {
        var out = Lookup(fromCache: r.fromCache)
        out.outcomes = r.outcomes.map { describe($0, own: own) }
        var outIndex = Int.max
        for l in [r.best].compactMap({ $0 }) + r.alternatives {
            guard let kind = LyricsSourceKind.of(l.source), sources.contains(kind) else { continue }
            if let why = rejectReason(l, query: q) {
                out.rejected.append("\(kind.rawValue)/\(l.syncType.rawValue): \(why)")
                continue
            }
            guard let conv = convert(l) else { continue }
            let rank = Lookup.rank(conv), idx = order.firstIndex(of: kind) ?? order.count
            guard rank > out.rank || (rank == out.rank && idx < outIndex) else { continue }
            out.lyrics = conv
            out.provider = kind
            outIndex = idx
        }
        return out
    }

    /// nil — подходит; иначе причина отказа. Записи по id (Apple, AMLL по id каталога) — без названия, доверяем id.
    static func rejectReason(_ l: LyricsCore.Lyrics, query q: Query) -> String? {
        if let r = l.source.matchQuality.reason { return "почти совпадение: \(r)" }
        if l.isInstrumental || l.isEmpty { return "пусто/инструментал" }
        guard let t = l.source.title, !t.isEmpty, let a = l.source.artist, !a.isEmpty else { return nil }
        // Длительность записи для сверки ±3 с:
        // * найдено по id (каталог Apple, ISRC, id NetEase/QQ у AMLL) — версию определяет id, длительность не сверяем;
        // * AMLL — `source.duration` у неё nil (с cd4c949): конец текста ≠ длина трека («Numb» отвергался «±10 с»),
        //   а текст длиннее трека LyricsCore сам помечает near-miss (отвергнут выше). Сверяем название/исполнителя/версию;
        // * остальные — длительность у источника (нет — строже пороги названия и исполнителя).
        let byID = [.catalogID, .isrc, .externalID].contains(l.source.matchKind)
        if l.source.provider == .amll, !byID, q.duration >= 1, let end = l.lines.compactMap(\.end).max(), end > q.duration + 20 {
            return "\(a) — \(t): текст длиннее трека (\(Int(end)) с)"
        }
        let trusted = byID || l.source.provider == .amll
        let c = LyricsMatch.Candidate(title: t, artist: a, duration: trusted ? q.duration : (l.source.duration ?? 0), synced: "x")
        let e = LyricsMatch.evaluate(q, c, durationTolerance: 3)
        return e.accepted ? nil : "\(a) — \(t): \(e.reason ?? "")"
    }

    static func describe(_ o: ProviderOutcome, own: String = "deezer") -> String {
        let s: String
        switch o.status {
        case .found(let n, let best): s = "\(best.rawValue) ×\(n)"
        case .notFound: s = "нет" + (o.note.map { " (\($0))" } ?? "")
        case .failed(let e): s = "сбой \(e)"
        case .skipped(let w): s = "пропущен (\(w))"
        case .cancelled: s = "отменён"
        }
        return "\(o.provider == .local ? own : o.provider.rawValue): \(s), \(String(format: "%.1f", o.seconds)) с"
    }

    /// Ключ кеша (LyricsCore `TrackQuery.cacheKey`): нормализованные название | исполнитель | теги версии | длительность,
    /// без альбома и регистра.
    nonisolated static func cacheKey(_ q: Query) -> String { trackQuery(q).cacheKey }

    nonisolated static func trackQuery(_ q: Query) -> TrackQuery {
        TrackQuery(title: q.title, artist: q.artist, album: q.album.isEmpty ? nil : q.album,
                   duration: q.duration >= 1 ? q.duration : nil)
    }

    /// Текст LyricsCore → наша модель (строки со временем, слова/слоги, фоновый вокал). nil — показывать нечего.
    static func convert(_ l: LyricsCore.Lyrics) -> Lyrics? {
        let name = LyricsSourceKind.of(l.source)?.title
        func words(_ w: [LyricsCore.LyricWord]) -> [LyricWord] {
            w.map { LyricWord(text: $0.text, begin: $0.begin, end: max($0.begin, $0.end), joins: $0.isContinuation) }
        }
        switch l.syncType {
        case .none:
            let lines = l.lines.map { LyricLine(time: 0, text: $0.text) }
            return lines.contains { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
                ? Lyrics(lines: lines, synced: false, source: name) : nil
        case .line, .word:
            var lines: [LyricLine] = []
            for x in l.lines {
                guard let b = x.begin else { continue }
                var bg = words(x.background)
                // Построчный бэк-вокал без слов — одним «словом» на время строки (тусклее и мельче, без заливки по слогам).
                if bg.isEmpty, let t = x.backgroundText, !t.isEmpty, !x.words.isEmpty, let e = x.end {
                    bg = [LyricWord(text: t, begin: b, end: e)]
                }
                lines.append(LyricLine(time: b, text: x.text, end: x.end, words: words(x.words), background: bg))
            }
            lines = lines.enumerated().sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }.map(\.element)
            return lines.isEmpty ? nil : Lyrics(lines: lines, synced: true, source: name)
        }
    }

    /// Движок под включённые источники в порядке опроса (`LyricsEngine` берёт приоритет из порядка провайдеров).
    private func engine(for order: [LyricsSourceKind]) -> LyricsEngine {
        if let e = engine, engineSources == order { return e }
        let parts: [OwnLyricsProviders.Part]
        if let o = providersOverride {
            parts = order.flatMap { k in o.filter { LyricsSourceKind.of($0) == k }.map { OwnLyricsProviders.Part(kind: k, provider: $0) } }
        } else {
            parts = order.map { k -> OwnLyricsProviders.Part in
                let p: any LyricsProvider
                switch k {
                case .apple: p = AppleMusicProvider(http: http, credentials: credentials)
                case .amll: p = amll
                case .yandex: p = YandexMusicLyricsProvider(http: http)
                case .musixmatch: p = MusixmatchLyricsProvider(http: http)
                case .netease: p = NetEaseProvider(http: http)
                case .qq: p = QQProvider(http: http)
                case .kugou: p = KuGouProvider(http: http)
                case .deezer: p = DeezerLyricsProvider(http: http)
                case .lrclib: p = LRCLIBProvider(http: http)
                }
                return OwnLyricsProviders.Part(kind: k, provider: p)
            }
        }
        let e = LyricsEngine(providers: Self.collapseOwn(parts), cache: cache)
        engineOwn = parts.filter { $0.provider.id == .local }.map(\.kind.rawValue).joined(separator: "+")
        engine = e
        engineSources = order
        memory = [:]
        return e
    }

    /// Провайдеры под `.local` (Яндекс, Deezer) — одним составным на месте первого из них: у движка память ответов
    /// по id провайдера, два `.local` получали бы ответы друг друга. Один — как есть.
    static func collapseOwn(_ parts: [OwnLyricsProviders.Part]) -> [any LyricsProvider] {
        let own = parts.filter { $0.provider.id == .local }
        guard own.count > 1 else { return parts.map(\.provider) }
        var out: [any LyricsProvider] = []
        var placed = false
        for p in parts {
            if p.provider.id != .local { out.append(p.provider) }
            else if !placed { out.append(OwnLyricsProviders(parts: own)); placed = true }
        }
        return out
    }

    /// Вход/выход в источник с учёткой (Яндекс): забыть память движка (ответы провайдеров ~10 мин — составной `.local`
    /// помнит ответ «без Яндекса»), память итогов и записи кеша без синхронизации («не найдено» и простой текст).
    func accountChanged() async -> Int {
        memory = [:]
        await engine?.clearResponseMemo()
        return purgeUnsyncedCache()
    }

    /// В памяти — несколько последних треков (текущий, прошлый, повтор), не весь кеш.
    /// Отладка (`--lyrics-lookup --fresh`): забыть итог для трека (память и дисковый кэш движка).
    func forgetForDebug(_ q: Query) {
        memory = [:]
        cache.remove(key: Self.trackQuery(q).cacheKey)
    }

    private func remember(_ key: String, _ l: Lyrics?) {
        if memory.count >= 8, memory[key] == nil { memory.removeAll() }
        memory[key] = l
    }

    // MARK: Старт

    /// Один раз за запуск (из `MediaModel.start`, в фоне): просроченное из кеша — вон; индексы AMLL — заранее, чтобы
    /// поиск по названию работал с первого трека. Индекс на диске свежее суток — сети нет (`AMLLProvider` сам сверяет
    /// дату файла с `indexTTL`), только разбор с диска. `amll == false` (источник выключен) — индексы не трогаем.
    /// Индекс AMLL (10 МБ на диске, ~31 МБ в памяти) — выключен ради бюджета памяти.
    static var useAMLLIndex = false

    @discardableResult
    func startup(amll useAMLL: Bool) async -> (purged: Int, indexes: Bool) {
        guard !prefetched else { return (0, false) }
        prefetched = true
        let purged = cache.purgeExpired()
        guard useAMLL, Self.useAMLLIndex, amllIndexDir != nil, providersOverride == nil else { return (purged, false) }
        await amll.prefetchIndexes()
        return (purged, true)
    }

    // MARK: Токен Apple Music

    /// Сохранить (или удалить — nil/пусто) media-user-token в Keychain. Значение нигде не печатается.
    func setAppleToken(_ token: String?) async -> Bool {
        let t = token?.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        do {
            try await credentials.set((t?.isEmpty ?? true) ? nil : t, for: .mediaUserToken)
            if t?.isEmpty ?? true {
                try? await credentials.set(nil, for: .appleDeveloperToken)
                try? await credentials.set(nil, for: .appleStorefront)
            }
        } catch {
            return false
        }
        memory = [:]
        return true
    }

    func hasAppleToken() async -> Bool {
        guard let v = try? await credentials.value(for: .mediaUserToken) else { return false }
        return !v.isEmpty
    }

    // MARK: Размер кеша

    /// Лимиты кеша на диске (15.11, «кеш подобный не нужен, можно чистить»): только для офлайна — не больше
    /// 200 треков и 5 МБ, не старше 30 дней. Держит сам `LyricsCache`: чистит сразу, как только запись вышла за предел.
    static let maxEntries = 200
    static let maxBytes = 5 << 20
    static let maxAge: TimeInterval = 30 * 86400

    /// Файлы каталога с размерами.
    nonisolated static func files(_ dir: URL?) -> [(URL, Int)] {
        guard let dir else { return [] }
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey],
                                                                 options: [.skipsHiddenFiles])) ?? []
        return urls.map { ($0, (try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
    }

    /// Сколько занимают тексты и индексы AMLL на диске, байт.
    func diskUsage() -> Int { (Self.files(cacheDir) + Self.files(amllIndexDir)).reduce(0) { $0 + $1.1 } }

    /// Очистить всё: тексты на диске и в памяти, индексы AMLL (скачаются заново при следующем запуске), HTTP-кеш приложения.
    func clearAll() {
        memory = [:]
        cache.removeAll()
        for f in Self.files(amllIndexDir) { try? FileManager.default.removeItem(at: f.0) }
        URLCache.shared.removeAllCachedResponses()
    }
}


/// Секреты текстов (токен Apple Music) — в файле острова (`SecretFile`, права 600), а не в Keychain: у локальной
/// подписи доступ к Keychain привязан к хэшу кода, и каждая пересборка спрашивала пароль (16.11). Прежнее значение
/// из Keychain (служба `local.simpleisland.lyrics`) переезжает один раз.
struct FileCredentialStore: CredentialStore {
    let service: String
    func value(for key: CredentialKey) async throws -> String? {
        SecretFile.shared.value(service: service, account: key.rawValue)
    }
    func set(_ value: String?, for key: CredentialKey) async throws {
        SecretFile.shared.set((value?.isEmpty ?? true) ? nil : value, service: service, account: key.rawValue)
    }
}
