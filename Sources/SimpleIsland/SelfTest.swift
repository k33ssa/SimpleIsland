import AppKit
import Combine
import SwiftUI
import IslandCore

/// Самотесты ядра: `SimpleIsland --selftest-core <screens|sleep|motion|rebuild [N]|loop|utils|perms|a11y|hold|calm|drag|run|guide|trap|swipe|all>`.
/// Экраны — поддельные `ScreenDescriptor` далеко за видимой областью (x = −40000): панели в `rebuild` показываются
/// там (путь оконного сервера), остальные тесты их не показывают. pid-файлы детей — во временном каталоге, файлы
/// работающего приложения не трогаются. Код выхода 0 — всё прошло.
@MainActor
enum CoreSelfTest {
    private static var failures: [String] = []
    private static var checks = 0

    static func run(_ args: [String]) -> Int32 {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let what = args.first ?? "all"
        // Служебный режим для теста сирот: «приложение» с ребёнком и внуком, которое тест убьёт `kill -9`.
        if what == "orphan-child" { return orphanChild(args.dropFirst().first) }
        let pidDir = FileManager.default.temporaryDirectory.appendingPathComponent("si-selftest-pids-\(getpid())")
        ManagedProcess.pidDirectory = pidDir
        defer { try? FileManager.default.removeItem(at: pidDir) }
        let all = what == "all"
        // Каждый тест — в своём пуле: у CLI нет внешнего пула, autoreleased-ссылки одного теста иначе держали бы
        // его окна до конца процесса и портили счёт живых объектов в следующем.
        func run(_ name: String, _ body: () -> Void) {
            guard all || what == name else { return }
            autoreleasepool { body() }
            pump(0.2)
        }
        run("screens") { screens() }
        run("sleep") { sleep() }
        run("motion") { motion() }
        run("rebuild") { rebuild(args.count > 1 ? Int(args[1]) ?? 50 : 50) }
        run("loop") { loop() }
        run("utils") { utils() }
        run("perms") { perms() }
        run("a11y") { a11y() }
        run("hold") { hold() }   // --- misc2 ---
        run("calm") { calm() }   // --- shelfbar --- остров «в покое» (уборка строки меню): ровно вырез
        run("drag") { dragPasteboard() }   // --- shelfbar --- что тащат: файл, обещание, картинка, ссылка
        run("run") { oneShotRuns() }   // --- misc2 ---
        run("guide") { permissionGuide() }   // кнопки прав не молчат: окно / настройки + карточка / перезапуск
        run("trap") { clickTrap() }          // клик мимо раскрытого острова только сворачивает
        run("fullscreen") { fullscreen() }   // полноэкранное окно (видео, игра) прячет остров своего экрана
        run("policy") { notificationPolicy() }   // пустые вспышки/карточки не показываются (UX 15.11)
        run("tabs") { tabBar() }
        run("swipe") { swipe() }                 // свайп следит за пальцами: прогресс, снап по середине и скорости
        run("beacon") { beacon() }               // точка у выреза в полноэкранном: цвета, приоритет, «просмотрено»                 // вкладки не лезут под вырез: слева → справа → «⋯»; пилюля симметрична
        if what == "leakprobe" { autoreleasepool { leakProbe() } }
        print("\n== итог: проверок \(checks), провалов \(failures.count)")
        for f in failures { print("  ПРОВАЛ: \(f)") }
        return failures.isEmpty ? 0 : 1
    }

    // MARK: Точка у выреза в полноэкранном (15.11.2026)

    private static func beacon() {
        print("\n== beacon: точка у выреза в полноэкранном")
        check(AttentionKind.ask.color == IslandPalette.warn && AttentionKind.done.color == IslandPalette.ok
              && AttentionKind.error.color == IslandPalette.err && AttentionKind.info.color == IslandPalette.blue,
              "цвета — как у живой точки: ждёт — жёлтая, готово — зелёная, ошибка — красная, уведомление — синяя")
        let a = ActivityCenter()
        var pubs = 0
        let sub = a.$attention.dropFirst().sink { _ in pubs += 1 }
        a.setAttention(.done, text: "Агент закончил · x", for: "agents")
        a.setAttention(.info, text: "Карточка", for: FullscreenBeacon.notificationsKey)
        check(a.topAttention?.state.kind == .info, "уведомление важнее «готово»")
        a.setAttention(.error, text: "Vafa", for: "vafa")
        check(a.topAttention?.moduleId == "vafa", "ошибка важнее уведомления")
        a.setAttention(.ask, text: "Агент ждёт", for: "agents")
        check(a.topAttention?.moduleId == "agents" && a.topAttention?.state.kind == .ask, "«ждёт ответа» важнее всего")
        let before = pubs
        a.setAttention(.ask, text: "Агент ждёт", for: "agents")
        check(pubs == before, "то же событие ещё раз — без публикации (и без нового пульса)")
        a.acknowledgeAttention(moduleId: "agents")
        check(a.attention["agents"] == nil && a.topAttention?.moduleId == "vafa", "просмотрено — гаснет, видна следующая")
        a.setAttention(.done, text: "готово", for: "agents")
        a.dropAttentionNews()
        check(a.attention["agents"] == nil && a.attention[FullscreenBeacon.notificationsKey] == nil && a.attention["vafa"] != nil,
              "вход в полноэкранный: старые «готово»/карточки прочь, ошибка остаётся")
        a.removeAll(moduleId: "vafa")
        check(a.topAttention == nil, "модуль остановлен — его точка снята")
        sub.cancel()

        let st = AttentionState(kind: .ask, text: "", opensTab: nil, seq: 1)
        check(FullscreenBeacon.kind(islandHidden: true, enabled: true, top: st) == .ask
              && FullscreenBeacon.kind(islandHidden: false, enabled: true, top: st) == nil
              && FullscreenBeacon.kind(islandHidden: true, enabled: false, top: st) == nil
              && FullscreenBeacon.kind(islandHidden: true, enabled: true, top: nil) == nil,
              "точка — только когда остров спрятан, настройка включена и событие есть")
        let f = FullscreenBeacon.frame(centerX: 864, screenTop: 1117, notchHeight: 32, hasNotch: true)
        check(abs(f.midX - 864) <= 0.5 && f.maxY == 1117 - 32 && f.height <= 16 && f.width <= 40,
              "ухо — по центру выреза, вплотную под ним, не больше 40×16", "\(f)")
        let f2 = FullscreenBeacon.frame(centerX: 960, screenTop: 1080, notchHeight: 30, hasNotch: false)
        check(f2.maxY == 1080, "без выреза — ухо от верхнего края экрана", "\(f2)")
        let path = FullscreenBeacon.earPath(size: f.size, e: FullscreenBeacon.earRadius)
        check(path.boundingBox.insetBy(dx: -0.5, dy: -0.5).contains(CGRect(origin: .zero, size: f.size))
              && CGRect(origin: .zero, size: f.size).insetBy(dx: -0.5, dy: -0.5).contains(path.boundingBox)
              && path.contains(CGPoint(x: f.width / 2, y: f.height / 2)) && !path.contains(CGPoint(x: 0.5, y: 1)),
              "форма уха: тело по центру, вогнутые сопряжения сверху (углы снизу пустые)")
        let pulse = FullscreenBeacon.pulseAnimation()
        check(pulse.repeatCount >= 2 && pulse.repeatCount <= 3 && pulse.isRemovedOnCompletion
              && Double(pulse.repeatCount) * pulse.duration < 4,
              "пульс 2–3 раза и всё (потом статично), меньше 4 с")
        let withAction = IslandNotification(moduleId: "vafa", title: "Vafa", body: "VPN выключен",
                                            actions: [IslandNotificationAction("Показать")])
        let plain = IslandNotification(moduleId: "hud", title: "AirPods Pro", body: "Подключены")
        let agentCard = IslandNotification(moduleId: "agents", title: "Разрешение", body: "Bash", actions: [IslandNotificationAction("Да")])
        check(FullscreenBeacon.isImportant(withAction) && !FullscreenBeacon.isImportant(plain) && !FullscreenBeacon.isImportant(agentCard),
              "синяя точка — карточки с действием (не агентские: у них своя точка)")
        check(SettingsData().fullscreenDot, "по умолчанию точка в полноэкранном включена")
        let panel = FullscreenBeaconPanel()
        check(panel.level == NotchPanel.islandLevel && panel.collectionBehavior.contains(.fullScreenAuxiliary)
              && !panel.canBecomeKey, "окно точки — над полноэкранным, фокус не забирает")
        panel.close()
    }

    // MARK: Вкладки верхней строки (15.11.2026)

    private static func tabBar() {
        print("\n== tabs: раскладка вкладок и пилюля")
        check(Pill.abbreviation("Эквалайзер") == "Экв." && Pill.abbreviation("Сегодня") == "Сегодня"
              && Pill.abbreviation("Vafa") == "Vafa", "сокращение: «Эквалайзер» → «Экв.», короткие — как есть")
        typealias L = TabBarLayout
        let seven = ["media", "today", "shelf", "agents", "vafa", "menubar", "equalizer"]
        let ten = seven + ["t8", "t9", "t10"]
        let wide: [CGFloat] = [90, 60, 24]
        func rowW(_ r: [String], _ sel: String?, _ sw: CGFloat) -> CGFloat {
            r.isEmpty ? 0 : r.map { $0 == sel ? sw : L.iconWidth }.reduce(0, +) + L.spacing * CGFloat(r.count - 1)
        }
        // Остров 186 pt выреза: стороны ~ (outerWidth - gap - 16)/2; берём слева 190, справа 190-58-10.
        let p3 = L.plan(leftIds: Array(seven.prefix(3)), rightIds: [], selected: "media", selectedWidths: wide, left: 190, right: 122)
        check(p3.left == ["media", "today", "shelf"] && p3.right.isEmpty && p3.overflow.isEmpty && p3.selectedVariant == 0,
              "3 вкладки слева — все слева, у выбранной полное имя", "\(p3)")
        let p3r = L.plan(leftIds: ["media"], rightIds: ["today", "shelf"], selected: "today", selectedWidths: wide, left: 190, right: 122)
        check(p3r.left == ["media"] && p3r.right == ["today", "shelf"] && p3r.overflow.isEmpty,
              "стороны соблюдаются: левая слева, правая справа", "\(p3r)")
        let p7 = L.plan(leftIds: Array(seven.prefix(4)), rightIds: Array(seven.suffix(3)), selected: "media",
                        selectedWidths: wide, left: 190, right: 122)
        check(p7.overflow.isEmpty && p7.left == Array(seven.prefix(4)) && p7.right == Array(seven.suffix(3)),
              "7 вкладок 4|3 — по своим сторонам, без «⋯»", "\(p7)")
        // Переполнение одной стороны: на другую не перескакивает, лишние — в «⋯», выбранная на виду.
        let pL = L.plan(leftIds: seven, rightIds: [], selected: "equalizer", selectedWidths: wide, left: 120, right: 122)
        check(pL.right.isEmpty && !pL.overflow.isEmpty && pL.left.contains("equalizer") && !pL.overflow.contains("equalizer")
              && Set(pL.left + pL.overflow) == Set(seven),
              "левая переполнена — лишние в «⋯», направо не уходят, выбранная видна", "\(pL)")
        check(rowW(pL.left, "equalizer", wide[pL.selectedVariant]) <= 120.5, "левая не шире своего места (под вырез не лезет)", "\(pL)")
        let pR = L.plan(leftIds: ["media"], rightIds: Array(seven.dropFirst()), selected: "today", selectedWidths: wide,
                        left: 190, right: 90)
        check(pR.left == ["media"] && !pR.overflow.isEmpty && pR.right.contains("today")
              && rowW(pR.right, "today", wide[pR.selectedVariant]) + L.moreWidth + L.spacing <= 90.5,
              "правая переполнена — «⋯» в её конце, ряд с «⋯» влезает", "\(pR)")
        let p10 = L.plan(leftIds: Array(ten.prefix(5)), rightIds: Array(ten.suffix(5)), selected: "t10",
                         selectedWidths: wide, left: 150, right: 90)
        let sw10 = wide[p10.selectedVariant]
        check(!p10.overflow.isEmpty && p10.right.contains("t10") && !p10.overflow.contains("t10"),
              "10 вкладок в тесноте — лишние в «⋯», выбранная на своей стороне", "\(p10)")
        check(rowW(p10.left, "t10", sw10) <= 150.5 && rowW(p10.right, "t10", sw10) + L.moreWidth + L.spacing <= 90.5,
              "ширины рядов не больше места", "\(p10)")
        check(p10.overflow == ten.filter { p10.overflow.contains($0) }, "«⋯» — по порядку: сначала левые, потом правые")
        check(Set(p10.left + p10.right + p10.overflow) == Set(ten) && p10.left.allSatisfy { ten.prefix(5).contains($0) },
              "ни одна вкладка не теряется и не меняет сторону")
        let pShort = L.plan(leftIds: Array(seven.prefix(3)), rightIds: Array(seven.suffix(4)), selected: "equalizer",
                            selectedWidths: [140, 60, 24], left: 190, right: 150)
        check(pShort.overflow.isEmpty && pShort.selectedVariant == 1, "тесно — сначала сокращение подписи, а не «⋯»", "\(pShort)")
        let pNone = L.plan(leftIds: seven, rightIds: [], selected: "media", selectedWidths: wide, left: 0, right: 0)
        check(pNone.left.contains("media"), "места нет совсем — выбранная всё равно видна", "\(pNone)")
        // Без выреза: обе группы подряд слева, разделитель занимает место.
        let pIn = L.plan(leftIds: ["media", "today"], rightIds: ["shelf", "agents"], selected: "media", selectedWidths: wide,
                         left: 300, right: 122, inline: true)
        check(pIn.inline && pIn.left == ["media", "today"] && pIn.right == ["shelf", "agents"] && pIn.overflow.isEmpty,
              "без выреза — левые, черта, правые подряд", "\(pIn)")
        let need = 90 + 3 * L.iconWidth + 3 * L.spacing
        let pIn2 = L.plan(leftIds: ["media", "today"], rightIds: ["shelf", "agents"], selected: "media", selectedWidths: [90],
                          left: need, right: 0, inline: true)
        check(pIn2.overflow == ["agents"], "без выреза — разделитель учтён в ширине", "\(pIn2)")
        let pIn3 = L.plan(leftIds: seven, rightIds: ["t8"], selected: "t8", selectedWidths: wide, left: 120, right: 60, inline: true)
        check(pIn3.right == ["t8"] && !pIn3.overflow.contains("t8") && pIn3.overflow == (seven + ["t8"]).filter { pIn3.overflow.contains($0) },
              "без выреза в тесноте — выбранная из правой группы на виду", "\(pIn3)")
        // Миграция старого settings.json: сколько стояло слева в прежней раскладке (остальное уезжало направо).
        check(L.legacyLeftCount(ids: Array(seven.prefix(3)), selectedWidths: wide, left: 190, right: 122) == 3,
              "прежняя раскладка: 3 вкладки — все слева")
        check(L.legacyLeftCount(ids: seven, selectedWidths: wide, left: 190, right: 122) == 4,
              "прежняя раскладка: 7 вкладок — 4 слева, 3 уезжали направо")
        check(L.legacyLeftCount(ids: seven, selectedWidths: [140, 60, 24], left: 190, right: 150) == 2,
              "прежняя раскладка: широкая подпись выбранной — 2 слева, 5 справа (полное имя, без «⋯»)")
        check(L.legacyLeftCount(ids: [], selectedWidths: wide, left: 190, right: 122) == 0, "прежняя раскладка: пусто — 0")

        // Каталог: «есть ли место слева» на острове 720 pt с вырезом 186.
        check(L.leftHasRoom(count: 3, width: 720, gap: 186) && !L.leftHasRoom(count: 12, width: 720, gap: 186),
              "место слева: 3 вкладки — есть, 12 — нет")

        // Пилюля: ширина — ровно один из вариантов (полное имя / сокращение / значок), без пустоты справа.
        func width(_ v: some View, proposal: CGFloat) -> CGFloat {
            let h = NSHostingController(rootView: AnyView(v))
            return h.sizeThatFits(in: CGSize(width: proposal, height: 24)).width
        }
        let full = width(Pill("Эквалайзер", systemImage: "waveform", selected: true).fixedSize(), proposal: 500)
        let short = width(Pill("Экв.", systemImage: "waveform", selected: true).fixedSize(), proposal: 500)
        let icon = width(Pill("Vafa", systemImage: "lock.shield", selected: false), proposal: 500)
        check(abs(icon - 24) < 0.5, "невыбранная — круг 24 pt, значок по центру", "\(icon)")
        let roomy = width(Pill("Эквалайзер", systemImage: "waveform", selected: true), proposal: 500)
        let tight = width(Pill("Эквалайзер", systemImage: "waveform", selected: true), proposal: short + 2)
        let none = width(Pill("Эквалайзер", systemImage: "waveform", selected: true), proposal: 30)
        check(abs(roomy - full) < 1, "место есть — полное имя, ширина по тексту", "\(roomy) vs \(full)")
        check(abs(tight - short) < 1, "тесно — «Экв.» целиком (не «Эквал…»)", "\(tight) vs \(short)")
        check(abs(none - 24) < 1, "совсем тесно — только значок, симметрично", "\(none)")
        check(abs(L.labeledWidth("Эквалайзер") - full) < 6, "оценка ширины подписи близка к настоящей", "\(L.labeledWidth("Эквалайзер")) vs \(full)")
    }

    // MARK: Политика уведомлений (15.11.2026)

    /// «Значок без текста» не показывается: ни вспышкой, ни карточкой (docs/ARCHITECTURE.md, «Политика уведомлений»).
    private static func notificationPolicy() {
        print("\n== policy: пустые вспышки и карточки")
        let hud = HUDCenter()
        hud.flash(HUDEvent(kind: "media.track", systemImage: "music.note"))
        check(hud.current == nil, "вспышка «только значок» не показана")
        hud.flash(HUDEvent(kind: "x", systemImage: "music.note", label: "  "))
        check(hud.current == nil, "вспышка с пустой подписью не показана")
        hud.flash(HUDEvent(kind: "volume", systemImage: "speaker.wave.2.fill", value: 0.5))
        check(hud.current?.kind == "volume", "вспышка со значением показана")
        hud.flash(HUDEvent(kind: "layout", customLeading: AnyView(Text("RU"))))
        check(hud.current?.kind == "layout", "вспышка со своим видом показана")
        hud.dismiss()
        let n = IslandNotifications()
        n.post(IslandNotification(moduleId: "media", title: "", body: " ", systemImage: "music.note"))
        check(n.current == nil, "пустая карточка (значок без слов) не показана")
        n.postFront(IslandNotification(moduleId: "media", title: "\n", body: ""))
        check(n.current == nil, "пустая карточка вне очереди тоже не показана")
        n.post(IslandNotification(moduleId: "hud", title: "AirPods Pro", body: "Подключены"))
        check(n.current?.title == "AirPods Pro", "карточка с текстом показана")
    }

    // MARK: Полноэкранный (15.11.2026)

    /// `FullscreenDetector` на снимках окон: MacBook 16" с вырезом (1728×1117, вырез 32, строка 37) и LG над ним.
    private static func fullscreen() {
        print("— полноэкранный: какое окно прячет остров")
        typealias W = FullscreenDetector.Window
        let main = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let lg = CGRect(x: 0, y: -1440, width: 2560, height: 1440)
        let menubar = W(id: 1, pid: 300, owner: "Window Server", name: "Menubar", layer: 24,
                        frame: CGRect(x: 0, y: 0, width: 1728, height: 37), alpha: 1)
        let dock = W(id: 2, pid: 301, owner: "Dock", name: "Dock", layer: 20, frame: main, alpha: 1)
        let shot = W(id: 3, pid: 302, owner: "Снимок экрана", name: nil, layer: 24, frame: main, alpha: 1)
        func app(_ id: CGWindowID, _ f: CGRect, pid: pid_t = 500, alpha: Double = 1) -> W {
            W(id: id, pid: pid, owner: "App", name: nil, layer: 0, frame: f, alpha: alpha)
        }
        let base = [menubar, dock, shot]
        func full(_ ws: [W], screen: CGRect = main, safe: CGFloat = 32) -> CGWindowID? {
            FullscreenDetector.coveringWindow(screen: screen, safeTop: safe, windows: base + ws, ownPID: 999)
        }
        check(full([]) == nil, "рабочий стол: Dock (слой 20) и «Снимок экрана» (слой 24) на весь экран — не полноэкранные")
        check(full([app(10, CGRect(x: 0, y: 38, width: 1728, height: 1079))]) == nil,
              "развёрнутое окно под строкой меню (y = 38) — не полноэкранное")
        check(full([app(11, CGRect(x: 0, y: 38, width: 1656, height: 1079))]) == nil, "Chrome почти на весь экран — нет")
        check(full([app(12, CGRect(x: 0, y: 32, width: 1728, height: 1085))]) == 12,
              "Safari/YouTube/QuickTime на весь экран — сразу под вырезом (y = 32), строка меню ещё видна — да")
        let noMenu = [dock, shot]
        check(FullscreenDetector.coveringWindow(screen: main, safeTop: 32,
                                                windows: noMenu + [app(13, CGRect(x: 0, y: 37, width: 1728, height: 1080))],
                                                ownPID: 999) == 13,
              "строки меню нет (полноэкранный стол), окно с y = 37 — да")
        check(full([app(14, main)]) == 14, "игра/плеер на весь экран поверх строки меню — да")
        check(full([app(15, main, pid: 999)]) == nil, "своё окно на весь экран — не считается")
        check(full([app(16, main, alpha: 0)]) == nil, "прозрачное окно на весь экран — не считается")
        let lgVideo = app(17, lg, pid: 501)
        check(full([lgVideo]) == nil && full([lgVideo], screen: lg, safe: 0) == 17,
              "видео на весь экран на LG прячет остров LG, не встроенного")
        let lgMenu = W(id: 4, pid: 300, owner: "Window Server", name: "Menubar", layer: 24,
                       frame: CGRect(x: 0, y: -1440, width: 2560, height: 25), alpha: 1)
        check(full([lgMenu, app(18, CGRect(x: 0, y: -1415, width: 2560, height: 1415))], screen: lg, safe: 0) == nil,
              "LG без выреза: развёрнутое окно под строкой 25 pt — нет")
        check(FullscreenDetector.recheckDelays.count >= 3 && FullscreenDetector.recheckDelays.last! >= 2
              && FullscreenDetector.recheckDelays.allSatisfy { $0 >= 0.25 },
              "после события — серия проверок до ~3 с (анимация входа), не чаще раза в 0,25 с и без постоянного опроса")
        check(FullscreenDetector.isCritical(duration: nil, actionCount: 2) && !FullscreenDetector.isCritical(duration: 6, actionCount: 1)
              && !FullscreenDetector.isCritical(duration: nil, actionCount: 0),
              "«нужен ответ» = карточка без срока и с кнопками")
        let d = SettingsData()
        check(d.hideInFullscreen && d.showCriticalInFullscreen, "по умолчанию: прятать в полноэкранном, вопросы показывать")
        let parsed = FullscreenDetector.parse([[kCGWindowNumber as String: 7, kCGWindowOwnerPID as String: 42,
                                                kCGWindowLayer as String: 0, kCGWindowOwnerName as String: "IINA",
                                                kCGWindowBounds as String: ["X": 0.0, "Y": 0.0, "Width": 1728.0, "Height": 1117.0]]])
        check(parsed.first?.frame == main && parsed.first?.alpha == 1, "разбор словаря CGWindowList")

        // --- shelfbar --- Живой случай 15.11: Chrome, сериал, кнопка «полный экран» плеера; 16" 1728×1117, вырез 32.
        // Снимок в момент входа (анимация стола) и итог: окно Chrome `0, 37, 1728×1080`, строка меню в списке.
        print("— полноэкранный: Chrome-видео (снимок 15.11) и тип стола")
        func chrome(_ id: CGWindowID, _ y: CGFloat, _ h: CGFloat, alpha: Double = 1, layer: Int = 0, x: CGFloat = 0) -> W {
            W(id: id, pid: 700, owner: "Google Chrome", name: nil, layer: layer, frame: CGRect(x: x, y: y, width: 1728, height: h), alpha: alpha)
        }
        let animating: [W] = [
            chrome(30, 37, 1080), chrome(31, -73, 41, alpha: 0), chrome(32, -79, 47, alpha: 0), chrome(33, 0, 1117),
            W(id: 34, pid: 301, owner: "Dock", name: nil, layer: 27, frame: main, alpha: 1),
            W(id: 35, pid: 999, owner: "SimpleIsland", name: nil, layer: 27, frame: CGRect(x: -381, y: 0, width: 1020, height: 500), alpha: 1),
            chrome(36, 0, 37, alpha: 0, layer: 26, x: 1058),
            W(id: 37, pid: 300, owner: "Window Server", name: "Menubar", layer: 24, frame: CGRect(x: -734, y: 0, width: 1728, height: 37), alpha: 1),
            W(id: 38, pid: 800, owner: "Claude", name: nil, layer: 0, frame: CGRect(x: -734, y: 38, width: 1669, height: 1079), alpha: 1),
        ]
        let settled: [W] = [menubar, chrome(30, 37, 1080), chrome(31, -73, 41, alpha: 0)]
        func decide(_ ws: [W], _ space: Int?) -> (CGWindowID?, FullscreenDetector.Reason) {
            let d = FullscreenDetector.decide(screen: main, safeTop: 32, windows: ws, ownPID: 999, spaceType: space)
            return (d.window, d.reason)
        }
        check(decide(settled, 0).0 == nil,
              "итог входа без типа стола: окно 0,37,1728×1080 и строка меню в списке — по рамкам НЕ видно (причина бага)")
        check(decide(settled, SpaceProbe.fullscreenType) == (30, .fullscreenSpace), "тот же итог на полноэкранном столе (тип 4) — прячем")
        check(decide(animating, SpaceProbe.fullscreenType).1 == .fullscreenSpace, "во время анимации на полноэкранном столе — прячем")
        check(decide(animating, nil).0 == 33, "без SkyLight во время анимации — запасное правило по окну 0,0 на весь экран")
        check(decide([menubar, chrome(40, 37, 1080)], 0).0 == nil, "обычный стол, развёрнутое окно при скрытом Dock — не прячем (выход)")
        check(decide([menubar, chrome(41, 0, 1117)], 0) == (41, .coveringWindow), "обычный стол, игра поверх строки меню — прячем")
        let probe = SpaceProbe.parse([
            ["Display Identifier": "37d8832a-2d66-02ca-b9f7-8f30a301b230", "Current Space": ["type": 4, "ManagedSpaceID": 2212]],
            ["Display Identifier": "AAAA", "Current Space": ["type": 0]],
        ])
        check(SpaceProbe.spaceType(for: "37D8832A-2D66-02CA-B9F7-8F30A301B230", in: probe) == 4
              && SpaceProbe.spaceType(for: "AAAA", in: probe) == 0, "разбор SLSCopyManagedDisplaySpaces: тип стола по UUID экрана")
        check(SpaceProbe.spaceType(for: "BBBB", in: ["MAIN": 4]) == 4, "общие столы на все мониторы («Main») — тип для любого экрана")
        let live = SpaceProbe.currentSpaceTypes()
        check(live != nil && !(live ?? [:]).isEmpty, "SkyLight доступен на этой системе, столов: \(live?.count ?? 0) (только чтение)")
        check(FullscreenDetector.recheckDelays.last! >= 5 && FullscreenDetector.pollWindow >= 6 && FullscreenDetector.pollWindow <= 15,
              "серия до 5 с + досмотр раз в секунду до \(Int(FullscreenDetector.pollWindow)) с — не вечный опрос")
        check(FullscreenDetector.hasScreenWideWindow(pid: 700, screens: [main], windows: settled)
              && !FullscreenDetector.hasScreenWideWindow(pid: 800, screens: [main], windows: settled),
              "досмотр только пока у переднего приложения окно на ширину экрана")
        // Спрятанный по правилу остров не возвращают ни активность медиа, ни уведомление, ни show() после пересборки.
        // Панель — на поддельном экране за видимой областью (x = −40000).
        let env = makeEnv()
        let c = IslandController(descriptor: builtin(), geometry: IslandGeometry.detect(builtin(), floatingAllowed: true)!, env: env)
        c.show()
        check(c.panel.isVisible, "до правила панель видна")
        c.setHiddenByRule(true)
        env.activities.post(IslandActivity(id: "media.now", moduleId: "media") { EmptyView() } trailing: { EmptyView() })
        env.notifications.show(IslandNotification(moduleId: "media", title: "Трек", source: "Музыка", body: "", avatarColors: [],
                                                  systemImage: "music.note", duration: 3))
        env.hud.show(HUDEvent(kind: "volume", value: 0.4))
        c.show()
        pump(0.3)
        check(!c.panel.isVisible, "спрятан правилом: активность, уведомление, HUD и show() его не показывают")
        c.setHiddenByRule(false)
        check(c.panel.isVisible, "вышли из полноэкранного — остров снова виден")
        c.close()
        // --- /shelfbar ---
    }


    // MARK: Интерактивный свайп (27.11.2026)

    /// Свайп трекпада и «потянуть» ведут форму по прогрессу 0…1; отпускание — к ближнему краю или по скорости;
    /// инерция не двигает; колесо, «Уменьшить движение» и события без фаз — прежний порог.
    static func swipe() {
        print("\n== swipe: остров следит за пальцами")
        let env = makeEnv()
        let g = IslandGeometry.detect(builtin(), floatingAllowed: true)!
        let c = IslandController(descriptor: builtin(), geometry: g, env: env)
        let m = c.model
        env.activities.post(IslandActivity(id: "m", moduleId: "media") { EmptyView() } trailing: { EmptyView() })
        pump(0.05)
        m.motion = .full   // окно в самотесте не показано — ядро ставит off; здесь проверяем полное движение
        check(m.presentation == .compact, "старт — компакт (\(m.presentation))")
        let rest = m.metrics(for: .compact).height
        var t: TimeInterval = 100
        // Медленный ход: шаги по 4 pt каждые 40 мс (100 pt/с — ниже порога скорости).
        func slow(to total: CGFloat, from start: CGFloat = 0) {
            var a = start
            let step: CGFloat = total > start ? 4 : -4
            while (step > 0 && a + step <= total) || (step < 0 && a + step >= total) {
                a += step; t += 0.04
                m.scroll(physicalDeltaY: step, precise: true, phase: .changed, time: t)
            }
        }
        func begin() { t += 1; m.scroll(physicalDeltaY: 0, precise: true, phase: .began, time: t) }
        func end() { t += 0.2; m.scroll(physicalDeltaY: 0, precise: true, phase: .ended, time: t) }

        // 1) прогресс по дельтам
        begin()
        check(m.swipeProgress == nil, "began без сдвига — форма не трогается")
        slow(to: 40)
        let dist = m.swipeDistance
        let expH = m.metrics(for: .expanded).height
        check(abs(dist - min(320, max(120, expH - rest))) < 0.5, "расстояние = разница высот (\(dist), \(expH) − \(rest))")
        check(abs((m.swipeProgress ?? -1) - 40 / dist) < 0.01, "прогресс = сдвиг / расстояние (\(m.swipeProgress ?? -1))")
        check(!m.expanded, "во время жеста не раскрыт")
        let mid = m.currentMetrics.height
        check(mid > rest && mid < expH, "форма между компактом и раскрытым (\(rest) < \(mid) < \(expH))")
        check(c.islandRect().height >= expH, "зона кликов на время жеста — по раскрытому")
        var pubs = 0
        let sub = m.objectWillChange.sink { _ in pubs += 1 }
        slow(to: 60, from: 40)
        check(pubs == 0, "кадры жеста не публикуют модель (вкладка не пересобирается): \(pubs)")
        sub.cancel()
        // 2) медленно отпустили до середины → обратно
        end()
        check(!m.expanded && m.swipeProgress == nil, "отпустили до середины медленно → свернулся")
        check(m.currentMetrics.height == rest, "форма вернулась к компакту")
        // 3) за середину → раскрыт
        begin(); slow(to: dist * 0.6); end()
        check(m.expanded && m.swipeProgress == nil, "за середину → раскрыт")
        // 4) обратно из раскрытого: чуть вверх — остался; за середину — свернулся
        begin(); slow(to: -dist * 0.2)
        check(abs((m.swipeProgress ?? -1) - 0.8) < 0.03, "из раскрытого вверх — прогресс идёт обратно (\(m.swipeProgress ?? -1))")
        end()
        check(m.expanded, "вверх на 20 % медленно → остался раскрыт")
        begin(); slow(to: -dist * 0.7); end()
        check(!m.expanded, "вверх за середину → свернулся")
        // 5) быстрый взмах: 20 % хода за 50 мс → раскрыт; обратный взмах на 70 % хода → свернулся
        begin()
        for _ in 0..<5 { t += 0.01; m.scroll(physicalDeltaY: dist * 0.04, precise: true, phase: .changed, time: t) }
        t += 0.008; m.scroll(physicalDeltaY: 0, precise: true, phase: .ended, time: t)
        check(m.expanded, "взмах вниз на 20 % хода → раскрыт по скорости")
        begin()
        for _ in 0..<5 { t += 0.01; m.scroll(physicalDeltaY: -dist * 0.04, precise: true, phase: .changed, time: t) }
        t += 0.008; m.scroll(physicalDeltaY: 0, precise: true, phase: .ended, time: t)
        check(!m.expanded, "взмах вверх на 20 % хода → свернулся по скорости")
        begin(); slow(to: dist * 0.7); t += 0.2
        for _ in 0..<4 { t += 0.01; m.scroll(physicalDeltaY: -dist * 0.05, precise: true, phase: .changed, time: t) }
        t += 0.008; m.scroll(physicalDeltaY: 0, precise: true, phase: .ended, time: t)
        check(!m.expanded, "довёл до 70 %, но взмахнул назад → свернулся")
        // 6) отмена жеста системой → к началу
        let tabBefore = m.selectedTab
        begin(); slow(to: dist * 0.8)
        t += 0.02; m.scroll(physicalDeltaY: 0, precise: true, phase: .cancelled, time: t)
        check(!m.expanded && m.swipeProgress == nil, "отмена (cancelled) на 80 % → вернулся к компакту")
        check(m.selectedTab == tabBefore, "отменённое открытие не подменяет вкладку")
        // 7) инерция после отпускания не двигает
        begin(); slow(to: dist * 0.3); end()
        for _ in 0..<20 { t += 0.016; m.scroll(physicalDeltaY: 30, precise: true, phase: .momentum, time: t) }
        check(!m.expanded && m.swipeProgress == nil, "инерция после отпускания не раскрывает")
        // 8) вверх по свёрнутому — ничего
        begin(); slow(to: -60)
        check(m.swipeProgress == nil && !m.expanded, "вверх по свёрнутому — форма не трогается")
        end()
        // 9) колесо — как раньше: щелчок переключает, без прогресса
        m.scroll(physicalDeltaY: 1, precise: false, phase: .none)
        check(m.expanded && m.swipeProgress == nil, "колесо вниз — раскрыл сразу")
        m.scroll(physicalDeltaY: -1, precise: false, phase: .none)
        check(!m.expanded, "колесо вверх — свернул")
        // 10) «Уменьшить движение» — порог 10 pt, без интерполяции
        m.motion = .reduced
        begin(); t += 0.02; m.scroll(physicalDeltaY: 6, precise: true, phase: .changed, time: t)
        check(!m.expanded && m.swipeProgress == nil, "reduced: 6 pt — ничего, формы нет")
        t += 0.02; m.scroll(physicalDeltaY: 6, precise: true, phase: .changed, time: t)
        check(m.expanded && m.swipeProgress == nil, "reduced: за порогом 10 pt — раскрыл сразу")
        t += 0.02; m.scroll(physicalDeltaY: -40, precise: true, phase: .changed, time: t)
        check(m.expanded, "reduced: один раз на жест")
        end()
        begin(); t += 0.02; m.scroll(physicalDeltaY: -12, precise: true, phase: .changed, time: t); end()
        check(!m.expanded, "reduced: вверх за порогом — свернул")
        // без фаз (старое устройство) — тоже порог
        m.motion = .full
        m.lastScroll = .distantPast
        m.scroll(physicalDeltaY: 12, precise: true, phase: .none)
        check(m.expanded && m.swipeProgress == nil, "события без фаз — прежний порог")
        m.collapse()
        // 11) замок: свайп вверх — явное сворачивание, снимает замок; отменённый — замок на месте
        m.expand(); m.setLocked(true)
        begin(); slow(to: -dist * 0.2); end()
        check(m.expanded && m.locked, "замок: недотянутый свайп — остался раскрыт и заперт")
        begin(); slow(to: -dist * 0.8); end()
        check(!m.expanded && !m.locked, "замок: свайп вверх свернул и снял замок")
        // 12) «потянуть» мышью — тот же механизм
        t += 1
        m.pull(translation: 7, phase: .began, time: t)
        for i in 1...20 { t += 0.04; m.pull(translation: 7 + CGFloat(i) * dist * 0.03, phase: .changed, time: t) }
        check((m.swipeProgress ?? 0) > 0.5 && !m.expanded, "потянуть: прогресс идёт за мышью (\(m.swipeProgress ?? -1))")
        t += 0.2; m.pull(translation: 7 + dist * 0.6, phase: .ended, time: t)
        check(m.expanded && m.swipeProgress == nil, "потянуть за середину → раскрыт")
        m.collapse()
        m.motion = .reduced
        m.pull(translation: 7, phase: .began); m.pull(translation: 13, phase: .changed)
        check(m.expanded && m.swipeProgress == nil, "потянуть при reduced — прежний порог 12 pt")
        m.pull(translation: 13, phase: .ended)
        m.collapse(); m.motion = .full
        // 13) клик/Esc посреди жеста — жест снят
        begin(); slow(to: dist * 0.4)
        m.expand()
        check(m.expanded && m.swipeProgress == nil, "явное раскрытие посреди жеста снимает прогресс")
        end()
        check(m.expanded, "конец снятого жеста ничего не делает")
        m.collapse()
        // 14) свайпы выключены в настройках
        env.settings.data.swipeGestures = false
        begin(); slow(to: dist * 0.8); end()
        check(!m.expanded && m.swipeProgress == nil, "свайпы выключены — ничего")
        env.settings.data.swipeGestures = true
        // 15) отладочный прогресс (снимки/`progress`)
        m.previewSwipe(0.5)
        let h = m.currentMetrics.height
        check(abs(h - (rest + (expH - rest) * 0.5)) < 0.5, "previewSwipe 0.5 — форма посередине (\(h))")
        m.previewSwipe(nil)
        check(m.swipeProgress == nil && !m.expanded, "previewSwipe nil — снят")
        c.close()
    }

    // MARK: Помощники

    private static func check(_ ok: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
        checks += 1
        if !ok { failures.append(what) }
        print("  [\(ok ? "ok" : "ПРОВАЛ")] \(what)\(ok ? "" : " — " + detail())")
    }

    private static func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            autoreleasepool { _ = RunLoop.main.run(mode: .default, before: min(end, Date().addingTimeInterval(0.01))) }
        }
    }

    private static func pump(until cond: () -> Bool, timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            // Условие — в своём пуле: autoreleased-ссылки из него (окна) не доживают до конца теста.
            if autoreleasepool(invoking: cond) { return true }
            autoreleasepool { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        }
        return cond()
    }

    static func physFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }

    private static func mb(_ b: UInt64) -> String { String(format: "%.1f МБ", Double(b) / 1_048_576) }

    private static func makeEnv(_ data: SettingsData = SettingsData(), modules: [IslandModule]? = nil) -> AppEnvironment {
        AppEnvironment(settings: SimpleIslandSettings(inMemory: data), themes: ThemeStore(),
                       modules: modules ?? ModuleRegistry.makeModules())
    }

    /// Поддельные экраны далеко за пределами настоящих (x = −40000): панели, даже если бы показались, не видны.
    nonisolated private static let ox: CGFloat = -40000

    static func builtin(wide: Bool = false, menu: Bool = true) -> ScreenDescriptor {
        let w: CGFloat = wide ? 1728 : 1512, h: CGFloat = wide ? 1117 : 982
        let aux: (CGFloat, CGFloat) = wide ? (771, 772) : (663, 664)
        return ScreenDescriptor(displayID: 1, name: "Встроенный", frame: CGRect(x: ox, y: 0, width: w, height: h),
                                visibleFrame: CGRect(x: ox, y: 0, width: w, height: h - 37),
                                safeArea: NSEdgeInsets(top: 32, left: 0, bottom: 0, right: 0),
                                auxLeftWidth: aux.0, auxRightWidth: aux.1, scale: 2, isMenuBarScreen: menu)
    }

    static func external(x: CGFloat = ox + 1512, w: CGFloat = 2560, h: CGFloat = 1440, menu: Bool = false,
                         scale: CGFloat = 2) -> ScreenDescriptor {
        ScreenDescriptor(displayID: 2, name: "Внешний", frame: CGRect(x: x, y: 0, width: w, height: h),
                         visibleFrame: CGRect(x: x, y: 0, width: w, height: h - 25), scale: scale, isMenuBarScreen: menu)
    }

    // MARK: 1. Экраны

    static func screens() {
        print("\n== screens: план островов, обновление на месте, склейка уведомлений")
        let env = makeEnv()
        let set = IslandSet(env: env)
        set.showsPanels = false
        var o = IslandPlanner.Options()

        func step(_ name: String, _ screens: [ScreenDescriptor], expect: Int,
                  created: Int, updated: Int, removed: Int, notch: [Bool]? = nil) {
            let b = (set.created, set.updated, set.removed)
            set.reconcile(IslandPlanner.plan(screens, o))
            let d = (set.created - b.0, set.updated - b.1, set.removed - b.2)
            print("  \(name): островов \(set.controllers.count), создано \(d.0), обновлено \(d.1), закрыто \(d.2)")
            check(set.controllers.count == expect && d.0 == created && d.1 == updated && d.2 == removed,
                  "\(name): ждали \(expect) остр., +\(created) ~\(updated) −\(removed)")
            if let notch { check(set.controllers.map(\.model.geometry.hasNotch) == notch, "\(name): вырез/капля \(notch)") }
        }

        step("встроенный экран", [builtin()], expect: 1, created: 1, updated: 0, removed: 0, notch: [true])
        let first = set.controllers.first.map(ObjectIdentifier.init)
        step("подключили монитор (один остров)", [builtin(), external()], expect: 1, created: 0, updated: 0, removed: 0)
        o.allScreens = true
        step("«на всех мониторах»", [builtin(), external()], expect: 2, created: 1, updated: 0, removed: 0, notch: [true, false])
        let ext = set.controllers.last.map(ObjectIdentifier.init)
        step("разрешение внешнего 1920×1080", [builtin(), external(w: 1920, h: 1080)], expect: 2, created: 0, updated: 1, removed: 0)
        check(set.controllers.last.map(ObjectIdentifier.init) == ext, "внешний обновлён на месте (то же окно)")
        step("раскладка: внешний слева", [builtin(), external(x: ox - 1920, w: 1920, h: 1080)], expect: 2, created: 0, updated: 1, removed: 0)
        step("масштаб внешнего ×1", [builtin(), external(x: ox - 1920, w: 1920, h: 1080, scale: 1)], expect: 2, created: 0, updated: 1, removed: 0)
        step("встроенный «больше места»", [builtin(wide: true), external(x: ox - 1920, w: 1920, h: 1080, scale: 1)],
             expect: 2, created: 0, updated: 1, removed: 0)
        check(abs((set.controllers.first?.model.geometry.notchWidth ?? 0) - 185) < 0.5, "ширина выреза 1728−771−772 = 185")
        check(set.controllers.first.map(ObjectIdentifier.init) == first, "встроенный не пересоздавался")
        step("тот же набор ещё раз", [builtin(wide: true), external(x: ox - 1920, w: 1920, h: 1080, scale: 1)],
             expect: 2, created: 0, updated: 0, removed: 0)
        step("clamshell: встроенного нет", [external(x: ox - 1920, w: 1920, h: 1080, menu: true, scale: 1)],
             expect: 1, created: 0, updated: 1, removed: 1, notch: [false])
        o.allScreens = false
        step("clamshell, один остров", [external(x: ox - 1920, w: 1920, h: 1080, menu: true, scale: 1)],
             expect: 1, created: 0, updated: 0, removed: 0, notch: [false])
        o.floatingOnNotchlessScreens = false
        step("clamshell без капли", [external(x: ox - 1920, w: 1920, h: 1080, menu: true, scale: 1)],
             expect: 0, created: 0, updated: 0, removed: 1)
        step("крышку открыли, монитор отключили", [builtin()], expect: 1, created: 1, updated: 0, removed: 0, notch: [true])
        o.paused = true
        step("пауза", [builtin()], expect: 0, created: 0, updated: 0, removed: 1)
        o.paused = false
        step("снять паузу", [builtin()], expect: 1, created: 1, updated: 0, removed: 0)
        set.closeAll()

        // Склейка пачки уведомлений.
        var current = [builtin()]
        var applied: [Date] = []
        let co = ScreenChangeCoalescer(delay: 0.4, read: { current }, apply: { _ in applied.append(Date()) })
        // Склейку проверяем отдельно от предела ожидания (под нагрузкой цикл уведомлений идёт дольше 1,5 с).
        co.maxWait = 60
        var lastNote = Date()
        for _ in 0..<12 { co.note(); lastNote = Date(); pump(0.02) }
        pump(0.6)
        let lag = applied.first.map { $0.timeIntervalSince(lastNote) } ?? -1
        print(String(format: "  пачка из 12 уведомлений → применений %d, через %.2f с после последнего", applied.count, lag))
        check(applied.count == 1 && lag >= 0.35 && lag < 0.6, "12 уведомлений склеены в одно применение (~0,4 с)")
        for _ in 0..<5 { co.note() }
        pump(0.6)
        check(applied.count == 1 && co.skips == 1, "та же подпись → пропуск (skips \(co.skips))")
        current = [builtin(), external()]
        co.note(); pump(0.6)
        check(applied.count == 2, "подключили монитор → применено")
        co.isHeld = true
        current = [builtin()]
        for _ in 0..<3 { co.note() }
        pump(0.6)
        check(applied.count == 2, "во сне не применяется")
        co.isHeld = false
        pump(0.6)
        check(applied.count == 3, "после пробуждения применено один раз")
        co.note(force: true); pump(0.6)
        check(applied.count == 4, "принудительно (пробуждение) — применено при той же подписи")
        print("  итого: уведомлений \(co.notes), применений \(co.applies), пропусков \(co.skips)")

        // Непрерывный поток уведомлений чаще 0,4 с (BetterDisplay, KVM, автоскрытие Dock): предел ожидания 1,5 с.
        co.maxWait = 1.5
        applied.removeAll()
        let fires0 = co.applies + co.skips
        let tFirst = Date()
        var k = 0, maxGap = 0.0, prev = Date()
        while Date().timeIntervalSince(tFirst) < 3.5 {
            k += 1
            current = [builtin(), external(w: 2560 + CGFloat(k % 2) * 100)]
            co.note(); pump(0.15)
            maxGap = max(maxGap, Date().timeIntervalSince(prev)); prev = Date()
        }
        let firstLag = applied.first.map { $0.timeIntervalSince(tFirst) } ?? -1
        let fires = co.applies + co.skips - fires0
        print(String(format: "  поток из %d уведомлений за 3,5 с (наибольший промежуток %.2f с): сверок %d, применений %d, первое через %.2f с",
                     k, maxGap, fires, applied.count, firstLag))
        // Без предела при промежутках < 0,4 с не было бы ни одной сверки до конца потока. Сверка может
        // оказаться пропуском: подпись в потоке скачет туда-обратно.
        check(maxGap >= 0.4 || (firstLag > 0 && firstLag < 1.5 + 0.35 && fires >= 2),
              "поток без пауз применяется не позже ~1,5 с (предел ожидания)")
        pump(0.6)
        // Пачка, начатая во сне, после пробуждения ждёт свои 0,4 с, а не применяется сразу по старому пределу.
        let before = applied.count
        co.isHeld = true
        current = [builtin()]
        co.note()
        pump(1.7)
        co.isHeld = false
        let tWake = Date()
        _ = pump(until: { applied.count > before }, timeout: 1)
        let wakeLag = Date().timeIntervalSince(tWake)
        print(String(format: "  пачка из сна применена через %.2f с после пробуждения", wakeLag))
        check(applied.count == before + 1 && wakeLag >= 0.3, "после пробуждения — склейка заново (≈0,4 с), не мгновенно")
    }

    // MARK: 2. Сон и пробуждение

    static func sleep() {
        print("\n== sleep: состояние системы, события модулям, общий тикер")
        let sys = SystemStateCenter()
        var got: [IslandSystemEvent] = []
        let token = sys.addHandler(owner: "test") { got.append($0) }
        let seq: [(IslandSystemEvent, IslandMotion)] = [
            (.willSleep, .off), (.didWake, .full), (.screensDidSleep, .off), (.screensDidWake, .full),
            (.screenLocked, .off), (.screenUnlocked, .full), (.sessionDidResignActive, .off),
            (.sessionDidBecomeActive, .full),
        ]
        for (e, m) in seq {
            sys.handle(e)
            check(sys.motion == m, "\(e.rawValue) → движение \(m)")
        }
        check(got.count == seq.count, "модуль получил \(got.count) из \(seq.count) событий")
        sys.removeHandler(owner: "test", token: token)
        sys.handle(.didWake)
        check(got.count == seq.count, "после отписки событий нет")

        // «Застрял во сне»: блокировка была, а `screenIsUnlocked` не пришёл — сверка с системой чинит флаги и
        // рассылает недостающее событие (по нему ядро возвращает мониторы мыши и острова).
        var fixes: [IslandSystemEvent] = []
        let t2 = sys.addHandler(owner: "test") { fixes.append($0) }
        sys.handle(.screenLocked)
        sys.handle(.sessionDidResignActive)
        fixes.removeAll()
        sys.applySessionState(locked: false, onConsole: true)
        check(sys.isInteractive && sys.motion == .full && fixes == [.sessionDidBecomeActive, .screenUnlocked],
              "сверка сессии: застрявшая блокировка снята, события \(fixes.map(\.rawValue))")
        fixes.removeAll()
        sys.applySessionState(locked: false, onConsole: true)
        check(fixes.isEmpty, "сверка без расхождений — без событий")
        sys.removeHandler(owner: "test", token: t2)
        if let real = SystemStateCenter.readSessionState() {
            print("  настоящая сессия этого Мака: заблокирован \(real.locked), на консоли \(real.onConsole)")
        } else {
            print("  настоящая сессия: словаря CGSession нет (не GUI-сессия)")
        }

        // Подписка через ModuleContext → снимается ядром при остановке модулей.
        let env = makeEnv()
        if let ctx = env.contexts.values.first {
            var n = 0
            ctx.onSystemEvent { _ in n += 1 }
            SystemStateCenter.shared.handle(.didWake)
            SystemStateCenter.shared.removeHandlers(owner: ctx.moduleId)
            SystemStateCenter.shared.handle(.didWake)
            check(n == 1, "context.onSystemEvent: 1 событие до снятия, 0 после")
        }

        // Тикер: работает только с подписчиками, пауза во сне, догоняющий тик после пробуждения.
        let ticker = SharedTicker(system: sys)
        check(!ticker.isRunning, "тикер без подписчиков не работает")
        var ticks = 0
        var tok: AnyCancellable? = ticker.subscribe(every: 0.2) { _ in ticks += 1 }
        pump(1.05)
        print("  тиков за 1,05 с при интервале 0,2 с: \(ticks), срабатываний таймера: \(ticker.fireCount)")
        check((4...6).contains(ticks), "тикер 0,2 с: 4–6 тиков за секунду")
        sys.handle(.willSleep)
        let atSleep = ticks
        pump(0.7)
        check(!ticker.isRunning && ticks == atSleep, "во сне тикер стоит (тиков \(ticks - atSleep))")
        sys.handle(.didWake)
        let tWake = Date()
        _ = pump(until: { ticks > atSleep }, timeout: 0.5)
        print(String(format: "  догоняющий тик через %.3f с после пробуждения", Date().timeIntervalSince(tWake)))
        check(ticks == atSleep + 1, "после пробуждения — один догоняющий тик (тиков \(ticks - atSleep))")
        var ticks2 = 0
        let tok2 = ticker.subscribe(every: 1) { _ in ticks2 += 1 }
        pump(0.3)
        tok?.cancel(); tok = nil
        check(ticker.isRunning && ticker.subscriberCount == 1, "второй подписчик держит тикер")
        tok2.cancel()
        check(!ticker.isRunning && ticker.subscriberCount == 0, "последний отписался → таймер снят")
        _ = ticks2
        // Токен отпущен не на главном потоке — отписка уходит на главную очередь, процесс не падает.
        let tok3 = ticker.subscribe(every: 1) { _ in }
        let box = TokenBox(tok3)
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread { box.token?.cancel(); box.token = nil; done.signal() }
        done.wait()
        _ = pump(until: { ticker.subscriberCount == 0 }, timeout: 1)
        check(ticker.subscriberCount == 0 && !ticker.isRunning, "отписка с фонового потока — без падения, таймер снят")
    }

    // MARK: 3. Уровень движения

    static func motion() {
        print("\n== motion: «Уменьшить движение», энергосбережение, батарея, видимость окна")
        let sys = SystemStateCenter()
        sys.simulateMotionInputs(reduceMotion: false, lowPower: false, onBattery: false)
        check(sys.motion == .full, "обычный режим → full")
        sys.simulateMotionInputs(reduceMotion: true)
        check(sys.motion == .reduced, "«Уменьшить движение» → reduced")
        sys.simulateMotionInputs(reduceMotion: false, lowPower: true)
        check(sys.motion == .full, "энергосбережение анимации не глушит (решение 16.11) → full")
        sys.simulateMotionInputs(lowPower: false, onBattery: true)
        check(sys.motion == .full, "батарея без настройки → full")
        sys.setReduceMotionOnBattery(true)
        check(sys.motion == .reduced, "батарея + настройка → reduced")
        sys.handle(.screensDidSleep)
        check(sys.motion == .off, "экраны спят → off (важнее reduced)")
        sys.handle(.screensDidWake)
        check(sys.motion == .reduced, "экраны проснулись → снова reduced")
        check(IslandMotion.off.animation(.default) == nil && IslandMotion.reduced.animation(.spring()) != nil,
              "off — без анимации, reduced — короткое затухание")
        check(!IslandMotion.reduced.allowsContinuousAnimation && IslandMotion.full.allowsContinuousAnimation,
              "бегущая рамка/эквалайзер только при full")

        // Остров, окно которого не показано → off, независимо от системы.
        let env = makeEnv()
        let c = IslandController(descriptor: builtin(), geometry: IslandGeometry.detect(builtin(), floatingAllowed: true)!, env: env)
        c.updateMotion()
        check(c.model.motion == .off, "окно не видно → движение острова off")
        c.close()
        print("  настоящие входы этого Мака: «Уменьшить движение» \(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion), энергосбережение \(ProcessInfo.processInfo.isLowPowerModeEnabled), батарея \(SystemStateCenter.readOnBattery())")
    }

    // MARK: 4. Пересборки и утечки

    static func rebuild(_ n: Int) {
        print("\n== rebuild \(n): пересоздание острова, живые окна/хосты, phys_footprint")
        let env = makeEnv()
        let g = IslandGeometry.detect(builtin(), floatingAllowed: true)!
        // Панели показываются по-настоящему (оконный сервер, слои), но за пределами экранов (x = −40000).
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(.prohibited) }
        let start = LiveObjects.counts
        if start.hosts + start.panels > 0 { print("  до теста уже живых (от других тестов): \(start)") }
        // Создавать внутри autoreleasepool: у CLI-процесса нет внешнего пула, который бы опустошался.
        var keep: IslandController?
        autoreleasepool { keep = IslandController(descriptor: builtin(), geometry: g, env: env) }
        // Разогрев: первые сборки SwiftUI заполняют кэши — их не считаем ростом.
        for _ in 0..<5 { autoreleasepool { let c = IslandController(descriptor: external(), geometry: g, env: env); c.show(); pump(0.02); c.close() } }
        pump(0.3)
        var shown = 0, onServer = 0
        func phase() {
            for i in 0..<n {
                autoreleasepool {
                    if i % 2 == 0 {
                        let c = IslandController(descriptor: external(), geometry: g, env: env)
                        c.show()
                        c.model.expanded = i % 4 == 0
                        pump(0.02)
                        if c.panel.isVisible { shown += 1 }
                        if c.panel.windowNumber > 0 { onServer += 1 }
                        c.close()
                    } else {
                        // Тот же путь, что при подключении/отключении монитора (IslandSet показывает новые).
                        let set = IslandSet(env: env)
                        set.reconcile(IslandPlanner.plan([external()], .init(allScreens: true)))
                        pump(0.02)
                        set.closeAll()
                    }
                }
            }
            pump(0.5)
        }
        let base = physFootprint()
        let t0 = Date()
        phase()
        let mid = physFootprint()
        phase()
        let after = physFootprint()
        // Третья серия: под нагрузкой разовый скачок кэшей в одной серии бывает до ~2 МБ (14.11: порог 1,5 МБ мигал
        // и на main, 2 из 4). Утечка растит КАЖДУЮ серию — берём меньший рост из второй и третьей.
        phase()
        let after3 = physFootprint()
        let counts = LiveObjects.counts
        let g1 = mid > base ? mid - base : 0, g2 = after > mid ? after - mid : 0
        let g3 = after3 > after ? after3 - after : 0
        print("  за \(String(format: "%.1f", Date().timeIntervalSince(t0))) с (2 × \(n)): живых хостов \(counts.hosts), панелей \(counts.panels), моделей \(counts.models), контроллеров \(counts.controllers)")
        print("  панели показаны: \(shown) из \(3 * ((n + 1) / 2)), на оконном сервере \(onServer)")
        print("  phys_footprint: до \(mb(base)), после \(n) \(mb(mid)) (+\(mb(g1))), после \(2 * n) \(mb(after)) (+\(mb(g2))), после \(3 * n) \(mb(after3)) (+\(mb(g3)))")
        check(shown == 3 * ((n + 1) / 2) && onServer == shown, "панели реально показаны (за экраном)")
        check(counts.hosts - start.hosts == 1 && counts.panels - start.panels == 1
              && counts.models - start.models == 1 && counts.controllers - start.controllers == 1,
              "после \(3 * n) пересборок живёт ровно один остров")
        // Не абсолютный порог (кэши SwiftUI/AppKit растут до плато по-разному), а наклон: вторая серия из n
        // пересборок не должна расти, как при утечке острова (≥ 100 КБ на пересборку).
        let slopeLimit = max(UInt64(1_572_864), UInt64(n) * 24 * 1024)
        check(min(g2, g3) <= slopeLimit,
              "рост за вторую/третью серию \(mb(g2))/\(mb(g3)), меньший ≤ \(mb(slopeLimit)) — плато, не утечка")
        let keepIsLive = autoreleasepool { LiveObjects.controllers.allObjects.contains { $0 === keep } }
        print("  живой контроллер — тот, что держим: \(keepIsLive)")
        autoreleasepool { keep?.close(); keep = nil }
        pump(0.3)
        let last = LiveObjects.counts
        check(last.hosts == start.hosts && last.panels == start.panels && last.models == start.models
              && last.controllers == start.controllers,
              "после закрытия последнего — ноль (хостов \(last.hosts), панелей \(last.panels), моделей \(last.models))")
    }

    /// Отладка утечки: живёт ли остров после close() в зависимости от того, сколько он прожил.
    static func leakProbe() {
        let env = makeEnv()
        let g = IslandGeometry.detect(builtin(), floatingAllowed: true)!
        for (life, expand) in [(0.0, false), (0.02, false), (0.3, false), (1.0, false), (0.02, true), (0.3, true)] {
            var c: IslandController?
            autoreleasepool { c = IslandController(descriptor: builtin(), geometry: g, env: env); c?.model.expanded = expand }
            pump(life)
            autoreleasepool { c?.close(); c = nil }
            pump(0.3)
            print("  жил \(life) с, раскрыт \(expand) → после close: \(LiveObjects.counts)")
        }
    }

    // MARK: 5. Петля перерисовки

    /// Модуль, меняющий высоту вкладки на каждый запрос.
    private final class ResizingModule: IslandModule {
        var id: String { "resizer" }
        var title: String { "Тест" }
        var systemImage: String { "square" }
        var height: CGFloat = 180
        var expandedHeight: CGFloat { height }
        func start(context: ModuleContext) {}
    }

    static func loop() {
        print("\n== loop: склейка публикаций и защита от петли layoutChanged → objectWillChange")
        let module = ResizingModule()
        let env = makeEnv(modules: [module])
        let c = IslandController(descriptor: builtin(), geometry: IslandGeometry.detect(builtin(), floatingAllowed: true)!, env: env)
        var islandPublishes = 0
        var modelPublishes = 0
        var bag = Set<AnyCancellable>()
        env.island.objectWillChange.sink { _ in islandPublishes += 1 }.store(in: &bag)
        c.model.objectWillChange.sink { _ in modelPublishes += 1 }.store(in: &bag)
        pump(0.1)

        // a) 1000 смен состояния за один шаг цикла → одна отчётная публикация.
        var s0 = c.stats, i0 = islandPublishes
        for i in 0..<1000 {
            c.model.expanded = i % 2 == 0
            if i % 3 == 0 { env.hud.show(HUDEvent(kind: "volume", value: Double(i % 100) / 100)) } else { env.hud.dismiss() }
        }
        c.model.expanded = false
        env.hud.dismiss()
        pump(0.2)
        var s1 = c.stats
        print("  1000 смен за шаг: изменений \(s1.stateChanges - s0.stateChanges), отчётов \(s1.reports - s0.reports), публикаций центра \(islandPublishes - i0)")
        check(s1.reports - s0.reports <= 2 && islandPublishes - i0 <= 4, "1000 смен за шаг → ≤ 2 отчёта, ≤ 4 публикации")

        // b) 1000 смен по одной на шаг → публикаций не больше смен.
        s0 = c.stats; i0 = islandPublishes
        var k = 0
        func next() {
            k += 1
            c.model.expanded = k % 2 == 0
            if k < 1000 { DispatchQueue.main.async { MainActor.assumeIsolated { next() } } }
        }
        next()
        // Под нагрузкой 1000 шагов цикла идут секунды — дождаться конца, иначе цепочка залезет в следующий опыт.
        check(pump(until: { k >= 1000 }, timeout: 120), "цепочка из 1000 шагов завершилась")
        c.model.expanded = false
        pump(0.2)
        s1 = c.stats
        print("  1000 смен по шагам: отчётов \(s1.reports - s0.reports), публикаций центра \(islandPublishes - i0)")
        check(s1.reports - s0.reports <= 1002 && islandPublishes - i0 <= 2 * 1000 + 4, "по шагам: публикаций ≤ 2 на смену")

        // c) Обратная связь: каждая публикация модели/центра зовёт invalidateLayout (как вьюха, что меряет себя
        //    в body). Без защиты — бесконечная петля; с защитой затухает за 1–2 прохода.
        env.island.objectWillChange.sink { _ in env.layoutChanged.send() }.store(in: &bag)
        c.model.objectWillChange.sink { _ in env.layoutChanged.send() }.store(in: &bag)
        s0 = c.stats
        let m0 = modelPublishes
        c.model.expand(tab: "resizer")
        pump(0.5)
        let mid = c.stats
        pump(0.3)
        s1 = c.stats
        print("  обратная связь: запросов раскладки \(s1.layoutRequests - s0.layoutRequests), проходов \(s1.layoutPasses - s0.layoutPasses), публикаций раскладки \(s1.layoutPublishes - s0.layoutPublishes), публикаций модели \(modelPublishes - m0)")
        check(s1.layoutPasses - s0.layoutPasses <= 4 && s1.layoutPublishes - s0.layoutPublishes <= 2,
              "петля затухает: ≤ 4 прохода, ≤ 2 публикации")
        check(s1.layoutPasses == mid.layoutPasses && s1.reports == mid.reports, "после затухания — тишина")

        // d) Модуль меняет высоту в каждом шаге цикла 1000 раз → проходов не больше 6 за 100 мс.
        s0 = c.stats
        var j = 0
        let t0 = Date()
        func grow() {
            j += 1
            module.height = 180 + CGFloat(j % 60)
            env.layoutChanged.send()
            if j < 1000 { DispatchQueue.main.async { MainActor.assumeIsolated { grow() } } }
        }
        grow()
        check(pump(until: { j >= 1000 }, timeout: 120), "1000 смен высоты завершились")
        let dt = Date().timeIntervalSince(t0)
        pump(0.3)
        s1 = c.stats
        let passes = s1.layoutPasses - s0.layoutPasses
        let limit = Int((dt + 0.3) / 0.1 + 1) * IslandController.layoutBurstLimit
        print(String(format: "  высота меняется 1000 раз за %.2f с: запросов %d, проходов %d (предел %d)", dt,
                     s1.layoutRequests - s0.layoutRequests, passes, limit))
        check(passes <= limit && passes < 1000, "проходов раскладки ≤ \(IslandController.layoutBurstLimit) за 100 мс")
        c.close()
        bag.removeAll()
    }

    // MARK: 6. Утилиты модулей

    static func utils() {
        print("\n== utils: ManagedProcess, ImageDownsampler, TailReader, FileWatcher")
        processTests()
        imageTests()
        fileTests()
    }

    private static func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

    private static func processTests() {
        // Вывод и EOF: обработчик чтения снимается, а не крутится (AT#891).
        let echo = ManagedProcess(executable: "/bin/sh", arguments: ["-c", "echo один; echo два; printf хвост"])
        var lines: [String] = []
        var exitCode: Int32 = -99
        echo.onLine = { lines.append($0) }
        echo.onExit = { exitCode = $0 }
        echo.start()
        _ = pump(until: { exitCode != -99 }, timeout: 5)
        pump(0.3)
        print("  echo: строки \(lines), код \(exitCode), вызовов чтения \(echo.readCallbacks)")
        check(lines == ["один", "два", "хвост"] && exitCode == 0, "строки собраны, хвост без \\n отдан на EOF")
        check(echo.readCallbacks <= 6, "на EOF чтение остановилось (вызовов \(echo.readCallbacks))")

        // Группа процессов: stop() гасит и ребёнка, и внука.
        let tree = ManagedProcess(executable: "/bin/sh", arguments: ["-c", "sleep 30 & echo $!; wait"])
        var grandchild: pid_t = 0
        tree.onLine = { grandchild = pid_t($0) ?? 0 }
        tree.start()
        let child = tree.pid
        _ = pump(until: { grandchild > 0 }, timeout: 5)
        check(alive(child) && grandchild > 0 && alive(grandchild), "ребёнок \(child) и внук \(grandchild) запущены")
        tree.stop(grace: 0.5)
        _ = pump(until: { !alive(grandchild) && !tree.isRunning }, timeout: 3)
        check(!tree.isRunning && !alive(child) && !alive(grandchild), "stop() завершил всю группу")

        // terminateAll (выход приложения).
        let sleeper = ManagedProcess(executable: "/bin/sleep", arguments: ["30"])
        sleeper.start()
        let sp = sleeper.pid
        check(ManagedProcess.liveGroups.contains(sp), "живые группы учитываются (\(ManagedProcess.liveGroups.count))")
        ManagedProcess.terminateAll(grace: 0.5)
        pump(0.2)
        check(!alive(sp) && ManagedProcess.liveGroups.isEmpty, "terminateAll: детей не осталось")

        // Перезапуск с паузой.
        let failing = ManagedProcess(executable: "/bin/sh", arguments: ["-c", "exit 3"], restart: .onFailure)
        failing.start()
        _ = pump(until: { failing.restartCount >= 1 }, timeout: 3)
        check(failing.restartCount >= 1, "упал с кодом 3 → перезапущен через паузу (перезапусков \(failing.restartCount))")
        failing.stop()
        let rc = failing.restartCount
        pump(2.5)
        check(failing.restartCount == rc, "после stop() перезапусков нет")

        // Брошен без stop(): deinit гасит группу и снимает запись.
        var abandoned: pid_t = 0
        autoreleasepool {
            let p = ManagedProcess(executable: "/bin/sleep", arguments: ["30"])
            p.start()
            abandoned = p.pid
        }
        _ = pump(until: { !alive(abandoned) && !ManagedProcess.liveGroups.contains(abandoned) }, timeout: 2)
        check(abandoned > 0 && !alive(abandoned) && !ManagedProcess.liveGroups.contains(abandoned),
              "ManagedProcess без stop() освобождён → ребёнок погашен, запись снята")

        orphanTests()
        signalTests()
    }

    /// Ребёнок через оболочку-прослойку (/bin/sh → bash: имя в процессе меняется) + внук; «приложение» убито
    /// `kill -9` → следующий запуск добивает обоих по pgid и времени старта.
    private static func orphanTests() {
        guard let exe = Bundle.main.executablePath else { check(false, "путь к себе"); return }
        let dir = ManagedProcess.pidDirectory
        let helper = ManagedProcess(executable: exe, arguments: ["--selftest-core", "orphan-child", dir.path])
        var child: pid_t = 0, grand: pid_t = 0
        helper.onLine = { line in
            let f = line.split(separator: " ")
            if f.count == 4, f[0] == "child" { child = pid_t(f[1]) ?? 0; grand = pid_t(f[3]) ?? 0 }
        }
        helper.start()
        _ = pump(until: { grand > 0 }, timeout: 15)
        let name = ManagedProcess.executableName(of: child) ?? "?"
        check(child > 0 && grand > 0 && alive(child) && alive(grand), "сирота: «приложение» \(helper.pid), ребёнок \(child) (\(name)), внук \(grand)")
        kill(helper.pid, SIGKILL)                  // жёсткое падение «приложения»: своя группа, только оно
        _ = pump(until: { !helper.isRunning }, timeout: 3)
        _ = pump(until: { ManagedProcess.parentPID(of: child) == 1 }, timeout: 2)
        check(alive(child) && alive(grand) && ManagedProcess.parentPID(of: child) == 1,
              "после kill -9 ребёнок и внук живы, родитель — launchd")
        // Чужой процесс с тем же pgid, но другим временем старта, и живой экземпляр — не трогаются.
        let decoy = ManagedProcess(executable: "/bin/sleep", arguments: ["30"])
        decoy.start()
        let fake = dir.appendingPathComponent("children.99999.pids")
        try? "\(decoy.pid) 1 2 sleep".write(to: fake, atomically: true, encoding: .utf8)
        let n = ManagedProcess.reapOrphans()
        _ = pump(until: { !alive(child) && !alive(grand) }, timeout: 2)
        print("  reapOrphans: групп \(n); ребёнок жив \(alive(child)), внук жив \(alive(grand)), чужой жив \(alive(decoy.pid))")
        check(n == 1 && !alive(child) && !alive(grand), "сироты прошлого запуска добиты (оболочка-прослойка распознана)")
        check(alive(decoy.pid) && !FileManager.default.fileExists(atPath: fake.path),
              "процесс с тем же pgid и другим временем старта не тронут")
        decoy.stop(grace: 0.2)
        _ = pump(until: { !decoy.isRunning }, timeout: 2)
    }

    /// Аварийный сигнал (SIGHUP без обработчика приложения) в «приложении» с детьми: дети погашены, процесс
    /// завершён тем же сигналом (прежнее действие, а не проглоченный сигнал).
    private static func signalTests() {
        guard let exe = Bundle.main.executablePath else { return }
        let helper = ManagedProcess(executable: exe, arguments: ["--selftest-core", "orphan-child",
                                                                 ManagedProcess.pidDirectory.path])
        var child: pid_t = 0, grand: pid_t = 0
        var code: Int32 = 0
        helper.onLine = { line in
            let f = line.split(separator: " ")
            if f.count == 4, f[0] == "child" { child = pid_t(f[1]) ?? 0; grand = pid_t(f[3]) ?? 0 }
        }
        helper.onExit = { code = $0 }
        helper.start()
        _ = pump(until: { grand > 0 }, timeout: 15)
        kill(helper.pid, SIGHUP)
        _ = pump(until: { !helper.isRunning && !alive(child) && !alive(grand) }, timeout: 3)
        print("  SIGHUP: код выхода \(code), ребёнок жив \(alive(child)), внук жив \(alive(grand))")
        check(code == -SIGHUP && grand > 0 && !alive(child) && !alive(grand),
              "сигнал: дети погашены из обработчика, процесс завершён тем же сигналом")
    }

    /// Служебный режим: запустить ребёнка через /bin/sh с внуком, сообщить pid-ы и ждать, пока не убьют.
    private static func orphanChild(_ dir: String?) -> Int32 {
        if let dir { ManagedProcess.pidDirectory = URL(fileURLWithPath: dir) }
        let p = ManagedProcess(executable: "/bin/sh", arguments: ["-c", "sleep 60 & echo $!; wait"])
        var grand: pid_t = 0
        p.onLine = { grand = pid_t($0) ?? 0 }
        p.start()
        _ = pump(until: { grand > 0 }, timeout: 10)
        FileHandle.standardOutput.write(Data("child \(p.pid) grandchild \(grand)\n".utf8))
        pump(60)
        p.stop()
        return 0
    }

    private static func imageTests() {
        // Большая картинка 3000×2000 → миниатюра под 64 pt ×2.
        let w = 3000, h = 2000
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { check(false, "CGContext"); return }
        ctx.setFillColor(CGColor(red: 1, green: 0.3, blue: 0.1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w / 2, height: h))
        ctx.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 1, alpha: 1)); ctx.fill(CGRect(x: w / 2, y: 0, width: w / 2, height: h))
        guard let big = ctx.makeImage(),
              let png = NSBitmapImageRep(cgImage: big).representation(using: .png, properties: [:]) else {
            check(false, "PNG"); return
        }
        let d = ImageDownsampler(costLimit: 1 << 20)
        var img1: NSImage?, img2: NSImage?
        var done = false
        Task { @MainActor in
            img1 = await d.image(data: png, maxPointSize: 64)
            img2 = await d.image(data: png, maxPointSize: 64)
            done = true
        }
        _ = pump(until: { done }, timeout: 10)
        let px = img1?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        print("  миниатюра: \(px?.width ?? 0)×\(px?.height ?? 0) px из \(w)×\(h), PNG \(png.count / 1024) КБ")
        check((px?.width ?? 0) == 128 && (px?.height ?? 0) <= 128, "бóльшая сторона = 64 pt × 2 = 128 px")
        check(img1 != nil && img1 === img2, "повтор — из кэша (тот же объект)")
        let colors = img1.flatMap { ImageDownsampler.dominantColors(of: $0) } ?? []
        check(colors.count == 3, "цвета свечения с уменьшенной копии: \(colors.count)")
    }

    private static func openFDs() -> Int { (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1 }

    private static func fileTests() {
        let fd0 = openFDs()
        defer {
            pump(0.2)
            let fd1 = openFDs()
            print("  открытых дескрипторов: до \(fd0), после \(fd1)")
            check(fd1 <= fd0, "TailReader/FileWatcher не оставили открытых дескрипторов")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("si-selftest-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // TailReader: 5 МБ журнала → читаем хвост, а не всё; дописанное — по событию.
        let log = dir.appendingPathComponent("session.jsonl")
        var text = ""
        for i in 0..<60_000 { text += "{\"n\":\(i),\"pad\":\"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\"}\n" }
        try? text.write(to: log, atomically: false, encoding: .utf8)
        let size = (try? FileManager.default.attributesOfItem(atPath: log.path)[.size] as? Int) ?? 0
        var got: [String] = []
        let tail = TailReader(url: log) { got.append(contentsOf: $0) }
        tail.start(tailBytes: 4096)
        print("  журнал \(size / 1024) КБ: прочитано \(tail.bytesRead) байт, строк \(got.count), последняя \(got.last?.prefix(14) ?? "—")")
        check(tail.bytesRead <= 4096 && got.last?.hasPrefix("{\"n\":59999") == true, "хвост: ≤ 4 КБ из \(size / 1024) КБ")
        let h = try? FileHandle(forWritingTo: log)
        _ = try? h?.seekToEnd()
        try? h?.write(contentsOf: Data("новая-1\nновая-2\nнов".utf8))
        let before = got.count
        _ = pump(until: { got.count >= before + 2 }, timeout: 2)
        try? h?.write(contentsOf: Data("ая-3\n".utf8))
        try? h?.close()
        _ = pump(until: { got.count >= before + 3 }, timeout: 2)
        check(Array(got.suffix(3)) == ["новая-1", "новая-2", "новая-3"], "дописанные строки пришли по событию, обрывок склеен")
        try? "после-ротации\n".write(to: log, atomically: true, encoding: .utf8)
        _ = pump(until: { got.last == "после-ротации" }, timeout: 2)
        check(got.last == "после-ротации", "файл заменён (ротация) → читается новый с начала")
        for r in 1...3 {
            try? "ротация-\(r)\n".write(to: log, atomically: true, encoding: .utf8)
            _ = pump(until: { got.last == "ротация-\(r)" }, timeout: 2)
            let a = try? FileHandle(forWritingTo: log)
            _ = try? a?.seekToEnd(); try? a?.write(contentsOf: Data("после-\(r)\n".utf8)); try? a?.close()
            _ = pump(until: { got.last == "после-\(r)" }, timeout: 2)
        }
        check(Array(got.suffix(2)) == ["ротация-3", "после-3"], "3 ротации с дописыванием — всё пришло")
        tail.stop()

        // FileWatcher: запись, атомарная замена, удаление + создание.
        let status = dir.appendingPathComponent("status.json")
        try? "{}".write(to: status, atomically: true, encoding: .utf8)
        let w = FileWatcher(url: status) {}
        w.start()
        let fh = try? FileHandle(forWritingTo: status)
        _ = try? fh?.seekToEnd(); try? fh?.write(contentsOf: Data(" ".utf8)); try? fh?.close()
        _ = pump(until: { w.changeCount >= 1 }, timeout: 2)
        check(w.changeCount == 1, "запись в файл → 1 событие")
        try? "{\"a\":1}".write(to: status, atomically: true, encoding: .utf8)
        _ = pump(until: { w.changeCount >= 2 }, timeout: 2)
        check(w.changeCount == 2 && w.isWatchingFile, "атомарная замена → событие, слежение переоткрыто")
        try? "{\"a\":2}".write(to: status, atomically: true, encoding: .utf8)
        _ = pump(until: { w.changeCount >= 3 }, timeout: 2)
        check(w.changeCount == 3, "вторая замена тоже видна (следим за новым файлом)")
        try? FileManager.default.removeItem(at: status)
        pump(0.3)
        try? "{\"b\":1}".write(to: status, atomically: false, encoding: .utf8)
        _ = pump(until: { w.changeCount >= 5 && w.isWatchingFile }, timeout: 2)
        check(w.isWatchingFile && w.changeCount >= 4, "удалили и создали заново → снова следим (событий \(w.changeCount))")
        w.stop()
    }

    // MARK: 7. Включение модуля и права (S3)

    static func perms() {
        print("\n== perms: включение модуля, права без системных окон")
        let env = makeEnv()
        guard let tabId = env.settings.data.tabs.first?.id, let ctx = env.contexts[tabId] else {
            check(false, "нет модуля с вкладкой"); return
        }
        check(ctx.isEnabled, "модуль \(tabId) с включённой вкладкой — включён")
        // Без ключа объяснения в Info.plist (у debug-бинарника Info.plist нет) системное окно не показываем.
        check(IslandPermission.microphone.usageDescriptionKey == "NSMicrophoneUsageDescription"
              && IslandPermission.automation(bundleId: "com.apple.Music").usageDescriptionKey == nil
              && (Bundle.main.object(forInfoDictionaryKey: "NSRemindersFullAccessUsageDescription") != nil
                  || !Permissions.canRequest(.reminders)),
              "права без ключа в Info.plist не запрашиваются (иначе TCC убьёт процесс)")
        if let hud = env.modules.first(where: { !$0.providesTab }), let hc = env.contexts[hud.id] {
            check(hc.isEnabled, "модуль без вкладки (\(hud.id)) — всегда включён")
        }
        var changes: [Bool] = []
        var seenInside: [Bool] = []
        let sub = ctx.onEnabledChange { on in changes.append(on); seenInside.append(ctx.isEnabled) }
        func setTab(_ on: Bool) {
            var d = env.settings.data
            if let i = d.tabs.firstIndex(where: { $0.id == tabId }) { d.tabs[i].enabled = on }
            env.settings.data = d
        }
        setTab(false); pump(0.05)
        env.settings.data.expandedWidth += 1; pump(0.05)       // другая настройка — не событие
        setTab(true); pump(0.05)
        check(changes == [false, true] && seenInside == [false, true],
              "onEnabledChange: \(changes) (в обработчике isEnabled уже новый: \(seenInside))")
        sub.cancel()

        // Выключенный модуль: ensurePermission не спрашивает и не показывает карточку.
        setTab(false); pump(0.05)
        var r1: PermissionStatus?
        Task { @MainActor in r1 = await ctx.ensurePermission(.camera, reason: "тест") }
        _ = pump(until: { r1 != nil }, timeout: 3)
        check(r1 == Permissions.status(.camera) && env.notifications.current == nil,
              "выключенный модуль: только статус (\(r1?.rawValue ?? "—")), без окна и карточки")
        setTab(true); pump(0.05)
        // Автоматизация незапущенного приложения: .unknown → ни запроса, ни карточки.
        var r2: PermissionStatus?
        Task { @MainActor in r2 = await ctx.ensurePermission(.automation(bundleId: "local.simpleisland.nonexistent"), reason: "тест") }
        _ = pump(until: { r2 != nil }, timeout: 3)
        check(r2 == .unknown && env.notifications.current == nil, "автоматизация, приложение не запущено → \(r2?.rawValue ?? "—"), без карточки")
        print("  Универсальный доступ: \(Permissions.status(.accessibility).rawValue) (запрашивали: \(Permissions.accessibilityWasRequested))")
    }

    // MARK: 8. Доступность

    // --- misc2 ---
    /// Удержание раскрытого острова (`holdExpanded`): уход курсора при открытом меню модуля не сворачивает остров,
    /// после отпускания — сворачивает (если курсор не вернулся); явное сворачивание работает всегда; страховочный срок.
    static func hold() {
        print("\n== hold: меню модуля держит остров раскрытым")
        var data = SettingsData()
        data.collapseDelay = 0.05
        data.hoverDelay = 0.01
        let env = makeEnv(data)
        let c = IslandController(descriptor: builtin(), geometry: IslandGeometry.detect(builtin(), floatingAllowed: true)!, env: env)
        guard let ctx = env.contexts["shelf"] ?? env.contexts.values.first else { check(false, "нет контекста модуля"); return }
        let m = c.model
        m.expand(tab: ctx.moduleId)
        check(m.expanded, "раскрыт")
        // a) без удержания: курсор ушёл → свернулся
        m.pointer(inside: true); m.pointer(inside: false)
        check(pump(until: { !m.expanded }, timeout: 2), "без удержания уход курсора сворачивает")
        // b) удержание: курсор ушёл на меню → не сворачивается; отпустили → свернулся
        m.expand(tab: ctx.moduleId); m.pointer(inside: true)
        ctx.holdExpanded("menu")
        check(env.island.isExpandHeld && env.island.expandHolds.contains("\(ctx.moduleId).menu"), "удержание записано с именем модуля")
        m.pointer(inside: false)
        pump(0.3)
        check(m.expanded, "меню открыто — уход курсора не сворачивает")
        ctx.releaseExpanded("menu")
        check(pump(until: { !m.expanded }, timeout: 2), "меню закрыли, курсора нет — свернулся")
        // c) курсор вернулся до отпускания — остаётся раскрытым
        m.expand(tab: ctx.moduleId); m.pointer(inside: true)
        ctx.holdExpanded("menu")
        m.pointer(inside: false); pump(0.2)
        m.pointer(inside: true)
        ctx.releaseExpanded("menu")
        pump(0.3)
        check(m.expanded, "курсор вернулся до закрытия меню — раскрыт")
        // d) явное сворачивание при удержании работает
        ctx.holdExpanded("menu")
        m.collapse()
        check(!m.expanded, "явное сворачивание (клик/свайп/сон) не блокируется")
        ctx.releaseAllExpandHolds()
        check(!env.island.isExpandHeld, "releaseAllExpandHolds снимает всё")
        // e) страховочный срок
        m.expand(tab: ctx.moduleId); m.pointer(inside: true)
        ctx.holdExpanded("menu", timeout: 1)
        m.pointer(inside: false)
        pump(0.5)
        check(m.expanded, "до срока держит")
        check(pump(until: { !m.expanded }, timeout: 3), "удержание снялось по сроку — свернулся")
        // f) публикации: повторное удержание тем же токеном не публикует
        var pubs = 0
        let sub = env.island.$expandHolds.dropFirst().sink { _ in pubs += 1 }
        ctx.holdExpanded("x"); ctx.holdExpanded("x"); ctx.releaseExpanded("x"); ctx.releaseExpanded("x")
        check(pubs == 2, "без публикации того же значения (\(pubs))")
        sub.cancel()
        // g) удержание — только у острова на вкладке модуля: второй монитор на другой вкладке сворачивается
        if let other = env.enabledTabModules.first(where: { $0.id != ctx.moduleId }) {
            let c2 = IslandController(descriptor: external(), geometry: IslandGeometry.detect(external(), floatingAllowed: true)!, env: env)
            let m2 = c2.model
            m.expand(tab: ctx.moduleId); m.pointer(inside: true)
            m2.expand(tab: other.id); m2.pointer(inside: true)
            ctx.holdExpanded("menu")
            m.pointer(inside: false); m2.pointer(inside: false)
            check(pump(until: { !m2.expanded }, timeout: 2), "другой остров на вкладке «\(other.id)» сворачивается при чужом удержании")
            check(m.expanded, "остров на вкладке модуля держится")
            ctx.releaseExpanded("menu")
            check(pump(until: { !m.expanded }, timeout: 2), "отпустили — свернулся и он")
            c2.close()
        } else { check(false, "нет второй вкладки для проверки двух островов") }
        c.close()
    }

    // --- shelfbar ---
    /// Удержание покоя (`holdCollapsed`): раскрытый остров сворачивается, раскрыть нельзя (клик, свайп, подлёт
    /// файла), наведение не набухает, компакт/HUD/уведомление не показываются — ширина ровно вырез; после отпускания
    /// остров снова показывает актуальное (компакт).
    static func calm() {
        print("\n== calm: остров в покое на время уборки строки меню")
        var data = SettingsData()
        data.collapseDelay = 0.05
        data.hoverDelay = 0.01
        let env = makeEnv(data)
        let g = IslandGeometry.detect(builtin(), floatingAllowed: true)!
        let c = IslandController(descriptor: builtin(), geometry: g, env: env)
        let m = c.model
        guard let ctx = env.contexts["menubar"] ?? env.contexts.values.first else { check(false, "нет контекста"); return }
        env.activities.post(IslandActivity(id: "m", moduleId: "media") { EmptyView() } trailing: { EmptyView() })
        check(m.presentation == .compact, "до удержания — компакт (\(m.presentation))")
        let compactW = m.currentMetrics.width
        m.expand()
        check(m.expanded, "раскрыт до удержания")
        ctx.holdCollapsed("cleanup")
        check(env.island.collapseHolds.contains("\(ctx.moduleId).cleanup") && ctx.isCollapseHeld, "удержание записано с именем модуля")
        check(pump(until: { !m.expanded && m.calm }, timeout: 1), "раскрытый остров свернулся")
        check(m.presentation == .idle, "в покое — .idle при активности (\(m.presentation))")
        let w = m.currentMetrics
        check(w.width == g.gap && w.height == g.notchHeight && w.earRadius == 0,
              "ширина ровно вырез \(w.width) = \(g.gap), без ушей (компакт был \(compactW))")
        env.hud.show(HUDEvent(kind: "volume", value: 0.5))
        check(m.presentation == .idle && m.currentMetrics.width == g.gap, "HUD-вспышка остров не расширяет")
        env.hud.dismiss()
        m.expand()
        check(!m.expanded, "expand (клик/свайп/«+») не раскрывает")
        m.scroll(physicalDeltaY: 30, precise: true, phase: .began)
        check(!m.expanded, "свайп вниз не раскрывает")
        env.island.setFileDrag(active: true)
        m.pointer(inside: true)
        pump(0.2)
        check(!m.hovering && !m.expanded, "наведение и подлёт файла не раскрывают и не набухают")
        check(m.currentMetrics.width == g.gap, "при наведении — всё ещё ровно вырез")
        m.pointer(inside: false)
        env.island.setFileDrag(active: false)
        ctx.holdCollapsed("cleanup")
        var pubs = 0
        let sub = env.island.$collapseHolds.dropFirst().sink { _ in pubs += 1 }
        ctx.holdCollapsed("cleanup")
        check(pubs == 0, "повторное удержание не публикует")
        ctx.releaseCollapsed("cleanup")
        check(pump(until: { !m.calm }, timeout: 1), "отпустили — покой снят")
        check(m.presentation == .compact && m.currentMetrics.width == compactW, "вернулся компакт той же ширины")
        m.expand()
        check(m.expanded, "раскрывается снова")
        m.collapse()
        ctx.holdCollapsed("a"); ctx.holdCollapsed("b")
        ctx.releaseAllCollapseHolds()
        check(!env.island.isCollapseHeld, "releaseAllCollapseHolds снимает все удержания модуля")
        check(pubs >= 2, "публикации только по изменению (\(pubs))")
        sub.cancel()
        c.close()
    }

    /// Разбор drag-буфера (`DragPasteboard`) на синтетических пастбордах: файл, file:// и http-ссылка, обещание
    /// файла (как у миниатюры снимка экрана), PNG и TIFF, текст; приём в папку — файлы как есть, обещание
    /// выполнено, картинка сохранена PNG «Снимок …».
    static func dragPasteboard() {
        print("\n== drag: что тащат (файл, обещание, картинка, ссылка)")
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("si-selftest-drag-\(getpid())", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let src = tmp.appendingPathComponent("отчёт.txt")
        try? Data("привет".utf8).write(to: src)
        var pasteboards: [NSPasteboard] = []
        func pb(_ fill: (NSPasteboard) -> Void) -> NSPasteboard {
            let p = NSPasteboard(name: .init("SimpleIsland.selftest.drag.\(getpid()).\(pasteboards.count)"))
            p.clearContents()
            fill(p)
            pasteboards.append(p)
            return p
        }
        func receive(_ p: NSPasteboard, _ dir: String) -> [URL]? {
            var out: [URL]?
            DragPasteboard.receive(p, into: tmp.appendingPathComponent(dir), timeout: 5) { out = $0 }
            _ = pump(until: { out != nil }, timeout: 8)
            return out
        }
        // 1. Файл из Finder
        let file = pb { $0.writeObjects([src as NSURL]) }
        var c = DragPasteboard.inspect(file)
        check(c.kind == .files && c.fileURLs.map(\.lastPathComponent) == ["отчёт.txt"], "file-url → файл (\(c.kind))")
        // --- shelfshot --- файл во временной папке ($TMPDIR — как у миниатюры снимка) копируется в папку приёма сразу
        let gotA = receive(file, "a")?.first
        check(gotA?.deletingLastPathComponent().lastPathComponent == "a" && gotA?.lastPathComponent == "отчёт.txt",
              "временный файл копируется в папку приёма при броске (\(gotA?.path ?? "—"))")
        // 2. Ссылки: file:// через public.url — файл; http — не файл
        let furl = pb { $0.setString(src.absoluteString, forType: .URL) }
        c = DragPasteboard.inspect(furl)
        check(c.kind == .files && c.fileURLs.first?.path == src.standardizedFileURL.path, "public.url file:// → файл (\(c.kind))")
        let web = pb { $0.writeObjects([URL(string: "https://example.com/cat.png")! as NSURL]) }
        c = DragPasteboard.inspect(web)
        check(!c.isFileLike && c.remoteURLs.count == 1, "http-ссылка — не файл, сеть не трогаем")
        check(receive(web, "w") == [], "http-ссылка → ничего не принято")
        // 3. Текст
        let text = pb { $0.setString("просто текст", forType: .string) }
        check(!DragPasteboard.isFileLike(text), "текст — не файл")
        // 4. Сырая картинка PNG и TIFF
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 3, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = rep.representation(using: .png, properties: [:])!
        let pngPB = pb { $0.setData(png, forType: .png) }
        c = DragPasteboard.inspect(pngPB)
        check(c.kind == .image && c.imageType == .png, "public.png → картинка")
        let gotPNG = receive(pngPB, "p") ?? []
        let isPNG: (URL) -> Bool = { u in
            (try? Data(contentsOf: u))?.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        }
        check(gotPNG.count == 1 && gotPNG[0].lastPathComponent.hasPrefix("Снимок ") && gotPNG[0].pathExtension == "png"
              && isPNG(gotPNG[0]), "картинка сохранена PNG «\(gotPNG.first?.lastPathComponent ?? "—")»")
        let tiffPB = pb { $0.setData(rep.tiffRepresentation!, forType: .tiff) }
        check(DragPasteboard.inspect(tiffPB).imageType == .tiff, "public.tiff → картинка")
        let gotTIFF = receive(tiffPB, "p") ?? []
        check(gotTIFF.count == 1 && isPNG(gotTIFF[0]) && gotTIFF[0] != gotPNG.first, "TIFF → PNG, имя не затирает прежний")
        // 5. Файл + картинка: приоритет у файла
        let both = pb { p in p.writeObjects([src as NSURL]); p.addTypes([.png], owner: nil); p.setData(png, forType: .png) }
        check(DragPasteboard.inspect(both).kind == .files, "файл важнее картинки")
        // 6. Обещание файла (NSFilePromiseProvider — как у миниатюры снимка экрана ⌘⇧4)
        let delegate = SelfTestPromise(data: png)
        let provider = NSFilePromiseProvider(fileType: "public.png", delegate: delegate)
        let promise = pb { $0.writeObjects([provider]) }
        c = DragPasteboard.inspect(promise)
        print("  типы обещания: \((promise.types ?? []).map(\.rawValue))")
        check(c.kind == .promises && c.promiseCount == 1 && c.isFileLike, "обещание файла → «тащат файл» (\(c.kind), \(c.promiseCount))")
        check(DragPasteboard.promisedFileTypes(promise) == ["public.png"], "приёмник обещания собран, тип public.png")
        // Выполнение обещания идёт через drag-сеанс источника: на синтетическом пастборде система его не зовёт
        // (проверено 15.11), поэтому здесь — только что приём не виснет и по сроку отдаёт пустой итог. Само
        // выполнение — живой проверкой (миниатюра снимка экрана на остров).
        // macOS 27 (20.11): NSFilePromiseReceiver вне настоящего перетаскивания — NSAssertion и abort процесса;
        // в живом броске обещание приходит из drag-сеанса и так не падает. Синтетический приём — только до 27.
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27 {
            let t0 = Date()
            var promised: [URL]?
            DragPasteboard.receive(promise, into: tmp.appendingPathComponent("promise"), timeout: 1) { promised = $0 }
            _ = pump(until: { promised != nil }, timeout: 4)
            check(promised != nil && Date().timeIntervalSince(t0) < 3, "приём обещания не виснет: итог по сроку (\(promised?.count ?? -1))")
        }
        _ = isPNG
        // 7. Типы для drop-зон
        let ids = Set(DragPasteboard.dropUTTypes.map(\.identifier))
        check(ids.isSuperset(of: ["public.file-url", "public.png", "public.tiff", "com.apple.NSFilePromiseItemMetaData"]),
              "drop-зона острова принимает file-url, картинки и обещания")
        check(DragPasteboard.imageFileName(date: Date(timeIntervalSince1970: 0)).hasPrefix("Снимок 19"), "имя «Снимок <дата> в <время>.png»")
        for p in pasteboards { p.releaseGlobally() }
    }
    // --- /shelfbar ---

    /// Разовый запуск `ManagedProcess.runCollecting`: итог, таймаут, уборка каталогов вывода прошлых запусков.
    static func oneShotRuns() {
        print("\n== run: разовые запуски утилит (runCollecting)")
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("SimpleIsland-run", isDirectory: true)
        // pid 999999 не бывает (pid_max на macOS — 99998), pid 1 (launchd) жив всегда.
        let stale = root.appendingPathComponent("999999-selftest"), live = root.appendingPathComponent("1-selftest")
        try? fm.createDirectory(at: stale, withIntermediateDirectories: true)
        try? fm.createDirectory(at: live, withIntermediateDirectories: true)
        let r = ManagedProcess.runCollectingBlocking("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"], timeout: 10)
        check(r.status == 3 && r.stdout == "out\n" && r.stderr == "err\n" && !r.timedOut && !r.launchFailed,
              "код, stdout, stderr (\(r.status) «\(r.stdout)» «\(r.stderr)»)")
        check(!fm.fileExists(atPath: stale.path), "каталог вывода умершего процесса убран при первом запуске")
        check(fm.fileExists(atPath: live.path), "каталог живого процесса не тронут")
        try? fm.removeItem(at: live)
        let own = (try? fm.contentsOfDirectory(atPath: root.path))?.filter { $0.hasPrefix("\(getpid())-") } ?? []
        check(own.isEmpty, "после итога свой каталог вывода удалён (\(own.count))")
        let t0 = Date()
        let t = ManagedProcess.runCollectingBlocking("/bin/sh", ["-c", "trap '' TERM; sleep 30"], timeout: 0.3)
        let dt = Date().timeIntervalSince(t0)
        check(t.timedOut && dt < 0.3 + ManagedProcess.killGrace + ManagedProcess.giveUpAfterKill + 1,
              String(format: "SIGTERM игнорируют — SIGKILL, итог «не ответил» за %.1f с", dt))
        check(pump(until: { ManagedProcess.liveGroups.isEmpty }, timeout: 5), "живых групп не осталось")
        let n = ManagedProcess.runCollectingBlocking("/nonexistent/tool", [])
        check(n.launchFailed && n.status == -1, "нет программы — launchFailed без падения")
    }
    // --- /misc2 ---

    // MARK: Права: решение «окно macOS / настройки + карточка / перезапуск»

    static func permissionGuide() {
        print("\n== guide: кнопки «Разрешить…» не молчат")
        // Как запущен процесс.
        let app = "/Applications/SimpleIsland.app"
        check(LaunchKind.detect(pid: 500, parentPid: 1, responsiblePid: 500, bundlePath: app) == .app,
              "из Finder/Dock (родитель launchd, сам себе ответственный) — приложение")
        check(LaunchKind.detect(pid: 500, parentPid: 300, responsiblePid: 34541, bundlePath: app) == .child(bundled: true),
              "из оболочки (ответственный — чужой) — не приложение, перезапуск возможен")
        check(LaunchKind.detect(pid: 500, parentPid: 300, responsiblePid: 500, bundlePath: app) == .app,
              "родитель не launchd, но ответственный сам — приложение")
        check(LaunchKind.detect(pid: 500, parentPid: 1, responsiblePid: nil, bundlePath: app) == .app
              && LaunchKind.detect(pid: 500, parentPid: 77, responsiblePid: nil, bundlePath: "/x/.build/debug") == .child(bundled: false),
              "без responsibility_* — по родителю; отладочный бинарник — перезапуск невозможен")
        let me = LaunchKind.current
        print("  этот процесс: \(me), ppid \(getppid()), ответственный \(LaunchKind.responsiblePid(of: getpid()).map(String.init) ?? "—")")
        check(!me.isApp, "самотест из оболочки распознан как «не приложение» (так же, как экземпляр, что видел пользователь)")

        // До запроса.
        typealias P = Permissions
        let A = LaunchKind.app, C = LaunchKind.child(bundled: true), D = LaunchKind.child(bundled: false)
        check(P.plan(.calendars, status: .granted, canRequest: true, launch: C) == .granted, "уже есть — ничего")
        check(P.plan(.calendars, status: .notDetermined, canRequest: true, launch: C) == .guide(.relaunch(canRelaunch: true))
              && P.plan(.camera, status: .denied, canRequest: true, launch: D) == .guide(.relaunch(canRelaunch: false)),
              "не приложение — без окна macOS (ушло бы от имени родителя), карточка «перезапустить»")
        check(P.plan(.calendars, status: .notDetermined, canRequest: true, launch: A) == .systemPrompt,
              "не спрашивали — окно macOS")
        check(P.plan(.calendars, status: .notDetermined, canRequest: false, launch: A) == .guide(.cannotAsk),
              "нет строки Info.plist — настройки + карточка, без окна (TCC убил бы процесс)")
        check(P.plan(.calendars, status: .denied, canRequest: true, launch: A) == .guide(.deniedBefore)
              && P.plan(.accessibility, status: .denied, canRequest: true, launch: A) == .guide(.deniedBefore),
              "запрещено раньше (и Универсальный доступ во второй раз) — настройки + карточка")
        check(P.plan(.automation(bundleId: "com.apple.Music"), status: .unknown, canRequest: true, launch: A) == .guide(.targetNotRunning)
              && P.plan(.bluetooth, status: .unknown, canRequest: true, launch: A) == .systemPrompt,
              "автоматизация незапущенного — «запустите»; прочее неизвестное — окно")
        // После запроса.
        check(P.followUp(.calendars, after: .granted, elapsed: 0.01, launch: A) == .granted, "дали — ничего")
        check(P.followUp(.calendars, after: .denied, elapsed: 0.05, launch: A) == .guide(.noAnswer),
              "ответ «нет» сразу — окно не появилось → настройки + карточка")
        check(P.followUp(.calendars, after: .notDetermined, elapsed: 0.05, launch: A) == .guide(.noAnswer),
              "статус не изменился — то же")
        check(P.followUp(.camera, after: .denied, elapsed: 3, launch: A) == .guide(.declined), "отказали в окне — настройки + карточка")
        check(P.followUp(.accessibility, after: .denied, elapsed: 0.01, launch: A) == .guide(.accessibilityPrompted),
              "Универсальный доступ — карточка без второго окна настроек")
        check(P.followUp(.automation(bundleId: "x"), after: .unknown, elapsed: 0.01, launch: A) == .guide(.targetNotRunning)
              && P.followUp(.reminders, after: .denied, elapsed: 0.01, launch: C) == .guide(.relaunch(canRelaunch: true)),
              "автоматизация без приложения; не приложение — перезапуск")
        // Ни один исход не молчит: у каждой подсказки есть текст, у «настроечных» — раздел, у перезапуска — кнопка.
        let all: [IslandPermission] = [.accessibility, .automation(bundleId: "com.apple.systemevents"), .calendars, .reminders,
                                       .camera, .microphone, .bluetooth, .audioCapture]
        let guides: [PermissionGuide] = [.deniedBefore, .cannotAsk, .noAnswer, .declined, .accessibilityPrompted,
                                         .targetNotRunning, .relaunch(canRelaunch: true), .relaunch(canRelaunch: false)]
        var bad: [String] = []
        for p in all {
            check(p.settingsURL.absoluteString.hasPrefix("x-apple.systempreferences:com.apple.preference.security?Privacy_"),
                  "\(p.title): раздел \(p.settingsURL.absoluteString.components(separatedBy: "?").last ?? "")")
            for g in guides {
                let t = g.text(for: p)
                if t.title.isEmpty || t.body.isEmpty || t.body.count > 130 { bad.append("\(p.title)/\(g): \(t.body.count)") }
                if g.opensSettings && !t.body.contains(p.paneTitle) { bad.append("\(p.title)/\(g): нет раздела") }
                let n = PermissionGuideCard(permission: p, guide: g).notification()
                let titles = n.actions.map(\.title)
                switch g {
                case .relaunch(true): if titles != ["Перезапустить"] { bad.append("\(g): \(titles)") }
                case .relaunch(false), .targetNotRunning: if !titles.isEmpty { bad.append("\(g): \(titles)") }
                default: if titles != ["Открыть настройки"] { bad.append("\(g): \(titles)") }
                }
                if n.bodyLines != 3 || n.duration == nil { bad.append("\(g): строки \(n.bodyLines)") }
            }
        }
        check(bad.isEmpty, "тексты ≤ 130 знаков, раздел назван, кнопки по случаю (\(bad.prefix(3)))")
        check(Set(guides.filter(\.opensSettings).map { "\($0)" }) == ["deniedBefore", "cannotAsk", "noAnswer"],
              "Системные настройки открываются сами, только когда окна macOS не было; после «Не разрешать», перезапуска и окна Универсального доступа — нет")
        check(PermissionGuideCard(permission: .camera, guide: .declined).notification().actions.map(\.title) == ["Открыть настройки"],
              "после «Не разрешать» — только карточка с кнопкой «Открыть настройки»")
        let relaunchBody = PermissionGuide.relaunch(canRelaunch: true).text(for: .calendars).body
        check(relaunchBody.contains("только у приложения, открытого из Finder/Dock") && relaunchBody.contains("Перезапустите"),
              "текст перезапуска: «\(relaunchBody)»")
        // Подсказка уходит в показ (приложение — карточкой в острове), раздел настроек при этом не открываем.
        var shown: PermissionGuideCard?
        let saved = PermissionGuideCenter.presenter
        PermissionGuideCenter.presenter = { shown = $0 }
        Permissions.showGuide(.relaunch(canRelaunch: true), for: .calendars, moduleId: "today")
        PermissionGuideCenter.presenter = saved
        check(shown?.guide == .relaunch(canRelaunch: true) && shown?.moduleId == "today"
              && PermissionGuideCenter.last?.permission == .calendars, "подсказка передана показу")
        // Старт из оболочки: модули проверяют права — ОДНА общая карточка за запуск, не ответ на нажатие.
        var launchCards: [PermissionGuideCard] = []
        PermissionGuideCenter.presenter = { launchCards.append($0) }
        PermissionGuideCenter.launchCardShown = false
        let firstNote = Permissions.noteNotLaunchedAsApp(.calendars, moduleId: "today")
        Permissions.noteNotLaunchedAsApp(.camera, moduleId: "today")
        Permissions.noteNotLaunchedAsApp(.accessibility, moduleId: "hud")
        PermissionGuideCenter.presenter = saved
        check(firstNote && launchCards.count == 1 && launchCards.first?.interactive == false
              && launchCards.first?.notificationId == "permission.guide.launch"
              && launchCards.first?.title == "SimpleIsland запущен не как приложение",
              "старт из оболочки: 3 проверки прав → 1 общая карточка «\(launchCards.first?.title ?? "—")»")
        // Показ: не ответ на нажатие — обычная очередь, раскрытый остров не трогаем; ответ — свернуть и вне очереди.
        autoreleasepool {
            let penv = makeEnv()
            let c = IslandController(descriptor: builtin(), geometry: IslandGeometry.detect(builtin(), floatingAllowed: true)!, env: penv)
            penv.notifications.post(IslandNotification(id: "other", moduleId: "x", title: "O", body: "o", duration: nil))
            c.model.expand()
            if let card = launchCards.first { AppDelegate.present(card, env: penv, controllers: [c]) }
            let quiet = c.model.expanded && penv.notifications.current?.id == "other"
            AppDelegate.present(PermissionGuideCard(permission: .calendars, guide: .noAnswer), env: penv, controllers: [c])
            let loud = !c.model.expanded && penv.notifications.current?.id == "permission.guide.Календари"
            penv.notifications.dismiss(); let next = penv.notifications.current?.id
            penv.notifications.dismiss(); let last = penv.notifications.current?.id
            check(quiet && loud && next == "other" && last == "permission.guide.launch",
                  "общая карточка — в очередь, остров раскрыт; на нажатие — свёрнут и сразу (\(quiet)/\(loud), потом \(next ?? "—"), \(last ?? "—"))")
            c.close()
        }
        // Карточка — вне очереди, показанная уходит в начало очереди.
        let notes = IslandNotifications()
        notes.post(IslandNotification(id: "a", moduleId: "x", title: "A", body: "a", duration: nil))
        notes.post(IslandNotification(id: "b", moduleId: "x", title: "B", body: "b", duration: nil))
        notes.postFront(PermissionGuideCard(permission: .calendars, guide: .noAnswer).notification())
        let firstShown = notes.current?.id
        notes.dismiss(); let second = notes.current?.id
        notes.dismiss(); let third = notes.current?.id
        check(firstShown == "permission.guide.Календари" && second == "a" && third == "b",
              "postFront: \(firstShown ?? "—"), затем \(second ?? "—"), \(third ?? "—")")
        // Высота многострочной карточки.
        let env = makeEnv()
        let model = IslandModel(env: env, geometry: IslandGeometry.detect(builtin(), floatingAllowed: true)!)
        env.notifications.show(IslandNotification(moduleId: "x", title: "t", body: "b"))
        let h1 = model.metrics(for: .notification).height
        env.notifications.show(PermissionGuideCard(permission: .calendars, guide: .deniedBefore).notification())
        let h3 = model.metrics(for: .notification).height, w3 = model.metrics(for: .notification).width
        check(h3 == h1 + 32 && w3 >= 580, "три строки — выше на 32 pt (\(h1) → \(h3)), шире (\(w3))")

        // Перезапуск: помощник ждёт выхода процесса и только потом `open -n`; не дождался — не открывает.
        let t0 = Date()
        let wait = ManagedProcess.runCollectingBlocking("/bin/sh", ["-c", AppRelauncher.helperScript(waitingFor: getpid(), tries: 3),
                                                                    "sh", "/nonexistent/SimpleIsland.app"], timeout: 10)
        let dt = Date().timeIntervalSince(t0)
        check(wait.status == 1 && wait.stderr.isEmpty && dt >= 0.25,
              String(format: "процесс жив — помощник ждёт и сдаётся без open (код %d, %.2f с)", wait.status, dt))
        // Зомби (вышел, родитель не забрал): `kill -0` видит его живым, `ps` — «Z» → считать вышедшим.
        var zpid: pid_t = 0
        var zargs: [UnsafeMutablePointer<CChar>?] = [strdup("/usr/bin/true"), nil]
        let spawned = posix_spawn(&zpid, "/usr/bin/true", nil, nil, &zargs, environ) == 0
        for a in zargs { free(a) }
        pump(0.3)
        let zstat = ManagedProcess.runCollectingBlocking("/bin/ps", ["-o", "stat=", "-p", "\(zpid)"], timeout: 5).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let tz = Date()
        let zr = ManagedProcess.runCollectingBlocking("/bin/sh", ["-c", AppRelauncher.helperScript(waitingFor: zpid, tries: 30),
                                                                  "sh", "/nonexistent/SimpleIsland.app"], timeout: 10)
        let zdt = Date().timeIntervalSince(tz)
        var st: Int32 = 0
        waitpid(zpid, &st, 0)
        check(spawned && zstat.hasPrefix("Z") && kill(zpid, 0) != 0 && zr.stderr.contains("/nonexistent/SimpleIsland.app") && zdt < 2,
              String(format: "зомби (ps «%@») — вышедший: open -n сразу (%.2f с), а не ожидание", zstat, zdt))
        check(AppRelauncher.helperScript(waitingFor: 1).contains("[ $i -gt 300 ]"), "предел ожидания выхода — 30 с")
        let gone = ManagedProcess.runCollectingBlocking("/bin/sh", ["-c", AppRelauncher.helperScript(waitingFor: 99999),
                                                                    "sh", "/nonexistent/SimpleIsland.app"], timeout: 10)
        check(gone.status != 0 && gone.stderr.contains("/nonexistent/SimpleIsland.app"),
              "процесса нет — сразу open -n (несуществующий путь: «\(gone.stderr.trimmingCharacters(in: .whitespacesAndNewlines))»)")
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("si-relaunch-\(getpid()).txt")
        let ok = AppRelauncher.spawnDetached(["/bin/sh", "-c", "/bin/ps -o pgid= -p $$ > \"$1\"; echo $$ >> \"$1\"", "sh", out.path])
        _ = pump(until: { ((try? String(contentsOf: out, encoding: .utf8)) ?? "").split(separator: "\n").count >= 2 }, timeout: 3)
        let lines = ((try? String(contentsOf: out, encoding: .utf8)) ?? "").split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        try? FileManager.default.removeItem(at: out)
        check(ok && lines.count == 2 && lines[0] == lines[1] && lines[0] != "\(getpgrp())",
              "помощник — в своей сессии (pgid \(lines.first ?? "—") = pid, не группа приложения \(getpgrp()))")
        check(AppRelauncher.bundleURL == nil, "отладочный бинарник без .app — перезапускать нечего")
    }

    // MARK: Ловушка кликов мимо раскрытого острова

    static func clickTrap() {
        print("\n== trap: клик мимо раскрытого острова только сворачивает")
        let base = TrapConditions(enabled: true, anyExpanded: true)
        func with(_ f: (inout TrapConditions) -> Void) -> Bool { var c = base; f(&c); return ClickAwayTrap.shouldShow(c) }
        check(ClickAwayTrap.shouldShow(base) && !with { $0.enabled = false } && !with { $0.anyExpanded = false }
              && !with { $0.suspended = true } && !with { $0.fileDrag = true } && !with { $0.dragSuppressed = true },
              "решение: раскрыт + настройка; не во сне, не при перетаскивании")
        check(!with { $0.held = true } && !with { $0.ownWindowActive = true } && !with { $0.voiceOver = true },
              "нет ловушки: модуль держит остров (меню, «Поделиться», AirDrop), наше окно ключевое/модальное, VoiceOver")
        autoreleasepool {
            let plain = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
            plain.isReleasedWhenClosed = false   // иначе close() отпустит его второй раз
            let notch = NotchPanel(contentRect: .zero)
            let trapW = ClickTrapWindow(frame: .zero)
            check(ClickAwayTrap.isOwnWindowActive(key: plain, modal: nil)
                  && ClickAwayTrap.isOwnWindowActive(key: nil, modal: plain)
                  && !ClickAwayTrap.isOwnWindowActive(key: notch, modal: nil)
                  && !ClickAwayTrap.isOwnWindowActive(key: trapW, modal: nil)
                  && !ClickAwayTrap.isOwnWindowActive(key: nil, modal: nil),
                  "Настройки/Каталог/NSOpenPanel ключевые или runModal → наше окно активно; остров и ловушка — нет")
            check(!trapW.isAccessibilityElement() && trapW.isAccessibilityHidden()
                  && !(trapW.contentView?.isAccessibilityElement() ?? true), "VoiceOver ловушку не видит")
            notch.close(); trapW.close(); plain.close()
        }
        check(SettingsData().clickAwayOnlyCollapses, "настройка по умолчанию включена")
        // Окна показываются по-настоящему (оконный сервер), но за экранами (x = −40000).
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(.prohibited) }
        let start = LiveObjects.trapCount
        let env = makeEnv()
        let set = IslandSet(env: env)
        set.showsPanels = false
        let two = [builtin(), external()]
        set.reconcile(IslandPlanner.plan(two, .init(allScreens: true)))
        let trap = ClickAwayTrap(env: env) { set.controllers }
        trap.setScreens(two)
        check(trap.windows.isEmpty && !trap.isShown, "до раскрытия окон нет (создаются при первом раскрытии)")
        guard let m = set.controllers.first?.model else { check(false, "нет острова"); return }
        m.expand()
        check(pump(until: { trap.isShown }, timeout: 2), "раскрыли — ловушка показана")
        autoreleasepool {
            let ws = Array(trap.windows.values)
            check(ws.count == 2 && ws.allSatisfy(\.isVisible) && ws.allSatisfy { $0.windowNumber > 0 },
                  "на обоих экранах (клик на другом мониторе тоже только сворачивает): \(ws.count)")
        }
        autoreleasepool { if let w = trap.windows[2] {
            let panel = set.controllers[0].panel
            check(w.level.rawValue > NSWindow.Level.floating.rawValue && w.level.rawValue > 20   // Dock — 20
                  && w.level.rawValue < NSWindow.Level.mainMenu.rawValue && w.level.rawValue < panel.level.rawValue,
                  "уровень \(w.level.rawValue): выше окон и Dock, ниже строки меню (24) и острова (\(panel.level.rawValue))")
            check(!w.canBecomeKey && !w.canBecomeMain && !w.ignoresMouseEvents && w.styleMask.contains(.nonactivatingPanel),
                  "клавиатуру не берёт, приложение не активирует, клики принимает")
            let a = w.backgroundColor.alphaComponent
            check(a * 255 >= 1 && a < 0.01, String(format: "фон почти прозрачный, но не 0 в 8 битах (%.4f)", a))
            check(w.collectionBehavior == panel.collectionBehavior, "столы и полный экран — как у панели острова")
            check(w.frame == external().frame, "рамка — весь экран")
        } }
        // События держат окно до опустошения пула — свой пул, иначе счёт живых окон ниже врал бы.
        // Нажатия: событие в окно → свернуть и поглотить.
        func send(_ type: NSEvent.EventType, to w: ClickTrapWindow) {
            guard let e = NSEvent.mouseEvent(with: type, location: NSPoint(x: 20, y: 20), modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                             context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
            w.sendEvent(e)
        }
        autoreleasepool {
            var results: [String] = []
            for type in [NSEvent.EventType.leftMouseDown, .rightMouseDown, .otherMouseDown] {
                m.expand()
                _ = pump(until: { trap.isShown }, timeout: 2)
                if let w = trap.windows[2] { send(type, to: w) }
                let collapsed = !m.expanded
                let hidden = pump(until: { !trap.isShown && trap.windows.values.allSatisfy { !$0.isVisible } }, timeout: 2)
                results.append("\(type.rawValue):\(collapsed && hidden ? "ok" : "нет")")
            }
            check(results.allSatisfy { $0.hasSuffix("ok") } && trap.stats.clicks == 3,
                  "левая/правая/средняя кнопка на другом экране — свернуть, ловушка ушла (\(results))")
            check(trap.windows.count == 2 && trap.stats.created == 2, "окна переиспользуются: создано \(trap.stats.created)")
            // Скролл и отпускание — не сворачивают.
            m.expand(); _ = pump(until: { trap.isShown }, timeout: 2)
            if let w = trap.windows[1], let v = w.contentView, let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -5, wheel2: 0, wheel3: 0),
               let e = NSEvent(cgEvent: cg) {
                v.scrollWheel(with: e)
                send(.leftMouseUp, to: w)
            }
            pump(0.1)
            check(m.expanded && trap.isShown, "скролл и отпускание кнопки остров не сворачивают")
        }
        // Клик в зону острова (панель не успела включить приём) — не сворачивать.
        let inside = NSPoint(x: set.controllers[0].islandRect().midX, y: set.controllers[0].islandRect().midY)
        trap.handleClick(at: inside)
        check(m.expanded && trap.stats.ignoredInside == 1, "клик в зоне острова — не «мимо»")
        // Перетаскивание файлов — ловушки нет.
        env.island.setFileDrag(active: true)
        check(pump(until: { !trap.isShown }, timeout: 2), "тащат файлы — ловушка убрана (бросок доходит до окон)")
        env.island.setFileDrag(active: false)
        check(pump(until: { trap.isShown }, timeout: 2), "перетаскивание кончилось — снова на месте")
        // Перетаскивание над самой ловушкой (из острова наружу) — уходит до сворачивания.
        autoreleasepool { trap.windows[1]?.onDragEntered?() }
        check(!trap.isShown && trap.windows.values.allSatisfy { !$0.isVisible }, "drag над ловушкой — ушла")
        m.collapse(); pump(0.1); m.expand()
        check(pump(until: { trap.isShown }, timeout: 2), "после сворачивания следующее раскрытие — снова с ловушкой")
        // Настройка и сон.
        env.settings.data.clickAwayOnlyCollapses = false
        check(pump(until: { !trap.isShown }, timeout: 2), "настройка выключена — ловушки нет")
        env.settings.data.clickAwayOnlyCollapses = true
        check(pump(until: { trap.isShown }, timeout: 2), "включили — есть")
        trap.suspended = true
        check(pump(until: { !trap.isShown }, timeout: 2), "сон/блокировка — убрана")
        trap.suspended = false
        check(pump(until: { trap.isShown }, timeout: 2), "пробуждение — на месте")
        // Модуль держит остров (меню, «Поделиться», AirDrop) — ловушки нет, отпустил — есть.
        if let ctx = env.contexts["shelf"] ?? env.contexts.values.first {
            ctx.holdExpanded("share")
            check(pump(until: { !trap.isShown }, timeout: 2), "holdExpanded (окно «Поделиться»/AirDrop) — ловушка убрана")
            ctx.releaseExpanded("share")
            check(pump(until: { trap.isShown }, timeout: 2), "отпустил — снова на месте")
        }
        // Ключевым стало наше окно / модальное (runModal NSOpenPanel): решение сразу, по уведомлению, без шага цикла.
        var ownActive = true
        trap.conditionsOverride = { $0.ownWindowActive = ownActive }
        autoreleasepool { NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: nil) }
        check(!trap.isShown && autoreleasepool { trap.windows.values.allSatisfy { !$0.isVisible } },
              "ключевое наше окно / модальная панель — ловушка убрана синхронно (в модальном цикле клик дошёл бы до панели)")
        ownActive = false
        autoreleasepool { NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: nil) }
        check(trap.isShown, "окно отпустило ключ — ловушка вернулась")
        trap.conditionsOverride = { $0.voiceOver = true }
        autoreleasepool { trap.refresh() }
        check(!trap.isShown, "VoiceOver включён — ловушки нет")
        trap.conditionsOverride = nil
        autoreleasepool { trap.refresh() }
        check(trap.isShown && trap.watchdog.isArmed, "ловушка показана — сторож взведён")
        // Сторож: снятие окон через оконный сервер с фонового потока.
        // Окна с sharingType = .none в CGWindowList не видны — спрашиваем оконный сервер напрямую.
        func onScreen() -> Set<Int> {
            let ids = autoreleasepool { (trap.windows.values.map(\.windowNumber) + (extra ?? [])) }
            return Set(ids.filter { TrapWatchdog.isOrderedIn($0) == true })
        }
        var extra: [Int]?
        let wids = autoreleasepool { trap.windows.values.map(\.windowNumber) }
        pump(0.2)   // AppKit отдаёт порядок окон оконному серверу на шаге цикла
        check(TrapWatchdog.isAvailable && wids.allSatisfy { onScreen().contains($0) },
              "SLSOrderWindow/CGSOrderWindow найдены, ловушки на оконном сервере (\(wids))")
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { TrapWatchdog.orderOut(wids); done.signal() }
        done.wait()
        check(wids.allSatisfy { !onScreen().contains($0) }, "сторож снял окна с экрана с фонового потока (без NSWindow)")
        autoreleasepool { for w in trap.windows.values { w.orderOut(nil) } }
        autoreleasepool { trap.refresh() }   // AppKit думает, что окна видны — привести в согласие
        autoreleasepool { trap.suspended = true; trap.refresh(); trap.suspended = false; trap.refresh() }
        pump(0.2)
        check(trap.isShown && wids.allSatisfy { onScreen().contains($0) }, "после — показываются как обычно")
        // Зависание главного потока: отдельная ловушка со сторожем 0,5 с.
        autoreleasepool {
            let stallTrap = ClickAwayTrap(env: env, controllers: { set.controllers }, stallLimit: 0.5)
            stallTrap.setScreens([builtin()])
            _ = pump(until: { stallTrap.isShown }, timeout: 2)
            let sw = autoreleasepool { stallTrap.windows.values.map(\.windowNumber) }
            extra = sw
            pump(0.2)
            let inBefore = !sw.isEmpty && sw.allSatisfy { onScreen().contains($0) }
            Thread.sleep(forTimeInterval: 1.6)          // главный поток «завис» (сторож — на своём потоке)
            let firedDuringStall = stallTrap.watchdog.rescues == 1
            let goneDuringStall = sw.allSatisfy { !onScreen().contains($0) }
            let recovered = pump(until: { stallTrap.stats.rescues == 1 }, timeout: 3)
            let settled = pump(until: { !m.expanded && !stallTrap.isShown && !trap.isShown }, timeout: 2)
            check(inBefore && firedDuringStall && goneDuringStall && recovered && settled,
                  "главный поток молчал 1,6 с (> 0,5): сторож снял ловушку во время зависания (\(inBefore)/\(firedDuringStall)/\(goneDuringStall)), после — остров свёрнут, ловушек нет (\(recovered)/\(settled))")
            stallTrap.closeAll()
        }
        m.expand()
        check(pump(until: { trap.isShown }, timeout: 2), "после зависания следующее раскрытие — с ловушкой")
        // Пересборка экранов: пропавший — окно закрыто; изменившийся — рамка на месте.
        // Синхронные вызовы AppKit (orderOut/close) оставляют окно в пуле — в приложении он пустеет на каждом шаге цикла.
        autoreleasepool { trap.setScreens([builtin()]) }
        pump(0.2)
        check(trap.windows.count == 1 && trap.stats.closed == 1 && LiveObjects.trapCount - start == 1,
              "экран отключили — его окно закрыто (живых \(LiveObjects.trapCount - start))")
        autoreleasepool { trap.setScreens([builtin(wide: true)]) }
        check(trap.windows[1]?.frame == builtin(wide: true).frame, "разрешение сменилось — рамка обновлена на месте")
        // 50 раскрытий и 20 подключений/отключений — без утечек.
        for i in 0..<50 {
            autoreleasepool {
                m.expand(); pump(0.005)
                m.collapse(); pump(0.005)
                if i % 5 == 0 { trap.setScreens(i % 10 == 0 ? two : [builtin()]) }
            }
        }
        for i in 0..<20 { autoreleasepool { trap.setScreens(i % 2 == 0 ? two : [builtin()]); m.expand(); pump(0.01); m.collapse(); pump(0.01) } }
        pump(0.3)
        let live = LiveObjects.trapCount - start
        check(live == trap.windows.count && live <= 2 && trap.stats.created - trap.stats.closed == trap.windows.count,
              "после 70 раскрытий и 30 пересборок живых окон \(live) (создано \(trap.stats.created), закрыто \(trap.stats.closed))")
        autoreleasepool { trap.closeAll(); set.closeAll() }
        pump(0.3)
        check(LiveObjects.trapCount == start, "выход — окон-ловушек ноль (\(LiveObjects.trapCount - start))")
    }

    static func a11y() {
        print("\n== a11y: что озвучит VoiceOver")
        let env = makeEnv()
        let model = IslandModel(env: env, geometry: .mockNotch)
        var labels: [String] = []
        func say(_ name: String) { let l = IslandAccessibility.label(model); labels.append(l); print("  \(name): «\(l)»") }
        say("покой")
        env.activities.post(IslandActivity(id: "m", moduleId: "media") { EmptyView() } trailing: { EmptyView() }
            .accessibility("Играет: Тестовый исполнитель — Трек"))
        say("компакт")
        env.activities.post(IslandActivity(id: "t", moduleId: "today", priority: -1) { EmptyView() } trailing: { EmptyView() })
        say("компакт + вторая (фон, без значка)")
        // Уши по назначениям (Настройки → Раскладка): левое — «Сегодня» → озвучиваются обе, капли нет.
        env.settings.data.leftEarModule = "today"
        let shown = IslandAccessibility.compactShown(model)
        check(shown.ears.map(\.id) == ["t", "m"] && shown.secondary == nil,
              "уши по назначению: озвучены обе активности, без повторов, значка второй нет")
        env.settings.data.leftEarModule = nil
        env.hud.show(HUDEvent(kind: "volume", systemImage: "speaker.wave.2.fill", label: "AirPods Pro", value: 0.62))
        say("HUD")
        env.hud.dismiss()
        env.notifications.show(IslandNotification(moduleId: "today", title: "Аня", source: "Telegram", body: "скинь макеты"))
        say("уведомление")
        env.notifications.dismiss()
        model.expand(tab: env.enabledTabModules.first?.id)
        say("раскрыт")
        check(labels.allSatisfy { $0.hasPrefix("SimpleIsland: ") }, "все состояния начинаются с «SimpleIsland: »")
        check(labels[1].contains("Играет") && labels[3].contains("Громкость") && labels[3].contains("62 %")
              && labels[4].contains("Аня"), "компакт/HUD/уведомление озвучивают содержание")
        check(IslandButton(systemImage: "slider.horizontal.3").resolvedAccessibilityLabel == "Настройки"
              && IslandButton(systemImage: "play.fill").resolvedAccessibilityLabel == "Играть"
              && IslandButton("Ответить").resolvedAccessibilityLabel == "Ответить"
              && IslandButton(systemImage: "xmark", accessibilityLabel: "Закрыть карточку").resolvedAccessibilityLabel == "Закрыть карточку",
              "IslandButton: подпись явная → текст → название значка")
    }
}

/// Токен, который можно отпустить с другого потока (самотест SharedTicker).
private final class TokenBox: @unchecked Sendable {
    var token: AnyCancellable?
    init(_ t: AnyCancellable) { token = t }
}

// --- shelfbar ---
/// Источник обещания для самотеста `drag`: пишет PNG по запросу приёмника.
final class SelfTestPromise: NSObject, NSFilePromiseProviderDelegate {
    let data: Data
    init(data: Data) { self.data = data }
    func filePromiseProvider(_ p: NSFilePromiseProvider, fileNameForType fileType: String) -> String { "Снимок экрана.png" }
    func filePromiseProvider(_ p: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        do { try data.write(to: url); completionHandler(nil) } catch { completionHandler(error) }
    }
}
// --- /shelfbar ---
