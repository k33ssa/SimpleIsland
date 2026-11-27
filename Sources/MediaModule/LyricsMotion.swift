import AppKit
import CoreText
import IslandCore
import QuartzCore

/// Экран «Текст» Apple Music: числа из разбора бинарника (`apple-music-native-lyrics/docs/research/lyrics-ui-spec.md`,
/// iOS 26.6.1, пресет `default`) в том виде, как их применяет SimpleLyrics (`App/Sources/Render/LyricsSpecs.swift`,
/// `TextBlock.swift`, `LyricLineLayer.swift`, `LyricsViewController.swift` — тот же автор). У Apple все размеры даны при
/// кегле 34 pt; в острове пространственные величины (растушёвка, подъём, свечение, размытие) пересчитаны на свой кегль
/// множителем `fontSize / 34`, альфы, времена, пружины и масштабы — как есть.
enum AMSpec {
    static let baseFontSize: CGFloat = 34

    // Цвета (альфа цвета текста темы; у Apple — белый поверх фона).
    static let selectedAlpha: CGFloat = 1               // selectedTextColor / lineProgressionGradientColor
    static let selectedUpcomingAlpha: CGFloat = 0.35    // ещё не спетая часть активной строки
    static let deselectedAlpha: CGFloat = 0.175         // неактивные строки
    static let selectedBgAlpha: CGFloat = 0.35          // selectedBackgroundVocalsTextColor
    static let selectedUpcomingBgAlpha: CGFloat = 0.175 // selectedUpcomingBackgroundVocalsTextColor
    /// Светлые темы острова (paper, sakura): тёмный текст на светлом — альфы режима «Увеличить контраст» у Apple
    /// (deselected label α 0.4); неспетое — 0.45 (у Apple в этом режиме 0.85 — тогда фронт заливки не виден).
    static let lightUpcomingAlpha: CGFloat = 0.45
    static let lightDeselectedAlpha: CGFloat = 0.4
    static let lightBgLitAlpha: CGFloat = 0.6
    static let lightBgDimAlpha: CGFloat = 0.4

    // Геометрия при 34 pt.
    static let feather: CGFloat = 30                    // lineProgressionGradientFeather
    static let syllableLift: CGFloat = 2                // syllableLift
    static let glowRadius: CGFloat = 5                  // glowRadius
    static let maxBlurRadius: CGFloat = 4               // radius = min(расстояние в строках, 4)
    static let emphasisScaleMax: CGFloat = 1.14         // emphasizingScaleRange 1…1.14
    static let glowMax: Float = 0.4                     // glowRange 0…0.4
    static let bgFontRatio: CGFloat = 22.0 / 34         // backgroundVocalsFont title2 (22) при largeTitle (34)

    // Время.
    static let animationHeadstart: Double = 0.1         // упреждение (у острова — сдвиг текста `LyricsSync.lineLead`)
    static let lineDelay: Double = 0.05                 // каскад строк при прокрутке
    static let lineFinish: Double = 0.25                // lineFinishProgressAnimationDuration
    static let liftResponse: Double = 1.5               // подъём обычного слога: ζ = 1, response 1.5
    static let lineChangeSpring = LyricSpring(mass: 1, stiffness: 100, damping: 18)
    static let dropSpring = LyricSpring(mass: 1, stiffness: 14, damping: 7)   // «опускание» слога/слова
    static let blurDuration: Double = 0.12
    static let blurCurve = CAMediaTimingFunction(controlPoints: 0.33, 0, 0.2, 0.1)

    /// Остров: соседние строки мельче активной (макет 01: 13 pt при 19 pt). У Apple неактивная — 0.98 при 34 pt и
    /// весь экран под текст; в трёх строках острова нужен заметный шаг.
    static let islandNeighborScale: CGFloat = 13.0 / 19
    /// Зазор между строками острова (pt). У Apple 25 при 34 pt — в 60 pt высоты три строки так не встают.
    static let islandLineGap: CGFloat = 2
    /// Длинная строка: у Apple переносится на следующий ряд. В острове два ряда по 19 pt не встают в 60 pt — ряды
    /// мельче (0,72 → ≈ 13,7 pt), строка выровнена по левому краю. Бегущая строка — только в компакте (там один ряд).
    static let islandWrapScale: CGFloat = 0.72
    /// Если и при 0,72 выходит больше двух рядов по высоте — мельче, по очереди.
    static let islandWrapScales: [CGFloat] = [0.72, 0.64, 0.56, 0.5]

    /// Шрифт строки: у Apple — `.largeTitle` bold (SF Pro Display Bold). Семейство — темы острова (Inter/моно/
    /// скруглённый), вес — bold, для системного шрифта — оптический размер Display (как у 34 pt).
    static func font(_ theme: Theme, size: CGFloat) -> NSFont {
        let weight = NSFont.Weight.bold
        switch theme.font.family {
        case .mono:
            return .monospacedSystemFont(ofSize: size, weight: weight)
        case .Inter:
            if let f = NSFont(name: "Inter", size: size) {
                let d = f.fontDescriptor.addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: weight]])
                return NSFont(descriptor: d, size: size) ?? f
            }
            fallthrough
        case .system:
            var base = NSFont.systemFont(ofSize: size, weight: weight)
            let display = base.fontDescriptor.addingAttributes(
                [NSFontDescriptor.AttributeName(rawValue: kCTFontOpticalSizeAttribute as String): baseFontSize])
            base = NSFont(descriptor: display, size: size) ?? base
            let design: NSFontDescriptor.SystemDesign
            switch theme.font.design {
            case .default: return base
            case .rounded: design = .rounded
            case .monospaced: design = .monospaced
            case .serif: design = .serif
            }
            return base.fontDescriptor.withDesign(design).flatMap { NSFont(descriptor: $0, size: size) } ?? base
        }
    }

    /// Выделение слова (Apple `Lyrics.Word.Emphasis`): d > 1 с и не больше 7 букв → f = min(d, 2) − 1.
    static func emphasis(duration d: Double, letters: Int) -> Double? {
        guard d > 1, letters <= 7, letters > 0 else { return nil }
        return min(d, 2) - 1
    }
}

/// Пружина mass/stiffness/damping с аналитической переходной характеристикой (перенос `Spring` из SimpleLyrics).
struct LyricSpring: Equatable {
    var mass: Double
    var stiffness: Double
    var damping: Double

    /// По dampingRatio/response (как SwiftUI/UIKit): stiffness = (2π/response)², damping = 2ζ√stiffness.
    static func response(_ response: Double, dampingRatio: Double = 1) -> LyricSpring {
        let k = pow(2 * .pi / max(response, 0.0001), 2)
        return LyricSpring(mass: 1, stiffness: k, damping: 2 * dampingRatio * sqrt(k))
    }

    /// Доля пути (0 → 1) через `t` с после старта из покоя.
    func step(_ t: Double) -> Double {
        guard t > 0 else { return 0 }
        let w0 = sqrt(stiffness / mass)
        let zeta = damping / (2 * sqrt(stiffness * mass))
        if zeta < 1 - 1e-6 {
            let wd = w0 * sqrt(1 - zeta * zeta)
            return 1 - exp(-zeta * w0 * t) * (cos(wd * t) + zeta * w0 / wd * sin(wd * t))
        } else if zeta > 1 + 1e-6 {
            let r1 = -w0 * (zeta - sqrt(zeta * zeta - 1))
            let r2 = -w0 * (zeta + sqrt(zeta * zeta - 1))
            return 1 - (r2 * exp(r1 * t) - r1 * exp(r2 * t)) / (r2 - r1)
        }
        return 1 - (1 + w0 * t) * exp(-w0 * t)
    }

    /// Время успокоения (порог 0,1 %, как `CASpringAnimation.settlingDuration`).
    var settlingDuration: Double {
        var t = 0.0, lastOut = 0.0
        while t < 10 {
            t += 1.0 / 120
            if abs(1 - step(t)) > 0.001 { lastOut = t } else if t - lastOut > 0.1 { break }
        }
        return lastOut
    }

    func animation(keyPath: String) -> CASpringAnimation {
        let a = CASpringAnimation(keyPath: keyPath)
        a.mass = mass; a.stiffness = stiffness; a.damping = damping
        a.duration = a.settlingDuration
        return a
    }
}

// MARK: - Сегменты строки

/// Слог/кусок слова с таймингом — единица заливки (перенос `DisplaySegment` из SimpleLyrics).
struct LyricSegment: Equatable {
    var text: String
    var begin: Double
    var end: Double
    /// Без пробела перед сегментом.
    var joins: Bool
    var wordIndex: Int
    /// Выделение слова (f), nil — обычный слог.
    var emphasis: Double?
    var wordBegin: Double
    var wordEnd: Double
    var background: Bool

    /// Слова строки → сегменты. Продолжения (`joins`) — одно слово; CJK-слог делится на символы поровну по времени.
    static func make(_ words: [LyricWord], background: Bool, emphasisAllowed: Bool) -> [LyricSegment] {
        var groups: [[LyricWord]] = []
        for w in words {
            if w.joins, !groups.isEmpty { groups[groups.count - 1].append(w) } else { groups.append([w]) }
        }
        var out: [LyricSegment] = []
        for (gi, g) in groups.enumerated() {
            let wb = g.first!.begin, we = g.last!.end
            let letters = g.map(\.text).joined().filter { $0.isLetter || $0.isNumber }.count
            let emph = emphasisAllowed && !background ? AMSpec.emphasis(duration: we - wb, letters: letters) : nil
            for (wi, w) in g.enumerated() {
                let chars = Array(w.text)
                if chars.count > 1, chars.allSatisfy(\.isCJKIdeograph) {
                    let step = (w.end - w.begin) / Double(chars.count)
                    for (ci, c) in chars.enumerated() {
                        out.append(LyricSegment(text: String(c), begin: w.begin + step * Double(ci),
                                                end: w.begin + step * Double(ci + 1), joins: !(wi == 0 && ci == 0),
                                                wordIndex: gi, emphasis: nil, wordBegin: wb, wordEnd: we, background: background))
                    }
                } else {
                    out.append(LyricSegment(text: w.text, begin: w.begin, end: w.end, joins: wi > 0, wordIndex: gi,
                                            emphasis: emph, wordBegin: wb, wordEnd: we, background: background))
                }
            }
        }
        return out
    }
}

extension Character {
    var isCJKIdeograph: Bool {
        guard let s = unicodeScalars.first?.value else { return false }
        return (0x4E00...0x9FFF).contains(s) || (0x3400...0x4DBF).contains(s) || (0x3040...0x30FF).contains(s)
            || (0xAC00...0xD7AF).contains(s) || (0xF900...0xFAFF).contains(s)
    }
}

// MARK: - Фронт заливки

/// Край заливки строки во времени (перенос `TextBlock.fillEdge` из SimpleLyrics): внутри слога край идёт линейно от
/// его начала к концу, между слогами стоит, растушёвка шириной `feather` центрирована на крае и одна на всю строку —
/// поэтому фронт проходит через границы слогов без скачков. Два отличия от SimpleLyrics, чтобы не было рывка на
/// ширину растушёвки: до начала строки край стоит на `x0 − f/2` (всё тускло) и первый слог стартует оттуда; после
/// конца последнего слога край доезжает до полной заливки за `lineFinishProgressAnimationDuration` 0,25 с (Apple:
/// «окончание прогресса — t + finishLineAnimationDuration»).
struct FillFront: Equatable {
    struct Span: Equatable { var x0: CGFloat; var x1: CGFloat; var begin: Double; var end: Double }
    var spans: [Span]
    var minX: CGFloat
    var maxX: CGFloat
    var feather: CGFloat
    var finish: Double = AMSpec.lineFinish

    init(spans: [Span], minX: CGFloat, maxX: CGFloat, feather: CGFloat) {
        self.spans = spans.sorted { $0.begin < $1.begin || ($0.begin == $1.begin && $0.x0 < $1.x0) }
        self.minX = minX
        self.maxX = maxX
        self.feather = feather
    }

    /// Край, при котором вся строка залита.
    var fullEdge: CGFloat { maxX + feather }
    /// Край «ничего не залито».
    var emptyEdge: CGFloat { (spans.first?.x0 ?? minX) - feather / 2 }
    var lastEnd: Double { spans.map(\.end).max() ?? -.infinity }

    /// Край в момент `t` (координаты строки). Доля заливки точки x: clamp(0,5 − (x − edge)/f).
    func edge(at t: Double) -> CGFloat {
        guard let first = spans.first else { return fullEdge }
        let le = lastEnd
        if t >= le {
            // Доливка до конца строки за 0,25 с от того места, где стоял край.
            let from = holdEdge(before: le)
            let p = finish > 0 ? CGFloat(min(1, (t - le) / finish)) : 1
            return from + (fullEdge - from) * p
        }
        var edge = emptyEdge
        for (i, s) in spans.enumerated() {
            if t >= s.end { edge = max(edge, s.x1) }
            else if t >= s.begin {
                let x0 = i == 0 && s.x0 <= first.x0 ? s.x0 - feather / 2 : s.x0
                let frac = CGFloat((t - s.begin) / max(0.001, s.end - s.begin))
                edge = max(edge, x0 + (s.x1 - x0) * frac)
                break
            } else { break }
        }
        return edge
    }

    /// Край, на котором строка стоит сразу после конца последнего слога (до доливки).
    private func holdEdge(before le: Double) -> CGFloat {
        var edge = emptyEdge
        for s in spans where s.end <= le { edge = max(edge, s.x1) }
        return edge
    }

    /// Ключевые точки (время трека → край) для `CAKeyframeAnimation`: между точками край линеен, скачки — две точки
    /// с одним временем. Совпадает с `edge(at:)` (проверяет самотест).
    func keyframes() -> [(Double, CGFloat)] {
        guard !spans.isEmpty else { return [] }
        var times = Set<Double>()
        for s in spans { times.insert(s.begin); times.insert(s.end) }
        let le = lastEnd
        times.insert(le + finish)
        let sorted = times.filter { $0 <= le + finish }.sorted()
        var pts: [(Double, CGFloat)] = []
        for b in sorted {
            let l = edge(at: b - 1e-7), r = edge(at: b)
            if abs(l - r) > 0.01 { pts.append((b, l)) }
            pts.append((b, r))
        }
        return pts
    }
}

// MARK: - Подъём, рост, свечение

/// Состояние узла (слог или глиф выделенного слова) в момент `t`: перенос `TextBlock.update` из SimpleLyrics.
enum NodeMotion {
    struct State: Equatable { var scale: CGFloat; var lift: CGFloat; var glow: Float }

    /// Обычный слог: подъём на `lift` пружиной ζ = 1, response 1,5 с от начала слога.
    static func syllable(begin: Double, t: Double, lift: CGFloat) -> State {
        State(scale: 1, lift: lift * CGFloat(LyricSpring.response(AMSpec.liftResponse).step(t - begin)), glow: 0)
    }

    /// Задержка глифа в «волне» выделенного слова: min(d / n · 0,4, 0,4) на каждый глиф.
    static func stagger(wordDuration d: Double, glyphs n: Int) -> Double { min(d / Double(max(1, n)) * 0.4, 0.4) }

    /// Глиф выделенного слова: рост до 1 + 0,14·f и подъём пружиной ζ = 1, response min(d, 3) (с волной по глифам),
    /// после конца слова рост и свечение спадают пружиной 1/14/7; свечение — 0,4·f.
    static func emphasized(f: Double, wordBegin: Double, wordEnd: Double, glyph i: Int, of n: Int, t: Double,
                           lift: CGFloat) -> State {
        let d = wordEnd - wordBegin
        let rise = LyricSpring.response(min(d, 3)).step(t - wordBegin - stagger(wordDuration: d, glyphs: n) * Double(i))
        let fall = AMSpec.dropSpring.step(t - wordEnd)
        let amount = rise * (1 - fall)
        return State(scale: 1 + (AMSpec.emphasisScaleMax - 1) * CGFloat(f * amount), lift: lift * CGFloat(rise),
                     glow: AMSpec.glowMax * Float(f * amount))
    }

    /// Сколько секунд после начала слова идёт движение глифов (для длины ключевой анимации).
    static func emphasisSpan(wordBegin: Double, wordEnd: Double, glyphs n: Int) -> Double {
        let d = wordEnd - wordBegin
        let riseEnd = stagger(wordDuration: d, glyphs: n) * Double(max(0, n - 1)) + LyricSpring.response(min(d, 3)).settlingDuration
        return max(riseEnd, d + AMSpec.dropSpring.settlingDuration)
    }

    /// Матрица узла: масштаб от центра слова по x и от базовой линии по y, подъём вверх (ось y вниз).
    static func transform(_ s: State, nodeMidX: CGFloat, wordCenterX: CGFloat, baselineFromCenter: CGFloat) -> CATransform3D {
        let dx = (nodeMidX - wordCenterX) * (s.scale - 1)
        let dy = -baselineFromCenter * (s.scale - 1) - s.lift
        return CATransform3DScale(CATransform3DMakeTranslation(dx, dy, 0), s.scale, s.scale, 1)
    }
}

// MARK: - Размытие слоя

/// Размытие строки фильтром сервера отрисовки `gaussianBlur` (ключ `filters.gaussianBlur.inputRadius`, как у Apple).
/// Класс `CAFilter` не публичный — берётся по имени; нет его — строки просто без размытия.
enum LayerBlur {
    private static let filterClass: AnyObject? = NSClassFromString("CAFilter")
    static let keyPath = "filters.gaussianBlur.inputRadius"
    static var isAvailable: Bool { filterClass != nil }

    static func install(on layer: CALayer) {
        guard let cls = filterClass,
              let filter = cls.perform(NSSelectorFromString("filterWithType:"), with: "gaussianBlur")?.takeUnretainedValue() as? NSObject
        else { return }
        filter.setValue(0, forKey: "inputRadius")
        layer.filters = [filter]
    }

    static func radius(of layer: CALayer, presented: Bool = true) -> CGFloat {
        let l = presented ? (layer.presentation() ?? layer) : layer
        return (l.value(forKeyPath: keyPath) as? CGFloat) ?? (layer.value(forKeyPath: keyPath) as? CGFloat) ?? 0
    }

    static func set(_ radius: CGFloat, on layer: CALayer, duration: Double) {
        guard isAvailable, layer.filters?.isEmpty == false else { return }
        let from = Self.radius(of: layer)
        layer.setValue(radius, forKeyPath: keyPath)
        layer.removeAnimation(forKey: "blur")
        guard duration > 0, abs(from - radius) > 0.01 else { return }
        let a = CABasicAnimation(keyPath: keyPath)
        a.fromValue = from
        a.toValue = radius
        a.duration = duration
        a.timingFunction = AMSpec.blurCurve
        layer.add(a.startingNow(on: layer), forKey: "blur")
    }
}

extension CAAnimation {
    /// Начало «сейчас» явным временем слоя (не 0 = «при фиксации»): кадр `CARenderer` на заданный момент видит начало
    /// анимации, а не модель (16.11, кадры `--render-lyrics-frames`). В окне разницы нет.
    func startingNow(on layer: CALayer) -> Self {
        beginTime = layer.convertTime(CACurrentMediaTime(), from: nil)
        fillMode = .backwards
        return self
    }
}
