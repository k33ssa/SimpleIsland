import Foundation
import IslandCore

/// Файл на полке. Лежит копией в `~/Library/Application Support/SimpleIsland/Shelf/<id>/<name>`.
public struct ShelfItem: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var addedAt: Date
    public var size: Int64
    public var isDirectory: Bool
    /// Только для снимков: плейсхолдер вместо миниатюры (не сохраняется).
    var mockArt: MockArt?

    enum MockArt: String, Codable, Sendable { case warm, sea, violet, document }

    enum CodingKeys: String, CodingKey { case id, name, addedAt, size, isDirectory }

    public init(id: UUID = UUID(), name: String, addedAt: Date = Date(), size: Int64, isDirectory: Bool = false) {
        self.id = id; self.name = name; self.addedAt = addedAt; self.size = size; self.isDirectory = isDirectory
    }

    /// Имя на карточке: без расширения (у папок — как есть).
    var displayName: String {
        guard !isDirectory else { return name }
        let base = (name as NSString).deletingPathExtension
        return base.isEmpty ? name : base
    }
}

/// Хранилище полки: копии файлов + индекс `index.json`. Без таймеров: очистку зовёт модель
/// (при запуске и раз в час). Все методы — на главном потоке, копирование — в фоне (`ShelfFiles`).
@MainActor
final class ShelfStore {
    let root: URL
    private(set) var items: [ShelfItem] = []

    init(root: URL = SimpleIslandPaths.appSupport.appendingPathComponent("Shelf", isDirectory: true)) {
        self.root = root
    }

    var indexURL: URL { root.appendingPathComponent("index.json") }

    func url(for item: ShelfItem) -> URL {
        root.appendingPathComponent(item.id.uuidString, isDirectory: true).appendingPathComponent(item.name)
    }

    /// Прочитать индекс; записи без файла отбросить. Папки `<uuid>` без записи (индекс повреждён, сменилась схема,
    /// приложение упало между копированием и записью индекса) не удаляются, а возвращаются на полку:
    /// имя — файл внутри, дата — дата создания папки. Срок потом уберёт их как обычно.
    /// Нечитаемый индекс сохраняется рядом как `index.broken-<время>.json`.
    func load() {
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        var loaded: [ShelfItem] = []
        var dirty = false
        if let data = try? Data(contentsOf: indexURL) {
            let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
            if let list = try? d.decode([ShelfItem].self, from: data) {
                loaded = list
            } else {
                let stamp = Int(Date().timeIntervalSince1970)
                try? fm.moveItem(at: indexURL, to: root.appendingPathComponent("index.broken-\(stamp).json"))
                dirty = true
            }
        }
        items = loaded.filter { fm.fileExists(atPath: url(for: $0).path) }
        if items.count != loaded.count { dirty = true }
        let known = Set(items.map(\.id.uuidString))
        let dirs = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        for d in dirs.sorted() where !known.contains(d) {
            guard let id = UUID(uuidString: d) else { continue }
            let dir = root.appendingPathComponent(d, isDirectory: true)
            if let item = Self.recover(id: id, dir: dir) {
                items.append(item)
            } else {
                try? fm.removeItem(at: dir)          // пустая папка — после неудачного копирования
            }
            dirty = true
        }
        items.sort { $0.addedAt < $1.addedAt }
        if dirty { save() }
    }

    /// Запись по папке без индекса. nil — внутри нет файла.
    static func recover(id: UUID, dir: URL) -> ShelfItem? {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        guard let name = names.first else { return nil }
        let file = dir.appendingPathComponent(name)
        let v = try? dir.resourceValues(forKeys: [.creationDateKey])
        var isDir: ObjCBool = false
        fm.fileExists(atPath: file.path, isDirectory: &isDir)
        return ShelfItem(id: id, name: name, addedAt: v?.creationDate ?? Date(),
                         size: ShelfFiles.size(of: file), isDirectory: isDir.boolValue)
    }

    func save() {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted]
        guard let data = try? e.encode(items) else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? data.write(to: indexURL, options: .atomic)
    }

    /// Добавить уже скопированные файлы (результат `ShelfFiles.importFiles`).
    func append(_ new: [ShelfItem]) {
        guard !new.isEmpty else { return }
        items.append(contentsOf: new)
        save()
    }

    /// Убрать с полки. `toTrash` — ручное удаление (можно вернуть из Корзины), иначе — насовсем (срок вышел).
    func remove(ids: Set<UUID>, toTrash: Bool) {
        let fm = FileManager.default
        for item in items where ids.contains(item.id) {
            let dir = root.appendingPathComponent(item.id.uuidString, isDirectory: true)
            if toTrash { try? fm.trashItem(at: url(for: item), resultingItemURL: nil) }
            try? fm.removeItem(at: dir)
        }
        items.removeAll { ids.contains($0.id) }
        save()
    }

    /// Удалить всё, что старше `ttl`. Возвращает число удалённых.
    @discardableResult
    func purgeExpired(ttl: TimeInterval, now: Date = Date()) -> Int {
        guard ttl > 0 else { return 0 }
        let old = Set(items.filter { now.timeIntervalSince($0.addedAt) >= ttl }.map(\.id))
        if !old.isEmpty { remove(ids: old, toTrash: false) }
        return old.count
    }

    /// Файл уже лежит на полке (бросили карточку с полки обратно на «На полку»).
    func contains(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/")
    }
}

/// Файловые операции полки, без состояния — можно звать из фона.
enum ShelfFiles {
    /// Скопировать (или перенести — для своих временных результатов) файлы в папки полки.
    /// На APFS `copyItem` делает clonefile — мгновенно и без места.
    static func importFiles(_ urls: [URL], into root: URL, move: Bool) throws -> [ShelfItem] {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var out: [ShelfItem] = []
        for src in urls {
            let id = UUID()
            let dir = root.appendingPathComponent(id.uuidString, isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let name = src.lastPathComponent.isEmpty ? "файл" : src.lastPathComponent
            let dst = dir.appendingPathComponent(name)
            do {
                if move { try fm.moveItem(at: src, to: dst) } else { try fm.copyItem(at: src, to: dst) }
            } catch {
                try? fm.removeItem(at: dir)
                throw error
            }
            var isDir: ObjCBool = false
            fm.fileExists(atPath: dst.path, isDirectory: &isDir)
            out.append(ShelfItem(id: id, name: name, size: size(of: dst), isDirectory: isDir.boolValue))
        }
        return out
    }

    /// Размер файла или папки (рекурсивно).
    static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        guard let v = try? url.resourceValues(forKeys: keys) else { return 0 }
        if v.isDirectory != true { return Int64(v.fileSize ?? v.totalFileAllocatedSize ?? 0) }
        var total: Int64 = 0
        if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) {
            for case let f as URL in e {
                if let fv = try? f.resourceValues(forKeys: keys), fv.isDirectory != true {
                    total += Int64(fv.fileSize ?? 0)
                }
            }
        }
        return total
    }

    /// Свободное имя в каталоге: «имя.png», «имя 2.png», …
    static func uniqueURL(in dir: URL, name: String) -> URL {
        let fm = FileManager.default
        var url = dir.appendingPathComponent(name)
        guard fm.fileExists(atPath: url.path) else { return url }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        repeat {
            url = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        } while fm.fileExists(atPath: url.path)
        return url
    }

    /// `$TMPDIR/SimpleIsland-shelf` — временные результаты операций.
    static var tempRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("SimpleIsland-shelf", isDirectory: true)
    }

    /// Адрес новой временной папки (ещё не создана) — чтобы убрать её и после ошибки.
    static func tempDirURL() -> URL { tempRoot.appendingPathComponent(UUID().uuidString, isDirectory: true) }

    /// Своя временная папка под результат операции.
    static func makeTempDir() throws -> URL {
        let dir = tempDirURL()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Убрать временные папки старше суток (остались после падения приложения). В фоне.
    static func cleanStaleTemp(olderThan age: TimeInterval = 86400, in root: URL = tempRoot) {
        DispatchQueue.global(qos: .background).async {
            let fm = FileManager.default
            let keys: [URLResourceKey] = [.contentModificationDateKey]
            guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: keys) else { return }
            for d in dirs {
                let m = (try? d.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
                if Date().timeIntervalSince(m) > age { try? fm.removeItem(at: d) }
            }
        }
    }
}

// MARK: - Подписи

enum ShelfFormat {
    static func size(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB]
        var s = f.string(fromByteCount: bytes)
        // Системный форматтер берёт язык процесса; приводим к русским единицам, если вышло по-английски.
        for (en, ru) in [("KB", "КБ"), ("MB", "МБ"), ("GB", "ГБ"), ("Zero", "0"), ("bytes", "Б")] {
            s = s.replacingOccurrences(of: en, with: ru)
        }
        if s.contains("."), !s.contains(",") { s = s.replacingOccurrences(of: ".", with: ",") }
        return s
    }

    static func age(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, now.timeIntervalSince(date))
        if s < 60 { return "сейчас" }
        if s < 3600 { return "\(Int(s / 60)) мин" }
        if s < 86400 { return "\(Int(s / 3600)) ч" }
        return "\(Int(s / 86400)) д"
    }

    static func files(_ n: Int) -> String { "\(n) \(plural(n, "файл", "файла", "файлов"))" }

    static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let n10 = n % 10, n100 = n % 100
        if n10 == 1 && n100 != 11 { return one }
        if (2...4).contains(n10) && !(12...14).contains(n100) { return few }
        return many
    }

    static func ttl(_ hours: Int) -> String {
        if hours <= 0 { return "без срока" }
        if hours % 24 == 0 { let d = hours / 24; return d == 1 ? "на 24 ч" : "на \(d) \(plural(d, "день", "дня", "дней"))" }
        return "на \(hours) ч"
    }
}
