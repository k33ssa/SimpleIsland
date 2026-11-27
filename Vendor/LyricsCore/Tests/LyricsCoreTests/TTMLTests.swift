import XCTest
@testable import LyricsCore

final class TTMLTests: XCTestCase {
    func testWordTimedDocument() throws {
        let l = try TTMLParser.parse(Fixtures.ttmlWord, source: Fixtures.src)
        XCTAssertEqual(l.syncType, .word)
        XCTAssertEqual(l.language, "en")
        XCTAssertEqual(l.lines.count, 3)
        XCTAssertEqual(l.duration!, 216.12, accuracy: 0.001)
        XCTAssertEqual(l.leadingSilence!, 0.12, accuracy: 0.001)
        XCTAssertEqual(l.songwriters, ["Alice A", "Bob B"])

        // агенты
        XCTAssertEqual(l.agents.map(\.id), ["v1", "v2", "v1000"])
        XCTAssertEqual(l.agents[1].name, "Second Singer")
        XCTAssertEqual(l.agents[2].kind, .group)

        // строка 1: слоги Hel+lo — одно слово, пробел — граница
        let l1 = l.lines[0]
        XCTAssertEqual(l1.key, "L1")
        XCTAssertEqual(l1.agentID, "v1")
        XCTAssertEqual(l1.songPart, "Verse")
        XCTAssertEqual(l1.words.map(\.text), ["Hel", "lo", "world"])
        XCTAssertEqual(l1.words.map(\.isContinuation), [false, true, false])
        XCTAssertEqual(l1.text, "Hello world")
        XCTAssertEqual(l1.begin!, 1.152, accuracy: 0.0001)
        XCTAssertEqual(l1.words[2].end, 3.0, accuracy: 0.0001)

        // строка 2: фоновый вокал, скобки сняты
        let l2 = l.lines[1]
        XCTAssertEqual(l2.agentID, "v2")
        XCTAssertEqual(l2.text, "Soft night")
        XCTAssertEqual(l2.background.map(\.text), ["echo", "echo"])
        XCTAssertEqual(l2.backgroundText, "echo echo")
        XCTAssertEqual(l2.background[0].begin, 6.2, accuracy: 0.0001)
        XCTAssertTrue(l2.hasBackground)

        // строка 3: агент и songPart от div, время HH:MM:SS
        let l3 = l.lines[2]
        XCTAssertEqual(l3.agentID, "v1000")
        XCTAssertEqual(l3.songPart, "Chorus")
        XCTAssertEqual(l3.begin!, 605.25, accuracy: 0.0001)
        XCTAssertEqual(l3.end!, 3601.5, accuracy: 0.0001)
        XCTAssertEqual(l3.text, "Singit")

        // переводы и транслитерации по itunes:key
        XCTAssertEqual(l1.translation?.text, "Привет, мир")
        XCTAssertEqual(l1.translation?.language, "ru")
        XCTAssertEqual(l1.translation?.kind, .subtitle)
        XCTAssertEqual(l2.translation?.text, "Тихий")
        XCTAssertEqual(l2.translation?.backgroundText, "эхо")
        XCTAssertEqual(l1.transliteration?.text, "haro wārudo")
        XCTAssertEqual(l1.transliteration?.language, "ja-Latn")
        XCTAssertTrue(l.hasTranslations)
        XCTAssertNil(l3.translation)
    }

    func testLineTimedDocument() throws {
        let l = try TTMLParser.parse(Fixtures.ttmlLine, source: Fixtures.src)
        XCTAssertEqual(l.syncType, .line)
        XCTAssertEqual(l.language, "ru")
        XCTAssertEqual(l.lines.count, 2)
        XCTAssertEqual(l.lines[0].text, "Первая строка")
        XCTAssertTrue(l.lines[0].words.isEmpty)
        XCTAssertEqual(l.lines[0].begin!, 44.46, accuracy: 0.0001)
        XCTAssertEqual(l.lines[1].begin!, 47.5, accuracy: 0.0001)      // суффикс s
        XCTAssertEqual(l.lines[1].end!, 50, accuracy: 0.0001)
        XCTAssertEqual(l.lines[1].text, "Вторая & строка")
        XCTAssertEqual(l.duration!, 198.55, accuracy: 0.0001)
        XCTAssertTrue(l.songwriters.isEmpty)
    }

    func testAMLLStyleDocument() throws {
        let l = try TTMLParser.parse(Fixtures.ttmlAMLL, source: Fixtures.src)
        XCTAssertEqual(l.syncType, .word)    // itunes:timing нет, но есть спаны со временем
        XCTAssertEqual(l.metadata["musicName"], ["Test Song"])
        XCTAssertEqual(l.metadata["isrc"], ["XX-AAA-00-00001"])
        XCTAssertEqual(l.lines[0].songPart, "Intro")   // kebab-вариант
        XCTAssertEqual(l.lines[0].text, "One two")
        XCTAssertEqual(l.lines[0].translation?.text, "раз два")
        XCTAssertEqual(l.lines[0].transliteration?.text, "wan tsū")
        XCTAssertEqual(l.lines[0].transliteration?.language, "ja-Latn")
    }

    func testTimeFormats() {
        XCTAssertEqual(TimeCode.parse("1.541"), 1.541)
        XCTAssertEqual(TimeCode.parse("3:36.120")!, 216.12, accuracy: 1e-9)
        XCTAssertEqual(TimeCode.parse("00:03:18.550")!, 198.55, accuracy: 1e-9)
        XCTAssertEqual(TimeCode.parse("12.5s"), 12.5)
        XCTAssertEqual(TimeCode.parse("250ms"), 0.25)
        XCTAssertNil(TimeCode.parse("abc"))
        XCTAssertNil(TimeCode.parse("1:2:3:4"))
        XCTAssertEqual(TimeCode.format(1.152), "1.152")
        XCTAssertEqual(TimeCode.format(216.12), "3:36.120")
        XCTAssertEqual(TimeCode.format(3601.5), "1:00:01.500")
        XCTAssertEqual(TimeCode.format(0), "0.000")
    }

    func testRejectsNonTTML() {
        XCTAssertThrowsError(try TTMLParser.parse("<html/>", source: Fixtures.src))
        XCTAssertThrowsError(try TTMLParser.parse("not xml", source: Fixtures.src))
    }

    func testUnsyncedBody() throws {
        let doc = """
        <tt xmlns="http://www.w3.org/ns/ttml"><body><div><p>Just text</p><p>More text</p></div></body></tt>
        """
        let l = try TTMLParser.parse(doc, source: Fixtures.src)
        XCTAssertEqual(l.syncType, .none)
        XCTAssertEqual(l.lines.map(\.text), ["Just text", "More text"])
        XCTAssertEqual(l.lines.map(\.key), ["L1", "L2"])
    }

    // MARK: генератор

    func testWriterRoundTripWord() throws {
        let a = try TTMLParser.parse(Fixtures.ttmlWord, source: Fixtures.src)
        let xml = TTMLWriter.write(a)
        let b = try TTMLParser.parse(xml, source: Fixtures.src)
        assertSameContent(a, b)
        // второй круг стабилен
        let xml2 = TTMLWriter.write(b)
        XCTAssertEqual(xml, xml2)
    }

    func testWriterRoundTripLine() throws {
        let a = try TTMLParser.parse(Fixtures.ttmlLine, source: Fixtures.src)
        let b = try TTMLParser.parse(TTMLWriter.write(a), source: Fixtures.src)
        assertSameContent(a, b)
        XCTAssertEqual(b.syncType, .line)
    }

    func testWriterOutputIsAppleShaped() throws {
        let a = try TTMLParser.parse(Fixtures.ttmlWord, source: Fixtures.src)
        let xml = TTMLWriter.write(a)
        XCTAssertTrue(xml.contains("itunes:timing=\"Word\""))
        XCTAssertTrue(xml.contains("xmlns:itunes=\"http://music.apple.com/lyric-ttml-internal\""))
        XCTAssertTrue(xml.contains("itunes:songPart=\"Verse\""))
        XCTAssertTrue(xml.contains("ttm:role=\"x-bg\""))
        XCTAssertTrue(xml.contains("<songwriter>Alice A</songwriter>"))
        XCTAssertNil(xml.firstMatch(of: /(begin|end|dur)="[^"]*s"/), "времена без суффикса s")
        // внутри <p> нет переносов строк и отступов — пробелы значимы
        for p in xml.matches(of: /<p [^>]*>(.*?)<\/p>/) {
            XCTAssertFalse(p.output.1.contains("\n"))
            XCTAssertFalse(p.output.1.contains("  "))
        }
        // слоги одного слова вплотную
        XCTAssertTrue(xml.contains("</span><span begin=\"1.600\""))
    }

    func testWriterEscapesXML() throws {
        let line = LyricLine(key: "L1", begin: 0, end: 1, text: "a < b & \"c\"")
        let l = Lyrics(source: Fixtures.src, language: "en", syncType: .line, lines: [line])
        let xml = TTMLWriter.write(l)
        let back = try TTMLParser.parse(xml, source: Fixtures.src)
        XCTAssertEqual(back.lines[0].text, "a < b & \"c\"")
    }

    private func assertSameContent(_ a: Lyrics, _ b: Lyrics, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.syncType, b.syncType, file: file, line: line)
        XCTAssertEqual(a.language, b.language, file: file, line: line)
        XCTAssertEqual(a.songwriters, b.songwriters, file: file, line: line)
        XCTAssertEqual(a.agents, b.agents, file: file, line: line)
        XCTAssertEqual(a.lines.count, b.lines.count, file: file, line: line)
        for (x, y) in zip(a.lines, b.lines) {
            XCTAssertEqual(x.key, y.key, file: file, line: line)
            XCTAssertEqual(x.text, y.text, file: file, line: line)
            XCTAssertEqual(x.agentID, y.agentID, file: file, line: line)
            XCTAssertEqual(x.songPart, y.songPart, file: file, line: line)
            XCTAssertEqual(x.words.map(\.text), y.words.map(\.text), file: file, line: line)
            XCTAssertEqual(x.words.map(\.isContinuation), y.words.map(\.isContinuation), file: file, line: line)
            XCTAssertEqual(x.background.map(\.text), y.background.map(\.text), file: file, line: line)
            XCTAssertEqual(x.begin ?? -1, y.begin ?? -1, accuracy: 0.0006, file: file, line: line)
            XCTAssertEqual(x.end ?? -1, y.end ?? -1, accuracy: 0.0006, file: file, line: line)
            XCTAssertEqual(x.translations.map(\.text), y.translations.map(\.text), file: file, line: line)
            XCTAssertEqual(x.transliterations.map(\.text), y.transliterations.map(\.text), file: file, line: line)
            XCTAssertEqual(x.translations.map(\.language), y.translations.map(\.language), file: file, line: line)
        }
    }
}
