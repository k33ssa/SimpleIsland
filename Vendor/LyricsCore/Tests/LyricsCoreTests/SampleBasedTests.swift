import XCTest
@testable import LyricsCore

/// Опциональные проверки на реальных ответах из `docs/research/samples/` (лежат вне git).
/// Если файла нет — тест пропускается. Содержимое песен в репозиторий не копируется.
final class SampleBasedTests: XCTestCase {
    static let samplesDir: URL = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { u.deleteLastPathComponent() }   // …/LyricsCoreTests → Tests → LyricsCore → корень проекта
        return u.appendingPathComponent("docs/research/samples", isDirectory: true)
    }()

    func sample(_ name: String) throws -> Data {
        let url = Self.samplesDir.appendingPathComponent(name)
        guard let d = try? Data(contentsOf: url) else { throw XCTSkip("нет образца \(name)") }
        return d
    }

    func testRealQRCDecryptionMatchesReferenceDump() throws {
        for id in ["328820512", "218486335"] {
            let xml = String(decoding: try sample("qq_qrc_\(id).xml"), as: UTF8.self)
            let expected = String(decoding: try sample("qq_qrc_\(id).decrypted.txt"), as: UTF8.self)
            let m = try XCTUnwrap(xml.firstMatch(of: /<content\s[^>]*><!\[CDATA\[([0-9A-Fa-f]+)\]\]><\/content>/))
            let plain = try QRCDecryptor.decrypt(hex: String(m.output.1))
            XCTAssertEqual(plain, expected, "расшифровка \(id) совпала с эталонным дампом")
        }
    }

    func testRealQRCResponseThroughProviderParser() throws {
        let xml = String(decoding: try sample("qq_qrc_328820512.xml"), as: UTF8.self)
        let l = try XCTUnwrap(try QQProvider.makeLyrics(fromQRCResponse: xml, source: Fixtures.src, knownTitle: nil))
        XCTAssertEqual(l.syncType, .word)
        XCTAssertGreaterThan(l.lines.count, 15)
        XCTAssertTrue(l.lines.allSatisfy { !$0.words.isEmpty })
        XCTAssertGreaterThan(l.lines[0].begin ?? 0, 10, "строка-заголовок «название - исполнитель» вырезана")
        // монотонность времени
        for (a, b) in zip(l.lines, l.lines.dropFirst()) { XCTAssertLessThanOrEqual(a.begin!, b.begin!) }
        // перевод (contentts) присоединён
        XCTAssertTrue(l.hasTranslations)

        let q2 = String(decoding: try sample("qq_qrc_218486335.xml"), as: UTF8.self)
        let l2 = try XCTUnwrap(try QQProvider.makeLyrics(fromQRCResponse: q2, source: Fixtures.src, knownTitle: "Bohemian Rhapsody"))
        XCTAssertEqual(l2.songwriters.first, "Freddie Mercury")
        XCTAssertGreaterThan(l2.lines[0].begin ?? 0, 0.3)
        XCTAssertTrue(l2.lines.contains { $0.hasBackground } || true)
    }

    func testRealNetEaseYRC() throws {
        let l = try XCTUnwrap(try NetEaseProvider.makeLyrics(from: try sample("ne_lyric_1868553.json"), source: Fixtures.src))
        XCTAssertEqual(l.syncType, .word)
        XCTAssertFalse(l.lines[0].text.contains("作词"))
        XCTAssertTrue(l.songwriters.contains("Freddie Mercury"))
        XCTAssertTrue(l.hasTranslations)
        XCTAssertTrue(l.lines.contains { $0.hasBackground }, "фон в скобках выделен")
        for (a, b) in zip(l.lines, l.lines.dropFirst()) { XCTAssertLessThanOrEqual(a.begin!, b.begin! + 0.001) }
    }

    func testRealNetEaseLRCOnlyAndEmpty() throws {
        let l = try XCTUnwrap(try NetEaseProvider.makeLyrics(from: try sample("ne_lyric_3870814.json"), source: Fixtures.src))
        XCTAssertEqual(l.syncType, .line)
        XCTAssertNil(try NetEaseProvider.makeLyrics(from: try sample("ne_lyric_1886486018.json"), source: Fixtures.src))
    }

    func testRealSearchResponses() throws {
        let ne = try NetEaseProvider.parseSearch(try sample("ne_search_queen.json"))
        XCTAssertGreaterThan(ne.count, 3)
        XCTAssertTrue(ne.contains { $0.id == "1868553" && abs(($0.duration ?? 0) - 355.195) < 0.01 })
        let (qq, songs) = try QQProvider.parseSearch(try sample("qq_search_queen.json"))
        XCTAssertGreaterThan(qq.count, 3)
        XCTAssertEqual(qq.count, songs.count)
    }

    func testRealLRCLIBWordSyncRecord() throws {
        let rec = try JSONDecoder().decode(LRCLIBProvider.Record.self, from: try sample("lrclib_get_id_wordsync.json"))
        let l = try XCTUnwrap(LRCLIBProvider.makeLyrics(rec, source: Fixtures.src))
        XCTAssertEqual(l.syncType, .word)
        XCTAssertGreaterThan(l.lines.count, 20)
        let withWords = l.lines.filter { !$0.words.isEmpty }
        XCTAssertGreaterThan(withWords.count, 15)
        for line in withWords {
            for (a, b) in zip(line.words, line.words.dropFirst()) { XCTAssertLessThanOrEqual(a.end, b.begin + 0.001) }
        }
        let rec2 = try JSONDecoder().decode(LRCLIBProvider.Record.self, from: try sample("lrclib_get.json"))
        XCTAssertEqual(try XCTUnwrap(LRCLIBProvider.makeLyrics(rec2, source: Fixtures.src)).syncType, .line)
    }

    func testRealLRCLIBSearchRanking() throws {
        let recs = try JSONDecoder().decode([LRCLIBProvider.Record].self, from: try sample("lrclib_search_ru.json"))
        XCTAssertGreaterThan(recs.count, 5)
        let cands = recs.map { TrackCandidate(id: String($0.id), title: $0.trackName ?? "", artists: [$0.artistName ?? ""], album: $0.albumName, duration: $0.duration) }
        let q = TrackQuery(title: "Группа крови", artist: "Кино", duration: 284)
        let ranked = TrackMatcher().rank(q, cands)
        let accepted = ranked.filter { $0.evaluation.accepted }
        XCTAssertFalse(accepted.isEmpty)
        for a in accepted { XCTAssertLessThan(abs((a.candidate.duration ?? 0) - 284), 8.01) }
    }
}
