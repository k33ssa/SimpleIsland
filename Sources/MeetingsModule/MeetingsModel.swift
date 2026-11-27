import AppKit
import Combine
import Foundation
import IslandCore

/// Настройки модуля (settings.json → moduleSettings.meetings). Пароля здесь нет и не будет; cookie — в Keychain.
public struct MeetingsPrefs: Codable, Equatable {
    public var server = StenServer.defaultAddress
    /// Имя, под которым вошли (для подписи «Вошли как …»; не секрет).
    public var userName: String?
    /// Записи, которые не дошли до сервера (нет сети, сессия кончилась): отправить файлом после входа.
    public var pending: [PendingUpload] = []
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        server = (try? c.decode(String.self, forKey: .server)) ?? StenServer.defaultAddress
        userName = try? c.decode(String.self, forKey: .userName)
        pending = (try? c.decode([PendingUpload].self, forKey: .pending)) ?? []
    }
}

public struct PendingUpload: Codable, Equatable, Sendable {
    public var meetingId: Int
    public var path: String
    public var title: String
}

/// Источник звука записи: микрофон в приложении, синтетика в самотесте. Все колбэки — на главном потоке.
@MainActor
public protocol MeetingAudioSource: AnyObject {
    /// Кусок fMP4 (`isInit` — заголовок).
    var onSegment: ((Data, Bool) -> Void)? { get set }
    var onLevel: ((Float) -> Void)? { get set }
    var onFailure: ((String) -> Void)? { get set }
    func start() throws
    /// Остановить и дописать последний кусок; `done` — после последнего `onSegment`.
    func stop(_ done: @escaping @MainActor () -> Void)
}

/// Микрофон Мака → fMP4/AAC 48 кГц моно, кусок каждые 2 с.
@MainActor
final class MicAudioSource: MeetingAudioSource {
    var onSegment: ((Data, Bool) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onFailure: ((String) -> Void)?
    private var recorder: MicRecorder?

    func start() throws {
        let seg = try FMP4Segmenter(sampleRate: MicRecorder.sampleRate) { [weak self] data, isInit in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.onSegment?(data, isInit) } }
        }
        let r = MicRecorder(segmenter: seg)
        r.onLevel = { [weak self] l in self?.onLevel?(l) }
        r.onFailure = { [weak self] m in self?.onFailure?(m) }
        try r.start()
        recorder = r
    }

    func stop(_ done: @escaping @MainActor () -> Void) {
        guard let r = recorder else { done(); return }
        recorder = nil
        r.stop { _ in DispatchQueue.main.async { MainActor.assumeIsolated { withExtendedLifetime(self) { done() } } } }
    }
}

public enum MeetingsAuth: Equatable {
    case loggedOut
    case loggingIn
    case loggedIn(String)
    public var isLoggedIn: Bool { if case .loggedIn = self { return true }; return false }
}

public enum RecordPhase: Equatable {
    case idle, starting, recording, stopping, uploading
}

public enum LoadState: Equatable {
    case idle, loading, failed(String)
}

/// Состояние модуля «Встречи»: вход, список, протокол, запись, опрос обработки.
@MainActor
public final class MeetingsModel: ObservableObject {
    @Published public private(set) var prefs: MeetingsPrefs
    @Published public private(set) var auth: MeetingsAuth = .loggedOut
    /// Ошибка входа / общая строка-подсказка под формой.
    @Published public var authMessage: String?
    @Published public private(set) var meetings: [StenMeeting] = []
    @Published public private(set) var listState: LoadState = .idle
    /// Открытая встреча (nil — список).
    @Published public private(set) var selected: Int?
    @Published public private(set) var reports: [Int: StenReport] = [:]
    @Published public private(set) var detailState: LoadState = .idle
    @Published public private(set) var record: RecordPhase = .idle
    @Published public private(set) var recordingId: Int?
    @Published public private(set) var recordStart: Date?
    @Published public var recordMessage: String?
    /// Встречи в обработке и их последний статус.
    @Published public private(set) var processing: [Int: StenStatus] = [:]
    /// Прогресс загрузки файлом (запасной путь).
    @Published public private(set) var uploadProgress: Double?

    /// Уровни микрофона для полосок (`Visualizer(feed:)`, Core Animation мимо SwiftUI).
    public let levels = AudioLevelsFeed()
    private var levelHistory = [Float](repeating: 0, count: AudioLevelsFeed.wideCount)

    public let client: StenClient
    let store: StenSessionStore
    var makeSource: () -> MeetingAudioSource = { MicAudioSource() }
    /// Доступ к микрофону (кнопка «Начать запись» — действие пользователя). Самотест подменяет.
    var requestMicrophone: () async -> Bool = { await Permissions.requestFromUser(.microphone, moduleId: "meetings") == .granted }
    var saveHandler: ((MeetingsPrefs) -> Void)?
    var now: () -> Date = Date.init
    /// Где лежат локальные копии записей.
    var recordingsDir = SimpleIslandPaths.appSupport.appendingPathComponent("Meetings", isDirectory: true)

    // События для модуля (компакт, карточки).
    var onRecordingChange: (() -> Void)?
    var onProcessingChange: (() -> Void)?
    var onReady: ((StenMeeting) -> Void)?
    var onUnauthorized: (() -> Void)?

    // Запись
    private var source: MeetingAudioSource?
    private var initSegment: Data?
    private var chunkChain: Task<Void, Never>?
    private var chunksFailed = false
    private var chunksSent = 0
    private var localFile: FileHandle?
    private var localURL: URL?
    private var recordingTitle = ""

    // Опрос
    private var pollWork: DispatchWorkItem?
    private var pollDelay: TimeInterval = 2
    private(set) var pollPaused = false
    private var lastPercent: [Int: Double] = [:]
    private var lastListFetch: Date?
    /// Сколько раз опрошен /status (самотест: «без обработки — ни одного запроса»).
    public private(set) var pollCount = 0
    /// Задержки опроса по порядку (самотест бэкоффа).
    public private(set) var pollDelays: [TimeInterval] = []
    /// Потолок интервала опроса, с.
    var maxPollDelay: TimeInterval = 15
    var minPollDelay: TimeInterval = 2

    public init(prefs: MeetingsPrefs = MeetingsPrefs(), store: StenSessionStore = FileSessionStore()) {
        self.prefs = prefs
        self.store = store
        let server = StenServer(prefs.server) ?? StenServer(StenServer.defaultAddress) ?? StenServer(StenServer.placeholderAddress)!
        client = StenClient(server: server, cookie: store.load(account: server.account))
        client.onCookie = { [weak self] c in self?.persistCookie(c) }
        if client.cookie != nil { auth = .loggedIn(prefs.userName ?? "") }
    }

    public var server: StenServer { client.server }
    public var isRecording: Bool { record == .recording || record == .starting }

    // MARK: Вход

    /// Вход. Пароль живёт только в этом вызове: уходит одним запросом и не сохраняется.
    public func login(name: String, password: String) async {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, !password.isEmpty else { authMessage = "Введите имя и пароль"; return }
        auth = .loggingIn
        authMessage = nil
        client.cookie = nil
        do {
            let shown = try await client.login(name: n, password: password)
            guard client.cookie != nil else {
                auth = .loggedOut
                authMessage = "Сервер не выдал сессию — проверьте адрес сервера"
                return
            }
            updatePrefs { $0.userName = shown }
            auth = .loggedIn(shown)
            lastListFetch = nil
            await refreshList(force: true)
            await retryPending()
        } catch let e as StenError {
            auth = .loggedOut
            if case .unauthorized(let d) = e { authMessage = d.isEmpty || d == "Нужно войти" ? "Неверное имя или пароль" : d }
            else { authMessage = e.localizedDescription }
        } catch {
            auth = .loggedOut
            authMessage = error.localizedDescription
        }
    }

    /// Выйти: сказать серверу (не вышло — неважно) и забыть cookie.
    public func logout() async {
        if client.cookie != nil { try? await client.logout() }
        forgetSession(message: nil)
    }

    /// Проверить сессию (вкладку открыли в первый раз). 401 → форма входа.
    public func verifySession() async {
        guard client.cookie != nil else { return }
        do {
            if let name = try await client.me(), !name.isEmpty {
                updatePrefs { $0.userName = name }
                auth = .loggedIn(name)
            }
        } catch { handle(error) }
    }

    func setLoggedInName(_ n: String) { auth = .loggedIn(n) }

    func forgetSession(message: String?) {
        store.delete(account: client.server.account)
        client.cookie = nil
        auth = .loggedOut
        authMessage = message
        meetings = []
        reports = [:]
        selected = nil
        processing = [:]
        stopPolling()
        onProcessingChange?()
    }

    private func persistCookie(_ c: String) {
        if c.isEmpty { store.delete(account: client.server.account) } else { store.save(c, account: client.server.account) }
    }

    /// Новый адрес сервера (туннель сменился). Сессия — своя у каждого адреса.
    @discardableResult
    public func setServer(_ text: String) -> Bool {
        guard let s = StenServer(text) else { return false }
        guard s != client.server else { return true }
        updatePrefs { $0.server = s.display; $0.userName = nil }
        client.server = s
        client.cookie = store.load(account: s.account)
        auth = client.cookie != nil ? .loggedIn("") : .loggedOut
        meetings = []; reports = [:]; selected = nil; lastListFetch = nil
        processing = [:]; stopPolling(); onProcessingChange?()
        return true
    }

    /// Общая реакция на ошибки: 401 — снова вход.
    @discardableResult
    func handle(_ error: Error) -> String {
        if case StenError.unauthorized = error {
            forgetSession(message: "Сессия закончилась — войдите снова")
            onUnauthorized?()
            return "Нужно войти"
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    func updatePrefs(_ f: (inout MeetingsPrefs) -> Void) {
        var p = prefs
        f(&p)
        guard p != prefs else { return }
        prefs = p
        saveHandler?(p)
    }

    // MARK: Список и протокол

    /// Список встреч. Без `force` — не чаще раза в 15 с (вкладку открывают часто).
    public func refreshList(force: Bool = false) async {
        guard auth.isLoggedIn else { return }
        if !force, let t = lastListFetch, now().timeIntervalSince(t) < 15 { return }
        lastListFetch = now()
        if meetings.isEmpty { listState = .loading }
        do {
            let list = try await client.meetings()
            meetings = list.sorted { ($0.createdAt ?? .distantPast, $0.id) > ($1.createdAt ?? .distantPast, $1.id) }
            listState = .idle
            // Сервер уже закончил то, что мы считаем «в обработке» (опрос мог стоять) — снять кольцо.
            for m in meetings where processing[m.id] != nil && (m.status == "ready" || m.status == "consensus") {
                processing[m.id] = nil
                finishTracking(m.id)
                onProcessingChange?()
            }
            // Что сервер ещё обрабатывает — опрашивать (пишет-то, может, другой браузер — тогда «recording», не трогаем).
            for m in meetings where m.status == "processing" && processing[m.id] == nil && m.id != recordingId {
                processing[m.id] = StenStatus(status: "processing")
            }
            if !processing.isEmpty { onProcessingChange?(); schedulePoll(after: 0.5) }
        } catch {
            let msg = handle(error)
            listState = auth.isLoggedIn ? .failed(msg) : .idle
        }
    }

    public func open(_ id: Int) {
        selected = id
        Task { await loadReport(id) }
    }

    public func closeDetail() { selected = nil; detailState = .idle }

    public func loadReport(_ id: Int, force: Bool = false) async {
        if reports[id] != nil && !force { detailState = .idle; return }
        detailState = .loading
        do {
            let r = try await client.report(id)
            reports[id] = r
            detailState = .idle
        } catch {
            detailState = .failed(handle(error))
        }
    }

    public func meeting(_ id: Int) -> StenMeeting? { meetings.first { $0.id == id } }

    public func copySummary(_ id: Int) {
        guard let r = reports[id] else { return }
        let text = StenGrouping.plainText(r, meetingTitle: meeting(id)?.title ?? "Встреча", link: server.consensusPage(id))
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    public func openOnSite(_ id: Int) { NSWorkspace.shared.open(server.consensusPage(id)) }

    // MARK: Запись

    static func defaultTitle(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return "Встреча " + f.string(from: d)
    }

    public func startRecording() async {
        guard record == .idle, auth.isLoggedIn else { return }
        recordMessage = nil
        record = .starting
        onRecordingChange?()
        guard await requestMicrophone() else {
            record = .idle
            recordMessage = "Нет доступа к микрофону — разрешите в Системных настройках"
            onRecordingChange?()
            return
        }
        let title = Self.defaultTitle(now())
        let meeting: StenMeeting
        do { meeting = try await client.createMeeting(title: title) }
        catch {
            record = .idle
            recordMessage = "Не удалось начать запись: " + handle(error)
            onRecordingChange?()
            return
        }
        recordingTitle = meeting.title
        recordingId = meeting.id
        initSegment = nil; chunksFailed = false; chunksSent = 0; chunkChain = nil
        openLocalFile(meeting.id)
        let src = makeSource()
        src.onSegment = { [weak self] d, isInit in self?.segment(d, isInit: isInit) }
        src.onLevel = { [weak self] l in self?.level(l) }
        src.onFailure = { [weak self] m in
            self?.recordMessage = m
            Task { await self?.stopRecording() }
        }
        do { try src.start() }
        catch {
            record = .idle
            recordingId = nil
            closeLocalFile(delete: true)
            recordMessage = "Микрофон не включился: \((error as NSError).localizedDescription)"
            // Пустую встречу — убрать с сервера не пытаемся (DELETE — необратимо, а id мог совпасть с чужим); остаётся
            // в списке «записью без звука».
            onRecordingChange?()
            return
        }
        source = src
        recordStart = now()
        record = .recording
        if !meetings.contains(where: { $0.id == meeting.id }) {
            meetings.insert(StenMeeting(id: meeting.id, title: meeting.title, createdAt: now(), status: "recording"), at: 0)
        }
        onRecordingChange?()
    }

    /// Сколько кусков отдал источник за запись (самотест).
    public private(set) var segmentsReceived = 0

    private func segment(_ data: Data, isInit: Bool) {
        segmentsReceived += 1
        try? localFile?.write(contentsOf: data)
        guard let id = recordingId else { return }
        if isInit { initSegment = data; return }
        var payload = data
        if let i = initSegment { payload = i + data; initSegment = nil }
        guard !chunksFailed else { return }
        let prev = chunkChain
        chunkChain = Task { [weak self] in
            await prev?.value
            await self?.sendChunk(id, payload)
        }
    }

    /// Кусок с повтором: 3 попытки (1 с, 2 с). Не дошёл — дальше куски не шлём, по стопу — файлом.
    private func sendChunk(_ id: Int, _ data: Data) async {
        guard !chunksFailed else { return }
        for attempt in 0..<3 {
            do {
                try await client.uploadChunk(id, data)
                chunksSent += 1
                return
            } catch StenError.unauthorized {
                break
            } catch {
                if attempt < 2 { try? await Task.sleep(nanoseconds: UInt64(1_000_000_000 * (1 << attempt))) }
            }
        }
        chunksFailed = true
        recordMessage = "Связь с сервером пропала — пишу на диск, отправлю файлом после «Стоп»"
    }

    private func level(_ l: Float) {
        levelHistory.removeFirst()
        levelHistory.append(l)
        guard levels.hasDemand else { return }
        let wide = levelHistory
        let compact = Array(levelHistory.suffix(AudioLevelsFeed.compactCount))
        levels.publish(wide: wide, compact: compact, interval: 0.1)
    }

    public func stopRecording() async {
        guard record == .recording, let id = recordingId, let src = source else { return }
        record = .stopping
        onRecordingChange?()
        source = nil
        // Источник держим до `done`: его колбэки — через weak self, и без этой ссылки последний фрагмент
        // (дописывается уже после stop) терялся вместе с источником (самотест 16.11: 4 с из 5).
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            src.stop { withExtendedLifetime(src) { c.resume() } }
        }
        levels.setIdle()
        levelHistory = [Float](repeating: 0, count: AudioLevelsFeed.wideCount)
        // Заголовок без единого фрагмента (остановили за долю секунды) — отправить хоть его.
        if let i = initSegment, !chunksFailed { initSegment = nil; chunkChain = Task { [weak self, prev = chunkChain] in
            await prev?.value; await self?.sendChunk(id, i) } }
        await chunkChain?.value
        chunkChain = nil
        let file = localURL
        closeLocalFile(delete: false)
        var finalId = id
        var ok = false
        if !chunksFailed && chunksSent > 0 {
            do { try await client.stop(id); ok = true }
            catch StenError.unauthorized { _ = handle(StenError.unauthorized("")) }
            catch { recordMessage = "Стоп не дошёл: " + handle(error) + " — отправляю файлом" }
        }
        if !ok, let file, auth.isLoggedIn {
            record = .uploading
            onRecordingChange?()
            if let newId = await uploadFile(file, meetingId: id, title: recordingTitle) { finalId = newId; ok = true }
        }
        if !ok, let file {
            updatePrefs { $0.pending.append(PendingUpload(meetingId: id, path: file.path, title: recordingTitle)) }
            if !auth.isLoggedIn { recordMessage = "Запись сохранена — отправлю после входа" }
        }
        record = .idle
        recordingId = nil
        recordStart = nil
        uploadProgress = nil
        if ok {
            if let i = meetings.firstIndex(where: { $0.id == id }) { meetings[i].status = "processing"; meetings[i].id = finalId }
            track(finalId, file: file)
        }
        onRecordingChange?()
    }

    /// Запасной путь — файлом (как «Загрузить запись» на сайте). 409/404 на старой встрече → новая встреча.
    private func uploadFile(_ file: URL, meetingId: Int, title: String) async -> Int? {
        uploadProgress = 0
        do {
            try await client.uploadAudio(meetingId, file: file, mime: "audio/mp4")
            return meetingId
        } catch StenError.unauthorized {
            _ = handle(StenError.unauthorized(""))
            return nil
        } catch StenError.conflict, StenError.notFound {
            do {
                let m = try await client.createMeeting(title: title)
                try await client.uploadAudio(m.id, file: file, mime: "audio/mp4")
                return m.id
            } catch {
                recordMessage = "Не отправилось: " + handle(error)
                return nil
            }
        } catch {
            recordMessage = "Не отправилось: " + handle(error)
            return nil
        }
    }

    /// После входа — отправить записи, что не дошли.
    func retryPending() async {
        let list = prefs.pending
        guard !list.isEmpty, auth.isLoggedIn else { return }
        for p in list {
            let url = URL(fileURLWithPath: p.path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                updatePrefs { $0.pending.removeAll { $0 == p } }
                continue
            }
            if let id = await uploadFile(url, meetingId: p.meetingId, title: p.title) {
                updatePrefs { $0.pending.removeAll { $0 == p } }
                track(id, file: url)
            }
        }
        await refreshList(force: true)
    }

    private var trackedFiles: [Int: URL] = [:]

    private func track(_ id: Int, file: URL?) {
        if let file { trackedFiles[id] = file }
        processing[id] = StenStatus(status: "processing")
        onProcessingChange?()
        pollDelay = minPollDelay
        schedulePoll(after: minPollDelay)
    }

    private func openLocalFile(_ id: Int) {
        try? FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
        let url = recordingsDir.appendingPathComponent("meeting-\(id).mp4")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        localURL = url
        localFile = try? FileHandle(forWritingTo: url)
    }

    private func closeLocalFile(delete: Bool) {
        try? localFile?.close()
        localFile = nil
        if delete, let u = localURL { try? FileManager.default.removeItem(at: u) }
        localURL = nil
    }

    /// Локальные копии старше недели и не ждущие отправки — убрать.
    func cleanupOldRecordings() {
        let keep = Set(prefs.pending.map(\.path))
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: recordingsDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for u in items where !keep.contains(u.path) {
            let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if now().timeIntervalSince(d) > 7 * 86400 { try? fm.removeItem(at: u) }
        }
    }

    // MARK: Опрос обработки (только пока что-то обрабатывается)

    func schedulePoll(after delay: TimeInterval) {
        pollWork?.cancel()
        guard !processing.isEmpty, !pollPaused, auth.isLoggedIn else { pollWork = nil; return }
        pollDelays.append(delay)
        let w = DispatchWorkItem { [weak self] in Task { @MainActor in await self?.pollOnce() } }
        pollWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    func stopPolling() { pollWork?.cancel(); pollWork = nil }

    public func pausePolling() { pollPaused = true; stopPolling() }
    public func resumePolling() {
        guard pollPaused else { return }
        pollPaused = false
        pollDelay = minPollDelay
        schedulePoll(after: 1)
    }

    func pollOnce() async {
        pollWork = nil
        guard !pollPaused else { return }
        var changed = false
        var networkTrouble = false
        for id in processing.keys.sorted() {
            pollCount += 1
            do {
                let s = try await client.status(id)
                if processing[id] != s { processing[id] = s }
                if s.isReady {
                    processing[id] = nil
                    changed = true
                    finishTracking(id)
                    if let i = meetings.firstIndex(where: { $0.id == id }) { meetings[i].status = s.status }
                    reports[id] = nil
                    let m = meeting(id) ?? StenMeeting(id: id, title: "Встреча")
                    onReady?(m)
                } else if s.isError {
                    processing[id] = nil
                    changed = true
                    if let i = meetings.firstIndex(where: { $0.id == id }) { meetings[i].status = "error" }
                    recordMessage = "Не удалось обработать «\(meeting(id)?.title ?? "встречу")»: " + (s.error ?? "ошибка")
                } else if s.status == "recording" && id != recordingId {
                    // Сервер ждёт кусков от другого клиента — не наше, не опрашиваем.
                    processing[id] = nil
                    changed = true
                } else if let p = s.percent, p != lastPercent[id] {
                    lastPercent[id] = p
                    changed = true
                }
            } catch StenError.notFound {
                processing[id] = nil
                changed = true
            } catch StenError.unauthorized {
                handle(StenError.unauthorized(""))
                return
            } catch {
                networkTrouble = true
            }
        }
        onProcessingChange?()
        guard !processing.isEmpty else { stopPolling(); return }
        // Бэкофф: прогресс идёт — часто, стоит — реже (до 15 с), нет сети — ещё реже (до 60 с).
        if networkTrouble { pollDelay = min(max(pollDelay * 2, 5), 60) }
        else if changed { pollDelay = min(minPollDelay * 1.5, maxPollDelay) }
        else { pollDelay = min(pollDelay * 1.5, maxPollDelay) }
        schedulePoll(after: pollDelay)
    }

    private func finishTracking(_ id: Int) {
        lastPercent[id] = nil
        if let f = trackedFiles.removeValue(forKey: id) { try? FileManager.default.removeItem(at: f) }
    }

    // MARK: Снимки и самотест

    func mock(auth: MeetingsAuth, meetings: [StenMeeting] = [], processing: [Int: StenStatus] = [:],
              selected: Int? = nil, report: StenReport? = nil, record: RecordPhase = .idle, recordStart: Date? = nil,
              message: String? = nil, authMessage: String? = nil) {
        self.auth = auth; self.meetings = meetings; self.processing = processing
        self.selected = selected; self.record = record; self.recordStart = recordStart
        self.recordingId = record == .idle ? nil : meetings.first?.id
        self.recordMessage = message; self.authMessage = authMessage
        if let selected, let report { reports[selected] = report }
    }

    /// Остановить всё (модуль выключили/выход): запись — дописать и отправить, опрос — снять.
    func shutdown() async {
        if record == .recording { await stopRecording() }
        stopPolling()
    }
}
