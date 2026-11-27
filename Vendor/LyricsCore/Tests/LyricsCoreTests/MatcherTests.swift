import XCTest
@testable import LyricsCore

final class NormalizerTests: XCTestCase {
    func testFold() {
        XCTAssertEqual(TextNormalizer.fold("  Beyoncé — Déjà Vu! "), "beyonce deja vu")
        XCTAssertEqual(TextNormalizer.fold("Simon & Garfunkel"), "simon and garfunkel")
        XCTAssertEqual(TextNormalizer.fold("ＡＢＣ１２３"), "abc123")
        XCTAssertEqual(TextNormalizer.fold("Ёлка"), "елка")
        XCTAssertEqual(TextNormalizer.fold("夜に駆ける"), "夜に駆ける")
    }

    func testTitleQualifiersAreClassifiedNotDropped() {
        let t = TextNormalizer.parseTitle("Song Name (Remastered 2011) [Live at Venue] (feat. Guest One & Guest Two)")
        XCTAssertEqual(t.base, "song name")
        XCTAssertEqual(t.tags, [.remaster, .live])
        XCTAssertEqual(t.featured, ["guest one", "guest two"])
        XCTAssertEqual(t.qualifiers.count, 3)
        XCTAssertEqual(t.display, "Song Name")
    }

    func testTailQualifier() {
        let t = TextNormalizer.parseTitle("Song - Remastered 2011")
        XCTAssertEqual(t.base, "song")
        XCTAssertEqual(t.tags, [.remaster])
        let u = TextNormalizer.parseTitle("Song - Live at Wembley Stadium")
        XCTAssertEqual(u.tags, [.live])
        // обычный дефис в названии не трогаем
        let w = TextNormalizer.parseTitle("Rock - n - Roll Star")
        XCTAssertEqual(w.tags, [])
        XCTAssertEqual(w.base, "rock n roll star")
    }

    func testUnrecognizedBracketsStayInTitle() {
        let t = TextNormalizer.parseTitle("(I Can't Get No) Satisfaction")
        XCTAssertEqual(t.base, "i can t get no satisfaction")
        XCTAssertTrue(t.tags.isEmpty)
    }

    func testFeatWithoutBrackets() {
        let t = TextNormalizer.parseTitle("Song feat. Someone Else")
        XCTAssertEqual(t.base, "song")
        XCTAssertEqual(t.featured, ["someone else"])
    }

    func testVersionTagsMultilingual() {
        XCTAssertEqual(TextNormalizer.parseTitle("Песня (Remix)").tags, [.remix])
        XCTAssertEqual(TextNormalizer.parseTitle("Песня (Акустическая версия)").tags.contains(.acoustic), true)
        XCTAssertEqual(TextNormalizer.parseTitle("曲 (Instrumental)").tags, [.instrumental])
        XCTAssertEqual(TextNormalizer.parseTitle("Song (Sped Up)").tags, [.speedChanged])
        XCTAssertEqual(TextNormalizer.parseTitle("Song (Deluxe Edition)").tags, [.deluxe])
        XCTAssertEqual(TextNormalizer.parseTitle("Song (Radio Edit)").tags, [.radioEdit])
    }

    func testArtistSplitting() {
        XCTAssertEqual(TextNormalizer.splitArtists("Artist A & Artist B, Artist C feat. D"),
                       ["artist a", "artist b", "artist c", "d"])
        XCTAssertEqual(TextNormalizer.splitArtistsRaw("Первый, Второй").first, "Первый")
    }

    func testSimilarity() {
        XCTAssertEqual(TextNormalizer.similarity("abc", "abc"), 1)
        XCTAssertGreaterThanOrEqual(TextNormalizer.similarity("bohemian rhapsody", "bohemian rhapsody remaster"), 0.8)
        XCTAssertLessThan(TextNormalizer.similarity("hello", "goodbye"), 0.4)
        XCTAssertEqual(TextNormalizer.similarity("", "x"), 0)
    }
}

final class MatcherTests: XCTestCase {
    let matcher = TrackMatcher()

    func q(_ title: String = "Test Song", _ artist: String = "Test Artist", album: String? = "Test Album",
           duration: TimeInterval? = 200, isrc: String? = nil) -> TrackQuery {
        TrackQuery(title: title, artist: artist, album: album, duration: duration, isrc: isrc)
    }

    func testExactMatchAccepted() {
        let e = matcher.evaluate(q(), TrackCandidate(id: "1", title: "Test Song", artists: ["Test Artist"], album: "Test Album", duration: 200.4))
        XCTAssertTrue(e.accepted)
        XCTAssertGreaterThan(e.score, 0.97)
    }

    func testRemasterIsMinorLiveIsSignificant() {
        let base = q("Test Song (Remastered 2011)")
        let remaster = matcher.evaluate(base, TrackCandidate(id: "1", title: "Test Song", artists: ["Test Artist"], duration: 200))
        XCTAssertTrue(remaster.accepted)
        XCTAssertGreaterThan(remaster.score, 0.93)
        XCTAssertTrue(remaster.versionMismatch.isEmpty)           // remaster — не значимое различие
        XCTAssertGreaterThan(remaster.versionPenalty, 0)           // но не молча: небольшой штраф есть

        let live = matcher.evaluate(q(), TrackCandidate(id: "2", title: "Test Song - Live at Venue", artists: ["Test Artist"], duration: 200))
        XCTAssertEqual(live.versionMismatch, [.live])
        XCTAssertLessThan(live.score, remaster.score - 0.15)

        let both = matcher.evaluate(q("Test Song (Live)"), TrackCandidate(id: "3", title: "Test Song (Live)", artists: ["Test Artist"], duration: 200))
        XCTAssertTrue(both.versionMismatch.isEmpty)                // оба live — совпадают
        XCTAssertTrue(both.accepted)
    }

    func testDurationToleranceAndHardLimit() {
        let c = { (d: TimeInterval) in TrackCandidate(id: "1", title: "Test Song", artists: ["Test Artist"], album: "Test Album", duration: d) }
        XCTAssertTrue(matcher.evaluate(q(), c(201.5)).accepted)
        let off4 = matcher.evaluate(q(), c(204))
        XCTAssertLessThan(off4.duration!, 0.9)
        let far = matcher.evaluate(q(), c(215))
        XCTAssertFalse(far.accepted)
        XCTAssertNotNil(far.rejectReason)
    }

    func testRejectsDifferentSong() {
        let e = matcher.evaluate(q(), TrackCandidate(id: "1", title: "Completely Different", artists: ["Test Artist"], duration: 200))
        XCTAssertFalse(e.accepted)
        let e2 = matcher.evaluate(q(), TrackCandidate(id: "1", title: "Test Song", artists: ["Another Person"], duration: 200))
        XCTAssertFalse(e2.accepted)
    }

    func testMissingDurationRaisesBar() {
        let weakish = TrackCandidate(id: "1", title: "Test Song Reprise Extended", artists: ["Test Artist"])
        XCTAssertFalse(matcher.evaluate(q(), weakish).accepted)
        let exact = TrackCandidate(id: "1", title: "Test Song", artists: ["Test Artist"], album: "Test Album")
        XCTAssertTrue(matcher.evaluate(q(), exact).accepted)
    }

    func testISRCOverrides() {
        let e = matcher.evaluate(q(isrc: "us-abc-12-34567"), TrackCandidate(id: "1", title: "Whatever", artists: ["X"], duration: 10, isrc: "USABC1234567"))
        XCTAssertTrue(e.accepted)
        XCTAssertTrue(e.isrcMatch)
        XCTAssertEqual(e.score, 1)
    }

    func testFeaturedArtistsInTitleCount() {
        let query = q("Song (feat. Guest)", "Main Artist")
        let cand = TrackCandidate(id: "1", title: "Song", artists: ["Main Artist", "Guest"], duration: 200)
        let e = matcher.evaluate(query, cand)
        XCTAssertTrue(e.accepted)
        XCTAssertGreaterThan(e.artist, 0.95)
    }

    func testRankingPicksRightVersion() {
        let cands = [
            TrackCandidate(id: "live", title: "Test Song (Live)", artists: ["Test Artist"], duration: 240),
            TrackCandidate(id: "studio", title: "Test Song", artists: ["Test Artist"], duration: 200.5),
            TrackCandidate(id: "remix", title: "Test Song (Remix)", artists: ["Test Artist"], duration: 200.5),
        ]
        let r = matcher.rank(q(), cands)
        XCTAssertEqual(r.first?.candidate.id, "studio")
        XCTAssertTrue(r.first!.evaluation.accepted)
        XCTAssertFalse(r.last!.evaluation.accepted)
    }

    func testCyrillicAndYo() {
        let query = TrackQuery(title: "Всё хорошо", artist: "Группа", duration: 180)
        let e = matcher.evaluate(query, TrackCandidate(id: "1", title: "Все хорошо", artists: ["Группа"], duration: 180))
        XCTAssertTrue(e.accepted)
    }

    func testCatalogIdZeroMeansMissing() {
        XCTAssertNil(TrackQuery(catalogId: "0", title: "a", artist: "b").catalogId)
        XCTAssertNil(TrackQuery(catalogId: "", title: "a", artist: "b").catalogId)
        XCTAssertEqual(TrackQuery(catalogId: "123", title: "a", artist: "b").catalogId, "123")
    }

    func testCacheKey() {
        XCTAssertEqual(TrackQuery(catalogId: "123", title: "a", artist: "b").cacheKey, "am-123")
        let k1 = TrackQuery(title: "Song (Remastered)", artist: "Artist", duration: 200.2).cacheKey
        let k2 = TrackQuery(title: "song - remastered 2011", artist: "ARTIST", duration: 199.8).cacheKey
        XCTAssertEqual(k1, k2)                                      // нормализованные метаданные
        let k3 = TrackQuery(title: "Song (Live)", artist: "Artist", duration: 200).cacheKey
        XCTAssertNotEqual(k1, k3)                                   // версия — часть ключа
    }
}
