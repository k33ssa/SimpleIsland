import Foundation

/// Выполняет `operation` с ограничением по времени. По истечении — отмена задачи и `LyricsError.network("таймаут")`.
func withDeadline<T: Sendable>(_ seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            throw LyricsError.network("таймаут \(Int(seconds)) с")
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw LyricsError.cancelled }
        return first
    }
}

/// Пауза с учётом отмены.
func pause(_ seconds: TimeInterval) async throws {
    try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
}

/// Небольшой кэш в памяти с TTL и ограничением по числу записей (самые старые вытесняются).
actor ResponseMemo<Value: Sendable> {
    private var items: [String: (date: Date, value: Value)] = [:]
    private let ttl: TimeInterval
    private let capacity: Int

    init(ttl: TimeInterval, capacity: Int) {
        self.ttl = ttl
        self.capacity = max(1, capacity)
    }

    func get(_ key: String) -> Value? {
        guard let it = items[key] else { return nil }
        if Date().timeIntervalSince(it.date) > ttl { items[key] = nil; return nil }
        return it.value
    }

    func set(_ key: String, _ value: Value) {
        items[key] = (Date(), value)
        if items.count > capacity, let oldest = items.min(by: { $0.value.date < $1.value.date })?.key { items[oldest] = nil }
    }

    func remove(_ key: String) { items[key] = nil }
    func removeAll() { items.removeAll() }
}
