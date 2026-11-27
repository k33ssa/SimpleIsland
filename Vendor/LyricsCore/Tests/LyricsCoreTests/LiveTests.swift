import XCTest
@testable import LyricsCore

/// Живые проверки сети. Выполняются только при `AMNL_LIVE=1`. Тексты песен не сохраняются и не печатаются —
/// проверяется только структура. Apple без media-user-token не проверяется (токен есть только у пользователя).
final class LiveTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AMNL_LIVE"] == "1", "AMNL_LIVE=1 не задан")
    }

    let queen = TrackQuery(title: "Bohemian Rhapsody", artist: "Queen", album: "A Night at the Opera", duration: 355)
    let http = URLSessionHTTPClient(timeout: 15)

    func testLRCLIB() async throws {
        let r = try await LRCLIBProvider(http: http).lyrics(for: queen)
        XCTAssertFalse(r.isEmpty)
        XCTAssertNotEqual(r.first?.syncType, SyncType.none)
        print("LIVE lrclib: \(r.map { "\($0.syncType.rawValue)/\($0.source.format ?? "")/\($0.lines.count)" })")
    }

    func testNetEase() async throws {
        let r = try await NetEaseProvider(http: http).lyrics(for: queen)
        XCTAssertFalse(r.isEmpty)
        print("LIVE netease: \(r.map { "\($0.syncType.rawValue)/\($0.source.format ?? "")/\($0.lines.count) conf=\(String(format: "%.2f", $0.source.confidence))" })")
        XCTAssertEqual(r.first?.syncType, .word)
    }

    func testQQ() async throws {
        let r = try await QQProvider(http: http).lyrics(for: queen)
        XCTAssertFalse(r.isEmpty)
        print("LIVE qq: \(r.map { "\($0.syncType.rawValue)/\($0.source.format ?? "")/\($0.lines.count) conf=\(String(format: "%.2f", $0.source.confidence))" })")
        XCTAssertEqual(r.first?.syncType, .word)
    }

    func testAMLLDirectAndIndex() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("amll-live-\(UUID().uuidString)")
        var opts = AMLLProvider.Options(); opts.indexDownload = .await
        let p = AMLLProvider(http: http, cacheDirectory: dir, options: opts)
        // прямое попадание по id каталога Apple (запись есть в am-lyrics на 14.11.2026)
        let direct = try await p.lyrics(for: TrackQuery(catalogId: "1443431915", title: "x", artist: "y"))
        XCTAssertEqual(direct.first?.syncType, .word)
        XCTAssertEqual(direct.first?.source.matchKind, .catalogID)
        // индекс: поиск по ISRC (формат с дефисами нормализуется)
        let byISRC = try await p.lyrics(for: TrackQuery(catalogId: "000", title: "吻别", artist: "张学友", isrc: "CN-E22-19-00702"))
        XCTAssertEqual(byISRC.first?.source.matchKind, .isrc)
        print("LIVE amll: direct=\(direct.first?.lines.count ?? 0) lines, byISRC=\(byISRC.first?.lines.count ?? 0) lines")
    }

    func testAppleDeveloperTokenScrape() async throws {
        let tp = AppleDeveloperTokenProvider(http: http)
        let t = try await tp.token()
        let payload = try XCTUnwrap(AppleDeveloperTokenProvider.decodePayload(t))
        XCTAssertEqual(payload["iss"] as? String, "AMPWebPlay")
        let exp = (payload["exp"] as? NSNumber)?.doubleValue ?? 0
        XCTAssertGreaterThan(exp, Date().timeIntervalSince1970)
        print("LIVE apple token: iss=AMPWebPlay, действует ещё \(Int((exp - Date().timeIntervalSince1970) / 86400)) сут. (значение не печатается)")
    }

    func testFullCascadeWithoutAppleToken() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cascade-live-\(UUID().uuidString)")
        let engine = LyricsEngine.standard(credentials: InMemoryCredentialStore(), http: http, cacheDirectory: dir)
        var o = FetchOptions(); o.exhaustive = true
        let t0 = Date()
        let r = await engine.lyrics(for: queen, options: o)
        print("LIVE cascade за \(String(format: "%.1f", Date().timeIntervalSince(t0))) с: best=\(r.best?.source.provider.rawValue ?? "-")/\(r.best?.syncType.rawValue ?? "-"), альтернатив \(r.alternatives.count)")
        for o in r.outcomes { print("   \(o.provider.rawValue): \(o.status) \(String(format: "%.1f", o.seconds)) с") }
        XCTAssertNotNil(r.best)
        XCTAssertEqual(r.best?.syncType, .word)
        XCTAssertEqual(r.outcomes.first { $0.provider == .appleMusic }?.status, .skipped("недоступен"))
        // повторный вызов — из кэша
        let again = await engine.lyrics(for: queen)
        XCTAssertTrue(again.fromCache)
    }

    func testRussianTrackCascade() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cascade-ru-\(UUID().uuidString)")
        let engine = LyricsEngine.standard(credentials: InMemoryCredentialStore(), http: http, cacheDirectory: dir)
        let q = TrackQuery(title: "Группа крови", artist: "Кино", album: "Группа крови", duration: 284)
        var o = FetchOptions(); o.exhaustive = true
        let r = await engine.lyrics(for: q, options: o)
        print("LIVE ru: best=\(r.best?.source.provider.rawValue ?? "-")/\(r.best?.syncType.rawValue ?? "-"), альтернатив \(r.alternatives.count)")
        for o in r.outcomes { print("   \(o.provider.rawValue): \(o.status)") }
        XCTAssertNotNil(r.best)
    }
}
