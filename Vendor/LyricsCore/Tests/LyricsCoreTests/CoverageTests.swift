import XCTest
@testable import LyricsCore

/// Расширение охвата: KuGou (KRC), запасные поиски QQ, лимиты NetEase, связки id между провайдерами. Фикстуры синтетические.
final class CoverageTests: XCTestCase {
    static let krcB64 = "a3JjMTjbRPxlOPR3QTPKsezVJthKOXC2bVpjawdrU+1mFgPV/Q5NEIAOufFM6aJarGmkmHqKTUOkRNbAtNboE9LWxnVAoW8jX5LUWN9NdvSLevwxyEQG1gxHZkHMdZDeVrarlm2U06ZP6XwKQ6ESrizRmcVltw=="

    func testKRCDecodeAndParse() throws {
        let text = try KRCParser.decode(base64: Self.krcB64)
        XCTAssertTrue(text.contains("[0,2000]"))
        let l = try KRCParser.parse(text, source: LyricsSource(provider: .kugou))
        XCTAssertEqual(l.syncType, .word)
        XCTAssertEqual(l.lines.count, 2)
        XCTAssertEqual(l.lines[0].text, "Alpha beta gamma")
        XCTAssertEqual(l.lines[0].words[1].begin, 0.5, accuracy: 0.001)
        XCTAssertEqual(l.lines[1].words[0].begin, 2.5, accuracy: 0.001)   // смещение от начала строки → абсолютное время
        XCTAssertEqual(l.lines[1].words[1].begin, 3.1, accuracy: 0.001)
        XCTAssertEqual(l.source.format, "krc")
    }

    func kugouHTTP(withLyrics: Bool = true) -> MockHTTP {
        let http = MockHTTP()
        http.on("song_search_v2", body: json(["data": ["lists": [
            ["FileHash": "H1", "SongName": "Synthetic Song", "SingerName": "Test Artist、Guest", "Duration": 200, "AlbumName": "A"],
            ["FileHash": "H2", "SongName": "Synthetic Song (Live)", "SingerName": "Test Artist", "Duration": 215]]]]))
        http.on("lyrics.kugou.com/search", body: json(["candidates": [["id": "77", "accesskey": "KEY"]]]))
        if withLyrics { http.on("lyrics.kugou.com/download", body: json(["content": Self.krcB64])) }
        return http
    }

    func testKuGouProviderFindsWordSync() async throws {
        let http = kugouHTTP()
        let r = try await KuGouProvider(http: http).response(for: TrackQuery(title: "Synthetic Song", artist: "Test Artist", duration: 200))
        XCTAssertEqual(r.lyrics.count, 1)
        XCTAssertEqual(r.lyrics[0].syncType, .word)
        XCTAssertEqual(r.lyrics[0].source.provider, .kugou)
        XCTAssertFalse(r.lyrics[0].source.matchQuality.isNearMiss)
        XCTAssertEqual(http.requests(containing: "fmt=krc").count, 1)
    }

    func testKuGouFallsBackToLRCAndReportsNoLyrics() async throws {
        let http = kugouHTTP(withLyrics: false)
        http.on("fmt=krc", body: json(["content": ""]))
        http.on("fmt=lrc", body: json(["content": Data("[00:01.00]one\n[00:05.00]two".utf8).base64EncodedString()]))
        let r = try await KuGouProvider(http: http).response(for: TrackQuery(title: "Synthetic Song", artist: "Test Artist", duration: 200))
        XCTAssertEqual(r.lyrics.first?.syncType, .line)
        let empty = MockHTTP()
        empty.on("song_search_v2", body: json(["data": ["lists": []]]))
        empty.on("mobiles.kugou.com", body: json(["status": 1, "data": ["info": []]]))   // запасной поиск тоже пуст → «не найдено»
        let r2 = try await KuGouProvider(http: empty).response(for: TrackQuery(title: "Synthetic Song", artist: "Test Artist", duration: 200))
        XCTAssertTrue(r2.lyrics.isEmpty)
    }

    func testKuGouWrongDurationBecomesNearMiss() async throws {
        let http = MockHTTP()
        http.on("song_search_v2", body: json(["data": ["lists": [["FileHash": "H9", "SongName": "Synthetic Song", "SingerName": "Test Artist", "Duration": 236]]]]))
        http.on("lyrics.kugou.com/search", body: json(["candidates": [["id": "1", "accesskey": "K"]]]))
        http.on("lyrics.kugou.com/download", body: json(["content": Self.krcB64]))
        let r = try await KuGouProvider(http: http).response(for: TrackQuery(title: "Synthetic Song", artist: "Test Artist", duration: 200))
        XCTAssertEqual(r.lyrics.count, 1)
        XCTAssertTrue(r.lyrics[0].source.matchQuality.isNearMiss)
    }

    // MARK: - QQ

    func testQQFallsThroughSearchChain() async throws {
        let http = MockHTTP()
        http.on("client_search_cp", status: 500, body: "boom")
        http.on("search_for_qq_cp", body: json(["data": ["song": ["list": [
            ["songid": 5, "songmid": "MID5", "songname": "Synthetic Song", "singer": [["name": "Test Artist"]], "interval": 200, "albumname": "A"]]]]]))
        let (cands, songs) = try await QQProvider(http: http).findSongs("x")
        XCTAssertEqual(cands.first?.title, "Synthetic Song")
        XCTAssertEqual(cands.first?.duration, 200)
        XCTAssertEqual(songs["5"]?.mid, "MID5")
        // оба основных упали → smartbox_new
        let h2 = MockHTTP()
        h2.on("client_search_cp", status: 500)
        h2.on("search_for_qq_cp", status: 500)
        h2.on("smartbox_new", body: json(["data": ["song": ["itemlist": [["id": "9", "mid": "M9", "name": "Synthetic Song", "singer": "Test Artist"]]]]]))
        let (c2, _) = try await QQProvider(http: h2).findSongs("x")
        XCTAssertEqual(c2.count, 1)
        // все упали → ошибка
        let h3 = MockHTTP()
        do { _ = try await QQProvider(http: h3).findSongs("x"); XCTFail() } catch {}
    }

    // MARK: - NetEase

    func testNetEaseLimit10_andHint() async throws {
        let http = MockHTTP()
        http.on("/api/search/get", body: json(["result": ["songs": [
            ["id": 11, "name": "Synthetic Song", "artists": [["name": "Test Artist"]], "duration": 200000]]]]))
        http.on("/api/song/lyric", body: json(["lrc": ["lyric": "[00:01.00]one\n[00:05.00]two"]]))
        let r = try await NetEaseProvider(http: http).response(for: TrackQuery(title: "Synthetic Song", artist: "Test Artist", duration: 200))
        XCTAssertTrue(http.requests(containing: "limit=10").count >= 1)
        XCTAssertEqual(r.hints?.neteaseId, "11")
        XCTAssertEqual(NetEaseProvider(http: http).maxCandidates, 5)
    }

    func testNetEasePicksWordSyncCandidateAmongSeveral() async throws {
        let http = MockHTTP()
        http.on("/api/search/get", body: json(["result": ["songs": [
            ["id": 1, "name": "Synthetic Song", "artists": [["name": "Test Artist"]], "duration": 200000],
            ["id": 2, "name": "Synthetic Song", "artists": [["name": "Test Artist"]], "duration": 200500],
            ["id": 3, "name": "Synthetic Song", "artists": [["name": "Test Artist"]], "duration": 199800]]]]))
        http.on("id=1&", body: json(["lrc": ["lyric": "[00:01.00]one\n[00:05.00]two"]]))
        http.on("id=2&", body: json(["lrc": ["lyric": "[00:01.00]one\n[00:05.00]two"]]))
        http.on("id=3&", body: json(["yrc": ["lyric": "[1000,2000](1000,500,0)aa (1500,500,0)bb\n[4000,1000](4000,500,0)cc (4500,500,0)dd"]]))
        let r = try await NetEaseProvider(http: http).response(for: TrackQuery(title: "Synthetic Song", artist: "Test Artist", duration: 200))
        XCTAssertEqual(r.lyrics.first?.syncType, .word)
    }

    // MARK: - связки id

    struct HintProvider: LyricsProvider {
        let id: LyricsProviderID
        let hints: TrackHints?
        func lyrics(for query: TrackQuery) async throws -> [Lyrics] { [] }
        func response(for query: TrackQuery) async throws -> ProviderResponse { ProviderResponse(lyrics: [], hints: hints) }
    }

    final class IDConsumer: LyricsProvider, @unchecked Sendable {
        let id: LyricsProviderID = .amll
        var usesCrossProviderIDs: Bool { true }
        private let lock = NSLock()
        private var seen: [TrackQuery] = []
        var queries: [TrackQuery] { lock.lock(); defer { lock.unlock() }; return seen }
        func lyrics(for query: TrackQuery) async throws -> [Lyrics] { try await response(for: query).lyrics }
        func response(for query: TrackQuery) async throws -> ProviderResponse {
            lock.lock(); seen.append(query); lock.unlock()
            if query.neteaseId == "555" { return ProviderResponse(lyrics: [fakeLyrics(.amll, .word, trackID: "ncm-lyrics/555")]) }
            return ProviderResponse(lyrics: [])
        }
    }

    func testHintsFromNetEaseReachAMLLWithinOneSearch() async {
        let amll = IDConsumer()
        let engine = LyricsEngine(providers: [amll, HintProvider(id: .netease, hints: TrackHints(neteaseId: "555")),
                                              FakeProvider(id: .lrclib, result: { [fakeLyrics(.lrclib, .none)] })])
        var o = FetchOptions(); o.useCache = false; o.exhaustive = true
        let r = await engine.lyrics(for: TrackQuery(title: "T", artist: "A", duration: 100), options: o)
        XCTAssertEqual(amll.queries.count, 2)
        XCTAssertNil(amll.queries[0].neteaseId)
        XCTAssertEqual(amll.queries[1].neteaseId, "555")
        XCTAssertEqual(r.best?.source.provider, .amll)
        XCTAssertEqual(r.best?.syncType, .word)
        XCTAssertEqual(r.outcomes.first { $0.provider == .amll }?.note, "повторный поиск по id из других сервисов")
    }

    func testNoRetryWhenConsumerAlreadyFound() async {
        final class Found: LyricsProvider, @unchecked Sendable {
            let id: LyricsProviderID = .amll
            var usesCrossProviderIDs: Bool { true }
            let n = Counter()
            func lyrics(for query: TrackQuery) async throws -> [Lyrics] { n.increment(); return [fakeLyrics(.amll, .word)] }
        }
        let f = Found()
        let engine = LyricsEngine(providers: [f, HintProvider(id: .netease, hints: TrackHints(neteaseId: "1"))])
        var o = FetchOptions(); o.useCache = false; o.exhaustive = true
        _ = await engine.lyrics(for: TrackQuery(title: "T", artist: "A", duration: 100), options: o)
        XCTAssertEqual(f.n.value, 1)
    }

    func testAMLLUsesQQMidDirectFile() async throws {
        let http = MockHTTP()
        let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:itunes="http://music.apple.com/lyric-ttml-internal" itunes:timing="Word"><body dur="10s"><div><p begin="1s" end="3s" itunes:key="L1"><span begin="1s" end="2s">hi</span> <span begin="2s" end="3s">you</span></p></div></body></tt>
        """
        http.on("qq-lyrics/MID7.ttml", body: ttml)
        var q = TrackQuery(title: "T", artist: "A", duration: 10)
        q.qqSongMid = "MID7"
        var opts = AMLLProvider.Options(); opts.useIndexSearch = false
        let r = try await AMLLProvider(http: http, options: opts).response(for: q)
        XCTAssertEqual(r.lyrics.first?.syncType, .word)
    }
}
