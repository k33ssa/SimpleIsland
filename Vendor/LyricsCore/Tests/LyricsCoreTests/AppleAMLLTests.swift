import XCTest
@testable import LyricsCore

enum FakeJWT {
    static func make(iss: String = "AMPWebPlay", exp: TimeInterval, tag: String = "sig") -> String {
        func b64(_ s: String) -> String {
            Data(s.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        return "\(b64(#"{"alg":"ES256","kid":"WebPlayKid"}"#)).\(b64(#"{"iss":"\#(iss)","iat":1,"exp":\#(Int(exp))}"#)).\(tag)Signature123"
    }
}

final class AppleTokenTests: XCTestCase {
    let future = Date().addingTimeInterval(60 * 86400).timeIntervalSince1970

    func bundle(_ real: String, decoy: String) -> String {
        "var a=\"\(decoy)\";var cfg={developerToken:\"\(real)\",app:\"web\"};"
    }

    func makeHTTP(real: String) -> MockHTTP {
        let http = MockHTTP()
        http.on("music.apple.com/us/browse", body: #"<html><script type="module" crossorigin src="/assets/vendor~x.js"></script><script type="module" crossorigin src="/assets/index~abc.js"></script></html>"#)
        http.on("/assets/index~abc.js", body: bundle(real, decoy: FakeJWT.make(iss: "SomethingElse", exp: future + 99999, tag: "decoy")))
        http.on("/assets/vendor~x.js", body: "nothing")
        return http
    }

    func testScrapeCachePersist() async throws {
        let real = FakeJWT.make(exp: future)
        let http = makeHTTP(real: real)
        let store = InMemoryCredentialStore()
        let tp = AppleDeveloperTokenProvider(http: http, store: store)
        let t1 = try await tp.token()
        XCTAssertEqual(t1, real)                                   // ложный JWT другого издателя проигнорирован
        let t2 = try await tp.token()
        XCTAssertEqual(t2, real)
        XCTAssertEqual(http.requests(containing: "/assets/index~abc.js").count, 1)   // повторно не качает
        let stored = try await store.value(for: .appleDeveloperToken)
        XCTAssertNotNil(stored)

        // новый экземпляр берёт токен из хранилища, не ходит в сеть
        let http2 = MockHTTP()
        let tp2 = AppleDeveloperTokenProvider(http: http2, store: store)
        let t3 = try await tp2.token()
        XCTAssertEqual(t3, real)
        XCTAssertTrue(http2.requests.isEmpty)
    }

    func testExpiredTokenIsReplaced() async throws {
        let old = FakeJWT.make(exp: Date().addingTimeInterval(600).timeIntervalSince1970, tag: "old")   // меньше запаса в час
        let store = InMemoryCredentialStore([.appleDeveloperToken: try! String(data: JSONEncoder().encode(AppleDeveloperTokenProvider.Stored(token: old, exp: Date().addingTimeInterval(600).timeIntervalSince1970)), encoding: .utf8)!])
        let fresh = FakeJWT.make(exp: future, tag: "fresh")
        let tp = AppleDeveloperTokenProvider(http: makeHTTP(real: fresh), store: store)
        let t = try await tp.token()
        XCTAssertEqual(t, fresh)
    }

    func testForceRefreshAndInvalidate() async throws {
        let real = FakeJWT.make(exp: future)
        let http = makeHTTP(real: real)
        let tp = AppleDeveloperTokenProvider(http: http, store: nil)
        _ = try await tp.token()
        _ = try await tp.token(forceRefresh: true)
        XCTAssertEqual(http.requests(containing: "/assets/index~abc.js").count, 2)
    }

    func testNoTokenInBundleFails() async {
        let http = MockHTTP()
        http.on("music.apple.com/us/browse", body: #"<script src="/assets/index~z.js"></script>"#)
        http.on("/assets/index~z.js", body: "no tokens here")
        do {
            _ = try await AppleDeveloperTokenProvider(http: http).token()
            XCTFail()
        } catch let e as LyricsError {
            if case .badResponse = e {} else { XCTFail("\(e)") }
        } catch { XCTFail("\(error)") }
    }

    func testFindTokenIgnoresExpiredOrForeign() {
        let js = "\"\(FakeJWT.make(iss: "Other", exp: future))\" \"\(FakeJWT.make(exp: future + 10, tag: "later"))\" \"\(FakeJWT.make(exp: future, tag: "earlier"))\""
        let f = AppleDeveloperTokenProvider.findToken(inJS: js)
        XCTAssertEqual(Int(f!.exp), Int(future + 10))
        XCTAssertNil(AppleDeveloperTokenProvider.findToken(inJS: "eyJabc.eyJdef.ghi"))
    }
}

final class AppleMusicProviderTests: XCTestCase {
    let future = Date().addingTimeInterval(60 * 86400).timeIntervalSince1970
    let secretMUT = "SECRET-MEDIA-USER-TOKEN-VALUE"

    func wordTTMLResponse() -> String { json(["data": [["attributes": ["ttml": Fixtures.ttmlWord]]]]) }
    func lineTTMLResponse() -> String { json(["data": [["attributes": ["ttml": Fixtures.ttmlLine]]]]) }

    func makeProvider(_ http: MockHTTP, mut: String? = "SECRET-MEDIA-USER-TOKEN-VALUE") -> (AppleMusicProvider, JWTBox) {
        let jwt = FakeJWT.make(exp: future)
        http.on("music.apple.com/us/browse", body: #"<script src="/assets/index~abc.js"></script>"#)
        http.on("/assets/index~abc.js", body: "x=\"\(jwt)\"")
        var initial: [CredentialKey: String] = [:]
        if let mut { initial[.mediaUserToken] = mut }
        let store = InMemoryCredentialStore(initial)
        var o = AppleMusicProvider.Options(language: "en-US")
        o.host = "https://amp.test"
        return (AppleMusicProvider(http: http, credentials: store, options: o), JWTBox(jwt: jwt, store: store))
    }
    struct JWTBox { var jwt: String; var store: InMemoryCredentialStore }

    func testSyllableLyricsHappyPath() async throws {
        let http = MockHTTP()
        http.on("/v1/me/storefront", body: json(["data": [["id": "ru", "type": "storefronts"]]]))
        http.on("/songs/123/syllable-lyrics", body: wordTTMLResponse())
        let (p, box) = makeProvider(http)
        let r = try await p.lyrics(for: TrackQuery(catalogId: "123", title: "T", artist: "A", duration: 200))
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].syncType, .word)
        XCTAssertEqual(r[0].source.provider, .appleMusic)
        XCTAssertEqual(r[0].source.matchKind, .catalogID)
        XCTAssertEqual(r[0].source.confidence, 1)
        // storefront взят из /v1/me/storefront и сохранён
        let sf = try await box.store.value(for: .appleStorefront)
        XCTAssertEqual(sf, "ru")
        let req = http.requests(containing: "/syllable-lyrics").first!
        XCTAssertTrue(req.url!.absoluteString.contains("/v1/catalog/ru/songs/123/syllable-lyrics"))
        XCTAssertTrue(req.url!.absoluteString.contains("extend=ttmlLocalizations"))
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer \(box.jwt)")
        XCTAssertEqual(req.value(forHTTPHeaderField: "media-user-token"), secretMUT)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Origin"), "https://music.apple.com")
    }

    func testFallbackToLinesWhen404() async throws {
        let http = MockHTTP()
        http.on("/v1/me/storefront", body: json(["data": [["id": "us"]]]))
        http.on("/songs/5/syllable-lyrics", status: 404, body: "{}")
        http.on("/songs/5/lyrics", body: lineTTMLResponse())
        let (p, _) = makeProvider(http)
        let r = try await p.lyrics(for: TrackQuery(catalogId: "5", title: "T", artist: "A"))
        XCTAssertEqual(r.first?.syncType, .line)
        XCTAssertEqual(http.requests(containing: "/syllable-lyrics").count, 1)
    }

    func testNoLyricsAtAll() async throws {
        let http = MockHTTP()
        http.on("/v1/me/storefront", body: json(["data": [["id": "us"]]]))
        http.on("/songs/5/", status: 404, body: "{}")
        let (p, _) = makeProvider(http)
        let r = try await p.lyrics(for: TrackQuery(catalogId: "5", title: "T", artist: "A"))
        XCTAssertTrue(r.isEmpty)
    }

    func testUnauthorizedRefreshesDeveloperTokenOnceThenFails() async throws {
        let http = MockHTTP()
        http.on("/v1/me/storefront", body: json(["data": [["id": "us"]]]))
        http.on("/songs/5/syllable-lyrics", status: 403, body: "{}")
        let (p, _) = makeProvider(http)
        do {
            _ = try await p.lyrics(for: TrackQuery(catalogId: "5", title: "T", artist: "A"))
            XCTFail()
        } catch let e as LyricsError {
            XCTAssertEqual(e, .unauthorized)
            XCTAssertFalse(e.description.contains(secretMUT))
        }
        // один повтор после перевыпуска токена: два запроса текста, две загрузки бандла (первая + перевыпуск)
        XCTAssertEqual(http.requests(containing: "/songs/5/syllable-lyrics").count, 2)
        XCTAssertEqual(http.requests(containing: "/assets/index~abc.js").count, 2)
    }

    func testRefreshRecoversAfter401() async throws {
        let http = MockHTTP()
        http.on("/v1/me/storefront", body: json(["data": [["id": "us"]]]))
        let counter = Counter()
        http.on("/songs/5/syllable-lyrics") { _ in
            counter.increment() == 1 ? HTTPResponse(data: Data("{}".utf8), status: 401) : HTTPResponse(data: Data(self.wordTTMLResponse().utf8), status: 200)
        }
        let (p, _) = makeProvider(http)
        let r = try await p.lyrics(for: TrackQuery(catalogId: "5", title: "T", artist: "A"))
        XCTAssertEqual(r.first?.syncType, .word)
    }

    func testMissingMediaUserToken() async {
        let http = MockHTTP()
        let (p, _) = makeProvider(http, mut: nil)
        let avail = await p.isAvailable()
        XCTAssertFalse(avail)
        do { _ = try await p.lyrics(for: TrackQuery(catalogId: "5", title: "T", artist: "A")); XCTFail() }
        catch let e as LyricsError { XCTAssertEqual(e, .notConfigured("media-user-token")) }
        catch { XCTFail("\(error)") }
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testTTMLLocalizationsDictionary() {
        let body = json(["data": [["attributes": ["ttml": "plain", "ttmlLocalizations": ["ru-RU": "RU", "en-US": "EN"]]]]])
        XCTAssertEqual(AppleMusicProvider.extractTTML(from: Data(body.utf8), preferredLanguage: "en-US"), "EN")
        XCTAssertEqual(AppleMusicProvider.extractTTML(from: Data(body.utf8), preferredLanguage: "ru"), "RU")
        let only = json(["data": [["attributes": ["ttmlLocalizations": "STR"]]]])
        XCTAssertEqual(AppleMusicProvider.extractTTML(from: Data(only.utf8), preferredLanguage: "en"), "STR")
        XCTAssertNil(AppleMusicProvider.extractTTML(from: Data("{}".utf8), preferredLanguage: "en"))
    }

    func testResolveByISRCWhenNoCatalogId() async throws {
        let http = MockHTTP()
        http.on("/v1/me/storefront", body: json(["data": [["id": "us"]]]))
        http.on("filter%5Bisrc%5D=USABC1234567", body: json(["data": [["id": "777", "attributes": ["name": "Test Song", "artistName": "Test Artist", "durationInMillis": 200000]]]]))
        http.on("/songs/777/syllable-lyrics", body: wordTTMLResponse())
        let (p, _) = makeProvider(http)
        let r = try await p.lyrics(for: TrackQuery(title: "Test Song", artist: "Test Artist", duration: 200, isrc: "US-ABC-12-34567"))
        XCTAssertEqual(r.first?.source.trackID, "777")
        XCTAssertEqual(r.first?.source.matchKind, .isrc)
    }

    func testResolveBySearchRespectsMatcher() async throws {
        let http = MockHTTP()
        http.on("/v1/me/storefront", body: json(["data": [["id": "us"]]]))
        http.on("/catalog/us/search", body: json(["results": ["songs": ["data": [
            ["id": "1", "attributes": ["name": "Test Song (Live)", "artistName": "Test Artist", "durationInMillis": 260000]],
            ["id": "2", "attributes": ["name": "Test Song", "artistName": "Test Artist", "durationInMillis": 200400]],
        ]]]]))
        http.on("/songs/2/syllable-lyrics", body: wordTTMLResponse())
        let (p, _) = makeProvider(http)
        let r = try await p.lyrics(for: TrackQuery(title: "Test Song", artist: "Test Artist", duration: 200))
        XCTAssertEqual(r.first?.source.trackID, "2")
        XCTAssertEqual(r.first?.source.matchKind, .metadata)

        // ничего подходящего — пусто, без запроса текста
        let http2 = MockHTTP()
        http2.on("/v1/me/storefront", body: json(["data": [["id": "us"]]]))
        http2.on("/catalog/us/search", body: json(["results": ["songs": ["data": [["id": "9", "attributes": ["name": "Other", "artistName": "Else", "durationInMillis": 100000]]]]]]))
        let (p2, _) = makeProvider(http2)
        let r2 = try await p2.lyrics(for: TrackQuery(title: "Test Song", artist: "Test Artist", duration: 200))
        XCTAssertTrue(r2.isEmpty)
        XCTAssertTrue(http2.requests(containing: "lyrics").isEmpty)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    @discardableResult func increment() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
    func decrementOnly() { lock.lock(); n -= 1; lock.unlock() }
    func set(_ v: Int) { lock.lock(); n = v; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

final class AMLLProviderTests: XCTestCase {
    let ttml = Fixtures.ttmlAMLL
    let base = "https://raw.githubusercontent.com/amll-dev/amll-ttml-db/main"

    func index(_ rows: [(id: String, title: String, artist: String, isrc: String?, am: String?)]) -> String {
        rows.map { r in
            var meta: [[Any]] = [["album", ["Album"]], ["artists", [r.artist]], ["musicName", [r.title]]]
            if let i = r.isrc { meta.append(["isrc", [i]]) }
            if let a = r.am { meta.append(["appleMusicId", [a]]) }
            return json(["id": r.id, "metadata": meta, "rawLyricFile": "x.ttml"])
        }.joined(separator: "\n")
    }

    func provider(_ http: MockHTTP, dir: URL? = nil, mode: AMLLProvider.IndexDownload = .await) -> AMLLProvider {
        var o = AMLLProvider.Options(); o.indexDownload = mode
        return AMLLProvider(http: http, cacheDirectory: dir ?? tmpDir(), options: o)
    }

    func tmpDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("amll-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func testDirectHitByCatalogId() async throws {
        let http = MockHTTP()
        http.on("/am-lyrics/111.ttml", body: ttml)
        let r = try await provider(http).lyrics(for: TrackQuery(catalogId: "111", title: "x", artist: "y"))
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].syncType, .word)
        XCTAssertEqual(r[0].source.matchKind, .catalogID)
        XCTAssertEqual(r[0].source.trackID, "am-lyrics/111")
        XCTAssertEqual(r[0].source.title, "Test Song")
        XCTAssertTrue(http.requests(containing: "index.jsonl").isEmpty)
    }

    func testIndexSearchByISRC() async throws {
        let http = MockHTTP()
        http.on("/am-lyrics/index.jsonl", body: index([("999", "Other Name", "Someone", "XXAAA0000001", nil)]))
        http.on("/am-lyrics/999.ttml", body: ttml)
        let q = TrackQuery(catalogId: "404", title: "Test Song", artist: "Test Artist", duration: 60, isrc: "XX-AAA-00-00001")
        http.on("/am-lyrics/404.ttml", status: 404)
        let r = try await provider(http).lyrics(for: q)
        XCTAssertEqual(r.first?.source.matchKind, .isrc)
        XCTAssertEqual(r.first?.source.trackID, "am-lyrics/999")
    }

    func testIndexSearchByMetadataIsStrict() async throws {
        let http = MockHTTP()
        http.on("/am-lyrics/index.jsonl", body: index([("1", "Test Song", "Test Artist", nil, nil), ("2", "Test Song Two", "Another", nil, nil)]))
        http.on("/ncm-lyrics/index.jsonl", body: "")
        http.on("/am-lyrics/1.ttml", body: ttml)
        let r = try await provider(http).lyrics(for: TrackQuery(title: "Test Song", artist: "Test Artist", duration: 60))
        XCTAssertEqual(r.first?.source.trackID, "am-lyrics/1")
        XCTAssertEqual(r.first?.source.matchKind, .metadata)
        XCTAssertLessThanOrEqual(r.first!.source.confidence, 0.95)
        // другой исполнитель — отказ
        let r2 = try await provider(http).lyrics(for: TrackQuery(title: "Test Song", artist: "Nobody Else", duration: 60))
        XCTAssertTrue(r2.isEmpty)
    }

    func testRejectsTextMuchLongerThanTrack() async throws {
        let http = MockHTTP()
        http.on("/am-lyrics/index.jsonl", body: index([("1", "Test Song", "Test Artist", nil, nil)]))
        http.on("/ncm-lyrics/index.jsonl", body: "")
        http.on("/am-lyrics/1.ttml", body: ttml)                 // строка заканчивается на 5 с
        // трек длиной 200 с — текст короче, это нормально; а вот длина трека 1 с и текст до 5 с — нет, но допуск 20 с
        let ok = try await provider(http).lyrics(for: TrackQuery(title: "Test Song", artist: "Test Artist", duration: 200))
        XCTAssertEqual(ok.count, 1)
        let long = ttml.replacingOccurrences(of: "end=\"00:05.000\"", with: "end=\"05:00.000\"")
        http.on("/am-lyrics/1.ttml", body: long)
        let bad = try await provider(http).lyrics(for: TrackQuery(title: "Test Song", artist: "Test Artist", duration: 100))
        // текст другой версии: больше не выбрасывается, но помечен near-miss и не может стать лучшим
        XCTAssertTrue(bad.allSatisfy { $0.source.matchQuality.isNearMiss })
        XCTAssertEqual(bad.count, 1)
    }

    func testBackgroundModeDoesNotBlockAndWarmsIndex() async throws {
        let http = MockHTTP()
        http.on("/am-lyrics/index.jsonl", body: index([("1", "Test Song", "Test Artist", nil, nil)]))
        http.on("/ncm-lyrics/index.jsonl", body: "")
        http.on("/am-lyrics/1.ttml", body: ttml)
        let dir = tmpDir()
        let p = provider(http, dir: dir, mode: .background)
        let q = TrackQuery(title: "Test Song", artist: "Test Artist", duration: 60)
        let first = try await p.lyrics(for: q)
        XCTAssertTrue(first.isEmpty, "индекса ещё нет — по метаданным не ищем, каскад не задерживаем")
        // фоновая загрузка закончилась → следующий запрос находит
        var found: [Lyrics] = []
        for _ in 0..<50 {
            found = try await p.lyrics(for: q)
            if !found.isEmpty { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(found.first?.source.trackID, "am-lyrics/1")
        XCTAssertEqual(http.requests(containing: "/am-lyrics/index.jsonl").count, 1)
    }

    func testPrefetch() async throws {
        let http = MockHTTP()
        http.on("/am-lyrics/index.jsonl", body: index([("1", "Test Song", "Test Artist", nil, nil)]))
        http.on("/ncm-lyrics/index.jsonl", body: index([]))
        let p = provider(http, mode: .background)
        await p.prefetchIndexes()
        XCTAssertEqual(http.requests(containing: "index.jsonl").count, 2)
    }

    func testIndexIsCachedOnDiskWithETag() async throws {
        let dir = tmpDir()
        let http = MockHTTP()
        http.on("/am-lyrics/index.jsonl") { req in
            if req.value(forHTTPHeaderField: "If-None-Match") == "\"abc\"" { return HTTPResponse(data: Data(), status: 304) }
            return HTTPResponse(data: Data(self.index([("1", "Test Song", "Test Artist", nil, nil)]).utf8), status: 200, headers: ["ETag": "\"abc\""])
        }
        var opts = AMLLProvider.Options(); opts.indexTTL = 0       // всегда считаем устаревшим → условный запрос
        let store = AMLLIndexStore(http: http, base: base, directory: dir, ttl: 0, timeout: 5)
        let a = try await store.entries(folder: "am-lyrics", mode: .await)!
        XCTAssertEqual(a.count, 1)
        let store2 = AMLLIndexStore(http: http, base: base, directory: dir, ttl: 0, timeout: 5)
        let b = try await store2.entries(folder: "am-lyrics", mode: .await)!
        XCTAssertEqual(b, a)
        XCTAssertEqual(http.requests(containing: "index.jsonl").count, 2)
        XCTAssertEqual(http.requests(containing: "index.jsonl")[1].value(forHTTPHeaderField: "If-None-Match"), "\"abc\"")
        _ = opts
    }
}
