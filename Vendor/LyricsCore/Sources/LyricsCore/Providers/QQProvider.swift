import Foundation

/// QQ Music: поиск `client_search_cp`, пословный QRC (`lyric_download.fcg`, шифрованный), запасной LRC (`fcg_query_lyric_new`).
public struct QQProvider: LyricsProvider {
    public let id: LyricsProviderID = .qq

    let http: HTTPClient
    let searchHost: String
    let matcher: TrackMatcher
    let maxCandidates: Int

    public init(http: HTTPClient, host: String = "https://c.y.qq.com", maxCandidates: Int = 5,
                matcher: TrackMatcher = TrackMatcher(config: .init(durationTolerance: 3, durationHardLimit: 8))) {
        self.http = http
        self.searchHost = host
        self.maxCandidates = maxCandidates
        self.matcher = matcher
    }

    struct Song: Sendable { var id: String; var mid: String }

    private var headers: [String: String] {
        ["User-Agent": UserAgent.browser, "Referer": "https://y.qq.com/", "Accept": "*/*"]
    }

    public func lyrics(for query: TrackQuery) async throws -> [Lyrics] {
        try await response(for: query).lyrics
    }

    public func response(for query: TrackQuery) async throws -> ProviderResponse {
        let parsed = TextNormalizer.parseTitle(query.title)
        let primary = TextNormalizer.splitArtistsRaw(query.artist).first ?? query.artist
        var (cands, songs) = try await findSongs("\(parsed.display) \(primary)")
        if cands.isEmpty { (cands, songs) = try await findSongs(parsed.display) }
        let triage = matcher.triage(query, cands)
        let ranked = triage.accepted

        var hints: TrackHints?
        if let top = ranked.first, top.evaluation.score >= 0.85, let song = songs[top.candidate.id] { hints = TrackHints(qqSongMid: song.mid) }
        var results: [Lyrics] = []
        var errors = CandidateErrors()
        for (cand, ev) in ranked.prefix(maxCandidates) {
            try Task.checkCancellation()
            guard let song = songs[cand.id] else { continue }
            let src = LyricsSource(provider: .qq, trackID: song.mid, title: cand.title, artist: cand.artists.first,
                                   duration: cand.duration, confidence: ev.score, matchKind: .metadata)
            if var l = try await errors.attempt({ try await fetch(song: song, source: src, knownTitle: query.title) }) {
                l = SyllableSupport.stripHeaderLine(l, title: query.title, artist: query.artist)
                // У запасного поиска (smartbox) длительности нет — сверяем по концу текста.
                if cand.duration == nil, let qd = query.duration, let last = l.lines.compactMap({ $0.end }).max(), last > qd + 15 {
                    Log.net.info("qq: \(song.mid, privacy: .public) отброшен — текст длиннее трека")
                    continue
                }
                results.append(l)
                if l.syncType == .word { break }
            }
        }
        if results.isEmpty {
            for (cand, ev, reason) in triage.nearMisses.prefix(LRCLIBProvider.maxNearMisses) {
                try Task.checkCancellation()
                guard let song = songs[cand.id] else { continue }
                let src = LyricsSource(provider: .qq, trackID: song.mid, title: cand.title, artist: cand.artists.first,
                                       duration: cand.duration, confidence: ev.score, matchKind: .metadata,
                                       matchQuality: .nearMiss(reason))
                if var l = try await errors.attempt({ try await fetch(song: song, source: src, knownTitle: query.title) }) {
                    l = SyllableSupport.stripHeaderLine(l, title: query.title, artist: query.artist)
                    results.append(l)
                }
            }
        }
        try errors.throwIfNothing(!results.isEmpty)
        results.sort { a, b in a.syncType != b.syncType ? a.syncType > b.syncType : a.source.confidence > b.source.confidence }
        var note: String?
        if !results.contains(where: { !$0.source.matchQuality.isNearMiss }) {
            note = triage.summary
            if !triage.accepted.isEmpty { note! += ", у принятых нет текста или он длиннее трека" }
        }
        return ProviderResponse(lyrics: results, note: note, hints: hints)
    }

    // MARK: - поиск

    /// Цепочка поиска: `client_search_cp` (с длительностью) → `search_for_qq_cp` (старый формат, тоже с длительностью) →
    /// `smartbox_new` (без длительности). Пустой ответ и сбой (HTTP 500, не JSON) одинаково ведут к следующему звену.
    /// 14.11.2026 `client_search_cp` отвечал 500 на любые запросы, `smartbox` работал; 15.11 снова 200.
    func findSongs(_ term: String) async throws -> ([TrackCandidate], [String: Song]) {
        let steps: [(String, (String) async throws -> ([TrackCandidate], [String: Song]))] = [
            ("client_search_cp", { try await self.search($0) }),
            ("search_for_qq_cp", { try await self.searchLegacy($0) }),
            ("smartbox_new", { try await self.smartbox($0) }),
        ]
        var lastError: Error?
        for (name, step) in steps {
            do {
                let r = try await step(term)
                if !r.0.isEmpty { return r }
            } catch LyricsError.cancelled {
                throw LyricsError.cancelled
            } catch is CancellationError {
                throw LyricsError.cancelled
            } catch {
                lastError = error
                Log.net.info("qq: \(name, privacy: .public) не сработал, пробую следующий")
            }
        }
        if let e = lastError { throw e }
        return ([], [:])
    }

    func searchLegacy(_ term: String) async throws -> ([TrackCandidate], [String: Song]) {
        guard let url = URLBuilder.url(searchHost + "/soso/fcgi-bin/search_for_qq_cp",
                                       query: [("w", term), ("format", "json"), ("p", "1"), ("n", "10")]) else { return ([], [:]) }
        let resp = try await http.send(.make(url, headers: headers))
        try resp.requireOK()
        return try Self.parseSearch(resp.data)
    }

    func smartbox(_ term: String) async throws -> ([TrackCandidate], [String: Song]) {
        guard let url = URLBuilder.url(searchHost + "/splcloud/fcgi-bin/smartbox_new.fcg", query: [("key", term), ("format", "json")]) else { return ([], [:]) }
        let resp = try await http.send(.make(url, headers: headers))
        try resp.requireOK()
        return try Self.parseSmartbox(resp.data)
    }

    static func parseSmartbox(_ data: Data) throws -> ([TrackCandidate], [String: Song]) {
        guard let obj = try? JSONSerialization.jsonObject(with: stripJSONP(data)) as? [String: Any] else {
            throw LyricsError.badResponse("QQ: smartbox не JSON")
        }
        if let code = BodyCode.int(obj["code"]), code != 0 { throw LyricsError.badResponse("QQ: smartbox code \(code)") }
        guard let list = ((obj["data"] as? [String: Any])?["song"] as? [String: Any])?["itemlist"] as? [[String: Any]] else { return ([], [:]) }
        var cands: [TrackCandidate] = []
        var songs: [String: Song] = [:]
        for s in list {
            let rawID = (s["id"] as? String) ?? (s["id"] as? NSNumber)?.stringValue
            guard let id = rawID, let mid = s["mid"] as? String, let name = s["name"] as? String else { continue }
            let singer = (s["singer"] as? String) ?? ""
            cands.append(TrackCandidate(id: id, title: name, artists: TextNormalizer.splitArtistsRaw(singer).isEmpty ? [singer] : TextNormalizer.splitArtistsRaw(singer)))
            songs[id] = Song(id: id, mid: mid)
        }
        return (cands, songs)
    }

    func search(_ term: String) async throws -> ([TrackCandidate], [String: Song]) {
        guard let url = URLBuilder.url(searchHost + "/soso/fcgi-bin/client_search_cp",
                                       query: [("w", term), ("format", "json"), ("p", "1"), ("n", "10"), ("cr", "1"), ("new_json", "1")]) else { return ([], [:]) }
        let resp = try await http.send(.make(url, headers: headers))
        try resp.requireOK()
        return try Self.parseSearch(resp.data)
    }

    static func parseSearch(_ data: Data) throws -> ([TrackCandidate], [String: Song]) {
        guard let obj = try? JSONSerialization.jsonObject(with: Self.stripJSONP(data)) as? [String: Any] else {
            throw LyricsError.badResponse("QQ: поиск не JSON")
        }
        // QQ: HTTP 200 с `code` ≠ 0 — сбой/антибот (не «пустая выдача»): пусть цепочка перейдёт к следующему звену.
        if let code = BodyCode.int(obj["code"]), code != 0 { throw LyricsError.badResponse("QQ: code \(code)") }
        guard let list = ((obj["data"] as? [String: Any])?["song"] as? [String: Any])?["list"] as? [[String: Any]] else { return ([], [:]) }
        var cands: [TrackCandidate] = []
        var songs: [String: Song] = [:]
        for s in list {
            // Новый формат: id/mid/name/album{name}; старый (`search_for_qq_cp`): songid/songmid/songname/albumname.
            guard let idNum = (s["id"] as? NSNumber) ?? (s["songid"] as? NSNumber),
                  let mid = (s["mid"] as? String) ?? (s["songmid"] as? String),
                  let name = (s["name"] as? String) ?? (s["songname"] as? String) else { continue }
            let singers = (s["singer"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
            let album = ((s["album"] as? [String: Any])?["name"] as? String) ?? (s["albumname"] as? String)
            let interval = (s["interval"] as? NSNumber)?.doubleValue
            let id = idNum.stringValue
            cands.append(TrackCandidate(id: id, title: name, artists: singers, album: album, duration: interval))
            songs[id] = Song(id: id, mid: mid)
        }
        return (cands, songs)
    }

    /// Ответ может прийти как JSONP: `callback({...})`.
    static func stripJSONP(_ data: Data) -> Data {
        guard let first = data.first(where: { !" \n\r\t".utf8.contains($0) }), first != UInt8(ascii: "{") else { return data }
        guard let s = String(data: data, encoding: .utf8), let l = s.firstIndex(of: "("), let r = s.lastIndex(of: ")"), l < r else { return data }
        return Data(s[s.index(after: l)..<r].utf8)
    }

    // MARK: - текст

    func fetch(song: Song, source: LyricsSource, knownTitle: String) async throws -> Lyrics? {
        // 1. QRC
        if let l = try await fetchQRC(song: song, source: source, knownTitle: knownTitle) { return l }
        // 2. LRC
        return try await fetchLRC(song: song, source: source, knownTitle: knownTitle)
    }

    func fetchQRC(song: Song, source: LyricsSource, knownTitle: String) async throws -> Lyrics? {
        guard let url = URL(string: searchHost + "/qqmusic/fcgi-bin/lyric_download.fcg") else { return nil }
        var h = headers
        h["Content-Type"] = "application/x-www-form-urlencoded"
        let body = Data("version=15&miniversion=82&lrctype=4&musicid=\(song.id)".utf8)
        let resp = try await http.send(.make(url, method: "POST", headers: h, body: body))
        try resp.requireOK()
        return try Self.makeLyrics(fromQRCResponse: resp.text, source: source, knownTitle: knownTitle)
    }

    /// Разбор ответа `lyric_download.fcg`: XML в комментарии с `<content>`, `<contentts>`, `<contentroma>` (CDATA, HEX).
    static func makeLyrics(fromQRCResponse text: String, source: LyricsSource, knownTitle: String?) throws -> Lyrics? {
        func section(_ tag: String) -> String? {
            let pattern = "<\(tag)\\s[^>]*><!\\[CDATA\\[(.*?)\\]\\]></\(tag)>"
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
                  let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let r = Range(m.range(at: 1), in: text) else { return nil }
            let v = String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            return v.isEmpty ? nil : v
        }
        func decode(_ s: String) -> String? {
            if looksLikeHex(s) { return try? QRCDecryptor.decrypt(hex: s) }
            return s   // у части старых ответов текст открытый
        }
        guard let mainRaw = section("content"), let main = decode(mainRaw) else { return nil }
        var lyrics: Lyrics
        var src = source
        if main.contains("[") && main.firstMatch(of: /(?m)^\[\d+,\d+\]/) != nil || main.contains("LyricContent") {
            src.format = "qrc"
            var opts = QRCParser.Options(knownTitle: knownTitle)
            opts.knownTitle = knownTitle
            guard let l = try? QRCParser.parse(main, source: src, options: opts) else { return nil }
            lyrics = l
        } else {
            src.format = "lrc"
            let l = LRCParser.parse(decodeEntities(main), source: src)
            guard l.syncType != .none else { return nil }
            lyrics = l
        }
        let aux = LyricsSource(provider: .qq)
        if let tsRaw = section("contentts"), let ts = decode(tsRaw),
           let ann = AnnotationMerge.parseAnnotationText(decodeEntities(ts), source: aux) {
            lyrics = AnnotationMerge.attach(ann, to: lyrics, kind: .subtitle)
        }
        if let rmRaw = section("contentroma"), let rm = decode(rmRaw),
           let ann = AnnotationMerge.parseAnnotationText(decodeEntities(rm), source: aux) {
            lyrics = AnnotationMerge.attach(ann, to: lyrics, kind: .transliteration)
        }
        return lyrics
    }

    static func looksLikeHex(_ s: String) -> Bool {
        s.utf8.count >= 16 && s.utf8.count % 2 == 0 && s.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 70) || ($0 >= 97 && $0 <= 102) }
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        return s.replacingOccurrences(of: "&apos;", with: "'").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
    }

    func fetchLRC(song: Song, source: LyricsSource, knownTitle: String) async throws -> Lyrics? {
        guard let url = URLBuilder.url(searchHost + "/lyric/fcgi-bin/fcg_query_lyric_new.fcg",
                                       query: [("songmid", song.mid), ("g_tk", "5381"), ("format", "json"),
                                               ("inCharset", "utf8"), ("outCharset", "utf-8")]) else { return nil }
        let resp = try await http.send(.make(url, headers: headers))
        try resp.requireOK()
        return Self.makeLyrics(fromLRCResponse: resp.data, source: source)
    }

    static func makeLyrics(fromLRCResponse data: Data, source: LyricsSource) -> Lyrics? {
        guard let obj = try? JSONSerialization.jsonObject(with: stripJSONP(data)) as? [String: Any],
              (obj["retcode"] as? NSNumber)?.intValue ?? 0 == 0,
              let b64 = obj["lyric"] as? String, let d = Data(base64Encoded: b64),
              let text = String(data: d, encoding: .utf8) else { return nil }
        var src = source; src.format = "lrc"
        var lyrics = LRCParser.parse(decodeEntities(text), source: src)
        guard lyrics.syncType != .none else { return nil }
        let r = SyllableSupport.stripLeadingCredits(lyrics.lines)
        lyrics.lines = r.lines
        lyrics.songwriters = r.writers
        for i in lyrics.lines.indices { lyrics.lines[i].key = "L\(i + 1)" }
        if let tb = obj["trans"] as? String, let td = Data(base64Encoded: tb), let tt = String(data: td, encoding: .utf8),
           let ann = AnnotationMerge.parseAnnotationText(decodeEntities(tt), source: LyricsSource(provider: .qq)) {
            lyrics = AnnotationMerge.attach(ann, to: lyrics, kind: .subtitle)
        }
        return lyrics.lines.isEmpty ? nil : lyrics
    }
}
