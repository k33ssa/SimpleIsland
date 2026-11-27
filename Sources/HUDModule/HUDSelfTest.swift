import AppKit
import Darwin
import AudioToolbox
import CoreAudio
import SwiftUI
import IslandCore

/// Самотест модуля без экрана: `SimpleIsland --selftest-hud`. Систему не меняет (громкость/яркость только
/// читаются), GUI не открывает. Код возврата 0 — все проверки прошли.
@MainActor
public enum HUDSelfTest {
    private static var failures = 0
    private static var passes = 0

    private static func check(_ ok: Bool, _ what: String) {
        if ok { passes += 1; print("PASS  \(what)") } else { failures += 1; print("FAIL  \(what)") }
    }
    private static func info(_ s: String) { print("INFO  \(s)") }

    public static func run(_ args: [String]) -> Int32 {
        _ = NSApplication.shared
        pure()
        widths(args)
        fillAroundNotch()
        powerFollowUp()
        networkDebounce()
        tapLogic()
        live()
        micVsPlayback()
        moduleLifecycle()
        bluetoothLogic()
        profilerRuns()
        systemEvents()
        idleWakeups()
        print("\nHUD selftest: \(passes) passed, \(failures) failed")
        return failures == 0 ? 0 : 1
    }

    // MARK: Заливка и вырез

    /// HUD «Заливка» на Маке с вырезом (16.11, живой скрин «Заряжается 63 %»: край уровня ушёл под вырез).
    /// Шкала идёт по видимым крыльям: край уровня и его кромка никогда не лежат в зоне выреза, уровень растёт
    /// монотонно, 50 % — ровно полное левое крыло, без выреза — линейно. Слой во всю форму (с ушами) — 0 % пусто,
    /// 100 % до внешнего края.
    private static func fillAroundNotch() {
        let ew = HUDFillBackground.edgeWidth
        var underNotch: [String] = [], nonMonotonic: [String] = []
        for notch: CGFloat in [160, 185, 186, 200, 230] {
            for side: CGFloat in [HUDMeasure.minSide, 120, 132, 160, HUDMeasure.maxSide] {
                let w = 2 * side + notch, nl = side, nr = side + notch
                var prev: CGFloat = -1
                for p in 0...1000 {
                    let v = Double(p) / 1000
                    let x = HUDFillBackground.edgeX(value: v, width: w, notch: notch)
                    // Край (и кромка шириной `edgeWidth` слева от него) — целиком на виду.
                    if v > 0, v < 1, x > nl + 0.001, x - ew < nr - 0.001 {
                        underNotch.append("вырез \(Int(notch)) ухо \(Int(side)) \(p / 10)% → \(x)")
                    }
                    if x < prev - 0.001 { nonMonotonic.append("\(Int(notch))/\(Int(side)) \(p / 10)%") }
                    prev = x
                }
                if abs(HUDFillBackground.edgeX(value: 0.5, width: w, notch: notch) - nl) > 0.001 {
                    underNotch.append("50 % ≠ левое крыло (\(Int(notch))/\(Int(side)))")
                }
            }
        }
        check(underNotch.isEmpty, "заливка: край уровня 0–100 % не попадает в зону выреза"
              + (underNotch.isEmpty ? "" : " — \(underNotch.prefix(3).joined(separator: "; "))"))
        check(nonMonotonic.isEmpty, "заливка: край растёт монотонно, через вырез — скачком")
        check(HUDFillBackground.edgeX(value: 0, width: 600, notch: 186) == 0
              && HUDFillBackground.edgeX(value: 1, width: 600, notch: 186) == 600
              && HUDFillBackground.edgeX(value: 0.63, width: 600, notch: 0) == 378
              && HUDFillBackground.edgeX(value: .nan, width: 600, notch: 186) == 0,
              "заливка: 0 % / 100 % — края, без выреза — линейно, NaN — пусто")
        // 63 % у живого скрина: ухо 132, вырез 185 → край в правом крыле, справа от выреза.
        let x63 = HUDFillBackground.edgeX(value: 0.63, width: 2 * 132 + 185, notch: 185)
        check(x63 >= 132 + 185 + ew, "заливка 63 %: край справа от выреза (\(Int(x63)) pt)")
        // Слой во всю форму: уши залиты по краям, а не чёрная кромка.
        let ear: CGFloat = 8, ow = 2 * 132 + 185 + 2 * ear
        check(HUDFillBackground.outerEdgeX(value: 1, outerWidth: ow, notch: 185, ear: ear) == ow
              && HUDFillBackground.outerEdgeX(value: 0, outerWidth: ow, notch: 185, ear: ear) == 0
              && HUDFillBackground.outerEdgeX(value: 0.5, outerWidth: ow, notch: 185, ear: ear) == ear + 132,
              "заливка во всю форму: 100 % — до внешнего края ушей, 50 % — до выреза, 0 % — пусто")
        // Настоящие вспышки батареи с вырезом этого Мака: край не под вырезом и не режет текст справа.
        var bad: [String] = []
        for notch: CGFloat in [185, 186] {
            for pct in stride(from: 1, through: 99, by: 1) {
                let e = HUDFlashes.charging(percent: pct, minutesToFull: 84, isCharging: true, theme: .obsidian, notch: notch)
                let w = 2 * e.sideWidth + notch
                let x = HUDFillBackground.edgeX(value: e.value ?? 0, width: w, notch: notch)
                if x > e.sideWidth + 0.001, x - ew < e.sideWidth + notch - 0.001 { bad.append("\(pct)% под вырезом") }
                let tw = HUDMeasure.text(e.valueText ?? "", weight: .bold, theme: .obsidian, digits: true)
                let textStart = w - HUDMeasure.outerInset - tw
                let clearable = 2 * (1 - (e.value ?? 0)) * HUDMeasure.maxSide >= tw + HUDMeasure.outerInset + 6
                if x > textStart - 2, x < w - HUDMeasure.outerInset + 2, clearable {
                    bad.append("\(pct)% режет «\(e.valueText ?? "")»")
                }
            }
        }
        check(bad.isEmpty, "зарядка 1–99 % с вырезом 185/186: край виден и не режет текст"
              + (bad.isEmpty ? "" : " — \(bad.prefix(4).joined(separator: "; "))"))
    }

    // MARK: Чистая логика

    private static func pure() {
        // Шаг 1/16 и 1/64, прилипание к сетке, границы.
        check(HUDStep.apply(0.5, up: true, fine: false) == 9.0 / 16, "шаг громкости +1/16")
        check(HUDStep.apply(0.5, up: false, fine: false) == 7.0 / 16, "шаг громкости −1/16")
        check(HUDStep.apply(0.5, up: true, fine: true) == 33.0 / 64, "мелкий шаг ⌥⇧ +1/64")
        check(HUDStep.apply(1, up: true, fine: false) == 1, "верхняя граница 1")
        check(HUDStep.apply(0, up: false, fine: false) == 0, "нижняя граница 0")
        check(HUDStep.apply(0.52, up: true, fine: false) == 9.0 / 16, "между делениями — до ближайшего вверх")
        check(HUDStep.apply(0.52, up: false, fine: false) == 8.0 / 16, "между делениями — до ближайшего вниз")

        // Разбор NX_SYSDEFINED.
        var allOK = true
        for k in MediaKey.allCases {
            for down in [true, false] {
                let d1 = MediaKeyEvent.data1(key: k, down: down)
                let e = MediaKeyEvent.decode(subtype: 8, data1: d1, flags: [])
                if e?.key != k || e?.isDown != down || e?.isRepeat != false { allOK = false }
            }
        }
        check(allOK, "data1: все 7 клавиш, нажатие/отпускание")
        check(MediaKeyEvent.decode(subtype: 8, data1: MediaKeyEvent.data1(key: .soundUp, down: true, repeating: true),
                                   flags: [])?.isRepeat == true, "data1: автоповтор")
        check(MediaKeyEvent.decode(subtype: 7, data1: MediaKeyEvent.data1(key: .soundUp, down: true), flags: []) == nil,
              "подтип ≠ 8 игнорируется")
        // work/keys: плей/пауза (16) теперь разбирается — её решает «Медиа» через мост ядра; незнакомый код — нет.
        check(MediaKeyEvent.decode(subtype: 8, data1: (16 << 16) | (0xA << 8), flags: [])?.key == .play
              && MediaKeyEvent.decode(subtype: 8, data1: (12 << 16) | (0xA << 8), flags: []) == nil,
              "плей/пауза (16) разобрана как транспорт, незнакомый код (12) — нет")
        let fine = MediaKeyEvent.decode(subtype: 8, data1: MediaKeyEvent.data1(key: .soundUp, down: true),
                                        flags: [.maskAlternate, .maskShift])
        check(fine?.fine == true && fine?.optionOnly == false, "⌥⇧ — мелкий шаг")
        let opt = MediaKeyEvent.decode(subtype: 8, data1: MediaKeyEvent.data1(key: .brightnessUp, down: true),
                                       flags: [.maskAlternate])
        check(opt?.optionOnly == true, "только ⌥ — отдаём системе")

        // Питание: события по переходам.
        let base = PowerSnapshot(hasBattery: true, onAC: false, isCharging: false, isCharged: false, percent: 50,
                                 minutesToFull: nil, minutesToEmpty: 200)
        var plugged = base; plugged.onAC = true; plugged.isCharging = true
        check(PowerWatcher.diff(old: base, new: plugged) == [.pluggedIn], "питание: подключили")
        check(PowerWatcher.diff(old: plugged, new: base) == [.unplugged], "питание: отключили")
        var full = plugged; full.isCharged = true; full.isCharging = false
        check(PowerWatcher.diff(old: plugged, new: full) == [.charged], "питание: заряжено")
        var b21 = base; b21.percent = 21
        var b20 = base; b20.percent = 20
        var b11 = base; b11.percent = 11
        var b10 = base; b10.percent = 10
        check(PowerWatcher.diff(old: b21, new: b20) == [.low(20)], "питание: 20 %")
        check(PowerWatcher.diff(old: b11, new: b10) == [.low(10)], "питание: 10 %")
        check(PowerWatcher.diff(old: b20, new: b20).isEmpty, "питание: без перехода — тишина")
        var timeOnly = plugged; timeOnly.minutesToFull = 40
        check(PowerWatcher.diff(old: plugged, new: timeOnly).isEmpty, "питание: смена времени — тишина")
        check(PowerWatcher.diff(old: nil, new: base).isEmpty, "питание: первое чтение — тишина")

        // Раскладка.
        check(InputWatcher.shortCode(languages: ["ru"], sourceID: "com.apple.keylayout.Russian") == "RU", "код RU")
        check(InputWatcher.shortCode(languages: ["en-US"], sourceID: "com.apple.keylayout.US") == "EN", "код EN")
        check(InputWatcher.shortCode(languages: [], sourceID: "com.apple.keylayout.ABC") == "EN", "код ABC → EN")

        // Тексты.
        check(HUDFlashes.duration(minutes: 34) == "34 мин" && HUDFlashes.duration(minutes: 312) == "5 ч 12 мин"
              && HUDFlashes.duration(minutes: 120) == "2 ч", "время до полной/пустой")
        check(HUDFlashes.plausibleMinutes(1200) == nil && HUDFlashes.plausibleMinutes(34) == 34
              && HUDFlashes.plausibleMinutes(-1) == nil, "время IOPS: неправдоподобное отбрасывается")
        check(HeadphonesBattery(left: 82, right: 80, caseLevel: 54).text == "L 82% · R 80% · кейс 54%", "заряд AirPods")
        check(HeadphonesBattery().text == nil, "нет заряда — без текста")
        let two = HeadphonesBattery(left: 82, right: 80, caseLevel: 54).lines
        check(two?.top == "L 82% · R 80%" && two?.bottom == "кейс 54%", "заряд AirPods в две строки: L/R и кейс")
        check(HeadphonesBattery(single: 64).lines.map { $0.top == "64%" && $0.bottom == nil } == true,
              "один заряд — одна строка")
        check(HeadphonesBattery(caseLevel: 54).lines.map { $0.top == "кейс 54%" && $0.bottom == nil } == true,
              "только кейс — одна строка")
        check(HeadphonesBattery().lines == nil, "нет заряда — правой части нет")
        let pods = HUDFlashes.headphonesConnected(name: "AirPods Pro", battery: HeadphonesBattery(left: 82, right: 80, caseLevel: 54))
        check(pods.body == "Подключены" && pods.trailing != nil && pods.spokenDescription.contains("кейс 54%"),
              "карточка AirPods: справа заряд, VoiceOver его читает")
        let sony = HUDFlashes.headphonesConnected(name: "Sony WH-1000XM5", battery: nil)
        check(sony.trailing == nil && sony.body == "Подключены", "карточка без заряда — без правой части")

        // Заряд через system_profiler (без приватных прав): разбор и поиск по адресу/имени.
        let profilerJSON = #"""
        {"SPBluetoothDataType":[{"controller_properties":{},
          "device_connected":[{"AirPods Pro":{"device_address":"A1:B2:C3:D4:E5:F6","device_batteryLevelCase":"54%",
            "device_batteryLevelLeft":"82%","device_batteryLevelRight":"80 %","device_minorType":"Headphones"}},
            {"Magic Mouse":{"device_address":"11:22:33:44:55:66","device_batteryLevelMain":"71%"}},
            {"JBL Flip 6":{"device_address":"77:88:99:AA:BB:CC"}}],
          "device_not_connected":[{"Старые":{"device_address":"00:00:00:00:00:01","device_batteryLevelMain":"50%"}}]}]}
        """#
        let entries = BluetoothProfiler.parse(Data(profilerJSON.utf8))
        check(entries.count == 2 && entries.first { $0.name == "AirPods Pro" }?.battery
                == HeadphonesBattery(left: 82, right: 80, caseLevel: 54),
              "system_profiler: заряд L/R/кейс подключённых, без заряда и неподключённые — мимо")
        check(BluetoothProfiler.find(in: entries, name: "другое имя", address: "a1-b2-c3-d4-e5-f6")?.left == 82,
              "system_profiler: поиск по адресу «aa-bb-…» ↔ «AA:BB:…»")
        check(BluetoothProfiler.find(in: entries, name: "Magic Mouse", address: nil)?.single == 71
              && BluetoothProfiler.find(in: entries, name: "JBL Flip 6", address: nil) == nil
              && BluetoothProfiler.parse(Data("не json".utf8)).isEmpty,
              "system_profiler: поиск по имени; нет заряда / мусор — nil")

        // Яркость: «авто» при автояркости.
        let auto = HUDFlashes.brightness(0.8, auto: true, style: .thread, theme: .obsidian)
        let manual = HUDFlashes.brightness(0.8, style: .thread, theme: .obsidian)
        check(auto.label == "авто" && manual.label == nil && auto.spokenDescription.contains("автоматически"),
              "яркость: подпись «авто» только при автояркости")
        // Громкость сегментами — 16 делений; ухо под них, и когда стиль берётся из настроек.
        let seg16: CGFloat = HUDFlashes.barWidth(.segments, theme: .obsidian)
        let seg10: CGFloat = HUDFlashes.barWidth(.segments, segments: 10, theme: .obsidian)
        check(seg16 == CGFloat(125) && seg10 == CGFloat(77), "сегменты: громкость 16 (125 pt), подсветка 10 (77 pt)")
        let segVol = HUDFlashes.volume(0.62, muted: false, device: "AirPods Pro", style: nil, fallback: .segments, theme: .obsidian)
        let segNeed: CGFloat = seg16 + HUDMeasure.outerInset + HUDMeasure.notchGap
        check(segVol.segments == 16 && segVol.sideWidth >= segNeed,
              "громкость сегментами из настроек: ухо вмещает 16 делений (\(Int(segVol.sideWidth)) pt)")
        // Ядро не рисует больше сегментов, чем влезает в ухо (событие без своей ширины — 120 pt — не залезает под вырез).
        let segKbd = HUDFlashes.keyboard(0.6, style: .segments, theme: .obsidian)
        check(HUDTrailing.fittingSegments(16, sideWidth: 120) == 12 && HUDTrailing.fittingSegments(16, sideWidth: 145) == 16
              && HUDTrailing.fittingSegments(10, sideWidth: 120) == 10 && HUDTrailing.fittingSegments(16, sideWidth: 10) == 1
              && HUDTrailing.fittingSegments(40, sideWidth: 400) == 16,
              "ядро: сегментов не больше, чем влезает в ухо (120 pt → 12, 145 pt → 16), потолок 16, минимум 1")
        check(HUDTrailing.fittingSegments(segVol.segments, sideWidth: segVol.sideWidth) == 16
              && HUDTrailing.fittingSegments(segKbd.segments, sideWidth: segKbd.sideWidth) == 10,
              "вспышки модуля: громкость — все 16 делений, подсветка — 10 (ширина уха своя)")
        let defaultEvent = HUDEvent(kind: "volume", value: 0.5)
        let fit = CGFloat(HUDTrailing.fittingSegments(defaultEvent.segments, sideWidth: defaultEvent.sideWidth))
        check(fit * 5 + (fit - 1) * 3 + 12 + 8 <= defaultEvent.sideWidth,
              "событие по умолчанию (16 сегментов, ухо \(Int(defaultEvent.sideWidth)) pt): полоса \(Int(fit * 8 - 3)) pt влезает")
        let charging = HUDFlashes.charging(percent: 78, minutesToFull: 34, isCharging: true, theme: .obsidian)
        check(charging.style == .fill && charging.valueText == "78% · 34 мин" && charging.value == 0.78, "вспышка зарядки")

        // Настройки: недостающие поля — по умолчанию, неизвестные игнорируются.
        let partial = #"{"vpn": false, "network": false, "replaceSystemHUD": true, "unknown": 1}"#.data(using: .utf8)!
        let p = try? JSONDecoder().decode(HUDPrefs.self, from: partial)
        check(p?.network == false && p?.replaceSystemHUD == true && p?.volume == true && p?.keyboardSegments == true,
              "настройки: частичный JSON, старый ключ «vpn» игнорируется")
        let empty = try? JSONDecoder().decode(HUDPrefs.self, from: Data("{}".utf8))
        check(empty?.replaces(axGranted: true) == true && empty?.replaces(axGranted: false) == false,
              "замена системных индикаторов по умолчанию: есть Универсальный доступ — включена, нет — выключена")
        // У пользователя 15.11 в settings.json записано "replaceSystemHUD": false (модуль сохраняет настройки целиком)
        // — это не выбор: с доступом замена включается.
        let saved = try? JSONDecoder().decode(HUDPrefs.self, from: Data(#"{"replaceSystemHUD": false, "volume": true}"#.utf8))
        check(saved?.replaces(axGranted: true) == true, "старый сохранённый false без выбора — не мешает включиться")
        var chosen = HUDPrefs()
        chosen.setReplaces(false)
        let round = (try? JSONEncoder().encode(chosen)).flatMap { try? JSONDecoder().decode(HUDPrefs.self, from: $0) }
        check(round?.replaces(axGranted: true) == false && round?.replaceSystemHUDChosen == true,
              "пользователь выключил сам — выключено и после перезапуска")
        chosen.setReplaces(true)
        check(chosen.replaces(axGranted: false) == true, "включил сам без доступа — режим замены ждёт доступа (tap без права не создаётся)")

        // Все SF Symbols, что рисуем, существуют.
        let symbols = ["speaker.slash.fill", "speaker.fill", "speaker.wave.1.fill", "speaker.wave.2.fill",
                       "speaker.wave.3.fill", "sun.min.fill", "sun.max.fill", "light.min", "light.max", "bolt.fill",
                       "powerplug.fill", "battery.100percent.bolt", "battery.0percent", "battery.25percent",
                       "battery.50percent", "battery.75percent", "battery.100percent", "airpods", "airpodspro",
                       "airpodsmax", "beats.headphones", "headphones", "globe", "keyboard", "camera", "arrow.right", "capslock",
                       "capslock.fill", "camera.fill", "mic.fill", "lock.shield.fill", "lock.open.fill", "wifi",
                       "wifi.slash", "cable.connector", "network"]
        let missing = symbols.filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil }
        check(missing.isEmpty, "SF Symbols на месте" + (missing.isEmpty ? "" : ": нет \(missing)"))
    }

    // MARK: Ширина ушей по шрифту темы

    private static func widths(_ args: [String]) {
        var dirs: [URL] = []
        for (i, a) in args.enumerated() where a == "--themes-dir" && i + 1 < args.count {
            dirs.append(URL(fileURLWithPath: args[i + 1]))
        }
        if dirs.isEmpty, let repo = SimpleIslandPaths.repoThemes {
            dirs.append(repo)
        }
        let themes = ThemeStore(extraDirectories: dirs, load: true).themes
        info("тем для проверки ширины: \(themes.count)")
        let mono = themes.first { $0.font.family == .mono } ?? .obsidian
        check(mono.font.family == .mono, "есть моноширинная тема для проверки (\(mono.id))")
        check(HUDMeasure.text("Динамики MacBook Pro", theme: mono) > HUDMeasure.text("Динамики MacBook Pro", theme: .obsidian),
              "моноширинная тема — подпись шире, чем в системном шрифте")

        let room = HUDMeasure.outerInset + HUDMeasure.notchGap
        var bad: [String] = []
        for t in themes {
            func lead(_ e: HUDEvent) -> CGFloat {
                HUDMeasure.symbol(e.systemImage) + (e.label.map { 7 + HUDMeasure.text($0, theme: t) } ?? 0)
            }
            for name in ["AirPods Pro", "Динамики MacBook Pro", "Внешние динамики LG UltraFine 5K Display"] {
                for muted in [false, true] {
                    let e = HUDFlashes.volume(0.5, muted: muted, device: name, style: nil, theme: t)
                    if lead(e) + room > e.sideWidth + 0.5 { bad.append("\(t.id): громкость «\(name)»") }
                    if muted, HUDMeasure.text(e.valueText ?? "", weight: .bold, theme: t) + room > e.sideWidth + 0.5 {
                        bad.append("\(t.id): «без звука»")
                    }
                }
            }
            for e in [HUDFlashes.charging(percent: 78, minutesToFull: 34, isCharging: true, theme: t),
                      HUDFlashes.unplugged(percent: 64, minutesToEmpty: 312, theme: t),
                      HUDFlashes.lowBattery(percent: 10, theme: t)] {
                let lw = HUDMeasure.symbol(e.systemImage) + 7 + HUDMeasure.text(e.label ?? "", weight: .bold, theme: t)
                let tw = HUDMeasure.text(e.valueText ?? "", weight: .bold, theme: t, digits: true)
                if max(lw, tw) + room > e.sideWidth + 0.5 { bad.append("\(t.id): батарея «\(e.valueText ?? "")»") }
                // Край заливки не режет текст справа (если ухо для этого не вышло бы за максимум).
                let w = 2 * e.sideWidth + HUDMeasure.defaultNotch
                let edge = HUDFillBackground.edgeX(value: e.value ?? 0, width: w, notch: HUDMeasure.defaultNotch)
                let textStart = w - HUDMeasure.outerInset - tw
                // Не освободить и ухом максимальной ширины (правое крыло короче всего острова: 2·(1 − v)·ухо) —
                // край ложится под текст, это допустимо (как 90+ % раньше).
                let clearable = 2 * (1 - (e.value ?? 0)) * HUDMeasure.maxSide >= tw + HUDMeasure.outerInset + 6
                if edge > textStart - 2, edge < w - HUDMeasure.outerInset + 2, clearable {
                    bad.append("\(t.id): край заливки по тексту «\(e.valueText ?? "")»")
                }
            }
            let h = HUDFlashes.headphonesDisconnected(name: "AirPods Pro Максима", theme: t)
            let hl = HUDFlashes.tagWidth("AirPods Pro Максима", symbol: "airpodspro", theme: t)
            if hl + room > h.sideWidth + 0.5, h.sideWidth < HUDMeasure.maxSide { bad.append("\(t.id): наушники") }
            let n = HUDFlashes.network(online: false, interface: nil, theme: t)
            if max(HUDFlashes.tagWidth("Нет сети", symbol: "wifi.slash", theme: t),
                   HUDFlashes.noteWidth("проверь Wi-Fi", theme: t)) + room > n.sideWidth + 0.5 {
                bad.append("\(t.id): Нет сети")
            }
            for style in HUDBarStyle.allCases {
                let e = HUDFlashes.volume(0.62, muted: false, device: "AirPods Pro", style: style, theme: t)
                if HUDFlashes.barWidth(style, theme: t) + room > e.sideWidth + 0.5 { bad.append("\(t.id): полоса \(style)") }
            }
            let ba = HUDFlashes.brightness(0.8, auto: true, style: nil, theme: t)
            if HUDMeasure.symbol(ba.systemImage) + 7 + HUDMeasure.text("авто", theme: t) + room > ba.sideWidth + 0.5 {
                bad.append("\(t.id): яркость «авто»")
            }
        }
        check(bad.isEmpty, "ширина ушей: зазор у выреза ≥ \(Int(HUDMeasure.notchGap)) pt во всех темах"
              + (bad.isEmpty ? "" : ": \(bad.prefix(6))"))
        let long = HUDFlashes.volume(0.5, muted: false, device: "Внешние динамики LG UltraFine 5K Display", style: nil,
                                     theme: mono)
        check(long.sideWidth <= HUDMeasure.maxSide && (long.label ?? "").hasSuffix("…"),
              "слишком длинное имя — ухо не шире \(Int(HUDMeasure.maxSide)), подпись с «…» (\(long.label ?? ""))")
        let muted = HUDFlashes.volume(0.5, muted: true, device: "AirPods", style: nil, theme: .obsidian)
        check(muted.value == nil && muted.valueText == "без звука", "без звука — «без звука», а не «0»")
    }

    // MARK: Уточнение вспышки зарядки

    private static func powerFollowUp() {
        let w = PowerWatcher()
        var got: [PowerEvent] = []
        w.onEvent = { e, _ in got.append(e) }
        let t0 = Date()
        let onBattery = PowerSnapshot(hasBattery: true, onAC: false, isCharging: false, isCharged: false, percent: 78,
                                      minutesToFull: nil, minutesToEmpty: 200)
        var plugged = onBattery; plugged.onAC = true; plugged.minutesToEmpty = nil   // время ещё «считается»
        var withTime = plugged; withTime.isCharging = true; withTime.minutesToFull = 34
        w.handle(onBattery, at: t0)
        w.handle(plugged, at: t0.addingTimeInterval(1))
        w.handle(withTime, at: t0.addingTimeInterval(4))
        check(got == [.pluggedIn, .chargingDetails], "зарядка: время пришло через 3 с — вспышка уточняется")
        var later = withTime; later.minutesToFull = 33
        w.handle(later, at: t0.addingTimeInterval(5))
        check(got.count == 2, "зарядка: уточнение одно на подключение")

        got = []
        w.handle(onBattery, at: t0.addingTimeInterval(20))
        w.handle(plugged, at: t0.addingTimeInterval(21))
        w.handle(withTime, at: t0.addingTimeInterval(21 + PowerWatcher.detailsWindow + 1))
        check(got == [.unplugged, .pluggedIn], "зарядка: позже 10 с — без повторной вспышки")

        got = []
        w.handle(onBattery, at: t0.addingTimeInterval(40))
        w.handle(withTime, at: t0.addingTimeInterval(41))
        w.handle(later, at: t0.addingTimeInterval(42))
        check(got == [.unplugged, .pluggedIn], "зарядка: время было сразу — уточнять нечего")
    }

    // MARK: Сеть: сон, дребезг

    private static func networkDebounce() {
        let n = NetworkWatcher()
        var flashes: [String] = []
        n.onNetwork = { ok, _ in flashes.append(ok ? "online" : "offline") }
        n.startForTest()
        func spin(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        n.pathChanged(online: true, interface: "Wi-Fi")
        n.pathChanged(online: false, interface: nil)
        spin(0.3)
        n.pathChanged(online: true, interface: "Wi-Fi")
        spin(NetworkWatcher.lossDelay + 0.3)
        check(flashes.isEmpty, "сеть пропала на миг — ни одной вспышки")

        n.pathChanged(online: false, interface: nil)
        spin(NetworkWatcher.lossDelay + 0.3)
        n.pathChanged(online: true, interface: "Wi-Fi")
        check(flashes == ["offline", "online"], "сеть пропала дольше 3 с — «Нет сети», потом «Сеть есть»")

        flashes = []
        n.willSleep()
        n.pathChanged(online: false, interface: nil)
        n.didWake()
        n.pathChanged(online: true, interface: "Wi-Fi")
        spin(NetworkWatcher.lossDelay + 0.3)
        check(flashes.isEmpty && n.isQuiet, "сон и пробуждение — тишина (Wi-Fi переподключается)")

        // Вне тишины: смена интерфейса — вспышка с новым.
        n.now = { Date().addingTimeInterval(NetworkWatcher.wakeQuiet + 1) }
        n.pathChanged(online: true, interface: "Ethernet")
        check(flashes == ["online"], "сеть: Wi-Fi → Ethernet — одна вспышка")
        n.stop()
        check(n.pendingWorkCount == 0, "сеть: stop() снимает отложенные вспышки и конец тишины")
    }

    // MARK: Логика tap без настоящего tap

    private static func tapLogic() {
        let tap = MediaKeyTap()
        var seen: [MediaKeyEvent] = []
        tap.handler = { e in seen.append(e); return e.key.isVolume }
        tap.setModeForTest(.active)
        let down = MediaKeyEvent(key: .soundUp, isDown: true, isRepeat: false, fine: false, optionOnly: false)
        let up = MediaKeyEvent(key: .soundUp, isDown: false, isRepeat: false, fine: false, optionOnly: false)
        check(tap.route(down) == true, "активный режим: наше нажатие глотается")
        check(tap.route(up) == true, "активный режим: отпускание проглоченной тоже глотается")
        let bd = MediaKeyEvent(key: .brightnessUp, isDown: true, isRepeat: false, fine: false, optionOnly: false)
        let bu = MediaKeyEvent(key: .brightnessUp, isDown: false, isRepeat: false, fine: false, optionOnly: false)
        check(tap.route(bd) == false && tap.route(bu) == false, "активный режим: чужая клавиша проходит системе")
        tap.setModeForTest(.listen)
        check(tap.route(down) == false && tap.route(up) == false, "режим наблюдения: ничего не глотаем")
        check(seen.filter(\.isDown).count == 3, "обработчик видит каждое нажатие")

        // Настоящее CGEvent NX_SYSDEFINED через process().
        tap.setModeForTest(.active)
        if let ns = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: 0xA00),
                                       timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                                       data1: MediaKeyEvent.data1(key: .soundDown, down: true), data2: -1),
           let cg = ns.cgEvent {
            let swallowed = tap.process(type: CGEventType(rawValue: 14)!, event: cg)
            check(swallowed && seen.last?.key == .soundDown, "CGEvent NX_SYSDEFINED разобран и проглочен")
            let before = tap.reenableCount
            _ = tap.process(type: .tapDisabledByTimeout, event: cg)
            check(tap.reenableCount == before + 1, "kCGEventTapDisabledByTimeout обработан (tap включается обратно)")
        } else {
            check(false, "не удалось синтезировать NX_SYSDEFINED")
        }
        tap.setModeForTest(nil)
        mediaTransport()
    }

    /// Медиаклавиши ⏯ ⏭ ⏮: разбор кодов 16–20, путь HUD → мост ядра → «Медиа» (заглушка), отпускание.
    private static func mediaTransport() {
        let codes: [(Int, MediaKey, MediaTransportKey)] = [(16, .play, .playPause), (17, .next, .next), (18, .previous, .previous),
                                                           (19, .fast, .next), (20, .rewind, .previous)]
        var ok = true
        for (code, key, t) in codes {
            let d = MediaKeyEvent.decode(subtype: 8, data1: (code << 16) | (0xA << 8), flags: [])
            let u = MediaKeyEvent.decode(subtype: 8, data1: (code << 16) | (0xB << 8) | 1, flags: [])
            ok = ok && d?.key == key && d?.isDown == true && u?.isDown == false && u?.isRepeat == true && key.transport == t
        }
        check(ok, "медиаклавиши: коды PLAY 16, NEXT 17, PREVIOUS 18, FAST 19, REWIND 20 разобраны; FAST ≡ вперёд, REWIND ≡ назад")
        check(MediaKey.soundUp.transport == nil && MediaKey.brightnessUp.transport == nil, "медиаклавиши: громкость/яркость — не транспорт")

        let (ctx, hud, _) = makeContext()
        let m = HUDIslandModule()
        let router = MediaKeyRouter()
        m.router = router
        m.start(context: ctx)
        var got: [MediaTransportPress] = []
        var take = true
        router.register(owner: "media", wants: true) { p in got.append(p); return take }
        m.tap.setModeForTest(.active)
        let down = MediaKeyEvent(key: .play, isDown: true, isRepeat: false, fine: false, optionOnly: false)
        let rep = MediaKeyEvent(key: .play, isDown: true, isRepeat: true, fine: false, optionOnly: false)
        let up = MediaKeyEvent(key: .play, isDown: false, isRepeat: false, fine: false, optionOnly: false)
        check(m.tap.route(down) && m.tap.route(rep) && m.tap.route(up), "медиаклавиши: «Медиа» взяла ⏯ → нажатие, повтор и отпускание проглочены")
        check(got.map(\.phase) == [.down, .repeating, .up] && got.allSatisfy { $0.key == .playPause },
              "медиаклавиши: мост получил нажатие, повтор и отпускание")
        take = false; got = []
        let nd = MediaKeyEvent(key: .fast, isDown: true, isRepeat: false, fine: false, optionOnly: false)
        let nu = MediaKeyEvent(key: .fast, isDown: false, isRepeat: false, fine: false, optionOnly: false)
        check(!m.tap.route(nd) && !m.tap.route(nu) && got.map(\.phase) == [.down], "медиаклавиши: «Медиа» отказалась → системе, отпускание тоже")
        m.tap.setModeForTest(.listen)
        got = []
        check(!m.tap.route(down) && !m.tap.route(up) && got.isEmpty, "медиаклавиши: режим наблюдения — мост не зовём, ничего не глотаем")
        m.tap.setModeForTest(nil)
        // Tap активный только ради медиаклавиш (замена системного HUD выключена) — громкость не трогаем.
        if let model = m.settingsModelForTest {
            var p = model.prefs; p.setReplaces(false); model.prefs = p
        }
        m.tap.setModeForTest(.active)
        let vol = MediaKeyEvent(key: .soundUp, isDown: true, isRepeat: false, fine: false, optionOnly: false)
        check(m.handleKey(vol) == false && hud.current == nil, "медиаклавиши: tap активный ради музыки, замена выкл. — громкость системе")
        m.tap.setModeForTest(nil)
        router.unregister(owner: "media")
        m.stop()
    }

    // MARK: Живые чтения (только чтение)

    private static func live() {
        let dev = AudioWatcher.defaultOutputDevice()
        check(dev != 0, "CoreAudio: устройство вывода есть")
        info("вывод: \(AudioWatcher.name(dev) ?? "?"), громкость \(AudioWatcher.volume(dev).map { String(format: "%.3f", $0) } ?? "—"), "
             + "mute \(AudioWatcher.muted(dev).map { "\($0)" } ?? "—"), транспорт \(AudioWatcher.transport(dev).map { fourCC($0) } ?? "—")")

        // Перевесить слушатели на другое устройство вывода и обратно (баг boring.notch).
        let w = AudioWatcher()
        w.start()
        check(w.boundDevice == dev && w.listenerCount >= 2, "CoreAudio: слушатели на устройстве и system object (\(w.listenerCount))")
        info("можно менять громкость: \(w.canSetVolume())")
        let outputs = AudioWatcher.allDevices().filter { $0 != dev && AudioWatcher.hasStreams($0, scope: kAudioObjectPropertyScopeOutput) }
        if let other = outputs.first {
            w.rebind(to: other)
            check(w.boundDevice == other, "смена устройства: слушатели перевешены на «\(AudioWatcher.name(other) ?? "?")»")
            w.rebind(to: dev)
            check(w.boundDevice == dev, "смена устройства: и обратно")
        } else {
            info("другого устройства вывода нет — перевес проверен только на одном")
        }
        w.stop()
        check(w.listenerCount == 0 && w.removeFailures == 0, "CoreAudio: stop() снимает все слушатели, система подтвердила")

        let d = DisplayBrightness.shared
        info("DisplayServices: символы \(d.hasSymbols), встроенный экран \(DisplayBrightness.builtinDisplay().map { "\($0)" } ?? "нет"), "
             + "доступна \(d.isAvailable), яркость \(d.get().map { String(format: "%.3f", $0) } ?? "—")")
        check(d.hasSymbols, "DisplayServices: dlopen/dlsym")
        let k = KeyboardBacklight.shared
        info("KeyboardBrightnessClient: \(k.loadNote), id \(k.keyboardID), доступна \(k.isAvailable), "
             + "значение \(k.get().map { String(format: "%.3f", $0) } ?? "—")")
        if let s = PowerWatcher.read() {
            info("батарея: есть \(s.hasBattery), сеть \(s.onAC), заряжается \(s.isCharging), \(s.percent)%, "
                 + "до полной \(s.minutesToFull.map(String.init) ?? "—") мин, до пустой \(s.minutesToEmpty.map(String.init) ?? "—") мин")
            check(true, "IOPS: источники питания читаются")
        } else {
            check(false, "IOPS: источники питания не читаются")
        }
        let code = InputWatcher.currentLayoutCode()
        check(code != nil, "TIS: текущая раскладка — \(code ?? "?")")
        info("Caps Lock сейчас: \(InputWatcher.capsLockState())")
        info("камер: \(CaptureWatcher.cameras().count), камера работает: \(CaptureWatcher.cameraRunning())")
        info("входных аудиоустройств: \(CaptureWatcher.inputDevices().count), микрофон работает: \(CaptureWatcher.micRunning()), "
             + "пишут: \(CaptureWatcher.micApps())")
        let procs = CaptureWatcher.processObjectsOrNil()
        check(procs != nil, "CoreAudio: список процессов читается (\(procs?.count ?? 0))")
        let cw = CaptureWatcher()
        cw.start()
        check(cw.processListenerCount > 0, "микрофон: слушатели на процессах CoreAudio (\(cw.processListenerCount))")
        cw.stop()
        check(cw.listenerCount == 0 && cw.removeFailures == 0, "камера/микрофон: stop() — все слушатели сняты, система подтвердила")
        check(!CaptureWatcher.cameras().isEmpty, "CoreMediaIO: камера видна без прав")
        info("автояркость: \(d.isAutoBrightness.map { $0 ? "вкл" : "выкл" } ?? "не читается")")
        info("Универсальный доступ: \(AccessibilityAccess.isTrusted)")
        info("Bluetooth: ключ в Info.plist \(BluetoothWatcher.hasUsageDescription), доступ \(BluetoothWatcher.access)")
        check(BluetoothWatcher.hasUsageDescription || BluetoothWatcher.access == .unavailable,
              "Bluetooth без ключа Info.plist не трогаем")
    }

    // MARK: Микрофон ≠ музыка в гарнитуре

    /// Тишина (нули) на выход устройства, у которого есть и вход, и выход (USB-гарнитура, AirPods): флаг
    /// устройства `IsRunningSomewhere` становится true, а микрофон по процессам — нет. Ничего не слышно,
    /// вход не открывается (AudioQueue только на выход), настройки системы не меняются.
    private static func micVsPlayback() {
        let duplex = AudioWatcher.allDevices().filter {
            AudioWatcher.hasStreams($0, scope: kAudioObjectPropertyScopeInput)
                && AudioWatcher.hasStreams($0, scope: kAudioObjectPropertyScopeOutput)
        }
        guard let dev = duplex.first(where: { !CaptureWatcher.deviceRunningSomewhere($0) }) ?? duplex.first,
              let uid = deviceUID(dev) else {
            info("устройства со входом и выходом нет — проверка «музыка ≠ микрофон» пропущена")
            return
        }
        let before = CaptureWatcher.micRunning()
        var fmt = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
                                              mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                              mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
                                              mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var q: AudioQueueRef?
        let st = AudioQueueNewOutput(&fmt, { _, q, buf in
            memset(buf.pointee.mAudioData, 0, Int(buf.pointee.mAudioDataBytesCapacity))
            buf.pointee.mAudioDataByteSize = buf.pointee.mAudioDataBytesCapacity
            AudioQueueEnqueueBuffer(q, buf, 0, nil)
        }, nil, nil, nil, 0, &q)
        guard st == noErr, let q else { info("AudioQueue не создалась (\(st)) — проверка пропущена"); return }
        defer { AudioQueueDispose(q, true) }
        let cfObj = uid as CFString
        var cfUID = Unmanaged.passUnretained(cfObj)
        _ = withExtendedLifetime(cfObj) {
            AudioQueueSetProperty(q, kAudioQueueProperty_CurrentDevice, &cfUID, UInt32(MemoryLayout<Unmanaged<CFString>>.size))
        }
        for _ in 0..<3 {
            var b: AudioQueueBufferRef?
            if AudioQueueAllocateBuffer(q, 4800 * 8, &b) == noErr, let b {
                memset(b.pointee.mAudioData, 0, Int(b.pointee.mAudioDataBytesCapacity))
                b.pointee.mAudioDataByteSize = b.pointee.mAudioDataBytesCapacity
                AudioQueueEnqueueBuffer(q, b, 0, nil)
            }
        }
        guard AudioQueueStart(q, nil) == noErr else { info("AudioQueue не запустилась — проверка пропущена"); return }
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        let deviceFlag = CaptureWatcher.deviceRunningSomewhere(dev)
        let mic = CaptureWatcher.micRunning()
        let me = getpid()
        let selfInput = CaptureWatcher.processObjects().contains {
            CaptureWatcher.processPID($0) == me && CaptureWatcher.processIsRunningInput($0)
        }
        let inputs = CaptureWatcher.processObjects().filter(CaptureWatcher.processIsRunningInput)
            .map { p -> String in
                let pid = CaptureWatcher.processPID(p) ?? -1
                return "\(CaptureWatcher.executablePath(pid: pid).map { ($0 as NSString).lastPathComponent } ?? "pid \(pid)")"
                    + (CaptureWatcher.isAudioInfrastructure(pid: pid) ? " (драйвер, не считаем)" : "")
            }
        info("процессы с входом во время теста: \(inputs), мой pid \(me), приложения: \(CaptureWatcher.micApps())")
        AudioQueueStop(q, true)
        info("тишина на «\(AudioWatcher.name(dev) ?? "?")»: флаг устройства \(deviceFlag), микрофон по процессам \(mic) "
             + "(до этого \(before))")
        check(deviceFlag, "звук на гарнитуру: флаг устройства IsRunningSomewhere = true (старый способ дал бы «микрофон»)")
        check(!selfInput && mic == before, "звук на гарнитуру: микрофон по процессам не включился")
        check(!CaptureWatcher.isAudioInfrastructure(pid: me), "своё приложение — не «драйвер»")
    }

    private static func deviceUID(_ d: AudioObjectID) -> String? {
        var a = AudioWatcher.addr(kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal)
        var uid: Unmanaged<CFString>?
        var s = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(d, &a, 0, nil, &s, &uid) == noErr, let u = uid?.takeRetainedValue() else { return nil }
        return u as String
    }

    // MARK: Модуль целиком

    private static func moduleLifecycle() {
        let settings = SimpleIslandSettings(inMemory: SettingsData())
        let hud = HUDCenter()
        let activities = ActivityCenter()
        let ctx = ModuleContext(moduleId: "hud", settings: settings, themes: ThemeStore(load: false),
                                activities: activities, hud: hud, notifications: IslandNotifications(),
                                island: IslandStateCenter(), openTab: { _ in })
        let m = HUDIslandModule()
        m.start(context: ctx)
        check(m.activeSubscriptions >= 6, "start(): подписки на события (\(m.activeSubscriptions))")
        if AccessibilityAccess.isTrusted {
            check(m.tap.mode == .active, "есть Универсальный доступ — замена включена по умолчанию: tap активный (глотает клавиши)")
        } else {
            check(!m.tap.isRunning, "без Универсального доступа tap не создаётся и не падает")
        }
        check(m.settingsView() != nil, "раздел настроек есть")
        // Прокрутить цикл: первые события (NWPath, IOPS) не должны давать вспышку.
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        check(hud.current == nil, "при старте вспышек нет")

        // События → вспышки (без системы: зовём обработчики напрямую).
        let s = PowerSnapshot(hasBattery: true, onAC: true, isCharging: true, isCharged: false, percent: 78,
                              minutesToFull: 34, minutesToEmpty: nil)
        m.powerEvent(.pluggedIn, s)
        check(hud.current?.kind == "battery" && hud.current?.style == .fill, "зарядка → вспышка «Заливка»")
        m.captureChanged(camera: true, microphone: false, app: "Телемост")
        check(hud.current?.kind == "capture", "камера включилась → вспышка")
        hud.dismiss()
        m.captureChanged(camera: true, microphone: false, app: "Телемост")
        check(hud.current == nil, "камера всё ещё включена → повторной вспышки нет")
        m.captureChanged(camera: false, microphone: false, app: nil)
        check(hud.current == nil && activities.activities.isEmpty, "камера выключилась → тихо")

        // Флаги «уже показали» сбрасываются, когда камеру/микрофон выключили в настройках.
        m.captureChanged(camera: true, microphone: false, app: "Телемост")
        hud.dismiss()
        if let model = m.settingsModelForTest {
            var p = model.prefs; p.camera = false; p.microphone = false
            model.prefs = p
            p.camera = true; p.microphone = true
            model.prefs = p
        }
        m.captureChanged(camera: true, microphone: false, app: "Телемост")
        check(hud.current?.kind == "capture", "камеру выключили и включили в настройках → первая вспышка снова приходит")
        hud.dismiss()
        m.captureChanged(camera: false, microphone: false, app: nil)
        m.recheckEnvironment()
        check(true, "перепроверка прав и экранов (didBecomeActive / смена экранов) не падает")
        m.audio.onChange?(AudioWatcher.State(device: 1, name: "AirPods Pro", volume: 0.5, muted: false), .device)
        check(hud.current?.kind == "volume" && hud.current?.label == "AirPods Pro", "смена устройства → вспышка с именем")
        let opt = MediaKeyEvent(key: .brightnessUp, isDown: true, isRepeat: false, fine: false, optionOnly: true)
        check(m.handleKey(opt) == false, "⌥+яркость — системе")
        let vol = MediaKeyEvent(key: .soundUp, isDown: true, isRepeat: false, fine: false, optionOnly: false)
        if m.tap.mode != .active { check(m.handleKey(vol) == false, "без замены громкость не трогаем") }

        m.stop()
        check(m.activeSubscriptions == 0, "stop(): все подписки сняты")
        check(m.audio.removeFailures == 0 && m.capture.removeFailures == 0, "stop(): система подтвердила снятие слушателей")
        check(activities.activities.isEmpty, "stop(): активностей модуля нет")
    }

    // MARK: Сон / пробуждение / экраны / сессия (через SystemStateCenter.handle — как ядро)

    private static func makeContext() -> (ModuleContext, HUDCenter, IslandNotifications) {
        let hud = HUDCenter()
        let notes = IslandNotifications()
        let ctx = ModuleContext(moduleId: "hud", settings: SimpleIslandSettings(inMemory: SettingsData()),
                                themes: ThemeStore(load: false), activities: ActivityCenter(), hud: hud,
                                notifications: notes, island: IslandStateCenter(), openTab: { _ in })
        return (ctx, hud, notes)
    }

    private static func systemEvents() {
        let sys = SystemStateCenter.shared
        func spin(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        let (ctx, hud, notes) = makeContext()
        let m = HUDIslandModule()
        m.start(context: ctx)
        spin(0.4)
        let tapBefore = m.tap.isRunning, modeBefore = m.tap.mode, createsBefore = m.tap.createCount
        let audioRewires = m.audio.rewireCount
        info("tap до сна: \(tapBefore ? "есть (\(modeBefore == .active ? "активный" : "наблюдение"))" : "нет (нет прав или не нужен)")")

        sys.handle(.willSleep)
        check(m.network.isQuiet && !m.tap.isRunning && m.pendingWork == 0,
              "сон: сеть молчит, tap снят, отложенных дел нет")
        sys.handle(.screensDidSleep)
        // Пробуждение приходит пачкой — перевесить один раз.
        sys.handle(.didWake)
        sys.handle(.screensDidWake)
        sys.handle(.screensChanged)
        check(m.rewireCount == 0, "пробуждение: перевешивание отложено и склеивается")
        spin(HUDIslandModule.rewireDelay + 0.3)
        check(m.rewireCount == 1 && m.audio.rewireCount == audioRewires + 1,
              "пробуждение + экраны: слушатели перевешены один раз (\(m.rewireCount))")
        let dev = AudioWatcher.defaultOutputDevice()
        check(m.audio.boundDevice == dev && m.audio.listenerCount >= 2 && m.audio.removeFailures == 0,
              "CoreAudio после пробуждения: слушатели на текущем устройстве вывода и system object (\(m.audio.listenerCount))")
        check(m.input.watchesLayout && m.input.watchesCaps, "раскладка и Caps Lock: подписки заново")
        check(m.bluetooth.isRunning == (BluetoothWatcher.access == .granted),
              "IOBluetooth: уведомления заново, если Bluetooth разрешён (сейчас \(BluetoothWatcher.access))")
        if tapBefore {
            check(m.tap.isRunning && m.tap.mode == modeBefore && m.tap.createCount > createsBefore,
                  "event tap после пробуждения создан заново в том же режиме")
        } else {
            check(!m.tap.isRunning, "event tap не нужен/нет прав — и после пробуждения его нет")
        }
        check(hud.current == nil && notes.current == nil, "пробуждение — без вспышек и карточек")
        check(m.network.isQuiet, "после пробуждения 6 с сеть молчит (переподключение)")

        // Блокировка: клавиши — системе; разблокировали — как было.
        sys.handle(.screenLocked)
        check(!m.tap.isRunning, "экран заблокирован — tap снят (клавиши у системы)")
        sys.handle(.screenUnlocked)
        check(m.tap.isRunning == tapBefore, "разблокировали — tap как до блокировки")
        // Быстрое переключение пользователей.
        sys.handle(.sessionDidResignActive)
        check(!m.tap.isRunning, "сессия ушла в фон — tap снят")
        sys.handle(.sessionDidBecomeActive)
        spin(HUDIslandModule.rewireDelay + 0.3)
        check(m.rewireCount == 2 && m.tap.isRunning == tapBefore, "сессия вернулась — слушатели перевешены, tap как был")

        m.stop()
        let after = m.rewireCount
        sys.handle(.didWake)
        spin(HUDIslandModule.rewireDelay + 0.2)
        check(m.rewireCount == after && m.activeSubscriptions == 0 && m.pendingWork == 0,
              "после stop() системные события модуль не трогают, подписка снята")
        check(sys.isInteractive, "состояние SystemStateCenter вернулось (не спит, не заблокирован)")
    }

    // MARK: Bluetooth: карточка подключения (логика без IOBluetooth — право TCC в самотесте не трогаем)

    private static func spinUntil(_ timeout: TimeInterval, _ done: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while !done(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    /// JSON system_profiler во временном файле — для подставного процесса (`/usr/bin/perl` печатает его).
    private static func profilerFixture() -> String {
        let json = """
        {
          "SPBluetoothDataType" : [
            {
              "device_connected" : [
                {
                  "AirPods Pro" : {
                    "device_address" : "A1:B2:C3:D4:E5:F6",
                    "device_batteryLevelCase" : "54%",
                    "device_batteryLevelLeft" : "82%",
                    "device_batteryLevelRight" : "80%"
                  }
                }
              ]
            }
          ]
        }
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("simpleisland-hud-profiler-\(getpid()).json")
        try? json.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    /// perl: прочитать файл, напечатать первые `split` байт, подождать `pause` с, напечатать остальное (без
    /// перевода строки в конце — как у system_profiler; `newline` — с ним), затем подождать `after` с и выйти.
    private static func perlArgs(_ file: String, split: Int = 0, pause: Double = 0, after: Double = 0,
                                 newline: Bool = false) -> [String] {
        let script = #"local $/; open F, $ARGV[0] or exit 1; my $s = <F>; $s =~ s/\n+$//; $| = 1; "#
            + #"print substr($s, 0, $ARGV[1]); select(undef, undef, undef, $ARGV[2]); print substr($s, $ARGV[1]); "#
            + #"print "\n" if $ARGV[4]; select(undef, undef, undef, $ARGV[3]);"#
        return ["-e", script, file, "\(split)", "\(pause)", "\(after)", newline ? "1" : "0"]
    }

    private static func bluetoothLogic() {
        let fixture = profilerFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture) }
        let prof = BluetoothProfiler(executable: "/usr/bin/perl", arguments: perlArgs(fixture))
        let bt = BluetoothWatcher(profiler: prof)
        bt.batteryDelay = 0.1
        var cards: [(String, HeadphonesBattery?)] = []
        var updates: [(String, HeadphonesBattery)] = []
        bt.onConnect = { cards.append(($0, $1)) }
        bt.onBattery = { updates.append(($0, $1)) }
        bt.onDisconnect = { _ in }

        // Регистрация присылает уже подключённые — мимо; новые — карточка.
        bt.resetBaseline(["aa-old"])
        bt.deviceConnected(key: "aa-old", name: "Старые", address: "aa-old") { nil }
        check(bt.pendingCount == 0, "уже подключённое при регистрации — без карточки")

        // Главный сценарий: AirPods подключились сразу после пробуждения, во время перевешивания (новый список
        // «уже подключённых» их уже содержит) — отложенная карточка не теряется.
        bt.deviceConnected(key: "pods", name: "AirPods Pro", address: "a1-b2-c3-d4-e5-f6") {
            HeadphonesBattery(left: 82, right: 80, caseLevel: 54)
        }
        bt.resetBaseline(["aa-old", "pods"])   // как rewire(): регистрация заново, отложенное не трогается
        spinUntil(1) { !cards.isEmpty }
        check(cards.count == 1 && cards.first?.0 == "AirPods Pro" && cards.first?.1?.left == 82,
              "подключение сразу после пробуждения: перевешивание карточку не отменяет")
        // Повторная доставка того же подключения регистрацией — без второй карточки; отключили и подключили — карточка.
        bt.deviceConnected(key: "pods", name: "AirPods Pro", address: nil) { nil }
        check(bt.pendingCount == 0, "повтор «уже подключено» от новой регистрации — без второй карточки")
        var offs = 0
        bt.onDisconnect = { _ in offs += 1 }
        bt.deviceDisconnected(key: "pods", name: "AirPods Pro", isAudio: true)
        check(offs == 1 && !bt.baseline.contains("pods"), "отключились — вспышка, из «уже подключённых» ушли")

        // Заряд напрямую не прочитался: карточка сразу без заряда, затем system_profiler обновляет её на месте.
        cards.removeAll()
        bt.deviceConnected(key: "pods", name: "AirPods Pro", address: "a1-b2-c3-d4-e5-f6") { nil }
        spinUntil(3) { !updates.isEmpty }
        check(cards.count == 1 && cards.first?.1 == nil, "заряда сразу нет — карточка показана без заряда, не ждёт system_profiler")
        check(updates.count == 1 && updates.first?.1 == HeadphonesBattery(left: 82, right: 80, caseLevel: 54) && prof.runCount == 1,
              "system_profiler ответил — заряд обновляет карточку (\(prof.runCount) запуск)")

        // Не чаще раза в минуту: переподключение — ответ из памяти, процесс не запускается.
        bt.deviceDisconnected(key: "pods", name: "AirPods Pro", isAudio: true)
        bt.deviceConnected(key: "pods", name: "AirPods Pro", address: "a1-b2-c3-d4-e5-f6") { nil }
        spinUntil(1) { updates.count >= 2 }
        check(updates.count == 2 && prof.runCount == 1 && !prof.isRunning,
              "переподключение в пределах минуты — заряд из памяти, system_profiler не запускается")

        // Карточка на месте: replace меняет показанную (тот же id), ушедшую не возвращает.
        let notes = IslandNotifications()
        notes.post(HUDFlashes.headphonesConnected(name: "AirPods Pro", battery: nil))
        let replaced = notes.replace(HUDFlashes.headphonesConnected(name: "AirPods Pro", battery: HeadphonesBattery(single: 64)))
        check(replaced && notes.current?.id == "hud.bt.AirPods Pro" && notes.current?.trailing != nil,
              "ядро: replace обновляет показанную карточку на месте (заряд справа)")
        notes.dismiss()
        check(!notes.replace(HUDFlashes.headphonesConnected(name: "AirPods Pro", battery: HeadphonesBattery(single: 64)))
              && notes.current == nil, "ядро: карточку уже закрыли — replace её не возвращает")
        notes.post(IslandNotification(moduleId: "x", title: "другое", body: "…"))
        notes.post(HUDFlashes.headphonesConnected(name: "AirPods Pro", battery: nil))
        check(notes.replace(HUDFlashes.headphonesConnected(name: "AirPods Pro", battery: HeadphonesBattery(single: 64)))
              && notes.current?.title == "другое", "ядро: карточка в очереди — заменена там, показанная не тронута")
        notes.dismiss()
        check(notes.current?.trailing != nil, "ядро: из очереди вышла уже обновлённая карточка")

        bt.stop()
        check(bt.pendingCount == 0 && bt.baseline.isEmpty && !prof.isRunning, "stop(): без отложенного и процессов")
    }

    /// Процесс заряда: ответ по закрывающей `}` (EOF), а не по выходу; тайм-аут; хвост после выхода; чужие строки.
    private static func profilerRuns() {
        let fixture = profilerFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture) }
        let size = (try? Data(contentsOf: URL(fileURLWithPath: fixture)).count) ?? 0
        let prof = BluetoothProfiler(executable: "/usr/bin/perl", arguments: perlArgs(fixture, after: 3, newline: true))
        prof.minInterval = 0
        var got: [[BluetoothProfiler.Entry]] = []
        var t0 = Date()
        prof.fetch { got.append($0) }
        spinUntil(2.5) { !got.isEmpty }
        let took = Date().timeIntervalSince(t0)
        check(got.count == 1 && got.first?.first?.battery.left == 82 && took < 2,
              String(format: "ответ готов по закрывающей «}», не дожидаясь выхода процесса: %.2f с", took))
        spinUntil(0.8) { !prof.isRunning }
        check(!prof.isRunning, "после ответа процесс остановлен")

        // Тайм-аут, а сразу за ним новый запуск: строки старого процесса в ответ нового не попадают.
        got.removeAll()
        prof.timeout = 0.4
        prof.arguments = perlArgs(fixture, split: 10, pause: 2)
        prof.fetch { got.append($0) }
        spinUntil(1) { !got.isEmpty }
        check(got.count == 1 && got[0].isEmpty, "тайм-аут — пустой ответ, ожидающие не висят")
        prof.timeout = 4
        prof.arguments = perlArgs(fixture, split: size / 2, pause: 0.5)
        got.removeAll()
        t0 = Date()
        prof.fetch { got.append($0) }
        spinUntil(4) { !got.isEmpty }
        check(got.count == 1 && got[0].count == 1 && got[0].first?.battery.caseLevel == 54,
              "новый запуск сразу после тайм-аута: ответ целый, чужих строк нет")

        // Несколько ожидающих — один запуск и один ответ на всех.
        got.removeAll()
        let runs = prof.runCount
        prof.arguments = perlArgs(fixture, split: size / 2, pause: 0.3)
        prof.fetch { got.append($0) }
        prof.fetch { got.append($0) }
        spinUntil(3) { got.count >= 2 }
        check(got.count == 2 && prof.runCount == runs + 1, "два запроса во время одного запуска — один процесс")

        // Без закрывающей «}» (обрезанный вывод) — после выхода ждём хвост не дольше tailGrace, ответ пустой.
        let cut = FileManager.default.temporaryDirectory.appendingPathComponent("simpleisland-hud-cut-\(getpid()).json")
        try? "{\n  \"SPBluetoothDataType\" : [".write(to: cut, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: cut) }
        prof.tailGrace = 0.3
        prof.arguments = perlArgs(cut.path)
        got.removeAll()
        prof.fetch { got.append($0) }
        spinUntil(2) { !got.isEmpty }
        check(got.count == 1 && got[0].isEmpty && !prof.isRunning, "обрезанный вывод — пустой ответ после выхода, без зависания")

        // Покой: ответ из памяти не запускает процесс.
        prof.minInterval = 60
        let before = prof.runCount
        var cached = false
        prof.fetch { _ in cached = true }
        check(cached && prof.runCount == before && !prof.isRunning, "в пределах minInterval — ответ из памяти сразу")
        prof.cancel()
    }

    // MARK: Покой: модуль процесс не будит

    /// Пробуждения процесса (ri_pkg_idle_wkups + ri_interrupt_wkups) — то же, что IDLEW у top.
    private static func wakeups() -> UInt64? {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        return rc == 0 ? info.ri_pkg_idle_wkups + info.ri_interrupt_wkups : nil
    }

    private static func idleWakeups() {
        func spin(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        let tickers = SharedTicker.shared.subscriberCount
        // Окно 10 с: в 5 с шум одного прогона сравним с самим бюджетом.
        let window: TimeInterval = 10
        spin(0.5)
        guard let b0 = wakeups() else { check(false, "proc_pid_rusage не читается"); return }
        spin(window)
        let base = Double((wakeups() ?? b0) - b0) / window

        let (ctx, hud, _) = makeContext()
        let m = HUDIslandModule()
        m.start(context: ctx)
        spin(1.5) // первые события (NWPath, IOPS) прошли
        check(SharedTicker.shared.subscriberCount == tickers && m.pendingWork == 0 && hud.current == nil,
              "покой: ни тикеров, ни отложенных дел, ни вспышек")
        let w0 = wakeups() ?? 0
        spin(window)
        let rate = Double((wakeups() ?? w0) - w0) / window
        info(String(format: "пробуждения процесса: без модуля %.2f/с, с модулем %.2f/с (бюджет покоя ≤ 1/с)", base, rate))
        check(rate - base <= 1, String(format: "покой: модуль добавляет ≤ 1 пробуждения/с (%+.2f)", rate - base))
        check(rate <= 1, String(format: "покой: всего ≤ 1 пробуждения/с, бюджет PITFALLS (%.2f/с)", rate))
        m.stop()
    }

    private static func fourCC(_ v: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((v >> $0) & 0xFF) }
        return String(bytes: bytes, encoding: .ascii) ?? "\(v)"
    }
}
