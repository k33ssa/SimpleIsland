import AppKit
import Combine
import Foundation
import IslandCore

/// Самотест модуля Vafa без экрана и без настоящей Vafa: `SimpleIsland --selftest-vafa`.
/// Файл статуса — во временном каталоге (живой `/usr/local/var/vpn-guard` не читается и не трогается).
/// Проверяет разбор, фазы, слежение за файлом (появление каталога, запись на месте, атомарная замена, удаление),
/// паузу слушателя в спокойствии, сон, и реакцию модуля: компакт, точку, карточку, вспышку, включение/выключение.
@MainActor
public enum VafaSelfTest {
    private static var passes = 0
    private static var failures = 0

    private static func check(_ ok: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
        if ok { passes += 1; print("ok    \(what)") } else { failures += 1; print("ПРОВАЛ \(what) \(detail())") }
    }

    /// Крутить главный цикл, пока условие не станет истинным (события DispatchSource приходят на главную очередь).
    @discardableResult
    private static func spin(_ timeout: TimeInterval = 3, until cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !cond() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return cond()
    }

    private static func spinFor(_ t: TimeInterval) { spin(t) { false } }

    public static func run() -> Int32 {
        _ = NSApplication.shared
        passes = 0; failures = 0
        parsing()
        phases()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("simpleisland-vafa-\(getpid())-\(UInt32.random(in: 0...UInt32.max))")
        defer { try? FileManager.default.removeItem(at: tmp) }
        watching(tmp.appendingPathComponent("w"))
        module(tmp.appendingPathComponent("m"))
        print("\nVafa selftest: \(passes) passed, \(failures) failed")
        return failures == 0 ? 0 : 1
    }

    // MARK: Разбор и фазы

    static let sample = #"{"time":1794636835,"state":"up","vpn":true,"iface":"utun225","country":"DE","on_down":"freeze","apps":[{"path":"/Applications/Claude.app","locked":false,"procs":28,"frozen":0}],"cli":{"locked":false,"procs":6,"frozen":0}}"#
    static let real = #"{"time":1794636835,"cycle":36222,"state":"up","vpn":true,"iface":"utun225","proxy":"","net":"via:utun225","net_ok":true,"net_error":"","country":"DE","on_down":"freeze","geo":true,"countries":["BY","CN"],"apps":[{"path":"/Applications/Claude.app","locked":false,"procs":33,"frozen":0},{"path":"/Applications/VLC.app","locked":false,"procs":0,"frozen":0}],"cli":{"locked":false,"procs":8,"frozen":0}}"#

    private static func parsing() {
        let s = VafaStatus.parse(Data(sample.utf8))
        check(s?.state == "up" && s?.vpn == true && s?.iface == "utun225" && s?.country == "DE" && s?.onDown == "freeze",
              "разбор: поля верхнего уровня")
        check(s?.apps.first?.name == "Claude" && s?.apps.first?.procs == 28, "разбор: имя приложения из path")
        check(s?.cli?.name == VafaStatus.cliName && s?.cli?.procs == 6, "разбор: CLI без path → «Claude Code в терминале»")
        let r = VafaStatus.parse(Data(real.utf8))
        check(r?.apps.count == 2 && r?.cli?.procs == 8, "разбор: лишние поля (net, geo, countries) не мешают")
        check(VafaStatus.parse(Data("{\"state\":".utf8)) == nil, "обрезанный файл → nil")
        check(VafaStatus.parse(Data()) == nil, "пустой файл → nil")
        let partial = VafaStatus.parse(Data(#"{"state":"down"}"#.utf8))
        check(partial?.state == "down" && partial?.apps.isEmpty == true && partial?.vpn == false, "без полей — по умолчанию")
        check(VafaStatus.list(["A"]) == "A" && VafaStatus.list(["A", "B"]) == "A и B"
              && VafaStatus.list(["A", "B", "C"]) == "A, B и C", "список имён по-русски")
    }

    private static func phases() {
        let now = Date()
        var s = VafaStatus(time: now.timeIntervalSince1970, apps: [.init(path: "/Applications/Claude.app", procs: 3)])
        check(VafaPhase.of(s, now: now) == .ok, "фаза: up без заморозки → всё работает")
        s.state = "unsure"; s.vpn = false
        check(VafaPhase.of(s, now: now) == .checking, "фаза: unsure без заморозки → проверяю (без тревоги)")
        s.state = "down"
        check(VafaPhase.of(s, now: now) == .triggered, "фаза: down → охрана сработала")
        s.state = "up"; s.vpn = true; s.apps[0].frozen = 2
        check(VafaPhase.of(s, now: now) == .triggered, "фаза: что-то заморожено → сработала")
        s.apps[0].frozen = 0; s.cli = .init(path: VafaStatus.cliName, locked: true)
        check(VafaPhase.of(s, now: now) == .triggered, "фаза: запуск CLI запрещён → сработала")
        s.cli = nil; s.time = now.timeIntervalSince1970 - 600
        check(VafaPhase.of(s, now: now) == .stale, "фаза: файл не обновлялся 10 мин → не отвечает")
        check(VafaPhase.of(nil, now: now) == .notInstalled, "фаза: нет файла → не установлена")
        check(VafaPhase.of(nil, now: now, installed: true) == .notRunning, "фаза: нет файла, но Vafa стоит → не запущена")
        // unsure: маршрут через VPN (страна не подтверждена) против паузы GRACE (VPN пропал)
        let grace = VafaIslandModule.mockGrace, country = VafaIslandModule.mockUnsureCountry
        check(!grace.routeIsVPN && country.routeIsVPN && grace.netClosed, "unsure: GRACE (en0) отличается от «страна не подтверждена» (utun)")
        var px = grace; px.proxy = "http://127.0.0.1:10808"
        check(px.routeIsVPN, "unsure: VPN-клиент в режиме прокси — маршрут через VPN")
        let r = VafaStatus.parse(Data(real.utf8))
        check(r?.net == "via:utun225" && r?.netClosed == false, "разбор: net (фильтр сети)")
        // Компакт: заморожено 3 (VLC — только запрет запуска)
        let t = VafaIslandModule.mockTriggered
        check(t.frozenItems.count == 3 && t.blocked.count == 4, "заморожено 3 из 4 заблокированных", "\(t.frozenItems.count)/\(t.blocked.count)")
    }

    // MARK: Слежение за файлом

    private static func json(_ s: VafaStatus) -> Data {
        var d: [String: Any] = ["time": s.time, "state": s.state, "vpn": s.vpn, "iface": s.iface,
                                "country": s.country, "on_down": s.onDown,
                                "apps": s.apps.map { ["path": $0.path, "locked": $0.locked, "procs": $0.procs, "frozen": $0.frozen] }]
        if let c = s.cli { d["cli"] = ["locked": c.locked, "procs": c.procs, "frozen": c.frozen] }
        return (try? JSONSerialization.data(withJSONObject: d)) ?? Data()
    }

    private static func ok(_ t: TimeInterval = Date().timeIntervalSince1970) -> VafaStatus {
        VafaStatus(time: t, apps: [.init(path: "/Applications/Claude.app", procs: 3)], cli: .init(path: VafaStatus.cliName, procs: 1))
    }
    private static func triggered() -> VafaStatus {
        VafaStatus(state: "down", vpn: false, iface: "", apps: [.init(path: "/Applications/Claude.app", locked: true, procs: 3, frozen: 3)],
                   cli: .init(path: VafaStatus.cliName, locked: true, procs: 1, frozen: 1))
    }

    /// Как vpn-guard: tmp + mv поверх.
    private static func atomicWrite(_ d: Data, _ url: URL) {
        let tmp = url.appendingPathExtension("tmp")
        try? d.write(to: tmp)
        _ = rename(tmp.path, url.path)
    }

    private static func watching(_ root: URL) {
        let dir = root.appendingPathComponent("var/vpn-guard")
        let file = dir.appendingPathComponent("status.json")
        let m = VafaModel(statusURL: file)
        m.calmPause = 0.4
        m.installMarkers = []
        var events: [VafaPhase] = []
        var statusEvents = 0
        m.onPhaseChange = { _, new, _ in events.append(new) }
        m.onStatusChange = { _ in statusEvents += 1 }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        m.start()
        check(m.phase == .notInstalled && events == [.notInstalled], "нет каталога → «не установлена», одно событие")
        check(!m.isListening, "нет каталога → слушаем ближайший существующий каталог, не файл")

        // Установили: каталог и файл появились.
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        atomicWrite(json(ok()), file)
        check(spin { m.phase == .ok }, "каталог и файл появились → «всё работает»", "фаза \(m.phase)")
        check(spin { m.isListening || m.readCount > 0 }, "после появления — слушатель файла висит или на паузе")

        // Спокойно: после прочтения слушатель на паузе, потом вешается снова.
        spin(2) { m.isListening }
        atomicWrite(json(ok(Date().timeIntervalSince1970 + 1)), file)
        check(spin { !m.isListening }, "спокойно: после события слушатель снят на паузу (энергия)")
        let reads = m.readCount
        check(spin(2) { m.isListening && m.readCount > reads }, "после паузы — одно прочтение и слушатель снова", "чтений \(m.readCount - reads)")

        // Только время круга поменялось — ни фазы, ни статуса.
        let ev0 = events.count, st0 = statusEvents
        atomicWrite(json(ok(Date().timeIntervalSince1970 + 2)), file)
        spinFor(0.5)
        check(events.count == ev0 && statusEvents == st0, "поменялось только время круга → событий нет")

        // Охрана сработала: атомарная замена.
        spin(2) { m.isListening }
        atomicWrite(json(triggered()), file)
        check(spin { m.phase == .triggered }, "атомарная замена → «сработала»", "фаза \(m.phase)")
        check(events.last == .triggered, "событие смены фазы пришло")
        check(m.isListening, "пока сработала — слушаем без пауз")

        // Запись на месте (без замены): ещё одно приложение заморожено.
        var t2 = triggered(); t2.apps.append(.init(path: "/Applications/VLC.app", locked: true, procs: 1, frozen: 1))
        let st1 = statusEvents
        try? json(t2).write(to: file)
        check(spin { statusEvents > st1 }, "запись на месте → статус обновился внутри фазы")
        check(m.status?.blocked.count == 3, "заморожено три пункта")

        // Обрезанный файл посреди записи — состояние не теряется.
        try? Data("{\"state\":".utf8).write(to: file)
        spinFor(0.4)
        check(m.phase == .triggered && m.status?.blocked.count == 3, "обрезанный файл → прежнее состояние")

        // Служба умерла посреди тревоги: записей нет — тикер раз в 30 с замечает старый `time`.
        check(m.isCheckingStale, "сработала → проверка «служба замолчала» по тикеру висит")
        m.checkStale(now: Date().addingTimeInterval(VafaPhase.staleAfter + 30))
        check(m.phase == .stale, "файл битый и старый → всё равно «не отвечает»", "фаза \(m.phase)")
        atomicWrite(json(triggered()), file)
        check(spin { m.phase == .triggered }, "служба ожила → снова «сработала»")
        m.checkStale(now: Date().addingTimeInterval(VafaPhase.staleAfter - 10))
        check(m.phase == .triggered, "запись свежая → фаза прежняя")
        m.checkStale(now: Date().addingTimeInterval(VafaPhase.staleAfter + 30))
        check(m.phase == .stale && !m.isCheckingStale, "запись старше 2 мин → «не отвечает», тикер снят", "фаза \(m.phase)")

        // Вернулось.
        atomicWrite(json(ok()), file)
        check(spin { m.phase == .ok }, "VPN вернулся → «всё работает»")
        check(m.isCheckingStale, "всё работает → проверка «служба замолчала» висит")

        // unsure (пауза GRACE/страна): тоже спокойно — слушатель на паузе, как в «всё работает».
        spin(2) { m.isListening }
        var u = ok(); u.state = "unsure"; u.vpn = false
        atomicWrite(json(u), file)
        check(spin { m.phase == .checking }, "unsure → «проверяю»")
        check(spin { !m.isListening }, "проверяю: слушатель снят на паузу (файл пишется каждую секунду)")
        check(spin(2) { m.isListening }, "проверяю: после паузы слушатель снова")
        atomicWrite(json(ok()), file)
        check(spin { m.phase == .ok }, "страна подтверждена → «всё работает»")

        // Сон: слушатель снят, запись не замечается; пробуждение — перечитали.
        spin(2) { m.isListening }
        m.pause()
        check(!m.isListening, "сон → слушатель снят")
        atomicWrite(json(triggered()), file)
        spinFor(0.5)
        check(m.phase == .ok, "во сне запись не читается")
        m.resume()
        check(m.phase == .triggered && m.isListening, "пробуждение → перечитали и слушаем")

        // Удалили (Vafa снесли) → «не установлена»; поставили снова → читается.
        m.installMarkers = []
        try? FileManager.default.removeItem(at: file)
        check(spin { m.phase == .notInstalled }, "файл удалён → «не установлена»")
        m.installMarkers = [root.path]
        m.reload()
        check(m.phase == .notRunning, "файла нет, но Vafa стоит → «не запущена»")
        atomicWrite(json(ok()), file)
        check(spin { m.phase == .ok }, "файл снова появился → «всё работает»")

        m.stop()
        check(!m.isListening && !m.isRunning, "stop → всё снято")
    }

    // MARK: Модуль целиком

    private static func module(_ root: URL) {
        let dir = root.appendingPathComponent("vpn-guard")
        let file = dir.appendingPathComponent("status.json")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        atomicWrite(json(ok()), file)

        var data = SettingsData()
        data.tabs = [TabSetting(id: "vafa", enabled: false)]
        let settings = SimpleIslandSettings(inMemory: data)
        let activities = ActivityCenter(), hud = HUDCenter(), notes = IslandNotifications()
        var opened: [String?] = []
        let ctx = ModuleContext(moduleId: "vafa", settings: settings, themes: ThemeStore(load: false),
                                activities: activities, hud: hud, notifications: notes, island: IslandStateCenter(),
                                openTab: { opened.append($0) })
        let mod = VafaIslandModule(statusURL: file)
        mod.model.calmPause = 0.3
        mod.model.installMarkers = []
        check(!mod.tabEnabledByDefault, "модуль по умолчанию выключен")
        mod.start(context: ctx)
        check(!mod.model.isRunning, "выключен → файл не читается и не слушается")

        settings.data.tabs[0].enabled = true
        check(spin { mod.model.isRunning && mod.model.phase == .ok }, "включили из каталога → читает, «всё работает»")
        check(activities.activities.isEmpty && activities.statusDots["vafa"] == nil, "всё работает → ни компакта, ни точки")

        spin(2) { mod.model.isListening }
        atomicWrite(json(triggered()), file)
        check(spin { mod.model.phase == .triggered }, "охрана сработала → фаза")
        check(activities.activities.contains { $0.id == "vafa.guard" }, "компакт с замком")
        check(activities.statusDots["vafa"]?.priority == 100, "красная живая точка (приоритет 100)")
        let n = notes.current
        check(n?.title == "Vafa: VPN выключен" && (n?.body.hasPrefix("Заморожено: Claude") ?? false),
              "карточка «Vafa: VPN выключен — заморожено: Claude, …»", "\(n?.title ?? "-") / \(n?.body ?? "-")")
        n?.actions.first?.handler()
        check(opened.last == "vafa", "«Показать» раскрывает вкладку Vafa")

        // Тревога длится: меняется только число процессов — компакт не публикуется заново.
        var posts = 0
        let sub = activities.$activities.dropFirst().sink { _ in posts += 1 }
        var t1 = triggered(); t1.apps[0].procs = 5; t1.apps[0].frozen = 5
        atomicWrite(json(t1), file)
        check(spin { mod.model.status?.apps.first?.procs == 5 }, "статус с другим числом процессов прочитан")
        check(posts == 0, "только процессы → компакт не перерисовывается", "публикаций \(posts)")
        var t3 = t1; t3.apps.append(.init(path: "/Applications/VLC.app", locked: true))
        atomicWrite(json(t3), file)
        check(spin { posts > 0 }, "добавился заблокированный → компакт обновился")
        sub.cancel()

        atomicWrite(json(ok()), file)
        check(spin { mod.model.phase == .ok }, "VPN вернулся")
        check(!activities.activities.contains { $0.id == "vafa.guard" } && activities.statusDots["vafa"] == nil,
              "компакт и точка сняты")
        check(hud.current?.kind == "vafa", "вспышка «Vafa: всё снова работает»")

        settings.data.tabs[0].enabled = false
        check(spin { !mod.model.isRunning }, "выключили → слушатель снят")
        mod.stop()
    }
}
