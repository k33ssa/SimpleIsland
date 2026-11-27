import Darwin
import Foundation

/// Дочерний процесс под контролем (грабли E3: у Atoll три вечных `log stream` оставались сиротами после выхода,
/// EOF-петля чтения pipe давала 80–93 % CPU).
///
/// * Запуск через `posix_spawn` в **своей группе процессов** (`POSIX_SPAWN_SETPGROUP`): завершение бьёт всю
///   группу (`killpg`), внуки (perl, shell-обёртки) не остаются. Наследуются только stdin/stdout/stderr
///   (`POSIX_SPAWN_CLOEXEC_DEFAULT`) — дескрипторы приложения не утекают в ребёнка.
/// * Гарантированное завершение: `ManagedProcess.terminateAll()` из `applicationWillTerminate` (ядро зовёт само);
///   обработчики SIGTERM/SIGINT/SIGHUP и аварийных сигналов (SIGSEGV, SIGABRT…) бьют группы детей прямо из
///   обработчика (`killpg` безопасен для сигналов), затем сигнал уходит прежнему обработчику (или действию по
///   умолчанию); при следующем запуске `reapOrphans()` добивает тех, кто пережил `kill -9` приложения: pid-файл
///   на процесс (`children.<pid>.pids`) хранит группу и **время старта** ведущего процесса — оно не меняется при
///   `exec`, поэтому оболочки-прослойки (`/bin/sh` → bash, `/usr/bin/env`, `python3`, `git` из xcode-select)
///   распознаются, а чужой процесс с тем же pid — нет.
/// * Чтение вывода — `readabilityHandler`, который **снимается на EOF**; строки собираются из кусков.
/// * Перезапуск по желанию: пауза растёт 1 → 2 → 4 … до `maxRestartDelay`, сбрасывается после 30 с жизни.
///
/// ```swift
/// let p = ManagedProcess(executable: "/usr/bin/perl", arguments: [script], restart: .onFailure)
/// p.onLine = { line in … }            // главный поток
/// p.start()
/// p.stop()                            // SIGTERM группе, через 2 с — SIGKILL
/// ```
@MainActor
public final class ManagedProcess {
    public enum RestartPolicy: Sendable { case never, onFailure, always }

    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]?
    public let restart: RestartPolicy
    public var maxRestartDelay: TimeInterval = 60
    /// Строка stdout (без `\n`), на главном потоке.
    public var onLine: (@MainActor (String) -> Void)?
    /// Строка stderr.
    public var onErrorLine: (@MainActor (String) -> Void)?
    /// Процесс завершился (код выхода или -сигнал).
    public var onExit: (@MainActor (Int32) -> Void)?

    public private(set) var pid: pid_t = 0
    public private(set) var isRunning = false
    public private(set) var restartCount = 0
    /// Сколько раз сработал обработчик чтения (для самотестов: на EOF он должен сняться, а не крутиться).
    public private(set) var readCallbacks = 0
    // --- media2 ---
    /// Дать ребёнку трубу в stdin (команды строками — `send(_:)`). По умолчанию stdin — /dev/null. Труба
    /// закрывается при остановке и выходе ребёнка: помощник, который ждёт EOF на stdin, уходит сам.
    public var providesStdin = false
    /// Потолок строки stdout/stderr (дальше — отдаётся кусок как есть). Обложка base64 от помощника медиа бывает
    /// больше 1 МБ — ему нужен свой потолок.
    public var maxLineBytes = 1 << 20
    /// `posix_spawn` не удался (код ошибки). Перезапуск по политике всё равно запланирован — владелец может
    /// сдаться (`stop()`) и перейти на запасной путь: без этого сбой запуска не виден (`onExit` не зовётся).
    public var onSpawnFailure: (@MainActor (Int32) -> Void)?
    nonisolated(unsafe) private var stdinFD: Int32 = -1
    /// До какого места буфер строки уже просмотрен в поисках `\n`: длинная строка (обложка base64) не сканируется
    /// заново на каждом куске трубы (было квадратично по длине строки).
    private var outScanned = 0
    private var errScanned = 0
    // --- /media2 ---

    private var outHandle: FileHandle?
    private var errHandle: FileHandle?
    private var exitSource: DispatchSourceProcess?
    private var stopping = false
    private var startedAt = Date.distantPast
    private var restartDelay: TimeInterval = 1
    private var restartWork: DispatchWorkItem?
    private var outBuffer = Data()
    private var errBuffer = Data()
    /// Копия `pid` для `deinit` (он не на главном акторе): брошенный без `stop()` процесс не живёт до выхода.
    nonisolated(unsafe) private var deinitGroup: pid_t = 0

    public init(executable: String, arguments: [String] = [], environment: [String: String]? = nil,
                restart: RestartPolicy = .never) {
        self.executable = executable; self.arguments = arguments
        self.environment = environment; self.restart = restart
        Self.installSignalHandlersOnce()
    }

    // MARK: Запуск / остановка

    @discardableResult
    public func start() -> Bool {
        guard !isRunning else { return true }
        stopping = false
        restartWork?.cancel(); restartWork = nil

        var outPipe: [Int32] = [0, 0], errPipe: [Int32] = [0, 0]
        guard pipe(&outPipe) == 0 else { return false }
        guard pipe(&errPipe) == 0 else { close(outPipe[0]); close(outPipe[1]); return false }
        // --- media2 --- CLOEXEC сразу после pipe(): `Process()`/`posix_spawn` на другом потоке (TerminalJumper,
        // NetworkWatcher, полка) не унаследует концы труб. В ребёнке `adddup2` снимает флаг с fd 0/1/2.
        for fd in outPipe + errPipe { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }

        // --- media2 --- stdin: труба (`providesStdin`) или /dev/null.
        var inPipe: [Int32] = [-1, -1]
        if providesStdin {
            guard pipe(&inPipe) == 0 else { close(outPipe[0]); close(outPipe[1]); close(errPipe[0]); close(errPipe[1]); return false }
            for fd in inPipe { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        }
        // --- /media2 ---
        var fa: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        if providesStdin { posix_spawn_file_actions_adddup2(&fa, inPipe[0], 0) }   // --- media2 ---
        else { posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0) }
        posix_spawn_file_actions_adddup2(&fa, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&fa, errPipe[1], 2)

        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attr, 0)
        var noSignals = sigset_t(); sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attr, &noSignals)
        var defaults = sigset_t(); sigfillset(&defaults)
        posix_spawnattr_setsigdefault(&attr, &defaults)

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envList = (environment ?? ProcessInfo.processInfo.environment).map { "\($0.key)=\($0.value)" }
        let envp = envList.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }

        var child: pid_t = 0
        let rc = posix_spawn(&child, executable, &fa, &attr, argv, envp)
        close(outPipe[1]); close(errPipe[1])
        // --- media2 --- свой конец stdin: без SIGPIPE (ребёнок умер — write вернёт EPIPE, приложение не падает),
        // не наследуется другими детьми (Process() без CLOEXEC_DEFAULT).
        if providesStdin {
            close(inPipe[0])
            if rc == 0 {
                _ = fcntl(inPipe[1], F_SETNOSIGPIPE, 1)
                _ = fcntl(inPipe[1], F_SETFD, FD_CLOEXEC)
                // Неблокирующий: ребёнок не читает stdin и труба полна — главный поток не встанет (строка теряется).
                _ = fcntl(inPipe[1], F_SETFL, fcntl(inPipe[1], F_GETFL) | O_NONBLOCK)
                stdinFD = inPipe[1]
            } else {
                close(inPipe[1])
            }
        }
        // --- /media2 ---
        guard rc == 0 else {
            close(outPipe[0]); close(errPipe[0])
            NSLog("SimpleIsland: не запустить %@: %s", executable, strerror(rc))
            scheduleRestart(after: -1)
            onSpawnFailure?(rc)   // --- media2 ---
            return false
        }
        pid = child
        deinitGroup = child
        isRunning = true
        startedAt = Date()
        Self.register(pgid: child)

        outHandle = attach(fd: outPipe[0], isError: false)
        errHandle = attach(fd: errPipe[0], isError: true)

        let src = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: .main)
        src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.reap() } }
        exitSource = src
        src.resume()
        return true
    }

    /// Остановить: SIGTERM всей группе, через `grace` секунд — SIGKILL. Перезапуска не будет.
    public func stop(grace: TimeInterval = 2) {
        stopping = true
        restartWork?.cancel(); restartWork = nil
        closeStdin()   // --- media2 --- штатный выход помощника по EOF, SIGTERM ниже — если завис
        guard isRunning, pid > 0 else { return }
        let group = pid
        killpg(group, SIGTERM)
        DispatchQueue.main.asyncAfter(deadline: .now() + grace) { [weak self] in
            MainActor.assumeIsolated {
                // Группа ещё наша (не собрана `reap`, который сам добивает внуков) — добить. Собранную не трогаем:
                // её номер мог достаться чужой группе.
                guard Self.isRegistered(group) else { return }
                if killpg(group, 0) == 0 { killpg(group, SIGKILL) }
                if let self, self.isRunning, self.pid == group { self.reap() }
            }
        }
    }

    deinit {
        if stdinFD >= 0 { close(stdinFD) }   // --- media2 ---
        // Брошен без `stop()`: гасим группу сразу и собираем зомби в фоне; запись реестра снимаем на главном.
        let g = deinitGroup
        guard g > 0, ManagedProcess.slotsContain(g) else { return }
        killpg(g, SIGKILL)
        DispatchQueue.global(qos: .utility).async { var st: Int32 = 0; _ = waitpid(g, &st, 0) }
        DispatchQueue.main.async { MainActor.assumeIsolated { ManagedProcess.unregister(pgid: g) } }
    }

    // --- agents2 ---
    /// Оба потока (stdout, stderr) дочитаны до EOF: последние строки уже отданы `onLine`/`onErrorLine`. Для разовых
    /// запусков: `onExit` может прийти раньше хвоста вывода (чтение идёт на фоновой очереди) — ждать обоих.
    public var isOutputDrained: Bool { outHandle == nil && errHandle == nil }
    // --- /agents2 ---

    // MARK: Чтение

    private func attach(fd: Int32, isError: Bool) -> FileHandle {
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        h.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                // EOF: снять обработчик, иначе он будет звать нас бесконечно (AT#891).
                handle.readabilityHandler = nil
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.consume(chunk, isError: isError) }
            }
        }
        return h
    }

    private func consume(_ chunk: Data, isError: Bool) {
        readCallbacks += 1
        if chunk.isEmpty {
            // EOF: отдать хвост без перевода строки.
            let rest = isError ? errBuffer : outBuffer
            if !rest.isEmpty { deliver(rest, isError: isError) }
            if isError { errBuffer.removeAll(); errHandle = nil } else { outBuffer.removeAll(); outHandle = nil }
            if isError { errScanned = 0 } else { outScanned = 0 }   // --- media2 ---
            return
        }
        if isError { errBuffer.append(chunk) } else { outBuffer.append(chunk) }
        // Потолок строки — 1 МБ: процесс без переводов строки не съест память.
        while true {
            let buf = isError ? errBuffer : outBuffer
            // --- media2 --- искать `\n` только в непросмотренном хвосте (было: весь буфер на каждом куске).
            let scanned = min(isError ? errScanned : outScanned, buf.count)
            guard let nl = buf[(buf.startIndex + scanned)...].firstIndex(of: 0x0A) else {
                if isError { errScanned = buf.count } else { outScanned = buf.count }
                if buf.count > maxLineBytes {   // --- media2 --- было 1 << 20
                    deliver(buf, isError: isError)
                    if isError { errBuffer.removeAll(); errScanned = 0 } else { outBuffer.removeAll(); outScanned = 0 }
                }
                break
            }
            let line = buf[buf.startIndex..<nl]
            let rest = Data(buf[buf.index(after: nl)...])
            if isError { errBuffer = rest; errScanned = 0 } else { outBuffer = rest; outScanned = 0 }   // --- media2 --- сброс просмотра
            deliver(Data(line), isError: isError)
        }
    }

    private func deliver(_ data: Data, isError: Bool) {
        let s = String(decoding: data, as: UTF8.self)
        if isError { onErrorLine?(s) } else { onLine?(s) }
    }

    // MARK: Завершение и перезапуск

    private func reap() {
        guard isRunning else { return }
        var status: Int32 = 0
        let r = waitpid(pid, &status, WNOHANG)
        if r == 0 { return }    // ещё жив (событие от группы после SIGKILL)
        let code: Int32 = (status & 0x7F) == 0 ? (status >> 8) & 0xFF : -(status & 0x7F)
        exitSource?.cancel(); exitSource = nil
        Self.unregister(pgid: pid)
        // Внуки могли остаться в группе — добить группу.
        if killpg(pid, 0) == 0 { killpg(pid, SIGKILL) }
        isRunning = false
        pid = 0
        deinitGroup = 0
        closeStdin()   // --- media2 ---
        onExit?(code)
        scheduleRestart(after: code)
    }

    private func scheduleRestart(after code: Int32) {
        guard !stopping else { return }
        switch restart {
        case .never: return
        case .onFailure: if code == 0 { return }
        case .always: break
        }
        if Date().timeIntervalSince(startedAt) > 30 { restartDelay = 1 }
        let delay = restartDelay
        restartDelay = min(maxRestartDelay, restartDelay * 2)
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.stopping else { return }
                self.restartCount += 1
                self.start()
            }
        }
        restartWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    // --- media2 ---
    /// Строка в stdin ребёнка (`providesStdin`), `\n` добавляется. false — трубы нет, ребёнок её закрыл, труба
    /// полна (неблокирующая запись) или строка с `\n` длиннее `PIPE_BUF` (512 байт): только такие пишутся в трубу
    /// атомарно — длинная могла бы записаться не целиком, и хвост склеился бы со следующей командой.
    @discardableResult
    public func send(_ line: String) -> Bool {
        guard stdinFD >= 0, isRunning else { return false }
        let bytes = Array((line + "\n").utf8)
        guard bytes.count <= Int(PIPE_BUF) else { return false }
        var off = 0
        while off < bytes.count {
            let n = bytes[off...].withUnsafeBytes { write(stdinFD, $0.baseAddress, $0.count) }
            if n < 0 { if errno == EINTR { continue }; return false }
            off += n
        }
        return true
    }

    private func closeStdin() {
        if stdinFD >= 0 { close(stdinFD); stdinFD = -1 }
    }
    // --- /media2 ---

    // MARK: Реестр групп (для сигналов и выхода)

    /// Сколько детей одновременно помнит реестр.
    nonisolated private static let slotCount = 64
    /// Группы живых детей — фиксированная память, а не Swift-массив: обработчик сигнала читает её без блокировок,
    /// аллокаций и copy-on-write (запись — одно выровненное слово с главного потока).
    nonisolated(unsafe) private static let slots: UnsafeMutablePointer<pid_t> = {
        let p = UnsafeMutablePointer<pid_t>.allocate(capacity: slotCount)
        p.initialize(repeating: 0, count: slotCount)
        return p
    }()
    /// Прежние действия сигналов (по номеру сигнала) — обработчик возвращает их и повторяет сигнал.
    nonisolated(unsafe) private static let previousActions: UnsafeMutablePointer<sigaction> = {
        let p = UnsafeMutablePointer<sigaction>.allocate(capacity: Int(NSIG))
        p.initialize(repeating: sigaction(), count: Int(NSIG))
        return p
    }()
    nonisolated(unsafe) private static var handlersInstalled = false
    /// Время старта ведущего процесса группы (для pid-файла): pgid → (сек, мкс).
    private static var startTimes: [pid_t: (UInt64, UInt64)] = [:]

    private static func register(pgid: pid_t) {
        if let i = (0..<slotCount).first(where: { slots[$0] == 0 }) { slots[i] = pgid }
        if let info = bsdInfo(pgid) { startTimes[pgid] = (info.pbi_start_tvsec, info.pbi_start_tvusec) }
        savePidFile()
    }

    fileprivate static func unregister(pgid: pid_t) {
        for i in 0..<slotCount where slots[i] == pgid { slots[i] = 0 }
        startTimes[pgid] = nil
        savePidFile()
    }

    private static func isRegistered(_ pgid: pid_t) -> Bool { slotsContain(pgid) }

    nonisolated private static func slotsContain(_ pgid: pid_t) -> Bool {
        (0..<slotCount).contains { slots[$0] == pgid }
    }

    /// Живые группы детей (для самотестов и диагностики).
    public static var liveGroups: [pid_t] { (0..<slotCount).map { slots[$0] }.filter { $0 > 0 } }

    /// Завершить всех детей: SIGTERM, короткое ожидание, SIGKILL. Зовёт ядро в `applicationWillTerminate`.
    public static func terminateAll(grace: TimeInterval = 0.5) {
        let live = liveGroups
        guard !live.isEmpty else { return }
        for g in live { killpg(g, SIGTERM) }
        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline, live.contains(where: { killpg($0, 0) == 0 }) { usleep(20_000) }
        for g in live where killpg(g, 0) == 0 { killpg(g, SIGKILL) }
        for i in 0..<slotCount { slots[i] = 0 }
        startTimes.removeAll()
        savePidFile()
    }

    private static func installSignalHandlersOnce() {
        guard !handlersInstalled else { return }
        handlersInstalled = true
        _ = slots; _ = previousActions   // создать память здесь, а не в обработчике сигнала
        // Аварийные и «вежливые» сигналы: бьём группы детей, возвращаем прежнее действие (обработчик сборщика
        // падений или действие по умолчанию) и повторяем сигнал. Сигналы, которые приложение уже игнорирует
        // (SIGTERM/SIGINT/SIGHUP ловит ядро через DispatchSource для штатного выхода с сохранением настроек),
        // не трогаем — тогда детей гасит terminateAll() из applicationWillTerminate.
        for sig in [SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT, SIGTRAP, SIGHUP, SIGQUIT] {
            var old = sigaction()
            sigaction(sig, nil, &old)
            if unsafeBitCast(old.__sigaction_u.__sa_handler, to: Int.self) == 1 { continue }   // SIG_IGN
            previousActions[Int(sig)] = old
            var action = sigaction()
            action.__sigaction_u.__sa_handler = { sig in
                ManagedProcess.killAllFromSignal()
                // Вернуть прежнее действие и повторить сигнал — дальше как без нас (падение, отчёт, выход).
                sigaction(sig, ManagedProcess.previousActions + Int(sig), nil)
                raise(sig)
            }
            sigemptyset(&action.sa_mask)
            action.sa_flags = SA_RESETHAND
            sigaction(sig, &action, nil)
        }
        atexit { ManagedProcess.killAllFromSignal() }
    }

    /// Только async-signal-safe вызовы: чтение фиксированной памяти и kill.
    nonisolated private static func killAllFromSignal() {
        for i in 0..<slotCount {
            let g = slots[i]
            if g > 0 { killpg(g, SIGKILL) }
        }
    }

    // MARK: Сироты после жёсткого падения

    /// Каталог pid-файлов (`children.<pid>.pids`, у каждого экземпляра приложения свой). Самотесты подменяют
    /// его временным, чтобы не трогать файлы работающего приложения.
    public static var pidDirectory: URL = SimpleIslandPaths.appSupport

    private static var pidFile: URL {
        pidDirectory.appendingPathComponent("children.\(getpid()).pids")
    }

    private static func savePidFile() {
        let live = liveGroups
        let fm = FileManager.default
        if live.isEmpty { try? fm.removeItem(at: pidFile); return }
        try? fm.createDirectory(at: pidDirectory, withIntermediateDirectories: true)
        // pgid, время старта ведущего (сек, мкс), имя — только для человека, при сверке не используется.
        let lines = live.compactMap { g -> String? in
            guard let t = startTimes[g] else { return nil }
            return "\(g) \(t.0) \(t.1) \(executableName(of: g) ?? "")"
        }.joined(separator: "\n")
        try? lines.write(to: pidFile, atomically: true, encoding: .utf8)
    }

    /// Добить детей прошлых запусков, переживших жёсткое падение (`kill -9`). Смотрит pid-файлы экземпляров,
    /// которых уже нет (живой экземпляр приложения не трогает). Группа считается нашей, если её ведущий жив, его
    /// родитель — launchd и время старта совпадает с записанным; или ведущий уже вышел, но группа ещё есть
    /// (номер группы не переиспользуется, пока в ней кто-то жив). Зовёт ядро при старте. Вернёт число групп.
    @discardableResult
    public static func reapOrphans() -> Int {
        let fm = FileManager.default
        try? fm.removeItem(at: pidDirectory.appendingPathComponent("children.pids"))   // старый общий формат
        guard let names = try? fm.contentsOfDirectory(atPath: pidDirectory.path) else { return 0 }
        let me = executableName(of: getpid())
        var killed = 0
        for name in names where name.hasPrefix("children.") && name.hasSuffix(".pids") {
            let ownerText = name.dropFirst("children.".count).dropLast(".pids".count)
            guard let owner = pid_t(ownerText), owner != getpid() else { continue }
            // Экземпляр жив (второе окно приложения, самотест) — его дети не сироты.
            if kill(owner, 0) == 0 || errno == EPERM, executableName(of: owner) == me { continue }
            let url = pidDirectory.appendingPathComponent(name)
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            for line in text.split(separator: "\n") {
                let f = line.split(separator: " ", omittingEmptySubsequences: true)
                guard f.count >= 3, let g = pid_t(f[0]), g > 1, let sec = UInt64(f[1]), let usec = UInt64(f[2])
                else { continue }
                guard isOrphanGroup(g, startSec: sec, startUsec: usec) else { continue }
                killpg(g, SIGKILL)
                killed += 1
            }
            try? fm.removeItem(at: url)
        }
        return killed
    }

    /// Наша ли это осиротевшая группа (см. `reapOrphans`).
    nonisolated static func isOrphanGroup(_ g: pid_t, startSec: UInt64, startUsec: UInt64) -> Bool {
        if let leader = bsdInfo(g) {
            return pid_t(leader.pbi_pgid) == g && leader.pbi_ppid == 1
                && leader.pbi_start_tvsec == startSec && leader.pbi_start_tvusec == startUsec
        }
        return !groupMembers(g).isEmpty
    }

    /// Процессы группы `g` (`proc_listpids(PROC_PGRP_ONLY)`).
    nonisolated static func groupMembers(_ g: pid_t) -> [pid_t] {
        var buf = [pid_t](repeating: 0, count: 256)
        let bytes = buf.withUnsafeMutableBytes { raw in
            proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(g), raw.baseAddress, Int32(raw.count))
        }
        guard bytes > 0 else { return [] }
        return Array(buf.prefix(Int(bytes) / MemoryLayout<pid_t>.size)).filter { $0 > 0 }
    }

    nonisolated static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        return n == MemoryLayout<proc_bsdinfo>.size ? info : nil
    }

    public nonisolated static func parentPID(of pid: pid_t) -> pid_t? {
        bsdInfo(pid).map { pid_t($0.pbi_ppid) }
    }

    public nonisolated static func executableName(of pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buf)).lastPathComponent
    }
}
