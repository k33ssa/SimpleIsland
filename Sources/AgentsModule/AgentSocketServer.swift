import Darwin
import Foundation

/// Сервер сокета агентов: AF_UNIX, права сокета 0600 + проверка собеседника (`getpeereid`: только свой uid),
/// строки JSON. Каталог общий с ядром (Application Support/SimpleIsland), его права не трогаем — защищает сам сокет. Своя последовательная очередь,
/// никаких таймеров: только DispatchSource на чтение. Сообщения и обрывы отдаются на главный поток.
final class AgentSocketServer: @unchecked Sendable {
    enum StartError: Error, CustomStringConvertible {
        case pathTooLong, busy, system(String)
        var description: String {
            switch self {
            case .pathTooLong: return "путь к сокету длиннее 103 байт"
            case .busy: return "сокет уже слушает другой экземпляр SimpleIsland"
            case .system(let s): return s
            }
        }
    }

    let path: String
    /// (соединение, строка JSON) — на главном потоке.
    var onMessage: (@MainActor (Int, Data) -> Void)?
    /// Соединение закрылось (хук завершён или убит) — на главном потоке.
    var onClose: (@MainActor (Int) -> Void)?

    private let queue = DispatchQueue(label: "local.simpleisland.agents.socket")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var conns: [Int: Conn] = [:]
    private var nextId = 0
    /// Файл сокета, который создали мы (устройство + inode): удаляем только его, а не чужой с тем же именем.
    private var boundFile: (dev: dev_t, ino: ino_t)?

    private final class Conn {
        let fd: Int32
        var source: DispatchSourceRead?
        var buffer = Data()
        init(fd: Int32) { self.fd = fd }
    }

    init(path: String) { self.path = path }

    func start() throws {
        try queue.sync { try bindAndListen() }
        Self.installExitCleanupOnce()
    }

    /// Слушает ли сокет: дескриптор жив и в режиме приёма, файл на месте и это наш файл (его не удалили и не
    /// подменили — напр. почистили Application Support, пока Мак спал).
    var isHealthy: Bool {
        queue.sync {
            // SO_ACCEPTCONN у AF_UNIX на macOS не читается (ENOPROTOOPT) — проверяем, что дескриптор жив.
            guard listenFD >= 0, acceptSource != nil, let bound = boundFile, fcntl(listenFD, F_GETFD) != -1 else { return false }
            var st = stat()
            guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFSOCK else { return false }
            return st.st_dev == bound.dev && st.st_ino == bound.ino
        }
    }

    /// Пересоздать слушающий сокет, не трогая открытые соединения (висящие запросы разрешений доживут до ответа).
    func restartListener() throws {
        try queue.sync {
            acceptSource?.cancel(); acceptSource = nil
            if listenFD >= 0 { unlinkIfOurs(); listenFD = -1 }
            try bindAndListen()
        }
    }

    /// На очереди сокета.
    private func bindAndListen() throws {
        guard var addr = UnixSocket.address(path) else { throw StartError.pathTooLong }
        let dir = (path as NSString).deletingLastPathComponent
        // Новый каталог — 0700; уже существующий (его создаёт ядро ради settings.json) не трогаем.
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        if FileManager.default.fileExists(atPath: path) {
            if let fd = UnixSocket.connect(path: path) { close(fd); throw StartError.busy }
            unlink(path)   // старый файл от упавшего процесса
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StartError.system("socket: \(String(cString: strerror(errno)))") }
        let old = umask(0o177)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(old)
        guard r == 0 else {
            let e = String(cString: strerror(errno)); close(fd)
            throw StartError.system("bind: \(e)")
        }
        chmod(path, 0o600)
        var st = stat()
        boundFile = lstat(path, &st) == 0 ? (st.st_dev, st.st_ino) : nil
        guard listen(fd, 32) == 0 else {
            let e = String(cString: strerror(errno)); close(fd); unlinkIfOurs()
            throw StartError.system("listen: \(e)")
        }
        Self.setExitCleanup(path: path, file: boundFile)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listenFD = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptAll() }
        src.setCancelHandler { close(fd) }
        acceptSource = src
        src.resume()
    }

    func stop() {
        queue.sync {
            acceptSource?.cancel(); acceptSource = nil
            for (_, c) in conns { c.source?.cancel() }
            conns.removeAll()
            // Уборку при выходе снимаем, только если она про наш файл: у другого живого экземпляра (самотесты) — своя.
            if let b = boundFile { Self.clearExitCleanup(ifFile: b) }
            if listenFD >= 0 { unlinkIfOurs(); listenFD = -1 }
        }
    }

    /// Удалить файл сокета, только если он всё ещё наш (тот же inode).
    private func unlinkIfOurs() {
        defer { boundFile = nil }
        guard let b = boundFile else { return }
        var st = stat()
        if lstat(path, &st) == 0, st.st_dev == b.dev, st.st_ino == b.ino { unlink(path) }
    }

    // MARK: - Уборка при выходе мимо stop()

    // Штатный выход (меню, SIGTERM/SIGINT/SIGHUP → NSApp.terminate → applicationWillTerminate → stop модулей) файл
    // удаляет в stop(). `exit()` в обход этого — через atexit: фиксированная память, только lstat/unlink.
    // Аварийный сигнал файл оставляет — его уберёт следующий запуск (connect не проходит → unlink), а хук на
    // мёртвом файле сразу уходит в терминал.
    nonisolated(unsafe) private static let exitPath: UnsafeMutablePointer<CChar> = {
        let p = UnsafeMutablePointer<CChar>.allocate(capacity: 1024)
        p.initialize(repeating: 0, count: 1024)
        return p
    }()
    nonisolated(unsafe) private static var exitDev: dev_t = 0
    nonisolated(unsafe) private static var exitIno: ino_t = 0
    nonisolated(unsafe) private static var exitInstalled = false

    private static func setExitCleanup(path: String?, file: (dev: dev_t, ino: ino_t)?) {
        exitPath[0] = 0
        guard let path, let file else { return }
        let bytes = Array(path.utf8CString)
        guard bytes.count <= 1024 else { return }
        exitDev = file.dev; exitIno = file.ino
        // С конца к началу: первый байт пишется последним — обработчик видит либо пусто, либо путь целиком.
        for (i, b) in bytes.enumerated().reversed() { exitPath[i] = b }
    }

    private static func clearExitCleanup(ifFile file: (dev: dev_t, ino: ino_t)) {
        guard exitPath[0] != 0, exitDev == file.dev, exitIno == file.ino else { return }
        exitPath[0] = 0
    }

    /// Для самотеста: какой файл уберётся при `exit()` (nil — никакой).
    static var exitCleanupPath: String? { exitPath[0] == 0 ? nil : String(cString: exitPath) }

    private static func installExitCleanupOnce() {
        guard !exitInstalled else { return }
        exitInstalled = true
        _ = exitPath
        atexit {
            let p = AgentSocketServer.exitPath
            guard p[0] != 0 else { return }
            var st = stat()
            if lstat(p, &st) == 0, st.st_dev == AgentSocketServer.exitDev, st.st_ino == AgentSocketServer.exitIno { unlink(p) }
        }
    }

    /// Ответить хуку и закрыть соединение.
    func reply(_ data: Data, to id: Int) {
        queue.async { [weak self] in
            guard let self, let c = self.conns[id] else { return }
            _ = UnixSocket.writeAll(c.fd, data + Data([0x0A]))
            self.drop(id, notify: false)
        }
    }

    // MARK: - На очереди сокета

    private func acceptAll() {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 { return }
            // Чужой пользователь (или root через sudo-скрипт) не может ни слать события, ни отвечать за нас.
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { close(fd); continue }
            UnixSocket.setNoSigPipe(fd)
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            nextId += 1
            let id = nextId
            let c = Conn(fd: fd)
            let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            src.setEventHandler { [weak self] in self?.readFrom(id) }
            src.setCancelHandler { close(fd) }
            c.source = src
            conns[id] = c
            src.resume()
        }
    }

    private func readFrom(_ id: Int) {
        guard let c = conns[id] else { return }
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(c.fd, &chunk, chunk.count)
            if n > 0 {
                c.buffer.append(contentsOf: chunk[0..<n])
                if c.buffer.count > 8 << 20 { drop(id, notify: true); return }
                continue
            }
            if n < 0, errno == EAGAIN || errno == EINTR { break }
            // 0 — хук закрыл (или убит), <0 — ошибка.
            flushLines(c, id: id)
            drop(id, notify: true)
            return
        }
        flushLines(c, id: id)
    }

    private func flushLines(_ c: Conn, id: Int) {
        while let nl = c.buffer.firstIndex(of: 0x0A) {
            let line = Data(c.buffer[c.buffer.startIndex..<nl])
            c.buffer.removeSubrange(c.buffer.startIndex...nl)
            guard !line.isEmpty else { continue }
            let handler = onMessage
            DispatchQueue.main.async { MainActor.assumeIsolated { handler?(id, line) } }
        }
    }

    private func drop(_ id: Int, notify: Bool) {
        guard let c = conns.removeValue(forKey: id) else { return }
        c.source?.cancel()
        if notify {
            let handler = onClose
            DispatchQueue.main.async { MainActor.assumeIsolated { handler?(id) } }
        }
    }
}
