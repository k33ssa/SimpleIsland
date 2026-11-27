import XCTest
@testable import LyricsCore

final class LRCLIBProviderTests: XCTestCase {
    let yaml = """
    version: '1.0'
    metadata:
      title: Test Song
      artist: Test Artist
      duration_ms: 200000
      language: en
    lines:
    - text: Hello there
      start_ms: 1000
      end_ms: 3000
      words:
      - text: 'Hello '
        start_ms: 1000
      - text: there
        start_ms: 2000
    - text: Second one
      start_ms: 4000
      end_ms: 6000
      words:
      - text: 'Sec'
        start_ms: 4000
      - text: 'ond '
        start_ms: 4500
      - text: 'one'
        start_ms: 5000
    """

    func record(id: Int, title: String = "Test Song", duration: Double = 200, synced: String? = nil, plain: String? = nil,
                lyricsfile: String? = nil, hasWord: Bool = false, instrumental: Bool = false) -> [String: Any] {
        var d: [String: Any] = ["id": id, "trackName": title, "name": title, "artistName": "Test Artist", "albumName": "Test Album",
                                "duration": duration, "instrumental": instrumental, "hasWordSync": hasWord]
        if let synced { d["syncedLyrics"] = synced }
        if let plain { d["plainLyrics"] = plain }
        if let lyricsfile { d["lyricsfile"] = lyricsfile }
        return d
    }

    func testMiniYAMLLyricsfile() throws {
        let l = try LRCLIBProvider.parseLyricsfile(yaml, source: Fixtures.src)!
        XCTAssertEqual(l.syncType, .word)
        XCTAssertEqual(l.language, "en")
        XCTAssertEqual(l.duration, 200)
        XCTAssertEqual(l.lines.count, 2)
        XCTAssertEqual(l.lines[0].words.map(\.text), ["Hello", "there"])
        XCTAssertEqual(l.lines[0].words[0].end, 2.0, accuracy: 1e-9)       // конец слова = начало следующего
        XCTAssertEqual(l.lines[0].words[1].end, 3.0, accuracy: 1e-9)       // у последнего — конец строки
        XCTAssertEqual(l.lines[1].words.map(\.text), ["Sec", "ond", "one"])
        XCTAssertEqual(l.lines[1].words.map(\.isContinuation), [false, true, false])
        XCTAssertEqual(l.lines[1].text, "Second one")
    }

    func testMiniYAMLQuotingAndFolding() throws {
        let doc = """
        a: 'it''s'
        b: "tab\\there \\u0041"
        c: plain value # comment
        d: folded
          continuation line
        e:
        - x
        - y: 1
          z: 2
        f: |
          line one
          line two
        """
        let v = try MiniYAML.parse(doc)
        XCTAssertEqual(v["a"]?.string, "it's")
        XCTAssertEqual(v["b"]?.string, "tab\there A")
        XCTAssertEqual(v["c"]?.string, "plain value")
        XCTAssertEqual(v["d"]?.string, "folded continuation line")
        XCTAssertEqual(v["e"]?.array?.count, 2)
        XCTAssertEqual(v["e"]?.array?[1]["z"]?.double, 2)
        XCTAssertEqual(v["f"]?.string, "line one\nline two")
    }

    func testGetHitWithWordSync() async throws {
        let http = MockHTTP()
        http.on("/api/get?", body: json(record(id: 7, lyricsfile: yaml, hasWord: true)))
        let p = LRCLIBProvider(http: http)
        let q = TrackQuery(title: "Test Song", artist: "Test Artist", album: "Test Album", duration: 200)
        let r = try await p.lyrics(for: q)
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].syncType, .word)
        XCTAssertEqual(r[0].source.provider, .lrclib)
        XCTAssertEqual(r[0].source.trackID, "7")
        XCTAssertEqual(r[0].source.format, "lyricsfile")
        // нейтральный User-Agent
        let req = http.requests(containing: "/api/get").first!
        XCTAssertEqual(req.value(forHTTPHeaderField: "User-Agent"), "AMNL/0.1")
        XCTAssertTrue(req.url!.absoluteString.contains("duration=200"))
    }

    func testFallsBackToSearchAndPicksCorrectVersion() async throws {
        let http = MockHTTP()
        http.on("/api/get?", status: 404, body: "{}")
        http.on("/api/search", body: json([
            record(id: 1, title: "Test Song (Live)", duration: 260, synced: "[00:01.00]live"),
            record(id: 2, title: "Test Song", duration: 201, synced: "[00:01.00]studio line\n[00:05.00]second"),
            record(id: 3, title: "Test Song", duration: 200, plain: "plain only"),
        ]))
        let p = LRCLIBProvider(http: http)
        let r = try await p.lyrics(for: TrackQuery(title: "Test Song (Remastered)", artist: "Test Artist", duration: 200))
        XCTAssertEqual(r.first?.source.trackID, "2")           // построчный раньше простого
        XCTAssertEqual(r.first?.syncType, .line)
        XCTAssertEqual(r.last?.syncType, SyncType.none)
        XCTAssertFalse(r.contains { $0.source.trackID == "1" }) // live отброшен
        // запрос поиска идёт по очищенному названию
        XCTAssertTrue(http.requests(containing: "/api/search").first!.url!.absoluteString.contains("track_name=Test%20Song&"))
    }

    func testInstrumental() async throws {
        let http = MockHTTP()
        http.on("/api/get?", body: json(record(id: 9, instrumental: true)))
        let r = try await LRCLIBProvider(http: http).lyrics(for: TrackQuery(title: "Test Song", artist: "Test Artist", duration: 200))
        XCTAssertTrue(r.first?.isInstrumental == true)
    }

    func testNothingFound() async throws {
        let http = MockHTTP()
        http.on("/api/get?", status: 404)
        http.on("/api/search", body: "[]")
        let r = try await LRCLIBProvider(http: http).lyrics(for: TrackQuery(title: "Nope", artist: "Nobody", duration: 100))
        XCTAssertTrue(r.isEmpty)
    }

    func testRateLimitSurfaces() async {
        let http = MockHTTP()
        http.on("/api/get?", status: 429, headers: ["Retry-After": "7"])
        do {
            _ = try await LRCLIBProvider(http: http).lyrics(for: TrackQuery(title: "x", artist: "y", duration: 100))
            XCTFail("ожидалась ошибка")
        } catch let e as LyricsError {
            XCTAssertEqual(e, .rateLimited(retryAfter: 7))
        } catch { XCTFail("\(error)") }
    }
}

final class NetEaseProviderTests: XCTestCase {
    let search = json(["result": ["songs": [
        ["id": 111, "name": "Test Song (Live)", "artists": [["name": "Test Artist"]], "album": ["name": "Live"], "duration": 260000],
        ["id": 222, "name": "Test Song", "artists": [["name": "Test Artist"]], "album": ["name": "Test Album"], "duration": 200300],
        ["id": 333, "name": "Test Song", "artists": [["name": "Test Artist"]], "album": ["name": "Test Album"], "duration": 200100],
    ], "songCount": 3]])

    func lyricBody(yrc: String? = nil, lrc: String? = nil, tlyric: String? = nil) -> String {
        json(["code": 200, "lrc": ["lyric": lrc ?? ""], "yrc": ["lyric": yrc ?? ""], "tlyric": ["lyric": tlyric ?? ""],
              "ytlrc": ["lyric": ""], "romalrc": ["lyric": ""]])
    }

    func testYRCWithTranslation() async throws {
        let http = MockHTTP()
        http.on("/api/search/get", body: search)
        http.on("id=222", body: lyricBody(lrc: "[00:01.00]one"))
        http.on("id=333", body: lyricBody(yrc: Fixtures.yrc, tlyric: "[00:01.000]привет\n[00:05.000]дальше"))
        let p = NetEaseProvider(http: http)
        let r = try await p.lyrics(for: TrackQuery(title: "Test Song", artist: "Test Artist", duration: 200))
        XCTAssertEqual(r.first?.syncType, .word)
        XCTAssertEqual(r.first?.source.trackID, "333")
        XCTAssertEqual(r.first?.lines[0].translation?.text, "привет")
        XCTAssertEqual(r.first?.lines[1].translation?.text, "дальше")
        XCTAssertFalse(http.requests(containing: "id=111").contains { _ in true }, "live-версию не опрашиваем")
        let req = http.requests(containing: "/api/song/lyric").first!
        XCTAssertTrue(req.url!.absoluteString.contains("yv=1"))
        XCTAssertEqual(req.value(forHTTPHeaderField: "Referer"), "https://music.163.com/")
    }

    func testLRCFallbackStripsCredits() async throws {
        let http = MockHTTP()
        http.on("/api/search/get", body: search)
        http.on("/api/song/lyric", body: lyricBody(lrc: "[00:00.025] 作词 : Someone\n[00:00.050] 作曲 : Other\n[00:12.00]real line\n[00:20.00]second"))
        let r = try await NetEaseProvider(http: http, maxCandidates: 1).lyrics(for: TrackQuery(title: "Test Song", artist: "Test Artist", duration: 200))
        XCTAssertEqual(r.first?.syncType, .line)
        XCTAssertEqual(r.first?.lines.map(\.text), ["real line", "second"])
        XCTAssertEqual(r.first?.songwriters, ["Someone", "Other"])
    }

    func testUncollectedAndEncryptedSearch() async throws {
        let http = MockHTTP()
        http.on("/api/search/get", body: search)
        http.on("/api/song/lyric", body: #"{"uncollected":true,"lrc":{"lyric":""},"code":200}"#)
        let r = try await NetEaseProvider(http: http).lyrics(for: TrackQuery(title: "Test Song", artist: "Test Artist", duration: 200))
        XCTAssertTrue(r.isEmpty)

        let http2 = MockHTTP()
        http2.on("/api/search/get", body: #"{"result":"A1B2C3","abroad":true,"code":200}"#)
        do {
            _ = try await NetEaseProvider(http: http2).lyrics(for: TrackQuery(title: "x", artist: "y", duration: 1))
            XCTFail("ожидалась ошибка")
        } catch let e as LyricsError {
            if case .badResponse = e {} else { XCTFail("\(e)") }
        }
    }

    func testPureMusic() throws {
        let l = try NetEaseProvider.makeLyrics(from: Data(#"{"pureMusic":true,"code":200}"#.utf8), source: Fixtures.src)
        XCTAssertTrue(l?.isInstrumental == true)
    }
}

final class QQProviderTests: XCTestCase {
    let search = json(["code": 0, "data": ["song": ["list": [
        ["id": 555, "mid": "MID555", "name": "Test Song", "singer": [["name": "Test Artist"]], "album": ["name": "Test Album"], "interval": 200],
    ]]]])

    func qrcResponse(contentHex: String, ts: String = "", roma: String = "") -> String {
        """
        <!--
        <?xml version="1.0" encoding="utf-8"?><lyric><content type="file" mime="file"><![CDATA[\(contentHex)]]></content><contentts type="file" mime="file"><![CDATA[\(ts)]]></contentts><contentroma type="file" mime="file"><![CDATA[\(roma)]]></contentroma></lyric>
        -->
        """
    }

    func testQRCEncryptedWithTranslation() async throws {
        let http = MockHTTP()
        http.on("client_search_cp", body: search)
        http.on("lyric_download", method: "POST", body: qrcResponse(contentHex: Fixtures.qrcEncryptedHex, ts: "[00:01.00]привет\n[00:04.00]пока"))
        let r = try await QQProvider(http: http).lyrics(for: TrackQuery(title: "Test Song", artist: "Test Artist", duration: 200))
        XCTAssertEqual(r.first?.syncType, .word)
        XCTAssertEqual(r.first?.source.trackID, "MID555")
        XCTAssertEqual(r.first?.lines[0].text, "Hello world!")
        XCTAssertEqual(r.first?.lines[0].translation?.text, "привет")
        XCTAssertEqual(r.first?.lines[1].translation?.text, "пока")
        let post = http.requests(containing: "lyric_download").first!
        XCTAssertEqual(String(data: post.httpBody!, encoding: .utf8), "version=15&miniversion=82&lrctype=4&musicid=555")
        XCTAssertEqual(post.value(forHTTPHeaderField: "Referer"), "https://y.qq.com/")
    }

    func testFallsBackToLRCWhenQRCEmpty() async throws {
        let lrc = Data("[ti:Test Song]\n[00:00.00]Test Song - Test Artist\n[00:10.00]first &apos;line&apos;\n[00:20.00]second".utf8).base64EncodedString()
        let http = MockHTTP()
        http.on("client_search_cp", body: search)
        http.on("lyric_download", method: "POST", body: qrcResponse(contentHex: ""))
        http.on("fcg_query_lyric_new", body: json(["retcode": 0, "lyric": lrc, "trans": ""]))
        let r = try await QQProvider(http: http).lyrics(for: TrackQuery(title: "Test Song", artist: "Test Artist", duration: 200))
        XCTAssertEqual(r.first?.syncType, .line)
        XCTAssertEqual(r.first?.lines.map(\.text), ["first 'line'", "second"])   // заголовок вырезан, сущности раскрыты
        XCTAssertTrue(http.requests(containing: "songmid=MID555").count == 1)
    }

    func testJSONPAndRejection() throws {
        let wrapped = Data("callback(\(search))".utf8)
        let (c, s) = try QQProvider.parseSearch(wrapped)
        XCTAssertEqual(c.first?.duration, 200)
        XCTAssertEqual(s["555"]?.mid, "MID555")
    }

    func testSmartboxFallbackWhenMainSearchFails() async throws {
        let http = MockHTTP()
        http.on("client_search_cp", status: 500)
        http.on("smartbox_new", body: json(["code": 0, "data": ["song": ["count": 2, "itemlist": [
            ["id": "555", "mid": "MID555", "name": "Test Song", "singer": "Test Artist"],
            ["id": "556", "mid": "MID556", "name": "Test Song (Live)", "singer": "Test Artist"],
        ]]]]))
        http.on("lyric_download", method: "POST", body: qrcResponse(contentHex: Fixtures.qrcEncryptedHex))
        let r = try await QQProvider(http: http).lyrics(for: TrackQuery(title: "Test Song", artist: "Test Artist", duration: 200))
        XCTAssertEqual(r.first?.syncType, .word)
        XCTAssertEqual(r.first?.source.trackID, "MID555")
        XCTAssertEqual(r.count, 1)
    }

    func testSmartboxTextLongerThanTrackIsRejected() async throws {
        let http = MockHTTP()
        http.on("client_search_cp", status: 500)
        http.on("smartbox_new", body: json(["code": 0, "data": ["song": ["itemlist": [["id": "555", "mid": "MID555", "name": "Test Song", "singer": "Test Artist"]]]]]))
        // открытый QRC: последняя строка заканчивается на 101 с, а трек — 30 с (другая версия) → отказ
        http.on("lyric_download", method: "POST", body: qrcResponse(contentHex: "[2000,1000]Early (2000,500)line(2500,500)\n[100000,1000]Late (100000,500)line(100500,500)"))
        let bad = try await QQProvider(http: http).lyrics(for: TrackQuery(title: "Test Song", artist: "Test Artist", duration: 30))
        XCTAssertTrue(bad.isEmpty)
        let ok = try await QQProvider(http: http).lyrics(for: TrackQuery(title: "Test Song", artist: "Test Artist", duration: 100))
        XCTAssertEqual(ok.count, 1)
    }

    func testOpenTextInsideContentIsAccepted() throws {
        let resp = qrcResponse(contentHex: "[0,100]x(0,50)y(50,50)\n[500,500]Open (500,250)text(750,250)")
        let l = try QQProvider.makeLyrics(fromQRCResponse: resp, source: Fixtures.src, knownTitle: nil)
        XCTAssertEqual(l?.lines.last?.text, "Open text")
    }
}
