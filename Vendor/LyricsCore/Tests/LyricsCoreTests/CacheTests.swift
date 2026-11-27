import XCTest
@testable import LyricsCore

final class ClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.lock(); defer { lock.unlock() }; return t }
    func advance(_ s: TimeInterval) { lock.lock(); t = t.addingTimeInterval(s); lock.unlock() }
}

final class CacheTests: XCTestCase {
    func make(clock: ClockBox = ClockBox()) -> (LyricsCache, ClockBox) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lc-\(UUID().uuidString)")
        return (LyricsCache(directory: dir, now: { clock.now }), clock)
    }

    func testRoundTripPreservesEverything() throws {
        let (c, _) = make()
        var l = try TTMLParser.parse(Fixtures.ttmlWord, source: LyricsSource(provider: .appleMusic, trackID: "1", confidence: 1, matchKind: .catalogID))
        l.lines[0].translations.append(LyricAnnotation(kind: .subtitle, language: "ru", text: "x"))
        l.fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)   // Date не переживает JSON без потери 1 ulp
        c.store(key: "k", best: l, alternatives: [fakeLyrics(.lrclib, .line)])
        let hit = c.load(key: "k")
        XCTAssertEqual(hit?.best, l)
        XCTAssertEqual(hit?.alternatives.count, 1)
        XCTAssertNil(c.load(key: "other"))
    }

    func testTTLByQuality() {
        let (c, clock) = make()
        c.store(key: "w", best: fakeLyrics(.amll, .word), alternatives: [])
        c.store(key: "l", best: fakeLyrics(.lrclib, .line), alternatives: [])
        c.store(key: "p", best: fakeLyrics(.lrclib, .none), alternatives: [])
        c.store(key: "n", best: nil, alternatives: [])
        clock.advance(31 * 60)
        XCTAssertNil(c.load(key: "n"))              // негативный — 30 мин
        XCTAssertNotNil(c.load(key: "p"))
        clock.advance(7 * 86400)
        XCTAssertNil(c.load(key: "p"))              // простой — 7 суток
        XCTAssertNotNil(c.load(key: "l"))
        clock.advance(8 * 86400)
        XCTAssertNil(c.load(key: "l"))              // построчный — 14 суток
        XCTAssertNotNil(c.load(key: "w"))
        clock.advance(20 * 86400)
        XCTAssertNil(c.load(key: "w"))              // пословный — 30 суток
    }

    func testPinnedNeverExpiresAndIsNotOverwritten() {
        let (c, clock) = make()
        c.store(key: "k", best: fakeLyrics(.qq, .word, trackID: "manual"), alternatives: [], pinned: true)
        c.store(key: "k", best: fakeLyrics(.lrclib, .line, trackID: "auto"), alternatives: [])
        clock.advance(400 * 86400)
        XCTAssertEqual(c.load(key: "k")?.best?.source.trackID, "manual")
        c.store(key: "k", best: fakeLyrics(.amll, .word, trackID: "manual2"), alternatives: [], pinned: true)
        XCTAssertEqual(c.load(key: "k")?.best?.source.trackID, "manual2")
    }

    func testPurgeAndRemove() {
        let (c, clock) = make()
        c.store(key: "a", best: fakeLyrics(.lrclib, .none), alternatives: [])
        c.store(key: "b", best: fakeLyrics(.lrclib, .word), alternatives: [])
        clock.advance(8 * 86400)
        XCTAssertEqual(c.purgeExpired(), 1)
        c.remove(key: "b")
        XCTAssertNil(c.load(key: "b"))
    }

    func testCorruptFileIsDroppedAndDirectoryExcludedFromBackup() throws {
        let (c, _) = make()
        c.store(key: "a", best: fakeLyrics(.lrclib, .line), alternatives: [])
        let files = try FileManager.default.contentsOfDirectory(at: c.directory, includingPropertiesForKeys: nil)
        try Data("not json".utf8).write(to: files[0])
        XCTAssertNil(c.load(key: "a"))
        let v = try c.directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(v.isExcludedFromBackup, true)
    }

    func testSameKeyDifferentContentNotConfused() {
        let (c, _) = make()
        c.store(key: "k1", best: fakeLyrics(.lrclib, .line, trackID: "1"), alternatives: [])
        c.store(key: "k2", best: fakeLyrics(.lrclib, .line, trackID: "2"), alternatives: [])
        XCTAssertEqual(c.load(key: "k1")?.best?.source.trackID, "1")
        XCTAssertEqual(c.load(key: "k2")?.best?.source.trackID, "2")
    }
}

final class CredentialTests: XCTestCase {
    func testInMemory() async throws {
        let s = InMemoryCredentialStore()
        try await s.set("v", for: .mediaUserToken)
        let v = try await s.value(for: .mediaUserToken)
        XCTAssertEqual(v, "v")
        try await s.set(nil, for: .mediaUserToken)
        let n = try await s.value(for: .mediaUserToken)
        XCTAssertNil(n)
    }

    /// Реальный Keychain (login keychain на macOS). Уникальный service, в конце удаляем.
    func testKeychainRoundTrip() async throws {
        let store = KeychainCredentialStore(service: "app.amnl.lyrics.tests.\(UUID().uuidString)")
        do {
            let empty = try await store.value(for: .mediaUserToken)
            XCTAssertNil(empty)
            try await store.set("first", for: .mediaUserToken)
            try await store.set("second", for: .mediaUserToken)      // обновление
            let v = try await store.value(for: .mediaUserToken)
            XCTAssertEqual(v, "second")
            try await store.set(nil, for: .mediaUserToken)
            let gone = try await store.value(for: .mediaUserToken)
            XCTAssertNil(gone)
        } catch let e as LyricsError {
            try? await store.set(nil, for: .mediaUserToken)
            throw XCTSkip("Keychain недоступен в этом окружении: \(e)")
        }
    }
}
