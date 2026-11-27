import XCTest
@testable import LyricsCore

/// Аудит 15.11.2026: скорость каскада, классификация ошибок, дыры сопоставления. Фикстуры синтетические.
final class AuditMatchingTests: XCTestCase {
    let matcher = TrackMatcher()

    // MARK: транслит

    func testLatinSkeletonBridgesCyrillicAndLatin() {
        XCTAssertEqual(TextNormalizer.latinSkeleton("кино"), TextNormalizer.latinSkeleton("kino"))
        XCTAssertEqual(TextNormalizer.latinSkeleton(TextNormalizer.fold("Оксимирон")), TextNormalizer.latinSkeleton(TextNormalizer.fold("Oxxxymiron")))
        XCTAssertEqual(TextNormalizer.latinSkeleton(TextNormalizer.fold("Тима Белорусских")), TextNormalizer.latinSkeleton(TextNormalizer.fold("Tima Belorusskikh")))
        XCTAssertEqual(TextNormalizer.latinSkeleton(TextNormalizer.fold("Монеточка")), TextNormalizer.latinSkeleton(TextNormalizer.fold("Monetochka")))
        XCTAssertGreaterThanOrEqual(TextNormalizer.similarity("земфира", "zemfira"), 0.95)
        // разные слова в разных алфавитах остаются разными
        XCTAssertLessThan(TextNormalizer.similarity("кино", "queen"), 0.6)
    }

    func testMatcherAcceptsTransliteratedArtist() {
        let q = TrackQuery(title: "Группа крови", artist: "Кино", duration: 285)
        XCTAssertTrue(matcher.evaluate(q, TrackCandidate(id: "1", title: "Группа крови", artists: ["Kino"], duration: 284)).accepted)
        let q2 = TrackQuery(title: "Город под подошвой", artist: "Oxxxymiron", duration: 277)
        XCTAssertTrue(matcher.evaluate(q2, TrackCandidate(id: "2", title: "Город под подошвой", artists: ["Оксимирон"], duration: 276)).accepted)
        // название латиницей, исполнитель кириллицей
        let q3 = TrackQuery(title: "Gruppa krovi", artist: "Kino", duration: 285)
        XCTAssertTrue(matcher.evaluate(q3, TrackCandidate(id: "3", title: "Группа крови", artists: ["Кино"], duration: 285)).accepted)
    }

    // MARK: ложные совпадения

    func testSimilarButDifferentArtistRejected() {
        let q = TrackQuery(title: "Hold On", artist: "Drake", duration: 200)
        let e = matcher.evaluate(q, TrackCandidate(id: "1", title: "Hold On", artists: ["Blake"], duration: 201))
        XCTAssertFalse(e.accepted, "drake/blake = 0.6 по Левенштейну — раньше принималось")
    }

    func testTitleContainmentNotEnough() {
        let q = TrackQuery(title: "Love", artist: "Some Band", duration: 200)
        XCTAssertFalse(matcher.evaluate(q, TrackCandidate(id: "1", title: "Love Story", artists: ["Some Band"], duration: 200)).accepted)
    }

    func testCandidateWithoutArtistNeedsDuration() {
        let q = TrackQuery(title: "Hello", artist: "Adele")
        XCTAssertFalse(matcher.evaluate(q, TrackCandidate(id: "1", title: "Hello", artists: [""])).accepted)
        let qd = TrackQuery(title: "Hello", artist: "Adele", duration: 295)
        XCTAssertTrue(matcher.evaluate(qd, TrackCandidate(id: "1", title: "Hello", artists: [""], duration: 295)).accepted)
    }

    func testCollaborationsAndVersionsStillMatch() {
        let q = TrackQuery(title: "Die With A Smile", artist: "Lady Gaga & Bruno Mars", duration: 252)
        XCTAssertTrue(matcher.evaluate(q, TrackCandidate(id: "1", title: "Die With A Smile", artists: ["Lady Gaga", "Bruno Mars"], duration: 251)).accepted)
        XCTAssertTrue(matcher.evaluate(q, TrackCandidate(id: "2", title: "Die With A Smile", artists: ["Lady Gaga"], duration: 251)).accepted)
        let q2 = TrackQuery(title: "Take What You Want (feat. Ozzy Osbourne & Travis Scott)", artist: "Post Malone", duration: 230)
        XCTAssertTrue(matcher.evaluate(q2, TrackCandidate(id: "3", title: "Take What You Want", artists: ["Post Malone", "Ozzy Osbourne", "Travis Scott"], duration: 229)).accepted)
        let q3 = TrackQuery(title: "Here Comes the Sun - Remastered 2009", artist: "The Beatles", duration: 186)
        XCTAssertTrue(matcher.evaluate(q3, TrackCandidate(id: "4", title: "Here Comes The Sun", artists: ["The Beatles"], duration: 185)).accepted)
    }

    // MARK: LRCLIB: допуск длительности

    func testLRCLIBForeignVersionSevenSecondsOffIsNearMissNotExact() async throws {
        let http = MockHTTP()
        http.on("/api/get?", status: 404, body: "{}")
        http.on("/api/search", body: json([
            ["id": 1, "trackName": "Test Song", "artistName": "Test Artist", "duration": 207, "syncedLyrics": "[00:01.00]other version"],
        ]))
        let r = try await LRCLIBProvider(http: http).response(for: TrackQuery(title: "Test Song", artist: "Test Artist", duration: 200))
        XCTAssertEqual(r.lyrics.count, 1)
        XCTAssertTrue(r.lyrics[0].source.matchQuality.isNearMiss, "7 с — другая версия: только как near-miss")
    }
}

final class AuditErrorTests: XCTestCase {
    func tmpCache() -> LyricsCache {
        LyricsCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("audit-\(UUID().uuidString)"))
    }

    func testLRCLIBHTMLIsFailureNotNotFound() async {
        let http = MockHTTP()
        http.on("/api/get?", body: "<!DOCTYPE html><html><body>Just a moment...</body></html>")
        http.on("/api/search", body: "<html><body>captcha</body></html>")
        let engine = LyricsEngine(providers: [LRCLIBProvider(http: http)], cache: tmpCache())
        let q = TrackQuery(title: "Test Song", artist: "Test Artist", duration: 200)
        let r = await engine.lyrics(for: q)
        guard case .failed(let msg) = r.outcomes.first?.status else { return XCTFail("ожидался сбой, а не «не найдено»: \(String(describing: r.outcomes.first?.status))") }
        XCTAssertTrue(msg.contains("HTML"), msg)
        XCTAssertTrue(r.hadFailures)
        XCTAssertNil(engine.cache?.load(key: q.cacheKey, fingerprint: q.fingerprint), "после сбоя «не найдено» не кэшируется")
    }

    func testNetEaseAntiBotCodeIsRateLimited() async {
        let http = MockHTTP()
        http.on("/api/search/get", body: json(["code": -460, "message": "网络太拥挤，请稍候再试！"]))
        let engine = LyricsEngine(providers: [NetEaseProvider(http: http)])
        var o = FetchOptions(); o.useCache = false
        let r = await engine.lyrics(for: TrackQuery(title: "Test Song", artist: "Test Artist", duration: 200), options: o)
        XCTAssertEqual(r.outcomes.first?.status, .failed(LyricsError.rateLimited(retryAfter: nil).description))
    }

    func testQQBodyCodeFallsThroughChain() async throws {
        let http = MockHTTP()
        http.on("client_search_cp", body: json(["code": 500003, "data": [:]]))
        http.on("search_for_qq_cp", body: json(["code": 0, "data": ["song": ["list": [
            ["songid": 7, "songmid": "M7", "songname": "Test Song", "singer": [["name": "Test Artist"]], "interval": 200]]]]]))
        http.on("lyric_download", method: "POST", body: "<!--<?xml version=\"1.0\"?><QrcInfos></QrcInfos>-->")
        http.on("fcg_query_lyric_new", body: json(["retcode": 0, "lyric": Data("[00:01.00]one\n[00:03.00]two".utf8).base64EncodedString()]))
        let r = try await QQProvider(http: http).response(for: TrackQuery(title: "Test Song", artist: "Test Artist", duration: 200))
        XCTAssertEqual(r.lyrics.first?.syncType, .line)
    }

    func testOneCandidateFailureDoesNotLoseOthers() async throws {
        let http = MockHTTP()
        http.on("/api/search/get", body: json(["result": ["songs": [
            ["id": 222, "name": "Test Song", "artists": [["name": "Test Artist"]], "duration": 200300],
            ["id": 333, "name": "Test Song", "artists": [["name": "Test Artist"]], "duration": 200100],
        ]]]))
        http.on("id=222", status: 503, body: "")
        http.on("id=333", body: json(["code": 200, "lrc": ["lyric": "[00:01.00]one\n[00:02.00]two"]]))
        let r = try await NetEaseProvider(http: http).response(for: TrackQuery(title: "Test Song", artist: "Test Artist", duration: 200))
        XCTAssertEqual(r.lyrics.count, 1)
        // а если упали все кандидаты — это сбой, не «не найдено»
        let bad = MockHTTP()
        bad.on("/api/search/get", body: json(["result": ["songs": [["id": 222, "name": "Test Song", "artists": [["name": "Test Artist"]], "duration": 200300]]]]))
        bad.on("/api/song/lyric", status: 503, body: "")
        do {
            _ = try await NetEaseProvider(http: bad).response(for: TrackQuery(title: "Test Song", artist: "Test Artist", duration: 200))
            XCTFail("ожидался сбой")
        } catch { XCTAssertEqual(error as? LyricsError, .badStatus(503)) }
    }

    func testCancelledSearchDoesNotWriteNegativeCache() async {
        let cache = tmpCache()
        let engine = LyricsEngine(providers: [
            FakeProvider(id: .amll, result: { [] }),
            FakeProvider(id: .netease, delay: 5, result: { [fakeLyrics(.netease, .word)] }),
        ], cache: cache)
        let q = TrackQuery(title: "T", artist: "A", duration: 100)
        let task = Task { await engine.lyrics(for: q) }
        try? await Task.sleep(nanoseconds: 150_000_000)
        task.cancel()   // сменился трек
        let r = await task.value
        XCTAssertNil(r.best)
        XCTAssertNil(cache.load(key: q.cacheKey, fingerprint: q.fingerprint), "отменённый поиск не должен оставлять «не найдено» на 30 мин")
    }

    func testOfflineClassification() {
        XCTAssertEqual(LyricsError.from(URLError(.notConnectedToInternet)), .offline)
        XCTAssertEqual(LyricsError.from(URLError(.timedOut)), .network("таймаут запроса"))
        XCTAssertTrue(LyricsError.offline.isTransient)
        XCTAssertFalse(LyricsError.notFound.isTransient)
        let r = LyricsResult(best: nil, alternatives: [], outcomes: [
            ProviderOutcome(provider: .appleMusic, status: .skipped("недоступен"), seconds: 0),
            ProviderOutcome(provider: .netease, status: .failed(LyricsError.offline.description), seconds: 0),
            ProviderOutcome(provider: .lrclib, status: .failed(LyricsError.offline.description), seconds: 0),
        ], fromCache: false)
        XCTAssertTrue(r.isOffline)
        XCTAssertEqual(LyricsEngine.status(for: URLError(.notConnectedToInternet)), .failed(LyricsError.offline.description))
        let nsJSON = NSError(domain: NSCocoaErrorDomain, code: 3840)
        guard case .failed(let m) = LyricsEngine.status(for: nsJSON) else { return XCTFail() }
        XCTAssertTrue(m.contains("не JSON"))
    }

    func testRetryPolicy() {
        XCTAssertNotNil(URLSessionHTTPClient.retryDelay(status: 503, retryAfter: nil))
        XCTAssertNotNil(URLSessionHTTPClient.retryDelay(status: 429, retryAfter: 1))
        XCTAssertNil(URLSessionHTTPClient.retryDelay(status: 429, retryAfter: 30), "долгий Retry-After — не ждём, сразу сбой")
        XCTAssertNil(URLSessionHTTPClient.retryDelay(status: 404, retryAfter: nil))
        XCTAssertNil(URLSessionHTTPClient.retryDelay(status: 200, retryAfter: nil))
    }
}

final class AuditKuGouTests: XCTestCase {
    func testEmptyV2ResponseIsRetriedThenMobileFallback() async throws {
        let http = MockHTTP()
        http.on("song_search_v2", body: json(["status": 1, "error_code": 0, "data": ["lists": []]]))
        http.on("mobiles.kugou.com/api/v3/search/song", body: json(["status": 1, "errcode": 0, "data": ["info": [
            ["hash": "ABC", "songname": "Synthetic Song", "singername": "Test Artist", "duration": 200, "album_name": "X"]]]]))
        http.on("lyrics.kugou.com/search", body: json(["candidates": [["id": "1", "accesskey": "K"]]]))
        http.on("lyrics.kugou.com/download", body: json(["content": CoverageTests.krcB64]))
        let r = try await KuGouProvider(http: http).response(for: TrackQuery(title: "Synthetic Song", artist: "Test Artist", duration: 200))
        XCTAssertEqual(r.lyrics.first?.syncType, .word)
        XCTAssertEqual(http.requests(containing: "song_search_v2").count, 2, "пустой v2 повторяется один раз")
        XCTAssertEqual(http.requests(containing: "mobiles.kugou.com").count, 1)
    }

    func testKuGouErrorStatusIsFailure() async {
        let http = MockHTTP()
        http.on("song_search_v2", body: json(["status": 0, "error_code": 20010, "error_msg": "limit"]))
        http.on("mobiles.kugou.com", body: json(["status": 0, "errcode": 20010]))
        do {
            _ = try await KuGouProvider(http: http).response(for: TrackQuery(title: "S", artist: "A", duration: 200))
            XCTFail("ожидался сбой")
        } catch { XCTAssertNotNil(error as? LyricsError) }
    }
}

final class AuditEngineTests: XCTestCase {
    let query = TrackQuery(catalogId: "42", title: "T", artist: "A", duration: 100)

    func testProgressiveUpdatesShowFirstThenBetter() async {
        let engine = LyricsEngine(providers: [
            FakeProvider(id: .amll, delay: 0.4, result: { [fakeLyrics(.amll, .word)] }),
            FakeProvider(id: .lrclib, delay: 0.02, result: { [fakeLyrics(.lrclib, .line)] }),
        ])
        var o = FetchOptions(); o.useCache = false
        let t0 = Date()
        var updates: [(TimeInterval, LyricsResult)] = []
        for await u in engine.lyricsUpdates(for: query, options: o) { updates.append((Date().timeIntervalSince(t0), u)) }
        XCTAssertGreaterThanOrEqual(updates.count, 2)
        XCTAssertEqual(updates.first?.1.best?.source.provider, .lrclib)
        XCTAssertEqual(updates.first?.1.isFinal, false)
        XCTAssertLessThan(updates.first!.0, 0.3, "первый текст — не дожидаясь медленного AMLL")
        XCTAssertEqual(updates.last?.1.isFinal, true)
        XCTAssertEqual(updates.last?.1.best?.source.provider, .amll)
        XCTAssertEqual(updates.filter { $0.1.isFinal }.count, 1)
    }

    func testCallbackVariantMatchesReturnValue() async {
        let engine = LyricsEngine(providers: [FakeProvider(id: .lrclib, result: { [fakeLyrics(.lrclib, .line)] })])
        var o = FetchOptions(); o.useCache = false
        let seen = Counter()
        let r = await engine.lyrics(for: query, options: o) { u in if u.isFinal { seen.increment() } }
        XCTAssertEqual(seen.value, 1)
        XCTAssertEqual(r.best?.source.provider, .lrclib)
    }

    func testGracePeriodStopsWaitingForSlowHigherPriority() async {
        let engine = LyricsEngine(providers: [
            FakeProvider(id: .amll, delay: 5, result: { [] }),
            FakeProvider(id: .netease, delay: 0.02, result: { [fakeLyrics(.netease, .word)] }),
        ])
        var o = FetchOptions(); o.useCache = false; o.wordGracePeriod = 0.3
        let t0 = Date()
        let r = await engine.lyrics(for: query, options: o)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 2)
        XCTAssertEqual(r.best?.source.provider, .netease)
        XCTAssertEqual(r.outcomes.first { $0.provider == .amll }?.status, .cancelled)
        // nil — старое поведение: ждём более приоритетный
        o.wordGracePeriod = nil
        let engine2 = LyricsEngine(providers: [
            FakeProvider(id: .amll, delay: 0.6, result: { [fakeLyrics(.amll, .word)] }),
            FakeProvider(id: .netease, delay: 0.02, result: { [fakeLyrics(.netease, .word)] }),
        ])
        let r2 = await engine2.lyrics(for: query, options: o)
        XCTAssertEqual(r2.best?.source.provider, .amll)
    }

    func testResponseMemoAvoidsRepeatRequestsForAlternatives() async {
        let calls = Counter()
        let engine = LyricsEngine(providers: [
            FakeProvider(id: .netease, result: { [fakeLyrics(.netease, .word)] }, onCall: { calls.increment() }),
            FakeProvider(id: .lrclib, result: { [fakeLyrics(.lrclib, .line)] }),
        ])
        var o = FetchOptions(); o.useCache = true
        _ = await engine.lyrics(for: query, options: o)
        o.exhaustive = true
        let full = await engine.lyrics(for: query, options: o)
        XCTAssertEqual(calls.value, 1, "исчерпывающий поиск после обычного не повторяет запрос к тому же источнику")
        XCTAssertEqual(full.alternatives.map(\.source.provider), [.lrclib])
        o.forceRefresh = true
        _ = await engine.lyrics(for: query, options: o)
        XCTAssertEqual(calls.value, 2, "forceRefresh обходит память ответов")
    }

    func testFailuresAreNotMemoized() async {
        let calls = Counter()
        let engine = LyricsEngine(providers: [
            FakeProvider(id: .netease, result: { throw LyricsError.badStatus(503) }, onCall: { calls.increment() }),
        ])
        _ = await engine.lyrics(for: query)
        _ = await engine.lyrics(for: query)
        XCTAssertEqual(calls.value, 2)
    }
}

final class AuditCacheAMLLTests: XCTestCase {
    func dir() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("audit-cache-\(UUID().uuidString)") }
    func files(_ d: URL) -> [URL] { ((try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "json" } }

    func testMaxEntriesHeldWithoutWaitingForPruneInterval() {
        let d = dir()
        let cache = LyricsCache(directory: d, maxEntries: 10, maxBytes: nil, pruneInterval: 50)
        for i in 0..<40 { cache.store(key: "k\(i)", best: fakeLyrics(.lrclib, .line), alternatives: []) }
        XCTAssertLessThanOrEqual(files(d).count, 10, "раньше чистка раз в 50 записей → до 49 файлов при пределе 10")
        XCTAssertNotNil(cache.load(key: "k39"), "свежие остаются")
    }

    func testMaxBytes() throws {
        let d = dir()
        let one = try JSONEncoder().encode(fakeLyrics(.lrclib, .line)).count
        let limit = one * 12
        let cache = LyricsCache(directory: d, maxEntries: 1000, maxBytes: limit, pruneInterval: 100)
        for i in 0..<60 { cache.store(key: "k\(i)", best: fakeLyrics(.lrclib, .line), alternatives: []) }
        let total = try files(d).reduce(0) { $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        XCTAssertLessThanOrEqual(total, limit)
        XCTAssertGreaterThan(files(d).count, 0)
    }

    func testPinnedSurvivesPruning() {
        let d = dir()
        let cache = LyricsCache(directory: d, maxEntries: 5, maxBytes: nil, pruneInterval: 1)
        cache.store(key: "pinned", best: fakeLyrics(.lrclib, .line), alternatives: [], pinned: true)
        for i in 0..<20 { cache.store(key: "k\(i)", best: fakeLyrics(.lrclib, .line), alternatives: []) }
        XCTAssertNotNil(cache.load(key: "pinned"))
    }

    func testAMLLDirectFileHasNoSourceDuration() async throws {
        let http = MockHTTP()
        http.on("/am-lyrics/111.ttml", body: Fixtures.ttmlAMLL)
        let p = AMLLProvider(http: http, cacheDirectory: dir())
        let r = try await p.lyrics(for: TrackQuery(catalogId: "111", title: "x", artist: "y", duration: 200))
        XCTAssertNil(r.first?.source.duration, "конец текста — не длительность трека (из-за этого у потребителей отвергался «Numb»)")
        XCTAssertNotNil(r.first?.duration)
    }

    func testAMLLIndexSearchIsMemoizedForRetry() async throws {
        let http = MockHTTP()
        let row = json(["id": "999", "metadata": [["musicName", ["Unrelated"]], ["artists", ["Nobody"]]]])
        http.on("/am-lyrics/index.jsonl", body: row)
        http.on("/ncm-lyrics/index.jsonl", body: row)
        http.on("/ncm-lyrics/555.ttml", status: 404)
        var o = AMLLProvider.Options(); o.indexDownload = .await
        let p = AMLLProvider(http: http, cacheDirectory: dir(), options: o)
        let q = TrackQuery(title: "Test Song", artist: "Test Artist", duration: 200)
        _ = try await p.response(for: q)
        var q2 = q; q2.neteaseId = "555"
        let r = try await p.response(for: q2)
        XCTAssertTrue(r.lyrics.isEmpty)
        XCTAssertEqual(http.requests(containing: "index.jsonl").count, 2, "индексы скачаны один раз")
        XCTAssertEqual(http.requests(containing: "555.ttml").count, 1, "повтор с id проверяет прямой файл")
    }

    func testAMLLIndexPrefilterFindsCyrillicVsLatin() {
        let entries = [AMLLIndexEntry(id: "1", title: "Gruppa krovi", artists: ["Kino"], album: nil, isrcs: [], appleIDs: []),
                       AMLLIndexEntry(id: "2", title: "Something else", artists: ["Other"], album: nil, isrcs: [], appleIDs: [])]
        let hits = AMLLProvider.search(entries, query: TrackQuery(title: "Группа крови", artist: "Кино"), matcher: TrackMatcher(), platform: "am")
        XCTAssertEqual(hits.map(\.entry.id), ["1"])
    }
}
