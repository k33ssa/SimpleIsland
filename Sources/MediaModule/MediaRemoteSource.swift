import AppKit
import Foundation
import IslandCore

/// «Что играет» через MediaRemote: процесс-помощник `/usr/bin/perl` грузит нашу SimpleIslandMR.dylib
/// (Helpers/MediaRemote, docs/TECH.md §1) и пишет JSON-строки в stdout; команды уходят строками в его stdin.
/// Процесс — `ManagedProcess` (своя группа процессов, гасится при выходе/сигнале/падении приложения, на EOF чтение
/// снимается). Падение — перезапуск с паузой 1 → 2 → 4 … 60 с (`ManagedProcess`); три быстрых падения подряд или
/// «MediaRemote недоступен» (код 3) — источник считается неработающим (`onFailure`), модуль переходит на
/// AppleScript и пробует снова позже (`MediaModel`: через 10 мин, после пробуждения Мака, при новом `start()`).
@MainActor
final class MediaRemoteSource {
    struct State {
        var playing: Bool
        var pid: Int32
        var bundle: String?
        var parentBundle: String?
        var info: [String: Any]
        var artworkId: String?
        /// Помощник решил, что позиция застыла при «играет» (Chrome) — показан как пауза.
        var stalled = false
    }

    var onState: ((State) -> Void)?
    var onArtwork: ((String, Data) -> Void)?
    var onFailure: ((String) -> Void)?

    /// Помощник сообщил, что нашёл MRMediaRemoteSendCommandToApp (строка `caps`).
    private(set) var hasSendToApp = false
    /// `sendto` уронил помощника (выход в течение `sendToCrashWindow` после команды) — до конца запуска не шлём.
    private(set) var sendToAppBroken = false
    private var lastSendToAt: Date?
    static let sendToCrashWindow: TimeInterval = 3
    /// Можно слать команды конкретному приложению (медиаклавиши «последнему музыкальному»).
    var canSendToApp: Bool { isRunning && process != nil && hasSendToApp && !sendToAppBroken }

    /// Источник включён (процесс работает или ждёт перезапуска после падения).
    private(set) var isRunning = false
    private(set) var failed = false
    /// Текущий процесс помощника (самотест смотрит его pid/группу).
    private(set) var process: ManagedProcess?
    private var quickFailures = 0
    private var launchedAt = Date()
    /// Разбор JSON и декодирование base64 обложки — не на главном потоке, по порядку строк. Обложку помощник уже
    /// уменьшает сам (ImageIO, ≤ 600 px, JPEG): строка — сотни КБ, а не десятки МБ исходного PNG.
    private let parseQueue = DispatchQueue(label: "simpleisland.media.mr-parse", qos: .userInitiated)
    /// Сколько процессов помощника запущено за жизнь источника (для самотеста и журнала).
    private(set) var launches = 0
    /// Остановленные процессы, которые ещё не вышли.
    private var retiring: [ManagedProcess] = []
    /// Самотест: сколько остановленных процессов ждут выхода.
    var retiringCount: Int { retiring.count }
    /// Интерпретатор помощника (самотест подменяет на несуществующий — проверить сбой запуска).
    nonisolated(unsafe) static var perlPath = "/usr/bin/perl"

    /// Скрипт perl: загрузить библиотеку и вызвать simpleisland_mr_run (режим — в SIMPLEISLAND_MR_MODE).
    nonisolated static let perlScript = """
    use DynaLoader; my $h = DynaLoader::dl_load_file($ARGV[0], 0) or die DynaLoader::dl_error(); \
    my $s = DynaLoader::dl_find_symbol($h, "simpleisland_mr_run") or die DynaLoader::dl_error(); \
    DynaLoader::dl_install_xsub("main::run", $s); run();
    """

    /// Где лежит библиотека: $SIMPLEISLAND_MR_DYLIB → .app/Contents/Resources → рядом с исполняемым файлом.
    nonisolated static func locateDylib() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["SIMPLEISLAND_MR_DYLIB"], !env.isEmpty {
            candidates.append(URL(fileURLWithPath: env))
        }
        if let r = Bundle.main.resourceURL { candidates.append(r.appendingPathComponent("SimpleIslandMR.dylib")) }
        if let e = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent() {
            candidates.append(e.appendingPathComponent("SimpleIslandMR.dylib"))
        }
        return candidates.first { fm.isReadableFile(atPath: $0.path) }
    }

    nonisolated static var isAvailable: Bool {
        locateDylib() != nil && FileManager.default.isExecutableFile(atPath: "/usr/bin/perl")   // настоящий, не perlPath
    }

    /// Окружение помощника: режим, без чужих настроек perl (PERL5LIB, PERLLIB, PERL5OPT, PERL5DB…).
    nonisolated static func helperEnvironment(mode: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["SIMPLEISLAND_MR_MODE"] = mode
        for k in env.keys where k.hasPrefix("PERL") { env.removeValue(forKey: k) }
        return env
    }

    /// Снять отметку «не работает» — следующий `configureSources()` попробует снова.
    func resetFailure() { failed = false; quickFailures = 0 }

    func start() {
        failed = false
        quickFailures = 0
        launch()
    }

    func stop() {
        isRunning = false
        // Закрытие stdin — штатный выход помощника; SIGTERM группе — если завис, через 2 с SIGKILL (ManagedProcess).
        // Объект держим до выхода процесса: брошенный ManagedProcess сразу бьёт группу SIGKILL.
        // Не работающий (ждёт перезапуска после падения) — `stop()` только отменит перезапуск: `onExit` уже не придёт,
        // держать его в `retiring` незачем (иначе копились бы при каждом сне во время серии падений).
        if let p = process {
            if p.isRunning { retiring.append(p) }
            p.stop()
        }
        process = nil
    }

    /// Переподписаться на поток Now Playing (после сна MediaRemote мог потерять регистрацию уведомлений):
    /// новый процесс помощника, старый гасится.
    func restart() {
        guard isRunning else { return }
        stop()
        launch()
    }

    /// Команда помощнику: play | pause | toggle | next | prev | seek <с> | speed <x> | refresh.
    /// Команда конкретному приложению (MediaRemote): коды MRMediaRemoteCommand — 2 toggle, 4 next, 5 prev,
    /// 8/9 начать/закончить перемотку вперёд, 10/11 — назад. Сигнатура функции — догадка (помощник, шапка).
    func sendTo(bundle: String, code: Int) {
        guard canSendToApp, !bundle.contains(" "), !bundle.contains("\n") else { return }
        lastSendToAt = Date()
        send("sendto \(bundle) \(code)")
    }

    func send(_ command: String) {
        // Помощник умер между проверкой и записью — `send` вернёт false (EPIPE без SIGPIPE), приложение не падает.
        _ = process?.send(command)
    }

    // MARK: Процесс

    private func launch() {
        guard let dylib = Self.locateDylib() else {
            fail("Нет SimpleIslandMR.dylib (scripts/build-media-helper.sh)")
            return
        }
        let p = ManagedProcess(executable: Self.perlPath, arguments: ["-e", Self.perlScript, dylib.path],
                               environment: Self.helperEnvironment(mode: "stream"), restart: .always)
        p.providesStdin = true
        // Обложка от помощника — уменьшенный JPEG (≤ 600 px), base64 ≈ сотни КБ; 4 МБ — с запасом на исходную
        // картинку, которую помощник не смог уменьшить (больше 2 МБ он не шлёт).
        p.maxLineBytes = Self.maxLineBytes
        let queue = parseQueue
        p.onLine = { [weak self, weak p] line in
            // Строка от уже остановленного процесса (сон, `restart()`) — не применять.
            guard let self, let p, p === self.process else { return }
            let text = UncheckedBox(line)
            queue.async { [weak self, weak p] in
                guard let obj = Self.parse(text.value) else { return }
                let box = UncheckedBox(obj)
                DispatchQueue.main.async { [weak self, weak p] in
                    MainActor.assumeIsolated {
                        // И здесь: пока строка разбиралась, процесс могли остановить.
                        guard let self, let p, p === self.process else { return }
                        self.handle(box.value)
                    }
                }
            }
        }
        p.onSpawnFailure = { [weak self, weak p] rc in
            // perl не запустился (posix_spawn) — `onExit` не будет, «быстрые падения» не считаются: сразу на запасной путь.
            guard let self, let p, p === self.process else { return }
            p.stop()
            self.fail("perl не запустился: \(String(cString: strerror(rc)))")
        }
        p.onErrorLine = { line in NSLog("SimpleIsland media helper: %@", line) }
        p.onExit = { [weak self, weak p] code in
            guard let self, let p else { return }
            self.retiring.removeAll { $0 === p }
            guard p === self.process else { return }
            self.didExit(p, code: code)
        }
        process = p
        isRunning = true
        launchedAt = Date()
        launches += 1
        // Сбой запуска — `onSpawnFailure` выше (сразу запасной путь), здесь ничего.
        _ = p.start()
    }

    /// Выход помощника. Перезапуск с паузой делает сам `ManagedProcess` (`.always`); здесь решаем, не сдаться ли.
    private func didExit(_ p: ManagedProcess, code: Int32) {
        hasSendToApp = false
        if let t = lastSendToAt, Date().timeIntervalSince(t) < Self.sendToCrashWindow {
            sendToAppBroken = true
            NSLog("SimpleIsland media: помощник вышел (код %d) сразу после sendto — команды приложению выключены", code)
        }
        lastSendToAt = nil
        if code == 3 { p.stop(); fail("MediaRemote недоступен"); return }
        let lived = Date().timeIntervalSince(launchedAt)
        if lived < 5 { quickFailures += 1 } else { quickFailures = 0 }
        if quickFailures >= 3 { p.stop(); fail("помощник падает (код \(code))"); return }
        // Следующий запуск — после паузы ManagedProcess (1, 2, 4 с): три подряд всё равно укладываются в «быстрые».
        launchedAt = Date()
        NSLog("SimpleIsland media: помощник вышел (код %d), перезапуск с паузой", code)
    }

    private func fail(_ reason: String) {
        failed = true
        isRunning = false
        process = nil
        NSLog("SimpleIsland media: MediaRemote отключён — %@", reason)
        onFailure?(reason)
    }

    // MARK: Протокол

    /// Потолок строки помощника (`ManagedProcess.maxLineBytes`).
    nonisolated static let maxLineBytes = 4 << 20

    /// Разбор строки помощника (не на главном потоке): JSON; у обложки base64 сразу декодируется в `bytes` (Data).
    nonisolated static func parse(_ line: String) -> [String: Any]? {
        guard var obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
        if obj["type"] as? String == "artwork", let b64 = obj["data"] as? String {
            obj["data"] = nil
            if let d = Data(base64Encoded: b64) { obj["bytes"] = d }
        }
        return obj
    }

    func handle(_ obj: [String: Any]) {
        switch obj["type"] as? String {
        case "now":
            let st = State(playing: (obj["playing"] as? Bool) ?? false,
                           pid: Int32((obj["pid"] as? NSNumber)?.intValue ?? 0),
                           bundle: obj["bundle"] as? String,
                           parentBundle: obj["parentBundle"] as? String,
                           info: obj["info"] as? [String: Any] ?? [:],
                           artworkId: obj["artworkId"] as? String,
                           stalled: (obj["stalled"] as? Bool) ?? false)
            onState?(st)
        case "artwork":
            // `bytes` — уже декодировано в `parse` (фон); `data` (base64) — строка, разобранная не через `parse`.
            if let id = obj["id"] as? String,
               let data = (obj["bytes"] as? Data) ?? (obj["data"] as? String).flatMap({ Data(base64Encoded: $0) }) {
                onArtwork?(id, data)
            }
        case "caps":
            hasSendToApp = (obj["sendToApp"] as? Bool) ?? false
        case "error":
            NSLog("SimpleIsland media helper: %@", (obj["message"] as? String) ?? "?")
        default:
            break
        }
    }

    /// Состояние помощника → NowPlaying (nil — никто не играет).
    static func nowPlaying(from st: State, appName: String?) -> NowPlaying? {
        let i = st.info
        func str(_ k: String) -> String { (i[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        func num(_ k: String) -> Double? { (i[k] as? NSNumber)?.doubleValue }
        let title = str("Title")
        guard !title.isEmpty else { return nil }
        var n = NowPlaying(title: title)
        n.artist = str("Artist")
        n.album = str("Album")
        n.duration = max(0, num("Duration") ?? 0)
        n.elapsed = max(0, num("ElapsedTime") ?? 0)
        n.timestamp = num("Timestamp").map { Date(timeIntervalSince1970: $0) } ?? Date()
        let rate = num("PlaybackRate") ?? (st.playing ? 1 : 0)
        n.isPlaying = st.playing
        n.rate = rate > 0 ? rate : 1
        // Помощник браузера (WebKit/Chrome Helper) — показываем родительское приложение.
        n.bundleId = st.parentBundle ?? st.bundle
        n.appName = appName
        n.artworkId = st.artworkId
        n.mediaType = str("MediaType")
        n.pid = st.pid > 0 ? st.pid : nil
        n.youTubeId = YouTube.videoId(inInfo: i)
        n.liveFlag = (i["IsAlwaysLive"] as? NSNumber)?.boolValue == true || (i["IsLiveStream"] as? NSNumber)?.boolValue == true
        return n
    }
}

/// Склейка кусков трубы в строки (вызывается с одной очереди FileHandle — последовательно).
final class LineReader: @unchecked Sendable {
    private var buffer = Data()
    private let onLine: @Sendable (Data) -> Void
    init(onLine: @escaping @Sendable (Data) -> Void) { self.onLine = onLine }

    func feed(_ chunk: Data) {
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if !line.isEmpty { onLine(Data(line)) }
        }
        // Защита от мусора без переводов строк: обложка — сотни КБ, 32 МБ — явно что-то не то.
        if buffer.count > 32 << 20 { buffer.removeAll() }
    }
}

struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ v: T) { value = v }
}
