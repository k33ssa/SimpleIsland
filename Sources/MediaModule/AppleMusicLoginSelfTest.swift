import Foundation
import IslandCore
import LyricsCore

/// Самотест подключения Apple Music (часть `--selftest-media`, без сети и без настоящего входа): разбор cookie окна
/// входа, проверка токена на заглушке amp-api (200 / 401→новый developer token→401 / 500 / нет сети), сохранение и
/// удаление, сброс отрицательного кеша и памяти (трек спрашивается заново), самообновление токена системной учётки.
/// Настоящий файл секретов и Keychain не трогаются (временный `SecretFile`, хранилище в памяти).
enum AppleMusicLoginSelfTest {
    typealias Check = LyricsSelfTest.Check
    static func await_<T: Sendable>(_ op: @escaping @Sendable () async -> T) -> T { LyricsCoreSelfTest.await_(op) }

    static func run(_ check: Check) {
        cookies(check)
        verify(check)
        storage(check)
        refresh(check)
    }

    // MARK: cookie

    static func cookie(_ name: String, _ value: String, domain: String, expires: Date? = Date().addingTimeInterval(86400)) -> HTTPCookie {
        var p: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: "/"]
        if let expires { p[.expires] = expires }
        return HTTPCookie(properties: p)!
    }

    static func cookies(_ check: Check) {
        let far = Date().addingTimeInterval(180 * 86400)
        let set = [cookie("media-user-token", "EVIL", domain: "music.apple.com.evil.example"),
                   cookie("media-user-token", "ROOT", domain: ".apple.com"),
                   cookie("itspod", "x", domain: ".music.apple.com"),
                   cookie("media-user-token", "OLD", domain: ".music.apple.com", expires: Date().addingTimeInterval(-60)),
                   cookie("media-user-token", "  ", domain: ".music.apple.com"),
                   cookie("media-user-token", "GOOD", domain: ".music.apple.com", expires: far),
                   cookie("media-user-token", "SHORT", domain: "music.apple.com")]
        let t = AppleMusicAuth.token(from: set)
        check(t == "GOOD", "Apple вход: cookie media-user-token — только music.apple.com, не просрочен, не пуст, самый долгий",
              t == nil ? "nil" : (t == "GOOD" ? "ok" : "чужой"))
        check(AppleMusicAuth.token(from: Array(set.prefix(5))) == nil, "Apple вход: без входа (нет годной cookie) — nil", "")
    }

    // MARK: проверка токена

    final class Stub: HTTPClient, @unchecked Sendable {
        var amp: [Int]          // ответы /v1/me/storefront по очереди
        var offline = false
        var calls: [URLRequest] = []
        let lock = NSLock()
        init(amp: [Int]) { self.amp = amp }
        func send(_ r: URLRequest) async throws -> HTTPResponse {
            let s: Int = lock.withLock {
                calls.append(r)
                return amp.isEmpty ? 500 : amp.first!
            }
            if offline { throw LyricsError.network("самотест") }
            let u = r.url!.absoluteString
            if u.contains("/v1/me/storefront") {
                lock.withLock { if !amp.isEmpty { amp.removeFirst() } }
                return HTTPResponse(data: Data(#"{"data":[{"id":"tr","type":"storefronts"}]}"#.utf8), status: s)
            }
            if u.hasSuffix(".js") { return HTTPResponse(data: Data("var t=\"\(AppleMusicLoginSelfTest.jwt("B"))\";".utf8), status: 200) }
            if u.contains("music.apple.com") {
                return HTTPResponse(data: Data(#"<html><script type="module" src="/assets/index-x.js"></script></html>"#.utf8), status: 200)
            }
            return HTTPResponse(data: Data(), status: 404)
        }
    }

    /// Поддельный JWT веб-плеера (iss AMPWebPlay, действует сутки) — подпись не настоящая, сеть его не видит.
    static func jwt(_ tag: String) -> String {
        func b64(_ s: String) -> String {
            Data(s.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let exp = Int(Date().timeIntervalSince1970) + 86400
        return b64(#"{"alg":"ES256","kid":"\#(tag)"}"#) + "." + b64(#"{"iss":"AMPWebPlay","exp":\#(exp),"tag":"\#(tag)"}"#) + ".c2lnbmF0dXJlLXNlbGZ0ZXN0"
    }

    static func payload(_ jwt: String) -> [String: Any]? {
        let p = jwt.split(separator: "."); guard p.count == 3 else { return nil }
        var b = String(p[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        return Data(base64Encoded: b).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    }

    static func devJSON(_ tag: String) -> String {
        #"{"token":"\#(jwt(tag))","exp":\#(Date().timeIntervalSince1970 + 86400)}"#
    }

    static func verify(_ check: Check) {
        func run(_ stub: Stub) -> AppleMusicStatus {
            let store = InMemoryCredentialStore([.appleDeveloperToken: devJSON("A")])
            let dev = AppleDeveloperTokenProvider(http: stub, store: store)
            return await_ { await AppleMusicAuth.verify(token: "MUT-selftest", http: stub, developerTokens: dev) }
        }
        let ok = Stub(amp: [200])
        let s1 = run(ok)
        let r = ok.calls.first
        check(s1 == .connected(storefront: "tr") && r?.value(forHTTPHeaderField: "media-user-token") == "MUT-selftest"
              && r?.value(forHTTPHeaderField: "Authorization") == "Bearer \(jwt("A"))"
              && r?.value(forHTTPHeaderField: "Origin") == "https://music.apple.com" && ok.calls.count == 1,
              "Apple вход: проверка — 200 → «подключена · TR», заголовки как у AppleMusicProvider", "\(s1) \(ok.calls.count)")
        let deny = Stub(amp: [401, 403])
        let s2 = run(deny)
        let amps = deny.calls.filter { $0.url!.path.contains("/v1/me/storefront") }
        check(s2 == .needsSubscription && amps.count == 2
              && amps.last?.value(forHTTPHeaderField: "Authorization") == "Bearer \(jwt("B"))",
              "Apple вход: 401 → новый developer token → 403 → «нужна подписка / войдите заново»", "\(s2) \(amps.count)")
        let s3 = run(Stub(amp: [500]))
        check({ if case .unverified = s3 { return true }; return false }(), "Apple вход: 500 → «проверить не удалось», токен остаётся", "\(s3)")
        let off = Stub(amp: []); off.offline = true
        let s4 = run(off)
        check(s4 == .unverified("нет сети"), "Apple вход: нет сети → «проверить не удалось»", "\(s4)")
    }

    // MARK: сохранение, удаление, сброс кеша

    /// «Apple» без сети: доступен только с токеном (как `AppleMusicProvider.isAvailable`), отдаёт пословный текст.
    final class Counting: LyricsProvider, @unchecked Sendable {
        let id: LyricsProviderID = .appleMusic
        let creds: CredentialStore
        var calls = 0
        init(creds: CredentialStore) { self.creds = creds }
        func isAvailable() async -> Bool { ((try? await creds.value(for: .mediaUserToken)) ?? nil) != nil }
        func lyrics(for query: TrackQuery) async throws -> [LyricsCore.Lyrics] {
            calls += 1
            let src = LyricsSource(provider: .appleMusic, trackID: "1", title: query.title, artist: query.artist,
                                   duration: query.duration, confidence: 1, matchKind: .catalogID, matchQuality: .exact)
            let w = [LyricsCore.LyricWord(text: "раз", begin: 1, end: 1.5), LyricsCore.LyricWord(text: "два", begin: 1.5, end: 2)]
            return [LyricsCore.Lyrics(source: src, syncType: .word, lines: [LyricsCore.LyricLine(key: "L1", begin: 1, end: 2, text: "раз два", words: w)])]
        }
    }

    static func storage(_ check: Check) {
        let fm = FileManager.default
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("simpleisland-amlogin-\(getpid())")
        defer { try? fm.removeItem(at: tmp) }
        let secrets = SecretFile(url: tmp.appendingPathComponent("secrets.json"), migrateFromKeychain: false)
        let base = InMemoryCredentialStore()
        let creds = AppleMusicCredentialStore(base: base, meta: secrets, minter: { _, _ in "never" })
        let counting = Counting(creds: creds)
        let svc = LyricsService(cacheDir: tmp.appendingPathComponent("cache"), credentials: creds, providers: [counting])
        let q = LyricsService.Query(artist: "Синтетика", title: "Тёплый ветер", album: "", duration: 200.4)

        // «Не найдено» запомнено (память + диск), позитивная запись другого трека — на диске.
        // Без токена Apple пропущен → «не найдено» запомнено (память + диск); позитивная запись другого трека — на диске.
        let r0 = await_ { await svc.lookup(q, sources: [.apple]) }
        _ = await_ { await svc.lookup(q, sources: [.apple]) }
        svc.cache.store(key: "positive-selftest", best: LyricsCoreSelfTest.mockLyrics(.qq, word: true), alternatives: [])
        let before = counting.calls
        let files0 = LyricsService.files(svc.cache.directory).count

        let ok = await_ { await svc.connectApple(token: "  \"MUT-login\"\n") }
        let saved = await_ { try? await base.value(for: .mediaUserToken) }
        let has = await_ { await svc.hasAppleToken() }
        let files1 = LyricsService.files(svc.cache.directory).count
        let positive = svc.cache.load(key: "positive-selftest") != nil
        let r1 = await_ { await svc.lookup(q, sources: [.apple]) }
        check(ok && saved == "MUT-login" && has, "Apple вход: токен из cookie сохранён тем же путём (обрезка кавычек)", "\(ok) \(has)")
        check(r0.lyrics == nil && before == 0 && files0 == 2 && files1 == 1 && positive && counting.calls == 1
              && r1.provider == .apple && r1.lyrics?.wordSynced == true,
              "Apple вход: сброс «не найдено» (диск и память) — трек спрошен заново, найденное не тронуто",
              "до \(before), файлов \(files0)→\(files1), спрошен \(counting.calls), после: \(r1.provider?.rawValue ?? "нет") \(r1.outcomes)")

        // Выход: токен, developer token и страна — вон.
        _ = await_ { try? await base.set(devJSON("A"), for: .appleDeveloperToken) }
        _ = await_ { try? await base.set("tr", for: .appleStorefront) }
        _ = await_ { await svc.setAppleToken(nil) }
        let left = await_ { () -> [String?] in
            [try? await base.value(for: .mediaUserToken), try? await base.value(for: .appleDeveloperToken),
             try? await base.value(for: .appleStorefront)].map { $0 ?? nil }
        }
        let hasAfter = await_ { await svc.hasAppleToken() }
        check(!hasAfter && left.allSatisfy { $0 == nil }, "Apple вход: «Выйти» удаляет токен, developer token и страну", "\(left.map { $0 == nil })")

        // Файл секретов — права 600.
        secrets.set("x", service: "selftest", account: "a")
        let perm = (try? fm.attributesOfItem(atPath: tmp.appendingPathComponent("secrets.json").path)[.posixPermissions] as? Int) ?? 0
        check(perm == 0o600, "Apple вход: файл секретов — права 600", String(perm, radix: 8))
    }

    // MARK: системная учётка: самообновление

    final class Clock: @unchecked Sendable { var t = Date() }

    static func refresh(_ check: Check) {
        let fm = FileManager.default
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("simpleisland-amsys-\(getpid())")
        defer { try? fm.removeItem(at: tmp) }
        let secrets = SecretFile(url: tmp.appendingPathComponent("secrets.json"), migrateFromKeychain: false)
        let base = InMemoryCredentialStore([.mediaUserToken: "SYS-A", .appleDeveloperToken: devJSON("A")])
        let clock = Clock()
        final class Log: @unchecked Sendable { var mints: [(String, Bool)] = [] }
        let log = Log()
        let store = AppleMusicCredentialStore(base: base, meta: secrets, minter: { dev, ignore in
            let tag = (payload(dev)?["tag"] as? String) ?? "?"
            log.mints.append((tag, ignore)); return "SYS-\(tag)-\(log.mints.count)"
        }, now: { clock.t })
        let r = await_ { () -> [String?] in
            await store.markSystem(developerToken: jwt("A"))
            let a = try? await store.value(for: .mediaUserToken)                       // свежий — без выпуска
            try? await base.set(devJSON("B"), for: .appleDeveloperToken)               // LyricsCore сменил developer token
            let b = try? await store.value(for: .mediaUserToken)                       // → новый токен
            let b2 = try? await store.value(for: .mediaUserToken)                      // повтор — без выпуска
            clock.t = clock.t.addingTimeInterval(8 * 86400)
            let c = try? await store.value(for: .mediaUserToken)                       // старше 7 дней → новый мимо кеша
            try? await store.set("MANUAL", for: .mediaUserToken)                       // вставили руками — не системный
            try? await base.set(devJSON("C"), for: .appleDeveloperToken)
            let d = try? await store.value(for: .mediaUserToken)
            return [a, b, b2, c, d].map { $0 ?? nil }
        }
        let tags = log.mints.map { "\($0.0)\($0.1 ? "!" : "")" }
        check(r == ["SYS-A", "SYS-B-1", "SYS-B-1", "SYS-B-2", "MANUAL"] && tags == ["B", "B!"],
              "Apple системный токен: перевыпуск при смене developer token и через 7 дней, ручной не трогается",
              "\(r.map { $0 ?? "nil" }) \(tags)")
    }
}
