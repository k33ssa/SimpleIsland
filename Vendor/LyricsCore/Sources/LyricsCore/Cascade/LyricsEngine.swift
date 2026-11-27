import Foundation

public struct FetchOptions: Sendable {
    /// Игнорировать кэш (в том числе закреплённый выбор) и искать заново.
    public var forceRefresh = false
    /// Опросить всех провайдеров до конца — для списка альтернатив. Без раннего выхода.
    public var exhaustive = false
    /// Читать/писать кэш.
    public var useCache = true
    /// Предел ожидания одного провайдера.
    public var providerTimeout: TimeInterval = 12
    /// Предел всего каскада: по истечении возвращается лучшее из уже полученного.
    public var overallTimeout: TimeInterval = 25
    /// Если точной версии нет нигде — подставить лучшее «почти совпадение» (другая версия записи) как `best`
    /// с пометкой `LyricsResult.bestIsApproximate`. `false` — near-miss остаются только в `alternatives`.
    public var allowApproximate = true
    /// Точный пословный текст уже есть у менее приоритетного источника — сколько ещё ждать более приоритетные
    /// (они могут дать то же качество, но висят до `providerTimeout`). `nil` — ждать как раньше. Не действует при `exhaustive`.
    public var wordGracePeriod: TimeInterval? = 2
    public init() {}
}

public struct ProviderOutcome: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case found(count: Int, best: SyncType)
        case notFound
        case failed(String)
        case skipped(String)
        case cancelled
    }
    public var provider: LyricsProviderID
    public var status: Status
    public var seconds: TimeInterval
    /// Краткая причина для `.notFound`, если известна («кандидатов: 5, отвергнуты по длительности: 2»).
    public var note: String? = nil
}

public struct LyricsResult: Sendable {
    /// Лучший найденный текст (`nil` — не нашли нигде).
    public var best: Lyrics?
    /// Остальные варианты: другие источники и версии — для ручного выбора.
    public var alternatives: [Lyrics]
    public var outcomes: [ProviderOutcome]
    public var fromCache: Bool
    /// Что искали (для диагностики: показать пользователю, по каким данным шёл поиск).
    public var query: TrackQuery? = nil
    /// `best` — «почти совпадение» (синхронизация другой версии записи, могла уехать по времени): показать плашку
    /// «приблизительная синхронизация» или показать текст без таймингов.
    public var bestIsApproximate: Bool = false
    /// Причина приблизительности («длительность отличается на 56 с»).
    public var approximateReason: String? = nil
    /// `false` — промежуточный результат из `lyricsUpdates(for:)` / `onUpdate`: поиск ещё идёт, `best` может улучшиться.
    public var isFinal: Bool = true

    /// Хотя бы один источник упал (сеть, таймаут, лимит, неожиданный ответ) — «не найдено» может быть ложным.
    public var hadFailures: Bool {
        outcomes.contains { if case .failed = $0.status { return true } else { return false } }
    }
    /// Все опрошенные источники упали с сетевой ошибкой «нет сети» — показать «нет подключения», а не «текста нет».
    public var isOffline: Bool {
        let asked = outcomes.filter { if case .skipped = $0.status { return false } else { return true } }
        return !asked.isEmpty && asked.allSatisfy { $0.status == .failed(LyricsError.offline.description) }
    }

    /// Apple отверг токен — пользователю нужно обновить media-user-token.
    public var appleNeedsToken: Bool {
        outcomes.contains { $0.provider == .appleMusic && ($0.status == .failed(LyricsError.unauthorized.description)) }
    }
}

/// Каскад источников: Apple → AMLL → NetEase → QQ → KuGou → LRCLIB. Пословный текст предпочтительнее построчного,
/// построчный — простого. Провайдеры опрашиваются параллельно (с ограничением), ранний выход — когда
/// никто из более приоритетных уже не может дать лучшее.
public final class LyricsEngine: Sendable {
    public struct Configuration: Sendable {
        /// Сколько провайдеров опрашивать одновременно. 3 → 6 (15.11.2026): источники на разных хостах, а при 3 KuGou и LRCLIB
        /// (самые быстрые, 0.1–0.8 с) ждали, пока освободится слот после AMLL/NetEase/QQ.
        public var maxConcurrent = 6
        public var maxAlternatives = 12
        public init() {}
    }

    /// Провайдеры в порядке приоритета.
    public let providers: [any LyricsProvider]
    public let cache: LyricsCache?
    public let configuration: Configuration

    public init(providers: [any LyricsProvider], cache: LyricsCache? = nil, configuration: Configuration = Configuration()) {
        self.providers = providers
        self.cache = cache
        self.configuration = configuration
    }

    /// Стандартный набор: Apple (если в `credentials` есть media-user-token), AMLL, NetEase, QQ, LRCLIB.
    public static func standard(credentials: CredentialStore, http: HTTPClient = URLSessionHTTPClient(),
                                cacheDirectory: URL? = nil, configuration: Configuration = Configuration()) -> LyricsEngine {
        let cache = LyricsCache(directory: cacheDirectory)
        let amllDir = cache.directory.appendingPathComponent("amll-index", isDirectory: true)
        let providers: [any LyricsProvider] = [
            AppleMusicProvider(http: http, credentials: credentials),
            AMLLProvider(http: http, cacheDirectory: amllDir),
            NetEaseProvider(http: http),
            QQProvider(http: http),
            KuGouProvider(http: http),
            LRCLIBProvider(http: http),
        ]
        return LyricsEngine(providers: providers, cache: cache, configuration: configuration)
    }

    // MARK: - публичный API

    public func lyrics(for query: TrackQuery, options: FetchOptions = FetchOptions()) async -> LyricsResult {
        await fetch(query, options: options, onUpdate: nil)
    }

    /// Как `lyrics(for:options:)`, но с промежуточными результатами: `onUpdate` вызывается каждый раз, когда `best` улучшился
    /// (первый годный текст — сразу, затем, например, пословный вместо построчного), с `isFinal == false`.
    /// Итог возвращается и передаётся в `onUpdate` последним вызовом с `isFinal == true`.
    @discardableResult
    public func lyrics(for query: TrackQuery, options: FetchOptions = FetchOptions(),
                       onUpdate: @escaping @Sendable (LyricsResult) -> Void) async -> LyricsResult {
        await fetch(query, options: options, onUpdate: onUpdate)
    }

    /// Поток результатов: промежуточные (`isFinal == false`) по мере улучшения `best`, последний — итоговый (`isFinal == true`).
    /// Прекращение чтения потока (или отмена задачи-читателя) отменяет поиск.
    public func lyricsUpdates(for query: TrackQuery, options: FetchOptions = FetchOptions()) -> AsyncStream<LyricsResult> {
        AsyncStream { continuation in
            let task = Task {
                _ = await self.fetch(query, options: options) { continuation.yield($0) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Сбросить память ответов провайдеров (её держит движок ~10 мин, чтобы исчерпывающий поиск после обычного не повторял запросы).
    public func clearResponseMemo() async { await responseMemo.removeAll() }

    private func fetch(_ query: TrackQuery, options: FetchOptions, onUpdate: (@Sendable (LyricsResult) -> Void)?) async -> LyricsResult {
        let result = await fetchFinal(query, options: options, onUpdate: onUpdate)
        onUpdate?(result)
        return result
    }

    private func fetchFinal(_ query: TrackQuery, options: FetchOptions, onUpdate: (@Sendable (LyricsResult) -> Void)?) async -> LyricsResult {
        let key = query.cacheKey
        // Исчерпывающий опрос (список альтернатив) обходит кэш, кроме закреплённого выбора.
        // Негативная запись действует только для того же запроса (отпечаток): метаданные могли дозаполниться.
        if options.useCache, !options.forceRefresh, let hit = cache?.load(key: key, fingerprint: query.fingerprint),
           hit.pinned || !options.exhaustive {
            Log.cascade.info("кэш: попадание \(key, privacy: .public)")
            var best = hit.best
            var alternatives = hit.alternatives
            if !hit.pinned, !options.allowApproximate, let b = best, b.source.matchQuality.isNearMiss {
                alternatives.insert(b, at: 0)
                best = nil
            }
            let approx = !hit.pinned && (best?.source.matchQuality.isNearMiss ?? false)
            return LyricsResult(best: best, alternatives: alternatives, outcomes: [], fromCache: true, query: query,
                                bestIsApproximate: approx, approximateReason: approx ? best?.source.matchQuality.reason : nil)
        }
        if options.forceRefresh { cache?.remove(key: key) }

        let run = await runCascade(query, options: options, onUpdate: onUpdate)
        let (best, alternatives) = Self.arrange(run.results, providerOrder: providers.map(\.id), maxAlternatives: configuration.maxAlternatives,
                                                allowApproximate: options.allowApproximate)

        if options.useCache, let cache {
            // Не кэшируем, если более приоритетный провайдер упал (временный сбой) — пусть повторит поиск.
            let bestIndex = best.flatMap { b in providers.firstIndex { $0.id == b.source.provider } } ?? providers.count
            let higherFailed = run.outcomes.enumerated().contains { (i, o) in
                if case .failed = o.status, let pi = providers.firstIndex(where: { $0.id == o.provider }) { return pi < bestIndex }
                return false
            }
            let anyFailed = run.outcomes.contains { if case .failed = $0.status { return true } else { return false } }
            // Негативную запись не пишем, если title или artist пусты: на iPhone метаданные дозаполняются позже,
            // и полный запрос с тем же catalogId не должен упереться в «не найдено».
            let skipNegative = best == nil && !query.hasSearchableMetadata
            // Поиск отменён (сменился трек) или часть источников не дослушали: «не найдено» не доказано — не кэшируем.
            let anyCancelled = run.outcomes.contains { $0.status == .cancelled }
            let interrupted = Task.isCancelled || (best == nil && anyCancelled)
            if !higherFailed && !(best == nil && anyFailed) && !run.cutByDeadline && !skipNegative && !interrupted {
                cache.store(key: key, best: best, alternatives: alternatives, fingerprint: query.fingerprint)
            }
        }
        let approx = best?.source.matchQuality.isNearMiss ?? false
        return LyricsResult(best: best, alternatives: alternatives, outcomes: run.outcomes, fromCache: false, query: query,
                            bestIsApproximate: approx, approximateReason: approx ? best?.source.matchQuality.reason : nil)
    }

    /// Закрепляет ручной выбор пользователя: он сохраняется в кэше без срока давности.
    public func select(_ lyrics: Lyrics, for query: TrackQuery, alternatives: [Lyrics] = []) {
        cache?.store(key: query.cacheKey, best: lyrics, alternatives: alternatives, pinned: true)
    }

    /// Снять ручной выбор.
    public func clearSelection(for query: TrackQuery) {
        cache?.remove(key: query.cacheKey)
    }

    // MARK: - ранжирование

    /// Ключ сортировки: чем меньше, тем лучше. Сначала тип синхронизации, затем приоритет источника, затем уверенность.
    static func rankKey(_ l: Lyrics, providerOrder: [LyricsProviderID]) -> (Int, Int, Double) {
        let sync: Int
        switch l.syncType {
        case .word: sync = 0
        case .line: sync = 1
        case .none: sync = 2
        }
        let p = providerOrder.firstIndex(of: l.source.provider) ?? providerOrder.count
        return (sync, p, -l.source.confidence)
    }

    /// Выбор лучшего: точный пословный → точный построчный → точный простой → (если `allowApproximate`) near-miss в том же порядке.
    /// Near-miss, ставший `best`, остаётся помеченным `.nearMiss` (см. `LyricsResult.bestIsApproximate`).
    static func arrange(_ all: [Lyrics], providerOrder: [LyricsProviderID], maxAlternatives: Int,
                        allowApproximate: Bool = true) -> (Lyrics?, [Lyrics]) {
        let nearMisses = all.filter { $0.source.matchQuality.isNearMiss && !$0.isEmpty }
        let all = all.filter { !$0.source.matchQuality.isNearMiss }
        // Пустой «инструментал» не должен вытеснять реальный текст.
        let real = all.filter { !$0.isEmpty }
        let instrumental = all.first { $0.isInstrumental }
        let sorted = real.sorted { a, b in
            let ka = rankKey(a, providerOrder: providerOrder), kb = rankKey(b, providerOrder: providerOrder)
            if ka.0 != kb.0 { return ka.0 < kb.0 }
            if ka.1 != kb.1 { return ka.1 < kb.1 }
            return ka.2 < kb.2
        }
        var seen = Set<String>()
        var unique: [Lyrics] = []
        for l in sorted {
            let k = "\(l.source.provider.rawValue)|\(l.source.trackID ?? "")|\(l.source.format ?? "")|\(l.syncType.rawValue)"
            if seen.insert(k).inserted { unique.append(l) }
        }
        var near = sortedNearMisses(nearMisses, providerOrder: providerOrder)
        if let best = unique.first { return (best, Array(unique.dropFirst().prefix(maxAlternatives)) + near) }
        if let instrumental { return (instrumental, near) }
        if allowApproximate, !near.isEmpty { return (near.removeFirst(), near) }
        return (nil, near)
    }

    /// Near-miss: пословный → построчный → простой, внутри — по уверенности, затем по приоритету источника; без дублей; не больше `maxNearMisses`.
    static let maxNearMisses = 4
    static func sortedNearMisses(_ list: [Lyrics], providerOrder: [LyricsProviderID]) -> [Lyrics] {
        let sorted = list.sorted { a, b in
            if a.syncType != b.syncType { return a.syncType > b.syncType }
            if a.source.confidence != b.source.confidence { return a.source.confidence > b.source.confidence }
            let pa = providerOrder.firstIndex(of: a.source.provider) ?? providerOrder.count
            let pb = providerOrder.firstIndex(of: b.source.provider) ?? providerOrder.count
            if pa != pb { return pa < pb }
            return a.syncType > b.syncType
        }
        var seen = Set<String>()
        return sorted.filter { seen.insert("\($0.source.provider.rawValue)|\($0.source.trackID ?? "")|\($0.source.format ?? "")").inserted }
            .prefix(maxNearMisses).map { $0 }
    }

    // MARK: - каскад

    /// Ошибка провайдера → статус. «Не JSON» (HTML-заглушка, капча, страница блокировки) — сбой, а не «не найдено».
    static func status(for error: Error) -> ProviderOutcome.Status {
        if error is CancellationError { return .cancelled }
        if let e = error as? LyricsError { return e == .cancelled ? .cancelled : .failed(e.description) }
        if let u = error as? URLError { return u.code == .cancelled ? .cancelled : .failed(LyricsError.from(u).description) }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, (3840...3851).contains(ns.code) || ns.code == 4864 || ns.code == 4865 {
            return .failed(LyricsError.badResponse("не JSON (страница-заглушка, капча или блокировка?)").description)
        }
        return .failed("\(type(of: error))")
    }

    private struct RunResult {
        var results: [Lyrics]
        var outcomes: [ProviderOutcome]
        var cutByDeadline: Bool
    }

    private actor Collector {
        var results: [Lyrics] = []
        var outcomes: [Int: ProviderOutcome] = [:]
        var finished = Set<Int>()
        var bestWordProvider: Int?
        var hints = TrackHints()

        func addHints(_ h: TrackHints?) { if let h { hints.merge(h) } }
        func replace(index: Int, outcome: ProviderOutcome, lyrics: [Lyrics]) {
            outcomes[index] = outcome
            results.append(contentsOf: lyrics)
        }
        func add(index: Int, outcome: ProviderOutcome, lyrics: [Lyrics]) {
            outcomes[index] = outcome
            finished.insert(index)
            results.append(contentsOf: lyrics)
            if lyrics.contains(where: { $0.syncType == .word && !$0.isEmpty && !$0.source.matchQuality.isNearMiss }) {
                bestWordProvider = min(bestWordProvider ?? index, index)
            }
        }
        /// Можно остановиться: есть пословный результат, и все более приоритетные провайдеры уже ответили.
        func canStop() -> Bool {
            guard let p = bestWordProvider else { return false }
            return (0..<p).allSatisfy { finished.contains($0) }
        }
        func snapshot() -> ([Lyrics], [Int: ProviderOutcome]) { (results, outcomes) }
        var hasExactWord: Bool { bestWordProvider != nil }

        var lastEmittedKey: String?
        /// Промежуточный результат, если `best` изменился с прошлого раза (иначе `nil`).
        func progress(providerOrder: [LyricsProviderID], maxAlternatives: Int, allowApproximate: Bool, query: TrackQuery) -> LyricsResult? {
            let (best, alts) = LyricsEngine.arrange(results, providerOrder: providerOrder, maxAlternatives: maxAlternatives,
                                                     allowApproximate: allowApproximate)
            guard let best else { return nil }
            let key = "\(best.source.provider.rawValue)|\(best.source.trackID ?? "")|\(best.syncType.rawValue)|\(best.source.matchQuality.isNearMiss)"
            guard key != lastEmittedKey else { return nil }
            lastEmittedKey = key
            let approx = best.source.matchQuality.isNearMiss
            return LyricsResult(best: best, alternatives: alts, outcomes: outcomes.keys.sorted().compactMap { outcomes[$0] }, fromCache: false,
                                query: query, bestIsApproximate: approx, approximateReason: approx ? best.source.matchQuality.reason : nil,
                                isFinal: false)
        }
    }

    /// Память ответов провайдеров (только успешных) на ~10 мин: исчерпывающий поиск альтернатив после обычного и повторный
    /// показ того же трека не повторяют сетевые запросы. Ключ — провайдер + все поля запроса, влияющие на поиск.
    private let responseMemo = ResponseMemo<ProviderResponse>(ttl: 600, capacity: 300)

    static func memoKey(_ p: LyricsProviderID, _ q: TrackQuery) -> String {
        [p.rawValue, q.fingerprint, q.catalogId ?? "", q.isrc ?? "", q.album ?? "", q.neteaseId ?? "", q.qqSongMid ?? "", q.storefront ?? ""]
            .joined(separator: "|")
    }

    private enum GroupEvent: Sendable { case provider, graceTimer }

    private func runCascade(_ query: TrackQuery, options: FetchOptions, onUpdate: (@Sendable (LyricsResult) -> Void)?) async -> RunResult {
        let collector = Collector()
        let providers = self.providers
        let order = providers.map(\.id)
        let limit = max(1, configuration.maxConcurrent)
        let maxAlternatives = configuration.maxAlternatives
        let memo = (options.useCache && !options.forceRefresh) ? responseMemo : nil
        if options.forceRefresh { for p in providers { await responseMemo.remove(Self.memoKey(p.id, query)) } }
        var cut = false

        // Деактивированных (нет токена) отсеиваем заранее, чтобы они не занимали слоты.
        var active: [Int] = []
        for (i, p) in providers.enumerated() {
            if await p.isAvailable() { active.append(i) }
            else {
                await collector.add(index: i, outcome: ProviderOutcome(provider: p.id, status: .skipped("недоступен"), seconds: 0), lyrics: [])
            }
        }

        let deadline = Date().addingTimeInterval(options.overallTimeout)
        await withTaskGroup(of: GroupEvent.self) { group in
            var next = 0
            var running = 0
            var graceArmed = false

            func launch(_ i: Int) {
                let provider = providers[i]
                running += 1
                group.addTask {
                    let started = Date()
                    let outcome: ProviderOutcome
                    var found: [Lyrics] = []
                    var hints: TrackHints?
                    do {
                        let limitSeconds = min(options.providerTimeout, max(0.2, deadline.timeIntervalSinceNow))
                        let key = Self.memoKey(provider.id, query)
                        let response: ProviderResponse
                        if let memo, let cached = await memo.get(key) {
                            response = cached
                        } else {
                            response = try await withDeadline(limitSeconds) { try await provider.response(for: query) }
                            if !Task.isCancelled { await self.responseMemo.set(key, response) }
                        }
                        hints = response.hints
                        found = response.lyrics.filter { !$0.lines.isEmpty || $0.isInstrumental }
                        let exact = found.filter { !$0.source.matchQuality.isNearMiss }
                        let nearCount = found.count - exact.count
                        if let top = exact.map(\.syncType).max() {
                            outcome = ProviderOutcome(provider: provider.id, status: .found(count: exact.count, best: top), seconds: Date().timeIntervalSince(started))
                        } else {
                            var note = response.note
                            if nearCount > 0 {
                                let n = "только почти совпадения: \(nearCount) (другая версия записи)"
                                note = note.map { "\($0); \(n)" } ?? n
                            }
                            outcome = ProviderOutcome(provider: provider.id, status: .notFound, seconds: Date().timeIntervalSince(started), note: note)
                        }
                    } catch {
                        outcome = ProviderOutcome(provider: provider.id, status: Self.status(for: error), seconds: Date().timeIntervalSince(started))
                    }
                    await collector.addHints(hints)
                    await collector.add(index: i, outcome: outcome, lyrics: found)
                    if let onUpdate, let p = await collector.progress(providerOrder: order, maxAlternatives: maxAlternatives,
                                                                       allowApproximate: options.allowApproximate, query: query) {
                        onUpdate(p)
                    }
                    Log.cascade.info("\(provider.id.rawValue, privacy: .public): \(String(describing: outcome.status), privacy: .public) за \(String(format: "%.1f", outcome.seconds), privacy: .public) с")
                    return .provider
                }
            }

            while next < active.count && running < limit { launch(active[next]); next += 1 }
            loop: while running > 0 {
                guard let event = await group.next() else { break }
                switch event {
                case .graceTimer:
                    // Пословный уже есть, а более приоритетные не ответили за отведённое время — не ждём их до таймаута.
                    Log.cascade.info("пословный уже есть — не ждём остальных дольше \(options.wordGracePeriod ?? 0, privacy: .public) с")
                    break loop
                case .provider:
                    running -= 1
                    if !options.exhaustive, await collector.canStop() { break loop }
                    if !options.exhaustive, !graceArmed, let grace = options.wordGracePeriod, await collector.hasExactWord {
                        graceArmed = true
                        group.addTask {
                            try? await Task.sleep(nanoseconds: UInt64(max(0, grace) * 1_000_000_000))
                            return .graceTimer
                        }
                    }
                    // Пословный есть: менее приоритетные запускать незачем (лучше не дадут), ждём только более приоритетные.
                    if next < active.count, !(await collector.hasExactWord && !options.exhaustive) { launch(active[next]); next += 1 }
                }
            }
            group.cancelAll()
        }
        cut = Date() >= deadline

        // Связки: id, найденные одними провайдерами (NetEase → neteaseId, QQ → qqSongMid), отдаём тем, кто умеет искать по ним
        // (AMLL), если у них с первого раза не вышло. Один повторный запрос на провайдера.
        let learned = await collector.hints
        var enriched = query
        enriched.neteaseId = enriched.neteaseId ?? learned.neteaseId
        enriched.qqSongMid = enriched.qqSongMid ?? learned.qqSongMid
        let retryQuery = enriched
        if retryQuery != query, !cut, !Task.isCancelled {
            let (_, current) = await collector.snapshot()
            let haveWord = await collector.hasExactWord
            for i in active where providers[i].usesCrossProviderIDs {
                if case .found = current[i]?.status { continue }
                if current[i]?.status == .cancelled { continue }   // его не дождались — повтор тоже не ждём
                var remaining = deadline.timeIntervalSinceNow
                // пословный уже есть — повтор лишь уточняет источник, долго не ждём
                if haveWord, !options.exhaustive, let g = options.wordGracePeriod { remaining = min(remaining, max(g, 1)) }
                guard remaining > 0.5 else { break }
                let started = Date()
                guard let response = try? await withDeadline(min(options.providerTimeout, remaining), { try await providers[i].response(for: retryQuery) }) else { continue }
                let found = response.lyrics.filter { !$0.lines.isEmpty || $0.isInstrumental }
                let exact = found.filter { !$0.source.matchQuality.isNearMiss }
                guard !found.isEmpty else { continue }
                let status: ProviderOutcome.Status = exact.map(\.syncType).max().map { .found(count: exact.count, best: $0) } ?? .notFound
                await collector.replace(index: i, outcome: ProviderOutcome(provider: providers[i].id, status: status,
                                                                          seconds: (current[i]?.seconds ?? 0) + Date().timeIntervalSince(started),
                                                                          note: "повторный поиск по id из других сервисов"), lyrics: found)
                if let onUpdate, let p = await collector.progress(providerOrder: providers.map(\.id), maxAlternatives: configuration.maxAlternatives,
                                                                   allowApproximate: options.allowApproximate, query: query) {
                    onUpdate(p)
                }
            }
        }

        let (results, outcomeMap) = await collector.snapshot()
        let outcomes = outcomeMap.keys.sorted().compactMap { outcomeMap[$0] }
        return RunResult(results: results, outcomes: outcomes, cutByDeadline: cut)
    }
}
