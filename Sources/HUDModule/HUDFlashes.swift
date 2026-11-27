import SwiftUI
import IslandCore

/// Готовые вспышки по макету 06. Одни и те же фабрики — у живых событий и у снимков, так снимки показывают
/// ровно то, что увидит пользователь.
@MainActor
enum HUDFlashes {
    static let brightnessTint = Color(hex: "#FFC85A")
    static let capsTint = Color(hex: "#FF9F45")
    /// «Плохо» (Нет сети): розово-красный, как в макете 06, событие 09.
    static let badTint = Color(hex: "#FF8AA0")

    // MARK: Громкость, яркость, подсветка

    static func volumeSymbol(_ v: Double, muted: Bool) -> String {
        if muted { return "speaker.slash.fill" }
        if v <= 0.001 { return "speaker.fill" }
        if v < 0.34 { return "speaker.wave.1.fill" }
        if v < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    /// Ширина правого уха у полосы по стилю. nil — стиль из настроек (`fallback`, у живых событий — текущий
    /// `settings.hudStyle`; без него — «нить»). Сегментов до 16 (как в ядре, `HUDTrailing`).
    static func barWidth(_ style: HUDBarStyle?, segments: Int = 16, fallback: HUDBarStyle = .thread, theme: Theme) -> CGFloat {
        switch style ?? fallback {
        case .segments:
            let n = CGFloat(max(1, min(segments, 16)))
            return n * 5 + (n - 1) * 3
        case .fill:
            return 24
        case .number:
            return HUDMeasure.text("100", size: 17, weight: .heavy, theme: theme, digits: true)
                + HUDMeasure.text("%", size: 11, weight: .semibold, theme: theme) + 1
        case .thread:
            return 70 + 8 + 24
        }
    }

    /// Ухо для стандартной вспышки: значок + подпись слева, полоса/текст справа.
    static func standardSide(symbol: String?, label: String?, labelWeight: NSFont.Weight = .semibold,
                             trailing: CGFloat, min lo: CGFloat, theme: Theme) -> CGFloat {
        var lead = HUDMeasure.symbol(symbol)
        if let label { lead += (symbol == nil ? 0 : 7) + HUDMeasure.text(label, weight: labelWeight, theme: theme) }
        return HUDMeasure.side(lead, trailing, min: lo)
    }

    static func fitLabel(_ s: String?, symbol: String?, weight: NSFont.Weight = .semibold, theme: Theme) -> String? {
        guard let s else { return nil }
        return HUDMeasure.fit(s, width: HUDMeasure.maxLabelWidth(iconWidth: HUDMeasure.symbol(symbol)),
                              weight: weight, theme: theme)
    }

    static func volume(_ v: Double, muted: Bool, device: String?, style: HUDBarStyle?, fallback: HUDBarStyle = .thread,
                       theme: Theme) -> HUDEvent {
        let symbol = volumeSymbol(v, muted: muted)
        let label = fitLabel(device, symbol: symbol, theme: theme)
        // Без звука — понятное «без звука» справа, а не точка на нити и «0».
        let valueText: String? = muted ? "без звука" : nil
        let trailing = muted ? HUDMeasure.text("без звука", weight: .bold, theme: theme)
            : barWidth(style, fallback: fallback, theme: theme)
        return HUDEvent(kind: "volume", systemImage: symbol, label: label,
                        value: muted ? nil : clamp(v), valueText: valueText, style: style,
                        sideWidth: standardSide(symbol: symbol, label: label, trailing: trailing, min: 120, theme: theme))
    }

    /// Яркость. `auto` — включена автояркость: подпись «авто» (макет 06, событие 02).
    static func brightness(_ v: Double, auto: Bool = false, style: HUDBarStyle?, fallback: HUDBarStyle = .thread,
                           theme: Theme) -> HUDEvent {
        let symbol = v < 0.3 ? "sun.min.fill" : "sun.max.fill"
        let label: String? = auto ? "авто" : nil
        var e = HUDEvent(kind: "brightness", systemImage: symbol, label: label,
                         value: clamp(v), tint: IslandPalette.readable(brightnessTint, on: theme), style: style,
                         sideWidth: standardSide(symbol: symbol, label: label,
                                                 trailing: barWidth(style, fallback: fallback, theme: theme),
                                                 min: 120, theme: theme))
        if auto { e.accessibilityLabel = "Яркость, автоматически, \(Int((clamp(v) * 100).rounded())) %" }
        return e
    }

    /// Подсветка клавиатуры — только значок клавиатуры и сегменты (макет 06, событие 03).
    static func keyboard(_ v: Double, style: HUDBarStyle?, fallback: HUDBarStyle = .thread, theme: Theme) -> HUDEvent {
        HUDEvent(kind: "keyboard", systemImage: "keyboard", value: clamp(v), style: style, segments: 10,
                 sideWidth: standardSide(symbol: "keyboard", label: nil,
                                         trailing: barWidth(style, segments: 10, fallback: fallback, theme: theme),
                                         min: 120, theme: theme))
    }

    /// Время до полной/пустой показываем, только если оно правдоподобно (IOPS иногда отдаёт десятки часов).
    nonisolated static func plausibleMinutes(_ m: Int?) -> Int? {
        guard let m, m > 0, m <= 600 else { return nil }
        return m
    }

    // MARK: Питание

    static func duration(minutes m: Int) -> String {
        if m < 60 { return "\(m) мин" }
        let h = m / 60, r = m % 60
        return r == 0 ? "\(h) ч" : "\(h) ч \(r) мин"
    }

    static func batterySymbol(_ percent: Int) -> String {
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    /// Вспышка батареи «Заливкой»: уши по ширине подписи и `valueText` в шрифте темы; край заливки не режет текст.
    static func battery(symbol: String, label: String, percent: Int, text: String, tint: Color?, theme: Theme,
                        notch: CGFloat) -> HUDEvent {
        let value = Double(percent) / 100
        let trailing = HUDMeasure.text(text, weight: .bold, theme: theme, digits: true)
        var side = standardSide(symbol: symbol, label: label, labelWeight: .bold, trailing: trailing, min: 132, theme: theme)
        side = HUDMeasure.sideClearingFillEdge(value: value, trailingText: trailing, notch: notch, current: side)
        return HUDEvent(kind: "battery", systemImage: symbol, label: label, value: value, valueText: text, tint: tint,
                        style: .fill, sideWidth: side)
    }

    /// Подключили зарядку: остров наливается зелёным до уровня заряда.
    static func charging(percent: Int, minutesToFull: Int?, isCharging: Bool, theme: Theme,
                         notch: CGFloat = HUDMeasure.defaultNotch) -> HUDEvent {
        var text = "\(percent)%"
        if isCharging, let m = plausibleMinutes(minutesToFull) { text += " · " + duration(minutes: m) }
        return battery(symbol: isCharging ? "bolt.fill" : "powerplug.fill", label: isCharging ? "Заряжается" : "Подключено",
                       percent: percent, text: text, tint: IslandPalette.ok, theme: theme, notch: notch)
    }

    static func charged(percent: Int, theme: Theme, notch: CGFloat = HUDMeasure.defaultNotch) -> HUDEvent {
        battery(symbol: "battery.100percent.bolt", label: "Заряжено", percent: percent, text: "\(percent)%",
                tint: IslandPalette.ok, theme: theme, notch: notch)
    }

    static func unplugged(percent: Int, minutesToEmpty: Int?, theme: Theme,
                          notch: CGFloat = HUDMeasure.defaultNotch) -> HUDEvent {
        var text = "\(percent)%"
        if let m = plausibleMinutes(minutesToEmpty) { text += " · " + duration(minutes: m) }
        return battery(symbol: batterySymbol(percent), label: "От батареи", percent: percent, text: text, tint: nil,
                       theme: theme, notch: notch)
    }

    static func lowBattery(percent: Int, theme: Theme, notch: CGFloat = HUDMeasure.defaultNotch) -> HUDEvent {
        // Что случилось + что сделать: «Мало заряда · 10% · подключи» (политика уведомлений, UX 15.11).
        battery(symbol: "battery.25percent", label: "Мало заряда", percent: percent, text: "\(percent)% · подключи",
                tint: IslandPalette.err, theme: theme, notch: notch)
    }

    // MARK: Наушники

    static func headphonesSymbol(_ name: String) -> String {
        let n = name.lowercased()
        if n.contains("airpods max") { return "airpodsmax" }
        if n.contains("airpods pro") { return "airpodspro" }
        if n.contains("airpods") { return "airpods" }
        if n.contains("beats") { return "beats.headphones" }
        return "headphones"
    }

    /// Подключились наушники — карточка под вырезом (макет 06, событие 04): слева значок, имя и «Подключены»,
    /// справа заряд в две строки «L 82% · R 80%» / «кейс 54%». Заряда не узнали — правой части нет.
    static func headphonesConnected(name: String, battery: HeadphonesBattery?) -> IslandNotification {
        var n = IslandNotification(id: "hud.bt.\(name)", moduleId: "hud", title: name, body: "Подключены",
                                   icon: AnyView(HeadphonesBadge(symbol: headphonesSymbol(name))),
                                   duration: 4)
        if let b = battery, let lines = b.lines {
            n.trailing = AnyView(HeadphonesBatteryView(top: lines.top, bottom: lines.bottom))
            n.trailingAccessibilityLabel = "Заряд: " + (b.text ?? "")
        }
        return n
    }

    /// Левое ухо «значок + подпись» (`HUDTag`): ширина.
    static func tagWidth(_ text: String, symbol: String, theme: Theme) -> CGFloat {
        HUDMeasure.symbol(symbol, size: 13.5) + 7 + HUDMeasure.text(text, weight: .bold, theme: theme)
    }

    static func noteWidth(_ text: String, theme: Theme) -> CGFloat {
        HUDMeasure.text(text, weight: .semibold, theme: theme)
    }

    /// Обрезать текст правого уха (`HUDNote`), чтобы не упирался в вырез.
    static func fitNote(_ s: String, theme: Theme) -> String {
        HUDMeasure.fit(s, width: HUDMeasure.maxSide - HUDMeasure.outerInset - HUDMeasure.notchGap, theme: theme)
    }

    static func fitTag(_ s: String, symbol: String, theme: Theme) -> String {
        let room = HUDMeasure.maxSide - HUDMeasure.outerInset - HUDMeasure.notchGap - HUDMeasure.symbol(symbol, size: 13.5) - 7
        return HUDMeasure.fit(s, width: room, weight: .bold, theme: theme)
    }

    static func headphonesDisconnected(name: String, theme: Theme) -> HUDEvent {
        let symbol = headphonesSymbol(name)
        let n = fitTag(name, symbol: symbol, theme: theme)
        return HUDEvent(kind: "bluetooth",
                        sideWidth: HUDMeasure.side(tagWidth(n, symbol: symbol, theme: theme),
                                                   noteWidth("отключены", theme: theme), min: 120),
                        customLeading: AnyView(HUDTag(text: n, systemImage: symbol, tone: .plain)),
                        customTrailing: AnyView(HUDNote(text: "отключены")))
    }

    // MARK: Раскладка, Caps Lock

    static func layout(from: String?, to: String, capsOn: Bool, theme: Theme) -> HUDEvent {
        let lead = HUDMeasure.symbol("globe", size: 12.5) + (from.map { 6 + HUDMeasure.text($0, weight: .bold, theme: theme) } ?? 0)
        let trail = (capsOn ? 12 : 0) + HUDMeasure.symbol("arrow.right", size: 11) + 6
            + HUDMeasure.text(to, weight: .heavy, theme: theme) + 14
        return HUDEvent(kind: "layout", sideWidth: HUDMeasure.side(lead, trail, min: capsOn ? 84 : 72),
                        customLeading: AnyView(LayoutFrom(code: from)),
                        customTrailing: AnyView(LayoutTo(code: to, capsOn: capsOn)))
    }

    static func capsLock(on: Bool, theme: Theme) -> HUDEvent {
        let symbol = on ? "capslock.fill" : "capslock"
        let trail = (on ? 13 : 0) + HUDMeasure.text(on ? "вкл" : "выкл", weight: .bold, theme: theme)
        return HUDEvent(kind: "capslock",
                        sideWidth: HUDMeasure.side(tagWidth("Caps Lock", symbol: symbol, theme: theme), trail, min: 112),
                        customLeading: AnyView(HUDTag(text: "Caps Lock", systemImage: symbol, tone: on ? .caps : .plain)),
                        customTrailing: AnyView(CapsState(on: on)))
    }

    // MARK: Камера и микрофон

    static func captureIconsWidth(camera: Bool, microphone: Bool) -> CGFloat {
        7 + (camera ? 7 + HUDMeasure.symbol("camera", size: 12.5) : 0)
            + (microphone ? 7 + HUDMeasure.symbol("mic.fill", size: 12.5) : 0)
    }

    static func capture(camera: Bool, microphone: Bool, app: String?, theme: Theme) -> HUDEvent {
        let fallback = camera && microphone ? "камера и микрофон" : (camera ? "камера" : "микрофон")
        let note = fitNote(app ?? fallback, theme: theme)
        return HUDEvent(kind: "capture",
                        sideWidth: HUDMeasure.side(captureIconsWidth(camera: camera, microphone: microphone),
                                                   noteWidth(note, theme: theme), min: 104),
                        customLeading: AnyView(CaptureIcons(camera: camera, microphone: microphone)),
                        customTrailing: AnyView(HUDNote(text: note)))
    }

    // MARK: Сеть

    static func network(online: Bool, interface: String?, theme: Theme) -> HUDEvent {
        let symbol: String
        switch (online, interface) {
        case (false, _): symbol = "wifi.slash"
        case (true, "Ethernet"): symbol = "cable.connector"
        case (true, "Wi-Fi"): symbol = "wifi"
        default: symbol = "network"
        }
        let text = online ? "Сеть есть" : "Нет сети"
        let note = online ? (interface ?? "сеть") : "проверь Wi-Fi"
        return HUDEvent(kind: "network",
                        sideWidth: HUDMeasure.side(tagWidth(text, symbol: symbol, theme: theme), noteWidth(note, theme: theme),
                                                   min: 120),
                        customLeading: AnyView(HUDTag(text: text, systemImage: symbol, tone: online ? .ok : .bad)),
                        customTrailing: AnyView(HUDNote(text: note)))
    }

    static func clamp(_ v: Double) -> Double { min(1, max(0, v.isFinite ? v : 0)) }
}

/// Заряд наушников (что удалось узнать).
struct HeadphonesBattery: Equatable {
    var left: Int?
    var right: Int?
    var caseLevel: Int?
    var single: Int?

    var isEmpty: Bool { left == nil && right == nil && caseLevel == nil && single == nil }

    var text: String? {
        var parts: [String] = []
        if let l = left, let r = right { parts.append("L \(l)% · R \(r)%") }
        else if let l = left { parts.append("L \(l)%") }
        else if let r = right { parts.append("R \(r)%") }
        else if let s = single { parts.append("\(s)%") }
        if let c = caseLevel { parts.append("кейс \(c)%") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Две строки для правой части карточки: наушники (L/R или общий) и кейс.
    var lines: (top: String, bottom: String?)? {
        var top: String?
        if let l = left, let r = right { top = "L \(l)% · R \(r)%" }
        else if let l = left { top = "L \(l)%" }
        else if let r = right { top = "R \(r)%" }
        else if let s = single { top = "\(s)%" }
        let bottom = caseLevel.map { "кейс \($0)%" }
        guard let t = top ?? bottom else { return nil }
        return (t, top == nil ? nil : bottom)
    }
}
