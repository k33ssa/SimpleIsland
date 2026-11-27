import Foundation

/// Слежение за файлом через `DispatchSource` (kqueue), без опроса. Переживает замену файла
/// (атомарная запись `write(to:options:.atomic)`, `mv` поверх, удаление и создание заново): на `delete`/`rename`
/// дескриптор переоткрывается по пути; если файла пока нет — ждёт его появления, следя за каталогом.
///
/// ```swift
/// watcher = FileWatcher(url: statusURL) { [weak self] in self?.reloadStatus() }   // главный поток, склейка 0,1 с
/// watcher.start()
/// ```
/// Для status.json Vafa, конфигов, файлов агентов. Журналы с дописыванием — `TailReader`.
@MainActor
public final class FileWatcher {
    public let url: URL
    /// Склейка пачки событий (запись + атрибуты + переименование) в один вызов.
    public var coalesce: TimeInterval = 0.1
    private let onChange: @MainActor () -> Void
    // nonisolated(unsafe): трогаются только с главного потока; доступны из deinit, чтобы закрыть дескрипторы.
    nonisolated(unsafe) private var source: DispatchSourceFileSystemObject?
    nonisolated(unsafe) private var dirSource: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    /// Сколько раз вызван `onChange` (самотесты).
    public private(set) var changeCount = 0
    public private(set) var isWatchingFile = false

    public init(url: URL, onChange: @escaping @MainActor () -> Void) {
        self.url = url
        self.onChange = onChange
    }

    deinit {
        source?.cancel()
        dirSource?.cancel()
    }

    public func start() {
        stop()
        if !openFile() { watchDirectory() }
    }

    public func stop() {
        source?.cancel(); source = nil
        dirSource?.cancel(); dirSource = nil
        pending?.cancel(); pending = nil
        isWatchingFile = false
    }

    private func openFile() -> Bool {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return false }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                            eventMask: [.write, .extend, .delete, .rename, .attrib, .revoke],
                                                            queue: .main)
        src.setEventHandler { [weak self, weak src] in
            MainActor.assumeIsolated {
                guard let self, let src else { return }
                let ev = src.data
                if ev.contains(.delete) || ev.contains(.rename) || ev.contains(.revoke) {
                    // Файл заменили: переоткрыть по пути (новый файл уже на месте при атомарной записи).
                    src.cancel()
                    self.source = nil
                    self.isWatchingFile = false
                    if !self.openFile() { self.watchDirectory() }
                }
                self.schedule()
            }
        }
        src.setCancelHandler { close(fd) }
        source = src
        isWatchingFile = true
        dirSource?.cancel(); dirSource = nil
        src.resume()
        return true
    }

    /// Файла нет — следим за каталогом, пока он не появится.
    private func watchDirectory() {
        guard dirSource == nil else { return }
        let dir = url.deletingLastPathComponent()
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .link, .rename],
                                                            queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.source == nil else { return }
                if self.openFile() { self.schedule() }
            }
        }
        src.setCancelHandler { close(fd) }
        dirSource = src
        src.resume()
    }

    private func schedule() {
        pending?.cancel()
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.changeCount += 1
                self.onChange()
            }
        }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + coalesce, execute: w)
    }
}

/// Хвост файла и дочитывание новых строк по событию (грабли M2: у Atoll/OpenVibe журналы агентов читались
/// целиком — 502 МБ JSONL → 914 МБ RSS и 150–206 % CPU).
///
/// * `start(tailBytes:)` — читает только последние `tailBytes` байт (первая неполная строка отбрасывается),
///   дальше — только новое, от запомненного смещения.
/// * Новое приходит по событию `DispatchSource` (`.extend`/`.write`), не по таймеру.
/// * Файл усекли (смещение > размера) — читает с начала; заменили/удалили — переоткрывает по пути.
/// * Строка длиннее `maxLineBytes` (по умолчанию 1 МБ) — обрезается; за один проход читается не больше
///   `maxChunkBytes` (4 МБ), остальное — на следующем шаге цикла, чтобы не морозить главный поток.
///
/// ```swift
/// tail = TailReader(url: sessionLog) { [weak self] lines in self?.ingest(lines) }
/// tail.start(tailBytes: 256 << 10)
/// ```
@MainActor
public final class TailReader {
    public let url: URL
    public var maxLineBytes = 1 << 20
    public var maxChunkBytes = 4 << 20
    private let onLines: @MainActor ([String]) -> Void
    private var handle: FileHandle?
    private var offset: UInt64 = 0
    private var partial = Data()
    nonisolated(unsafe) private var source: DispatchSourceFileSystemObject?
    nonisolated(unsafe) private var dirSource: DispatchSourceFileSystemObject?
    private var readScheduled = false
    /// Сколько байт прочитано всего (самотесты: хвост, а не весь файл).
    public private(set) var bytesRead: UInt64 = 0

    public init(url: URL, onLines: @escaping @MainActor ([String]) -> Void) {
        self.url = url
        self.onLines = onLines
    }

    deinit {
        source?.cancel()
        dirSource?.cancel()
    }

    /// Начать: отдать последние строки (не больше `tailBytes` байт) и дальше следить.
    public func start(tailBytes: UInt64 = 64 << 10) {
        stop()
        guard open(fromEndMinus: tailBytes) else { watchDirectory(); return }
        readAvailable()
    }

    public func stop() {
        // Дескриптор файла закрывает обработчик отмены источника — не раньше, чем источник отменён (Dispatch).
        source?.cancel(); source = nil
        dirSource?.cancel(); dirSource = nil
        handle = nil
        partial.removeAll()
    }

    private func open(fromEndMinus tail: UInt64?) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        handle = h
        let size = (try? h.seekToEnd()) ?? 0
        if let tail {
            offset = size > tail ? size - tail : 0
            partial.removeAll()
            if offset > 0 {
                // Начали с середины строки — до первого перевода строки отбросить.
                try? h.seek(toOffset: offset)
                if let probe = try? h.read(upToCount: Int(min(tail, 64 << 10))), let nl = probe.firstIndex(of: 0x0A) {
                    offset += UInt64(nl - probe.startIndex + 1)
                }
            }
        } else {
            offset = 0
        }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: h.fileDescriptor,
                                                            eventMask: [.extend, .write, .delete, .rename, .revoke],
                                                            queue: .main)
        src.setEventHandler { [weak self, weak src] in
            MainActor.assumeIsolated {
                guard let self, let src else { return }
                let ev = src.data
                if ev.contains(.delete) || ev.contains(.rename) || ev.contains(.revoke) {
                    // Ротация/замена: дочитать старый и переоткрыть новый с начала.
                    self.readAvailable()
                    src.cancel(); self.source = nil      // дескриптор закроет обработчик отмены
                    self.handle = nil
                    self.partial.removeAll()
                    if !self.open(fromEndMinus: nil) { self.watchDirectory() } else { self.readAvailable() }
                } else {
                    self.scheduleRead()
                }
            }
        }
        // Закрыть файл — только здесь: после отмены источника, а не до (иначе kqueue следит за чужим номером).
        src.setCancelHandler { try? h.close() }
        source = src
        dirSource?.cancel(); dirSource = nil
        src.resume()
        return true
    }

    private func watchDirectory() {
        guard dirSource == nil else { return }
        let fd = Darwin.open(url.deletingLastPathComponent().path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .link, .rename],
                                                            queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.handle == nil else { return }
                if self.open(fromEndMinus: nil) { self.readAvailable() }
            }
        }
        src.setCancelHandler { close(fd) }
        dirSource = src
        src.resume()
    }

    private func scheduleRead() {
        guard !readScheduled else { return }
        readScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.readScheduled = false
                self.readAvailable()
            }
        }
    }

    /// Дочитать новое от смещения.
    public func readAvailable() {
        guard let h = handle else { return }
        let size = (try? h.seekToEnd()) ?? 0
        if size < offset { offset = 0; partial.removeAll() }      // усекли
        guard size > offset else { return }
        let want = Int(min(size - offset, UInt64(maxChunkBytes)))
        try? h.seek(toOffset: offset)
        guard let data = try? h.read(upToCount: want), !data.isEmpty else { return }
        offset += UInt64(data.count)
        bytesRead += UInt64(data.count)
        partial.append(data)
        var lines: [String] = []
        var start = partial.startIndex
        while let nl = partial[start...].firstIndex(of: 0x0A) {
            var line = partial[start..<nl]
            if line.count > maxLineBytes { line = line.prefix(maxLineBytes) }
            lines.append(String(decoding: line, as: UTF8.self))
            start = partial.index(after: nl)
        }
        partial = Data(partial[start...])
        if partial.count > maxLineBytes { partial = Data(partial.prefix(maxLineBytes)) }
        if !lines.isEmpty { onLines(lines) }
        if size > offset { scheduleRead() }                       // остаток — следующим шагом
    }
}
