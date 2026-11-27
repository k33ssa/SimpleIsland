import AppKit
import Combine
import IslandCore

/// Самотест модуля «Строка меню»: `SimpleIsland --selftest-menubar [--live]`. Без окна и без прав, событий в систему не
/// шлёт, своего значка в строку меню не ставит (разделитель и перенос — в режиме dryRun).
/// * инвентарь на зафиксированном снимке слоя 25 (измерен на Маке пользователя 14.11.2026, macOS 15.5): призраки
///   выключенных модулей Пункта управления, значки под вырезом, имена, ключи; то же без имён окон (нет «Записи экрана»);
///   разделы относительно разделителя;
/// * назначение разделам и восстановление (reconcile), место нового разделителя, длина разделителя, точка броска;
/// * настройки: сохранение/чтение, частичный и испорченный JSON;
/// * карточка подтверждения (обычный, системный, часы, раскладка, без Универсального доступа) и клавиши;
/// * модуль: включение/выключение, разделитель при выходе убирается, «Вернуть всё».
/// * macOS 27 (MenuBarAgent): разбор снимка AX-слотов (измерен 20.11.2026, macOS 27.2.1), разделы при разделителе
///   в строке и в overflow, склейка окон, длина разделителя, события способа `.agent`;
/// `--live` — дополнительно печатает живой инвентарь (только чтение окон и AX-атрибутов).
/// `--live --live-move` (только macOS 27, нужен Универсальный доступ): живая проба переноса СВОИМИ двумя значками
/// (тестовый значок и разделитель) — ждёт тишины ввода ≥ 10 с (курсор на миг уходит в строку меню и возвращается),
/// ставит разделитель в строку, тестовый значок левее него, разворачивает разделитель (система прячет левее него),
/// сворачивает и убирает оба; чужие значки не переносит, их порядок сверяется до/после.
@MainActor
public enum MenuBarSelfTest {
    private static var passes = 0
    private static var failures = 0

    private static func check(_ ok: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
        if ok { passes += 1; print("ok    \(what)") } else { failures += 1; print("ПРОВАЛ \(what) \(detail())") }
    }

    public static func run(live: Bool) -> Int32 {
        _ = NSApplication.shared
        passes = 0; failures = 0
        MenuBarDivider.dryRun = true
        MenuBarMover.dryRun = true
        MenuBarMover.pressDisabled = true
        inventory()
        inventoryWithoutNames()
        sections()
        multiScreen()
        planning()
        geometry()
        showPlanning()
        moverStyles()
        failureTexts()
        prefs()
        cards()
        keys()
        hotKey()
        moduleLifecycle()
        cleanupPlate()   // --- shelfbar ---
        agentInventory()
        agentDivider()
        agentMerge()
        agentMover()
        agentMultiScreen()
        check(MenuBarMover.postedEvents == 0, "в систему не отправлено ни одного события", "\(MenuBarMover.postedEvents)")
        if live { printLive() }
        if live && CommandLine.arguments.contains("--live-move") { liveMove() }
        print("\nMenuBar selftest: \(passes) passed, \(failures) failed")
        return failures == 0 ? 0 : 1
    }

    // MARK: Снимок слоя 25 (14.11.2026, MacBook Pro 16" с вырезом, экран 1728 pt)

    nonisolated static let ownPID: pid_t = 99_999
    static let apps: [pid_t: MenuBarAppInfo] = [
        6854: .init(bundleId: "com.parallels.desktop.console", name: "Parallels Desktop"),
        36713: .init(bundleId: "ru.keepcoder.Telegram", name: "Telegram"),
        27612: .init(bundleId: "local.vafa", name: "Vafa"),
        11911: .init(bundleId: "local.screentab", name: "ScreenTab"),
        80920: .init(bundleId: "com.anthropic.claudefordesktop", name: "Claude"),
        46096: .init(bundleId: "com.rogueamoeba.soundsource", name: "SoundSource"),
        40803: .init(bundleId: "su.happ.proxy", name: "Happ"),
        2377: .init(bundleId: "com.bjango.istatmenus.status", name: "iStat Menus Status"),
        2446: .init(bundleId: "org.openvpn.client.app", name: "OpenVPN Connect"),
        2387: .init(bundleId: "com.if.Amphetamine", name: "Amphetamine"),
        2380: .init(bundleId: "com.apple.TextInputMenuAgent", name: "TextInputMenuAgent"),
        991: .init(bundleId: "com.apple.controlcenter", name: "Пункт управления"),
        1111: .init(bundleId: "com.apple.Spotlight", name: "Spotlight"),
        965: .init(bundleId: "com.electron.ollama", name: "Ollama"),
    ]

    static func w(_ owner: String, _ pid: pid_t, _ x: CGFloat, _ width: CGFloat, _ name: String, _ on: Bool, _ id: CGWindowID)
        -> MenuBarRawWindow {
        MenuBarRawWindow(windowID: id, pid: pid, ownerName: owner, name: name,
                         frame: CGRect(x: x, y: 0, width: width, height: 37), onScreen: on)
    }

    static let fixture: [MenuBarRawWindow] = [
        w("Parallels Desktop", 6854, 799, 38, "Item-1", false, 37789),
        w("Telegram", 36713, 1165, 40, "Item-0", true, 37619),
        w("Vafa", 27612, 1064, 30, "Item-0", true, 37601),
        w("ScreenTab", 11911, 837, 34, "Item-0", false, 31239),
        w("Claude", 80920, 1094, 40, "Item-0", true, 28350),
        w("SoundSource", 46096, 1506, 43, "SSMainAppMenuIcon", true, 31134),
        w("Happ", 40803, 871, 38, "Item-0", false, 19424),
        w("iStat Menus Status", 2377, 980, 84, "com.bjango.istatmenus.battery", true, 153),
        w("OpenVPN Connect", 2446, 909, 32, "Item-0", false, 147),
        w("Amphetamine", 2387, 1134, 31, "Amphetamine", true, 144),
        w("TextInputMenuAgent", 2380, 1350, 44, "Item-0", true, 143),
        w("iStat Menus Status", 2377, 941, 39, "com.bjango.istatmenus.sensors", false, 159),
        w("Пункт управления", 991, 1286, 48, "ScreenMirroring", false, 5703),
        w("OpenVPN Connect", 2446, 1264, 16, "Item-1", true, 148),
        w("Пункт управления", 991, 1016, 48, "AudioVideoModule", false, 6315),
        w("iStat Menus Status", 2377, 1205, 26, "com.bjango.istatmenus.cpu", true, 158),
        w("Spotlight", 1111, 1474, 32, "Item-0", true, 56),
        w("Пункт управления", 991, 1280, 33, "NowPlaying", true, 242),
        w("Ollama", 965, 1231, 33, "Item-0", true, 30),
        w("Пункт управления", 991, 1313, 37, "StageManager", true, 37),
        w("Пункт управления", 991, 1200, 38, "FocusModes", false, 36),
        w("Пункт управления", 991, 1394, 42, "Battery", true, 35),
        w("Пункт управления", 991, 1436, 38, "WiFi", true, 34),
        w("Пункт управления", 991, 1549, 34, "BentoBox", true, 33),
        w("Пункт управления", 991, 1583, 147, "Clock", true, 32),
        // свой значок острова — в список не идёт
        w("SimpleIsland", ownPID, 1460, 14, "Item-0", true, 9001),
    ]
    static let ccVisibility: [String: Bool] = [
        "AudioVideoModule": false, "Battery": true, "BentoBox": true, "Clock": true, "FocusModes": false,
        "NowPlaying": true, "ScreenMirroring": false, "StageManager": true, "WiFi": true,
    ]
    /// Вырез 16" (≈ 1728/2 ± 100) — для печати; раздел «под вырезом» берётся из onscreen.
    static let notch = CGRect(x: 764, y: 0, width: 200, height: 32)

    static func printTable(_ inv: MenuBarInventory) {
        func pad(_ t: String, _ n: Int) -> String { t.count >= n ? String(t.prefix(n)) : t + String(repeating: " ", count: n - t.count) }
        print("  " + pad("владелец", 20) + pad("имя", 18) + pad("рамка", 20) + pad("сист.", 6) + "раздел")
        for it in inv.items {
            let frame = "x=\(Int(it.frame.minX)) w=\(Int(it.frame.width))" + (it.onScreen ? "" : " off")
            print("  " + pad(it.ownerName, 20) + pad(it.displayName, 18) + pad(frame, 20) + pad(it.isSystem ? "да" : "нет", 6)
                  + it.section.rawValue + (it.hiddenByNotch ? " · под вырезом" : "") + (it.axTitle.map { " · AX «\($0)»" } ?? "")
                  + (it.hasStableKey ? "" : " · ключ неустойчив (\(it.key))"))
        }
    }

    // MARK: Инвентарь

    static func inventory() {
        print("— инвентарь (снимок 14.11, с именами окон)")
        let inv = MenuBarInventory.parse(MenuBarScanInput(windows: fixture, apps: apps, ownPID: ownPID,
                                                          ccVisibility: ccVisibility, notch: notch))
        printTable(inv)
        check(inv.ghosts == 3, "призраки выключенных модулей Пункта управления отброшены: 3", "\(inv.ghosts)")
        check(inv.items.count == 22, "значков 22 (25 окон − 3 призрака, свой значок не в счёт)", "\(inv.items.count)")
        check(!inv.items.contains { $0.pid == ownPID }, "свой значок не в списке")
        let notchNames = Set(inv.underNotch.map(\.displayName))
        check(notchNames == ["Parallels Desktop", "ScreenTab", "Happ", "OpenVPN Connect", "iStat Menus"],
              "под вырезом: Parallels, ScreenTab, Happ, OpenVPN, iStat (датчики)", "\(notchNames.sorted())")
        check(inv.underNotch.allSatisfy(\.hiddenByNotch), "hiddenByNotch у значков под вырезом")
        check(inv.visible.count == 17, "видно 17", "\(inv.visible.count)")
        check(inv.visible.first?.displayName == "Часы", "первый справа — часы", inv.visible.first?.displayName ?? "-")
        let byName = Dictionary(inv.items.map { ($0.displayName, $0) }, uniquingKeysWith: { a, _ in a })
        check(byName["Wi-Fi"]?.isSystem == true && byName["Wi-Fi"]?.isMovable == true, "Wi-Fi — системный, двигается")
        check(byName["Часы"]?.isMovable == false && byName["Пункт управления"]?.isMovable == false, "часы и Пункт управления не двигаются")
        check(byName["Раскладка"]?.kind == .system("TextInput"), "раскладка — системный TextInput")
        check(byName["Spotlight"]?.isSystem == true, "Spotlight — системный")
        check(byName["Ollama"]?.canQuit == true && byName["Ollama"]?.isSystem == false, "Ollama — приложение, можно выйти")
        check(byName["iStat Menus"] != nil, "«iStat Menus Status» → «iStat Menus»")
        check(Set(inv.items.map(\.key)).count == inv.items.count, "ключи уникальны")
        check(byName["Wi-Fi"]?.key == "com.apple.controlcenter|WiFi", "ключ Wi-Fi", byName["Wi-Fi"]?.key ?? "-")
    }

    static func inventoryWithoutNames() {
        print("— инвентарь без имён окон (нет «Записи экрана»)")
        let anon = fixture.map { var x = $0; x.name = nil; return x }
        let inv = MenuBarInventory.parse(MenuBarScanInput(windows: anon, apps: apps, ownPID: ownPID, notch: notch))
        check(inv.ghosts == 3, "призраки найдены по наложению рамок без имён", "\(inv.ghosts)")
        check(inv.underNotch.count == 5, "под вырезом те же 5", "\(inv.underNotch.count)")
        check(Set(inv.items.map(\.key)).count == inv.items.count, "ключи уникальны и без имён (порядковые номера)")
        let cc = inv.items.filter { if case .controlCenter = $0.kind { return true }; return false }
        check(cc.count == 6 && cc.allSatisfy { $0.displayName == "Пункт управления" },
              "модули Пункта управления без имени — «Пункт управления»", "\(cc.count)")
        check(cc.allSatisfy(\.isMovable), "без имени модуля значок не считается неподвижным (не знаем, что это часы)")
        // Ключи без «Записи экрана» (п. 2): у OpenVPN два значка → «#0/#1» меняются при переносе — восстановление их не
        // трогает; у Ollama значок один — «#0» устойчив.
        let vpn = inv.items.filter { $0.ownerName == "OpenVPN Connect" }
        let ollama = inv.items.first { $0.ownerName == "Ollama" }
        check(vpn.count == 2 && vpn.allSatisfy { !$0.hasStableKey } && ollama?.hasStableKey == true,
              "двухзначковое приложение без имён — ключи неустойчивы, однозначковое — устойчив")
        var vp = MenuBarPrefs()
        for v in vpn { vp.set(v.key, .island) }
        if let o = ollama { vp.set(o.key, .island) }
        let rv = MenuBarPlanner.reconcile(inv, vp)
        check(rv.moves.map(\.key) == [ollama?.key ?? "-"], "спрятали #0 у OpenVPN → reconcile его не двигает, Ollama — двигает",
              "\(rv.moves.map(\.key))")
        let withAX = MenuBarInventory.parse(MenuBarScanInput(windows: anon, apps: apps, ownPID: ownPID, ax: [
            MenuBarAXInfo(pid: 2446, frame: CGRect(x: 1264, y: 0, width: 16, height: 37), title: nil, detail: "OpenVPN Connect", identifier: nil),
            MenuBarAXInfo(pid: 2446, frame: CGRect(x: 909, y: 0, width: 32, height: 37), title: nil, detail: "Статус 3", identifier: "vpn.status"),
        ], notch: notch))
        let vpn2 = withAX.items.filter { $0.ownerName == "OpenVPN Connect" }.map(\.key).sorted()
        let vpnItems = withAX.items.filter { $0.ownerName == "OpenVPN Connect" }
        check(vpn2 == ["org.openvpn.client.app|#0", "org.openvpn.client.app|vpn.status"]
              && vpnItems.first { $0.key.hasSuffix("vpn.status") }?.hasStableKey == true
              && vpnItems.first { $0.key.hasSuffix("#0") }?.hasStableKey == false,
              "ключ из AX — только идентификатор; описание (меняется с состоянием) — нет, такой значок неустойчив", "\(vpn2)")
    }

    static func sections() {
        print("— разделы относительно разделителя")
        var win = fixture.filter { $0.windowID != 30 && $0.windowID != 28350 && $0.windowID != 37619 }
        // Разделитель развёрнут: правый край — у левого края Vafa (1064), длина 10000. Ollama, Claude, Telegram — левее.
        win.append(MenuBarRawWindow(windowID: 9002, pid: ownPID, ownerName: "SimpleIsland", name: "Item-1",
                                    frame: CGRect(x: 1064 - 10000, y: 0, width: 10000, height: 37), onScreen: false))
        win.append(w("Ollama", 965, -8969, 33, "Item-0", false, 30))
        win.append(w("Claude", 80920, -9009, 40, "Item-0", false, 28350))
        win.append(w("Telegram", 36713, -9049, 40, "Item-0", false, 37619))
        // Призрак левее разделителя не ищем: рамка как у Claude, но это спрятанный значок.
        let inv = MenuBarInventory.parse(MenuBarScanInput(windows: win, apps: apps, ownPID: ownPID, dividerWindowID: 9002,
                                                          ccVisibility: ccVisibility, notch: notch))
        check(inv.dividerFrame != nil, "рамка разделителя найдена")
        check(Set(inv.inIslandSection.map(\.displayName)) == ["Ollama", "Claude", "Telegram"],
              "левее разделителя: Ollama, Claude, Telegram", "\(inv.inIslandSection.map(\.displayName))")
        check(inv.underNotch.count == 5, "под вырезом — правее разделителя, но не на экране: 5", "\(inv.underNotch.count)")
        check(inv.items.count == 22, "всего 22", "\(inv.items.count)")
        sectionInv = inv
    }

    static var sectionInv = MenuBarInventory.empty

    /// Тот же снимок с разделителем, но Ollama, Claude, Telegram ещё видны (правее разделителя).
    static func beforeInv() -> MenuBarInventory {
        var win = fixture
        win.append(MenuBarRawWindow(windowID: 9002, pid: ownPID, ownerName: "SimpleIsland", name: "Item-1",
                                    frame: CGRect(x: 980 - 10000, y: 0, width: 10000, height: 37), onScreen: false))
        return MenuBarInventory.parse(MenuBarScanInput(windows: win, apps: apps, ownPID: ownPID, dividerWindowID: 9002,
                                                       ccVisibility: ccVisibility, notch: notch))
    }

    /// Копии окон на другом экране: сдвиг по x, своя высота строки, без имён (как у macOS 15.5, измерено 14.11).
    static func copies(_ ws: [MenuBarRawWindow], dx: CGFloat, y: CGFloat, idBase: CGWindowID,
                       hidden: Set<CGWindowID> = []) -> [MenuBarRawWindow] {
        ws.enumerated().map { i, w in
            MenuBarRawWindow(windowID: idBase + CGWindowID(i), pid: w.pid, ownerName: w.ownerName, name: "",
                             frame: CGRect(x: w.frame.minX + dx, y: y, width: w.frame.width, height: 24),
                             onScreen: !hidden.contains(w.windowID) && w.pid != ownPID)
        }
    }

    static func multiScreen() {
        print("— несколько экранов (у каждого своя строка меню и свои копии значков)")
        // 1. Как на Маке пользователя 14.11: LG 2560×1440 над встроенным, копии на y = −1440, у выключенных модулей
        //    Пункта управления копии без имени в нуле (x = 0, y = 0).
        let main = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let above = CGRect(x: 1004, y: -1440, width: 2560, height: 1440)
        let liveOnes = fixture.filter { !($0.ownerName == "Пункт управления" && !$0.onScreen) }
        var win = fixture + copies(liveOnes, dx: 1834, y: -1440, idBase: 50_000)
        for i in 0..<3 {
            win.append(MenuBarRawWindow(windowID: 60_000 + CGWindowID(i), pid: 991, ownerName: "Пункт управления", name: "",
                                        frame: CGRect(x: 0, y: 0, width: 48, height: 24), onScreen: false))
        }
        var inv = MenuBarInventory.parse(MenuBarScanInput(windows: win, apps: apps, ownPID: ownPID,
                                                          ccVisibility: ccVisibility, notch: notch, screens: [main, above]))
        check(inv.items.count == 22 && inv.visible.count == 17 && inv.underNotch.count == 5,
              "монитор сверху: те же 22 значка (17 видно, 5 под вырезом), копии не задвоились",
              "\(inv.items.count)/\(inv.visible.count)/\(inv.underNotch.count)")
        check(inv.ghosts == 6, "призраки: 3 по defaults + 3 неразмещённые копии в нуле", "\(inv.ghosts)")
        check(inv.otherScreenCopies == liveOnes.count, "копии другого экрана пропущены: \(liveOnes.count)", "\(inv.otherScreenCopies)")
        check(inv.items.allSatisfy { $0.frame.minY == 0 }, "в списке только окна основного экрана")

        // 2. Монитор справа на той же высоте, разделитель развёрнут (3456) на обоих: Ollama, Claude, Telegram спрятаны.
        let len: CGFloat = 3456
        let hiddenIDs: Set<CGWindowID> = [30, 28350, 37619]
        func layout(dx: CGFloat, screens: [CGRect]) -> MenuBarInventory {
            var base = fixture.filter { !hiddenIDs.contains($0.windowID) }
            let div = MenuBarRawWindow(windowID: 9002, pid: ownPID, ownerName: "SimpleIsland", name: "Item-1",
                                       frame: CGRect(x: 1064 - len, y: 0, width: len, height: 37), onScreen: true)
            base.append(div)
            base.append(w("Ollama", 965, div.frame.minX - 33, 33, "Item-0", false, 30))
            base.append(w("Claude", 80920, div.frame.minX - 73, 40, "Item-0", false, 28350))
            base.append(w("Telegram", 36713, div.frame.minX - 113, 40, "Item-0", false, 37619))
            let ext = copies(base.filter { !($0.ownerName == "Пункт управления" && !$0.onScreen) },
                             dx: dx, y: 0, idBase: 70_000, hidden: hiddenIDs)
                .map { c -> MenuBarRawWindow in
                    var c = c
                    if c.pid == ownPID && c.frame.width == len { c.onScreen = true }   // копия разделителя
                    return c
                }
            return MenuBarInventory.parse(MenuBarScanInput(windows: base + ext, apps: apps, ownPID: ownPID,
                                                           dividerWindowID: 9002, ccVisibility: ccVisibility,
                                                           notch: notch, screens: screens, dividerLength: len))
        }
        inv = layout(dx: 1920, screens: [main, CGRect(x: 1728, y: 0, width: 1920, height: 1080)])
        check(Set(inv.inIslandSection.map(\.displayName)) == ["Ollama", "Claude", "Telegram"] && inv.items.count == 22,
              "монитор справа: за разделителем ровно 3, всего 22", "\(inv.inIslandSection.map(\.displayName)) \(inv.items.count)")
        check(inv.dividerFrame?.minX == 1064 - len, "разделитель — копия основного экрана")
        // 3. Монитор слева (x < 0): спрятанные копии основного экрана по x попадают в ширину левого монитора.
        inv = layout(dx: -1730, screens: [main, CGRect(x: -2560, y: 0, width: 2560, height: 1440)])
        check(Set(inv.inIslandSection.map(\.displayName)) == ["Ollama", "Claude", "Telegram"] && inv.items.count == 22
              && inv.visible.count == 14,
              "монитор слева: спрятанные не перепутаны с копиями левого экрана",
              "\(inv.inIslandSection.map(\.displayName)) \(inv.items.count) \(inv.visible.count)")
    }

    // MARK: Назначение и восстановление

    static func planning() {
        print("— назначение разделам и восстановление")
        let inv = sectionInv
        guard let ollama = inv.items.first(where: { $0.displayName == "Ollama" }),
              let claude = inv.items.first(where: { $0.displayName == "Claude" }),
              let vafa = inv.items.first(where: { $0.displayName == "Vafa" }),
              let telegram = inv.items.first(where: { $0.displayName == "Telegram" }),
              let clock = inv.items.first(where: { $0.displayName == "Часы" }),
              let happ = inv.items.first(where: { $0.displayName == "Happ" }) else {
            check(false, "значки снимка на месте"); return
        }
        var p = MenuBarPrefs()
        p.set(ollama.key, .island, name: "Ollama")
        p.set(claude.key, .hidden, name: "Claude")
        p.set(vafa.key, .island, name: "Vafa")
        p.set(happ.key, .island, name: "Happ")
        p.placements[clock.key] = .island
        var r = MenuBarPlanner.reconcile(inv, p)
        check(Set(r.moves.map(\.key)) == [vafa.key, happ.key] && r.moves.allSatisfy { $0.direction == .intoHidden },
              "восстановить: Vafa (в строке) и Happ (под вырезом) → за разделитель; часы не трогаем",
              "\(r.moves.map(\.key))")
        check(r.adopt == [telegram.key], "Telegram, ⌘-перетащенный за разделитель вручную, принят «в остров»", "\(r.adopt)")
        p.set(vafa.key, .island, remember: false)
        r = MenuBarPlanner.reconcile(inv, p)
        check(!r.moves.contains { $0.key == vafa.key }, "снята галочка «Помнить» — Vafa не возвращаем")
        let island = MenuBarPlanner.islandItems(inv, p)
        check(island.contains { $0.key == ollama.key } && !island.contains { $0.key == claude.key },
              "во вкладке: Ollama есть, Claude («спрятан совсем») нет")
        check(island.filter { $0.section == .notch }.count == 5, "во вкладке и 5 из-под выреза")
        check(MenuBarPlanner.hiddenCount(p) == 1, "спрятано совсем: 1")
        p.set(ollama.key, .bar)
        check(p.placements[ollama.key] == nil, "«в строке» — запись убрана")
        check(p.needsDivider, "что-то спрятано — разделитель нужен")
        p.resetPlacements()
        check(!p.needsDivider && p.placements.isEmpty && p.noRestore.isEmpty, "«Вернуть всё» — назначений нет")

        let base = MenuBarInventory.parse(MenuBarScanInput(windows: fixture, apps: apps, ownPID: ownPID,
                                                           ccVisibility: ccVisibility))
        let pos = MenuBarPlanner.dividerPreferredPosition(base, screenMaxX: 1728)
        check(pos == 749, "новый разделитель — у левого края видимых (iStat, x=980): 1728 − 980 + 1 = 749", "\(pos ?? -1)")
    }

    static func geometry() {
        print("— разделитель и точка броска")
        check(MenuBarDividerMath.expandedLength(screenWidths: [1728]) == 3456, "длина: 2 × 1728 = 3456")
        check(MenuBarDividerMath.expandedLength(screenWidths: [5120, 1728]) == 10000, "длина не больше 10000")
        check(MenuBarDividerMath.expandedLength(screenWidths: []) == 500, "без экранов — 500")
        let item = CGRect(x: 1231, y: 0, width: 33, height: 37), div = CGRect(x: 1180, y: 0, width: 12, height: 37)
        let p1 = MenuBarMover.destination(item: item, target: div, side: .leftOf)
        check(p1.x == 1180 + 4 + 33, "левее разделителя: значок правее — поправка на его ширину", "\(p1.x)")
        let p2 = MenuBarMover.destination(item: CGRect(x: -9000, y: 0, width: 33, height: 37), target: div, side: .rightOf)
        check(p2.x == 1192 - 4 && p2.y == 18.5, "правее разделителя: значок левее — без поправки", "\(p2)")
    }

    // MARK: Временный показ, способы переноса, тексты неудач (15.11.2026)

    static func testItem(_ name: String, x: CGFloat, w: CGFloat, section: MenuBarSection, wid: CGWindowID,
                         kind: MenuBarItemKind = .app) -> MenuBarItem {
        MenuBarItem(windowID: wid, pid: 4000 + pid_t(wid), ownerName: name, bundleId: "t.\(name)", windowName: "Item-0",
                    frame: CGRect(x: x, y: 0, width: w, height: 37), onScreen: section == .visible, kind: kind,
                    key: "t.\(name)|Item-0", displayName: name, axTitle: nil, section: section)
    }

    /// Куда ставить значок при временном показе (без сворачивания разделителя): живой случай пользователя 15.11 —
    /// MacBook 16", вырез 771…956, видимые от x=1133, eqMac за разделителем.
    static func showPlanning() {
        print("— временный показ: левее какого значка ставить")
        let clock = testItem("Clock", x: 1584, w: 146, section: .visible, wid: 1, kind: .controlCenter(module: "Clock"))
        let cc = testItem("CC", x: 1550, w: 34, section: .visible, wid: 2, kind: .controlCenter(module: "BentoBox"))
        let wifi = testItem("WiFi", x: 1480, w: 38, section: .visible, wid: 3, kind: .controlCenter(module: "WiFi"))
        let vafa = testItem("Vafa", x: 1178, w: 30, section: .visible, wid: 4)
        let istat = testItem("iStat", x: 1133, w: 45, section: .visible, wid: 5)
        let eq = testItem("eqMac", x: -2614, w: 38, section: .island, wid: 6)
        let notchHidden = testItem("Happ", x: 900, w: 38, section: .notch, wid: 7)
        let inv = MenuBarInventory(items: [clock, cc, wifi, vafa, istat, eq, notchHidden], dividerFrame: nil, ghosts: 0)
        let t1 = MenuBarPlanner.showTarget(for: eq, in: inv, leftLimit: 956)
        check(t1?.displayName == "iStat", "есть место справа от выреза — левее самого левого видимого (iStat): 1133 − 38 ≥ 958",
              t1?.displayName ?? "nil")
        let t2 = MenuBarPlanner.showTarget(for: eq, in: inv, leftLimit: 1130)
        check(t2?.displayName == "Vafa", "у самого левого места нет — следующий подходящий (Vafa)", t2?.displayName ?? "nil")
        let t3 = MenuBarPlanner.showTarget(for: eq, in: inv, leftLimit: 1600)
        check(t3?.displayName == "WiFi", "строка забита — самый правый подвижный (часы и Пункт управления не двигаются)",
              t3?.displayName ?? "nil")
        let t4 = MenuBarPlanner.showTarget(for: notchHidden, in: inv, leftLimit: 956)
        check(t4?.displayName == "iStat", "значок под вырезом — тоже в видимую часть, без разделителя", t4?.displayName ?? "nil")
        let t5 = MenuBarPlanner.showTarget(for: eq, in: inv, leftLimit: nil)
        check(t5?.displayName == "iStat", "экран без выреза — левее самого левого видимого", t5?.displayName ?? "nil")
        let only = MenuBarInventory(items: [clock, cc, eq], dividerFrame: nil, ghosts: 0)
        check(MenuBarPlanner.showTarget(for: eq, in: only, leftLimit: 956) == nil, "видны только часы и Пункт управления — цели нет")
    }

    /// Способ `.offscreen` (как у Ice): нажатие вне экранов с ⌘ и номером окна значка, отпускание у цели без ⌘ с номером
    /// окна цели; на время событий наши окна пропускают мышь; причины отказа.
    static func moverStyles() {
        print("— перенос: нажатие вне экрана, свои окна пропускают мышь, причины отказа")
        let mv = MenuBarMover()
        var events: [CGEvent] = []
        var guardDuring: [Bool] = []
        mv.testSink = { events.append($0); guardDuring.append(SyntheticMouse.isActive) }
        mv.testIdle = { true }
        let item = CGRect(x: 900, y: 0, width: 38, height: 37)       // под вырезом — где остров
        let target = CGRect(x: 1133, y: 0, width: 45, height: 37)
        var r: Bool?
        mv.drag(itemWindow: 30, pid: 965, item: item, targetWindow: 9002, target: target, side: .leftOf) { r = $0 }
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        check(r == true && events.map(\.type) == [.leftMouseDown, .leftMouseUp], "по умолчанию — 2 события: нажатие и отпускание",
              "\(events.map(\.type.rawValue))")
        if events.count == 2 {
            let d = events[0], u = events[1]
            check(d.location == MenuBarMover.offscreenPoint && d.flags.contains(.maskCommand)
                  && d.getIntegerValueField(.mouseEventWindowUnderMousePointer) == 30
                  && d.getIntegerValueField(.eventTargetUnixProcessID) == 965,
                  "нажатие: вне экранов (20000, 20000), с ⌘, номер окна значка, pid владельца", "\(d.location)")
            check(u.location == CGPoint(x: 1133, y: 18.5) && !u.flags.contains(.maskCommand)
                  && u.getIntegerValueField(.mouseEventWindowUnderMousePointer) == 9002,
                  "отпускание: левый край цели, без ⌘, номер окна цели", "\(u.location)")
        }
        check(guardDuring == [true, true] && !SyntheticMouse.isActive && SyntheticMouse.guardedCount == 0,
              "пока идут события, наши окна пропускают мышь; после — как было", "\(guardDuring)")
        check(MenuBarMover.destination(item: item, target: target, side: .rightOf, style: .offscreen).x == 1178,
              "правее цели — её правый край")
        check(mv.lastFailure == nil, "удача — причины отказа нет")

        // Причины отказа.
        let busy = MenuBarMover()
        busy.testSink = { _ in }
        busy.testIdle = { true }
        var rb: Bool?
        busy.drag(itemWindow: 1, pid: 1, item: item, targetWindow: 2, target: target, side: .leftOf) { _ in }
        busy.drag(itemWindow: 1, pid: 1, item: item, targetWindow: 2, target: target, side: .leftOf) { rb = $0 }
        check(rb == false && busy.lastFailure == .busy, "второй перенос, пока идёт первый, — отказ «занят»")
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        let noAX = MenuBarMover()       // dryRun и без приёмника — как без Универсального доступа
        var rn: Bool?
        noAX.drag(itemWindow: 1, pid: 1, item: item, targetWindow: 2, target: target, side: .leftOf) { rn = $0 }
        check(rn == false && noAX.lastFailure == .noAccess, "без права — отказ «нет Универсального доступа», событий нет")
        let held = MenuBarMover()
        held.testSink = { _ in }
        held.testIdle = { false }        // ⌘ зажат всё время
        var rh: Bool?
        held.drag(itemWindow: 1, pid: 1, item: item, targetWindow: 2, target: target, side: .leftOf) { rh = $0 }
        RunLoop.main.run(until: Date().addingTimeInterval(3.4))
        check(rh == false && held.lastFailure == .inputBusy, "зажатые клавиши так и не отпустили — отказ «ввод занят»",
              "\(String(describing: rh)) \(String(describing: held.lastFailure))")
    }

    static func failureTexts() {
        print("— тексты неудач переноса")
        let t1 = MenuBarModel.moveFailureText(name: "eqMac", verb: "показать", failure: .noAccess, sent: false,
                                              isSystem: false, canSettings: false) ?? ""
        check(t1.contains("Универсального доступа") && t1.contains("Конфиденциальность"),
              "нет права — сказано, какого, и где включить", t1)
        let t2 = MenuBarModel.moveFailureText(name: "Wi-Fi", verb: "перенести", failure: nil, sent: true,
                                              isSystem: true, canSettings: true) ?? ""
        check(t2.contains("Пункте управления"), "системный не сдвинулся — путь через Пункт управления", t2)
        let t3 = MenuBarModel.moveFailureText(name: "eqMac", verb: "показать", failure: .inputBusy, sent: false,
                                              isSystem: false, canSettings: false) ?? ""
        check(t3.contains("зажаты"), "зажатые клавиши — так и сказано", t3)
        check(MenuBarModel.moveFailureText(name: "x", verb: "показать", failure: .cancelled, sent: false,
                                           isSystem: false, canSettings: false) == nil, "сброс пользователем — без сообщения")
        let m = MenuBarModel()
        m.testNotifications = []
        let wifi = testItem("Wi-Fi", x: 1480, w: 38, section: .visible, wid: 3, kind: .controlCenter(module: "WiFi"))
        m.reportMoveFailure(name: "Wi-Fi", verb: "перенести", item: wifi, sent: true)
        let n = m.testNotifications?.first
        check(n?.actions.first?.title == "Открыть Пункт управления",
              "системный не сдвинулся — уведомление с кнопкой «Открыть Пункт управления» (сами настройки не трогаем)",
              n?.actions.first?.title ?? "нет уведомления")
        let clock = testItem("Часы", x: 1584, w: 146, section: .visible, wid: 1, kind: .controlCenter(module: "Clock"))
        let card = CleanupCard.make(for: clock, axGranted: true)
        check(card.options == [.systemSettings(.controlCenter)], "часы — только «Пункт управления»")
        let av = testItem("AV", x: 1300, w: 30, section: .visible, wid: 9, kind: .controlCenter(module: "AudioVideoModule"))
        let avCard = CleanupCard.make(for: av, axGranted: true)
        check(!avCard.options.contains(.toIsland) && !avCard.options.contains(.hide) && avCard.note != nil,
              "индикатор камеры/микрофона macOS не даёт прятать — ни «в остров», ни «спрятать», с пояснением",
              "\(avCard.options)")
        let wifiCard = CleanupCard.make(for: wifi, axGranted: true)
        check(wifiCard.options.first == .toIsland && wifiCard.options.contains(.systemSettings(.controlCenter))
              && wifiCard.options.contains(.hide), "Wi‑Fi: в остров / выключить в Пункте управления / спрятать")
    }

    // MARK: Настройки

    static func prefs() {
        print("— настройки")
        var p = MenuBarPrefs()
        p.set("a|0", .island, name: "A")
        p.set("b|0", .hidden, name: "B", remember: false)
        p.showStack = true
        p.hotKey = HotKeySpec(keyCode: 45, modifiers: 0x1000 | 0x0100, keyLabel: "N")
        let settings = SimpleIslandSettings(inMemory: SettingsData())
        settings.setModuleValue(p, for: MenuBarIslandModule.moduleId)
        let back = settings.moduleValue(MenuBarPrefs.self, for: MenuBarIslandModule.moduleId)
        check(back == p, "сохранение и чтение через settings.json → moduleSettings", "\(String(describing: back))")
        let partial = #"{"showStack": true}"#.data(using: .utf8)!
        let d1 = try? JSONDecoder().decode(MenuBarPrefs.self, from: partial)
        check(d1?.showStack == true && d1?.hotKeyEnabled == true && d1?.hotKey == MenuBarPrefs.defaultHotKey && d1?.restoreOnLaunch == true,
              "частичный JSON: остальное по умолчанию")
        let odd = #"{"placements": {"x|0": "island", "y|0": "plasma"}, "hotKey": 5, "realIcons": "да"}"#.data(using: .utf8)!
        let d2 = try? JSONDecoder().decode(MenuBarPrefs.self, from: odd)
        check(d2?.placements == ["x|0": .island] && d2?.hotKey == MenuBarPrefs.defaultHotKey && d2?.realIcons == false,
              "испорченные поля не ломают остальное", "\(String(describing: d2))")
        check(MenuBarPrefs().hotKey.displayString == "⌃⌥B", "горячая клавиша по умолчанию ⌃⌥B")
        check(MenuBarPrefs().realIcons == false, "«Запись экрана» по умолчанию не нужна")
    }

    // MARK: Карточка и клавиши

    static func item(_ name: String, _ kind: MenuBarItemKind, section: MenuBarSection = .visible) -> MenuBarItem {
        MenuBarItem(windowID: 1, pid: 1, ownerName: name, bundleId: nil, windowName: nil,
                    frame: CGRect(x: 0, y: 0, width: 30, height: 37), onScreen: section == .visible, kind: kind,
                    key: name, displayName: name, axTitle: nil, section: section)
    }

    static func cards() {
        print("— карточка подтверждения")
        let app = CleanupCard.make(for: item("Ollama", .app), axGranted: true)
        check(app.options == [.toIsland, .hide, .quit], "приложение: в остров / спрятать / выйти", "\(app.options)")
        check(app.options.first == .toIsland, "по умолчанию (⏎) — «Убрать в остров»")
        check(app.showsRemember && app.title == "Ollama — что сделать?", "галочка «Помнить…» и заголовок")
        let wifi = CleanupCard.make(for: item("Wi-Fi", .controlCenter(module: "WiFi")), axGranted: true)
        check(wifi.options == [.toIsland, .systemSettings(.controlCenter), .hide], "Wi-Fi: в остров / выключить в Пункте управления / спрятать",
              "\(wifi.options)")
        check(!wifi.options.contains(.quit) && !wifi.showsRemember, "системный: без «Выйти» и без галочки")
        check(wifi.subtitle == "системный значок macOS", "подпись системного")
        let clock = CleanupCard.make(for: item("Часы", .controlCenter(module: "Clock")), axGranted: true)
        check(clock.options == [.systemSettings(.controlCenter)] && clock.note != nil, "часы: только настройки и пояснение")
        let input = CleanupCard.make(for: item("Раскладка", .system("TextInput")), axGranted: true)
        check(input.options.contains(.systemSettings(.keyboard)), "раскладка: выключить в настройках клавиатуры")
        let noAX = CleanupCard.make(for: item("Ollama", .app), axGranted: false)
        check(noAX.details.first == "нужен Универсальный доступ" && noAX.options.count == 3,
              "без Универсального доступа: варианты те же, с пометкой")
        let notch = CleanupCard.make(for: item("Happ", .app, section: .notch), axGranted: true)
        check(notch.subtitle.contains("под вырезом"), "значок под вырезом — так и написано")
    }

    static func keys() {
        print("— клавиши режима уборки")
        let order = ["Vafa", "Ollama", "Wi-Fi"]
        let cards: [String: CleanupCard] = [
            "Vafa": CleanupCard.make(for: item("Vafa", .app), axGranted: true),
            "Ollama": CleanupCard.make(for: item("Ollama", .app), axGranted: true),
            "Wi-Fi": CleanupCard.make(for: item("Wi-Fi", .controlCenter(module: "WiFi")), axGranted: true),
        ]
        let card: (String) -> CleanupCard? = { cards[$0] }
        var st = CleanupState()
        check(CleanupKeys.key(forKeyCode: 36) == .enter && CleanupKeys.key(forKeyCode: 76) == .enter
              && CleanupKeys.key(forKeyCode: 53) == .escape && CleanupKeys.key(forKeyCode: 125) == .down
              && CleanupKeys.key(forKeyCode: 0) == nil, "коды клавиш: ⏎, Enter, Esc, ↓; «A» — не наша")
        _ = CleanupKeys.handle(.right, state: &st, order: order, card: card)
        check(st.hoveredKey == "Vafa", "→ без карточки — первый значок")
        _ = CleanupKeys.handle(.right, state: &st, order: order, card: card)
        check(st.hoveredKey == "Ollama", "→ ещё раз — следующий")
        _ = CleanupKeys.handle(.enter, state: &st, order: order, card: card)
        check(st.selectedKey == "Ollama" && st.optionIndex == 0, "⏎ — карточка для значка под курсором")
        var cmd = CleanupKeys.handle(.enter, state: &st, order: order, card: card)
        check(cmd == .perform(key: "Ollama", option: .toIsland, remember: true), "⏎ в карточке — «Убрать в остров»", "\(cmd)")
        CleanupKeys.click("Ollama", state: &st)
        _ = CleanupKeys.handle(.up, state: &st, order: order, card: card)
        check(st.optionIndex == 0, "↑ на первом — остаётся")
        for _ in 0..<5 { _ = CleanupKeys.handle(.down, state: &st, order: order, card: card) }
        check(st.optionIndex == 2, "↓ упирается в последний (Выйти)", "\(st.optionIndex)")
        _ = CleanupKeys.handle(.space, state: &st, order: order, card: card)
        check(st.remember == false, "Space — снять «Помнить»")
        cmd = CleanupKeys.handle(.enter, state: &st, order: order, card: card)
        check(cmd == .none && st.confirmingQuit, "⏎ на «Выйти» — сначала уточнение")
        cmd = CleanupKeys.handle(.escape, state: &st, order: order, card: card)
        check(cmd == .none && !st.confirmingQuit && st.selectedKey == "Ollama", "Esc в уточнении — назад к вариантам")
        _ = CleanupKeys.handle(.enter, state: &st, order: order, card: card)
        cmd = CleanupKeys.handle(.enter, state: &st, order: order, card: card)
        check(cmd == .perform(key: "Ollama", option: .quit, remember: false), "⏎ ⏎ — выйти из приложения", "\(cmd)")
        CleanupKeys.click("Ollama", state: &st)
        _ = CleanupKeys.handle(.right, state: &st, order: order, card: card)
        check(st.selectedKey == "Wi-Fi" && st.optionIndex == 0, "→ в карточке — карточка соседнего значка")
        _ = CleanupKeys.handle(.tab, state: &st, order: order, card: card)
        check(st.optionIndex == 1, "Tab — следующий вариант")
        cmd = CleanupKeys.handle(.escape, state: &st, order: order, card: card)
        check(cmd == .none && st.selectedKey == nil, "Esc — карточка закрыта, режим остаётся")
        cmd = CleanupKeys.handle(.escape, state: &st, order: order, card: card)
        check(cmd == .exit, "Esc ещё раз — выход из режима")
        CleanupKeys.click("Vafa", state: &st)
        CleanupKeys.click("Vafa", state: &st)
        check(st.selectedKey == nil, "второй щелчок по тому же значку — закрыть карточку")
    }

    static func hotKey() {
        print("— горячая клавиша")
        check(MenuBarHotKey.spec(keyCode: 11, flags: [.control, .option]) == MenuBarPrefs.defaultHotKey, "⌃⌥ + B → ⌃⌥B")
        check(MenuBarHotKey.spec(keyCode: 11, flags: []) == nil, "без модификаторов не записывается")
        check(MenuBarHotKey.spec(keyCode: 11, flags: [.shift]) == nil, "⇧B не записывается — нужен ⌘, ⌃ или ⌥")
        check(MenuBarHotKey.spec(keyCode: 11, flags: [.command, .shift]) != nil, "⌘⇧B записывается")
        check([1, 2, 5, 11, 21, 22, 112].map(MenuBarText.icons)
              == ["1 значок", "2 значка", "5 значков", "11 значков", "21 значок", "22 значка", "112 значков"],
              "склонение: 1 значок, 2 значка, 5 значков, 11 значков, 21 значок")
        check(MenuBarHotKey.label(keyCode: 11) == "B" && MenuBarHotKey.label(keyCode: 49) == "Space", "подписи клавиш по латинице")
    }

    // MARK: Модуль

    static func moduleLifecycle() {
        print("— модуль: включение, выход, «Вернуть всё» (разделитель — dryRun, в строку меню ничего не ставится)")
        var data = SettingsData()
        var p = MenuBarPrefs()
        p.hotKeyEnabled = false
        p.restoreOnLaunch = false
        p.placements = ["test.app|0": .island]
        let settings = SimpleIslandSettings(inMemory: data)
        settings.setModuleValue(p, for: MenuBarIslandModule.moduleId)
        data = settings.data
        let ctx = ModuleContext(moduleId: MenuBarIslandModule.moduleId, settings: settings, themes: ThemeStore(load: false),
                                activities: ActivityCenter(), hud: HUDCenter(), notifications: IslandNotifications(),
                                island: IslandStateCenter(), openTab: { _ in })
        let mod = MenuBarIslandModule()
        check(mod.tabEnabledByDefault && mod.id == "menubar" && mod.title == "Значки", "id menubar, вкладка «Значки», включена по умолчанию")
        mod.start(context: ctx)
        check(StatusMenuItems.shared.entries.contains { $0.moduleId == "menubar" && $0.title == "Уборка строки меню…" },
              "пункт «Уборка строки меню…» в меню значка")
        check(mod.model.divider.exists && mod.model.divider.isExpanded, "что-то спрятано — разделитель есть и развёрнут")
        check(MenuBarHotKey.shared.registered == nil, "горячая клавиша выключена в настройках — не зарегистрирована")
        // «Усыновление» и новые значки (ревью п. 3): за разделителем без записи — только то, что перешло туда из
        // видимых при свёрнутом разделителе в окне ручного переноса; иначе — сообщение, не запись.
        let m = mod.model
        m.testNotifications = []
        let before = beforeInv()
        m.apply(before)                       // первый скан — точка отсчёта
        m.apply(sectionInv)                   // Ollama, Claude, Telegram «сами» оказались за развёрнутым разделителем
        check(m.prefs.placements.count == 1, "развёрнутый разделитель: значки за ним не записываются сами",
              "\(m.prefs.placements)")
        check(m.testNotifications?.count == 1 && m.testNotifications?.first?.actions.first?.title == "Вернуть в строку",
              "о значках, оказавшихся за разделителем, — сообщение с «Вернуть в строку»",
              "\(m.testNotifications?.map(\.body) ?? [])")
        m.apply(before); m.apply(sectionInv)
        check(m.testNotifications?.count == 1, "одно и то же сообщение второй раз не показывается")
        m.manualUntil = Date().addingTimeInterval(30)
        m.divider.collapse()
        m.apply(before); m.apply(sectionInv)
        check(m.prefs.placements.count == 4, "окно ручного переноса, черта видна: перетащенные за неё — «в остров»",
              "\(m.prefs.placements.count)")
        m.manualUntil = nil
        // Автовосстановление (25.11): назначенное «в остров» и выскочившее в строку возвращается молча, без
        // уведомления; где снята «Помнить место» (noRestore) — не трогается и не предлагается.
        m.prefs.placements = ["test.app|0": .island, "local.vafa|Item-0": .island]
        m.prefs.noRestore = ["local.vafa|Item-0"]
        m.testNotifications = []
        let offered = m.offerRestore(sectionInv, reason: "самотест")
        check(!offered && (m.testNotifications ?? []).isEmpty,
              "снята «Помнить место» — выскочивший значок не трогается и не предлагается",
              "\(m.testNotifications?.map(\.title) ?? [])")
        m.prefs.noRestore = []
        check(m.offerRestore(sectionInv, reason: "самотест") && (m.testNotifications ?? []).isEmpty,
              "назначен «в остров» и выскочил — возвращается молча, без уведомления")
        // «Помнить после перезапуска» снята (п. 12): после выхода приложения назначение забывается.
        m.prefs.set("ru.keepcoder.Telegram|Item-0", .island, name: "Telegram", remember: false)
        m.appsChanged(launched: false, bundleId: "ru.keepcoder.Telegram")
        check(m.prefs.placements["ru.keepcoder.Telegram|Item-0"] == nil && m.prefs.placements["local.vafa|Item-0"] == .island,
              "галочка снята: Telegram вышел — назначение забыто, остальные на месте")
        m.testNotifications = nil
        mod.model.prefs.placements = ["test.app|0": .island]
        mod.model.divider.expand()
        mod.model.prefs.showStack = true
        check(ctx.settings.moduleValue(MenuBarPrefs.self, for: "menubar")?.showStack == true, "смена настроек сохраняется")
        // «Вернуть всё» посреди переноса и временного показа (п. 1): отложенные шаги не воскрешают разделитель.
        var completed = false
        mod.model.inventory = sectionInv
        mod.model.tempShown = .init(key: "local.vafa|Item-0", windowID: 37601, pid: 99_998, sawMenu: true,
                                    since: Date().addingTimeInterval(-30), baseline: [])
        mod.model.manualUntil = Date().addingTimeInterval(30)
        mod.model.moveIntoHidden(key: "local.vafa|Item-0", allowCreate: true) { _ in completed = true }
        mod.model.resetAll()
        check(!mod.model.divider.exists && mod.model.prefs.placements.isEmpty, "«Вернуть всё»: разделителя нет, назначений нет")
        check(mod.model.tempShown == nil && mod.model.manualUntil == nil && mod.model.tick == nil,
              "«Вернуть всё» сбросил временный показ, окно ручного переноса и тикер")
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        mod.model.onTick()
        check(!mod.model.divider.exists && !completed && mod.model.prefs.placements.isEmpty,
              "отложенный перенос после «Вернуть всё» молча оборвался: разделитель не пересоздан, ничего не записано")
        // Временный показ закончился, а разделителя уже нет: спрятать обратно некуда — не создаём.
        mod.model.tempShown = .init(key: "local.vafa|Item-0", windowID: 37601, pid: 99_998, sawMenu: true,
                                    since: Date().addingTimeInterval(-30), baseline: [])
        mod.model.onTick()
        var second: Bool?
        mod.model.moveIntoHidden(key: "local.vafa|Item-0", attempt: 2) { second = $0 }
        check(!mod.model.divider.exists && second == false, "повтор переноса и конец временного показа разделитель не создают")
        mod.model.tempShown = nil
        // Автоповтор ⏎ не проскакивает «Выйти из …?» (п. 4).
        let km = MenuBarModel()
        km.inventory = MenuBarMocks.barInventory(width: 1500)
        km.axGranted = true
        CleanupKeys.click("ollama|0", state: &km.cleanup)
        km.cleanup.optionIndex = 2
        _ = km.handleKey(36)
        _ = km.handleKey(36, isRepeat: true)
        _ = km.handleKey(36, isRepeat: true)
        check(km.cleanup.confirmingQuit && km.cleanup.selectedKey == "ollama|0", "зажатый ⏎: уточнение «Выйти» осталось, выхода нет")
        _ = km.handleKey(125, isRepeat: true)
        check(km.cleanup.confirmingQuit, "в уточнении стрелки ничего не делают")
        recheckFixes(mod.model)
        mod.model.prefs.placements = ["test.app|0": .hidden]
        mod.model.divider.ensure(preferredPosition: nil); mod.model.divider.expand()
        // --- shelfbar --- режим уборки держит остров в покое (ровно вырез), выход — отпускает. Без прокрутки цикла
        // между входом и выходом: оверлей ставится после скана и при выходе до него не показывается.
        m.startCleanup()
        check(m.cleanupActive && ctx.island.collapseHolds == ["menubar.\(MenuBarModel.cleanupHoldToken)"],
              "уборка: остров удержан в покое (holdCollapsed)", "\(ctx.island.collapseHolds)")
        m.exitCleanup()
        check(!m.cleanupActive && !ctx.island.isCollapseHeld, "выход из уборки — удержание снято")
        ctx.holdCollapsed(MenuBarModel.cleanupHoldToken)   // как будто выключили модуль посреди уборки
        // --- /shelfbar ---
        // Выключили модуль во вкладках — разделитель убран, всё видно.
        if let i = settings.data.tabs.firstIndex(where: { $0.id == "menubar" }) { settings.data.tabs[i].enabled = false }
        else { settings.data.tabs.append(TabSetting(id: "menubar", enabled: false)) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        check(!mod.model.divider.exists, "модуль выключен — разделитель убран (значки не теряются)")
        check(!ctx.island.isCollapseHeld, "модуль выключен — остров не остаётся в покое")   // --- shelfbar ---
        check(!StatusMenuItems.shared.entries.contains { $0.moduleId == "menubar" }, "модуль выключен — пункта «Уборка…» в меню нет")
        settings.data.tabs = settings.data.tabs.map { var t = $0; if t.id == "menubar" { t.enabled = true }; return t }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        check(mod.model.divider.exists && mod.model.divider.isExpanded, "модуль снова включён — разделитель на месте и развёрнут")
        mod.stop()
        check(!mod.model.divider.isExpanded && !StatusMenuItems.shared.entries.contains { $0.moduleId == "menubar" },
              "stop (выход приложения): разделитель свёрнут (значки видны, место помнится), пункт меню убран")
        check(ctx.activities.activities.isEmpty, "своих активностей после остановки нет")
    }

    // --- shelfbar ---
    /// Плашка «Уборка · N значков» — под строкой меню, левее выреза и значков: не перекрывает ни значки, ни место
    /// под ними (подсказка у значка, карточка), не уходит за край экрана.
    static func cleanupPlate() {
        print("— плашка режима уборки: под строкой меню, левее выреза и значков")
        // 16" с вырезом: экран 1728, вырез 764…964, значки с 980.
        let notch = CGRect(x: 764, y: 0, width: 200, height: 38)
        var r = CleanupLayout.plate(screenWidth: 1728, menuBarHeight: 38, notch: notch, iconsMinX: 980)
        check(r.minY >= 38 && r.minY <= 50, "сразу под строкой меню", "\(r)")
        check(r.maxX <= notch.minX - 8 && r.minX >= 0, "левее выреза и в пределах экрана", "\(r)")
        // Значки начинаются левее выреза (вырез их прячет — правая часть забита).
        r = CleanupLayout.plate(screenWidth: 1728, menuBarHeight: 38, notch: notch, iconsMinX: 600)
        check(r.maxX <= 600 - 8 && r.minX >= 0, "значки левее выреза — плашка ещё левее", "\(r)")
        // Внешний экран без выреза.
        r = CleanupLayout.plate(screenWidth: 2560, menuBarHeight: 25, notch: nil, iconsMinX: 2100)
        check(r.maxX <= 2100 - 8 && r.minY >= 25 && r.width > 300, "без выреза — левее значков", "\(r)")
        r = CleanupLayout.plate(screenWidth: 1440, menuBarHeight: 25, notch: nil, iconsMinX: nil)
        check(r.minX >= 0 && r.maxX <= 1440, "без значков — в пределах экрана", "\(r)")
        // Значки почти от левого края — плашка не уходит за экран (сжимается до минимума).
        r = CleanupLayout.plate(screenWidth: 1440, menuBarHeight: 25, notch: nil, iconsMinX: 100)
        check(r.minX >= 0, "значков очень много — плашка в пределах экрана", "\(r)")
    }
    // --- /shelfbar ---

    // MARK: Повторная проверка ревью

    /// Модуль запущен, разделителя нет, назначений нет. Систему не трогает: перенос — в «приёмник» событий, сканы,
    /// если и запускаются, только читают.
    static func recheckFixes(_ m: MenuBarModel) {
        print("— повторная проверка: отмена переноса, исходный ключ показа, второй показ, порядок сканов, кнопки")
        // 1. Mover сверяет отмену после ожидания тишины ввода и между событиями.
        let mv = MenuBarMover()
        var sent: [CGEventType] = []
        mv.testSink = { sent.append($0.type) }
        var idle = false
        mv.testIdle = { idle }
        var cancelled = false
        var r1: Bool?
        let rect = CGRect(x: 1231, y: 0, width: 33, height: 37), div = CGRect(x: 1180, y: 0, width: 12, height: 37)
        mv.drag(itemWindow: 30, pid: 965, item: rect, targetWindow: 9002, target: div, side: .leftOf, style: .direct,
                isCancelled: { cancelled }) { r1 = $0 }
        cancelled = true; idle = true        // «Вернуть всё», пока ждали тишины ввода
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        check(r1 == false && sent.isEmpty && !mv.isBusy, "сброс во время ожидания тишины ввода — ни одного события",
              "\(String(describing: r1)) \(sent.count)")
        cancelled = false
        var r2: Bool?
        mv.drag(itemWindow: 30, pid: 965, item: rect, targetWindow: 9002, target: div, side: .leftOf, style: .direct,
                isCancelled: { cancelled }) { r2 = $0 }
        RunLoop.main.run(until: Date().addingTimeInterval(0.06))
        cancelled = true                     // сброс посреди перетаскивания
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        check(r2 == false && sent.first == .leftMouseDown && sent.last == .leftMouseUp && sent.count < 8,
              "сброс посреди перетаскивания — сразу отпускание, остальное не шлётся", "\(sent.map(\.rawValue))")
        sent = []; cancelled = false
        var r3: Bool?
        mv.drag(itemWindow: 30, pid: 965, item: rect, targetWindow: 9002, target: div, side: .leftOf, style: .direct,
                isCancelled: { cancelled }) { r3 = $0 }
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        check(r3 == true && sent.count == 8, "без отмены — 8 событий (в приёмник, не в систему)", "\(sent.count)")

        // 2. Временный показ значка «#N»: назначение висит на исходном ключе — по нему и возвращаем.
        m.testLog = []
        m.tempShown = .init(key: "org.openvpn.client.app|#1", windowID: 147, pid: 99_998, sawMenu: true,
                            since: Date().addingTimeInterval(-10), baseline: [])
        m.onTick()
        check(m.testLog == ["hide org.openvpn.client.app|#1"] && m.tempShown == nil,
              "конец временного показа — прячем по исходному ключу и номеру окна", "\(m.testLog ?? [])")
        let km = MenuBarModel()
        km.prefs.set("org.openvpn.client.app|#1", .island, name: "OpenVPN")
        km.finishMove(key: "org.openvpn.client.app|#1", newKey: "org.openvpn.client.app|#0", ok: true) { _ in }
        check(km.prefs.placements == ["org.openvpn.client.app|#0": .island] && km.prefs.names["org.openvpn.client.app|#0"] == "OpenVPN",
              "после переноса назначение переехало с исходного ключа на новый", "\(km.prefs.placements)")

        // 3. Второй показ, пока первый значок в строке: сначала спрятать первый, потом показывать второй; пока идёт
        //    перенос — третий отклоняется.
        m.axGranted = true
        m.inventory = sectionInv
        m.testLog = []
        m.tempShown = .init(key: "local.vafa|Item-0", windowID: 37601, pid: 99_998, sawMenu: true, since: Date(), baseline: [])
        guard let ollama = sectionInv.items.first(where: { $0.displayName == "Ollama" }),
              let claude = sectionInv.items.first(where: { $0.displayName == "Claude" }) else { check(false, "снимок"); return }
        m.open(ollama)
        m.open(claude)
        check(m.testLog == ["hide local.vafa|Item-0", "show \(ollama.key)"] && m.tempShown == nil,
              "второй показ: прежний спрятан, новый начат, третий (Claude) отклонён", "\(m.testLog ?? [])")
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        m.testLog = nil

        // 5. Порядок сканов: результат старше применённого не перезаписывает новый.
        let fresh = beforeInv(), stale = sectionInv
        let base = m.appliedSeq + 1000
        var got: MenuBarInventory?
        m.receiveScan(fresh, seq: base + 2, epoch: m.epoch, done: nil)
        m.receiveScan(stale, seq: base + 1, epoch: m.epoch) { got = $0 }
        check(m.inventory == fresh && got == fresh, "старый скан, пришедший позже, отброшен; ждущий получил свежий")
        m.receiveScan(stale, seq: base + 3, epoch: m.epoch - 1, done: nil)
        check(m.inventory == fresh, "скан до «Вернуть всё» (старое поколение) не применяется")

        // 6. Кнопки уведомлений после «Вернуть всё» ничего не делают.
        m.resetAll()                          // оборвать показ из п. 3, если он ещё в пути
        m.testNotifications = []
        m.testLog = []
        m.prefs.placements = ["local.vafa|Item-0": .island]
        m.divider.ensure(preferredPosition: nil); m.divider.expand()
        // (Предложения «Вернуть в остров?» больше нет — возврат молчаливый, 25.11; осталось сообщение о «сами за разделителем».)
        m.apply(beforeInv()); m.apply(sectionInv)        // Ollama, Claude, Telegram — «сами за разделителем»
        let notes = m.testNotifications ?? []
        m.resetAll()
        for n in notes { for a in n.actions { a.handler() } }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        check(notes.count == 1 && (m.testLog ?? []).isEmpty && m.prefs.placements.isEmpty && !m.divider.exists,
              "«Вернуть», «Вернуть в строку», «Оставить» после «Вернуть всё» — ничего не делают",
              "\(notes.count) \(m.testLog ?? []) \(m.prefs.placements)")
        m.testNotifications = nil
        m.testLog = nil

        // 4. Ключи: AX-описание в ключ не идёт; миграция вида ключа (имя окна ↔ #N) — один раз.
        let anon = fixture.map { var x = $0; x.name = nil; return x }
        let anonInv = MenuBarInventory.parse(MenuBarScanInput(windows: anon, apps: apps, ownPID: ownPID, ax: [
            MenuBarAXInfo(pid: 2446, frame: CGRect(x: 1264, y: 0, width: 16, height: 37), title: nil,
                          detail: "Connected", identifier: nil)], notch: notch))
        check(anonInv.items.filter { $0.ownerName == "OpenVPN Connect" }.allSatisfy { !$0.key.contains("Connected") },
              "AX-описание («Connected») в ключ не попадает")
        var mp = MenuBarPrefs()
        mp.set("local.vafa|Item-0", .island, name: "Vafa")                  // сохранено с «Записью экрана»
        mp.set("org.openvpn.client.app|Item-1", .hidden, name: "OpenVPN")   // два значка без имён — не угадать
        MenuBarModel.migrateKeys(&mp, anonInv)
        check(mp.placements["local.vafa|#0"] == .island && mp.placements["local.vafa|Item-0"] == nil
              && mp.placements["org.openvpn.client.app|Item-1"] == .hidden,
              "выключили «Запись экрана»: Vafa Item-0 → #0, OpenVPN (2 значка) не тронут", "\(mp.placements)")
        let named = MenuBarInventory.parse(MenuBarScanInput(windows: fixture, apps: apps, ownPID: ownPID,
                                                            ccVisibility: ccVisibility, notch: notch))
        var mp2 = MenuBarPrefs()
        mp2.set("org.openvpn.client.app|#0", .island)                       // старый ключ «#N»
        MenuBarModel.migrateKeys(&mp2, named)
        check(mp2.placements == ["org.openvpn.client.app|Item-1": .island], "старый «#0» → значок с этим номером (Item-1)",
              "\(mp2.placements)")
        MenuBarModel.migrateKeys(&mp2, named)
        check(mp2.placements == ["org.openvpn.client.app|Item-1": .island], "повторная миграция ничего не меняет")

        // 10. Сохранённое сочетание без ⌘/⌃/⌥ — назад к ⌃⌥B.
        let shiftOnly = #"{"hotKey": {"keyCode": 11, "modifiers": 512, "keyLabel": "B"}}"#.data(using: .utf8)!
        check((try? JSONDecoder().decode(MenuBarPrefs.self, from: shiftOnly))?.hotKey == MenuBarPrefs.defaultHotKey,
              "сохранённое ⇧B при загрузке сброшено на ⌃⌥B")
    }

    // MARK: Живой инвентарь (только чтение)

    // MARK: macOS 27 — снимок слотов MenuBarAgent (20.11.2026, macOS 27.2.1, 16" 1728 pt, вырез 771.5…956.5)

    nonisolated static let agentPID: pid_t = 7003
    static let agentApps: [pid_t: MenuBarAppInfo] = [
        35915: .init(bundleId: "ai.storyteller.artcraft-launcher", name: "ArtCraft Launcher"),
        55047: .init(bundleId: "moe.Throne.macosx", name: "Throne"),
        66288: .init(bundleId: "com.anthropic.claudefordesktop", name: "Claude"),
        36408: .init(bundleId: "local.screentab", name: "ScreenTab"),
        55809: .init(bundleId: "local.vafa.menu", name: "Vafa"),
        36412: .init(bundleId: "com.bjango.istatmenus.status", name: "iStat Menus Status"),
        40001: .init(bundleId: "com.if.Amphetamine", name: "Amphetamine"),
        36467: .init(bundleId: "io.tailscale.ipn.macsys", name: "Tailscale"),
        57826: .init(bundleId: "ru.keepcoder.Telegram", name: "Telegram"),
        37313: .init(bundleId: "com.electron.ollama", name: "Ollama"),
        36415: .init(bundleId: "com.apple.TextInputMenuAgent", name: "TextInputMenuAgent"),
        7003: .init(bundleId: "com.apple.MenuBarAgent", name: "MenuBarAgent"),
    ]

    nonisolated static func slot(_ pid: pid_t, _ x: CGFloat, _ w: CGFloat, title: String? = nil, detail: String? = nil,
                     id: String? = nil, order: Int = 0) -> MenuBarAgentSlot {
        MenuBarAgentSlot(pid: pid, frame: CGRect(x: x, y: 0, width: w, height: 33), title: title, detail: detail,
                         identifier: id, order: order)
    }

    nonisolated static let agentSlots: [MenuBarAgentSlot] = [
        slot(ownPID, 975, 38, detail: "SimpleIsland", order: 0),
        slot(35915, 975, 38, detail: "ArtCraft Launcher", order: 1),
        slot(55047, 975, 38, order: 2),
        slot(66288, 1021, 40), slot(36408, 1061, 34), slot(55809, 1095, 30, detail: "Vafa"),
        slot(36412, 1125, 45, title: "Battery 92%, 3:42 Remaining"), slot(40001, 1170, 31), slot(36467, 1201, 38),
        slot(57826, 1239, 40), slot(36412, 1279, 39, title: "CPU Core Average 46°"), slot(36412, 1318, 26, title: "CPU 24%"),
        slot(37313, 1344, 32), slot(36415, 1376, 44),
        slot(agentPID, 1428, 22, detail: "Фокусирование", id: "com.apple.menuextra.focusmode"),
        slot(agentPID, 1466, 26, title: "94 %", detail: "Аккумулятор", id: "com.apple.menuextra.battery"),
        slot(agentPID, 1508, 22, detail: "Wi‑Fi, Режим модема", id: "com.apple.menuextra.wifi"),
        slot(agentPID, 1546, 26, detail: "Пункт управления", id: "com.apple.menuextra.controlcenter"),
        slot(agentPID, 1588, 119, title: "Пт, 20 нояб.  14:34", detail: "Часы", id: "com.apple.menuextra.clock"),
    ]
    nonisolated static let agentIndicator = CGRect(x: 996, y: 1, width: 18, height: 30)

    static func agentInv(_ slots: [MenuBarAgentSlot] = agentSlots, indicator: CGRect? = agentIndicator,
                         divider: CGRect? = nil, expanded: Bool = false) -> MenuBarInventory {
        MenuBarInventory.parseAgent(MenuBarAgentInput(
            snapshot: MenuBarAgentSnapshot(slots: slots, indicator: indicator, expanded: false), apps: agentApps,
            ownPID: ownPID, agentPID: agentPID, dividerFrame: divider, dividerExpanded: expanded,
            notch: CGRect(x: 771.5, y: 0, width: 185, height: 32)))
    }

    static func agentInventory() {
        print("— macOS 27: инвентарь по слотам MenuBarAgent")
        let inv = agentInv()
        printTable(inv)
        check(inv.source == .agent && inv.ghosts == 0, "источник — MenuBarAgent, призраков нет")
        check(inv.items.count == 18 && !inv.items.contains { $0.pid == ownPID }, "значков 18, свой не в списке", "\(inv.items.count)")
        check(inv.visible.count == 16, "видно 16 (правее кнопки overflow)", "\(inv.visible.count)")
        check(Set(inv.underNotch.map(\.displayName)) == ["ArtCraft Launcher", "Throne"],
              "скрыты системой (левее кнопки overflow) — ArtCraft и Throne, разделителя нет → «под вырезом»",
              "\(inv.underNotch.map(\.displayName))")
        check(inv.inIslandSection.isEmpty, "без разделителя «в острове» пусто")
        let by = Dictionary(inv.items.map { ($0.displayName, $0) }, uniquingKeysWith: { a, _ in a })
        check(by["Wi-Fi"]?.key == "com.apple.controlcenter|WiFi" && by["Wi-Fi"]?.isMovable == true,
              "Wi-Fi: ключ как на 15/26 (назначения переживают обновление), двигается", by["Wi-Fi"]?.key ?? "-")
        check(by["Часы"]?.isMovable == false && by["Пункт управления"]?.isMovable == false, "часы и Пункт управления не двигаются")
        check(by["Батарея"]?.kind == .controlCenter(module: "Battery"), "com.apple.menuextra.battery → модуль Battery")
        check(by["Фокусирование"] != nil, "фокусирование — имя модуля по-русски")
        check(by["Раскладка"]?.kind == .system("TextInput"), "раскладка — системный TextInput")
        check(by["iStat Menus"] != nil, "«iStat Menus Status» → «iStat Menus»")
        let istat = inv.items.filter { $0.pid == 36412 }
        check(istat.count == 3 && istat.allSatisfy { !$0.hasStableKey }, "у iStat 3 значка, ключи «#N» — неустойчивые")
        check(istat.contains { $0.axTitle == "CPU 24%" }, "живые подписи значков из AX")
        check(Set(inv.items.map(\.key)).count == inv.items.count, "ключи уникальны")
        check(Set(inv.items.map(\.windowID)).count == inv.items.count && inv.items.allSatisfy { !$0.hasRealWindow },
              "синтетические номера уникальны и помечены «без окна»")
        check(by["Vafa"]?.key == "local.vafa.menu|#0" && by["Vafa"]?.hasStableKey == true, "одиночный значок — устойчивый ключ")
        check(MenuBarAgent.module(forIdentifier: "com.apple.menuextra.controlcenter") == "BentoBox"
              && MenuBarAgent.module(forIdentifier: "com.apple.menuextra.newthing") == "newthing"
              && MenuBarAgent.module(forIdentifier: nil) == nil, "идентификаторы модулей → имена; новые — как есть")
        // Раскрытый overflow: скрытые стоят в ряд левее выреза — всё ещё скрытые.
        var open = agentSlots
        for i in 0..<3 { open[i].frame.origin.x = 637 + CGFloat(i) * 38 }
        let invOpen = agentInv(open)
        check(invOpen.underNotch.count == 2 && invOpen.visible.count == 16, "раскрытый overflow: скрытые остаются скрытыми")
        // Всё влезает — кнопки overflow нет, скрытых нет.
        let fits = agentInv(Array(agentSlots.dropFirst(3)), indicator: nil)
        check(fits.underNotch.isEmpty && fits.visible.count == 16, "нет кнопки overflow — всё видно")
        check(agentInv(Array(agentSlots.dropFirst(3)), indicator: nil).items == fits.items, "разбор детерминирован")
    }

    static func agentDivider() {
        print("— macOS 27: разделитель в строке и в overflow, длина")
        // Разделитель перенесён в строку правее кнопки overflow (1033…1061) и развёрнут: всё скрытое — «в острове».
        var slots = agentSlots
        slots.append(slot(ownPID, 1033, 28, order: 30))
        let inBar = agentInv(slots, divider: CGRect(x: 1033, y: 0, width: 28, height: 33), expanded: true)
        check(Set(inBar.inIslandSection.map(\.displayName)) == ["ArtCraft Launcher", "Throne"] && inBar.underNotch.isEmpty,
              "разделитель в строке и развёрнут → скрытые системой — «в острове»", "\(inBar.inIslandSection.map(\.displayName))")
        check(inBar.dividerFrame?.minX == 1033 && !inBar.dividerInOverflow, "рамка разделителя — его слот")
        let collapsed = agentInv(slots, divider: CGRect(x: 1033, y: 0, width: 28, height: 33), expanded: false)
        check(collapsed.inIslandSection.isEmpty && collapsed.underNotch.count == 2, "свёрнут — скрытые «под вырезом»")
        // Новый разделитель — в overflow (система ставит новые левее всех): ничего не прячет.
        let lost = agentInv(divider: CGRect(x: 975, y: 0, width: 38, height: 33), expanded: true)
        check(lost.dividerInOverflow && lost.dividerFrame == nil && lost.inIslandSection.count == 2,
              "разделитель сам в overflow — помечен; скрытое системой при нём — всё равно «в острове»")
        // Куда бросать на 27: полная строка и раскрытый ряд — левее самого правого скрытого; иначе — левее разделителя.
        var openSlots = agentSlots
        for i in 0..<3 { openSlots[i].frame.origin.x = 637 + CGFloat(i) * 38 }
        var openInv = agentInv(openSlots)
        openInv.overflowExpanded = true
        let claude = openInv.items.first { $0.displayName == "Claude" }!
        let ht = MenuBarModel.agentHideTarget(openInv, dividerFrame: nil, excluding: claude.windowID)
        check(ht?.overflowRow == true && ht?.frame.minX == 713, "в остров при полной строке — в раскрытый ряд, левее крайнего правого скрытого",
              "\(String(describing: ht))")
        let roomy = agentInv(Array(agentSlots.dropFirst(3)), indicator: nil)
        let dv = CGRect(x: 990, y: 0, width: 28, height: 33)
        check(MenuBarModel.agentHideTarget(roomy, dividerFrame: dv, excluding: claude.windowID)?.overflowRow == false
              && MenuBarModel.agentHideTarget(roomy, dividerFrame: nil, excluding: claude.windowID) == nil,
              "есть место — левее разделителя в строке; без него — некуда")
        check(MenuBarModel.agentShowTarget(openInv, excluding: 0)?.minX == 1021, "вернуть — правее самого левого видимого (Claude)")
        // Длина: ≤ половины экрана − 20 (849 на 1728 система отбрасывает), не меньше 60.
        let cap = MenuBarDividerMath.agentLength(rightEdge: nil, leftLimit: nil, screenWidth: 1728)
        check(cap == 844 && cap + 16 <= 1728 / 2, "без выреза — предел 844 (окно 860 ≤ 864)", "\(cap)")
        check(MenuBarDividerMath.agentLength(rightEdge: 1061, leftLimit: 956.5, screenWidth: 1728) == 60,
              "правый край 1061, вырез до 956,5 → минимум 60")
        check(MenuBarDividerMath.agentLength(rightEdge: 1700, leftLimit: 956.5, screenWidth: 1728) == 685.5,
              "правый край 1700 → 1700 − 8 − 1006,5 = 685,5")
        check(MenuBarDividerMath.agentLength(rightEdge: 5000, leftLimit: 0, screenWidth: 1728) == 844, "не больше предела")
    }

    static func agentMerge() {
        print("— macOS 27: склейка двух окон MenuBarAgent")
        // Окно 1: AXApplication без подписей; окно 2: AXButton с подписями. Два значка iStat в одной точке overflow.
        let w1 = [slot(36412, 975, 38, order: 0), slot(36412, 975, 38, order: 1), slot(37313, 1344, 32, order: 2),
                  slot(agentPID, 1508, 22, detail: "Wi‑Fi", id: "com.apple.menuextra.wifi", order: 3)]
        let w2 = [slot(36412, 975, 38, title: "CPU 24%"), slot(36412, 975, 38, title: "Battery 90%"),
                  slot(37313, 1344, 32, detail: "Ollama")]
        let m = MenuBarAgent.merge([w1, w2])
        check(m.count == 4, "мест 4 (копии не задваиваются)", "\(m.count)")
        check(m.filter { $0.pid == 36412 }.compactMap(\.title).sorted() == ["Battery 90%", "CPU 24%"],
              "два значка в одной точке получают каждый свою подпись")
        check(m.first { $0.pid == 37313 }?.detail == "Ollama" && m.first { $0.pid == agentPID }?.identifier != nil,
              "подписи и идентификаторы сохранены")
        check(MenuBarAgent.merge([]).isEmpty, "пусто — пусто")
        check(MenuBarAgent.isHidden(CGRect(x: 975, y: 0, width: 38, height: 33), indicator: agentIndicator)
              && !MenuBarAgent.isHidden(CGRect(x: 1021, y: 0, width: 40, height: 33), indicator: agentIndicator)
              && !MenuBarAgent.isHidden(CGRect(x: 975, y: 0, width: 38, height: 33), indicator: nil)
              && MenuBarAgent.isHidden(CGRect(x: 985, y: 0, width: 28, height: 33), indicator: agentIndicator),
              "скрыт = левее кнопки overflow (и узкий 985+28, прижатый к ней — живая проба 20.11)")
        let collapsedRow = [slot(1, 975, 38), slot(2, 985, 28), slot(3, 1021, 40)]
        let openRow = [slot(1, 560, 37), slot(2, 597, 38), slot(3, 1021, 40)]
        check(!MenuBarAgent.isExpanded(collapsedRow, indicator: agentIndicator, byID: true)
              && MenuBarAgent.isExpanded(openRow, indicator: agentIndicator, byID: false),
              "раскрыт ли overflow — по геометрии, а не по id устаревшей копии кнопки")
    }

    static func agentMover() {
        print("— macOS 27: перенос «как человек» (способ .agent)")
        let mv = MenuBarMover()
        var events: [CGEvent] = []
        mv.testSink = { events.append($0) }
        mv.testIdle = { true }
        let item = CGRect(x: 572, y: 0, width: 28, height: 33)      // свой разделитель в раскрытом overflow
        let target = CGRect(x: 1021, y: 0, width: 40, height: 33)   // Claude
        var r: Bool?
        mv.drag(itemWindow: 0, pid: getpid(), item: item, targetWindow: 0, target: target, side: .rightOf, style: .agent) { r = $0 }
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        let types = events.map(\.type)
        check(r == true && events.count == 13 && types.first == .mouseMoved && types[1] == .leftMouseDown
              && types.last == .leftMouseUp && types.filter { $0 == .leftMouseDragged }.count == 10,
              "13 событий: движение, нажатие, 10 шагов, отпускание", "\(types.map(\.rawValue))")
        check(events.allSatisfy { $0.flags.contains(.maskCommand) && $0.getIntegerValueField(.mouseEventWindowUnderMousePointer) == 0
                                  && $0.getIntegerValueField(.eventTargetUnixProcessID) == 0 },
              "все с ⌘, без полей окна и pid (окон у значков нет)")
        check(events.first?.location == CGPoint(x: 586, y: 16.5) && events.last?.location == CGPoint(x: 1058, y: 16.5),
              "из центра значка к правой части цели (как в живой пробе 586 → 1057)", "\(events.last?.location ?? .zero)")
        check(MenuBarModel.agentMoveFailedText("Ollama").contains("Разрешить в строке меню"),
              "неудача на 27 — подсказка про «Разрешить в строке меню»")
    }

    // MARK: macOS 27 — два экрана (27.11.2026: встроенный 1728 с вырезом + LG 4K 1920 без выреза, над ним справа)

    nonisolated static func ls(_ pid: pid_t, _ x: CGFloat, _ w: CGFloat) -> MenuBarAgentSlot {
        MenuBarAgentSlot(pid: pid, frame: CGRect(x: x, y: -1080, width: w, height: 30))
    }

    static let multiApps: [pid_t: MenuBarAppInfo] = {
        var a = agentApps
        a[50001] = .init(bundleId: "app.amnl.lyrics.bridge", name: "SimpleLyrics Bridge")
        a[50002] = .init(bundleId: "com.k33ssa.SimpleFaceitWidget", name: "SimpleFaceit")
        return a
    }()

    static func agentMultiScreen() {
        print("— macOS 27: два экрана — спрятанное на основном видно на LG")
        let cc: [MenuBarAgentSlot] = [
            slot(agentPID, 1428, 22, id: "com.apple.menuextra.focusmode"), slot(agentPID, 1466, 26, id: "com.apple.menuextra.battery"),
            slot(agentPID, 1508, 22, id: "com.apple.menuextra.wifi"), slot(agentPID, 1546, 26, id: "com.apple.menuextra.controlcenter"),
            slot(agentPID, 1588, 119, id: "com.apple.menuextra.clock")]
        let lgCC = [ls(agentPID, 2624, 22), ls(agentPID, 2662, 26), ls(agentPID, 2704, 22), ls(agentPID, 2742, 26), ls(agentPID, 2784, 119)]
        // A: разделитель свёрнут (12). Основной: префикс скрыт системой; LG: видно всё.
        let mainA: [MenuBarAgentSlot] = [
            slot(36412, 905, 177, title: "Battery 59%"), slot(57826, 1042, 40), slot(66288, 1042, 40), slot(35915, 1044, 38),
            slot(50001, 1046, 36), slot(36408, 1048, 34), slot(37313, 1050, 32),
            slot(50002, 1090, 56), slot(ownPID, 1146, 28), slot(36412, 1174, 39), slot(55047, 1213, 38), slot(ownPID, 1251, 38),
            slot(55809, 1289, 30), slot(40001, 1319, 31), slot(36412, 1350, 26), slot(36415, 1376, 44)] + cc
        let lgA: [MenuBarAgentSlot] = [
            ls(37313, 1889, 32), ls(66288, 1921, 40), ls(36408, 1961, 34), ls(50001, 1995, 36), ls(35915, 2031, 38),
            ls(57826, 2069, 40), ls(36412, 2109, 177), ls(50002, 2286, 56), ls(ownPID, 2342, 28), ls(36412, 2370, 39),
            ls(55047, 2409, 38), ls(ownPID, 2447, 38), ls(55809, 2485, 30), ls(40001, 2515, 31), ls(36412, 2546, 26),
            ls(36415, 2572, 44)] + lgCC
        let lgFrame = CGRect(x: 1004, y: -1080, width: 1920, height: 30)
        let ind = CGRect(x: 1065, y: 1, width: 18, height: 30)
        func parse(_ main: [MenuBarAgentSlot], _ mainInd: CGRect?, _ lg: [MenuBarAgentSlot], _ lgInd: CGRect?, expanded: Bool)
            -> MenuBarInventory {
            MenuBarInventory.parseAgent(MenuBarAgentInput(
                snapshot: MenuBarAgentSnapshot(slots: main, indicator: mainInd, expanded: false,
                                               others: [MenuBarAgentBar(frame: lgFrame, slots: lg, indicator: lgInd)]),
                apps: multiApps, ownPID: ownPID, agentPID: agentPID, dividerFrame: CGRect(x: 1146, y: 0, width: 28, height: 33),
                dividerExpanded: expanded, notch: CGRect(x: 771.5, y: 0, width: 185, height: 32)))
        }
        let a = parse(mainA, ind, lgA, nil, expanded: true)
        printTable(a)
        let hiddenNames = Set(a.items.filter { $0.section != .visible }.map(\.displayName))
        check(a.screenCount == 2 && hiddenNames == ["iStat Menus", "Telegram", "Claude", "ArtCraft Launcher",
                                                    "SimpleLyrics Bridge", "ScreenTab", "Ollama"],
              "основной: скрыт префикс из 7", "\(hiddenNames)")
        let leaked = Set(a.items.filter { a.visibleElsewhere[$0.key] != nil && $0.section != .visible }.map(\.displayName))
        check(leaked == hiddenNames, "все 7 скрытых на основном видно на LG (жалоба 27.11)", "\(leaked)")
        check(a.visibleElsewhere[a.items.first { $0.displayName == "Vafa" }?.key ?? "-"] == [1], "видимое везде — видно и на LG")
        var p = MenuBarPrefs()
        for it in a.items where it.section != .visible { p.placements[it.key] = .island }
        check(MenuBarModel.leakedKeys(a, p).count == 7 && MenuBarModel.leakText(a, p)?.contains("другом экране") == true,
              "назначенные «в остров» и видные на LG — во вкладке честная строка")
        check(MenuBarModel.leakedKeys(a, MenuBarPrefs()).isEmpty, "без назначений протечек нет")
        // B: разделитель развёрнут до 844 (окно 860; на LG 1510…2370, кнопка overflow LG 1485). На основном скрытых
        // слотов нет совсем, кнопки нет; на LG часть скрытых — в ряду у кнопки, часть — без слотов.
        let mainB: [MenuBarAgentSlot] = [slot(36412, 1174, 39), slot(55047, 1213, 38), slot(ownPID, 1251, 38),
            slot(55809, 1289, 30), slot(40001, 1319, 31), slot(36412, 1350, 26), slot(36415, 1376, 44)] + cc
        let lgB: [MenuBarAgentSlot] = [ls(36412, 1325, 177), ls(50002, 1446, 56), ls(57826, 1462, 40), ls(35915, 1464, 38),
            ls(50001, 1466, 36), ls(ownPID, 1510, 860), ls(36412, 2370, 39), ls(55047, 2409, 38), ls(ownPID, 2447, 38),
            ls(55809, 2485, 30), ls(40001, 2515, 31), ls(36412, 2546, 26), ls(36415, 2572, 44)] + lgCC
        let b = parse(mainB, nil, lgB, CGRect(x: 1485, y: -1079, width: 18, height: 27), expanded: true)
        let bHidden = Set(b.items.filter { $0.section != .visible }.map(\.displayName))
        check(bHidden == ["iStat Menus", "SimpleFaceit", "Telegram", "ArtCraft Launcher", "SimpleLyrics Bridge"],
              "развёрнут: значки, которых нет на основном, взяты с LG как скрытые", "\(bHidden)")
        check(b.items.filter { $0.section != .visible }.allSatisfy { $0.section == .island }, "при развёрнутом разделителе — «в острове»")
        check(b.visibleElsewhere.keys.allSatisfy { k in b.item(key: k)?.section == .visible },
              "на LG ничего из скрытого не видно")
        check(Set(b.items.map(\.key)).count == b.items.count, "ключи уникальны и с добавленными")
        check(MenuBarDividerMath.agentMultiScreenLength(screenWidths: [1728, 1920]) == 844
              && MenuBarDividerMath.agentMultiScreenLength(screenWidths: [1440, 2560]) == 700,
              "длина при нескольких экранах — половина самого узкого − 20")
    }

    // MARK: macOS 27 — живая проба переноса своими значками

    private static func spin(_ sec: Double) {
        let end = Date().addingTimeInterval(sec)
        while Date() < end { CFRunLoopRunInMode(.defaultMode, 0.02, true); usleep(10_000) }
    }

    private static func idleSeconds() -> Double {
        [CGEventType.mouseMoved, .keyDown, .leftMouseDown, .scrollWheel]
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? 0
    }

    static func liveMove() {
        print("— macOS 27: живая проба переноса (свои значки)")
        guard MenuBarAgent.isActive, AXIsProcessTrusted() else { print("  пропуск: не macOS 27 или нет Универсального доступа"); return }
        var waited = 0.0
        while idleSeconds() < 10 && waited < 300 { spin(1); waited += 1 }
        guard idleSeconds() >= 10 else { print("  пропуск: пользователь работает (5 мин без паузы ≥ 10 с)"); return }
        let bar = NSStatusBar.system
        let t = bar.statusItem(withLength: NSStatusItem.variableLength)
        t.autosaveName = "SimpleIslandSelftestT"
        t.button?.title = "SI·T"
        let d = bar.statusItem(withLength: MenuBarDividerMath.collapsedLength)
        d.autosaveName = "SimpleIslandSelftestD"
        d.button?.title = "|"
        let wasDry = MenuBarMover.dryRun
        MenuBarMover.dryRun = false
        func cg(_ i: NSStatusItem) -> CGRect {
            guard let f = i.button?.window?.frame, let m = NSScreen.screens.first else { return .zero }
            return CGRect(x: f.minX, y: m.frame.maxY - f.maxY, width: f.width, height: f.height)
        }
        func userOrder() -> [String] {
            MenuBarScanner.scanNow(dividerWindowID: nil, dividerLength: nil).items.map(\.key)
        }
        func overflow(_ open: Bool) {
            var done = false
            DispatchQueue.global().async { MenuBarAgent.setOverflow(expanded: open); done = true }
            var w = 0.0
            while !done && w < 6 { spin(0.1); w += 0.1 }
            spin(1.5)   // AX уже «раскрыт», а окна значков ещё на старых местах — ждать перерисовки
        }
        func drag(_ from: CGRect, to target: CGRect, side: MenuBarMover.Side) -> Bool {
            let mv = MenuBarMover()
            var r: Bool?
            mv.drag(itemWindow: 0, pid: getpid(), item: from, targetWindow: 0, target: target, side: side, style: .agent) { r = $0 }
            var w = 0.0
            while r == nil && w < 15 { spin(0.1); w += 0.1 }
            spin(1)
            return r == true
        }
        func hidden(_ i: NSStatusItem) -> Bool { MenuBarAgent.isHidden(cg(i), indicator: MenuBarAgent.read()?.0.indicator) }
        spin(2)
        let before = userOrder()
        defer {
            bar.removeStatusItem(t); bar.removeStatusItem(d)
            spin(2)
            overflow(false)
            MenuBarMover.dryRun = wasDry
            let after = userOrder()
            check(after == before, "после пробы чужие значки на своих местах (\(after.count))",
                  "до \(before.count): \(before.prefix(4)) после: \(after.prefix(4))")
        }
        // Строка полна (на этом Маке): тестовый значок новый — в overflow. 1) Вернуть в строку: раскрыть overflow,
        // бросить правее самого левого видимого. 2) В остров: раскрыть overflow, бросить левее самого правого скрытого.
        overflow(true)
        var inv0 = MenuBarScanner.scanNow(dividerWindowID: nil, dividerLength: nil)
        guard let show = MenuBarModel.agentShowTarget(inv0, excluding: 0) else { check(false, "есть видимый подвижный значок"); return }
        print("  раскрыт: \(inv0.overflowExpanded), значок \(cg(t)), цель \(show)")
        let sent1 = drag(cg(t), to: show, side: .rightOf)
        overflow(false)
        spin(0.5)
        check(sent1 && !hidden(t), "из overflow в строку: значок виден (x=\(Int(cg(t).minX)))", "x=\(cg(t).minX)")
        overflow(true)
        inv0 = MenuBarScanner.scanNow(dividerWindowID: nil, dividerLength: nil)
        guard let hide = MenuBarModel.agentHideTarget(inv0, dividerFrame: nil, excluding: 0) else {
            check(false, "ряд скрытых раскрыт"); return
        }
        print("  раскрыт: \(inv0.overflowExpanded), значок \(cg(t)), цель \(hide.frame)")
        let sent2 = drag(cg(t), to: hide.frame, side: .leftOf)
        overflow(false)
        spin(0.5)
        check(sent2 && hidden(t), "из строки в overflow («в остров»): значок скрыт", "x=\(cg(t).minX)")
        _ = d
    }

    static func printLive() {
        print("— живой инвентарь (только чтение; Универсальный доступ: \(AXIsProcessTrusted() ? "есть" : "нет"), Запись экрана: \(CGPreflightScreenCaptureAccess() ? "есть" : "нет"))")
        let inv = MenuBarScanner.scanNow(dividerWindowID: nil, dividerLength: nil)
        print("  источник: \(inv.source.rawValue)\(MenuBarAgent.isActive ? " (macOS 27, MenuBarAgent)" : ""), overflow: \(inv.overflowIndicator.map { "кнопка x=\(Int($0.minX)), \(inv.overflowExpanded ? "раскрыт" : "свёрнут")" } ?? "нет")")
        printTable(inv)
        let elsewhere = inv.items.filter { $0.section != .visible && inv.visibleElsewhere[$0.key] != nil }.map(\.displayName)
        print("  экранов со строкой меню: \(inv.screenCount); скрытые на основном, но видные на другом экране: \(elsewhere.isEmpty ? "нет" : elsewhere.joined(separator: ", "))")
        print("  призраков: \(inv.ghosts), копий на других экранах: \(inv.otherScreenCopies), вырез: \(MenuBarScanner.notchRect().map { "\($0)" } ?? "нет")")
    }
}
