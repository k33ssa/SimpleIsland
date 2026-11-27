import Combine
import Foundation
import IslandCore

/// Состояние Vafa из её файла статуса. Без опроса: `FileWatcher` (запись и атомарная замена файла).
///
/// Энергия: `vpn-guard` переписывает файл каждый круг (~1 с) — слушать его подряд значило бы будить приложение
/// раз в секунду и в покое. Поэтому во всех фазах, кроме «охрана сработала» (всё работает, проверяю страну/пауза
/// GRACE, служба не отвечает), после каждого прочтения слушатель снимается на `calmPause` (4 с), затем файл читается
/// один раз и слушатель вешается снова. Круг ~5 с = 3 пробуждения (конец паузы, событие kqueue, склейка FileWatcher
/// 0,1 с) — ~0,6/с; реакция на срабатывание охраны — не позже ~5 с. Пока охрана сработала — слушаем без пауз, чтобы
/// «всё снова работает» пришло сразу. Служба умерла (записей нет — событий нет) — это замечает `SharedTicker` раз в
/// `staleCheckEvery` (30 с) по времени последней записи, без чтения файла. Во сне и при блокировке экрана — ничего.
///
/// Нет файла (и даже каталога `/usr/local/var/vpn-guard`) — следим за ближайшим существующим каталогом пути:
/// установили Vafa → каталог/файл появился → читаем.
@MainActor
public final class VafaModel: ObservableObject {
    @Published public private(set) var status: VafaStatus?
    @Published public private(set) var phase: VafaPhase = .notInstalled

    public let statusURL: URL
    /// Пауза слушателя после спокойного прочтения.
    public var calmPause: TimeInterval = 4
    /// Как часто проверять, не замолчала ли служба (файл давно не переписывался).
    public var staleCheckEvery: TimeInterval = 30
    /// Признаки установленной Vafa (нет файла статуса, но Vafa стоит → «не запущена»). Самотест подменяет.
    public var installMarkers = VafaPaths.installMarkers
    /// Поле `time` последнего прочитанного файла (обновляется на каждом чтении, в отличие от `status`).
    public private(set) var fileTime: Double = 0
    /// Смена фазы (старая, новая, статус). Зовётся только при реальной смене; первая загрузка — с `old == nil`.
    public var onPhaseChange: ((VafaPhase?, VafaPhase, VafaStatus?) -> Void)?
    /// Статус поменялся внутри той же фазы (напр. заморозили ещё одно приложение).
    public var onStatusChange: ((VafaStatus?) -> Void)?

    private var watcher: FileWatcher?
    private var ancestorWatcher: FileWatcher?
    private var resumeWork: DispatchWorkItem?
    private var staleTick: AnyCancellable?
    private var loaded = false
    public private(set) var isRunning = false
    /// Сколько раз файл прочитан (самотест).
    public private(set) var readCount = 0
    /// Слушатель файла сейчас висит (самотест: пауза в спокойствии).
    public var isListening: Bool { watcher != nil }
    /// Подписка на проверку «служба замолчала» висит (самотест).
    public var isCheckingStale: Bool { staleTick != nil }

    public init(statusURL: URL = VafaPaths.statusFile) {
        self.statusURL = statusURL
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        reload()
        listen()
    }

    public func stop() {
        isRunning = false
        resumeWork?.cancel(); resumeWork = nil
        watcher?.stop(); watcher = nil
        ancestorWatcher?.stop(); ancestorWatcher = nil
        staleTick = nil
    }

    /// Сон/блокировка: всё снять (состояние остаётся последним прочитанным).
    public func pause() {
        guard isRunning else { return }
        resumeWork?.cancel(); resumeWork = nil
        watcher?.stop(); watcher = nil
        ancestorWatcher?.stop(); ancestorWatcher = nil
        staleTick = nil
    }

    /// Пробуждение/разблокировка: перечитать и слушать заново.
    public func resume() {
        guard isRunning else { return }
        pause()
        reload()
        listen()
    }

    // MARK: Слушатели

    private func listen() {
        guard isRunning, watcher == nil else { return }
        let dir = statusURL.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: dir.path) {
            ancestorWatcher?.stop(); ancestorWatcher = nil
            // FileWatcher сам ждёт появления файла в существующем каталоге и переживает замену файла.
            let w = FileWatcher(url: statusURL) { [weak self] in self?.fileChanged() }
            w.start()
            watcher = w
        } else {
            watchAncestor(of: dir)
        }
    }

    /// Каталога статуса нет: следим за первым отсутствующим звеном пути (его родитель существует).
    private func watchAncestor(of dir: URL) {
        var missing = dir
        while !FileManager.default.fileExists(atPath: missing.deletingLastPathComponent().path), missing.path != "/" {
            missing = missing.deletingLastPathComponent()
        }
        guard ancestorWatcher?.url != missing else { return }
        ancestorWatcher?.stop()
        let w = FileWatcher(url: missing) { [weak self] in
            guard let self, self.isRunning else { return }
            // Звено появилось — перестроить слушатели (может, появился уже и сам файл).
            self.ancestorWatcher?.stop(); self.ancestorWatcher = nil
            self.reload()
            self.listen()
        }
        w.start()
        ancestorWatcher = w
    }

    private func fileChanged() {
        guard isRunning else { return }
        reload()
        // Не «сработала» — снять слушатель на паузу; на возобновлении прочитать один раз.
        guard phase != .triggered, calmPause > 0 else { return }
        watcher?.stop(); watcher = nil
        resumeWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isRunning else { return }
                self.resumeWork = nil
                self.reload()
                self.listen()
            }
        }
        resumeWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + calmPause, execute: w)
    }

    // MARK: Служба замолчала

    /// Тикер нужен, пока служба считается живой (есть файл и он свежий): иначе фаза «не отвечает» не наступит —
    /// без записей нет событий. В «не отвечает»/«нет файла» не нужен: оживёт — придёт событие записи.
    private func updateStaleTick() {
        let need = isRunning && (phase == .ok || phase == .checking || phase == .triggered) && staleCheckEvery > 0
        if need, staleTick == nil {
            staleTick = SharedTicker.shared.subscribe(every: staleCheckEvery) { [weak self] now in self?.checkStale(now: now) }
        } else if !need {
            staleTick = nil
        }
    }

    /// Последняя запись старше `staleAfter` — перечитать (файл читается только в этом случае).
    public func checkStale(now: Date = Date()) {
        guard isRunning, fileTime > 0, now.timeIntervalSince1970 - fileTime > VafaPhase.staleAfter else { return }
        reload(now: now)
        // Файл битый (reload оставил прежнее) и всё так же старый — всё равно «не отвечает».
        if phase != .stale, phase != .notInstalled, phase != .notRunning,
           now.timeIntervalSince1970 - fileTime > VafaPhase.staleAfter, var s = status {
            s.time = fileTime
            apply(s, now: now)
        }
    }

    // MARK: Чтение

    /// Прочитать файл (≈0,5 КБ) и опубликовать, только если что-то поменялось (время круга не считается).
    public func reload(now: Date = Date()) {
        readCount += 1
        let data = try? Data(contentsOf: statusURL, options: .uncached)
        // Файл есть, но не разобрался (пустой/обрезанный) — оставить прежнее состояние.
        if let data, VafaStatus.parse(data) == nil, FileManager.default.fileExists(atPath: statusURL.path), loaded { return }
        apply(data.flatMap(VafaStatus.parse), now: now)
    }

    /// Применить статус (самотест и снимки подают свой).
    public func apply(_ new: VafaStatus?, now: Date = Date()) {
        let installed = new == nil && installMarkers.contains { FileManager.default.fileExists(atPath: $0) }
        let newPhase = VafaPhase.of(new, now: now, installed: installed)
        fileTime = new?.time ?? 0
        let oldPhase = loaded ? phase : nil
        // Время круга меняется каждую секунду — сравниваем без него.
        let changed = !loaded || Self.strip(new) != Self.strip(status)
        loaded = true
        if changed { status = new }
        if newPhase != phase || oldPhase == nil {
            phase = newPhase
            onPhaseChange?(oldPhase, newPhase, new)
        } else if changed {
            onStatusChange?(new)
        }
        updateStaleTick()
    }

    private static func strip(_ s: VafaStatus?) -> VafaStatus? {
        guard var s else { return nil }
        s.time = 0
        return s
    }
}
