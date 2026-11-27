import Foundation

/// Источник текстов.
public protocol LyricsProvider: Sendable {
    var id: LyricsProviderID { get }
    /// Можно ли сейчас обращаться к провайдеру (например, у Apple нужен media-user-token).
    func isAvailable() async -> Bool
    /// Тексты для трека, лучшие первыми. Пустой массив — «не найдено». Ошибка — сбой (сеть, токен).
    func lyrics(for query: TrackQuery) async throws -> [Lyrics]
    /// То же, что `lyrics(for:)`, плюс пояснение, если не нашли. Есть реализация по умолчанию.
    func response(for query: TrackQuery) async throws -> ProviderResponse
    /// Провайдер умеет искать по id чужих сервисов (`neteaseId`, `qqSongMid`): если у него не вышло с первого раза,
    /// каскад повторит запрос, обогащённый id, которые нашли другие провайдеры.
    var usesCrossProviderIDs: Bool { get }
}

/// id трека в других сервисах, найденные в ходе поиска (для повторного запроса у провайдеров с `usesCrossProviderIDs`).
public struct TrackHints: Sendable, Equatable {
    public var neteaseId: String?
    public var qqSongMid: String?
    public init(neteaseId: String? = nil, qqSongMid: String? = nil) {
        self.neteaseId = neteaseId
        self.qqSongMid = qqSongMid
    }
    public var isEmpty: Bool { neteaseId == nil && qqSongMid == nil }
    mutating func merge(_ o: TrackHints) {
        neteaseId = neteaseId ?? o.neteaseId
        qqSongMid = qqSongMid ?? o.qqSongMid
    }
}

/// Ответ провайдера с диагностикой.
public struct ProviderResponse: Sendable {
    public var lyrics: [Lyrics]
    /// Краткая причина, если ничего не нашли («кандидатов: N, отвергнуты по длительности: K»).
    public var note: String?
    /// id в других сервисах, которые удалось определить (необязательно).
    public var hints: TrackHints?
    public init(lyrics: [Lyrics], note: String? = nil, hints: TrackHints? = nil) {
        self.lyrics = lyrics
        self.note = note
        self.hints = hints
    }
}

public extension LyricsProvider {
    func isAvailable() async -> Bool { true }
    var usesCrossProviderIDs: Bool { false }
    /// Как `lyrics(for:)`, но с пояснением. Провайдеры переопределяют; по умолчанию — без пояснения.
    func response(for query: TrackQuery) async throws -> ProviderResponse {
        ProviderResponse(lyrics: try await lyrics(for: query))
    }
}

/// Браузерный User-Agent для сервисов, которые отвергают чужие (Apple, NetEase, QQ). Нейтральный `AMNL/0.1` — для LRCLIB.
enum UserAgent {
    static let browser = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"
    static let amnl = "AMNL/0.1"
}

/// Сбор ошибок по кандидатам: сбой загрузки текста одного кандидата не должен терять уже найденное у других,
/// но если не нашлось ничего, а сбои были, — это «упало», а не «не найдено» (иначе в кэш ляжет ложное «не найдено»).
struct CandidateErrors {
    private(set) var last: Error?
    var count = 0

    mutating func attempt<T>(_ op: () async throws -> T?) async throws -> T? {
        do {
            return try await op()
        } catch let e as LyricsError where e == .cancelled {
            throw e
        } catch is CancellationError {
            throw LyricsError.cancelled
        } catch {
            last = error
            count += 1
            return nil
        }
    }

    /// Бросить последнюю ошибку, если результатов нет.
    func throwIfNothing(_ found: Bool) throws {
        if !found, let last { throw last }
    }
}

/// Код ошибки в теле JSON при HTTP 200 (NetEase `code`, QQ `code`, KuGou `status`/`error_code`): антибот, лимит, блокировка.
enum BodyCode {
    static func int(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue ?? (v as? String).flatMap { Int($0) } }
}
