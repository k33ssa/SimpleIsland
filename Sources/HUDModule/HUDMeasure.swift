import AppKit
import SwiftUI
import IslandCore

/// Ширина «ушей» по настоящим размерам текста в шрифте темы (а не «6,6 pt на символ»): у моноширинных тем
/// (pixel, terminal) буквы шире, и подпись иначе упирается в вырез. Ядро (`EarsLayout`) зазора у выреза не
/// оставляет — оставляем его здесь.
@MainActor
enum HUDMeasure {
    /// Отступ уха от внешнего края острова (как `inset` у `EarsLayout` для HUD).
    nonisolated static let outerInset: CGFloat = 12
    /// Минимальный зазор между содержимым уха и краем выреза.
    nonisolated static let notchGap: CGFloat = 8
    nonisolated static let minSide: CGFloat = 104
    nonisolated static let maxSide: CGFloat = 200
    /// Ширина выреза, если настоящую не узнать (снимки — `--notch 185x32`).
    nonisolated static let defaultNotch: CGFloat = 185

    /// NSFont, повторяющий `Theme.font(size, weight)`.
    static func font(_ size: CGFloat, _ weight: NSFont.Weight, theme: Theme, digits: Bool = false) -> NSFont {
        switch theme.font.family {
        case .mono:
            return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        case .Inter:
            let d = NSFontDescriptor(fontAttributes: [.family: "Inter", .traits: [NSFontDescriptor.TraitKey.weight: weight]])
            if NSFont(name: "Inter", size: size) != nil, let f = NSFont(descriptor: d, size: size) { return f }
            fallthrough
        case .system:
            let base = digits ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
                              : NSFont.systemFont(ofSize: size, weight: weight)
            let design: NSFontDescriptor.SystemDesign
            switch theme.font.design {
            case .default: return base
            case .rounded: design = .rounded
            case .monospaced: design = .monospaced
            case .serif: design = .serif
            }
            guard let d = base.fontDescriptor.withDesign(design), let f = NSFont(descriptor: d, size: size) else { return base }
            return f
        }
    }

    static func text(_ s: String, size: CGFloat = 12.5, weight: NSFont.Weight = .semibold, theme: Theme,
                     digits: Bool = false) -> CGFloat {
        guard !s.isEmpty else { return 0 }
        let w = NSAttributedString(string: s, attributes: [.font: font(size, weight, theme: theme, digits: digits)])
            .size().width
        return ceil(w) + 1
    }

    static func symbol(_ name: String?, size: CGFloat = 14) -> CGFloat {
        guard let name, let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .semibold)) else { return name == nil ? 0 : size + 4 }
        return ceil(img.size.width)
    }

    /// Ухо под содержимое шириной `content` (без отступов): + внешний отступ + зазор у выреза.
    static func side(_ contents: CGFloat..., min lo: CGFloat = minSide) -> CGFloat {
        let need = (contents.max() ?? 0) + outerInset + notchGap
        return Swift.min(maxSide, Swift.max(lo, ceil(need)))
    }

    /// Сколько места под подпись остаётся в ухе максимальной ширины рядом со значком.
    static func maxLabelWidth(iconWidth: CGFloat) -> CGFloat {
        maxSide - outerInset - notchGap - iconWidth - 7
    }

    /// Обрезать подпись с «…», чтобы влезла в `width` (длинное имя устройства не залезает под вырез даже
    /// в самом широком ухе).
    static func fit(_ s: String, width: CGFloat, size: CGFloat = 12.5, weight: NSFont.Weight = .semibold,
                    theme: Theme) -> String {
        guard text(s, size: size, weight: weight, theme: theme) > width else { return s }
        var chars = Array(s)
        while chars.count > 1 {
            chars.removeLast()
            let cand = String(chars).trimmingCharacters(in: .whitespaces) + "…"
            if text(cand, size: size, weight: weight, theme: theme) <= width { return cand }
        }
        return "…"
    }

    /// Ширина выреза на встроенном экране; нет выреза — значение по умолчанию.
    static func liveNotchWidth() -> CGFloat {
        for s in NSScreen.screens where s.safeAreaInsets.top > 0 {
            if let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
                let w = s.frame.width - l.width - r.width
                if w > 0, w < s.frame.width / 2 { return w }
            }
        }
        return defaultNotch
    }

    /// «Заливка»: край уровня идёт по видимым крыльям (`HUDFillBackground.edgeX`: 0–50 % — левое, 50–100 % —
    /// правое, вырез пропускается). Чтобы край не резал текст справа (`valueText`), расширить уши так, чтобы от
    /// края заливки до внешнего края было не меньше места под текст. Если для этого нужно ухо шире максимума
    /// (уровень 90+ %), край ляжет за текстом — оставляем как есть. `notch` = 0 — остров без выреза (линейно).
    static func sideClearingFillEdge(value: Double, trailingText: CGFloat, notch: CGFloat, current: CGFloat) -> CGFloat {
        let need = trailingText + outerInset + 6
        func clears(_ side: CGFloat) -> Bool {
            let w = 2 * side + notch
            return w - HUDFillBackground.edgeX(value: value, width: w, notch: notch) >= need
        }
        if value >= 0.98 || clears(current) { return current }
        // Правое крыло: от края до внешнего края 2·(1 − v)·side (без выреза — (1 − v)·w, этого не меньше).
        let rest = 2 * (1 - min(1, max(0, value)))
        var s = ceil(need / rest)
        while s <= maxSide, !clears(s) { s += 1 }
        return s <= maxSide ? max(current, s) : current
    }
}
