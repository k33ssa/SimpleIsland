import Foundation

/// Что мы ищем: трек, который сейчас играет.
public struct TrackQuery: Sendable, Equatable, Codable {
    /// id каталога Apple Music (`playbackStoreID`). Значения «0» и пустое считаются отсутствием id.
    public var catalogId: String?
    public var title: String
    public var artist: String
    public var album: String?
    /// Длительность в секундах.
    public var duration: TimeInterval?
    public var isrc: String?
    /// Storefront подписки (`us`, `ru`); если не задан — берётся из `/v1/me/storefront`.
    public var storefront: String?
    /// Известные id в других сервисах (если уже сопоставлены ранее).
    public var neteaseId: String?
    public var qqSongMid: String?

    public init(catalogId: String? = nil, title: String, artist: String, album: String? = nil,
                duration: TimeInterval? = nil, isrc: String? = nil, storefront: String? = nil,
                neteaseId: String? = nil, qqSongMid: String? = nil) {
        let cid = catalogId?.trimmingCharacters(in: .whitespaces)
        self.catalogId = (cid == nil || cid == "" || cid == "0") ? nil : cid
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration.flatMap { $0 > 0 ? $0 : nil }
        self.isrc = isrc.map(TrackQuery.normalizeISRC).flatMap { $0.isEmpty ? nil : $0 }
        self.storefront = storefront?.lowercased()
        self.neteaseId = neteaseId
        self.qqSongMid = qqSongMid
    }

    public static func normalizeISRC(_ s: String) -> String {
        s.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Отпечаток запроса: нормализованные название | исполнитель | теги версии | длительность. Не зависит от id каталога.
    public var fingerprint: String {
        let t = TextNormalizer.parseTitle(title)
        return [TextNormalizer.fold(t.base),
                TextNormalizer.fold(artist),
                t.tags.map(\.rawValue).sorted().joined(separator: "+"),
                duration.map { String(Int($0.rounded())) } ?? "?"].joined(separator: "|")
    }

    /// Метаданных достаточно для поиска по названию и исполнителю (на iPhone они иногда приходят пустыми и дозаполняются позже).
    public var hasSearchableMetadata: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Ключ кэша: id каталога, иначе нормализованные метаданные.
    public var cacheKey: String {
        if let id = catalogId { return "am-\(id)" }
        return "md-" + Hashing.sha256Hex(fingerprint).prefix(32)
    }
}

/// Запись трека на стороне провайдера (результат поиска).
public struct TrackCandidate: Sendable, Equatable {
    public var id: String
    public var title: String
    public var artists: [String]
    public var album: String?
    public var duration: TimeInterval?
    public var isrc: String?

    public init(id: String, title: String, artists: [String], album: String? = nil,
                duration: TimeInterval? = nil, isrc: String? = nil) {
        self.id = id
        self.title = title
        self.artists = artists
        self.album = album
        self.duration = duration
        self.isrc = isrc.map(TrackQuery.normalizeISRC)
    }
}
