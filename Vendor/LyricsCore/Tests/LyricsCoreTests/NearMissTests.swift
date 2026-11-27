import XCTest
@testable import LyricsCore

final class NearMissTests: XCTestCase {
    // MARK: - кэш «не найдено»

    func cache(clock: ClockBox = ClockBox()) -> (LyricsCache, ClockBox) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nm-\(UUID().uuidString)")
        return (LyricsCache(directory: dir, now: { clock.now }), clock)
    }

    func emptyEngine(_ c: LyricsCache) -> LyricsEngine {
        LyricsEngine(providers: [FakeProvider(id: .lrclib, result: { [] })], cache: c)
    }

    func testNoNegativeEntryForEmptyMetadata() async {
        let (c, _) = cache()
        let e = emptyEngine(c)
        let empty = TrackQuery(catalogId: "999", title: "", artist: "")
        let r = await e.lyrics(for: empty)
        XCTAssertNil(r.best)
        XCTAssertNil(c.load(key: "am-999"))
        let half = TrackQuery(catalogId: "999", title: "Song", artist: "  ")
        _ = await e.lyrics(for: half)
        XCTAssertNil(c.load(key: "am-999"))
    }

    func testNegativeEntryWritten_andIgnoredForDifferentFingerprint() async {
        let (c, _) = cache()
        let e = emptyEngine(c)
        let q1 = TrackQuery(catalogId: "5", title: "Song", artist: "Artist", duration: 200)
        let r1 = await e.lyrics(for: q1)
        XCTAssertFalse(r1.fromCache)
        XCTAssertEqual(r1.query, q1)
        let again = await e.lyrics(for: q1)
        XCTAssertTrue(again.fromCache)                       // тот же запрос — негативный кэш работает
        // другая длительность → другой отпечаток → игнор
        let q2 = TrackQuery(catalogId: "5", title: "Song", artist: "Artist", duration: 230)
        let other = await e.lyrics(for: q2)
        XCTAssertFalse(other.fromCache)
        // старая негативная запись без отпечатка тоже игнорируется
        c.store(key: "am-5", best: nil, alternatives: [])
        XCTAssertNil(c.load(key: "am-5", fingerprint: q1.fingerprint))
        XCTAssertNotNil(c.load(key: "am-5"))                 // без отпечатка — как раньше
    }

    func testPositiveEntryIgnoresFingerprint() {
        let (c, _) = cache()
        c.store(key: "k", best: fakeLyrics(.amll, .word), alternatives: [], fingerprint: "a")
        XCTAssertNotNil(c.load(key: "k", fingerprint: "b"))
    }

    func testNegativeTTLIs30Minutes() {
        let (c, clock) = cache()
        c.store(key: "n", best: nil, alternatives: [], fingerprint: "f")
        clock.advance(29 * 60)
        XCTAssertNotNil(c.load(key: "n", fingerprint: "f"))
        clock.advance(2 * 60)
        XCTAssertNil(c.load(key: "n", fingerprint: "f"))
    }

    func testFingerprintNormalizesButSeesDuration() {
        let a = TrackQuery(title: "Song (Remastered 2011)", artist: "ARTIST", duration: 200.2)
        let b = TrackQuery(title: "song", artist: "Artist", duration: 199.8)
        XCTAssertEqual(a.fingerprint, TrackQuery(title: "Song (Remastered 2011)", artist: "artist", duration: 200).fingerprint)
        XCTAssertNotEqual(a.fingerprint, TrackQuery(title: "Song", artist: "Artist", duration: 230).fingerprint)
        _ = b
    }

    func testOldCacheEntriesDecode() throws {
        // LyricsSource без matchQuality (старый кэш) читается как .exact
        let json = #"{"provider":"lrclib","confidence":0.9,"matchKind":"metadata"}"#
        let s = try JSONDecoder().decode(LyricsSource.self, from: Data(json.utf8))
        XCTAssertEqual(s.matchQuality, .exact)
        let n = LyricsSource(provider: .qq, matchQuality: .nearMiss("x"))
        let back = try JSONDecoder().decode(LyricsSource.self, from: JSONEncoder().encode(n))
        XCTAssertEqual(back.matchQuality, .nearMiss("x"))
    }

    // MARK: - матчер

    func cand(_ t: String, _ a: String, _ d: Double?) -> TrackCandidate { TrackCandidate(id: "1", title: t, artists: [a], duration: d) }

    func testNearMissBounds() {
        let m = TrackMatcher(config: .init(durationTolerance: 2.5, durationHardLimit: 10))
        let q = TrackQuery(title: "Somebody Save Me (feat. Jelly Roll)", artist: "Eminem", duration: 286)
        XCTAssertEqual(m.triage(q, [cand("Somebody Save Me", "Eminem", 286)]).accepted.count, 1)
        XCTAssertEqual(m.triage(q, [cand("Somebody Save Me", "Eminem", 230)]).nearMisses.count, 1)   // -56 с, 19.6 %
        XCTAssertEqual(m.triage(q, [cand("Somebody Save Me", "Eminem", 258)]).nearMisses.count, 1)
        let far = m.triage(q, [cand("Somebody Save Me", "Eminem", 100)])                              // -186 с
        XCTAssertTrue(far.nearMisses.isEmpty)
        XCTAssertEqual(far.rejectedByDuration, 1)
        // другое название / исполнитель — не near-miss
        XCTAssertTrue(m.triage(q, [cand("Lose Yourself", "Eminem", 250)]).nearMisses.isEmpty)
        XCTAssertTrue(m.triage(q, [cand("Somebody Save Me", "Adele", 250)]).nearMisses.isEmpty)
        // другая версия (live) — не near-miss
        XCTAssertTrue(m.triage(q, [cand("Somebody Save Me (Live)", "Eminem", 250)]).nearMisses.isEmpty)
        // короткий трек: 40 с абсолютно
        let q2 = TrackQuery(title: "Skit", artist: "Eminem", duration: 60)
        XCTAssertEqual(m.triage(q2, [cand("Skit", "Eminem", 95)]).nearMisses.count, 1)
        XCTAssertTrue(m.triage(q2, [cand("Skit", "Eminem", 130)]).nearMisses.isEmpty)
        // без длительности near-miss не бывает
        XCTAssertTrue(m.triage(TrackQuery(title: "Skit", artist: "Eminem"), [cand("Skit", "Eminem", 95)]).nearMisses.isEmpty)
        XCTAssertTrue(far.summary.contains("кандидатов: 1"))
    }

    // MARK: - провайдеры

    func record(_ id: Int, _ dur: Double, synced: String = "[00:01.00]line one\n[00:05.00]line two") -> [String: Any] {
        ["id": id, "trackName": "Somebody Save Me", "artistName": "Eminem", "albumName": "A", "duration": dur,
         "instrumental": false, "plainLyrics": "line one\nline two", "syncedLyrics": synced]
    }

    func testLRCLIBReturnsNearMissOnly() async throws {
        let http = MockHTTP()
        http.on("/api/get?", status: 404)
        http.on("/api/search", body: json([record(1, 230), record(2, 258)]))
        let q = TrackQuery(title: "Somebody Save Me (feat. Jelly Roll)", artist: "Eminem", duration: 286)
        let resp = try await LRCLIBProvider(http: http).response(for: q)
        XCTAssertEqual(resp.lyrics.count, 2)
        XCTAssertTrue(resp.lyrics.allSatisfy { $0.source.matchQuality.isNearMiss })
        XCTAssertNotNil(resp.note)
        XCTAssertTrue(resp.note!.contains("почти совпадений: 2"))
        // а с подходящей длительностью — точный результат, near-miss не добавляются
        let ok = try await LRCLIBProvider(http: http).response(for: TrackQuery(title: "Somebody Save Me", artist: "Eminem", duration: 230))
        XCTAssertEqual(ok.lyrics.count, 1)
        XCTAssertEqual(ok.lyrics[0].source.matchQuality, .exact)
        XCTAssertNil(ok.note)
    }

    func testNetEaseNearMiss() async throws {
        let http = MockHTTP()
        http.on("/api/search/get", body: json(["result": ["songs": [
            ["id": 11, "name": "Somebody Save Me", "artists": [["name": "Eminem"]], "album": ["name": "A"], "duration": 230000]]]]))
        http.on("/api/song/lyric", body: json(["code": 200, "lrc": ["lyric": "[00:10.00]a\n[00:20.00]b"]]))
        let r = try await NetEaseProvider(http: http).response(for: TrackQuery(title: "Somebody Save Me", artist: "Eminem", duration: 286))
        XCTAssertEqual(r.lyrics.count, 1)
        XCTAssertEqual(r.lyrics[0].source.matchQuality.isNearMiss, true)
        XCTAssertTrue(r.lyrics[0].source.matchQuality.reason!.contains("230"))
    }

    func testNetEaseNoNoteReasonCounts() async throws {
        let http = MockHTTP()
        http.on("/api/search/get", body: json(["result": ["songs": [
            ["id": 11, "name": "Somebody Save Me", "artists": [["name": "Eminem"]], "duration": 30000],
            ["id": 12, "name": "Other", "artists": [["name": "Someone"]], "duration": 286000]]]]))
        let r = try await NetEaseProvider(http: http).response(for: TrackQuery(title: "Somebody Save Me", artist: "Eminem", duration: 286))
        XCTAssertTrue(r.lyrics.isEmpty)
        XCTAssertEqual(r.note, "кандидатов: 2, отвергнуты по длительности: 1, по названию/исполнителю: 1")
    }

    // MARK: - каскад

    func nearLyrics(_ p: LyricsProviderID, _ sync: SyncType, conf: Double = 0.9) -> Lyrics {
        var l = fakeLyrics(p, sync, confidence: conf, trackID: "nm-\(p.rawValue)")
        l.source.matchQuality = .nearMiss("длительность отличается на 56 с")
        return l
    }

    func testArrangeNearMissIsLastResortBest() {
        let order: [LyricsProviderID] = [.appleMusic, .amll, .netease, .qq, .lrclib]
        let (b0, a0) = LyricsEngine.arrange([nearLyrics(.netease, .word), nearLyrics(.lrclib, .line)], providerOrder: order, maxAlternatives: 5)
        XCTAssertEqual(b0?.source.provider, .netease)                // нет точного → лучший near-miss (пословный)
        XCTAssertTrue(b0!.source.matchQuality.isNearMiss)
        XCTAssertEqual(a0.map(\.source.provider), [.lrclib])
        let (b0n, a0n) = LyricsEngine.arrange([nearLyrics(.netease, .word), nearLyrics(.lrclib, .line)], providerOrder: order, maxAlternatives: 5,
                                              allowApproximate: false)
        XCTAssertNil(b0n)                                            // старое поведение
        XCTAssertEqual(a0n.count, 2)
        // порядок near-miss: пословный → построчный → простой, даже при меньшей уверенности
        let (b2, _) = LyricsEngine.arrange([nearLyrics(.lrclib, .none, conf: 0.99), nearLyrics(.qq, .line, conf: 0.95), nearLyrics(.netease, .word, conf: 0.8)],
                                           providerOrder: order, maxAlternatives: 5)
        XCTAssertEqual(b2?.syncType, .word)
        let (b3, _) = LyricsEngine.arrange([nearLyrics(.lrclib, .none, conf: 0.99), nearLyrics(.qq, .line, conf: 0.8)], providerOrder: order, maxAlternatives: 5)
        XCTAssertEqual(b3?.syncType, .line)
        // точный простой лучше near-miss пословного
        let (b4, _) = LyricsEngine.arrange([nearLyrics(.netease, .word), fakeLyrics(.lrclib, .none)], providerOrder: order, maxAlternatives: 5)
        XCTAssertFalse(b4!.source.matchQuality.isNearMiss)
        // инструментал от точного источника лучше near-miss
        let inst = Lyrics(source: LyricsSource(provider: .lrclib), syncType: .none, lines: [], isInstrumental: true)
        let (b5, _) = LyricsEngine.arrange([nearLyrics(.netease, .word), inst], providerOrder: order, maxAlternatives: 5)
        XCTAssertTrue(b5!.isInstrumental)
        let (b1, a1) = LyricsEngine.arrange([nearLyrics(.netease, .word), fakeLyrics(.lrclib, .none)], providerOrder: order, maxAlternatives: 5)
        XCTAssertEqual(b1?.source.provider, .lrclib)                 // пусть простой, но точный
        XCTAssertEqual(a1.map(\.source.provider), [.netease])        // near-miss в конце
        XCTAssertTrue(a1.last!.source.matchQuality.isNearMiss)
        // near-miss идут после обычных альтернатив
        let (_, a2) = LyricsEngine.arrange([fakeLyrics(.qq, .word, trackID: "a"), nearLyrics(.netease, .word), fakeLyrics(.lrclib, .line)],
                                           providerOrder: order, maxAlternatives: 5)
        XCTAssertEqual(a2.map { $0.source.matchQuality.isNearMiss }, [false, true])
    }

    func testEngineReportsNearMissInOutcomeAndDoesNotStopEarly() async {
        var o = FetchOptions(); o.useCache = false
        let q = TrackQuery(catalogId: "1", title: "T", artist: "A", duration: 100)
        let calls = Counter()
        let engine = LyricsEngine(providers: [
            FakeProvider(id: .netease, result: { [self.nearLyrics(.netease, .word)] }),   // near-miss не должен останавливать каскад
            FakeProvider(id: .lrclib, result: { calls.increment(); return [] }),
        ])
        let r = await engine.lyrics(for: q, options: o)
        XCTAssertEqual(r.best?.source.provider, .netease)
        XCTAssertTrue(r.bestIsApproximate)
        XCTAssertEqual(r.approximateReason, "длительность отличается на 56 с")
        XCTAssertTrue(r.alternatives.isEmpty)
        XCTAssertEqual(r.outcomes.count, 2)
        XCTAssertEqual(r.outcomes[0].status, .notFound)
        XCTAssertTrue(r.outcomes[0].note?.contains("только почти совпадения: 1") == true)
        XCTAssertEqual(r.query, q)
    }

    func testAllowApproximateFalseKeepsOldBehavior() async {
        var o = FetchOptions(); o.useCache = false; o.allowApproximate = false
        let engine = LyricsEngine(providers: [FakeProvider(id: .netease, result: { [self.nearLyrics(.netease, .word)] })])
        let r = await engine.lyrics(for: TrackQuery(catalogId: "1", title: "T", artist: "A", duration: 100), options: o)
        XCTAssertNil(r.best)
        XCTAssertFalse(r.bestIsApproximate)
        XCTAssertEqual(r.alternatives.count, 1)
    }

    func testExactBeatsNearMissAndIsNotApproximate() async {
        var o = FetchOptions(); o.useCache = false; o.exhaustive = true
        let engine = LyricsEngine(providers: [
            FakeProvider(id: .netease, result: { [self.nearLyrics(.netease, .word)] }),
            FakeProvider(id: .lrclib, result: { [fakeLyrics(.lrclib, .none)] }),
        ])
        let r = await engine.lyrics(for: TrackQuery(catalogId: "1", title: "T", artist: "A", duration: 100), options: o)
        XCTAssertEqual(r.best?.source.provider, .lrclib)
        XCTAssertFalse(r.bestIsApproximate)
        XCTAssertNil(r.approximateReason)
    }

    func testApproximateBestThroughCacheAndOption() async {
        let (c, _) = cache()
        let q = TrackQuery(catalogId: "1", title: "T", artist: "A", duration: 100)
        let engine = LyricsEngine(providers: [FakeProvider(id: .lrclib, result: { [self.nearLyrics(.lrclib, .line)] })], cache: c)
        _ = await engine.lyrics(for: q)
        let hit = await engine.lyrics(for: q)
        XCTAssertTrue(hit.fromCache)
        XCTAssertEqual(hit.best?.source.provider, .lrclib)
        XCTAssertTrue(hit.bestIsApproximate)
        var o = FetchOptions(); o.allowApproximate = false
        let strict = await engine.lyrics(for: q, options: o)
        XCTAssertNil(strict.best)
        XCTAssertEqual(strict.alternatives.count, 1)
        // ручной выбор приблизительным не считается
        engine.select(self.nearLyrics(.lrclib, .line), for: q)
        let pinned = await engine.lyrics(for: q)
        XCTAssertNotNil(pinned.best)
        XCTAssertFalse(pinned.bestIsApproximate)
    }

    func testApproximateTTLShorterThanExact() {
        let clock = ClockBox()
        let (c, _) = cache(clock: clock)
        c.store(key: "a", best: nearLyrics(.lrclib, .word), alternatives: [])
        c.store(key: "b", best: fakeLyrics(.lrclib, .word), alternatives: [])
        clock.advance(7 * 3600)
        XCTAssertNil(c.load(key: "a"))
        XCTAssertNotNil(c.load(key: "b"))
    }

    // MARK: - plainVersion

    func testPlainVersion() {
        let l = Lyrics(source: Fixtures.src, syncType: .word, lines: [
            LyricLine(key: "a", begin: 0, end: 1, words: [LyricWord(text: "one", begin: 0, end: 0.5), LyricWord(text: "two", begin: 0.5, end: 1)],
                      background: [LyricWord(text: "oh", begin: 0.2, end: 0.4)],
                      translations: [LyricAnnotation(kind: .subtitle, text: "tr")]),
            LyricLine(key: "b", begin: 1, end: 2, text: ""),
            LyricLine(key: "c", begin: 2, end: 3, text: ""),
            LyricLine(key: "d", begin: 3, end: 4, text: "three"),
            LyricLine(key: "e", begin: 4, end: 5, text: ""),
        ], leadingSilence: 2)
        let p = l.plainVersion()
        XCTAssertEqual(p.syncType, .none)
        XCTAssertFalse(p.isSynced)
        XCTAssertEqual(p.lines.map(\.text), ["one two (oh)", "", "three"])
        XCTAssertEqual(p.lines.map(\.key), ["L1", "L2", "L3"])
        XCTAssertTrue(p.lines.allSatisfy { $0.begin == nil && $0.end == nil && $0.words.isEmpty && $0.background.isEmpty })
        XCTAssertEqual(p.lines[0].translations.first?.text, "tr")
        XCTAssertNil(p.leadingSilence)
        XCTAssertEqual(p.source, l.source)
        XCTAssertNil(p.lineIndex(at: 1))
        XCTAssertEqual(l.syncType, .word)   // исходный не тронут
    }

    func testNearMissSurvivesCacheAsAlternative() async {
        let (c, _) = cache()
        let q = TrackQuery(catalogId: "1", title: "T", artist: "A", duration: 100)
        let engine = LyricsEngine(providers: [FakeProvider(id: .lrclib, result: { [self.nearLyrics(.lrclib, .line)] })], cache: c)
        _ = await engine.lyrics(for: q)
        let hit = await engine.lyrics(for: q)
        XCTAssertTrue(hit.fromCache)
        XCTAssertTrue(hit.bestIsApproximate)
        var o = FetchOptions(); o.allowApproximate = false
        let hit2 = await engine.lyrics(for: q, options: o)
        XCTAssertNil(hit2.best)
        XCTAssertEqual(hit2.alternatives.first?.source.matchQuality.isNearMiss, true)
    }

    // MARK: - заголовок QQ

    func lyr(_ texts: [String]) -> Lyrics {
        Lyrics(source: Fixtures.src, syncType: .line,
               lines: texts.enumerated().map { LyricLine(key: "L\($0.offset + 1)", begin: Double($0.offset), end: Double($0.offset) + 1, text: $0.element) })
    }

    func testStripsQQHeaderLine() {
        let l = lyr(["Tobey (Explicit) - Eminem/Big Sean/BabyTron", "real first", "real second"])
        let r = SyllableSupport.stripHeaderLine(l, title: "Tobey (feat. Big Sean & BabyTron)", artist: "Eminem")
        XCTAssertEqual(r.lines.map(\.text), ["real first", "real second"])
        XCTAssertEqual(r.lines.map(\.key), ["L1", "L2"])
        // заголовок второй строкой
        let l2 = lyr(["", "Tobey - Eminem", "real"])
        XCTAssertEqual(SyllableSupport.stripHeaderLine(l2, title: "Tobey", artist: "Eminem").lines.map(\.text), ["", "real"])
    }

    func testKeepsRealLinesWithDash() {
        // не совпадает название
        let a = lyr(["I love you - Eminem said", "x"])
        XCTAssertEqual(SyllableSupport.stripHeaderLine(a, title: "Tobey", artist: "Eminem").lines.count, 2)
        // совпадает название, но справа нет исполнителя
        let b = lyr(["Tobey - the one and only", "x"])
        XCTAssertEqual(SyllableSupport.stripHeaderLine(b, title: "Tobey", artist: "Eminem").lines.count, 2)
        // заголовок не в первых двух строках
        let c = lyr(["one", "two", "Tobey - Eminem"])
        XCTAssertEqual(SyllableSupport.stripHeaderLine(c, title: "Tobey", artist: "Eminem").lines.count, 3)
    }

    func testQQProviderStripsHeader() async throws {
        let http = MockHTTP()
        http.on("client_search_cp", body: json(["data": ["song": ["list": [
            ["id": 1, "mid": "M1", "name": "Tobey", "singer": [["name": "Eminem"]], "interval": 284]]]]]))
        let body = "<?xml version=\"1.0\"?><Lyric_1 LyricType=\"1\" LyricContent=\"x\"/>"
        _ = body
        http.on("lyric_download", method: "POST", status: 200,
                body: "<content><![CDATA[]]></content>")
        http.on("fcg_query_lyric_new", body: json(["retcode": 0, "lyric": Data("[00:00.50]Tobey (Explicit) - Eminem/Big Sean/BabyTron\n[00:10.00]first\n[00:20.00]second".utf8).base64EncodedString()]))
        let r = try await QQProvider(http: http).lyrics(for: TrackQuery(title: "Tobey (feat. Big Sean & BabyTron)", artist: "Eminem", duration: 284))
        XCTAssertEqual(r.first?.lines.first?.text, "first")
    }
}
