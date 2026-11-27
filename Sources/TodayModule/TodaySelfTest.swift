import AppKit
import CoreAudio
import EventKit
import IslandCore

/// `SimpleIsland --selftest-today [--net]` — проверка логики модуля без GUI и без прав.
/// Системные настройки не меняет (тёмная тема, микрофон, Finder — только чтение).
@MainActor
public enum TodaySelfTest {
    private static var failures = 0
    private static var passes = 0

    private static func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if ok { passes += 1; print("  ok   \(name)") } else {
            failures += 1; print("  FAIL \(name) \(detail())")
        }
    }

    private static func info(_ s: String) { print("  info \(s)") }

    /// Дождаться async-задачи, крутя главный цикл (самотест синхронный).
    private static func waitFor<T>(_ timeout: TimeInterval = 20, _ op: @escaping @MainActor () async -> T) -> T? {
        let box = Box<T>()
        Task { @MainActor in box.value = await op(); box.done = true }
        let deadline = Date().addingTimeInterval(timeout)
        while !box.done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return box.value
    }

    @MainActor private final class Box<T> { var value: T?; var done = false }

    public static func run(network: Bool) -> Int32 {
        _ = NSApplication.shared
        // pid-файлы детей (ManagedProcess) — во временном каталоге, а не в каталоге приложения: упавший самотест
        // не оставит «сирот» на проверку работающему приложению.
        let pidDir = FileManager.default.temporaryDirectory.appendingPathComponent("si-today-selftest-pids-\(getpid())")
        ManagedProcess.pidDirectory = pidDir
        defer { try? FileManager.default.removeItem(at: pidDir) }
        print("Сегодня — самотест")

        print("[ссылки встреч]")
        let links: [(String, String?)] = [
            ("Zoom https://us02web.zoom.us/j/81234567890?pwd=abcDEF123 до встречи", "Zoom"),
            ("https://zoom.us/my/ivanov", "Zoom"),
            ("Join: https://meet.google.com/abc-defg-hij?authuser=0", "Google Meet"),
            ("<a href=\"https://teams.microsoft.com/l/meetup-join/19%3ameeting_ABC%40thread.v2/0?context=x\">Join</a>", "Teams"),
            ("https://teams.live.com/meet/9876543210", "Teams"),
            ("Телемост: https://telemost.yandex.ru/j/12345678901234.", "Телемост"),
            ("https://telemost.360.yandex.ru/j/5566778899", "Телемост"),
            ("https://kontur.ktalk.ru/abc123xyz", "Контур.Толк"),
            ("https://meet.jit.si/SimpleIslandDaily", "Jitsi"),
            ("Аудитория 305, второй этаж", nil),
            ("https://example.com/zoom.us/j/1", nil),
        ]
        for (text, want) in links {
            let got = MeetingLinks.find(in: text)
            check(got?.service == want, "«\(text.prefix(48))» → \(want ?? "нет")", "получено \(got?.service ?? "нет") \(got?.url.absoluteString ?? "")")
        }
        let tele = MeetingLinks.find(in: "Телемост: https://telemost.yandex.ru/j/12345678901234.")
        check(tele?.url.absoluteString == "https://telemost.yandex.ru/j/12345678901234", "хвостовая точка отрезана")
        let order = MeetingLinks.find(in: "сначала https://meet.google.com/abc-defg-hij потом https://zoom.us/j/1")
        check(order?.service == "Google Meet", "берётся самая ранняя ссылка в тексте")
        check(MeetingLinks.find(url: URL(string: "https://zoom.us/j/42"), location: "https://meet.google.com/abc-defg-hij", notes: nil)?.service == "Zoom",
              "поле url важнее location")
        if let z = MeetingLinks.find(in: "https://us02web.zoom.us/j/81234567890?pwd=abc") {
            let u = MeetingLinks.preferredOpenURL(z, zoomAppInstalled: true).absoluteString
            check(u.hasPrefix("zoommtg://us02web.zoom.us/join?action=join&confno=81234567890&pwd=abc"), "Zoom → zoommtg://", u)
        }

        print("[события]")
        let now = TodayMocks.mockNow()
        let evs = TodayMocks.events(now: now)
        check(EventLogic.featured(evs, now: now)?.main.id == "m2", "следующее — созвон 15:00")
        check(EventLogic.featured(evs, now: now.addingTimeInterval(15 * 60))?.main.id == "m2", "идущее со ссылкой остаётся главным")
        // Встречи внахлёст: «Работа 9–18» (без ссылки) и созвон в 15:00.
        let cal = Calendar.current
        let work = TodayEvent(id: "w", title: "Работа", start: cal.date(bySettingHour: 9, minute: 0, second: 0, of: now)!,
                              end: cal.date(bySettingHour: 18, minute: 0, second: 0, of: now)!)
        let call = evs.first { $0.id == "m2" }!
        let both = [work, call]
        let f1 = EventLogic.featured(both, now: now)
        check(f1?.main.id == "m2" && f1?.ongoing?.id == "w", "внахлёст: главный — созвон, «Сейчас: Работа» второй строкой", "\(String(describing: f1))")
        check(EventLogic.upcoming(both, now: now, grace: 180)?.id == "m2", "напоминание — по созвону, а не по идущей работе")
        check(EventLogic.upcoming(both, now: call.start.addingTimeInterval(120), grace: 180)?.id == "m2", "напоминание держится 3 мин после начала")
        check(EventLogic.upcoming(both, now: call.start.addingTimeInterval(200), grace: 180) == nil, "и потом снимается")
        check(EventLogic.featured(both, now: call.start.addingTimeInterval(600))?.main.id == "m2", "во время созвона — он (есть ссылка)")
        check(EventLogic.featured(both, now: call.end.addingTimeInterval(60))?.main.id == "w", "после созвона — снова «Сейчас: Работа»")
        let tea = TodayEvent(id: "t", title: "Чай", start: call.start.addingTimeInterval(20 * 60), end: call.end)
        let f2 = EventLogic.featured([call, tea], now: tea.start.addingTimeInterval(-120))
        check(f2?.main.id == "t" && f2?.ongoing?.id == "m2", "через 2 мин начнётся другое — оно главное")
        check(EventLogic.stamp(now.addingTimeInterval(-86400), now: now).hasPrefix("вчера "), "отметка «вчера HH:mm»")
        check(EventLogic.today(evs, now: now).count == 3, "на полосе — только сегодняшние")
        let c1 = EventLogic.countdown(to: now.addingTimeInterval(12 * 60), end: now.addingTimeInterval(3600), now: now)
        check(c1.value == "12" && c1.unit == " мин", "отсчёт 12 мин", "\(c1)")
        let c2 = EventLogic.countdown(to: now.addingTimeInterval(125 * 60), end: now.addingTimeInterval(9000), now: now)
        check(c2.value == "2:05" && c2.unit == " ч", "отсчёт 2:05 ч", "\(c2)")
        let c3 = EventLogic.countdown(to: now.addingTimeInterval(-60), end: now.addingTimeInterval(600), now: now)
        check(c3.value == "идёт", "идёт", "\(c3)")
        let c4 = EventLogic.countdown(to: now.addingTimeInterval(30), end: now.addingTimeInterval(600), now: now)
        check(c4.value == "1", "меньше минуты — «1 мин»", "\(c4)")
        let win = EventLogic.dayWindow(EventLogic.today(evs, now: now), now: now)
        check(Calendar.current.component(.hour, from: win.start) == 8 && Calendar.current.component(.hour, from: win.end) == 20,
              "окно полосы 8–20", "\(win)")
        let early = [TodayEvent(id: "e", title: "", start: TodayMocks.mockNow().addingTimeInterval(-8 * 3600), end: TodayMocks.mockNow().addingTimeInterval(-7 * 3600))]
        check(Calendar.current.component(.hour, from: EventLogic.dayWindow(early, now: now).start) == 6, "окно расширяется под раннее событие")
        check(EventLogic.people(["А", "Б", "В", "Г", "Д"]) == "А, Б, В и ещё 2", "участники «и ещё N»")

        print("[буфер обмена]")
        check(ClipRules.classify("#ff7a45").colorHex == "#FF7A45", "#RRGGBB → образец")
        check(ClipRules.classify("FF7A45").kind == .color, "RRGGBB без решётки → образец")
        check(ClipRules.classify("#FF7A4").kind != .color, "5 цифр — не цвет")
        check(ClipRules.classify("https://github.com/x/y").kind == .url, "ссылка")
        check(ClipRules.classify("swift build -c release\n--arch arm64").kind == .code, "команда → код")
        check(ClipRules.classify("Привет, как дела?").kind == .text, "обычный текст")
        check(!ClipRules.shouldRecord(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"], frontmostBundle: nil), "ConcealedType пропускается")
        check(!ClipRules.shouldRecord(types: ["public.utf8-plain-text", "org.nspasteboard.TransientType"], frontmostBundle: nil), "TransientType пропускается")
        check(!ClipRules.shouldRecord(types: ["public.utf8-plain-text"], frontmostBundle: "com.1password.1password"), "из 1Password не пишется")
        check(ClipRules.shouldRecord(types: ["public.utf8-plain-text"], frontmostBundle: "com.apple.Terminal"), "обычное пишется")
        check(ClipRules.looksSecret("ghp_A1b2C3d4E5f6G7h8I9j0KLMNOP") && !ClipRules.looksSecret("просто длинная фраза без цифр"), "похожее на токен на диск не пишется")
        var list: [ClipItem] = []
        for i in 0..<25 { list = ClipRules.inserting(ClipItem(kind: .text, text: "t\(i)", date: Date()), into: list) }
        check(list.count == 20 && list.first?.text == "t24", "история — 20 последних", "\(list.count)")
        list = ClipRules.inserting(ClipItem(kind: .text, text: "t10", date: Date()), into: list)
        check(list.count == 20 && list.first?.text == "t10" && list.filter { $0.text == "t10" }.count == 1, "дубль поднимается наверх")

        // Живой опрос на отдельном (не системном) буфере.
        let pbName = NSPasteboard.Name("SimpleIsland.selftest.\(getpid())")
        let pb = NSPasteboard(name: pbName)
        let hist = ClipboardHistory(pasteboard: pb)
        pb.clearContents(); pb.setString("секрет", forType: .string)
        pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        hist.poll()
        check(hist.items.isEmpty, "опрос: пароль с ConcealedType не записан")
        pb.clearContents(); pb.setString("#00AAFF", forType: .string)
        hist.poll()
        check(hist.items.first?.kind == .color, "опрос: цвет записан")
        pb.clearContents(); pb.setString("echo hi; ls -la", forType: .string)
        hist.poll(); hist.poll()
        check(hist.items.count == 2, "опрос: без изменения changeCount ничего не читается", "\(hist.items.count)")
        if let c = hist.items.last { hist.copyBack(c) }
        hist.poll()
        check(hist.items.count == 2 && hist.items.first?.kind == .color && pb.string(forType: .string) == "#00AAFF",
              "клик — вернуть в буфер, без дубля")
        pb.releaseGlobally()

        // Картинки: не больше 3 и 32 МБ, новые важнее.
        var imgs: [ClipItem] = []
        for i in 0..<5 {
            imgs = ClipRules.inserting(ClipItem(kind: .image, text: "img\(i)", date: Date(), imageData: Data(count: 1000)), into: imgs)
        }
        check(imgs.count == 3 && imgs.first?.text == "img4", "картинок в истории не больше 3", "\(imgs.map(\.text))")
        imgs = ClipRules.inserting(ClipItem(kind: .image, text: "big", date: Date(), imageData: Data(count: 15_000_000)), into: imgs)
        imgs = ClipRules.inserting(ClipItem(kind: .image, text: "big2", date: Date(), imageData: Data(count: 15_000_000)), into: imgs)
        imgs = ClipRules.inserting(ClipItem(kind: .image, text: "big3", date: Date(), imageData: Data(count: 15_000_000)), into: imgs)
        check(imgs.compactMap(\.imageData).reduce(0) { $0 + $1.count } <= ClipRules.maxImageBytes && imgs.first?.text == "big3",
              "картинок в истории не больше 32 МБ", "\(imgs.map(\.text))")
        // Превью из настоящей картинки.
        let bmp = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 800, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        if let png = bmp?.representation(using: .png, properties: [:]), let th = ClipRules.thumbnail(png) {
            check(max(th.width, th.height) <= 240, "превью картинки ≤ 240 px", "\(th.width)×\(th.height)")
        } else { check(false, "превью картинки") }
        // Файл истории: сразу 0600, без окна с правами по umask.
        let tmpFile = FileManager.default.temporaryDirectory.appendingPathComponent("simpleisland-selftest-\(getpid()).json")
        let oldMask = umask(0o022); defer { umask(oldMask) }
        check(ClipboardHistory.writePrivately(Data("[]".utf8), to: tmpFile), "запись истории")
        let perms = (try? FileManager.default.attributesOfItem(atPath: tmpFile.path)[.posixPermissions] as? Int) ?? -1
        check(perms == 0o600, "файл истории 0600", String(perms, radix: 8))
        check(ClipboardHistory.writePrivately(Data("[1]".utf8), to: tmpFile) && (try? Data(contentsOf: tmpFile)) == Data("[1]".utf8), "перезапись атомарно")
        try? FileManager.default.removeItem(at: tmpFile)

        print("[погода]")
        let sample = """
        {"latitude":59.94,"longitude":30.31,"utc_offset_seconds":10800,"timezone":"Europe/Moscow",
         "current":{"time":"2026-11-14T14:45","interval":900,"temperature_2m":-2.3,"apparent_temperature":-6.1,"weather_code":3,"is_day":1},
         "hourly":{"time":["2026-11-14T14:00","2026-11-14T15:00","2026-11-14T16:00","2026-11-14T17:00","2026-11-14T18:00"],
                   "temperature_2m":[-2.0,-2.4,-3.1,-3.4,null],"weather_code":[3,3,3,73,71]}}
        """
        do {
            let w = try WeatherAPI.parse(Data(sample.utf8), lat: 59.94, lon: 30.31)
            check(w.hours.count == 3 && w.hours.first.map { Calendar.current.dateComponents(in: TimeZone(secondsFromGMT: 10800)!, from: $0.time).hour == 15 } == true,
                  "часы после текущего, null пропущен", "\(w.hours.count)")
            check(WeatherAPI.degrees(w.temperature) == "−2°", "−2° с настоящим минусом")
            let at = w.hours.first!.time.addingTimeInterval(-600)
            check(WeatherAPI.summary(w, now: at).hasPrefix("Снег к "), "«Снег к …»", WeatherAPI.summary(w, now: at))
            check(w.hours(after: w.hours.last!.time).isEmpty && w.hours(after: at).count == 3, "без сети прошедшие часы отфильтрованы")
        } catch { check(false, "разбор ответа open-meteo", "\(error)") }
        check(WeatherAPI.degrees(0.4) == "0°" && WeatherAPI.degrees(3.6) == "4°", "округление градусов")

        check(WeatherAPI.isNetworkError(URLError(.notConnectedToInternet)) && !WeatherAPI.isNetworkError(URLError(.badServerResponse))
              && !WeatherAPI.isNetworkError(DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: ""))),
              "«нет сети» — только при ошибке подключения, не при 5xx/разборе")

        print("[процессы]")
        if let r = waitFor(20, { await Shell.run("/bin/sh", ["-c", "head -c 200000 /dev/zero >&2; echo done"], timeout: 10) }) {
            check(r.code == 0 && r.out.hasPrefix("done") && r.err.count == 200_000, "stderr > 64 КБ не вешает процесс", "code \(r.code) err \(r.err.count)")
        } else { check(false, "stderr > 64 КБ не вешает процесс", "тайм-аут") }

        // --- misc2 ---
        if let r = waitFor(20, { await Shell.run("/bin/sh", ["-c", "sleep 30 & sleep 30"], timeout: 1) }) {
            check(r.code != 0 && r.err.contains("не ответил"), "тайм-аут гасит процесс", "code \(r.code) «\(r.err)»")
        } else { check(false, "тайм-аут гасит процесс", "не вернулся за 20 с") }
        // Группа добита (SIGKILL через 2 с после SIGTERM, если не вышла) — живых детей не остаётся.
        let drained = { () -> Bool in
            let end = Date().addingTimeInterval(5)
            while !ManagedProcess.liveGroups.isEmpty && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            return ManagedProcess.liveGroups.isEmpty
        }()
        check(drained, "после запусков нет живых дочерних групп", "\(ManagedProcess.liveGroups)")
        if let r = waitFor(10, { await Shell.run("/nonexistent/tool", []) }) {
            check(r.code == -1, "нет программы — код −1 без падения")
        }

        print("[энергия: общий тикер]")
        let subs0 = SharedTicker.shared.subscriberCount
        let ch = ClipboardHistory(pasteboard: NSPasteboard(name: NSPasteboard.Name("SimpleIsland.selftest.tick.\(getpid())")))
        ch.start(persist: false)
        check(ch.isPolling && ClipboardHistory.pollInterval >= 1 && SharedTicker.shared.subscriberCount == subs0 + 1, "буфер: подписка на тикер (1 с — правило покоя), не Timer")
        ch.stop()
        check(!ch.isPolling && SharedTicker.shared.subscriberCount == subs0, "буфер: stop() отписывает")
        let sm = SystemMonitor()
        var samples = 0
        sm.onSample = { _ in samples += 1 }
        sm.setActive(true)
        check(sm.isActive && samples == 1 && SharedTicker.shared.subscriberCount == subs0 + 1, "нагрузка: первый замер сразу, дальше тикер 2 с")
        sm.setActive(false)
        check(!sm.isActive && SharedTicker.shared.subscriberCount == subs0, "нагрузка: вкладку закрыли — отписка")

        print("[микрофон: вернуть при выходе]")
        let fake = FakeMic()
        let tm = TodayModel()
        tm.mic = fake
        tm.toggle(.mic)
        check(fake.vol == 0 && tm.micOff && tm.prefs.micMutedByUs && tm.micDevice == fake.dev, "тумблер выключил вход, громкость запомнена",
              "vol \(fake.vol) off \(tm.micOff)")
        check(tm.prefs.micSavedVolume == 0.6, "сохранена прежняя громкость 0,6")
        tm.stop()   // так ядро зовёт его из applicationWillTerminate (меню «Выход», SIGTERM/SIGINT/SIGHUP)
        check(fake.vol == 0.6 && !fake.muted && !tm.prefs.micMutedByUs && !tm.micOff, "stop()/выход вернул громкость 0,6", "vol \(fake.vol)")
        let tm2 = TodayModel()
        tm2.mic = fake
        tm2.toggle(.mic)
        fake.dev = 77                       // вход сменили, пока микрофон выключен
        tm2.toggle(.mic)
        check(fake.restored.contains(42) && fake.restored.contains(77) && !tm2.prefs.micMutedByUs, "включение возвращает и прежнее устройство", "\(fake.restored)")
        tm2.stop()
        check(fake.restoreCalls == 3, "без выключения тумблером stop() микрофон не трогает", "\(fake.restoreCalls)")
        // --- /misc2 ---

        print("[камера]")
        let cam = CameraMirror()
        cam.stop()
        check(cam.state == .off, "stop() до старта — без падения")

        print("[система]")
        let t0 = SystemStats.cpuTicks()
        check(t0 != nil, "host_statistics(CPU) без прав")
        Thread.sleep(forTimeInterval: 0.4)
        if let a = t0, let b = SystemStats.cpuTicks() {
            let u = SystemStats.cpuUsage(from: a, to: b)
            check(u >= 0 && u <= 1, "ЦП 0…1", "\(u)"); info(String(format: "ЦП %.0f%%", u * 100))
        }
        if let m = SystemStats.memory() {
            check(m.used > 0 && m.used < m.total, "память: занято < всего")
            info(String(format: "ОЗУ %.1f из %.0f ГБ", m.used / 1_073_741_824, m.total / 1_073_741_824))
        } else { check(false, "host_statistics64(VM)") }
        info("thermalState: \(SystemStats.thermalTitle(ProcessInfo.processInfo.thermalState))")

        print("[батареи]")
        if let mac = Batteries.mac() { info("Mac: \(Int(mac.level * 100))%\(mac.charging ? " заряжается" : "")"); check(mac.level > 0 && mac.level <= 1, "батарея Mac 0…1") }
        else { info("батареи Mac нет") }
        let bt = Batteries.bluetooth()
        info("Bluetooth с зарядом: \(bt.isEmpty ? "нет" : bt.map { "\($0.name) \(Int($0.level * 100))%" }.joined(separator: ", "))")
        check(Batteries.item(from: ["Product": "Magic Mouse", "BatteryPercent": 18, "DeviceAddress": "aa"])?.name == "Мышь", "Magic Mouse → «Мышь»")
        check(Batteries.item(from: ["Product": "Apple Internal Keyboard / Trackpad", "BatteryPercent": 80, "Built-In": true]) == nil, "встроенная клавиатура пропущена")
        check(Batteries.item(from: ["Product": "Magic Keyboard"]) == nil, "без BatteryPercent — не показываем")

        print("[тумблеры — только чтение]")
        if let dev = MicControl.defaultInput() {
            info("вход: устройство \(dev), громкость \(MicControl.volume(dev).map { String(format: "%.2f", $0) } ?? "не настраивается"), элементы \(MicControl.volumeElements(dev)), mute \(MicControl.isMuted(dev).map { "\($0)" } ?? "нет")")
            check(!MicControl.volumeElements(dev).isEmpty || MicControl.isMuted(dev) != nil, "микрофон можно выключить (громкость или mute)")
        } else { info("нет устройства ввода") }
        info("тёмная тема: \(DarkMode.isOn), значки стола скрыты: \(CleanDesk.iconsHidden)")
        let aw = AwakeAssertion()
        check(aw.set(true) && aw.isOn, "IOPMAssertion «Не спать» создаётся")
        aw.set(false)
        check(!aw.isOn, "и снимается")
        check(FocusShortcut.pick(from: ["Перерыв", "Do Not Disturb"], preferred: "") == "Do Not Disturb", "ярлык ищется по стандартным именам")
        check(FocusShortcut.pick(from: ["Перерыв", "Не беспокоить"], preferred: "перерыв") == "Перерыв", "имя из настроек важнее")
        check(FocusShortcut.pick(from: ["Перерыв"], preferred: "") == nil, "нет ярлыка — тумблер скрыт")
        if let names = waitFor(20, { await FocusShortcut.list() }) {
            info("ярлыков: \(names.count), для «Тишины»: \(FocusShortcut.pick(from: names, preferred: "") ?? "нет — тумблер скрыт")")
        }

        print("[права — без запроса]")
        info("календарь: \(CalendarService.access), Info.plist-строка есть: \(CalendarService.canAskSystem) (нет → кнопка откроет Настройки, без системного запроса)")
        info("камера: \(CameraMirror.authorization.rawValue), Info.plist-строка есть: \(CameraMirror.canAskSystem)")

        print("[настройки и раскладка]")
        let partial = #"{"cityName":"Москва","tiles":[{"tile":"clipboard","enabled":false},{"tile":"event","enabled":true},{"tile":"event","enabled":false}]}"#
        if let p = try? JSONDecoder().decode(TodayPrefs.self, from: Data(partial.utf8)) {
            check(p.cityName == "Москва" && p.latitude == 59.94 && p.rememberClipboard == false, "неполный JSON — остальное по умолчанию")
            check(p.tiles.count == TodayTile.allCases.count && p.tiles.first?.tile == .clipboard && !p.isEnabled(.clipboard), "плитки без дублей, недостающие добавлены")
        } else { check(false, "разбор настроек") }
        let rows = TodayLayout.rows(TodayPrefs().enabledTiles)
        check(rows.map { $0.map(\.rawValue) } == [["event", "weather", "system"], ["batteries", "clipboard", "toggles"]], "по умолчанию — 2 ряда как в макете", "\(rows)")
        check(TodayLayout.rows([.weather, .system]).count == 1, "неполный ряд — один")
        let module = TodayIslandModule()
        check(module.expandedHeight == TodayLayout.height(rows: 2), "высота вкладки = 2 ряда")
        var mp = TodayPrefs(); mp.micSavedVolume = 0.42; mp.micMutedByUs = true
        if let d = try? JSONEncoder().encode(mp), let back = try? JSONDecoder().decode(TodayPrefs.self, from: d) {
            check(back.micSavedVolume == 0.42 && back.micMutedByUs, "громкость микрофона переживает перезапуск")
        } else { check(false, "громкость микрофона в настройках") }
        check(MeetingCompactLeading.sideWidth(for: "Созвон по проекту") > 116 && MeetingCompactLeading.sideWidth(for: String(repeating: "о", count: 80)) == 150,
              "ухо компакта — по названию, не шире 150", "\(MeetingCompactLeading.sideWidth(for: "Созвон по проекту"))")

        print("[значки SF Symbols]")
        var symbols = Set(ToggleKind.allCases.map(\.symbol) + TodayTile.allCases.map(\.systemImage))
        symbols.formUnion([BatteryItem.Kind.mac, .mouse, .keyboard, .trackpad, .headphones, .other].map {
            BatteryItem(id: "", name: "", kind: $0, level: 1).symbol })
        symbols.formUnion(["bolt.fill", "video", "video.fill", "calendar", "wifi.slash", "lock.fill", "xmark", "person.crop.square",
                           "exclamationmark.triangle.fill", "doc", "photo", "clipboard", "mic.slash.fill"])
        for code in [0, 1, 2, 3, 45, 51, 56, 61, 65, 66, 71, 75, 77, 80, 85, 95, 99] {
            symbols.insert(WeatherAPI.describe(code, isDay: true).symbol); symbols.insert(WeatherAPI.describe(code, isDay: false).symbol)
        }
        let missing = symbols.filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil }.sorted()
        check(missing.isEmpty, "все \(symbols.count) значков есть в системе", "нет: \(missing)")

        if network {
            print("[сеть: open-meteo]")
            let r: Result<WeatherSnapshot, Error>? = waitFor(20) {
                do { return .success(try await WeatherAPI.fetch(lat: 59.94, lon: 30.31)) } catch { return .failure(error) }
            }
            switch r {
            case .success(let w)?:
                check(w.hours.count >= 4, "прогноз получен: \(WeatherAPI.degrees(w.temperature)), \(WeatherAPI.summary(w))")
            case .failure(let e)? where !WeatherAPI.isNetworkError(e):
                check(false, "open-meteo ответил ошибкой", "\(e)")
            case .failure(let e)?:
                info("сети нет или сервис недоступен: \(e.localizedDescription) — плитка покажет последнее значение с пометкой")
            case nil:
                info("тайм-аут запроса")
            }
        }

        print("Итог: \(passes) ok, \(failures) FAIL")
        return failures == 0 ? 0 : 1
    }
}

// --- misc2 ---
/// Поддельный вход для самотеста: систему не трогает.
@MainActor
final class FakeMic: MicSwitch {
    var dev: AudioDeviceID = 42
    var vol: Float = 0.6
    var muted = false
    var restored: [AudioDeviceID] = []
    var restoreCalls = 0
    func defaultInput() -> AudioDeviceID? { dev }
    func volume(_ d: AudioDeviceID) -> Float? { vol }
    func setVolume(_ d: AudioDeviceID, _ value: Float) -> Bool { vol = value; return true }
    func setMuted(_ d: AudioDeviceID, _ on: Bool) -> Bool { muted = on; return true }
    func restore(_ d: AudioDeviceID, volume: Float) -> Bool {
        restoreCalls += 1; restored.append(d); vol = volume; muted = false; return true
    }
    func isOff() -> Bool { vol <= 0.001 || muted }
}
// --- /misc2 ---
