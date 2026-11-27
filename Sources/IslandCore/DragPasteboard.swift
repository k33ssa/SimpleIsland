import AppKit
import UniformTypeIdentifiers

// --- shelfbar ---
// Что тащат: «файл» в широком смысле. Раньше ядро и Полка понимали только `public.file-url` (Finder), и «скрин не
// кладётся» (15.11): плавающая миниатюра снимка экрана (⌘⇧3/4), вложения Почты/Telegram и картинки из Chrome отдают
// **обещание файла** (NSFilePromiseProvider: `com.apple.NSFilePromiseItemMetaData`,
// `com.apple.pasteboard.promised-file-content-type`, старое `Apple files promise pasteboard type`), Safari и
// просмотрщики — **сырую картинку** (`public.png` / `public.tiff`), часть приложений — `public.url` с `file://`.
//
// `DragPasteboard.inspect` разбирает пастборд (без чтения больших данных — только типы и ссылки),
// `receive` превращает содержимое в файлы на диске: ссылки как есть, обещания — `NSFilePromiseReceiver` в
// указанную папку, картинки — PNG «Снимок <дата> в <время>.png». Сеть не трогается: http(s)-ссылки пропускаются.

public enum DragPasteboard {
    /// Типы обещаний файла (новые и старый NSFilesPromisePboardType).
    public static let promiseTypes: [NSPasteboard.PasteboardType] = {
        var t = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        for raw in ["com.apple.NSFilePromiseItemMetaData", "com.apple.pasteboard.promised-file-url",
                    "com.apple.pasteboard.promised-file-content-type", "Apple files promise pasteboard type"]
        where !t.contains(NSPasteboard.PasteboardType(raw)) {
            t.append(NSPasteboard.PasteboardType(raw))
        }
        return t
    }()

    /// Сырые картинки, которые сохраняем в PNG (порядок — предпочтение).
    public static let imageTypes: [NSPasteboard.PasteboardType] = [
        .png, .tiff, NSPasteboard.PasteboardType(UTType.jpeg.identifier), NSPasteboard.PasteboardType(UTType.heic.identifier),
    ]

    /// Все типы, при которых перетаскивание считается «тащат файл» (регистрация drop-зон).
    public static var draggedTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, .URL, NSPasteboard.PasteboardType("NSFilenamesPboardType")] + promiseTypes + imageTypes
    }

    /// То же для SwiftUI `.onDrop(of:)`. Типы обещаний не объявлены в системе — динамические UTType.
    public static var dropUTTypes: [UTType] {
        var out: [UTType] = [.fileURL, .url, .image, .png, .tiff, .jpeg, .heic]
        for t in promiseTypes {
            // «Apple files promise pasteboard type» — не идентификатор (пробелы): только в AppKit-регистрации.
            guard !t.rawValue.contains(" ") else { continue }
            let u = UTType(t.rawValue) ?? UTType(importedAs: t.rawValue)
            if !out.contains(u) { out.append(u) }
        }
        return out
    }

    public struct Contents: Equatable, Sendable {
        /// Локальные файлы (`public.file-url`, `NSFilenamesPboardType`, `public.url` со схемой file://).
        public var fileURLs: [URL] = []
        /// Сколько обещаний файла (элементов с типом обещания).
        public var promiseCount = 0
        /// Тип сырой картинки, если есть (`public.png`, `public.tiff`…).
        public var imageType: NSPasteboard.PasteboardType?
        /// Сетевые ссылки (http/https…): их не скачиваем, только для сводки/отладки.
        public var remoteURLs: [URL] = []

        public init() {}

        /// Будет ли из этого файл. Одни сетевые ссылки и текст — нет.
        public var isFileLike: Bool { !fileURLs.isEmpty || promiseCount > 0 || imageType != nil }

        /// Что положим, по приоритету: файлы → обещания → картинка.
        public enum Kind: String, Sendable { case files, promises, image, none }
        public var kind: Kind {
            if !fileURLs.isEmpty { return .files }
            if promiseCount > 0 { return .promises }
            if imageType != nil { return .image }
            return .none
        }

        /// Сколько файлов выйдет (для сводки «N файлов»).
        public var expectedCount: Int {
            switch kind {
            case .files: return fileURLs.count
            case .promises: return promiseCount
            case .image: return 1
            case .none: return 0
            }
        }
    }

    /// Разобрать пастборд. Читает только типы и ссылки (быстро, можно на каждый `leftMouseDragged`).
    public static func inspect(_ pb: NSPasteboard) -> Contents {
        var c = Contents()
        let all = Set(pb.types ?? [])
        guard !all.isEmpty else { return c }
        if all.contains(.fileURL) || all.contains(.URL) || all.contains(NSPasteboard.PasteboardType("NSFilenamesPboardType")) {
            let urls = (pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? []
            var seen = Set<String>()
            for u in urls {
                if u.isFileURL {
                    let key = u.standardizedFileURL.path
                    if seen.insert(key).inserted { c.fileURLs.append(u.standardizedFileURL) }
                } else if u.scheme != nil {
                    c.remoteURLs.append(u)
                }
            }
        }
        let promise = Set(promiseTypes)
        if !all.isDisjoint(with: promise) {
            let items = pb.pasteboardItems ?? []
            c.promiseCount = items.filter { !Set($0.types).isDisjoint(with: promise) }.count
            if c.promiseCount == 0 { c.promiseCount = 1 }   // старый тип — на уровне пастборда, не элемента
        }
        c.imageType = imageTypes.first { all.contains($0) }
        return c
    }

    public static func isFileLike(_ pb: NSPasteboard) -> Bool { inspectTypes(pb).isFileLike }

    /// Разбор **без чтения ссылок на файлы** — только типы (и строка `public.url`, если других файловых типов нет).
    /// Для фазы перетаскивания (монитор мыши, подсветка, сводка): чтение `public.file-url` из drag-буфера до броска
    /// дало в журнале «Failed to get a sandbox extension (-21)» (16.11, миниатюра снимка) — данные файла читаем
    /// только в момент броска (`accept`). `fileURLs` здесь — заглушки по числу элементов, путей нет.
    public static func inspectTypes(_ pb: NSPasteboard) -> Contents {
        var c = Contents()
        let all = Set(pb.types ?? [])
        guard !all.isEmpty else { return c }
        let fileTypes: Set<NSPasteboard.PasteboardType> = [.fileURL, NSPasteboard.PasteboardType("NSFilenamesPboardType")]
        if !all.isDisjoint(with: fileTypes) {
            let n = (pb.pasteboardItems ?? []).filter { $0.types.contains(.fileURL) }.count
            c.fileURLs = Array(repeating: URL(fileURLWithPath: "/"), count: max(1, n))
        } else if all.contains(.URL), let s = pb.string(forType: .URL), let u = URL(string: s) {
            if u.isFileURL { c.fileURLs = [u] } else if u.scheme != nil { c.remoteURLs = [u] }
        }
        let promise = Set(promiseTypes)
        if !all.isDisjoint(with: promise) {
            c.promiseCount = max(1, (pb.pasteboardItems ?? []).filter { !Set($0.types).isDisjoint(with: promise) }.count)
        }
        c.imageType = imageTypes.first { all.contains($0) }
        return c
    }

    /// Типы обещанных файлов (`NSFilePromiseReceiver.fileTypes`), для сводки и самотеста.
    public static func promisedFileTypes(_ pb: NSPasteboard) -> [String] {
        ((pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver]) ?? [])
            .flatMap(\.fileTypes)
    }

    /// Имя для картинки без файла: «Снимок 2026-11-15 в 02.51.07.png» (как у снимков экрана macOS).
    public static func imageFileName(date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd' в 'HH.mm.ss"
        return "Снимок \(f.string(from: date)).png"
    }

    /// Свободное имя в папке: «имя.png», «имя 2.png»…
    public static func uniqueURL(in dir: URL, name: String) -> URL {
        let fm = FileManager.default
        var url = dir.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return url
    }

    /// PNG из данных картинки любого формата, что понимает ImageIO (png как есть).
    static func pngData(_ data: Data, type: NSPasteboard.PasteboardType) -> Data? {
        if type == .png { return data }
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Превратить содержимое пастборда в файлы на диске и отдать их ссылки (на главном потоке).
    /// --- shelfshot --- обёртка над `accept` (без NSItemProvider и без ответа «принимать ли бросок»): временные
    /// файлы источника копируются в `dir` сразу, нечитаемые — запасными путями. Пусто — нечего было взять.
    @MainActor
    public static func receive(_ pb: NSPasteboard, into dir: URL, timeout: TimeInterval = 30,
                               completion: @escaping @MainActor ([URL]) -> Void) {
        accept(pb, into: dir, timeout: timeout) { completion($0.files) }
    }

    /// Очередь, на которой источник пишет обещанные файлы (не главная: запись бывает долгой).
    static let promiseQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "SimpleIsland.filePromises"
        q.qualityOfService = .userInitiated
        return q
    }()

}

/// Сбор выполненных обещаний: отдаёт итог один раз — когда пришли все или по сроку.
private final class PromiseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    private var left: Int
    private var done = false
    private let completion: @MainActor ([URL]) -> Void

    init(expected: Int, completion: @escaping @MainActor ([URL]) -> Void) {
        left = max(1, expected)
        self.completion = completion
    }

    func add(_ url: URL?) {
        lock.lock()
        if let url { urls.append(url) }
        left -= 1
        let finished = left <= 0
        lock.unlock()
        if finished { finish() }
    }

    func finish() {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true
        let out = urls
        lock.unlock()
        DispatchQueue.main.async { MainActor.assumeIsolated { self.completion(out) } }
    }
}
// --- /shelfbar ---

// --- shelfshot ---
// «Снимок потерян» (16.11, 16:41): миниатюра снимка экрана отдаёт `public.file-url` на файл в
// `/var/folders/…/T/TemporaryItems/NSIRD_screencaptureui_*/Снимок экрана ….png`. Чтение его нашим процессом —
// `open: Operation not permitted` (sandboxd → tccd: kTCCServiceSystemPolicyAllFiles, отказ), а бросок уже был принят
// (`return true`) — screencaptureui пишет «Drag completed with copy/move» и снимок никуда не сохраняет. Копия шла
// в фоне позже, ошибка всплывала уже после потери.
//
// Правило: **бросок принимается, только если содержимое уже у нас** (или его пишет источник по обещанию).
// `accept` в самом обработчике броска, синхронно: файлы проверяются на чтение, временные (TemporaryItems, $TMPDIR)
// клонируются в папку приёма сразу; нечитаемые — запасные пути (файл от NSItemProvider, обещание, данные картинки
// из буфера под исходным именем). Ничего не вышло — `false`: источник сохраняет своё как обычно, плюс понятная ошибка.

import os

public extension DragPasteboard {
    /// Итог приёма: файлы на диске и (если что-то не взяли или взяли не туда) — текст для пользователя.
    struct DropResult: Sendable {
        public var files: [URL] = []
        /// nil — всё хорошо. Иначе — заголовок и пояснение ошибки/предупреждения.
        public var problem: (title: String, detail: String)?
        public init(files: [URL] = [], problem: (title: String, detail: String)? = nil) {
            self.files = files; self.problem = problem
        }
    }

    /// Выполнение обещаний: (буфер, папка, срок, итог) → начато ли (есть ли приёмники). Подменяется в самотесте —
    /// система выполняет обещание только в настоящем drag-сеансе.
    typealias PromiseFetcher = @MainActor (NSPasteboard, URL, TimeInterval, @escaping @MainActor ([URL]) -> Void) -> Bool

    static let dropLog = Logger(subsystem: "local.simpleisland", category: "drop")

    /// Принять бросок **сейчас** (звать из `performDrop`/`onDrop`, на главном потоке). Возвращает, принимать ли
    /// бросок: `false` — ничего не взяли, источник должен оставить своё у себя (снимок экрана сохранится как обычно).
    /// `completion` зовётся всегда ровно один раз (и при `false` — с текстом ошибки).
    @MainActor @discardableResult
    static func accept(_ pb: NSPasteboard, providers: [NSItemProvider] = [], into dir: URL, timeout: TimeInterval = 30,
                       promiseFetcher: PromiseFetcher? = nil,
                       completion: @escaping @MainActor (DropResult) -> Void) -> Bool {
        let fm = FileManager.default
        let c = inspect(pb)
        dropLog.info("drop: types=\((pb.types ?? []).map(\.rawValue).joined(separator: ","), privacy: .public) files=\(c.fileURLs.count) promises=\(c.promiseCount) image=\(c.imageType?.rawValue ?? "-", privacy: .public)")
        var ready: [URL] = []
        var lost: [URL] = []
        for u in c.fileURLs {
            if let err = openError(u) {
                dropLog.error("drop: нет чтения \(u.path, privacy: .public): \(String(cString: strerror(err)), privacy: .public)")
                lost.append(u); continue
            }
            if isVolatile(u) {
                // Временный файл источника (снимок экрана, вложение): забрать до возврата из броска.
                if let copy = stage(u, into: dir) { ready.append(copy) } else { lost.append(u) }
            } else {
                ready.append(u)
            }
        }
        let needFallback = !lost.isEmpty || c.fileURLs.isEmpty
        // Данные картинки читать сейчас (после броска буфер меняется), в PNG — только когда понадобятся.
        let rawImage: Data? = needFallback ? c.imageType.flatMap { pb.data(forType: $0) } : nil
        let imageType = c.imageType ?? .png
        let imageData: () -> Data? = { rawImage.flatMap { pngData($0, type: imageType) } }
        // 1) Файлы, которые не прочитать по ссылке, — копией от NSItemProvider (если система даст).
        if !lost.isEmpty, !providers.isEmpty {
            let got = loadFromProviders(providers, names: lost.map(\.lastPathComponent), into: dir, wait: 3)
            if !got.isEmpty {
                ready += got
                let names = Set(got.map { ($0.lastPathComponent as NSString).deletingPathExtension })
                lost.removeAll { names.contains(($0.lastPathComponent as NSString).deletingPathExtension) }
            }
        }
        // 2) Нечитаемые файлы — данными картинки под исходным именем (одна картинка — на первый потерянный).
        var savedElsewhere: URL?
        var imageUsed = false
        func saveImage(_ png: Data, name: String) {
            imageUsed = true
            if let url = write(png, name: name, into: dir) {
                ready.append(url)
                if !lost.isEmpty { lost.removeFirst() }
            } else if let url = write(png, name: name, into: userScreenshotsDirectory()) {
                // Записать к себе не вышло — данные в памяти не бросаем: в папку снимков пользователя.
                savedElsewhere = url
                if !lost.isEmpty { lost.removeFirst() }
            }
        }
        if needFallback, c.promiseCount == 0 || !lost.isEmpty, let png = imageData() {
            saveImage(png, name: lost.first.map { ($0.lastPathComponent as NSString).deletingPathExtension + ".png" } ?? imageFileName())
        }
        // 3) Обещания файла: источник пишет сам (и после возврата из броска) — принимаем бросок.
        let wantPromise = c.promiseCount > 0 && (c.fileURLs.isEmpty || (!lost.isEmpty && ready.isEmpty))
        if wantPromise {
            let fetch = promiseFetcher ?? { pb, dir, t, done in startPromises(pb, into: dir, timeout: t, completion: done) }
            let lostNames = lost.map(\.lastPathComponent)
            let readyNow = ready
            let started = fetch(pb, dir, timeout) { urls in
                var r = DropResult(files: readyNow + urls)
                if urls.isEmpty {
                    // Источник не выполнил обещание — хотя бы данные картинки, которые прочли при броске.
                    if let png = imageData(), let u = write(png, name: lostNames.first.map { ($0 as NSString).deletingPathExtension + ".png" } ?? imageFileName(), into: dir) {
                        r.files.append(u)
                    } else {
                        r.problem = ("Не удалось взять файл", "Приложение-источник не отдало файл — попробуй ещё раз или сохрани его сначала")
                    }
                }
                completion(r)
            }
            if started {
                dropLog.info("drop: обещание принято, готово сразу \(readyNow.count)")
                return true
            }
        }
        // Обещание не началось (чужой формат) — картинка, если её положили рядом.
        if needFallback, !imageUsed, ready.isEmpty, let png = imageData() {
            saveImage(png, name: lost.first.map { ($0.lastPathComponent as NSString).deletingPathExtension + ".png" } ?? imageFileName())
        }
        var result = DropResult(files: ready)
        if let savedElsewhere {
            result.problem = ("Сохранено не на полку",
                              "«\(savedElsewhere.lastPathComponent)» — в папке «\(savedElsewhere.deletingLastPathComponent().lastPathComponent)»: на полку записать не вышло")
        }
        if !lost.isEmpty { result.problem = lostProblem(lost, accepted: !ready.isEmpty || savedElsewhere != nil) }
        let accepted = !ready.isEmpty || savedElsewhere != nil
        dropLog.info("drop: принято \(ready.count), потеряно бы \(lost.count) → \(accepted ? "true" : "false", privacy: .public)")
        DispatchQueue.main.async { MainActor.assumeIsolated { completion(result) } }
        return accepted
    }

    /// Текст ошибки для файлов, которые не взяли (источник их сохранил: бросок для них не принят или они у него).
    internal static func lostProblem(_ lost: [URL], accepted: Bool) -> (title: String, detail: String) {
        let names = lost.map { "«\($0.lastPathComponent)»" }.joined(separator: ", ")
        let isShot = lost.contains { $0.path.contains("screencaptureui") || $0.lastPathComponent.hasPrefix("Снимок экрана")
            || $0.lastPathComponent.hasPrefix("Screenshot") }
        if isShot {
            return ("Снимок не взят",
                    "macOS не дала прочитать \(names) из своей временной папки. Снимок не потерян — он сохранится как обычно; положи его на полку из папки снимков")
        }
        return (accepted ? "Не все файлы взяты" : "Нет доступа к файлу",
                "Не прочитать \(names) — файл не тронут. Сохрани его сначала в Finder или дай SimpleIsland «Доступ к диску»")
    }

    /// Можно ли открыть файл на чтение (TCC отказывает именно на `open`, `access()` говорит «можно»).
    static func canRead(_ url: URL) -> Bool { openError(url) == nil }

    /// errno от `open(O_RDONLY)`, nil — открывается.
    static func openError(_ url: URL) -> Int32? {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK)
        guard fd >= 0 else { return errno }
        close(fd)
        return nil
    }

    /// Временное место источника: оттуда файл исчезнет после броска (TemporaryItems, $TMPDIR, /tmp).
    static func isVolatile(_ url: URL) -> Bool {
        let p = url.standardizedFileURL.resolvingSymlinksInPath().path
        if p.contains("/TemporaryItems/") { return true }
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path
        let roots = [tmp, "/private/var/folders/", "/private/tmp/", "/tmp/"]
        return roots.contains { !$0.isEmpty && p.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }

    /// Клон (APFS) / копия в папку приёма — сразу, на главном потоке.
    static func stage(_ url: URL, into dir: URL) -> URL? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let dst = uniqueURL(in: dir, name: url.lastPathComponent.isEmpty ? "файл" : url.lastPathComponent)
            try fm.copyItem(at: url, to: dst)
            return dst
        } catch {
            dropLog.error("drop: не скопировать \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func write(_ data: Data, name: String, into dir: URL) -> URL? {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = uniqueURL(in: dir, name: name)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            dropLog.error("drop: не записать \(name, privacy: .public) в \(dir.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Папка снимков экрана пользователя (`com.apple.screencapture location`, иначе Рабочий стол).
    static func userScreenshotsDirectory() -> URL {
        if let loc = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"), !loc.isEmpty {
            let p = (loc as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue { return URL(fileURLWithPath: p, isDirectory: true) }
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    /// Файлы от NSItemProvider (система отдаёт свою читаемую копию на время колбэка) — копируем внутри колбэка.
    /// Ждём не дольше `wait` секунд: колбэки приходят на фоновой очереди.
    @MainActor
    static func loadFromProviders(_ providers: [NSItemProvider], names: [String], into dir: URL, wait: TimeInterval) -> [URL] {
        final class Box: @unchecked Sendable { let lock = NSLock(); var urls: [URL] = [] }
        let box = Box()
        let group = DispatchGroup()
        for p in providers {
            // Тип содержимого (не ссылка): картинка/данные, которые провайдер умеет отдать файлом.
            guard let type = p.registeredTypeIdentifiers.first(where: { id in
                guard let t = UTType(id) else { return false }
                return t.conforms(to: .data) && !t.conforms(to: .url) && !t.conforms(to: .fileURL)
            }) else { continue }
            group.enter()
            _ = p.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                defer { group.leave() }
                guard let url, canRead(url) else { return }
                let want = names.first { ($0 as NSString).deletingPathExtension == (url.lastPathComponent as NSString).deletingPathExtension }
                let name = want ?? url.lastPathComponent
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let dst = uniqueURL(in: dir, name: name)
                if (try? FileManager.default.copyItem(at: url, to: dst)) != nil {
                    box.lock.lock(); box.urls.append(dst); box.lock.unlock()
                }
            }
        }
        if group.wait(timeout: .now() + wait) == .timedOut { dropLog.error("drop: NSItemProvider не ответил за \(wait) с") }
        box.lock.lock(); defer { box.lock.unlock() }
        return box.urls
    }

    /// Начать приём обещаний; false — приёмников нет (чужой формат).
    @MainActor
    static func startPromises(_ pb: NSPasteboard, into dir: URL, timeout: TimeInterval,
                              completion: @escaping @MainActor ([URL]) -> Void) -> Bool {
        let receivers = (pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver]) ?? []
        guard !receivers.isEmpty else { return false }
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch { return false }
        let box = PromiseBox(expected: receivers.reduce(0) { $0 + max(1, $1.fileTypes.count) }, completion: completion)
        for r in receivers {
            r.receivePromisedFiles(atDestination: dir, options: [:], operationQueue: promiseQueue) { url, error in
                box.add(error == nil ? url : nil)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.5, timeout)) { box.finish() }
        return true
    }
}
// --- /shelfshot ---
