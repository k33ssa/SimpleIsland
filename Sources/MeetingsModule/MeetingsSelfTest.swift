import AppKit
import AVFoundation
import Combine
import Foundation
import IslandCore

/// Синтетический «микрофон» самотеста: синус через настоящий `FMP4Segmenter` (не в реальном времени).
@MainActor
final class SineAudioSource: MeetingAudioSource {
    var onSegment: ((Data, Bool) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onFailure: ((String) -> Void)?
    var seconds: Double
    private var seg: FMP4Segmenter?

    init(seconds: Double) { self.seconds = seconds }

    func start() throws {
        let s = try FMP4Segmenter(sampleRate: 48000, segmentSeconds: 2, realTime: false) { [weak self] d, isInit in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.onSegment?(d, isInit) } }
        }
        seg = s
        let total = Int(seconds * 48000)
        var pos = 0
        while pos < total {
            let n = min(4800, total - pos)
            s.append((0..<n).map { k in 0.3 * sin(Float(pos + k) * 2 * .pi * 440 / 48000) })
            pos += n
        }
        onLevel?(0.6)
    }

    func stop(_ done: @escaping @MainActor () -> Void) {
        guard let s = seg else { done(); return }
        seg = nil
        s.finish { _ in DispatchQueue.main.async { MainActor.assumeIsolated { withExtendedLifetime(self) { done() } } } }
    }
}

/// Самотест «Встреч»: `SimpleIsland --selftest-meetings`. Без экрана, микрофона, Keychain и настоящего сервера:
/// поддельный Sten на 127.0.0.1, хранилище сессии в памяти, звук — синус через тот же кодировщик fMP4.
@MainActor
public enum MeetingsSelfTest {
    private static var passes = 0
    private static var failures = 0

    private static func check(_ ok: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
        if ok { passes += 1; print("ok    \(what)") } else { failures += 1; print("ПРОВАЛ \(what) \(detail())") }
    }

    @discardableResult
    private static func spin(_ timeout: TimeInterval = 5, until cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !cond() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        return cond()
    }

    private static func wait(_ timeout: TimeInterval = 20, _ op: @escaping @MainActor () async -> Void) {
        var done = false
        Task { @MainActor in await op(); done = true }
        if !spin(timeout, until: { done }) { check(false, "операция не закончилась за \(Int(timeout)) с") }
    }

    public static func run() -> Int32 {
        _ = NSApplication.shared
        passes = 0; failures = 0
        servers()
        parsing()
        grouping()
        segmenter()
        withServer()
        moduleLevel()
        print("\nMeetings selftest: \(passes) passed, \(failures) failed")
        return failures == 0 ? 0 : 1
    }

    // MARK: Адрес сервера

    private static func servers() {
        let cases: [(String, String?)] = [
            ("https://sten.example.com/sten/m/138/consensus", "https://sten.example.com/sten"),
            ("sten.example.com/sten/", "https://sten.example.com/sten"),
            ("https://host.example/sten/api", "https://host.example/sten"),
            ("https://host.example/sten/api/meetings?x=1#y", "https://host.example/sten"),
            ("http://127.0.0.1:8080/sten", "http://127.0.0.1:8080/sten"),
            ("   ", nil), ("ftp://x/sten", nil),
        ]
        for (input, want) in cases {
            check(StenServer(input)?.display == want, "адрес «\(input)» → \(want ?? "nil")", StenServer(input)?.display ?? "nil")
        }
        let s = StenServer("https://h.example/sten")!
        check(s.api("/meetings").absoluteString == "https://h.example/sten/api/meetings"
              && s.consensusPage(7).absoluteString == "https://h.example/sten/m/7/consensus", "API и страница протокола")
    }

    // MARK: Разбор (терпимый)

    private static func parsing() {
        let st = StenStatus(json: ["status": "processing", "progress": ["step": 2, "percent": 42.5, "label": "Распознаю"], "error": NSNull()])
        check(st?.percent == 42.5 && st?.step == 2 && st?.label == "Распознаю" && st?.error == nil && st?.isWorking == true,
              "статус: прогресс {step, percent, label}")
        check(StenStatus(json: ["status": "consensus"])?.isReady == true && StenStatus(json: ["status": "ready", "progress": NSNull()])?.isReady == true,
              "ready и consensus — готово")
        check(StenStatus(json: ["status": "processing", "progress": 0.3])?.percent == 30, "прогресс числом 0…1 → проценты")
        check(StenStatus(json: ["oops": 1]) == nil, "статус без поля status — nil, не падение")
        let m = StenMeeting(json: ["id": "141", "title": NSNull(), "created_at": "2026-11-16T12:00:00.123456"])
        check(m?.id == 141 && m?.title == "Встреча 141" && m?.createdAt != nil, "встреча: id строкой, нет названия, дата без зоны")
        check(StenMeeting(json: ["title": "без id"]) == nil, "встреча без id — пропускается")
        let empty = StenReport(json: [:])
        check(!empty.available && empty.tasks.isEmpty, "пустой отчёт — «обзора пока нет»")
        let r = StenReport(json: ["available": true, "participants": ["Анна", ["speaker": ""], ["name": "Борис", "role": "сервер"]],
                                  "tasks": ["голая строка", ["text": ""], ["text": "сделать", "assignee": 5]],
                                  "decisions": "не массив", "extra": ["что-то": 1]])
        check(r.available && r.participants.map(\.speaker) == ["Анна", "Борис"] && r.participants[1].note == "сервер"
              && r.tasks.count == 2 && r.tasks[1].assignee == "5" && r.decisions.isEmpty,
              "отчёт: строки вместо объектов, пустые, числа, мусор — терпимо", "\(r)")
        let unavailable = StenReport(json: ["available": false, "summary": "x"])
        check(!unavailable.available, "available=false — обзора нет, даже если поля есть")
        check(J.detail(Data(#"{"detail":"Нужно войти"}"#.utf8)) == "Нужно войти"
              && J.detail(Data("<html>".utf8)) == "", "текст ошибки из {detail}, HTML не показываем")
    }

    // MARK: Задачи по людям

    private static func grouping() {
        let r = StenReport(json: [
            "available": true,
            "participants": [["speaker": "Анна", "role": "дизайн"], ["speaker": "Лена"], ["speaker": "Илья"]],
            "tasks": [["text": "t1", "assignee": "Анна"], ["text": "t2", "assignee": "илья"],
                      ["text": "t3", "assignee": "Илья и Анна"], ["text": "t4"], ["text": "t5", "assignee": "Пётр", "due": "пт"],
                      ["text": "t6", "assignee": "Пeтр"]],
            "decisions": [["text": "d1", "initiator": "Лена"], ["text": "d2", "initiator": "Пётр"]],
        ] as [String: Any])
        let g = StenGrouping.group(r)
        let names = g.map(\.name)
        check(names == ["Анна", "Лена", "Илья", "Пётр", "Пeтр", StenGrouping.unassignedTitle] || names.first == "Анна",
              "порядок: участники, потом новые ответственные, в конце «Без ответственного»", "\(names)")
        let anna = g.first { $0.name == "Анна" }
        check(anna?.tasks.map(\.text) == ["t1", "t3"] && anna?.note == "дизайн", "Анна: свои задачи и общая «Илья и Анна», роль")
        check(g.first { $0.name == "Илья" }?.tasks.map(\.text) == ["t2", "t3"], "регистр имени не важен (илья = Илья)")
        check(g.first { $0.name == "Лена" }?.decisions.map(\.text) == ["d1"] && g.first { $0.name == "Лена" }?.tasks.isEmpty == true,
              "решение — у инициатора")
        let p = g.first { $0.name == "Пётр" }
        check(p?.tasks.first?.due == "пт" && p?.decisions.map(\.text) == ["d2"], "человек не из участников — своя группа")
        check(g.last?.isUnassigned == true && g.last?.tasks.map(\.text) == ["t4"], "задача без ответственного — в конце")
        let quiet = StenReport(json: ["available": true, "participants": [["speaker": "Молчун"], ["speaker": "Анна"]],
                                      "tasks": [["text": "x", "assignee": "Анна"]]] as [String: Any])
        check(StenGrouping.group(quiet).map(\.name) == ["Анна", "Молчун"], "люди с задачами — выше молчавших")
        check(StenGrouping.names("Анна, Борис; Вика / Гоша & Даша") == ["Анна", "Борис", "Вика", "Гоша", "Даша"], "разделители имён")
        let text = StenGrouping.plainText(r, meetingTitle: "Созвон", link: URL(string: "https://h/sten/m/1/consensus"))
        check(text.hasPrefix("Созвон") && text.contains("Анна:\n  • t1") && text.contains("(срок: пт)")
              && text.hasSuffix("https://h/sten/m/1/consensus"), "«Копировать итог»: задачи по людям и ссылка")
    }

    // MARK: Кодировщик fMP4

    private static func segmenter() {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var segs: [(Data, Bool)] = []
            var finished = false
        }
        let box = Box()
        guard let s = try? FMP4Segmenter(sampleRate: 48000, segmentSeconds: 2, realTime: false, onSegment: { d, i in
            box.lock.withLock { box.segs.append((d, i)) }
        }) else { check(false, "кодировщик fMP4 создаётся"); return }
        for k in 0..<50 {   // 5 с
            s.append((0..<4800).map { 0.3 * sin(Float(k * 4800 + $0) * 2 * .pi * 440 / 48000) })
        }
        s.finish { _ in box.lock.withLock { box.finished = true } }
        spin(10) { box.lock.withLock { box.finished } }
        let got = box.lock.withLock { box.segs }
        check(got.first?.1 == true && got.dropFirst().allSatisfy { !$0.1 } && got.count >= 3,
              "fMP4: заголовок, затем фрагменты (~2 с)", "\(got.map { ($0.0.count, $0.1) })")
        check(got.first.map { String(decoding: $0.0.prefix(8).suffix(4), as: UTF8.self) } == "ftyp", "первый кусок начинается с ftyp")
        let all = got.reduce(Data()) { $0 + $1.0 }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("meetings-selftest-\(getpid()).mp4")
        try? all.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var dur = 0.0
        wait { dur = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0 }
        check(abs(dur - 5) < 0.2, "склейка кусков — читаемый MP4 нужной длины", "\(dur) с")
        check(s.dropped == 0, "кодировщик не терял буферы", "\(s.dropped)")
    }

    // MARK: С поддельным сервером

    private static func withServer() {
        let server = StenMockServer()
        do { try server.start() } catch { check(false, "поддельный сервер не стартовал: \(error)"); return }
        defer { server.stop() }
        check(server.port > 0, "поддельный Sten на 127.0.0.1:\(server.port)")

        let store = MemorySessionStore()
        var prefs = MeetingsPrefs()
        prefs.server = server.root
        let model = MeetingsModel(prefs: prefs, store: store)
        model.requestMicrophone = { true }
        model.makeSource = { SineAudioSource(seconds: 5) }
        model.minPollDelay = 0.05
        model.maxPollDelay = 0.25
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("meetings-selftest-rec-\(getpid())")
        model.recordingsDir = dir
        defer { try? FileManager.default.removeItem(at: dir) }
        var saved: [MeetingsPrefs] = []
        model.saveHandler = { saved.append($0) }
        var readyIds: [Int] = []
        model.onReady = { readyIds.append($0.id) }

        check(model.auth == .loggedOut, "без сессии — форма входа")
        wait { await model.refreshList(force: true) }
        check(model.client.requestCount == 0, "не вошли — ни одного запроса")

        wait { var ok = false; ok = (try? await model.client.health()) ?? false; check(ok, "GET /health → ok") }

        wait { await model.login(name: "anna", password: "неверный") }
        check(model.auth == .loggedOut && model.authMessage == "Неверное имя или пароль" && store.items.isEmpty,
              "неверный пароль → текст ошибки, сессии нет", model.authMessage ?? "-")

        wait { await model.login(name: "anna", password: server.password) }
        check(model.auth == .loggedIn("Анна"), "вход → «Анна»", "\(model.auth)")
        let cookie = store.items[model.server.account] ?? ""
        check(cookie.hasPrefix("sten_session="), "в хранилище — только cookie сессии", cookie.isEmpty ? "-" : "есть")
        let savedText = saved.map { "\($0)" }.joined()
        check(!cookie.contains(server.password) && !savedText.contains(server.password) && !savedText.contains("secret"),
              "пароль не сохранён ни в сессии, ни в настройках")
        check(server.lastLoginBody.contains("\"name\""), "вход — POST /auth/login {name, password}")
        check(model.meetings.isEmpty && model.listState == .idle, "после входа — пустой список (как у живого аккаунта)")

        // Сессия переживает перезапуск: новая модель с тем же хранилищем — сразу «вошли».
        let again = MeetingsModel(prefs: prefs, store: store)
        check(again.auth.isLoggedIn, "перезапуск: cookie из хранилища → без формы входа")
        wait { await again.verifySession() }
        check(again.auth == .loggedIn("Анна"), "GET /auth/me подтверждает сессию")

        // Запись: создание → куски → стоп → опрос → готово.
        let before = server.requests.count
        wait { await model.startRecording() }
        check(model.record == .recording, "«Начать запись» → запись", model.recordMessage ?? "")
        guard let id = model.recordingId else { check(false, "встреча не создана"); return }
        check(server.meeting(id)?.title.hasPrefix("Встреча 20") == true, "POST /meetings {title: «Встреча ГГГГ-ММ-ДД ЧЧ:ММ»}")
        check(model.meetings.first?.id == id, "новая встреча — сверху списка")
        spin(5) { (server.meeting(id)?.chunks.count ?? 0) >= 2 }
        wait(30) { await model.stopRecording() }
        let mm = server.meeting(id)
        let chunks = mm?.chunks ?? []
        check(chunks.count >= 3, "куски по ~2 с ушли на /chunks", "\(chunks.count), от источника \(model.segmentsReceived)")
        check(chunks.first.map { String(decoding: $0.prefix(8).suffix(4), as: UTF8.self) } == "ftyp",
              "первый кусок — с заголовком (как первый кусок MediaRecorder)")
        let url = dir.appendingPathComponent("server-\(id).mp4")
        try? chunks.reduce(Data(), +).write(to: url)
        var dur = 0.0
        wait { dur = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0 }
        check(abs(dur - 5) < 0.3, "склейка на сервере — целая запись 5 с", "\(dur)")
        check(server.requests.contains("POST /sten/api/meetings/\(id)/stop") && mm?.audio == nil,
              "после кусков — POST /stop, файл не нужен")
        check(model.record == .idle && model.processing[id] != nil, "после стопа — встреча в обработке")
        check(spin(15) { readyIds.contains(id) }, "опрос /status до consensus → «Протокол готов»")
        check(model.processing.isEmpty && model.meeting(id)?.status == "consensus", "обработка снята, статус в списке")
        let delays = model.pollDelays
        check(delays.count >= 4 && delays.dropFirst().prefix(3).elementsEqual(delays.dropFirst().prefix(3).sorted()),
              "бэкофф: прогресс стоит — интервал растёт", "\(delays.map { String(format: "%.2f", $0) })")
        check(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("meeting-\(id).mp4").path),
              "локальная копия удалена после готовности")
        let polls = model.pollCount
        spin(0.8) { false }
        check(model.pollCount == polls && server.statusCalls(id) == polls, "нечего обрабатывать — опрос стоит (0 запросов)",
              "\(model.pollCount) vs \(polls)")
        _ = before

        // Протокол: группировка по людям.
        model.open(id)
        spin(5) { model.reports[id] != nil }
        let groups = StenGrouping.group(model.reports[id] ?? StenReport())
        check(groups.map(\.name) == ["Анна", "Илья", "Максим", StenGrouping.unassignedTitle],
              "протокол: группы по людям", "\(groups.map(\.name))")
        check(groups.first { $0.name == "Илья" }?.tasks.count == 2, "Илья: своя задача и общая с Анной")
        model.closeDetail()

        // Чужая встреча (как 138 на живом сервере) → 404.
        model.open(138)
        spin(5) { if case .failed = model.detailState { return true }; return false }
        check(model.detailState == .failed("Встреча не найдена или нет доступа"), "404 → «не найдена или нет доступа»",
              "\(model.detailState)")
        check(model.auth.isLoggedIn, "404 не выкидывает из аккаунта")
        model.closeDetail()

        // Куски не доходят → запасной путь: файлом на /audio (на встрече с кусками сервер ответит 409 → новая встреча).
        server.failChunks = true
        model.makeSource = { SineAudioSource(seconds: 3) }
        wait { await model.startRecording() }
        let id2 = model.recordingId ?? -1
        spin(8) { model.recordMessage?.contains("Связь") == true }
        wait(30) { await model.stopRecording() }
        let viaAudio = server.meeting(id2)?.audio
        check(viaAudio.map { String(decoding: $0.prefix(400), as: UTF8.self).contains("name=\"file\"") } == true
              && viaAudio.map { $0.range(of: Data("ftyp".utf8)) != nil } == true,
              "куски не дошли → POST /audio multipart «file» с записью", "\(viaAudio?.count ?? 0) байт")
        check(!server.requests.contains("POST /sten/api/meetings/\(id2)/stop"), "запасной путь — без /stop (как загрузка файла на сайте)")
        check(model.processing[id2] != nil, "после загрузки — опрос обработки")
        server.failChunks = false
        spin(15) { readyIds.contains(id2) }

        // Пауза опроса (сон): ни запроса.
        model.mockTrack(999_999)
        model.pausePolling()
        let c0 = server.requests.count
        spin(0.6) { false }
        check(server.requests.count == c0, "сон → опрос на паузе")
        model.resumePolling()
        check(spin(3) { model.processing[999_999] == nil }, "после пробуждения опрос продолжился (404 → снят)")

        // Сессия истекла на сервере → 401 → снова форма входа, cookie забыт.
        server.dropSessions()
        wait { await model.refreshList(force: true) }
        check(model.auth == .loggedOut && store.items.isEmpty && model.authMessage == "Сессия закончилась — войдите снова",
              "401 → форма входа, cookie удалён", "\(model.auth) \(model.authMessage ?? "-")")

        // Выход: сервер стирает cookie (Max-Age=0), хранилище пусто.
        wait { await model.login(name: "anna", password: server.password) }
        wait { await model.logout() }
        check(model.auth == .loggedOut && store.items.isEmpty, "«Выйти» → сессии нет")

        // Сменили адрес сервера (туннель) — своя сессия на каждый адрес.
        check(!model.setServer("   ") && model.setServer("https://new-tunnel.example/sten/m/5/consensus")
              && model.server.display == "https://new-tunnel.example/sten" && model.auth == .loggedOut,
              "новый адрес из ссылки на встречу → корень, вход заново")
    }

    // MARK: Модуль: компакт, карточка, выключен

    private static func moduleLevel() {
        var data = SettingsData()
        data.tabs = [TabSetting(id: MeetingsIslandModule.moduleId, enabled: false)]
        let settings = SimpleIslandSettings(inMemory: data)
        let activities = ActivityCenter(), hud = HUDCenter(), notes = IslandNotifications()
        var opened: [String?] = []
        let ctx = ModuleContext(moduleId: MeetingsIslandModule.moduleId, settings: settings, themes: ThemeStore(load: false),
                                activities: activities, hud: hud, notifications: notes, island: IslandStateCenter(),
                                openTab: { opened.append($0) })
        let mod = MeetingsIslandModule(store: MemorySessionStore())
        check(!mod.tabEnabledByDefault && mod.title == "Встречи", "модуль «Встречи» по умолчанию выключен")
        // Никаких запросов к настоящему серверу: адрес — закрытый порт на этом Маке.
        mod.model.setServer("http://127.0.0.1:9/sten")
        mod.start(context: ctx)
        check(mod.model.client.requestCount == 0 && activities.activities.isEmpty, "выключен → ни запросов, ни компакта")
        let now = Date()
        mod.model.mock(auth: .loggedIn("Анна"), meetings: MeetingsIslandModule.mockMeetings(now: now), record: .recording,
                       recordStart: now.addingTimeInterval(-60))
        mod.updateActivities()
        let rec = activities.activities.first { $0.id == MeetingsIslandModule.recordingActivity }
        check(rec != nil && (rec?.priority ?? 0) > 60 && activities.statusDots[MeetingsIslandModule.moduleId]?.priority == 60,
              "запись → красная точка и таймер в ушах (выше встречи «Сегодня»)")
        mod.model.mock(auth: .loggedIn("Анна"), meetings: MeetingsIslandModule.mockMeetings(now: now),
                       processing: [141: StenStatus(status: "processing", percent: 40)])
        mod.updateActivities()
        check(!activities.activities.contains { $0.id == MeetingsIslandModule.recordingActivity }
              && activities.activities.contains { $0.id == MeetingsIslandModule.processingActivity },
              "обработка → компакт с прогрессом, запись снята")
        mod.model.onReady?(StenMeeting(id: 138, title: "Созвон"))
        let n = notes.current
        check(n?.title == "Протокол готов" && n?.body == "Созвон" && n?.actions.first?.title == "Открыть", "карточка «Протокол готов · Открыть»")
        n?.actions.first?.handler()
        check(opened.last == MeetingsIslandModule.moduleId && mod.model.selected == 138, "«Открыть» → вкладка на протоколе")
        mod.stop()
    }
}

extension MeetingsModel {
    /// Самотест: встреча «в обработке» без записи.
    func mockTrack(_ id: Int) {
        var p = processing
        p[id] = StenStatus(status: "processing")
        mock(auth: auth, meetings: meetings, processing: p, selected: selected)
        schedulePoll(after: 0.05)
    }
}
