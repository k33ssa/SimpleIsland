import Foundation

/// Насколько точно текст привязан ко времени.
public enum SyncType: String, Codable, Sendable, Comparable, CaseIterable {
    /// Только текст, без времени.
    case none
    /// Время на уровне строки.
    case line
    /// Время на уровне слов/слогов.
    case word

    private var rank: Int {
        switch self {
        case .none: return 0
        case .line: return 1
        case .word: return 2
        }
    }
    public static func < (lhs: SyncType, rhs: SyncType) -> Bool { lhs.rank < rhs.rank }
}

/// Идентификатор источника текста.
public enum LyricsProviderID: String, Codable, Sendable, CaseIterable {
    case appleMusic
    case amll
    case netease
    case qq
    case kugou
    case lrclib
    case local
}

/// Насколько запись источника соответствует запросу.
public enum MatchQuality: Codable, Sendable, Equatable {
    /// Прошла порог сопоставления (или найдена по id/ISRC) — можно показывать как текст трека.
    case exact
    /// То же название и исполнитель, но не прошла порог (обычно — другая длительность, т. е. другая версия записи).
    /// Никогда не становится `best`, только вариант для ручного выбора. Строка — причина.
    case nearMiss(String)

    public var isNearMiss: Bool { if case .nearMiss = self { return true } else { return false } }
    public var reason: String? { if case .nearMiss(let r) = self { return r } else { return nil } }
}

/// Откуда взят текст.
public struct LyricsSource: Codable, Sendable, Equatable {
    public var provider: LyricsProviderID
    /// Идентификатор трека на стороне источника (adamId, id NetEase, mid QQ, id LRCLIB, id файла AMLL).
    public var trackID: String?
    /// Название/исполнитель найденной записи — чтобы пользователь в списке альтернатив видел, что это за версия.
    public var title: String?
    public var artist: String?
    /// Длительность найденной записи, если источник её сообщает.
    public var duration: TimeInterval?
    /// Уверенность сопоставления трека, 0...1 (1 — совпадение по id/ISRC).
    public var confidence: Double
    /// Как именно сопоставили.
    public var matchKind: MatchKind
    /// Дополнительная пометка (например, «yrc», «qrc», «lyricsfile», «syncedLyrics»).
    public var format: String?
    /// `.exact` или `.nearMiss(причина)`. В старых записях кэша поля нет — читается как `.exact`.
    public var matchQuality: MatchQuality

    public enum MatchKind: String, Codable, Sendable {
        case catalogID
        case isrc
        case externalID
        case metadata
        case unknown
    }

    public init(provider: LyricsProviderID, trackID: String? = nil, title: String? = nil, artist: String? = nil,
                duration: TimeInterval? = nil, confidence: Double = 1, matchKind: MatchKind = .unknown,
                format: String? = nil, matchQuality: MatchQuality = .exact) {
        self.matchQuality = matchQuality
        self.provider = provider
        self.trackID = trackID
        self.title = title
        self.artist = artist
        self.duration = duration
        self.confidence = confidence
        self.matchKind = matchKind
        self.format = format
    }

    private enum CodingKeys: String, CodingKey {
        case provider, trackID, title, artist, duration, confidence, matchKind, format, matchQuality
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decode(LyricsProviderID.self, forKey: .provider)
        trackID = try c.decodeIfPresent(String.self, forKey: .trackID)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        artist = try c.decodeIfPresent(String.self, forKey: .artist)
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration)
        confidence = try c.decode(Double.self, forKey: .confidence)
        matchKind = try c.decode(MatchKind.self, forKey: .matchKind)
        format = try c.decodeIfPresent(String.self, forKey: .format)
        matchQuality = try c.decodeIfPresent(MatchQuality.self, forKey: .matchQuality) ?? .exact
    }
}

/// Вокалист (агент) из `ttm:agent`.
public struct LyricAgent: Codable, Sendable, Equatable, Hashable {
    public enum Kind: String, Codable, Sendable { case person, group, other }
    public var id: String
    public var kind: Kind
    public var name: String?

    public init(id: String, kind: Kind = .person, name: String? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
    }
}

/// Слово или слог с таймингом.
public struct LyricWord: Codable, Sendable, Equatable {
    public var text: String
    public var begin: TimeInterval
    public var end: TimeInterval
    /// `true` — это продолжение предыдущего слова (между ними нет пробела: слоги, знаки препинания, CJK).
    public var isContinuation: Bool

    public init(text: String, begin: TimeInterval, end: TimeInterval, isContinuation: Bool = false) {
        self.text = text
        self.begin = begin
        self.end = end
        self.isContinuation = isContinuation
    }

    public var duration: TimeInterval { max(0, end - begin) }
}

public extension Array where Element == LyricWord {
    /// Склеивает слова в строку: пробел перед каждым словом, кроме продолжений.
    func joinedText() -> String {
        var result = ""
        for (i, w) in enumerated() {
            if i > 0 && !w.isContinuation { result += " " }
            result += w.text
        }
        return result
    }
}

/// Перевод или транслитерация строки.
public struct LyricAnnotation: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case subtitle
        case replacement
        case transliteration
    }
    public var kind: Kind
    /// BCP-47 (`ru`, `ja-Latn`), если известен.
    public var language: String?
    public var text: String
    /// Пословный тайминг перевода, если он есть (редко).
    public var words: [LyricWord]
    /// Перевод фонового вокала строки.
    public var backgroundText: String?

    public init(kind: Kind, language: String? = nil, text: String, words: [LyricWord] = [], backgroundText: String? = nil) {
        self.kind = kind
        self.language = language
        self.text = text
        self.words = words
        self.backgroundText = backgroundText
    }
}

/// Строка текста.
public struct LyricLine: Codable, Sendable, Equatable, Identifiable {
    /// Ключ строки (`itunes:key`, `L1`, …). Уникален в пределах текста.
    public var key: String
    public var id: String { key }
    /// Начало и конец строки; `nil` у текста без синхронизации.
    public var begin: TimeInterval?
    public var end: TimeInterval?
    /// Текст основного вокала. Для пословного текста совпадает с `words.joinedText()`.
    public var text: String
    /// Слова/слоги основного вокала (пусто у построчного и несинхронизированного текста).
    public var words: [LyricWord]
    /// Фоновый вокал — вложенные слова (`ttm:role="x-bg"`), скобки сняты.
    public var background: [LyricWord]
    /// Текст фонового вокала, если слов нет (построчный режим).
    public var backgroundText: String?
    /// Вокалист (`ttm:agent`), например `v1`.
    public var agentID: String?
    /// Часть песни: Intro, Verse, PreChorus, Chorus, Bridge, Outro и т. п.
    public var songPart: String?
    public var translations: [LyricAnnotation]
    public var transliterations: [LyricAnnotation]

    public init(key: String, begin: TimeInterval? = nil, end: TimeInterval? = nil, text: String = "",
                words: [LyricWord] = [], background: [LyricWord] = [], backgroundText: String? = nil,
                agentID: String? = nil, songPart: String? = nil,
                translations: [LyricAnnotation] = [], transliterations: [LyricAnnotation] = []) {
        self.key = key
        self.begin = begin
        self.end = end
        self.words = words
        self.text = words.isEmpty ? text : (text.isEmpty ? words.joinedText() : text)
        self.background = background
        self.backgroundText = backgroundText ?? (background.isEmpty ? nil : background.joinedText())
        self.agentID = agentID
        self.songPart = songPart
        self.translations = translations
        self.transliterations = transliterations
    }

    public var isWordSynced: Bool { !words.isEmpty }
    public var hasBackground: Bool { !background.isEmpty || (backgroundText?.isEmpty == false) }
    public var translation: LyricAnnotation? { translations.first }
    public var transliteration: LyricAnnotation? { transliterations.first }
    /// Пустая строка — пауза/инструментальный фрагмент.
    public var isGap: Bool { text.isEmpty && !hasBackground }
}

/// Текст песни целиком.
public struct Lyrics: Codable, Sendable, Equatable {
    public var source: LyricsSource
    /// Язык текста (BCP-47).
    public var language: String?
    public var syncType: SyncType
    public var lines: [LyricLine]
    public var agents: [LyricAgent]
    public var songwriters: [String]
    /// Длительность трека по данным текста (`body@dur`).
    public var duration: TimeInterval?
    /// Тишина в начале (`leadingSilence`).
    public var leadingSilence: TimeInterval?
    /// Прочие метаданные (теги LRC `ti/ar/al`, `amll:meta`).
    public var metadata: [String: [String]]
    /// Источник пометил трек как инструментальный (текста нет и не будет).
    public var isInstrumental: Bool
    public var fetchedAt: Date

    public init(source: LyricsSource, language: String? = nil, syncType: SyncType, lines: [LyricLine],
                agents: [LyricAgent] = [], songwriters: [String] = [], duration: TimeInterval? = nil,
                leadingSilence: TimeInterval? = nil, metadata: [String: [String]] = [:],
                isInstrumental: Bool = false, fetchedAt: Date = Date()) {
        self.source = source
        self.language = language
        self.syncType = syncType
        self.lines = lines
        self.agents = agents
        self.songwriters = songwriters
        self.duration = duration
        self.leadingSilence = leadingSilence
        self.metadata = metadata
        self.isInstrumental = isInstrumental
        self.fetchedAt = fetchedAt
    }

    public var isSynced: Bool { syncType != .none }
    public var isEmpty: Bool { lines.allSatisfy { $0.isGap } }
    public var hasTranslations: Bool { lines.contains { !$0.translations.isEmpty } }
    public var hasTransliterations: Bool { lines.contains { !$0.transliterations.isEmpty } }

    /// Индекс строки, активной в момент `time` (последняя строка с `begin <= time`), либо `nil` до первой.
    public func lineIndex(at time: TimeInterval) -> Int? {
        guard syncType != .none else { return nil }
        var lo = 0, hi = lines.count - 1, found: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if let b = lines[mid].begin, b <= time {
                found = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return found
    }

    /// Простой текст без таймингов (для показа и копирования).
    public var plainText: String {
        lines.map { $0.text }.joined(separator: "\n")
    }

    /// «Деградированная» версия: тот же текст без таймкодов (`syncType == .none`). Для случаев, когда синхронизация
    /// чужой версии записи явно не совпадает со временем. Пустые строки схлопываются в один разрыв куплета,
    /// края обрезаются; фоновый вокал остаётся текстом строки в скобках, переводы и транслитерация сохраняются.
    func plainVersion() -> Lyrics {
        var out: [LyricLine] = []
        for line in lines {
            var text = line.text
            if let bg = line.backgroundText, !bg.isEmpty { text = text.isEmpty ? "(\(bg))" : "\(text) (\(bg))" }
            if text.isEmpty {
                if let last = out.last, !last.text.isEmpty { out.append(LyricLine(key: "", text: "")) }
                continue
            }
            out.append(LyricLine(key: "", text: text, agentID: line.agentID, songPart: line.songPart,
                                 translations: line.translations.map { LyricAnnotation(kind: $0.kind, language: $0.language, text: $0.text) },
                                 transliterations: line.transliterations.map { LyricAnnotation(kind: $0.kind, language: $0.language, text: $0.text) }))
        }
        while let last = out.last, last.text.isEmpty { out.removeLast() }
        for i in out.indices { out[i].key = "L\(i + 1)" }
        var result = self
        result.syncType = .none
        result.lines = out
        result.leadingSilence = nil
        return result
    }
}
