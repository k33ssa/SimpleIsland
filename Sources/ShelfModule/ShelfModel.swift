import AppKit
import Combine
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers
import IslandCore

// MARK: - Цели броска

/// Цель броска — плитка во вкладке. Набор и порядок — в настройках модуля.
public enum ShelfTarget: String, Codable, CaseIterable, Identifiable, Sendable {
    case shelf, airdrop, share, zip, convert, text, cutout, custom

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .shelf: return "На полку"
        case .airdrop: return "AirDrop"
        case .share: return "Поделиться"
        case .zip: return "Сжать"
        case .convert: return "Конвертер"
        case .text: return "Текст"
        case .cutout: return "Без фона"
        case .custom: return "Действия"
        }
    }

    /// Подпись в настройках.
    var settingsTitle: String {
        switch self {
        case .shelf: return "На полку — хранить копию"
        case .airdrop: return "AirDrop"
        case .share: return "Поделиться… (системное меню: Telegram, Почта, Сообщения…)"
        case .zip: return "Сжать в ZIP"
        case .convert: return "Конвертер (картинки, PDF → PNG)"
        case .text: return "Текст — распознать в буфер обмена"
        case .cutout: return "Без фона — вырезать предмет"
        case .custom: return "Свои действия — скрипты и Shortcuts"
        }
    }

    var systemImage: String {
        switch self {
        case .shelf: return "tray.and.arrow.down"
        case .airdrop: return "dot.radiowaves.left.and.right"
        case .share: return "square.and.arrow.up"
        case .zip: return "archivebox"
        case .convert: return "arrow.triangle.2.circlepath"
        case .text: return "text.viewfinder"
        case .cutout: return "wand.and.stars"
        case .custom: return "bolt"
        }
    }

    /// Цвета значка (как в макете 04). nil — нейтральный (заливка элементов темы).
    var gradient: [Color]? {
        switch self {
        case .shelf: return nil
        case .airdrop: return [Color(hex: "#4AA8FF"), Color(hex: "#1D4FD8")]
        case .share: return [Color(hex: "#38BDF8"), Color(hex: "#2563EB")]
        case .zip: return [Color(hex: "#FFB36E"), Color(hex: "#FF7A45")]
        case .convert: return [Color(hex: "#A879FF"), Color(hex: "#7B2CFF")]
        case .text: return [Color(hex: "#39D98A"), Color(hex: "#0F9D58")]
        case .cutout: return [Color(hex: "#FF3DCB"), Color(hex: "#FF3D7F")]
        case .custom: return [Color(hex: "#FFD36E"), Color(hex: "#F59E0B")]
        }
    }

    /// Цвет подсветки плитки, над которой файл.
    var tint: Color { gradient?.first ?? Color(hex: "#4AA8FF") }

    /// «Распознаю…» — подпись активности в компакте.
    var busyTitle: String {
        switch self {
        case .shelf: return "Кладу…"
        case .airdrop: return "AirDrop…"
        case .share: return "Делюсь…"
        case .zip: return "Сжимаю…"
        case .convert: return "Конвертирую…"
        case .text: return "Распознаю…"
        case .cutout: return "Вырезаю…"
        case .custom: return "Выполняю…"
        }
    }
}

/// Куда класть результаты (ZIP, конвертер, «без фона»).
public enum ShelfPlacement: String, Codable, CaseIterable, Sendable {
    case shelf, nextToOriginal
    var title: String { self == .shelf ? "На полку" : "Рядом с оригиналом" }
}

/// Настройки модуля (`settings.json` → `moduleSettings.shelf`). Неизвестные/отсутствующие поля — по умолчанию.
public struct ShelfPrefs: Codable, Equatable, Sendable {
    /// Сколько файл лежит на полке, часов; 0 — без срока.
    public var ttlHours: Int = 24
    /// Порядок плиток.
    public var order: [ShelfTarget] = ShelfTarget.allCases
    /// Выключенные плитки.
    public var hidden: [ShelfTarget] = []
    public var placement: ShelfPlacement = .shelf
    public var convertFormat: ShelfConvertFormat = .auto

    public init() {}

    enum CodingKeys: String, CodingKey { case ttlHours, order, hidden, placement, convertFormat }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ttlHours = (try? c.decodeIfPresent(Int.self, forKey: .ttlHours)) ?? 24
        let raw = (try? c.decodeIfPresent([String].self, forKey: .order)) ?? []
        var o = raw.compactMap(ShelfTarget.init(rawValue:))
        for t in ShelfTarget.allCases where !o.contains(t) { o.append(t) }   // новые цели — в конец
        order = o
        hidden = ((try? c.decodeIfPresent([String].self, forKey: .hidden)) ?? []).compactMap(ShelfTarget.init(rawValue:))
        placement = (try? c.decodeIfPresent(ShelfPlacement.self, forKey: .placement)) ?? .shelf
        convertFormat = (try? c.decodeIfPresent(ShelfConvertFormat.self, forKey: .convertFormat)) ?? .auto
    }

    var visibleTargets: [ShelfTarget] { order.filter { !hidden.contains($0) } }
    var ttl: TimeInterval { TimeInterval(max(0, ttlHours)) * 3600 }
}

// MARK: - Модель

@MainActor
final class ShelfModel: ObservableObject {
    struct Busy: Equatable {
        var target: ShelfTarget
        /// nil — без процентов (крутится).
        var progress: Double?
        var count: Int
    }

    @Published private(set) var items: [ShelfItem] = []
    /// Миниатюры только видимых карточек (ленивый ряд: появилась — загрузить, ушла — забыть). Готовые лежат в
    /// `thumbCache` с лимитом по памяти — прокрутка назад не перегенерирует.
    @Published private(set) var thumbnails: [UUID: NSImage] = [:]
    @Published var selection: Set<UUID> = []
    /// Плитка, над которой сейчас файл.
    @Published var hotTarget: ShelfTarget?
    /// «2 файла · 14,2 МБ» — что тащат (из drag-буфера, один раз за перетаскивание).
    @Published var dragSummary: String?
    @Published private(set) var busy: Busy?
    @Published var prefs = ShelfPrefs() {
        didSet {
            guard prefs != oldValue, !isMock else { return }
            context?.saveSettings(prefs)
            if prefs.ttlHours != oldValue.ttlHours, context != nil { purge() }   // новый срок — сразу
        }
    }
    /// Только для снимков: делать вид, что тащат файлы (настоящий флаг — у ядра).
    @Published var mockDragging = false

    private(set) weak var context: ModuleContext?
    let store: ShelfStore
    let actionsDir: URL
    /// Мок-режим (снимки): систему не трогать.
    private(set) var isMock = false

    private var running: [UUID: (ShelfTarget, Double?)] = [:]
    private var runOrder: [UUID] = []
    /// Автоочистка: одна отложенная задача на ближайший срок (по стенным часам — идёт и во сне, сработает сразу
    /// после пробуждения). Полка пуста или срок выключен — задачи нет, пробуждений нет.
    private var purgeWork: DispatchWorkItem?
    /// Когда сработает автоочистка (для самотеста).
    private(set) var purgeAt: Date?
    /// Кэш миниатюр: NSCache с лимитом (стоимость — пиксели × 4), ключ — id + дата изменения файла.
    let thumbCache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.totalCostLimit = ShelfModel.thumbCacheBytes
        c.countLimit = 120
        return c
    }()
    static let thumbCacheBytes = 6 << 20
    /// Размер миниатюры на карточке (pt) — генерируем ровно под него ×2.
    static let thumbSize = CGSize(width: 28, height: 36)
    private var thumbLoading: Set<UUID> = []
    /// Ключи, для которых миниатюры нет (папка, zip, неизвестный тип): сразу значок, без повторного запроса в
    /// QuickLook при каждом показе карточки. Чистится вместе с карточками (`syncItems`).
    private(set) var thumbMissing: Set<NSString> = []
    private var bag = Set<AnyCancellable>()
    private var picker: NSSharingServicePicker?
    private var pickerDelegate: PickerDelegate?
    private var menuTarget: MenuTarget?
    /// Невидимое окно на месте плитки — к нему крепятся меню, чтобы они не зависели от острова.
    private let menuHost = MenuHost()
    @Published private(set) var shortcutsCache: [String] = []
    private let anchors = NSMapTable<NSString, NSView>.strongToWeakObjects()

    init(store: ShelfStore? = nil,
         actionsDir: URL = SimpleIslandPaths.appSupport.appendingPathComponent("Actions", isDirectory: true)) {
        self.store = store ?? ShelfStore()
        self.actionsDir = actionsDir
    }

    // MARK: Жизненный цикл

    /// Только привязать контекст (снимки: систему не трогаем).
    func attach(_ ctx: ModuleContext) { context = ctx }

    func start(_ ctx: ModuleContext) {
        context = ctx
        isMock = false
        prefs = ctx.loadSettings(ShelfPrefs.self) ?? ShelfPrefs()
        try? FileManager.default.createDirectory(at: actionsDir, withIntermediateDirectories: true)
        store.load()
        store.purgeExpired(ttl: prefs.ttl)
        syncItems()                                  // заодно ставит таймер на ближайший срок
        ShelfFiles.cleanStaleTemp()
        ShelfFiles.cleanStaleTemp(in: incomingRoot)   // --- shelfbar --- принятые обещания/картинки старше суток
        ctx.island.$isFileDragActive
            .removeDuplicates()
            .sink { [weak self] active in self?.dragChanged(active) }
            .store(in: &bag)
        ctx.island.$expandedTab
            .removeDuplicates()
            .sink { [weak self] tab in
                guard let self else { return }
                if tab == ctx.moduleId {
                    self.purge()
                    self.objectWillChange.send()      // освежить «возраст» карточек
                } else if !self.thumbnails.isEmpty {
                    self.thumbnails = [:]             // вкладку закрыли — в памяти только кэш с лимитом
                }
            }
            .store(in: &bag)
        // Пробуждение: срок мог выйти во сне (тикер и так даст догоняющий тик — это на случай пустой подписки).
        ctx.onSystemEvent { [weak self] e in
            switch e {
            case .didWake, .screensDidWake, .sessionDidBecomeActive:
                self?.purge()
            case .willSleep, .screenLocked, .sessionDidResignActive:
                // Остров свернётся сам; меню, оставшееся открытым, пусть не держит его после возврата.
                self?.context?.releaseAllExpandHolds()
            default: break
            }
        }
        // Остров уже раскрыт на другой вкладке, а над ним тащат файлы — переключить на Полку
        // (ядро раскрывает на Полке только свёрнутый остров).
        ctx.island.$isDropTargeted
            .removeDuplicates()
            .sink { [weak self] over in
                guard over, let self, let ctx = self.context, ctx.island.isFileDragActive,
                      ctx.island.isExpanded, ctx.island.expandedTab != ctx.moduleId,
                      ctx.settings.data.tabs.contains(where: { $0.id == ctx.moduleId && $0.enabled }) else { return }
                ctx.openTab()
            }
            .store(in: &bag)
        refreshShortcuts()
    }

    func stop() {
        purgeWork?.cancel(); purgeWork = nil; purgeAt = nil
        thumbnails = [:]
        context?.releaseAllExpandHolds()
        menuHost.close()
        picker = nil; pickerDelegate = nil
        bag.removeAll()
        context?.activities.removeAll(moduleId: context?.moduleId ?? "shelf")
        context = nil
    }

    // MARK: Мок для снимков

    func applyMock(items mock: [ShelfItem], dragging: Bool = false, hot: ShelfTarget? = nil, summary: String? = nil,
                   busy: Busy? = nil, selection: Set<UUID> = []) {
        isMock = true
        items = mock
        mockDragging = dragging
        hotTarget = hot
        dragSummary = summary
        self.busy = busy
        self.selection = selection
    }

    static func mockItems(now: Date = Date()) -> [ShelfItem] {
        var a = ShelfItem(name: "обложка.png", addedAt: now.addingTimeInterval(-3 * 3600), size: 2_100_000)
        a.mockArt = .warm
        var b = ShelfItem(name: "отчёт.docx", addedAt: now.addingTimeInterval(-5 * 3600), size: 480_000)
        b.mockArt = .document
        var c = ShelfItem(name: "скрин 14.11.png", addedAt: now.addingTimeInterval(-9 * 3600), size: 1_300_000)
        c.mockArt = .sea
        return [a, b, c]
    }

    // MARK: Полка

    func url(for item: ShelfItem) -> URL { store.url(for: item) }

    private func syncItems() {
        items = store.items
        let ids = Set(items.map(\.id))
        thumbnails = thumbnails.filter { ids.contains($0.key) }
        let idStrings = Set(items.map(\.id.uuidString))
        thumbMissing = thumbMissing.filter { idStrings.contains(String(($0 as String).prefix(36))) }
        selection = selection.intersection(ids)
        schedulePurge()
    }

    func purge() {
        guard !isMock else { return }
        if store.purgeExpired(ttl: prefs.ttl) > 0 { syncItems() } else { schedulePurge() }
    }

    /// Одна задача на ближайший срок (`asyncAfter(wallDeadline:)`, не чаще раза в 30 с — если файл не удалился,
    /// петли не будет). Просроченный файл уходит с диска в срок, а не «до часа спустя»; в покое пробуждение одно —
    /// в момент срока. Плюс очистка при открытии вкладки и после пробуждения.
    private func schedulePurge() {
        purgeWork?.cancel(); purgeWork = nil; purgeAt = nil
        guard !isMock, context != nil, prefs.ttl > 0,
              let next = items.map({ $0.addedAt.addingTimeInterval(prefs.ttl) }).min() else { return }
        let delay = max(30, next.timeIntervalSinceNow + 1)
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.purge() } }
        purgeWork = w
        purgeAt = Date().addingTimeInterval(delay)
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + delay, execute: w)
    }

    /// Идёт ли автоочистка (для самотеста).
    var isPurgeScheduled: Bool { purgeWork != nil }

    /// Скопировать на полку (в фоне; на APFS — клон).
    func addToShelf(_ urls: [URL], move: Bool = false, then: (@MainActor ([ShelfItem]) -> Void)? = nil) {
        let fresh = move ? urls : urls.filter { !store.contains($0) }
        guard !fresh.isEmpty, !isMock else { then?([]); return }
        let root = store.root
        runValue(.shelf, silentUnder: 0.4) { _ in
            try ShelfFiles.importFiles(fresh, into: root, move: move)
        } done: { [weak self] new in
            guard let self else { return }
            self.store.append(new)
            self.syncItems()
            then?(new)
        } failed: {
            then?([])
        }
    }

    func remove(_ ids: Set<UUID>) {
        guard !isMock else { items.removeAll { ids.contains($0.id) }; return }
        store.remove(ids: ids, toTrash: true)
        syncItems()
    }

    func clear() { remove(Set(items.map(\.id))) }

    func toggleSelection(_ item: ShelfItem) {
        if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
    }

    func open(_ item: ShelfItem) { NSWorkspace.shared.open(url(for: item)) }
    func reveal(_ item: ShelfItem) { NSWorkspace.shared.activateFileViewerSelecting([url(for: item)]) }

    /// К чему применить цель по щелчку — только выбранные карточки (случайный щелчок не отправит всю полку).
    var tapSubjects: [URL] {
        items.filter { selection.contains($0.id) }.map { url(for: $0) }
    }

    func thumbKey(_ item: ShelfItem) -> NSString {
        let mtime = (try? url(for: item).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?
            .timeIntervalSince1970 ?? 0
        return "\(item.id.uuidString)#\(Int(mtime))" as NSString
    }

    /// Карточка показалась: миниатюра из кэша или генерация под размер показа ×2. Картинки — ImageIO
    /// (`ImageDownsampler`, полный битмап в память не попадает), остальное — QuickLook.
    func thumbnailAppeared(_ item: ShelfItem) {
        guard !isMock else { return }
        visibleThumbs.insert(item.id)
        guard thumbnails[item.id] == nil, !thumbLoading.contains(item.id) else { return }
        let key = thumbKey(item)
        if let hit = thumbCache.object(forKey: key) { thumbnails[item.id] = hit; return }
        if thumbMissing.contains(key) { return }
        thumbLoading.insert(item.id)
        let id = item.id
        let file = url(for: item)
        let px = Int(max(Self.thumbSize.width, Self.thumbSize.height) * 2)
        let deliver: @MainActor (CGImage?) -> Void = { [weak self] cg in
            guard let self else { return }
            self.thumbLoading.remove(id)
            guard self.items.contains(where: { $0.id == id }) else { return }
            guard let cg else { self.thumbMissing.insert(key); return }
            let img = NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / 2, height: CGFloat(cg.height) / 2))
            self.thumbCache.setObject(img, forKey: key, cost: cg.width * cg.height * 4)
            // Карточку успели убрать с экрана — только в кэш.
            if self.visibleThumbs.contains(id) { self.thumbnails[id] = img }
        }
        let size = Self.thumbSize
        @Sendable func quickLook() {
            let req = QLThumbnailGenerator.Request(fileAt: file, size: size, scale: 2, representationTypes: .thumbnail)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, _ in
                let box = CGBox(rep?.cgImage)
                DispatchQueue.main.async { MainActor.assumeIsolated { deliver(box.image) } }
            }
        }
        guard ShelfOperations.isImage(file) else { quickLook(); return }
        DispatchQueue.global(qos: .utility).async {
            // Не разобрал ImageIO (редкий формат) — QuickLook.
            guard let cg = ImageDownsampler.downsample(url: file, maxPixelSize: px) else { quickLook(); return }
            let box = CGBox(cg)
            DispatchQueue.main.async { MainActor.assumeIsolated { deliver(box.image) } }
        }
    }

    /// Карточка ушла с экрана (ленивый ряд прокрутили, вкладку закрыли) — забыть, в кэше останется.
    func thumbnailDisappeared(_ item: ShelfItem) {
        visibleThumbs.remove(item.id)
        if thumbnails[item.id] != nil { thumbnails[item.id] = nil }
    }

    private var visibleThumbs: Set<UUID> = []

    // MARK: Перетаскивание

    var isDragging: Bool { mockDragging || (context?.island.isFileDragActive ?? false) }

    private func dragChanged(_ active: Bool) {
        guard active else { dragSummary = nil; hotTarget = nil; return }
        let pb = NSPasteboard(name: .drag)
        // --- shelfbar --- не только файлы Finder: обещание (снимок экрана, вложение) и картинка из браузера.
        // --- shelfshot --- во время перетаскивания — только типы: ссылки на файлы читаются в момент броска
        // (`DragPasteboard.accept`), поэтому в сводке число файлов без размера.
        let contents = DragPasteboard.inspectTypes(pb)
        switch contents.kind {
        case .promises: dragSummary = ShelfFormat.files(contents.promiseCount)
        case .image: dragSummary = "Картинка"
        case .none: dragSummary = nil
        case .files: dragSummary = ShelfFormat.files(contents.fileURLs.count)
        }
        // --- /shelfbar ---
    }

    /// Бросок на плитку.
    func drop(_ providers: [NSItemProvider], on target: ShelfTarget) -> Bool {
        drop(NSPasteboard(name: .drag), providers: providers, on: target)
    }

    /// Бросок с данного буфера (самотест подаёт свой пастборд и подменяет выполнение обещаний).
    func drop(_ pb: NSPasteboard, providers: [NSItemProvider], on target: ShelfTarget,
              promiseFetcher: DragPasteboard.PromiseFetcher? = nil) -> Bool {
        hotTarget = nil
        // --- shelfbar --- обещания файла и картинки — через drag-буфер (во время броска), в папку приёма.
        if DragPasteboard.inspectTypes(pb).isFileLike {
            // --- shelfshot --- содержимое забирается до возврата из броска; не взяли — false (источник оставит своё).
            return DragPasteboard.accept(pb, providers: providers, into: newIncomingDir(),
                                         promiseFetcher: promiseFetcher) { [weak self] r in
                guard let self else { return }
                if !r.files.isEmpty { self.acceptDropped(r.files, on: target) }
                if let p = r.problem { self.fail(p.title, detail: p.detail) }
            }
        }
        // --- /shelfbar ---
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !files.isEmpty else { return false }
        let box = URLCollector()
        let group = DispatchGroup()
        for p in files where p.canLoadObject(ofClass: URL.self) {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL { box.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated {
                let urls = box.urls
                guard !urls.isEmpty else {
                    self.fail("Это не файл", detail: "На плитки можно бросать файлы и папки — из Finder, с рабочего стола")
                    return
                }
                self.perform(target, urls: urls)
            }
        }
        return true
    }

    // --- shelfbar ---
    /// `Shelf/incoming`: сюда ядро и плитки кладут принятые обещания файла и картинки (по папке на бросок).
    var incomingRoot: URL { store.root.appendingPathComponent("incoming", isDirectory: true) }

    /// Новая папка приёма для одного броска (создаст `DragPasteboard.receive`).
    func newIncomingDir() -> URL { incomingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true) }

    /// Лежит ли файл в папке приёма (его можно переносить, а не копировать).
    func isIncoming(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(incomingRoot.standardizedFileURL.path + "/")
    }

    /// Брошенное (файлы и принятые обещания/картинки) — в цель. На полку принятые переносятся (папка приёма
    /// пустеет), Finder-файлы копируются; для остальных целей принятые остаются в `incoming` до суточной уборки.
    func acceptDropped(_ urls: [URL], on target: ShelfTarget) {
        let staged = urls.filter(isIncoming)
        let plain = urls.filter { !isIncoming($0) }
        guard target == .shelf, !staged.isEmpty else { perform(target, urls: urls); return }
        if !plain.isEmpty { perform(.shelf, urls: plain) }
        let dirs = Set(staged.map { $0.deletingLastPathComponent() })
        addToShelf(staged, move: true) { _ in
            for d in dirs where ((try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? []).isEmpty {
                try? FileManager.default.removeItem(at: d)
            }
        }
    }
    // --- /shelfbar ---

    /// Щелчок по плитке (без перетаскивания): «На полку» — выбрать файлы; остальное — к выбранным на полке.
    func tap(_ target: ShelfTarget) {
        guard !isMock else { return }
        if target == .shelf { chooseFiles(); return }
        guard !items.isEmpty else {
            notify("Полка пуста", body: "Перетащи файлы на «\(target.title)» или сначала положи их на полку",
                   image: target.systemImage)
            return
        }
        let urls = tapSubjects
        guard !urls.isEmpty else {
            notify("Сначала выбери файлы", body: "Щёлкни по карточкам на полке, потом по «\(target.title)»",
                   image: target.systemImage)
            return
        }
        perform(target, urls: urls)
    }

    /// Каким файлам подходит цель. Неподходящие пропускаются (о них — в итоговом уведомлении).
    static func accepts(_ target: ShelfTarget, _ url: URL) -> Bool {
        switch target {
        case .convert, .text: return ShelfOperations.isImage(url) || ShelfOperations.isPDF(url)
        case .cutout: return ShelfOperations.isImage(url)
        default: return true
        }
    }

    /// « · пропущено: a.docx, b.zip» — для текста уведомления.
    static func skippedNote(_ skipped: [URL]) -> String {
        guard !skipped.isEmpty else { return "" }
        let names = skipped.prefix(3).map(\.lastPathComponent).joined(separator: ", ")
        return " · пропущено: " + names + (skipped.count > 3 ? " и ещё \(skipped.count - 3)" : "")
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = "На полку"
        // Сначала свернуть остров: окно выбора (уровень модальной панели) ниже ловушки кликов раскрытого острова.
        context?.collapse()
        NSApp.activate()
        if panel.runModal() == .OK { addToShelf(panel.urls) }
    }

    // MARK: Действия

    func perform(_ target: ShelfTarget, urls all: [URL]) {
        guard !isMock, !all.isEmpty else { return }
        let urls = all.filter { Self.accepts(target, $0) }
        let skipped = all.filter { !Self.accepts(target, $0) }
        if urls.isEmpty {
            switch target {
            case .convert: fail("Конвертер берёт картинки и PDF", detail: skipped.map(\.lastPathComponent).joined(separator: ", "))
            case .text: fail("Текст распознаётся с картинок и PDF", detail: skipped.map(\.lastPathComponent).joined(separator: ", "))
            default: fail("Фон вырезается только у картинок", detail: skipped.map(\.lastPathComponent).joined(separator: ", "))
            }
            return
        }
        switch target {
        case .shelf: addToShelf(urls)
        case .airdrop: airDrop(urls)
        case .share: share(urls)
        case .zip:
            withOutput(urls, target: .zip) { out, _ in [try ShelfOperations.zip(urls, outDir: out)] }
        case .convert:
            let format = prefs.convertFormat
            withOutput(urls, target: .convert, skipped: skipped) { out, progress in
                try ShelfOperations.convert(urls, format: format, outDir: out, progress: progress)
            }
        case .cutout:
            withOutput(urls, target: .cutout, skipped: skipped) { out, progress in
                var res: [URL] = []
                for (i, u) in urls.enumerated() {
                    res.append(try ShelfOperations.removeBackground(u, outDir: out))
                    progress(Double(i + 1) / Double(urls.count))
                }
                return res
            }
        case .text: recognize(urls, skipped: skipped)
        case .custom: showActionsMenu(urls)
        }
    }

    private func airDrop(_ urls: [URL]) {
        guard let s = NSSharingService(named: .sendViaAirDrop), s.canPerform(withItems: urls) else {
            fail("AirDrop недоступен", detail: "Включи Wi‑Fi и Bluetooth и проверь, что AirDrop не выключен в Пункте управления")
            return
        }
        NSApp.activate()
        s.perform(withItems: urls)
    }

    func shareAllViaAirDrop() {
        guard !isMock, !items.isEmpty else { return }
        airDrop(items.map { url(for: $0) })
    }

    /// Меню «Поделиться» — от невидимого окна на месте плитки: остров может свернуться, пока курсор на меню,
    /// а меню останется на месте. Окно закрывается, когда служба отработала или меню закрыли.
    private func share(_ urls: [URL]) {
        guard let anchor = anchorView(.share), let host = menuHost.view(over: anchor) else {
            fail("Не показать меню «Поделиться»", detail: "Открой вкладку «Полка» и попробуй ещё раз")
            return
        }
        let p = NSSharingServicePicker(items: urls)
        let d = PickerDelegate { [weak self] in
            // Меню закрыли (служба выбрана или отмена) — остров можно сворачивать.
            self?.context?.releaseExpanded(Self.holdShare)
        } finish: { [weak self] in
            self?.context?.releaseExpanded(Self.holdShare)
            self?.menuHost.close(); self?.picker = nil; self?.pickerDelegate = nil
        }
        p.delegate = d
        picker = p
        pickerDelegate = d
        // Пока меню открыто, уход курсора на него не сворачивает остров (плитка-якорь не пропадает).
        context?.holdExpanded(Self.holdShare, timeout: 120)
        NSApp.activate()
        p.show(relativeTo: host.bounds, of: host, preferredEdge: .minY)
    }

    private func recognize(_ urls: [URL], skipped: [URL] = []) {
        runValue(.text) { progress in
            try ShelfOperations.recognizeText(urls, progress: progress)
        } done: { [weak self] text in
            guard let self else { return }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true).count
            guard lines > 0 else {
                self.notify("Текст не найден", body: (urls.count == 1 ? urls[0].lastPathComponent : ShelfFormat.files(urls.count))
                                + Self.skippedNote(skipped),
                            image: ShelfTarget.text.systemImage)
                return
            }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
            self.notify("Скопировано \(lines) \(ShelfFormat.plural(lines, "строка", "строки", "строк"))",
                        body: (text.split(separator: "\n").first.map(String.init) ?? "") + Self.skippedNote(skipped),
                        image: ShelfTarget.text.systemImage, source: "Текст")
        }
    }

    // MARK: Свои действия

    /// Скрипты `*.sh` из папки действий.
    var scripts: [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: actionsDir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "sh" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    var shortcuts: [String] { shortcutsCache }

    func refreshShortcuts() {
        guard !isMock else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let list = ShelfOperations.listShortcuts()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { if self?.shortcutsCache != list { self?.shortcutsCache = list } }
            }
        }
    }

    private func showActionsMenu(_ urls: [URL]) {
        let target = MenuTarget()
        let menu = NSMenu(title: "Свои действия")
        menu.autoenablesItems = false
        func add(_ title: String, to m: NSMenu, enabled: Bool = true, _ action: @escaping @MainActor () -> Void) {
            let item = NSMenuItem(title: title, action: #selector(MenuTarget.fire(_:)), keyEquivalent: "")
            item.target = target
            item.isEnabled = enabled
            item.representedObject = target.register(action)
            m.addItem(item)
        }
        let scripts = self.scripts
        if scripts.isEmpty {
            add("Скриптов нет — положи .sh в папку действий", to: menu, enabled: false) {}
        }
        for s in scripts {
            add(s.deletingPathExtension().lastPathComponent, to: menu) { [weak self] in self?.runCustom(script: s, urls: urls) }
        }
        menu.addItem(.separator())
        let sc = NSMenuItem(title: "Команды Shortcuts", action: nil, keyEquivalent: "")
        let sub = NSMenu(title: "Команды Shortcuts")
        if shortcutsCache.isEmpty {
            add("Команд нет", to: sub, enabled: false) {}
        }
        for name in shortcutsCache {
            add(name, to: sub) { [weak self] in self?.runCustom(shortcut: name, urls: urls) }
        }
        sc.submenu = sub
        menu.addItem(sc)
        menu.addItem(.separator())
        add("Открыть папку действий…", to: menu) { [weak self] in self?.openActionsFolder() }
        menuTarget = target
        refreshShortcuts()
        guard let anchor = anchorView(.custom), let host = menuHost.view(over: anchor) else {
            fail("Не показать меню действий", detail: "Открой вкладку «Полка» и попробуй ещё раз")
            return
        }
        NSApp.activate()
        // Пока меню открыто, остров не сворачивается по уходу курсора (снимается после закрытия меню).
        context?.holdExpanded(Self.holdActions, timeout: 300)
        // Вид не перевёрнут (y вверх): левый верхний угол меню — на 4 pt ниже плитки. popUp ждёт закрытия меню.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: host)
        context?.releaseExpanded(Self.holdActions)
        menuHost.close()
    }

    func openActionsFolder() {
        try? FileManager.default.createDirectory(at: actionsDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(actionsDir)
    }

    func openShelfFolder() {
        try? FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(store.root)
    }

    private func runCustom(script: URL? = nil, shortcut: String? = nil, urls: [URL]) {
        let name = script?.deletingPathExtension().lastPathComponent ?? shortcut ?? "Действие"
        let tmp = ShelfFiles.tempDirURL()
        let cleanup: @MainActor () -> Void = { try? FileManager.default.removeItem(at: tmp) }
        runValue(.custom) { _ -> ShelfOperations.ShortcutOutput in
            if let script { return .text(try ShelfOperations.runScript(script, files: urls)) }
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            return try ShelfOperations.runShortcut(shortcut ?? "", files: urls, outDir: tmp)
        } done: { [weak self] out in
            guard let self else { cleanup(); return }
            switch out {
            case .text(let line):
                cleanup()
                self.notify("Готово: \(name)", body: line.isEmpty ? ShelfFormat.files(urls.count) : line,
                            image: ShelfTarget.custom.systemImage, source: "Свои действия")
            case .file(let file):
                // Команда вернула файл/картинку — на полку (временную папку уберёт addToShelf-колбэк).
                self.addToShelf([file], move: true) { [weak self] new in
                    cleanup()
                    guard !new.isEmpty else { return }
                    self?.notify("Готово: \(name)", body: "На полке: " + new.map(\.name).joined(separator: ", "),
                                 image: ShelfTarget.custom.systemImage, source: "Свои действия")
                }
            }
        } failed: {
            cleanup()
        }
    }

    // MARK: Якоря для меню (NSView плитки)

    func setAnchor(_ view: NSView?, for target: ShelfTarget) {
        anchors.setObject(view, forKey: target.rawValue as NSString)
    }

    private func anchorView(_ target: ShelfTarget) -> NSView? {
        if let v = anchors.object(forKey: target.rawValue as NSString), v.window != nil { return v }
        return nil
    }

    // MARK: Фоновые операции

    /// Результаты в папку «рядом с оригиналом» или во временную → на полку. Временная папка удаляется всегда,
    /// в том числе после ошибки.
    private func withOutput(_ urls: [URL], target: ShelfTarget, skipped: [URL] = [],
                            work: @escaping @Sendable (URL, @escaping ShelfOperations.Progress) throws -> [URL]) {
        let nextTo: URL? = {
            guard prefs.placement == .nextToOriginal, let first = urls.first, !store.contains(first) else { return nil }
            let dir = first.deletingLastPathComponent()
            return FileManager.default.isWritableFile(atPath: dir.path) ? dir : nil
        }()
        let tmp = ShelfFiles.tempDirURL()
        let cleanup: @MainActor () -> Void = { try? FileManager.default.removeItem(at: tmp) }
        let note = Self.skippedNote(skipped)
        runValue(target) { progress in
            let out: URL
            if let nextTo { out = nextTo } else {
                try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
                out = tmp
            }
            return try work(out, progress)
        } done: { [weak self] results in
            guard let self else { cleanup(); return }
            if nextTo != nil {
                // Без открытия Finder на каждую операцию — кнопка в уведомлении.
                self.notify("Готово: \(ShelfFormat.files(results.count))",
                            body: results.map(\.lastPathComponent).joined(separator: ", ") + note,
                            image: target.systemImage, source: target.title,
                            actions: [IslandNotificationAction("Показать в Finder", role: .primary) {
                                NSWorkspace.shared.activateFileViewerSelecting(results)
                            }])
            } else {
                self.addToShelf(results, move: true) { [weak self] new in
                    cleanup()
                    guard !new.isEmpty else { return }
                    self?.notify("На полке: \(ShelfFormat.files(new.count))",
                                 body: new.map(\.name).joined(separator: ", ") + note,
                                 image: target.systemImage, source: target.title)
                }
            }
        } failed: {
            cleanup()
        }
    }

    /// Работа в фоне (GCD, QoS utility — не пул Swift concurrency: Vision и ожидание процессов блокируют поток),
    /// прогресс — в компакт-активность, ошибка — уведомлением; `failed` — уборка после ошибки.
    private func runValue<T: Sendable>(_ target: ShelfTarget, silentUnder: TimeInterval = 0,
                                       work: @escaping @Sendable (@escaping ShelfOperations.Progress) throws -> T,
                                       done: @escaping @MainActor (T) -> Void,
                                       failed: (@MainActor () -> Void)? = nil) {
        let job = UUID()
        // Короткое (копирование клоном) — без активности, чтобы остров не дёргался.
        let showWork = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.begin(job, target) }
        }
        if silentUnder > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + silentUnder, execute: showWork)
        } else {
            begin(job, target)
        }
        let pending = UncheckedBox(showWork)        // DispatchWorkItem не Sendable; трогаем только с главного потока
        let throttle = ProgressThrottle()
        let progress: ShelfOperations.Progress = { [weak self] p in
            guard throttle.accept(p) else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.update(job, p) } }
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try work(progress) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    pending.value.cancel()
                    self?.end(job)
                    switch result {
                    case .success(let v): done(v)
                    case .failure(let e):
                        failed?()
                        self?.fail("\(target.title): не получилось", detail: e.localizedDescription)
                    }
                }
            }
        }
    }

    private func begin(_ job: UUID, _ target: ShelfTarget) {
        running[job] = (target, nil)
        runOrder.append(job)
        refreshBusy()
    }

    private func update(_ job: UUID, _ p: Double) {
        guard running[job] != nil else { return }
        running[job]?.1 = min(1, max(0, p))
        refreshBusy()
    }

    private func end(_ job: UUID) {
        running[job] = nil
        runOrder.removeAll { $0 == job }
        refreshBusy()
    }

    private func refreshBusy() {
        guard let last = runOrder.last, let (target, p) = running[last] else {
            if busy != nil { busy = nil }
            context?.removeActivity(id: Self.activityId)
            return
        }
        let new = Busy(target: target, progress: p, count: runOrder.count)
        let changedKind = busy?.target != new.target || busy == nil
        busy = new
        if changedKind, let ctx = context { ctx.post(Self.activity(model: self, moduleId: ctx.moduleId)) }
    }

    static let activityId = "shelf.busy"
    static let holdShare = "share"
    static let holdActions = "actions"

    static func activity(model: ShelfModel, moduleId: String) -> IslandActivity {
        IslandActivity(id: activityId, moduleId: moduleId, priority: 45, sideWidth: 118,
                       bubble: AnyView(BusyBubble(model: model))) {
            BusyLeading(model: model)
        } trailing: {
            BusyTrailing(model: model)
        }
    }

    // MARK: Уведомления

    func notify(_ title: String, body: String, image: String, source: String? = "Полка", target: ShelfTarget? = nil,
                actions: [IslandNotificationAction] = []) {
        let t = target ?? ShelfTarget.allCases.first { $0.systemImage == image }
        context?.showNotification(IslandNotification(moduleId: context?.moduleId ?? "shelf", title: title,
                                                     source: source, body: body,
                                                     avatarColors: t?.gradient ?? [Color(hex: "#4AA8FF"), Color(hex: "#A879FF")],
                                                     systemImage: image, actions: actions,
                                                     duration: actions.isEmpty ? 4 : 8, opensTab: context?.moduleId))
    }

    func fail(_ title: String, detail: String) {
        var n = IslandNotification(moduleId: context?.moduleId ?? "shelf", title: title,
                                   source: "Полка", body: detail,
                                   avatarColors: [IslandPalette.err, Color(hex: "#B4233C")],
                                   systemImage: "exclamationmark.triangle.fill", duration: detail.count > 70 ? 10 : 6)
        if detail.count > 70 { n.bodyLines = 3 }   // --- shelfshot --- длинное пояснение (снимок не взят) — целиком
        context?.showNotification(n)
    }
}

// MARK: - Вспомогательное

private final class URLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [URL] = []
    func append(_ u: URL) { lock.lock(); items.append(u); lock.unlock() }
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return items }
}

private final class UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Не чаще шага 2 % — Vision зовёт прогресс очень часто.
private final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -1.0
    func accept(_ p: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard p >= 1 || p - last >= 0.02 else { return false }
        last = p
        return true
    }
}

/// Невидимое окно размером с плитку, поверх острова: к нему крепятся меню «Поделиться» и «Действия».
/// Если остров свернётся (курсор ушёл на меню), привязка меню не пропадёт вместе с плиткой.
@MainActor
private final class MenuHost {
    private var panel: NSPanel?

    func view(over anchor: NSView) -> NSView? {
        guard let win = anchor.window else { return nil }
        close()
        let rect = win.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let p = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.level = win.level
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        p.orderFrontRegardless()
        panel = p
        return p.contentView
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}

/// Закрыть окно-якорь, когда меню «Поделиться» закрыли или выбранная служба отработала.
private final class PickerDelegate: NSObject, NSSharingServicePickerDelegate, NSSharingServiceDelegate {
    private let closed: @MainActor () -> Void
    private let finish: @MainActor () -> Void
    init(closed: @escaping @MainActor () -> Void, finish: @escaping @MainActor () -> Void) {
        self.closed = closed; self.finish = finish
    }

    func sharingServicePicker(_ picker: NSSharingServicePicker, delegateFor sharingService: NSSharingService)
        -> NSSharingServiceDelegate? { self }

    func sharingServicePicker(_ picker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        // Меню закрыто в любом случае — удержание острова снять; окно-якорь — когда служба отработает.
        let c = closed
        DispatchQueue.main.async { MainActor.assumeIsolated { c() } }
        if service == nil { done() }
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) { done() }
    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) { done() }

    private func done() {
        let f = finish
        DispatchQueue.main.async { MainActor.assumeIsolated { f() } }
    }
}

/// Цель для пунктов NSMenu (замыкания вместо селекторов).
@MainActor
private final class MenuTarget: NSObject {
    private var actions: [Int: @MainActor () -> Void] = [:]
    func register(_ a: @escaping @MainActor () -> Void) -> Int {
        let k = actions.count
        actions[k] = a
        return k
    }
    @objc func fire(_ sender: NSMenuItem) {
        if let k = sender.representedObject as? Int { actions[k]?() }
    }
}

/// CGImage через границу очередей (неизменяемая картинка).
private final class CGBox: @unchecked Sendable {
    let image: CGImage?
    init(_ image: CGImage?) { self.image = image }
}
