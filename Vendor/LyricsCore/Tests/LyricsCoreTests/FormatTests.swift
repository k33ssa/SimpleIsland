import XCTest
@testable import LyricsCore

final class LRCTests: XCTestCase {
    func testPlainLRC() {
        let l = LRCParser.parse(Fixtures.lrc, source: Fixtures.src)
        XCTAssertEqual(l.syncType, .line)
        XCTAssertEqual(l.metadata["ti"], ["Test Song"])
        XCTAssertEqual(l.metadata["ar"], ["Test Artist"])
        // offset +500 мс: тексты появляются на 0.5 с раньше
        XCTAssertEqual(l.lines.count, 5)   // First, Repeated×2, пустая пауза, Last
        XCTAssertEqual(l.lines[0].begin!, 0.5, accuracy: 1e-6)
        XCTAssertEqual(l.lines[0].text, "First line")
        XCTAssertEqual(l.lines[0].end!, 5.0, accuracy: 1e-6)
        XCTAssertEqual(l.lines[1].text, "Repeated line")
        XCTAssertEqual(l.lines[1].begin!, 5.0, accuracy: 1e-6)
        XCTAssertEqual(l.lines[2].text, "")                     // пауза
        XCTAssertTrue(l.lines[2].isGap)
        XCTAssertEqual(l.lines[3].begin!, 15.0, accuracy: 1e-6)
        XCTAssertEqual(l.lines[3].text, "Repeated line")
        XCTAssertEqual(l.lines[4].begin!, 19.75, accuracy: 1e-6)
        XCTAssertEqual(l.lines[4].end!, 19.75 + 5, accuracy: 1e-6)   // запасная длина последней строки
    }

    func testLastLineEndsAtTrackDuration() {
        var o = LRCParser.Options(); o.trackDuration = 60
        let l = LRCParser.parse("[00:10.00]a\n[00:20.00]b", source: Fixtures.src, options: o)
        XCTAssertEqual(l.lines.last!.end!, 60)
    }

    func testCentisecondAndMillisecondFractions() {
        XCTAssertEqual(LRCParser.parseStamp("01:02.5")!, 62.5, accuracy: 1e-9)
        XCTAssertEqual(LRCParser.parseStamp("01:02.50")!, 62.5, accuracy: 1e-9)
        XCTAssertEqual(LRCParser.parseStamp("01:02.505")!, 62.505, accuracy: 1e-9)
        XCTAssertEqual(LRCParser.parseStamp("1:02:03.5")!, 3723.5, accuracy: 1e-9)
        XCTAssertNil(LRCParser.parseStamp("ar:Name"))
        XCTAssertNil(LRCParser.parseStamp("00:75.00".replacingOccurrences(of: "00:75.00", with: "x1:00")))
    }

    func testEnhancedLRC() {
        let l = LRCParser.parse(Fixtures.enhancedLRC, source: Fixtures.src)
        XCTAssertEqual(l.syncType, .word)
        let a = l.lines[0]
        XCTAssertEqual(a.words.map(\.text), ["Hel", "lo", "world"])
        XCTAssertEqual(a.words.map(\.isContinuation), [false, true, false])
        XCTAssertEqual(a.words[0].begin, 1.0, accuracy: 1e-6)
        XCTAssertEqual(a.words[0].end, 1.4, accuracy: 1e-6)
        XCTAssertEqual(a.words[2].end, 3.0, accuracy: 1e-6)        // закрывающая метка
        XCTAssertEqual(a.text, "Hello world")
        let b = l.lines[1]
        XCTAssertEqual(b.agentID, "v2")
        XCTAssertEqual(b.text, "Second line")
        XCTAssertEqual(b.background.map(\.text), ["(echo)"])       // скобки Apple-стиля снимаются только в TTML
        // строка без меток слов остаётся построчной
        XCTAssertTrue(l.lines[2].words.isEmpty)
        XCTAssertEqual(l.lines[2].text, "Plain tail")
    }

    func testPlainTextWithoutTimestamps() {
        let l = LRCParser.parse("First\n\n[Chorus]\nSecond", source: Fixtures.src)
        XCTAssertEqual(l.syncType, .none)
        XCTAssertEqual(l.lines.map(\.text), ["First", "[Chorus]", "Second"])
    }

    func testAngleBracketsInTextAreNotTimestamps() {
        let l = LRCParser.parse("[00:01.00]I <3 you", source: Fixtures.src)
        XCTAssertEqual(l.syncType, .line)
        XCTAssertEqual(l.lines[0].text, "I <3 you")
    }
}

final class YRCQRCTests: XCTestCase {
    func testYRC() throws {
        let l = try YRCParser.parse(Fixtures.yrc, source: Fixtures.src)
        XCTAssertEqual(l.syncType, .word)
        XCTAssertEqual(l.songwriters, ["Writer One", "Writer Two"])   // кредиты вырезаны и учтены
        XCTAssertEqual(l.lines.count, 2)
        let a = l.lines[0]
        XCTAssertEqual(a.begin!, 1.0, accuracy: 1e-9)
        XCTAssertEqual(a.end!, 4.0, accuracy: 1e-9)
        XCTAssertEqual(a.text, "Hello world!")
        XCTAssertEqual(a.words.map(\.text), ["Hello", "wor", "ld!"])
        XCTAssertEqual(a.words.map(\.isContinuation), [false, false, true])
        XCTAssertEqual(a.words[2].end, 2.6, accuracy: 1e-9)           // end = max(слог, знак)
        XCTAssertEqual(a.background.map(\.text), ["oh", "yeah"])      // группа в скобках
        XCTAssertEqual(a.background[0].begin, 2.7, accuracy: 1e-9)
        let b = l.lines[1]
        XCTAssertEqual(b.text, "Next line, end")                        // запятая приклеена, нулевая длительность не ломает
        XCTAssertEqual(b.words[1].end, 6.0, accuracy: 1e-9)
    }

    func testYRCOnlyCreditsFails() {
        XCTAssertThrowsError(try YRCParser.parse("[0,45](0,45,0) 作词 : X", source: Fixtures.src))
        XCTAssertThrowsError(try YRCParser.parse("garbage", source: Fixtures.src))
    }

    func testQRCDecryptionMatchesIndependentImplementation() throws {
        let text = try QRCDecryptor.decrypt(hex: Fixtures.qrcEncryptedHex)
        XCTAssertTrue(text.contains("<QrcInfos>"))
        XCTAssertTrue(text.contains("Say \"hi\""))
    }

    func testQRCEncryptedEndToEnd() throws {
        let text = try QRCDecryptor.decrypt(hex: Fixtures.qrcEncryptedHex)
        let l = try QRCParser.parse(text, source: Fixtures.src)
        XCTAssertEqual(l.syncType, .word)
        XCTAssertEqual(l.songwriters, ["Alice"])
        XCTAssertEqual(l.metadata["ti"], ["Test Song"])
        XCTAssertEqual(l.lines.count, 2)                      // заголовок и кредит вырезаны
        let a = l.lines[0]
        XCTAssertEqual(a.text, "Hello world!")
        XCTAssertEqual(a.words.map(\.text), ["Hello", "wor", "ld!"])
        XCTAssertEqual(a.words.map(\.isContinuation), [false, false, true])
        XCTAssertEqual(a.background.map(\.text), ["hey"])
        XCTAssertEqual(a.begin!, 1.0, accuracy: 1e-9)
        XCTAssertEqual(a.end!, 3.0, accuracy: 1e-9)
        XCTAssertEqual(a.words[1].begin, 1.5, accuracy: 1e-9)
        // текст с неэкранированными кавычками в LyricContent не ломает разбор
        XCTAssertEqual(l.lines[1].text, "Say \"hi\" & bye")
    }

    func testQRCPlainText() throws {
        let l = try QRCParser.parse(Fixtures.qrcPlain, source: Fixtures.src)
        XCTAssertEqual(l.lines.count, 1)
        XCTAssertEqual(l.lines[0].text, "One two")
        XCTAssertEqual(l.lines[0].words.map(\.begin), [2.0, 2.3])
    }

    func testQRCDecryptRejectsGarbage() {
        XCTAssertThrowsError(try QRCDecryptor.decrypt(hex: "ZZ"))
        XCTAssertThrowsError(try QRCDecryptor.decrypt(hex: "0011223344556677"))   // не zlib после расшифровки
        XCTAssertThrowsError(try QRCDecryptor.decrypt(hex: ""))
    }

    func testAnnotationMerge() throws {
        let main = LRCParser.parse("[00:01.00]one\n[00:05.00]two\n[00:09.00]three", source: Fixtures.src)
        let tr = LRCParser.parse("[00:01.02]раз\n[00:05.00]//\n[00:09.30]три", source: Fixtures.src)
        let merged = AnnotationMerge.attach(tr, to: main, kind: .subtitle, language: "ru")
        XCTAssertEqual(merged.lines[0].translation?.text, "раз")
        XCTAssertEqual(merged.lines[0].translation?.language, "ru")
        XCTAssertNil(merged.lines[1].translation)               // «//» — заглушка
        XCTAssertEqual(merged.lines[2].translation?.text, "три")
    }
}
