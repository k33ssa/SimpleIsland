import XCTest
@testable import LyricsCore

struct FakeProvider: LyricsProvider {
    var id: LyricsProviderID
    var delay: TimeInterval = 0
    var available = true
    var result: @Sendable () throws -> [Lyrics]
    var onCall: (@Sendable () -> Void)? = nil

    func isAvailable() async -> Bool { available }
    func lyrics(for query: TrackQuery) async throws -> [Lyrics] {
        onCall?()
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
        return try result()
    }
}

func fakeLyrics(_ p: LyricsProviderID, _ sync: SyncType, confidence: Double = 0.9, trackID: String = "1") -> Lyrics {
    let line: LyricLine
    switch sync {
    case .word: line = LyricLine(key: "L1", begin: 1, end: 2, words: [LyricWord(text: "hi", begin: 1, end: 2)])
    case .line: line = LyricLine(key: "L1", begin: 1, end: 2, text: "hi")
    case .none: line = LyricLine(key: "L1", text: "hi")
    }
    return Lyrics(source: LyricsSource(provider: p, trackID: trackID, confidence: confidence, matchKind: .metadata),
                  syncType: sync, lines: [line])
}

final class EngineTests: XCTestCase {
    let query = TrackQuery(catalogId: "42", title: "T", artist: "A", duration: 100)

    func tmp() -> LyricsCache {
        LyricsCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("cache-\(UUID().uuidString)"))
    }

    func testPrefersWordOverLineRegardlessOfSourceOrder() async {
        var o = FetchOptions(); o.useCache = false
        let engine = LyricsEngine(providers: [
            FakeProvider(id: .appleMusic, result: { [fakeLyrics(.appleMusic, .line)] }),
            // AMLL с задержкой: иначе мгновенные заглушки гоняются за слот, и QQ мог стартовать раньше, чем записан пословный NetEase
            FakeProvider(id: .amll, delay: 0.1, result: { [] }),
            FakeProvider(id: .netease, result: { [fakeLyrics(.netease, .word)] }),
            FakeProvider(id: .qq, result: { [fakeLyrics(.qq, .word)] }),
            FakeProvider(id: .lrclib, result: { [fakeLyrics(.lrclib, .none)] }),
        ], configuration: { var c = LyricsEngine.Configuration(); c.maxConcurrent = 3; return c }())   // по умолчанию теперь 6 — все сразу
        let r = await engine.lyrics(for: query, options: o)
        XCTAssertEqual(r.best?.source.provider, .netease)             // пословный NetEase раньше построчного Apple
        // ранний выход: QQ и LRCLIB не опрашивались — выше по приоритету уже есть пословный результат
        XCTAssertEqual(r.alternatives.map(\.source.provider), [.appleMusic])
        XCTAssertEqual(r.outcomes.count, 3)
        o.exhaustive = true
        let full = await engine.lyrics(for: query, options: o)
        XCTAssertEqual(full.best?.source.provider, .netease)
        XCTAssertEqual(full.alternatives.map(\.source.provider), [.qq, .appleMusic, .lrclib])
        XCTAssertEqual(full.outcomes.count, 5)
    }

    func testEarlyExitOnAppleWord() async {
        let slowCalled = Counter()
        let engine = LyricsEngine(providers: [
            FakeProvider(id: .appleMusic, delay: 0.05, result: { [fakeLyrics(.appleMusic, .word)] }),
            FakeProvider(id: .amll, delay: 5, result: { [fakeLyrics(.amll, .word)] }, onCall: { _ = slowCalled.increment() }),
            FakeProvider(id: .netease, delay: 5, result: { [fakeLyrics(.netease, .word)] }, onCall: { _ = slowCalled.increment() }),
        ])
        var o = FetchOptions(); o.useCache = false
        let t0 = Date()
        let r = await engine.lyrics(for: query, options: o)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 2, "не ждали медленных провайдеров")
        XCTAssertEqual(r.best?.source.provider, .appleMusic)
        XCTAssertEqual(r.best?.syncType, .word)
    }

    func testWaitsForHigherPriorityBeforeStopping() async {
        // Apple медленнее AMLL: AMLL с пословным текстом не должен заканчивать поиск раньше Apple.
        let engine = LyricsEngine(providers: [
            FakeProvider(id: .appleMusic, delay: 0.3, result: { [fakeLyrics(.appleMusic, .word)] }),
            FakeProvider(id: .amll, result: { [fakeLyrics(.amll, .word)] }),
        ])
        var o = FetchOptions(); o.useCache = false
        let r = await engine.lyrics(for: query, options: o)
        XCTAssertEqual(r.best?.source.provider, .appleMusic)
        XCTAssertEqual(r.alternatives.first?.source.provider, .amll)
    }

    func testExhaustiveRunsEverything() async {
        let engine = LyricsEngine(providers: [
            FakeProvider(id: .appleMusic, result: { [fakeLyrics(.appleMusic, .word)] }),
            FakeProvider(id: .lrclib, delay: 0.1, result: { [fakeLyrics(.lrclib, .line)] }),
        ])
        var o = FetchOptions(); o.useCache = false; o.exhaustive = true
        let r = await engine.lyrics(for: query, options: o)
        XCTAssertEqual(r.alternatives.map(\.source.provider), [.lrclib])
    }

    func testUnavailableProviderSkippedFailureDoesNotBreak() async {
        let engine = LyricsEngine(providers: [
            FakeProvider(id: .appleMusic, available: false, result: { XCTFail("не должен вызываться"); return [] }),
            FakeProvider(id: .amll, result: { throw LyricsError.network("down") }),
            FakeProvider(id: .lrclib, result: { [fakeLyrics(.lrclib, .line)] }),
        ])
        var o = FetchOptions(); o.useCache = false
        let r = await engine.lyrics(for: query, options: o)
        XCTAssertEqual(r.best?.source.provider, .lrclib)
        XCTAssertEqual(r.outcomes[0].status, .skipped("недоступен"))
        if case .failed = r.outcomes[1].status {} else { XCTFail("\(r.outcomes[1])") }
    }

    func testProviderTimeout() async {
        let engine = LyricsEngine(providers: [
            FakeProvider(id: .amll, delay: 10, result: { [fakeLyrics(.amll, .word)] }),
            FakeProvider(id: .lrclib, result: { [fakeLyrics(.lrclib, .line)] }),
        ])
        var o = FetchOptions(); o.useCache = false; o.providerTimeout = 0.2
        let t0 = Date()
        let r = await engine.lyrics(for: query, options: o)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 3)
        XCTAssertEqual(r.best?.source.provider, .lrclib)
    }

    func testCancellationStopsQuickly() async {
        let engine = LyricsEngine(providers: [FakeProvider(id: .amll, delay: 30, result: { [fakeLyrics(.amll, .word)] })])
        let task = Task { await engine.lyrics(for: query, options: { var o = FetchOptions(); o.useCache = false; return o }()) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        let t0 = Date()
        _ = await task.value
        XCTAssertLessThan(Date().timeIntervalSince(t0), 3)
    }

    func testConcurrencyLimit() async {
        let running = Counter(), maxSeen = Counter()
        struct Probe: LyricsProvider {
            var id: LyricsProviderID
            var running: Counter, maxSeen: Counter
            func lyrics(for query: TrackQuery) async throws -> [Lyrics] {
                let n = running.increment()
                if n > maxSeen.value { maxSeen.set(n) }
                defer { running.decrementOnly() }
                try await Task.sleep(nanoseconds: 60_000_000)
                return []
            }
        }
        let providers: [any LyricsProvider] = (0..<6).map { Probe(id: LyricsProviderID.allCases[$0 % 5], running: running, maxSeen: maxSeen) }
        var cfg = LyricsEngine.Configuration(); cfg.maxConcurrent = 2
        let engine = LyricsEngine(providers: providers, configuration: cfg)
        var o = FetchOptions(); o.useCache = false
        _ = await engine.lyrics(for: query, options: o)
        XCTAssertLessThanOrEqual(maxSeen.value, 2)
        XCTAssertEqual(maxSeen.value, 2)
    }

    // MARK: кэш в каскаде

    func testCacheHitSkipsProviders() async {
        let calls = Counter()
        let engine = LyricsEngine(providers: [FakeProvider(id: .lrclib, result: { [fakeLyrics(.lrclib, .line)] }, onCall: { _ = calls.increment() })], cache: tmp())
        _ = await engine.lyrics(for: query)
        let r2 = await engine.lyrics(for: query)
        XCTAssertTrue(r2.fromCache)
        XCTAssertEqual(r2.best?.source.provider, .lrclib)
        XCTAssertEqual(calls.value, 1)
        var force = FetchOptions(); force.forceRefresh = true
        let r3 = await engine.lyrics(for: query, options: force)
        XCTAssertFalse(r3.fromCache)
        XCTAssertEqual(calls.value, 2)
    }

    func testFailureOfHigherPriorityProviderIsNotCached() async {
        let engine = LyricsEngine(providers: [
            FakeProvider(id: .appleMusic, result: { throw LyricsError.network("blip") }),
            FakeProvider(id: .lrclib, result: { [fakeLyrics(.lrclib, .line)] }),
        ], cache: tmp())
        _ = await engine.lyrics(for: query)
        XCTAssertNil(engine.cache?.load(key: query.cacheKey))
    }

    func testNegativeResultIsCachedOnlyWhenNoFailures() async {
        let clean = LyricsEngine(providers: [FakeProvider(id: .lrclib, result: { [] })], cache: tmp())
        _ = await clean.lyrics(for: query)
        XCTAssertNotNil(clean.cache?.load(key: query.cacheKey))
        let failing = LyricsEngine(providers: [FakeProvider(id: .lrclib, result: { throw LyricsError.network("x") })], cache: tmp())
        _ = await failing.lyrics(for: query)
        XCTAssertNil(failing.cache?.load(key: query.cacheKey))
    }

    func testPinnedSelectionSurvivesAutomaticRefresh() async {
        let engine = LyricsEngine(providers: [FakeProvider(id: .lrclib, result: { [fakeLyrics(.lrclib, .line, trackID: "auto")] })], cache: tmp())
        engine.select(fakeLyrics(.qq, .word, trackID: "manual"), for: query)
        let r = await engine.lyrics(for: query)
        XCTAssertEqual(r.best?.source.trackID, "manual")
        XCTAssertTrue(r.fromCache)
        // принудительное обновление сбрасывает выбор
        var f = FetchOptions(); f.forceRefresh = true
        let r2 = await engine.lyrics(for: query, options: f)
        XCTAssertEqual(r2.best?.source.trackID, "auto")
    }

    func testInstrumentalDoesNotDisplaceRealLyrics() {
        let inst = Lyrics(source: LyricsSource(provider: .lrclib), syncType: .none, lines: [], isInstrumental: true)
        let (best, alts) = LyricsEngine.arrange([inst, fakeLyrics(.qq, .line)], providerOrder: LyricsProviderID.allCases, maxAlternatives: 5)
        XCTAssertEqual(best?.source.provider, .qq)
        XCTAssertTrue(alts.isEmpty)
        let (only, _) = LyricsEngine.arrange([inst], providerOrder: LyricsProviderID.allCases, maxAlternatives: 5)
        XCTAssertTrue(only?.isInstrumental == true)
    }
}

