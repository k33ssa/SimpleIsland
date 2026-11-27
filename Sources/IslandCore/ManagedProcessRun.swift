import Darwin
import Foundation

// --- misc2 ---
// Разовый запуск с ожиданием итога (ditto, shortcuts, osascript, defaults, свои скрипты) — поверх ManagedProcess:
// своя группа, гашение при выходе/падении приложения и после таймаута, pid-файл против сирот. Вывод пишется в
// файлы, а не в трубу: итог читается после выхода целиком и детерминированно (у трубы хвост мог прийти позже
// `onExit`), фоновый потомок скрипта (`cmd &`) вывод не держит, большой stderr процесс не вешает.

public extension ManagedProcess {
    struct RunOutput: Sendable {
        /// Код выхода; −сигнал, если процесс убит сигналом; −1 — не запустился.
        public var status: Int32
        public var stdout: String
        public var stderr: String
        /// Убит по таймауту.
        public var timedOut: Bool
        /// Не запустился (нет файла, posix_spawn не удался) — текст причины в `stderr`.
        public var launchFailed: Bool
    }

    /// Запустить `executable arguments…`, дождаться выхода (не дольше `timeout` — дальше SIGTERM группе, через 2 с
    /// SIGKILL; не вышел и через 3 с после SIGKILL — итог `timedOut` без выхода) и отдать вывод (последние
    /// `maxOutputBytes` каждого потока). `completion` — ровно один раз, на фоновой очереди.
    /// Когда программа вышла, её группа добивается (`reap`): фоновый потомок скрипта (`cmd &`, `nohup … &`) не
    /// переживает скрипт — так сирот не остаётся. Пережить можно только вне группы (`open -a …`, launchd).
    /// Звать можно с любого потока; сам процесс заводится на главном.
    nonisolated static func runCollecting(_ executable: String, _ arguments: [String] = [], timeout: TimeInterval = 60,
                                          maxOutputBytes: Int = 4 << 20,
                                          completion: @escaping @Sendable (RunOutput) -> Void) {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            completion(RunOutput(status: -1, stdout: "", stderr: "нет \(executable)", timedOut: false, launchFailed: true))
            return
        }
        Self.sweepStaleRunDirectoriesOnce()
        // Каталог вывода — `<pid>-<UUID>`: по pid при следующем запуске видно, чей он (см. sweep ниже).
        let dir = runRoot.appendingPathComponent("\(getpid())-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            completion(RunOutput(status: -1, stdout: "", stderr: "\(error.localizedDescription)", timedOut: false,
                                 launchFailed: true))
            return
        }
        let out = dir.appendingPathComponent("out"), err = dir.appendingPathComponent("err")
        let launch: @MainActor () -> Void = {
            // sh только перенаправляет вывод и делает exec — в группе остаётся сама программа (и её потомки).
            let p = ManagedProcess(executable: "/bin/sh",
                                   arguments: ["-c", #"o=$1; e=$2; shift 2; exec "$@" >"$o" 2>"$e""#, "sh",
                                               out.path, err.path, executable] + arguments)
            let state = RunState()
            // Итог — ровно один раз: по выходу процесса или (страховка) по сроку после SIGKILL.
            let finish: @MainActor (Int32) -> Void = { code in
                guard !state.finished else { return }
                state.finished = true
                let timedOut = state.timedOut
                DispatchQueue.global(qos: .utility).async {
                    let o = Self.readTail(out, max: maxOutputBytes)
                    let e = Self.readTail(err, max: maxOutputBytes)
                    try? FileManager.default.removeItem(at: dir)
                    completion(RunOutput(status: code, stdout: o, stderr: e, timedOut: timedOut, launchFailed: false))
                }
            }
            // Процесс не умер и после SIGKILL (непрерываемое ожидание в ядре — диск, сеть): не ждать вечно, а
            // отдать «не ответил». Ссылку на процесс отпустить — deinit ещё раз шлёт группе SIGKILL и собирает
            // зомби в фоне, когда тот всё-таки выйдет.
            let giveUp = DispatchWorkItem { [weak p] in
                MainActor.assumeIsolated {
                    guard !state.finished else { return }
                    p?.onExit = nil
                    finish(-SIGKILL)
                }
            }
            let killer = DispatchWorkItem { [weak p] in
                MainActor.assumeIsolated {
                    guard !state.finished, let p else { return }
                    state.timedOut = true
                    p.stop(grace: Self.killGrace)
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.killGrace + Self.giveUpAfterKill, execute: giveUp)
                }
            }
            // Замыкание держит процесс до выхода (брошенный ManagedProcess гасит группу в deinit); на выходе
            // ссылка снимается.
            p.onExit = { [p] code in
                guard !state.finished else { return }
                killer.cancel()
                giveUp.cancel()
                p.onExit = nil
                finish(code)
            }
            guard p.start() else {
                state.finished = true
                p.onExit = nil
                try? FileManager.default.removeItem(at: dir)
                completion(RunOutput(status: -1, stdout: "", stderr: "не запустить \(executable)", timedOut: false,
                                     launchFailed: true))
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0.1, timeout), execute: killer)
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated { launch() }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { launch() } }
        }
    }

    /// То же, `async`.
    nonisolated static func runCollecting(_ executable: String, _ arguments: [String] = [],
                                          timeout: TimeInterval = 60, maxOutputBytes: Int = 4 << 20) async -> RunOutput {
        await withCheckedContinuation { cont in
            runCollecting(executable, arguments, timeout: timeout, maxOutputBytes: maxOutputBytes) { cont.resume(returning: $0) }
        }
    }

    /// То же, с блокирующим ожиданием — для фоновых очередей (GCD). С главного потока крутит главный цикл, пока
    /// не дождётся (самотесты), — из кода интерфейса так не звать.
    nonisolated static func runCollectingBlocking(_ executable: String, _ arguments: [String] = [],
                                                  timeout: TimeInterval = 60,
                                                  maxOutputBytes: Int = 4 << 20) -> RunOutput {
        let box = OutputBox()
        let sem = DispatchSemaphore(value: 0)
        runCollecting(executable, arguments, timeout: timeout, maxOutputBytes: maxOutputBytes) { r in
            box.set(r)
            sem.signal()
        }
        if Thread.isMainThread {
            while box.value == nil {
                autoreleasepool { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
            }
        } else {
            sem.wait()
        }
        return box.value!
    }

    /// SIGTERM → SIGKILL группе по таймауту, через столько секунд.
    nonisolated static var killGrace: TimeInterval { 2 }
    /// После SIGKILL ждать выхода ещё столько секунд — дальше итог «не ответил» без выхода процесса.
    nonisolated static var giveUpAfterKill: TimeInterval { 3 }

    nonisolated private static var runRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("SimpleIsland-run", isDirectory: true)
    }

    /// Каталоги вывода, оставшиеся от прошлых запусков (приложение вышло или упало посреди утилиты): при первом
    /// разовом запуске в процессе удалить те, чей pid уже не жив (и старые, без pid в имени). Чужие живые — не трогать.
    nonisolated private static func sweepStaleRunDirectoriesOnce() {
        RunSweep.once.lock()
        defer { RunSweep.once.unlock() }
        guard !RunSweep.done else { return }
        RunSweep.done = true
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: runRoot.path) else { return }
        let me = getpid()
        for name in names {
            let pid = name.split(separator: "-", maxSplits: 1).first.flatMap { pid_t($0) }
            if let pid, pid == me || kill(pid, 0) == 0 || errno == EPERM { continue }   // свой или живой
            try? fm.removeItem(at: runRoot.appendingPathComponent(name))
        }
    }

    /// Хвост файла (не больше `max` байт), как текст UTF-8.
    nonisolated private static func readTail(_ url: URL, max: Int) -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let start = size > UInt64(max) ? size - UInt64(max) : 0
        try? h.seek(toOffset: start)
        let data = (try? h.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

/// Уборка старых каталогов вывода — один раз за процесс.
private enum RunSweep {
    nonisolated(unsafe) static var done = false
    static let once = NSLock()
}

/// Флаги одного запуска (только главный поток).
@MainActor
private final class RunState {
    var finished = false
    var timedOut = false
}

private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var v: ManagedProcess.RunOutput?
    func set(_ r: ManagedProcess.RunOutput) { lock.lock(); v = r; lock.unlock() }
    var value: ManagedProcess.RunOutput? { lock.lock(); defer { lock.unlock() }; return v }
}
// --- /misc2 ---
