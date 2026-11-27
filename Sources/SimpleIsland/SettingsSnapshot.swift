import AppKit
import Carbon.HIToolbox
import SwiftUI
import IslandCore

// Снимки окна настроек и онбординга (`--snapshot <каталог> --snapshot-module settings`) и самотесты
// (`--selftest-settings`). Без окон на экране и без запросов прав.

@MainActor
enum SettingsSnapshots {
    struct Shot {
        var name: String
        var prepare: @MainActor (inout SettingsData, SettingsNavigation) -> Void = { _, _ in }
    }

    static let settingsShots: [Shot] = [
        Shot(name: "layout"),
        Shot(name: "layout-module") { _, nav in nav.selectedModule = "media" },
        // Стороны выреза (16.11): часть вкладок справа.
        Shot(name: "layout-sides") { d, _ in
            d.tabs = ["media", "agents", "today", "shelf", "vafa", "menubar", "equalizer"].map {
                TabSetting(id: $0, enabled: $0 != "equalizer", side: ["vafa", "menubar", "equalizer"].contains($0) ? .right : .left)
            }
        },
        Shot(name: "layout-compact") { d, nav in
            nav.previewCompact = true
            d.leftEarModule = "media"; d.rightEarModule = "agents"
        },
        Shot(name: "themes") { _, nav in nav.section = .themes },
        Shot(name: "gestures") { _, nav in nav.section = .gestures },
        Shot(name: "gestures-conflict") { _, nav in nav.section = .gestures },   // ⌃⌥Space занято системой
        Shot(name: "visibility") { _, nav in nav.section = .visibility },
        Shot(name: "module-agents") { _, nav in nav.section = .module("agents") },
        Shot(name: "module-media") { _, nav in nav.section = .module("media") },   // «Тексты»: подключение Apple Music
        Shot(name: "module-menubar") { _, nav in nav.section = .module("menubar") },   // --- menubar ---
        Shot(name: "integrations") { _, nav in nav.section = .integrations },
        Shot(name: "displays") { _, nav in nav.section = .displays },
        Shot(name: "about") { _, nav in nav.section = .about },
    ]

    /// Статусы разрешений для снимков: видны все варианты.
    static let mockPermissions: [PermissionKind: PermissionState] = [
        .accessibility: .notDetermined, .automation: .unknown, .calendar: .granted, .camera: .denied,
    ]

    /// `<тема>-settings-<раздел>.png` и `<тема>-onboarding-<шаг>.png`. Возвращает число снимков.
    static func render(store: ThemeStore, theme: Theme, o: SnapshotRunner.Options) -> Int {
        var count = 0
        let permissions = PermissionCenter(mock: mockPermissions)
        for shot in settingsShots {
            var data = SettingsData()
            data.themeId = theme.id
            let nav = SettingsNavigation()
            shot.prepare(&data, nav)
            GlobalHotKey.shared.setSnapshotConflict(shot.name == "gestures-conflict" ? "«Выбрать следующий источник ввода»" : nil)
            defer { GlobalHotKey.shared.setSnapshotConflict(nil) }
            let env = makeEnv(store: store, data: data)
            let view = SettingsRootView(env: env, nav: nav, permissions: permissions)
                .frame(width: 1360, height: 860)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                // Как у живого окна (SettingsWindows.styleWindows): иначе текст разделов модулей со стандартным
                // цветом (.primary) в снимке чёрный на тёмном фоне.
                .environment(\.colorScheme, data.applying(to: theme).isLight ? .light : .dark)
            count += write(view, o.outDir.appendingPathComponent("\(theme.id)-settings-\(shot.name).png")) ? 1 : 0
        }
        for step in OnboardingStep.allCases {
            var data = SettingsData()
            data.themeId = theme.id
            let env = makeEnv(store: store, data: data)
            let view = OnboardingView(env: env, step: step, permissions: permissions)
                .frame(width: 820, height: 600)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .environment(\.colorScheme, .dark)   // окно онбординга всегда darkAqua
            count += write(view, o.outDir.appendingPathComponent("\(theme.id)-onboarding-\(step.name).png")) ? 1 : 0
        }
        return count
    }

    private static func makeEnv(store: ThemeStore, data: SettingsData) -> AppEnvironment {
        AppEnvironment(settings: SimpleIslandSettings(inMemory: data), themes: store,
                       modules: ModuleRegistry.makeModules(), isSnapshot: true)
    }

    private static func write<V: View>(_ view: V, _ url: URL) -> Bool {
        let r = ImageRenderer(content: view.environment(\.isSnapshot, true))
        r.scale = 2
        guard let cg = r.cgImage,
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
            fputs("SimpleIsland: не отрисован \(url.lastPathComponent)\n", stderr); return false
        }
        do { try png.write(to: url); return true } catch {
            fputs("SimpleIsland: не записан \(url.path): \(error)\n", stderr); return false
        }
    }
}

// MARK: - Самотесты

@MainActor
enum SettingsSelfTest {
    private static var failures = 0

    private static func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if ok { print("OK   \(name)") } else { failures += 1; print("FAIL \(name) \(detail())") }
    }

    static func run() -> Int32 {
        _ = NSApplication.shared
        failures = 0
        settingsData()
        tabOrder()
        ears()
        physics()
        themeFiles()
        hotKey()
        palettes()
        systemStatus()
        print(failures == 0 ? "ИТОГ: все проверки прошли" : "ИТОГ: провалено \(failures)")
        return failures == 0 ? 0 : 1
    }

    /// Старый settings.json без новых полей и круговой обмен новых полей.
    private static func settingsData() {
        let legacy = #"{"themeId": "paper", "tabs": [{"id": "media", "enabled": false}], "hoverDelay": 0.3}"#
        guard let d = try? MergedJSON.decode(SettingsData.self, from: Data(legacy.utf8), base: SettingsData()) else {
            check(false, "старый settings.json разбирается"); return
        }
        check(d.themeId == "paper" && d.hoverDelay == 0.3, "старый settings.json: старые поля на месте")
        check(d.toggleHotKey == .defaultToggle && d.toggleHotKeyEnabled, "по умолчанию горячая клавиша ⌃⌥Space включена",
              d.toggleHotKey.displayString)
        check(!d.onboardingCompleted && d.leftEarModule == nil && d.rightEarModule == nil && d.swipeGestures && d.wheelGestures,
              "по умолчанию: онбординг не пройден, уши авто, жесты включены")
        check(!d.reduceMotionOnBattery, "по умолчанию «Упрощать анимации на батарее» выключено")

        var n = SettingsData()
        n.leftEarModule = "media"; n.rightEarModule = "agents"
        n.toggleHotKey = HotKeySpec(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey | shiftKey), keyLabel: "K")
        n.toggleHotKeyEnabled = false; n.swipeGestures = false; n.onboardingCompleted = true
        n.reduceMotionOnBattery = true
        let back = (try? JSONEncoder().encode(n)).flatMap { try? MergedJSON.decode(SettingsData.self, from: $0, base: SettingsData()) }
        check(back == n, "новые поля сохраняются и читаются")
        check(n.toggleHotKey.displayString == "⇧⌘K", "подпись сочетания", n.toggleHotKey.displayString)

        // Сброс уха в «авто» (nil) не должен вернуться к значению по умолчанию после перезапуска.
        n.leftEarModule = nil
        let back2 = (try? JSONEncoder().encode(n)).flatMap { try? MergedJSON.decode(SettingsData.self, from: $0, base: SettingsData()) }
        check(back2?.leftEarModule == nil && back2?.rightEarModule == "agents", "ухо «авто» переживает перезапуск")

        // Запись в файл и чтение через SimpleIslandSettings.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("si-selftest-\(getpid()).json")
        let s1 = SimpleIslandSettings(fileURL: url)
        s1.data.leftEarModule = "shelf"; s1.data.onboardingCompleted = true
        s1.saveNow()
        let s2 = SimpleIslandSettings(fileURL: url)
        check(s2.data.leftEarModule == "shelf" && s2.data.onboardingCompleted, "settings.json на диске")
        // Выход без правок (saveNow из applicationWillTerminate) файл не переписывает: та же дата изменения.
        let old = Date(timeIntervalSince1970: 1_000_000)
        try? FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        s2.saveNow()
        let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        check(mtime == old, "saveNow без правок не переписывает settings.json", "\(mtime.map { "\($0)" } ?? "нет файла")")
        s2.data.leftEarModule = "media"
        s2.saveNow()
        let mtime2 = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        check(mtime2 != old && SimpleIslandSettings(fileURL: url).data.leftEarModule == "media", "saveNow с правкой пишет файл")
        try? FileManager.default.removeItem(at: url)
    }

    private static func tabOrder() {
        var tabs = ["media", "today", "shelf", "agents"].map { TabSetting(id: $0, enabled: true) }
        TabOrder.move(&tabs, id: "agents", before: "media")
        check(tabs.map(\.id) == ["agents", "media", "today", "shelf"], "перетаскивание вкладки вверх", "\(tabs.map(\.id))")
        TabOrder.move(&tabs, id: "agents", before: "shelf")
        check(tabs.map(\.id) == ["media", "today", "shelf", "agents"], "перетаскивание вкладки вниз", "\(tabs.map(\.id))")
        TabOrder.move(&tabs, id: "nope", before: "media")
        check(tabs.count == 4, "неизвестная вкладка не ломает порядок")

        // Стороны выреза (16.11). Миграция: старый settings.json без `side` — всё слева, порядок и включённость те же.
        let legacy = #"{"themeId":"obsidian","tabs":[{"id":"media","enabled":true},{"id":"agents","enabled":false},{"id":"today","enabled":true}]}"#
        let old = try? MergedJSON.decode(SettingsData.self, from: Data(legacy.utf8), base: SettingsData())
        check(old?.tabs.map(\.id) == ["media", "agents", "today"] && old?.tabs.map(\.enabled) == [true, false, true]
              && old?.tabs.allSatisfy { $0.side == .left } == true, "миграция: старые вкладки — все слева, порядок прежний",
              "\(old?.tabs ?? [])")
        check(old?.tabs.allSatisfy(\.sideIsLegacy) == true, "миграция: вкладки без стороны помечены как старые")
        // Что раньше уезжало направо, встаёт справа; выключенные — по месту в списке.
        var mig = SettingsData()
        mig.tabs = (try? MergedJSON.decode(SettingsData.self, from: Data(#"{"tabs":[{"id":"a","enabled":true},{"id":"b","enabled":false},{"id":"c","enabled":true},{"id":"d","enabled":true},{"id":"e","enabled":false},{"id":"f","enabled":true}]}"#.utf8), base: SettingsData()))?.tabs ?? []
        var asked: [String] = []
        let did = mig.migrateLegacyTabSides { asked = $0; return 2 }
        check(did && asked == ["a", "c", "d", "f"] && mig.tabs.map(\.side) == [.left, .left, .left, .right, .right, .right]
              && !mig.tabs.contains(where: \.sideIsLegacy) && mig.tabs.map(\.id) == ["a", "b", "c", "d", "e", "f"],
              "миграция: 2 влезали слева — остальные справа, порядок прежний", "\(mig.tabs.map { "\($0.id)/\($0.side)" })")
        check(!mig.migrateLegacyTabSides { _ in 0 }, "миграция второй раз ничего не делает")
        var fresh = SettingsData()
        fresh.tabs = (try? MergedJSON.decode(SettingsData.self, from: Data(#"{"tabs":[{"id":"a","enabled":true,"side":"left"},{"id":"b","enabled":true,"side":"left"}]}"#.utf8), base: SettingsData()))?.tabs ?? []
        check(!fresh.migrateLegacyTabSides { _ in 0 } && fresh.tabs.allSatisfy { $0.side == .left },
              "файл со сторонами не мигрирует — стороны как записаны")
        // Целиком: старый файл с 7 включёнными вкладками на острове 720 pt — как раньше, часть справа; файл пишется со сторонами.
        let legacy7 = #"{"tabs":["# + ["media", "today", "shelf", "agents", "vafa", "menubar", "equalizer"]
            .map { #"{"id":"\#($0)","enabled":true}"# }.joined(separator: ",") + "]}"
        if let d7 = try? MergedJSON.decode(SettingsData.self, from: Data(legacy7.utf8), base: SettingsData()) {
            let env7 = AppEnvironment(settings: SimpleIslandSettings(inMemory: d7), themes: ThemeStore(load: false),
                                      modules: ModuleRegistry.makeModules(), isSnapshot: true)
            let t7 = env7.settings.data.tabs
            let caps = TabBarLayout.capacities(width: 720, gap: IslandGeometry.mockNotch.notchWidth)
            let ids = t7.filter(\.enabled).map(\.id)
            let n = TabBarLayout.legacyLeftCount(ids: ids, selectedWidths: TabBarLayout.selectedWidths(title: "Медиа"),
                                                 left: caps.left, right: caps.right)
            let leftIds = TabArrangement.tabs(t7, on: .left).filter(\.enabled).map(\.id)
            check(n < 7 && leftIds == Array(ids.prefix(n)) && TabArrangement.tabs(t7, on: .right).count == 7 - n
                  && !t7.contains(where: \.sideIsLegacy),
                  "старый файл, 7 вкладок: \(n) слева, \(7 - n) справа — как стояли раньше",
                  "\(t7.map { "\($0.id)/\($0.side)" })")
            let enc = (try? JSONEncoder().encode(env7.settings.data)).map { String(decoding: $0, as: UTF8.self) } ?? ""
            check(enc.contains(#""side":"right""#) && !enc.contains("sideIsLegacy"), "после миграции стороны пишутся в файл")
        } else { check(false, "старый файл с 7 вкладками читается") }
        let odd = #"{"tabs":[{"id":"media","enabled":true,"side":"middle"},{"id":"shelf","side":"right"}]}"#
        let oddD = try? MergedJSON.decode(SettingsData.self, from: Data(odd.utf8), base: SettingsData())
        check(oddD?.tabs.map(\.side) == [.left, .right] && oddD?.tabs.last?.enabled == true,
              "незнакомая сторона → слева, без enabled → включена", "\(oddD?.tabs ?? [])")
        var round = SettingsData()
        round.tabs = [TabSetting(id: "media", enabled: true), TabSetting(id: "vafa", enabled: true, side: .right)]
        let back = (try? JSONEncoder().encode(round)).flatMap { try? MergedJSON.decode(SettingsData.self, from: $0, base: SettingsData()) }
        check(back?.tabs == round.tabs, "сторона переживает запись и чтение")

        var t = ["media", "today", "shelf", "agents"].map { TabSetting(id: $0, enabled: true) }
        func sides() -> String {
            "L:" + TabArrangement.tabs(t, on: .left).map(\.id).joined(separator: ",")
                + " R:" + TabArrangement.tabs(t, on: .right).map(\.id).joined(separator: ",")
        }
        TabArrangement.moveToEnd(&t, id: "shelf", side: .right)
        check(sides() == "L:media,today,agents R:shelf", "перенос в пустую правую секцию", sides())
        TabArrangement.move(&t, id: "media", before: "shelf")
        check(sides() == "L:today,agents R:media,shelf", "перетаскивание на строку другой секции — встаёт перед ней", sides())
        TabArrangement.flip(&t, id: "agents")
        check(sides() == "L:today R:agents,media,shelf", "стрелка направо — в начало правой (рядом с вырезом)", sides())
        TabArrangement.flip(&t, id: "shelf")
        check(sides() == "L:today,shelf R:agents,media", "стрелка налево — в конец левой (рядом с вырезом)", sides())
        TabArrangement.step(&t, id: "media", by: -1)
        check(sides() == "L:today,shelf R:media,agents", "«Выше» — внутри своей секции", sides())
        TabArrangement.step(&t, id: "today", by: -1)
        check(sides() == "L:today,shelf R:media,agents", "«Выше» у первой — ничего", sides())
        TabArrangement.moveToEnd(&t, id: "today", side: .right)
        TabArrangement.moveToEnd(&t, id: "shelf", side: .right)
        check(sides() == "L: R:media,agents,today,shelf", "левая секция может опустеть", sides())
        TabArrangement.moveToEnd(&t, id: "agents", side: .left)
        check(sides() == "L:agents R:media,today,shelf" && t.count == 4, "бросок в пустую левую секцию", sides())
        TabArrangement.move(&t, id: "nope", before: "media")
        TabArrangement.flip(&t, id: "nope")
        check(t.count == 4 && sides() == "L:agents R:media,today,shelf", "неизвестная вкладка ничего не ломает")
        // Новая из каталога: слева, если есть место, иначе справа.
        var n = [TabSetting(id: "media", enabled: true), TabSetting(id: "eq", enabled: false, side: .right)]
        TabArrangement.placeNew(&n, id: "eq") { _ in true }
        check(n.last?.id == "eq" && n.last?.side == .left && n.last?.enabled == true, "новая вкладка — в конец левой, если есть место")
        TabArrangement.placeNew(&n, id: "vafa") { $0 < 2 }
        TabArrangement.placeNew(&n, id: "shelf") { $0 < 2 }
        check(TabArrangement.tabs(n, on: .left).map(\.id) == ["media", "eq"] && TabArrangement.tabs(n, on: .right).map(\.id) == ["vafa", "shelf"],
              "слева нет места — новые в конец правой", "\(n.map { "\($0.id)/\($0.side)" })")
    }

    private static func ears() {
        let c = ActivityCenter()
        check(c.compactEars(left: "media", right: nil) == nil, "уши без активностей — nil")
        c.post(IslandActivity(id: "media.now", moduleId: "media", priority: 0, sideWidth: 56) { Text("L") } trailing: { Text("R") })
        c.post(IslandActivity(id: "agents.wait", moduleId: "agents", priority: 100, sideWidth: 77) { Text("L") } trailing: { Text("R") })
        let auto = c.compactEars(left: nil, right: nil)
        check(auto?.leadingId == "agents.wait" && auto?.trailingId == "agents.wait", "авто: оба уха у главной активности")
        // Вторая активность — значком внутри уха (UX 15.11), фон (музыка, priority 0) значком не показывается.
        check(c.secondaryActivity(left: nil, right: nil) == nil, "авто: музыка за агентом — без значка (фон)")
        check(c.compactSideWidth(left: nil, right: nil) == 77, "без значка ухо не шире", "\(String(describing: c.compactSideWidth(left: nil, right: nil)))")
        let mixed = c.compactEars(left: "media", right: "agents")
        check(mixed?.leadingId == "media.now" && mixed?.trailingId == "agents.wait", "левое ухо — медиа, правое — агенты")
        check(mixed?.sideWidth == 77, "ширина уха — по самой широкой", "\(String(describing: mixed?.sideWidth))")
        check(c.secondaryActivity(left: "media", right: "agents") == nil, "показанное в ухе не дублируется значком")
        let missing = c.compactEars(left: "today", right: nil)
        check(missing?.leadingId == "agents.wait", "модуль уха без активности → как у главной")

        // Оба уха отданы медиа: главная (агенты) не должна пропасть — она значком в ухе; хозяин компакта — медиа.
        check(c.secondaryActivity(left: "media", right: "media")?.id == "agents.wait",
              "оба уха — медиа: главная активность видна значком", c.secondaryActivity(left: "media", right: "media")?.id ?? "nil")
        check(c.compactSideWidth(left: "media", right: "media") == 56 + SecondaryMark.width, "значок добавляет уху место",
              "\(String(describing: c.compactSideWidth(left: "media", right: "media")))")
        check(c.compactOwner(left: "media", right: "media")?.id == "media.now", "оба уха — медиа: свечение и клик — медиа")
        check(c.compactOwner(left: "media", right: "agents")?.id == "agents.wait", "главная в ухе — она и хозяин компакта")
        check(c.compactOwner(left: nil, right: nil)?.id == "agents.wait", "без назначений хозяин — главная (как раньше)")
        // Клик по значку, когда уши заняты назначениями: поднять некуда → false, закрепление не меняется.
        check(!c.raiseSecondary(c.activities.first { $0.id == "agents.wait" }!, left: "media", right: "media")
              && c.pinnedPrimaryId == nil, "значок при занятых ушах: открыть её вкладку, закрепление прежнее")
        // Три активности, уши медиа | агенты: значком — третья (у неё есть что сказать, priority 50).
        c.post(IslandActivity(id: "today.next", moduleId: "today", priority: 50, sideWidth: 60) { Text("L") } trailing: { Text("R") })
        check(c.secondaryActivity(left: "media", right: "agents")?.id == "today.next", "уши медиа | агенты: значком третья")
        // Авто: агенты главные, встреча второй — значком; клик меняет местами.
        let second = c.secondaryActivity(left: nil, right: nil)
        check(second?.id == "today.next", "авто: встреча за агентом — значком", second?.id ?? "nil")
        check(second.map { c.raiseSecondary($0, left: nil, right: nil) } == true && c.primary?.id == "today.next"
              && c.secondaryActivity(left: nil, right: nil)?.id == "agents.wait", "авто: клик по значку меняет местами")
        c.pin(id: nil)
        c.remove(id: "today.next")
        // Правое ухо — агенты, левое авто: музыка в фоне — значка нет, ничего снаружи.
        check(c.secondaryActivity(left: nil, right: "agents") == nil, "левое авто + правое агенты: музыка без значка")
    }

    private static func physics() {
        var d = SettingsData()
        check(PhysicsPreset.detect(d) == .spring, "физика по умолчанию — «Пружина» (из темы)")
        PhysicsPreset.soft.apply(to: &d, theme: .obsidian)
        check(PhysicsPreset.detect(d) == .soft, "пресет «Мягко»")
        PhysicsPreset.custom.apply(to: &d, theme: .obsidian)
        check(PhysicsPreset.detect(d) == .custom, "«Своя» после «Мягко» видна как «Своя»")
        PhysicsPreset.spring.apply(to: &d, theme: .obsidian)
        check(d.springResponse == nil && d.springDamping == nil, "«Пружина» возвращает значения темы")
    }

    private static func themeFiles() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("si-selftest-themes-\(getpid())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("si-selftest-src-\(getpid()).json")
        defer { try? FileManager.default.removeItem(at: src) }
        let json5 = """
        {
          // своя тема с комментарием
          "id": "selftest-theme", "name": "Тест",
          "accent": "#00FF00",
        }
        """
        try? Data(json5.utf8).write(to: src)
        do {
            let t = try ThemeFiles.importTheme(from: src, into: dir).theme
            let file = dir.appendingPathComponent("selftest-theme.json")
            check(t.id == "selftest-theme" && t.accent == "#00FF00" && FileManager.default.fileExists(atPath: file.path),
                  "импорт JSON5-темы в папку тем")
            let store = ThemeStore(extraDirectories: [dir])
            check(store.theme(id: "selftest-theme") != nil, "импортированная тема видна в списке тем")
        } catch {
            check(false, "импорт JSON5-темы", "\(error)")
        }
        let bad = FileManager.default.temporaryDirectory.appendingPathComponent("si-selftest-bad-\(getpid()).json")
        defer { try? FileManager.default.removeItem(at: bad) }
        try? Data("это не json".utf8).write(to: bad)
        check((try? ThemeFiles.importTheme(from: bad, into: dir)) == nil, "битый файл темы отклоняется")
        // Не тема: JSON-объект без полей темы (package.json и т. п.).
        try? Data(#"{"name": "my-app", "version": "1.0.0", "dependencies": {}}"#.utf8).write(to: bad)
        check((try? ThemeFiles.importTheme(from: bad, into: dir)) == nil, "JSON без полей темы (package.json) отклоняется")
        // Совпадение id со встроенной и с уже импортированной — не перезаписываем, а -2, -3.
        try? Data(##"{"id": "obsidian", "name": "Мой обсидиан", "accent": "#123456"}"##.utf8).write(to: bad)
        if let r = try? ThemeFiles.importTheme(from: bad, into: dir, existingIds: ["obsidian"]) {
            check(r.theme.id == "obsidian-2" && r.renamedFrom == "obsidian"
                  && FileManager.default.fileExists(atPath: dir.appendingPathComponent("obsidian-2.json").path)
                  && !FileManager.default.fileExists(atPath: dir.appendingPathComponent("obsidian.json").path),
                  "id встроенной темы → импорт как obsidian-2", r.theme.id)
            let reread = try? Theme.decode(Data(contentsOf: dir.appendingPathComponent("obsidian-2.json")))
            check(reread?.id == "obsidian-2" && reread?.accent == "#123456", "переименованный файл читается с новым id")
        } else { check(false, "импорт темы с занятым id") }
        if let r = try? ThemeFiles.importTheme(from: src, into: dir, existingIds: ["obsidian"]) {
            check(r.theme.id == "selftest-theme-2", "повторный импорт той же темы → -2, старая не затёрта", r.theme.id)
        } else { check(false, "повторный импорт") }

        do {
            let (copy, url) = try ThemeFiles.makeCopy(of: .obsidian, into: dir, existingIds: ["obsidian", "obsidian-copy"])
            check(copy.id == "obsidian-copy-2" && copy.name.hasPrefix("Обсидиан"), "копия темы: новый id", copy.id)
            let reread = try Theme.decode(Data(contentsOf: url))
            check(reread.id == copy.id && reread.shape == Theme.obsidian.shape, "копия темы читается обратно")
        } catch {
            check(false, "копия темы", "\(error)")
        }
        check(ThemeFiles.sanitize("../evil theme") == "---evil-theme", "id темы не выводит за папку", ThemeFiles.sanitize("../evil theme"))
    }

    private static func hotKey() {
        check(HotKeySpec.defaultToggle.displayString == "⌃⌥Space", "⌃⌥Space по умолчанию", HotKeySpec.defaultToggle.displayString)
        check(GlobalHotKey.carbonModifiers([.control, .option]) == HotKeySpec.defaultToggle.modifiers, "флаги → Carbon")
        check(GlobalHotKey.keyLabel(keyCode: UInt16(kVK_Space), characters: " ") == "Space"
              && GlobalHotKey.keyLabel(keyCode: UInt16(kVK_ANSI_J), characters: "j") == "J", "подписи клавиш")
        let q = GlobalHotKey.keyLabel(keyCode: UInt16(kVK_ANSI_Q), characters: "й")
        check(q == "Q", "подпись по латинской раскладке: русская «й» → Q", q)

        // Системные сочетания: ⌃⌥Space при включённом «Следующий источник ввода» — конфликт.
        let sys = [GlobalHotKey.SystemHotKey(keyCode: 49, modifiers: UInt32(controlKey | optionKey), enabled: true,
                                             name: "Выбрать следующий источник ввода"),
                   GlobalHotKey.SystemHotKey(keyCode: 49, modifiers: UInt32(cmdKey), enabled: false, name: nil)]
        check(GlobalHotKey.systemConflict(for: .defaultToggle, in: sys) == "«Выбрать следующий источник ввода»",
              "⌃⌥Space занято системным сочетанием — видно")
        check(GlobalHotKey.systemConflict(for: HotKeySpec(keyCode: 49, modifiers: UInt32(cmdKey), keyLabel: "Space"), in: sys) == nil,
              "выключенное системное сочетание — не конфликт")
        let live = GlobalHotKey.systemHotKeys()
        print("     системных сочетаний: \(live.count); ⌃⌥Space на этом Маке: \(GlobalHotKey.systemConflict(for: .defaultToggle, in: live) ?? "свободно")")

        // Обработчик принимает только своё сочетание ('SILD', 1); чужое — eventNotHandledErr (дальше по цепочке).
        func event(signature: OSType, id: UInt32) -> EventRef? {
            var ev: EventRef?
            guard CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0, 0, &ev) == noErr, let ev else { return nil }
            var hk = EventHotKeyID(signature: signature, id: id)
            SetEventParameter(ev, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              MemoryLayout<EventHotKeyID>.size, &hk)
            return ev
        }
        let own = event(signature: GlobalHotKey.ownSignature, id: GlobalHotKey.ownId)
        let foreign = event(signature: 0x41474E54, id: 1) // 'AGNT' — горячая клавиша другого модуля
        check(GlobalHotKey.isOwnHotKey(own) && !GlobalHotKey.isOwnHotKey(foreign) && !GlobalHotKey.isOwnHotKey(nil),
              "обработчик различает свою и чужую горячую клавишу")
        if let own { ReleaseEvent(own) }
        if let foreign { ReleaseEvent(foreign) }
        if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option], timestamp: 0,
                                    windowNumber: 0, context: nil, characters: "j", charactersIgnoringModifiers: "j",
                                    isARepeat: false, keyCode: UInt16(kVK_ANSI_J)) {
            check(GlobalHotKey.spec(from: e)?.displayString == "⌥⌘J", "запись сочетания из события",
                  GlobalHotKey.spec(from: e)?.displayString ?? "nil")
        }
        if let plain = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.shift], timestamp: 0,
                                        windowNumber: 0, context: nil, characters: "J", charactersIgnoringModifiers: "j",
                                        isARepeat: false, keyCode: UInt16(kVK_ANSI_J)) {
            check(GlobalHotKey.spec(from: plain) == nil, "без ⌘/⌃/⌥ сочетание не принимается")
        }
        // Настоящая регистрация в Carbon — редкое сочетание, сразу снимается.
        let rare = HotKeySpec(keyCode: UInt32(kVK_F19), modifiers: UInt32(cmdKey | optionKey | controlKey | shiftKey), keyLabel: "F19")
        let st = GlobalHotKey.shared.register(rare)
        check(st == 0 && GlobalHotKey.shared.registered == rare, "RegisterEventHotKey без Универсального доступа", "код \(st)")
        GlobalHotKey.shared.unregister()
        check(GlobalHotKey.shared.registered == nil, "горячая клавиша снимается")
    }

    private static func palettes() {
        let store = ThemeStore(extraDirectories: [SimpleIslandPaths.repoThemes].compactMap { $0 })
        check(store.themes.count >= 17, "темы из design/themes загружены", "\(store.themes.count)")
        for id in ["paper", "sakura"] {
            if let t = store.theme(id: id) {
                check(SettingsPalette(theme: t).light && !SettingsPalette(theme: t, forceDark: true).light,
                      "\(id): светлое окно настроек, тёмный онбординг")
            }
        }
        // Настоящая контрастность (WCAG): текст на окне и подпись на акцентной кнопке — во всех темах.
        for t in store.themes {
            let p = SettingsPalette(theme: t)
            let window = NSColor(p.window)
            let ink = contrast(NSColor(p.ink), window), ink3 = contrast(NSColor(p.ink3), window)
            let onAcc = contrast(NSColor(p.onAccent), NSColor(p.accent))
            check(ink >= 7 && ink3 >= 3 && onAcc >= 2.5, "\(t.id): контраст текста и подписи на акценте",
                  String(format: "текст %.1f, вторичный %.1f, на акценте %.1f", ink, ink3, onAcc))
        }
    }

    private static func contrast(_ fg: NSColor, _ bg: NSColor) -> Double { SettingsPalette.contrast(fg, bg) }

    private static func systemStatus() {
        let pc = PermissionCenter()
        for k in PermissionKind.allCases where k != .automation {
            print("     разрешение \(k.title): \(pc.state(k).text)")
        }
        print("     автоматизация Music: \(PermissionCenter.automationStatus(bundleId: "com.apple.Music").text)")
        check(PermissionKind.allCases.allSatisfy { $0.settingsURL.scheme == "x-apple.systempreferences" },
              "разделы Системных настроек для прав заданы")
        // «Разрешить…»: системный запрос там, где без него приложение не появится в списке раздела.
        typealias P = PermissionCenter
        check(P.plan(.camera, state: .notDetermined, hasUsage: true, runningPlayer: nil, accessibilityPrompted: false) == .systemPrompt
              && P.plan(.calendar, state: .notDetermined, hasUsage: true, runningPlayer: nil, accessibilityPrompted: false) == .systemPrompt,
              "камера/календарь со строкой Info.plist → системный запрос")
        check(P.plan(.camera, state: .notDetermined, hasUsage: false, runningPlayer: nil, accessibilityPrompted: false) == .openSettings,
              "без строки Info.plist (не .app) → только раздел настроек, без падения")
        check(P.plan(.camera, state: .denied, hasUsage: true, runningPlayer: nil, accessibilityPrompted: false) == .openSettings,
              "уже запрещено → раздел настроек")
        check(P.plan(.automation, state: .unknown, hasUsage: true, runningPlayer: "com.apple.Music", accessibilityPrompted: false)
              == .automationPrompt(bundleId: "com.apple.Music"), "автоматизация: Music запущен → запрос к нему")
        check(P.plan(.automation, state: .unknown, hasUsage: true, runningPlayer: nil, accessibilityPrompted: false) == .openSettings,
              "автоматизация: плеер не запущен → раздел и подсказка")
        check(P.plan(.accessibility, state: .notDetermined, hasUsage: true, runningPlayer: nil, accessibilityPrompted: false) == .systemPrompt
              && P.plan(.accessibility, state: .notDetermined, hasUsage: true, runningPlayer: nil, accessibilityPrompted: true) == .openSettings,
              "универсальный доступ: сначала одно окно запроса, повторно — раздел")
        print("     строки Info.plist у этого процесса: \(P.usageKeys.values.sorted().map { "\($0)=\(Bundle.main.object(forInfoDictionaryKey: $0) != nil ? "есть" : "нет")" }.joined(separator: ", "))")
        let li = LoginItem()
        print("     автозапуск: \(li.statusText) (из .app: \(li.isBundled ? "да" : "нет"))")
        check(true, "статусы прав и автозапуска читаются без падений")
    }
}
