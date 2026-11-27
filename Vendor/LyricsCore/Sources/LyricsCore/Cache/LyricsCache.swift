import Foundation

/// Результат, который лежит в кэше: лучший текст и альтернативы.
public struct CachedLyrics: Codable, Sendable, Equatable {
    public var best: Lyrics?
    public var alternatives: [Lyrics]
    public var storedAt: Date
    public var expiresAt: Date
    /// Выбран пользователем вручную — не истекает и не перезаписывается автоматическим поиском.
    public var pinned: Bool
    /// Отпечаток запроса, по которому записан результат (нужен у негативных записей). Нет в старых записях.
    public var queryFingerprint: String?
}

/// Дисковый кэш текстов. По умолчанию — `Caches/app.amnl.lyrics` (не попадает в резервные копии, система может очистить).
/// Тексты Apple лежат только здесь и нигде не публикуются; каталог исключён из резервного копирования.
public final class LyricsCache: @unchecked Sendable {
    public struct TTL: Sendable {
        public var word: TimeInterval = 30 * 86400
        public var line: TimeInterval = 14 * 86400
        public var plain: TimeInterval = 7 * 86400
        /// Ничего не нашли — повторять поиск не раньше, чем через…
        public var negative: TimeInterval = 30 * 60
        /// `best` — «почти совпадение» (приблизительная синхронизация): перепроверять чаще, чем точный результат.
        public var approximate: TimeInterval = 6 * 3600
        public init() {}
    }

    private static let formatVersion = 1
    public let directory: URL
    public let ttl: TTL
    private let maxEntries: Int
    private let maxBytes: Int?
    private let pruneInterval: Int
    private let queue = DispatchQueue(label: "app.amnl.lyrics.cache")
    private let now: @Sendable () -> Date
    private var writesSincePrune = 0
    /// Приблизительное число файлов и байт (уточняется при каждой чистке, растёт при записи) — чтобы не листать каталог на каждую запись.
    private var approxCount: Int?
    private var approxBytes = 0

    public init(directory: URL? = nil, ttl: TTL = TTL(), maxEntries: Int = 3000, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory ?? LyricsCache.defaultDirectory()
        self.ttl = ttl
        self.maxEntries = maxEntries
        self.maxBytes = nil
        self.pruneInterval = 50
        self.now = now
        prepareDirectory()
    }

    /// То же, плюс предел по размеру и частота чистки.
    /// - `maxBytes`: предел суммарного размера файлов кэша (старые по времени изменения удаляются первыми; закреплённые — в последнюю очередь).
    /// - `pruneInterval`: проверять пределы раз в столько записей. Кроме того, проверка идёт сразу, как только по приблизительному
    ///   счёту превышен `maxEntries` или `maxBytes`, — так число файлов не уходит за предел больше чем на одну запись.
    public init(directory: URL? = nil, ttl: TTL = TTL(), maxEntries: Int = 3000, maxBytes: Int?, pruneInterval: Int = 50,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory ?? LyricsCache.defaultDirectory()
        self.ttl = ttl
        self.maxEntries = maxEntries
        self.maxBytes = maxBytes
        self.pruneInterval = max(1, pruneInterval)
        self.now = now
        prepareDirectory()
    }

    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("app.amnl.lyrics", isDirectory: true)
    }

    private func prepareDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var dir = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
    }

    // MARK: -

    private struct Envelope: Codable {
        var version: Int
        var key: String
        var entry: CachedLyrics
    }

    private func fileURL(_ key: String) -> URL {
        directory.appendingPathComponent(String(Hashing.sha256Hex(key).prefix(40)) + ".json")
    }

    /// Возвращает запись, если она есть и не просрочена (или закреплена).
    /// `fingerprint` — отпечаток текущего запроса: негативная запись («не найдено», `best == nil`) с другим или
    /// отсутствующим отпечатком игнорируется (первый запрос мог прийти с неполными метаданными).
    public func load(key: String, fingerprint: String? = nil) -> CachedLyrics? {
        queue.sync {
            let url = fileURL(key)
            guard let data = try? Data(contentsOf: url) else { return nil }
            guard let env = try? JSONDecoder.cache.decode(Envelope.self, from: data), env.version == Self.formatVersion, env.key == key else {
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            if !env.entry.pinned && env.entry.expiresAt <= now() {
                try? FileManager.default.removeItem(at: url)
                Log.cache.debug("кэш: запись просрочена")
                return nil
            }
            if let fingerprint, !env.entry.pinned, env.entry.best == nil, env.entry.queryFingerprint != fingerprint {
                Log.cache.debug("кэш: негативная запись для другого запроса — игнорируется")
                return nil
            }
            return env.entry
        }
    }

    /// Записывает результат. Закреплённую запись автоматический результат не затирает.
    @discardableResult
    public func store(key: String, best: Lyrics?, alternatives: [Lyrics], pinned: Bool = false,
                      fingerprint: String? = nil) -> CachedLyrics {
        queue.sync {
            if !pinned, let existing = readRaw(key: key), existing.pinned { return existing }
            let t = now()
            let life: TimeInterval
            if let best, best.source.matchQuality.isNearMiss, !pinned {
                life = ttl.approximate
            } else if let best {
                switch best.syncType {
                case .word: life = ttl.word
                case .line: life = ttl.line
                case .none: life = best.isInstrumental ? ttl.word : ttl.plain
                }
            } else {
                life = ttl.negative
            }
            let entry = CachedLyrics(best: best, alternatives: alternatives, storedAt: t, expiresAt: t.addingTimeInterval(life), pinned: pinned,
                                     queryFingerprint: fingerprint)
            let env = Envelope(version: Self.formatVersion, key: key, entry: entry)
            if let data = try? JSONEncoder.cache.encode(env) {
                let url = fileURL(key)
                let existed = FileManager.default.fileExists(atPath: url.path)
                do {
                    try data.write(to: url, options: [.atomic])
                    if approxCount != nil, !existed { approxCount! += 1 }
                    approxBytes += data.count
                } catch {
                    Log.cache.error("кэш: не удалось записать файл")
                }
            }
            pruneIfNeeded()
            return entry
        }
    }

    public func remove(key: String) {
        queue.sync { try? FileManager.default.removeItem(at: fileURL(key)) }
    }

    public func removeAll() {
        queue.sync {
            for u in cacheFiles() { try? FileManager.default.removeItem(at: u) }
        }
    }

    /// Удаляет просроченные записи; возвращает, сколько удалено.
    @discardableResult
    public func purgeExpired() -> Int {
        queue.sync {
            var n = 0
            for u in cacheFiles() {
                guard let data = try? Data(contentsOf: u), let env = try? JSONDecoder.cache.decode(Envelope.self, from: data) else {
                    try? FileManager.default.removeItem(at: u); n += 1; continue
                }
                if !env.entry.pinned && env.entry.expiresAt <= now() { try? FileManager.default.removeItem(at: u); n += 1 }
            }
            return n
        }
    }

    // MARK: -

    private func readRaw(key: String) -> CachedLyrics? {
        guard let data = try? Data(contentsOf: fileURL(key)), let env = try? JSONDecoder.cache.decode(Envelope.self, from: data),
              env.key == key else { return nil }
        return env.entry
    }

    private func cacheFiles() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "json" }
    }

    private func pruneIfNeeded() {
        writesSincePrune += 1
        let overCount = approxCount.map { $0 > maxEntries } ?? true   // счёт ещё не известен — проверить
        let overBytes = maxBytes.map { approxBytes > $0 } ?? false
        guard writesSincePrune >= pruneInterval || overCount || overBytes else { return }
        writesSincePrune = 0
        prune()
    }

    /// Удаляет самые старые файлы, пока не уложимся в `maxEntries` и `maxBytes`. Закреплённый выбор удаляется последним.
    private func prune() {
        struct F { var url: URL; var date: Date; var size: Int; var pinned: Bool }
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        var files: [F] = cacheFiles().map { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            return F(url: u, date: v?.contentModificationDate ?? .distantPast, size: v?.fileSize ?? 0, pinned: false)
        }
        var total = files.reduce(0) { $0 + $1.size }
        let overCount = files.count > maxEntries
        let overBytes = maxBytes.map { total > $0 } ?? false
        if overCount || overBytes {
            // закреплённые — в конец очереди на удаление (читаем только при реальной чистке)
            for i in files.indices {
                if let d = try? Data(contentsOf: files[i].url), let env = try? JSONDecoder.cache.decode(Envelope.self, from: d) { files[i].pinned = env.entry.pinned }
            }
            files.sort { a, b in a.pinned != b.pinned ? !a.pinned : a.date < b.date }
            var count = files.count
            var idx = 0
            while idx < files.count, count > maxEntries || (maxBytes.map { total > $0 } ?? false) {
                try? FileManager.default.removeItem(at: files[idx].url)
                total -= files[idx].size
                count -= 1
                idx += 1
            }
            approxCount = count
        } else {
            approxCount = files.count
        }
        approxBytes = total
    }
}

extension JSONEncoder {
    static var cache: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e }
}
extension JSONDecoder {
    static var cache: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }
}
