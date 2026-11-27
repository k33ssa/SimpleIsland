import Accelerate
import AppKit
import CoreAudio
import Foundation
import IslandCore

/// Самотест эквалайзера «Музыки» и своих пресетов: `SimpleIsland --selftest-equalizer [live]`.
///
/// Без `live` — логика без «Музыки»: разбор ответов AppleScript, скрипты, шаг/прилипание ползунка, имена, дебаунс
/// правок, хранение в настройках, «правда у Музыки» при открытии.
///
/// С `live` — на настоящей «Музыке» (16.11, «проверь, что звук меняется»): только если она уже запущена (сами не
/// запускаем). Запоминает EQ enabled / current preset и в конце ВСЕГДА возвращает как было; проверяет, что вкл/выкл,
/// выбор пресета, правка полос, переименование и удаление своего пресета реально доходят до «Музыки» (читает обратно
/// AppleScript), и что правка в самой «Музыке» видна виджету при открытии. Если «Музыка» играет — меряет звук её
/// процесса (process tap, как «Эквалайзер по реальному звуку»): окна по ~2,5 с — EQ выкл / +12 дБ на 32–125 Гц /
/// −12 дБ / выкл; сравнивает долю низов (25–150 Гц) к середине (0,5–4 кГц). Громкость не трогает, воспроизведение
/// не включает.
public enum MusicEqualizerSelfTest {
    @MainActor
    public static func run(arguments: [String]) -> Int32 {
        setvbuf(stdout, nil, _IOLBF, 0)   // построчно: при зависании в файле видно, где
        let check = MediaSelfTest.Checker()
        logic(check)
        if arguments.contains("live") { live(check) }
        print(check.failures == 0 ? "EQUALIZER SELFTEST: OK" : "EQUALIZER SELFTEST: \(check.failures) FAIL")
        return check.failures == 0 ? 0 : 1
    }

    // MARK: Логика

    @MainActor
    static func logic(_ check: MediaSelfTest.Checker) {
        let us = MusicEqualizer.separator, rs = MusicEqualizer.sectionSeparator
        // Ответ «Музыки» в русской локали: числа с запятой.
        let raw = "true" + us + "Свой бас" + us + ["Настройка вручную", "Рок", "Свой бас"].joined(separator: us)
            + rs + "-3,0;12,0;10,5;1,049999952316;0,0;0,0;0,0;0,0;0,0;0,0;-12,0"
        let s = MusicEqualizer.parse(raw)
        check(s?.enabled == true && s?.current == "Свой бас" && s?.presets == ["Настройка вручную", "Рок", "Свой бас"],
              "разбор: вкл · текущий · пресеты (с секцией полос)", "\(String(describing: s))")
        check(s?.currentBands?.count == 11 && s?.currentBands?[0] == -3 && s?.currentBands?[2] == 10.5
              && abs((s?.currentBands?[3] ?? 0) - 1.05) < 0.001 && s?.currentBands?[10] == -12,
              "разбор: полосы текущего пресета (запятая по локали)", "\(String(describing: s?.currentBands))")
        check(MusicEqualizer.parse("false" + us + "" + us + "Pop")?.currentBands == nil
              && MusicEqualizer.parse("false" + us + "" + us + "Pop" + rs + "")?.currentBands == nil,
              "разбор: без полос (нет текущего) — nil, остальное читается")
        check(MusicEqualizer.parseBands("1;2;3") == nil && MusicEqualizer.parseBands("0.5;1;2;3;4;5;6;7;8;9;10")?[0] == 0.5,
              "разбор полос: ровно 11 чисел, точка тоже годится")
        check(MusicEqualizer.parse("execution error: -1728") == nil, "разбор: ошибка — nil")

        // «Настройка вручную» — третья секция ответа (первый пресет Музыки).
        let withManual = MusicEqualizer.parse("false" + us + "Рок" + us + "Настройка вручную" + us + "Рок" + rs + "" + rs
                                              + "Настройка вручную" + us + "0,0;1,5;0;0;0;0;0;0;0;0;-2,5")
        check(withManual?.manualName == "Настройка вручную" && withManual?.manualBands?[1] == 1.5 && withManual?.manualBands?[10] == -2.5,
              "разбор: полосы «Настройки вручную»", "\(String(describing: withManual))")
        check(MusicEqualizer.parse("false" + us + "" + us + "Рок" + rs + "" + rs + "Рок" + us + "0;0;0;0;0;0;0;0;0;0;0")?.manualName == nil,
              "разбор: первый пресет не ручной — не редактируем")
        check(MusicEqualizer.readScript.contains("set m to EQ preset 1"), "чтение: ручной пресет — первый в списке Музыки")
        do {
            let mm = MusicEqualizer()
            var saved2: [CustomEQPreset]? = nil
            var sent2: [String] = []
            mm.store = (load: { [] }, save: { saved2 = $0 })
            mm.mock(withManual, access: .ready)
            mm.scriptSink = { sent2.append($0) }
            check(mm.editableId(name: "Настройка вручную") == MusicEqualizer.manualId && mm.editableId(name: "Рок") == nil,
                  "«Настройка вручную» редактируется, встроенные — нет")
            mm.setValue(MusicEqualizer.manualId, slider: 3, to: 6)
            mm.flush()
            check(sent2.count == 1 && sent2[0].contains("EQ preset \"Настройка вручную\"") && sent2[0].contains("set band 3 of e to 6.00")
                  && !sent2[0].contains("make new") || sent2.first?.contains("if exists EQ preset \"Настройка вручную\"") == true,
                  "полоса «Настройки вручную» → set band 3 этого пресета", sent2.first ?? "")
            check(saved2 == nil && mm.customs.isEmpty, "«Настройка вручную» в свои пресеты не записывается")
            mm.rename(MusicEqualizer.manualId, to: "Х"); mm.delete(MusicEqualizer.manualId)
            check(mm.manual?.name == "Настройка вручную" && sent2.count == 1, "«Настройку вручную» нельзя переименовать или удалить")
            mm.selectCustom(MusicEqualizer.manualId)
            check(mm.state?.current == "Настройка вручную" && mm.state?.enabled == true, "выбор «Настройки вручную» — текущий, EQ вкл")
        }

        // Числа и скрипты.
        check(MusicEqualizer.number(5.5) == "5.50" && MusicEqualizer.number(-20) == "-12.00" && MusicEqualizer.number(.nan) == "0.00",
              "число в AppleScript — с точкой, ±12, NaN → 0", MusicEqualizer.number(5.5))
        let p = CustomEQPreset(id: "x", name: "Бас \"ночь\"", preamp: -3, bands: [12, 12, 12, 0, 0, 0, 0, 0, 0, -4.5])
        let create = MusicEqualizer.syncScript(p, select: true)
        check(create.contains("if exists EQ preset \"Бас \\\"ночь\\\"\"")
              && create.contains("make new EQ preset with properties {name:\"Бас \\\"ночь\\\"\", preamp:-3.00, band 1:12.00")
              && create.contains("band 10:-4.50}") && create.contains("set band 10 of e to -4.50")
              && create.contains("set current EQ preset to e") && create.contains("set EQ enabled to true"),
              "скрипт своего пресета: досоздать/переписать все полосы, выбрать и включить", create)
        let edit = MusicEqualizer.syncScript(p, select: false)
        check(!edit.contains("current EQ preset") && !edit.contains("EQ enabled"), "правка полос — без смены текущего и вкл/выкл")
        check(MusicEqualizer.renameScript("А", "Б").contains("set name of EQ preset \"А\" to \"Б\"")
              && MusicEqualizer.deleteScript("А").contains("delete EQ preset \"А\"")
              && MusicEqualizer.deleteScript("А").contains("set current EQ preset to EQ preset 1"),
              "скрипты переименования и удаления (текущий — сначала на «Вручную»)")

        // Ползунок.
        check(CustomEQPreset.snapped(0.3) == 0 && CustomEQPreset.snapped(5.26) == 5.5 && CustomEQPreset.snapped(-30) == -12,
              "ползунок: шаг 0,5, прилипание к 0, предел ±12")
        check(CustomEQPreset.value(atY: 0, height: 100) == 12 && CustomEQPreset.value(atY: 100, height: 100) == -12
              && CustomEQPreset.value(atY: 50, height: 100) == 0 && CustomEQPreset.value(atY: -40, height: 100) == 12
              && CustomEQPreset.y(of: 0, height: 100) == 50 && CustomEQPreset.y(of: 6, height: 100) == 25,
              "ползунок: верх +12, низ −12, середина 0, за краем — край")
        check(CustomEQPreset.format(-4.5) == "−4,5" && CustomEQPreset.format(3) == "+3" && CustomEQPreset.format(0.1) == "0",
              "подпись дБ", CustomEQPreset.format(-4.5))
        check(CustomEQPreset(name: "a", bands: [1, 2]).bands.count == 10 && CustomEQPreset(name: "a", preamp: 40).preamp == 12,
              "пресет: всегда 10 полос, значения в пределах")

        // Имена.
        check(MusicEqualizer.uniqueName("Свой", taken: ["Свой", "свой 2"]) == "Свой 3"
              && MusicEqualizer.uniqueName("Рок", taken: ["Рок", "Поп"]) == "Рок 2"
              && MusicEqualizer.uniqueName("  ", taken: []) == "Свой",
              "имя: не совпадает с пресетами Музыки и своими (без регистра)")
        check(MusicEqualizer.gridOrder(["Настройка вручную", "Рок", "Мой"], excluding: ["Мой"]) == ["Рок", "Настройка вручную"],
              "сетка Apple: свои — отдельно, «Настройка вручную» — в конце")

        // Хранение: настройки «Медиа».
        var prefs = MediaPrefs()
        prefs.customEQ = [p]
        let data = try? JSONEncoder().encode(prefs)
        let back = data.flatMap { try? JSONDecoder().decode(MediaPrefs.self, from: $0) }
        check(back?.customEQ == [p], "хранение: свои пресеты в настройках переживают перезапуск")
        let old = try? JSONDecoder().decode(MediaPrefs.self, from: Data(#"{"compactLyrics":true}"#.utf8))
        check(old?.customEQ == [] && old?.compactLyrics == true, "хранение: старые настройки без пресетов читаются")
        let bad = try? JSONDecoder().decode(MediaPrefs.self, from: Data(#"{"customEQ":[{"name":"x","bands":[40,1],"preamp":-99}]}"#.utf8))
        check(bad?.customEQ.first?.bands.count == 10 && bad?.customEQ.first?.bands[0] == 12 && bad?.customEQ.first?.preamp == -12,
              "хранение: битые значения — в пределы, недостающие полосы — 0")
        check(MediaModel.onlyKeysChanged(prefs, MediaPrefs()), "правка своих пресетов не дёргает плеер (тексты, активность)")

        // Модуль ↔ настройки: пресет из виджета попадает в prefs модели «Медиа».
        let media = MediaIslandModule()
        if let eq = media.equalizerModule as? EqualizerIslandModule {
            eq.music.mock(.init(enabled: false, current: "Рок", presets: ["Настройка вручную", "Рок"],
                                currentBands: [0, 3, 2, 1, 0, 0, 0, 0, 1, 2, 3]), access: .ready)
            let id = eq.music.addCustom()
            check(media.model.prefs.customEQ.count == 1 && media.model.prefs.customEQ.first?.id == id
                  && media.model.prefs.customEQ.first?.bands.first == 3 && media.model.prefs.customEQ.first?.name == "Свой",
                  "«+ Свой»: значения текущего пресета, имя «Свой», сразу в настройках", "\(media.model.prefs.customEQ)")
            check(eq.music.state?.current == "Свой" && eq.music.state?.enabled == true, "«+ Свой»: сразу текущий и включён")
            // Перезапуск острова: модуль создан до чтения настроек — свои пресеты подтягиваются при открытии вкладки.
            let media2 = MediaIslandModule()
            if let eq2 = media2.equalizerModule as? EqualizerIslandModule {
                check(eq2.music.customs.isEmpty, "перезапуск: до чтения настроек своих нет")
                var pr = media2.model.prefs; pr.customEQ = media.model.prefs.customEQ; media2.model.prefs = pr
                eq2.music.reloadCustoms()
                check(eq2.music.customs == media.model.prefs.customEQ && !eq2.music.customs.isEmpty,
                      "перезапуск: открыли вкладку — свои пресеты из настроек на месте")
            }
        } else { check(false, "модуль эквалайзера") }

        // Действия (мок + перехват скриптов).
        let me = MusicEqualizer()
        var saved: [CustomEQPreset] = []
        var sent: [String] = []
        me.store = (load: { [] }, save: { saved = $0 })
        me.mock(.init(enabled: true, current: "Рок", presets: ["Настройка вручную", "Рок"]), access: .ready)
        me.scriptSink = { sent.append($0) }
        me.setValue("Рок", slider: 1, to: 5)
        check(sent.isEmpty && me.customs.isEmpty, "встроенный пресет Apple не правится (только свои по id)")
        let id = me.addCustom(name: "Рок", from: nil) ?? ""
        check(me.custom(id)?.name == "Рок 2" && saved.count == 1 && sent.last?.contains("make new EQ preset") == true,
              "свой с именем встроенного — «Рок 2», создаётся в Музыке", me.custom(id)?.name ?? "")

        // Дебаунс: 30 правок за ~60 мс → одна отправка с последним значением.
        sent = []
        me.debounce = 0.12
        let before = me.syncCount
        for k in 0..<30 {
            me.setValue(id, slider: 3, to: Double(k) * 0.4 - 6)
            _ = spinUntil(timeout: 0.002) { false }
        }
        check(me.syncCount == before && me.hasPendingEdits, "дебаунс: пока тянут — в Музыку ничего не ушло")
        _ = spinUntil(timeout: 0.4) { false }
        let last = CustomEQPreset.clamp(29 * 0.4 - 6)
        check(me.syncCount == before + 1 && sent.count == 1 && sent[0].contains("set band 3 of e to \(MusicEqualizer.number(last))"),
              "дебаунс: 30 правок → 1 скрипт с последним значением", "скриптов \(me.syncCount - before)")
        check(saved.first?.bands[2] == last, "дебаунс: последнее значение — и в настройках")
        // Конец перетаскивания — сразу, без ожидания; отложенная отправка после этого не повторяется.
        sent = []
        me.setValue(id, slider: 0, to: -2)
        me.flush()
        check(sent.count == 1 && sent[0].contains("set preamp of e to -2.00"), "отпустили ползунок — ушло сразу")
        _ = spinUntil(timeout: 0.3) { false }
        check(sent.count == 1, "после flush отложенной отправки нет")
        me.flush()
        check(sent.count == 1, "flush без правок ничего не шлёт")
        // Двойной клик — 0; сброс всех.
        me.setValue(id, slider: 3, to: 0)
        me.resetAll(id)
        check(me.custom(id).map { $0.bands.allSatisfy { $0 == 0 } && $0.preamp == 0 } == true, "«Сбросить» — все в 0")

        // «Правда у Музыки»: открыли вкладку, а полосы поменяли в окне эквалайзера Музыки.
        me.apply(.init(enabled: false, current: "Рок 2", presets: ["Настройка вручную", "Рок", "Рок 2"],
                       currentBands: [1, 4, 0, 0, 0, 0, 0, 0, 0, 0, -6]))
        check(me.custom(id)?.bands.first == 4 && me.custom(id)?.preamp == 1 && me.state?.enabled == false && !me.isSelected("Рок 2"),
              "открыли вкладку: вкл/выкл и полосы — как в Музыке сейчас")
        me.setValue(id, slider: 1, to: 9)
        me.apply(.init(enabled: true, current: "Рок 2", presets: ["Настройка вручную", "Рок", "Рок 2"], currentBands: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
        check(me.custom(id)?.bands.first == 9, "свою неотправленную правку старый ответ Музыки не затирает")
        me.flush()

        // Переименование и удаление.
        sent = []
        me.editing = id
        me.rename(id, to: "Рок")
        check(me.custom(id)?.name == "Рок 2" && sent.isEmpty, "переименование в занятое имя — без изменений")
        me.rename(id, to: "  Вечер ")
        check(me.custom(id)?.name == "Вечер" && saved.first?.name == "Вечер" && sent.last?.contains("to \"Вечер\"") == true
              && me.state?.current == "Вечер", "переименование: в Музыке, настройках и текущем")
        me.delete(id)
        check(me.customs.isEmpty && saved.isEmpty && me.editing == nil && sent.last?.contains("delete EQ preset \"Вечер\"") == true,
              "удаление: из Музыки и настроек, редактор закрыт")

        // Замер звука для live: на синтетике (60 Гц + 1 кГц) низы ×4 по амплитуде = +12 дБ к «низ−середина».
        func tone(_ lowAmp: Float) -> [Float] {
            (0..<48_000).map { i in
                let t = Float(i) / 48_000
                return lowAmp * sinf(2 * .pi * 60 * t) * 0.1 + sinf(2 * .pi * 1000 * t) * 0.1
            }
        }
        if let a = Bands.measure(tone(1), rate: 48_000), let b = Bands.measure(tone(4), rate: 48_000),
           let c = Bands.measure(tone(0.25), rate: 48_000) {
            check(abs(b.ratio - a.ratio - 12.04) < 0.5 && abs(a.ratio - c.ratio - 12.04) < 0.5 && abs(a.ratio) < 1.5,
                  "замер звука: низы ×4 → +12 дБ, ×¼ → −12 дБ (синтетика)",
                  String(format: "%+.2f / %+.2f / база %+.2f", b.ratio - a.ratio, c.ratio - a.ratio, a.ratio))
        } else { check(false, "замер звука: БПФ") }

        // Снимки виджета.
        let names = media.equalizerModule.snapshotStates().map(\.name)
        check(names.contains("custom") && names.contains("custom-editor"), "снимки: свои пресеты и редактор", "\(names)")
    }

    /// Крутить главный цикл до условия (шаг ~3 мс — дебаунс 120 мс меряется честно). Не `RunLoop.run(until:)`:
    /// в процессе из оболочки ожидание run loop с таймаутом здесь висело десятки секунд (16.11, 2 прогона из 2,
    /// несмотря на `beginActivity`) — поэтому цикл без ожидания + `usleep`.
    @MainActor
    static func spinUntil(timeout: TimeInterval, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            while CFRunLoopRunInMode(.defaultMode, 0, true) == .handledSource {}
            usleep(3000)
        }
        return cond()
    }

    // MARK: Живая проверка

    /// AppleScript на потоке `ScriptSource` с ожиданием ответа (самотест; главный поток ждёт).
    @MainActor
    static func script(_ src: String, timeout: TimeInterval = 15) -> String? {
        let box = ResultBox()
        ScriptSource.perform {
            let r = ScriptSource.run(src)
            box.set(r.descriptor?.stringValue ?? (r.errorNumber.map { "ERR \($0)" } ?? ""))
        }
        _ = spinUntil(timeout: timeout) { box.done }
        return box.value
    }

    @MainActor
    static func readMusic() -> MusicEqualizer.Snapshot? { script(MusicEqualizer.readScript).flatMap(MusicEqualizer.parse) }

    @MainActor
    static func live(_ check: MediaSelfTest.Checker) {
        print("\n== live: настоящая «Музыка»")
        guard ScriptSource.isRunning(MusicEqualizer.bundleId) else {
            print("SKIP live: «Музыка» не запущена — сами её не запускаем"); return
        }
        let st = ScriptSource.automationStatus(MusicEqualizer.bundleId, ask: false)
        guard st == noErr else { print("SKIP live: нет права «Автоматизация → Музыка» у этого процесса (\(st))"); return }
        guard let orig = readMusic() else { check(false, "live: прочитать эквалайзер Музыки"); return }
        let player = script("tell application id \"com.apple.Music\" to return (player state as text) & \"|\" & (sound volume as text)") ?? "?"
        print("исходно: EQ \(orig.enabled ? "вкл" : "выкл"), пресет «\(orig.current ?? "—")», пресетов \(orig.presets.count), плеер/громкость \(player)")
        let volumeBefore = player.split(separator: "|").last.map(String.init)

        let me = MusicEqualizer()
        var stored: [CustomEQPreset] = []
        me.store = (load: { [] }, save: { stored = $0 })
        var made: [String] = []   // имена своих пресетов, созданных тестом (удалить в конце)

        defer {
            // Вернуть как было: удалить свои, пресет и вкл/выкл — исходные.
            me.flush()
            for n in Set(made + me.customs.map(\.name)) { _ = script(MusicEqualizer.deleteScript(n)) }
            if let cur = orig.current { _ = script(MusicEqualizer.selectScript(cur)) }
            _ = script(MusicEqualizer.enableScript(orig.enabled))
            let after = readMusic()
            let leftovers = after?.presets.filter { $0.hasPrefix("SimpleIsland проверка") } ?? []
            check(after?.enabled == orig.enabled && after?.current == orig.current && after?.presets == orig.presets && leftovers.isEmpty,
                  "live: состояние Музыки возвращено (вкл/выкл, пресет, список пресетов)",
                  "было \(orig.enabled)/\(orig.current ?? "—")/\(orig.presets.count), стало \(String(describing: after?.enabled))/\(after?.current ?? "—")/\(after?.presets.count ?? -1)")
            let volAfter = script("tell application id \"com.apple.Music\" to return sound volume as text")
            check(volAfter == volumeBefore, "live: громкость не тронута", "\(volumeBefore ?? "?") → \(volAfter ?? "?")")
        }

        me.refresh()
        let ready = spinUntil(timeout: 10) { me.access == .ready && me.state != nil }
        check(ready && me.state?.enabled == orig.enabled && me.state?.current == orig.current,
              "live: виджет при открытии читает правду Музыки", "\(String(describing: me.state?.enabled)) / \(me.state?.current ?? "—")")
        guard ready else { return }

        // 1. Вкл/выкл из виджета → Музыка.
        let t0 = Date()
        me.setEnabled(!orig.enabled)
        var r = waitRead { $0.enabled == !orig.enabled }
        check(r?.enabled == !orig.enabled, "live: «\(orig.enabled ? "выкл" : "вкл")» из виджета дошло до Музыки",
              String(format: "%.2f с", Date().timeIntervalSince(t0)))
        me.setEnabled(orig.enabled)
        r = waitRead { $0.enabled == orig.enabled }
        check(r?.enabled == orig.enabled, "live: и обратно")

        // 2. Вкл/выкл в самой Музыке → виджет при открытии.
        _ = script(MusicEqualizer.enableScript(!orig.enabled))
        me.refresh()
        let seen = spinUntil(timeout: 5) { me.state?.enabled == !orig.enabled }
        check(seen, "live: переключили в Музыке — виджет при открытии показывает правду")
        _ = script(MusicEqualizer.enableScript(orig.enabled))

        // 3. Встроенный пресет из сетки.
        let builtin = orig.presets.first { $0 != orig.current && !$0.lowercased().contains("вручную") && $0 != "Manual" }
        if let b = builtin {
            me.select(b)
            r = waitRead { $0.current == b && $0.enabled }
            check(r?.current == b && r?.enabled == true, "live: выбор пресета «\(b)» — текущий в Музыке, EQ включён")
        }

        // 4. Свой пресет: создать, выбрать, править с дебаунсом, переименовать.
        let name = MusicEqualizer.uniqueName("SimpleIsland проверка", taken: orig.presets)
        made.append(name)
        let id = me.addCustom(name: name, from: [0, 12, 12, 12, 0, 0, 0, 0, 0, 0, 0]) ?? ""
        r = waitRead { $0.current == name }
        check(r?.current == name && r?.enabled == true && r?.currentBands?[1] == 12 && r?.currentBands?[3] == 12 && r?.currentBands?[4] == 0,
              "live: «+ Свой» создал пресет в Музыке с полосами и сделал текущим", "\(String(describing: r?.currentBands))")
        let syncs = me.syncCount
        for k in 0...20 { me.setValue(id, slider: 6, to: Double(k) * 0.3); _ = spinUntil(timeout: 0.01) { false } }
        r = waitRead { abs(($0.currentBands?[6] ?? 0) - 6) < 0.05 }
        check(abs((r?.currentBands?[6] ?? 0) - 6) < 0.05 && me.syncCount - syncs <= 3,
              "live: 21 правка полосы 1k за ~0,2 с → \(me.syncCount - syncs) скрипт(а), в Музыке последнее значение",
              "band 6 = \(String(describing: r?.currentBands?[6]))")
        // Правка полос в окне Музыки → виджет забирает при открытии.
        _ = script("tell application id \"com.apple.Music\" to set band 5 of EQ preset \(MusicEqualizer.quoted(name)) to -3")
        me.refresh()
        let adopted = spinUntil(timeout: 5) { me.custom(id)?.bands[4] == -3 }
        check(adopted && stored.first?.bands[4] == -3, "live: полосу поменяли в Музыке — виджет и настройки это видят")

        // 4б. «Настройка вручную» — правится напрямую; исходные полосы — вернуть.
        if let mName = me.manual?.name, let mOrig = me.manual {
            defer { _ = script(MusicEqualizer.syncScript(mOrig, select: false)) }
            let target = mOrig.bands[1] == 4.5 ? 3.0 : 4.5
            me.setValue(MusicEqualizer.manualId, slider: 2, to: target)
            me.flush()
            var mb: Double?
            _ = spinUntil(timeout: 5) {
                mb = script("tell application id \"com.apple.Music\" to return (band 2 of EQ preset \(MusicEqualizer.quoted(mName))) as text")
                    .flatMap { Double($0.replacingOccurrences(of: ",", with: ".")) }
                return mb.map { abs($0 - target) < 0.05 } ?? false
            }
            check(mb.map { abs($0 - target) < 0.05 } == true && stored.allSatisfy { $0.name != mName },
                  "live: «\(mName)» — полоса 64 Гц правится напрямую в Музыке (в свои не попадает)", "band 2 = \(String(describing: mb))")
        } else { print("live: «Настройка вручную» не найдена первым пресетом — пропуск") }

        // 5. Звук.
        if player.hasPrefix("playing") {
            measure(check, me: me, id: id, orig: orig)
        } else {
            print("ЗВУК: не мерил — «Музыка» не играет (\(player)); воспроизведение сам не включаю")
        }

        // 6. Переименование и удаление.
        let renamed = MusicEqualizer.uniqueName(name + " 2", taken: orig.presets)
        made.append(renamed)
        me.rename(id, to: renamed)
        r = waitRead { $0.presets.contains(renamed) }
        check(r?.presets.contains(renamed) == true && r?.presets.contains(name) == false, "live: переименование видно в Музыке")
        me.delete(id)
        r = waitRead { !$0.presets.contains(renamed) }
        check(r?.presets.contains(renamed) == false && stored.isEmpty, "live: удаление — пресета нет ни в Музыке, ни в настройках",
              "текущий после удаления: \(r?.current ?? "—")")
    }

    @MainActor
    static func waitRead(timeout: TimeInterval = 5, _ cond: (MusicEqualizer.Snapshot) -> Bool) -> MusicEqualizer.Snapshot? {
        let end = Date().addingTimeInterval(timeout)
        var last: MusicEqualizer.Snapshot?
        repeat {
            _ = spinUntil(timeout: 0.15) { false }
            last = readMusic()
            if let l = last, cond(l) { return l }
        } while Date() < end
        return last
    }

    // MARK: Звук

    /// Окна по 2,5 с: EQ выкл / свой +12 на 32–125 / −12 / выкл. Звук процесса «Музыки» — сырые отсчёты до AGC.
    @MainActor
    static func measure(_ check: MediaSelfTest.Checker, me: MusicEqualizer, id: String, orig: MusicEqualizer.Snapshot) {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: MusicEqualizer.bundleId).first?.processIdentifier
        else { print("ЗВУК: нет pid Музыки"); return }
        let rec = Recorder()
        let sink = AudioSampleSink { _, _, _, _, _ in }
        sink.raw = { abl, inter, ch in rec.consume(abl, interleaved: inter, channels: ch) }
        let backend = ProcessTapBackend()
        let info: AudioCaptureInfo
        do { info = try backend.start(target: AudioTapTarget(pid: pid, bundleId: MusicEqualizer.bundleId), sink: sink) } catch {
            print("ЗВУК: захват не запустился — \(error)"); return
        }
        defer { backend.stop() }
        print(String(format: "ЗВУК: захват процесса Музыки, %.0f Гц, буфер %d, план %@", info.sampleRate, info.bufferFrames, "\(info.plan)"))

        func window(_ label: String, setup: () -> Void) -> Bands? {
            setup()
            _ = spinUntil(timeout: 0.6) { false }   // EQ применился, старый буфер ушёл
            rec.reset()
            _ = spinUntil(timeout: 2.2) { false }
            let b = Bands.measure(rec.take(), rate: info.sampleRate)
            if let b {
                print(String(format: "  %-26@ низ 25–150 Гц %6.1f дБ · середина 0,5–4 кГц %6.1f дБ · низ−середина %+6.1f дБ · RMS %6.1f дБFS",
                             label as NSString, b.low, b.mid, b.ratio, b.rms))
            } else { print("  \(label): мало отсчётов") }
            return b
        }

        let flat = [Double](repeating: 0, count: 11)
        let off1 = window("EQ выкл") { _ = script(MusicEqualizer.enableScript(false)) }
        let boost = window("свой: +12 на 32/64/125") {
            for i in 0...10 { me.setValue(id, slider: i, to: flat[i]) }
            for i in 1...3 { me.setValue(id, slider: i, to: 12) }
            me.flush(); me.selectCustom(id)
            _ = waitRead(timeout: 2) { $0.enabled && $0.current == me.custom(id)?.name }
        }
        let cut = window("свой: −12 на 32/64/125") {
            for i in 1...3 { me.setValue(id, slider: i, to: -12) }
            me.flush()
            _ = waitRead(timeout: 2) { ($0.currentBands?[1] ?? 0) < -11 }
        }
        let off2 = window("EQ выкл (ещё раз)") { _ = script(MusicEqualizer.enableScript(false)) }
        _ = script(MusicEqualizer.enableScript(orig.enabled))   // сразу вернуть, не дожидаясь конца теста

        guard let o1 = off1, let o2 = off2, let bo = boost, let cu = cut else { check(false, "ЗВУК: все окна измерены"); return }
        guard max(o1.rms, bo.rms, cu.rms, o2.rms) > -90 else {
            print("ЗВУК: захват отдаёт тишину (нет права «Запись системного звука» у процесса из оболочки?) — не измерено")
            return
        }
        let off = (o1.ratio + o2.ratio) / 2
        print(String(format: "ЗВУК: относительно «выкл» (среднее двух окон, разброс %.1f дБ): подъём низов %+.1f дБ, срез %+.1f дБ",
                     abs(o1.ratio - o2.ratio), bo.ratio - off, cu.ratio - off))
        check(bo.ratio - off > 4, "ЗВУК: свой пресет +12 на низах — низов в звуке заметно больше", String(format: "%+.1f дБ", bo.ratio - off))
        check(off - cu.ratio > 4, "ЗВУК: −12 на низах — низов заметно меньше", String(format: "%+.1f дБ", cu.ratio - off))
    }

    /// Энергия полос по сырым отсчётам (моно), БПФ 4096 с окном Ханна.
    struct Bands {
        var low: Double, mid: Double, rms: Double
        var ratio: Double { low - mid }

        static func measure(_ x: [Float], rate: Double) -> Bands? {
            let n = 4096
            guard x.count >= n * 2, let dft = try? vDSP.DiscreteFourierTransform(count: n, direction: .forward,
                                                                                transformType: .complexComplex, ofType: Float.self)
            else { return nil }
            let win = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
            var power = [Double](repeating: 0, count: n / 2)
            var frames = 0
            var i = 0
            let zeros = [Float](repeating: 0, count: n)
            while i + n <= x.count {
                let seg = vDSP.multiply(Array(x[i..<i + n]), win)
                let out = dft.transform(real: seg, imaginary: zeros)
                let re: [Float] = out.real, im: [Float] = out.imaginary
                for k in 0..<(n / 2) {
                    let pr: Float = re[k] * re[k]
                    let pi: Float = im[k] * im[k]
                    power[k] += Double(pr + pi)
                }
                frames += 1; i += n
            }
            func band(_ lo: Double, _ hi: Double) -> Double {
                let a = max(1, Int(lo / rate * Double(n))), b = min(n / 2 - 1, Int(hi / rate * Double(n)))
                let e = power[a...b].reduce(0, +) / Double(max(1, frames))
                return 10 * log10(max(e, 1e-20))
            }
            let ms = x.reduce(0.0) { $0 + Double($1 * $1) } / Double(x.count)
            return Bands(low: band(25, 150), mid: band(500, 4000), rms: 10 * log10(max(ms, 1e-20)))
        }
    }

    /// Сырые отсчёты с потока ввода-вывода (моно), под замком.
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var buf: [Float] = []
        func reset() { lock.lock(); buf.removeAll(keepingCapacity: true); lock.unlock() }
        func take() -> [Float] { lock.lock(); defer { lock.unlock() }; return buf }
        func consume(_ abl: UnsafeMutableAudioBufferListPointer, interleaved: Bool, channels: Int) {
            var mono: [Float] = []
            if interleaved {
                let b = abl[abl.count - 1]
                let ch = max(1, Int(b.mNumberChannels))
                guard let d = b.mData?.assumingMemoryBound(to: Float.self) else { return }
                let frames = Int(b.mDataByteSize) / (4 * ch)
                mono = (0..<frames).map { f in (0..<ch).reduce(Float(0)) { $0 + d[f * ch + $1] } / Float(ch) }
            } else {
                let n = min(max(1, channels), abl.count)
                let bufs = (abl.count - n)..<abl.count
                let frames = bufs.map { Int(abl[$0].mDataByteSize) / 4 }.min() ?? 0
                mono = [Float](repeating: 0, count: frames)
                for j in bufs {
                    guard let d = abl[j].mData?.assumingMemoryBound(to: Float.self) else { continue }
                    for f in 0..<frames { mono[f] += d[f] / Float(n) }
                }
            }
            lock.lock(); if buf.count < 48_000 * 10 { buf += mono }; lock.unlock()
        }
    }

    final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var v: String?
        private var d = false
        func set(_ s: String) { lock.lock(); v = s; d = true; lock.unlock() }
        var done: Bool { lock.lock(); defer { lock.unlock() }; return d }
        var value: String? { lock.lock(); defer { lock.unlock() }; return v }
    }
}
