import AppKit
import CoreText
import QuartzCore

/// Одна строка текста песни на Core Animation (перенос `TextBlock`/`LyricLineLayer` из SimpleLyrics на анимации,
/// заданные один раз на строку): каждый слог (у выделенного слова — каждый глиф) — свой узел с тусклым и ярким
/// слоем; яркий открывает маска-градиент «сплошь → растушёвка 30 pt (при 34 pt) → пусто», край которой едет по
/// `FillFront` одной ключевой анимацией на узел. Подъём, рост, свечение — пружины/ключевые анимации слоёв. Процесс
/// просыпается только при смене строки и перемотке, кадры считает сервер отрисовки.
@MainActor
final class LyricLineLayer {
    struct Style: Equatable {
        var color: NSColor
        var upcoming: CGFloat      // неспетое у активной
        var deselected: CGFloat    // неактивная строка
        var bgLit: CGFloat
        var bgDim: CGFloat
        var bgDeselected: CGFloat

        static func make(color: NSColor, light: Bool) -> Style {
            light ? Style(color: color, upcoming: AMSpec.lightUpcomingAlpha, deselected: AMSpec.lightDeselectedAlpha,
                          bgLit: AMSpec.lightBgLitAlpha, bgDim: AMSpec.lightBgDimAlpha, bgDeselected: AMSpec.lightBgDimAlpha)
                  : Style(color: color, upcoming: AMSpec.selectedUpcomingAlpha, deselected: AMSpec.deselectedAlpha,
                          bgLit: AMSpec.selectedBgAlpha, bgDim: AMSpec.selectedUpcomingBgAlpha,
                          bgDeselected: AMSpec.selectedUpcomingBgAlpha)
        }
    }

    final class Node {
        let container = CALayer()
        let dim = CALayer()
        let lit = CALayer()
        let mask = CAGradientLayer()
        let seg: LyricSegment
        let glyphIndex: Int
        let glyphCount: Int
        let wordCenterX: CGFloat
        let baselineFromCenter: CGFloat
        /// Левый край картинки узла в координатах строки.
        let originX: CGFloat
        let midX: CGFloat
        /// Ряд строки (длинная строка переносится, как у Apple).
        let row: Int
        init(seg: LyricSegment, glyphIndex: Int, glyphCount: Int, wordCenterX: CGFloat, baselineFromCenter: CGFloat,
             originX: CGFloat, midX: CGFloat, row: Int) {
            self.seg = seg; self.glyphIndex = glyphIndex; self.glyphCount = glyphCount; self.wordCenterX = wordCenterX
            self.baselineFromCenter = baselineFromCenter; self.originX = originX; self.midX = midX; self.row = row
        }
    }

    let root = CALayer()
    let scroller = CALayer()
    private(set) var nodes: [Node] = []
    let line: LyricLine
    let fontSize: CGFloat
    let style: Style
    /// Пословная заливка (иначе — построчный текст: активная строка горит целиком, как `crossfade` у Apple).
    let gradient: Bool
    /// Фронт первого ряда (у однорядной строки — единственный).
    var mainFront: FillFront { fronts[0]?.main ?? FillFront(spans: [], minX: 0, maxX: 0, feather: feather) }
    /// Фронты по рядам: свой край у основного вокала и фона в каждом ряду (как `TextBlock.fillEdge(row:)`).
    private(set) var fronts: [Int: (main: FillFront, bg: FillFront?)] = [:]
    /// Ширина текста одним рядом (до переноса).
    let textWidth: CGFloat
    /// Высота одного ряда.
    let boxHeight: CGFloat
    /// Рядов после переноса и масштаб переноса: длинная активная строка у Apple переносится; в 60 pt острова два
    /// ряда помещаются только мельче — `islandWrapScale`. Слой строки масштабируется от левого края (anchor x = 0).
    let rows: Int
    let fit: CGFloat
    var height: CGFloat { CGFloat(rows) * boxHeight }
    let feather: CGFloat
    let lift: CGFloat
    /// Длина сплошной части маски: при краю за концом строки маска закрывает узел целиком.
    private let maskSolid: CGFloat
    private(set) var selected = false
    var visibleWidth: CGFloat

    static let noActions: [String: CAAction] = ["position": NSNull(), "bounds": NSNull(), "transform": NSNull(),
                                                 "frame": NSNull(), "contents": NSNull(), "opacity": NSNull(),
                                                 "shadowOpacity": NSNull(), "sublayers": NSNull(), "hidden": NSNull(),
                                                 "anchorPoint": NSNull(), "filters": NSNull(), "mask": NSNull()]

    /// - Parameters: `effects` — подъём/рост/свечение (нет в компакте).
    init(line: LyricLine, font: NSFont, bgFont: NSFont, style: Style, scale: CGFloat, visibleWidth: CGFloat,
         effects: Bool, wrap: Bool = true) {
        self.line = line
        self.fontSize = font.pointSize
        self.style = style
        self.visibleWidth = visibleWidth
        let k = font.pointSize / AMSpec.baseFontSize
        feather = max(4, AMSpec.feather * k)
        lift = effects ? AMSpec.syllableLift * k : 0
        gradient = line.isWordSynced
        root.actions = Self.noActions
        scroller.actions = Self.noActions
        root.anchorPoint = CGPoint(x: 0, y: 0.5)
        scroller.anchorPoint = .zero
        root.addSublayer(scroller)

        // Сегменты: пословно — слоги со временем; построчно — слова без времени (горят целиком).
        var segs: [LyricSegment]
        if gradient {
            segs = LyricSegment.make(line.words, background: false, emphasisAllowed: effects)
            segs += LyricSegment.make(line.background, background: true, emphasisAllowed: false)
        } else {
            let t = line.time
            segs = line.text.split(separator: " ").enumerated().map { i, p in
                LyricSegment(text: String(p), begin: t, end: t, joins: false, wordIndex: i, emphasis: nil,
                             wordBegin: t, wordEnd: t, background: false)
            }
        }
        // Одна строка CoreText: позиции слогов — со своим кернингом; фон-вокал — после основного, своим шрифтом.
        let color = style.color.cgColor
        func attrs(_ f: NSFont) -> [NSAttributedString.Key: Any] {
            [NSAttributedString.Key(kCTFontAttributeName as String): f as CTFont,
             NSAttributedString.Key(kCTForegroundColorAttributeName as String): color]
        }
        let full = NSMutableAttributedString()
        var ranges: [NSRange] = []
        for (i, s) in segs.enumerated() {
            let f = s.background ? bgFont : font
            if i > 0 {
                if s.background && !segs[i - 1].background {
                    full.append(NSAttributedString(string: "  ", attributes: attrs(font)))
                } else if !s.joins {
                    full.append(NSAttributedString(string: " ", attributes: attrs(f)))
                }
            }
            let start = full.length
            full.append(NSAttributedString(string: s.text, attributes: attrs(f)))
            ranges.append(NSRange(location: start, length: full.length - start))
        }
        let ascent = ceil(font.ascender), descent = ceil(-font.descender)
        boxHeight = ascent + descent
        let oneLine = CTLineCreateWithAttributedString(full)
        textWidth = ceil(CGFloat(CTLineGetTypographicBounds(oneLine, nil, nil, nil)))
        // Перенос: не влезает в ширину — ряды по ширине места / масштаб переноса (после масштаба ровно в колонку).
        var rowLines: [(CTLine, NSRange)] = []
        if wrap && textWidth > visibleWidth + 1 {
            // Высота перенесённой строки — не больше двух рядов ×0,72: очень длинная строка в узкой колонке берёт
            // масштаб мельче (0,64 / 0,56 / 0,5), а не третий ряд, который вытолкнул бы соседей за край.
            let ts = CTTypesetterCreateWithAttributedString(full)
            func breakRows(_ k: CGFloat) -> [(CTLine, NSRange)] {
                var out: [(CTLine, NSRange)] = []
                var start = 0
                while start < full.length {
                    var count = CTTypesetterSuggestLineBreak(ts, start, Double(visibleWidth / k))
                    if count <= 0 { count = full.length - start }
                    out.append((CTTypesetterCreateLine(ts, CFRange(location: start, length: count)), NSRange(location: start, length: count)))
                    start += count
                }
                return out
            }
            let limit = 2 * AMSpec.islandWrapScale + 0.01
            var chosen: (CGFloat, [(CTLine, NSRange)]) = (AMSpec.islandWrapScale, breakRows(AMSpec.islandWrapScale))
            for k in AMSpec.islandWrapScales {
                let r = breakRows(k)
                chosen = (k, r)
                if CGFloat(r.count) * k <= limit { break }
            }
            fit = chosen.0
            rowLines = chosen.1
        } else {
            fit = 1
            rowLines = [(oneLine, NSRange(location: 0, length: full.length))]
        }
        rows = max(1, rowLines.count)
        let pad = max(4, ceil(font.pointSize * 0.3))
        maskSolid = textWidth + 2 * feather + 2 * pad
        let ns = full.string as NSString
        func rowOf(_ idx: Int) -> Int { rowLines.firstIndex { NSLocationInRange(idx, $0.1) } ?? max(0, rowLines.count - 1) }
        func x(_ idx: Int, _ row: Int) -> CGFloat { CTLineGetOffsetForStringIndex(rowLines[row].0, idx, nil) }

        var spans: [Int: (main: [FillFront.Span], bg: [FillFront.Span])] = [:]
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (si, seg) in segs.enumerated() {
            // Слог может разорваться переносом только целиком по слову — но на всякий случай режем по рядам.
            for (ri, rl) in rowLines.enumerated() {
                guard let r = NSIntersectionRange(ranges[si], rl.1).length > 0 ? NSIntersectionRange(ranges[si], rl.1) : nil else { continue }
                let x0 = x(r.location, ri), x1 = x(r.location + r.length, ri)
                let span = FillFront.Span(x0: x0, x1: x1, begin: seg.begin, end: seg.end)
                if seg.background { spans[ri, default: ([], [])].bg.append(span) } else { spans[ri, default: ([], [])].main.append(span) }
                // Слово целиком в этом ряду (центр роста и волна по глифам).
                let word = segs.indices.filter { segs[$0].wordIndex == seg.wordIndex && segs[$0].background == seg.background }
                let inRow = word.map { NSIntersectionRange(ranges[$0], rl.1) }.filter { $0.length > 0 }
                let wx0 = inRow.map { x($0.location, ri) }.min() ?? x0
                let wx1 = inRow.map { x($0.location + $0.length, ri) }.max() ?? x1
                var glyphsBefore = 0, glyphsTotal = 0
                for j in word {
                    var n = 0
                    ns.enumerateSubstrings(in: ranges[j], options: .byComposedCharacterSequences) { _, _, _, _ in n += 1 }
                    glyphsTotal += n
                    if j < si { glyphsBefore += n }
                }
                var parts: [NSRange] = []
                if seg.emphasis != nil {
                    ns.enumerateSubstrings(in: r, options: .byComposedCharacterSequences) { _, sub, _, _ in parts.append(sub) }
                    var skipped = 0   // глифы слога в прежних рядах
                    ns.enumerateSubstrings(in: NSRange(location: ranges[si].location, length: max(0, r.location - ranges[si].location)),
                                           options: .byComposedCharacterSequences) { _, _, _, _ in skipped += 1 }
                    glyphsBefore += skipped
                } else { parts = [r] }
                let top = CGFloat(ri) * boxHeight
                for (pi, p) in parts.enumerated() {
                    let px0 = x(p.location, ri), px1 = x(p.location + p.length, ri)
                    let size = CGSize(width: max(1, px1 - px0) + 2 * pad, height: boxHeight + 2 * pad)
                    let img = Self.image(full.attributedSubstring(from: p), size: size, pad: pad, ascent: ascent, scale: scale)
                    let n = Node(seg: seg, glyphIndex: glyphsBefore + pi, glyphCount: max(1, glyphsTotal),
                                 wordCenterX: (wx0 + wx1) / 2, baselineFromCenter: (pad + ascent) - size.height / 2,
                                 originX: px0 - pad, midX: (px0 + px1) / 2, row: ri)
                    n.container.actions = Self.noActions
                    n.container.frame = CGRect(x: px0 - pad, y: top - pad, width: size.width, height: size.height)
                    for l in [n.dim, n.lit] {
                        l.actions = Self.noActions
                        l.contents = img
                        l.contentsScale = scale
                        l.frame = CGRect(origin: .zero, size: size)
                        n.container.addSublayer(l)
                    }
                    n.mask.actions = Self.noActions
                    n.mask.startPoint = CGPoint(x: 0, y: 0.5); n.mask.endPoint = CGPoint(x: 1, y: 0.5)
                    n.mask.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
                    n.mask.locations = [0, NSNumber(value: Double(maskSolid / (maskSolid + feather))), 1]
                    n.mask.anchorPoint = .zero
                    n.mask.bounds = CGRect(x: 0, y: 0, width: maskSolid + feather, height: size.height)
                    n.lit.mask = n.mask
                    if seg.emphasis != nil {
                        n.lit.shadowColor = style.color.cgColor
                        n.lit.shadowRadius = AMSpec.glowRadius * k
                        n.lit.shadowOffset = .zero
                        n.lit.shadowOpacity = 0
                    }
                    scroller.addSublayer(n.container)
                    nodes.append(n)
                }
            }
        }
        for ri in 0..<rows {
            let m = spans[ri]?.main ?? [], b = spans[ri]?.bg ?? []
            let main = FillFront(spans: gradient ? m : [], minX: m.map(\.x0).min() ?? 0, maxX: m.map(\.x1).max() ?? 0, feather: feather)
            let bg = b.isEmpty || !gradient ? nil
                : FillFront(spans: b, minX: b.map(\.x0).min() ?? 0, maxX: b.map(\.x1).max() ?? 0, feather: feather)
            fronts[ri] = (main, bg)
        }
        root.bounds = CGRect(x: 0, y: 0, width: fit < 1 ? visibleWidth / fit : max(textWidth, visibleWidth), height: height)
        scroller.frame = root.bounds
        CATransaction.commit()
        applyColors(selected: false, duration: 0)
        setEdges(at: -.infinity)
    }

    func front(of n: Node) -> FillFront {
        let f = fronts[n.row] ?? (mainFront, nil)
        return n.seg.background ? (f.bg ?? f.main) : f.main
    }

    /// Положение маски узла при крае `edge` (координаты строки): растушёвка центрирована на крае.
    func maskX(_ n: Node, edge: CGFloat) -> CGFloat { edge - n.originX - feather / 2 - maskSolid }

    /// Сдвиг длинной строки влево, чтобы край заливки не уходил дальше 0,6 ширины места.
    func followOffset(edge: CGFloat) -> CGFloat {
        guard fit == 1, rows == 1, textWidth > visibleWidth + 1 else { return 0 }
        return min(textWidth - visibleWidth, max(0, edge - 0.6 * visibleWidth))
    }

    // MARK: Состояния

    private func applyColors(selected: Bool, duration: Double) {
        for n in nodes {
            let bg = n.seg.background
            let dimA = selected ? (bg ? style.bgDim : style.upcoming) : (bg ? style.bgDeselected : style.deselected)
            let litA = selected ? (bg ? style.bgLit : AMSpec.selectedAlpha) : 0
            Self.animate(n.dim, "opacity", to: Float(dimA), duration: duration)
            Self.animate(n.lit, "opacity", to: Float(litA), duration: duration)
        }
    }

    private func setEdges(at t: Double) {
        for n in nodes {
            n.mask.position = CGPoint(x: maskX(n, edge: front(of: n).edge(at: t)), y: 0)
        }
    }

    /// Статичный кадр в момент трека `t` (пауза, «Уменьшить движение», снимки): без анимаций.
    func setStatic(selected sel: Bool, at t: Double) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        removeLineAnimations()
        selected = sel
        applyColors(selected: sel, duration: 0)
        setEdges(at: sel ? t : -.infinity)
        for n in nodes {
            let s = sel && gradient ? state(n, at: t) : NodeMotion.State(scale: 1, lift: 0, glow: 0)
            n.container.transform = NodeMotion.transform(s, nodeMidX: n.midX, wordCenterX: n.wordCenterX,
                                                         baselineFromCenter: n.baselineFromCenter)
            if n.seg.emphasis != nil { n.lit.shadowOpacity = s.glow }
        }
        scroller.position = CGPoint(x: sel ? -followOffset(edge: mainFront.edge(at: t)) : 0, y: 0)
        CATransaction.commit()
    }

    private func state(_ n: Node, at t: Double) -> NodeMotion.State {
        guard lift > 0 else { return NodeMotion.State(scale: 1, lift: 0, glow: 0) }
        if let f = n.seg.emphasis {
            return NodeMotion.emphasized(f: f, wordBegin: n.seg.wordBegin, wordEnd: n.seg.wordEnd, glyph: n.glyphIndex,
                                         of: n.glyphCount, t: t, lift: lift)
        }
        return NodeMotion.syllable(begin: n.seg.begin, t: t, lift: lift)
    }

    private func removeLineAnimations() {
        for n in nodes {
            n.mask.removeAllAnimations(); n.container.removeAllAnimations()
            n.lit.removeAnimation(forKey: "glow")
        }
        scroller.removeAllAnimations()
    }

    /// Активна и играет: заливка, подъём, рост, свечение и сдвиг длинной строки — анимациями по часам трека.
    /// `ca(p)` — время Core Animation, когда трек будет на позиции `p`; `position` — позиция сейчас.
    func play(ca: (Double) -> CFTimeInterval, rate: Double, position: Double, fps: CAFrameRateRange, fadeIn: Bool) {
        let rate = max(0.25, rate)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        removeLineAnimations()
        let wasSelected = selected
        selected = true
        applyColors(selected: true, duration: fadeIn && !wasSelected ? AMSpec.lineFinish : 0)

        // Заливка: одна ключевая анимация на узел (время трека → край, значения сдвинуты на положение узла).
        var frames: [Int: [(Double, CGFloat)]] = [:]
        for n in nodes {
            let fr = front(of: n)
            guard gradient else { n.mask.position = CGPoint(x: maskX(n, edge: fr.fullEdge), y: 0); continue }
            let key = n.row * 2 + (n.seg.background ? 1 : 0)
            let pts = frames[key] ?? fr.keyframes()
            frames[key] = pts
            n.mask.position = CGPoint(x: maskX(n, edge: fr.fullEdge), y: 0)
            guard let first = pts.first, let last = pts.last, last.0 > position, last.0 > first.0 else { continue }
            let a = CAKeyframeAnimation(keyPath: "position.x")
            a.values = pts.map { maskX(n, edge: $0.1) }
            a.keyTimes = pts.map { NSNumber(value: ($0.0 - first.0) / (last.0 - first.0)) }
            a.beginTime = ca(first.0)
            a.duration = (last.0 - first.0) / rate
            a.fillMode = .backwards
            a.preferredFrameRateRange = fps
            n.mask.add(a, forKey: "fill")
        }

        // Подъём слога / рост и свечение выделенного слова.
        if lift > 0 && gradient {
            for n in nodes {
                if let f = n.seg.emphasis {
                    let t0 = n.seg.wordBegin
                    let span = NodeMotion.emphasisSpan(wordBegin: t0, wordEnd: n.seg.wordEnd, glyphs: n.glyphCount)
                    let final = NodeMotion.emphasized(f: f, wordBegin: t0, wordEnd: n.seg.wordEnd, glyph: n.glyphIndex,
                                                      of: n.glyphCount, t: t0 + span + 10, lift: lift)
                    n.container.transform = NodeMotion.transform(final, nodeMidX: n.midX, wordCenterX: n.wordCenterX,
                                                                 baselineFromCenter: n.baselineFromCenter)
                    n.lit.shadowOpacity = 0
                    guard t0 + span > position else { continue }
                    // Кривые SimpleLyrics (пружины с волной по глифам и спадом после слова) — по 30 точек в секунду.
                    let count = max(2, Int(ceil(span * 30)) + 1)
                    var tr: [NSValue] = [], glow: [Float] = [], times: [NSNumber] = []
                    for i in 0..<count {
                        let u = Double(i) / Double(count - 1)
                        let s = NodeMotion.emphasized(f: f, wordBegin: t0, wordEnd: n.seg.wordEnd, glyph: n.glyphIndex,
                                                      of: n.glyphCount, t: t0 + u * span, lift: lift)
                        tr.append(NSValue(caTransform3D: NodeMotion.transform(s, nodeMidX: n.midX, wordCenterX: n.wordCenterX,
                                                                              baselineFromCenter: n.baselineFromCenter)))
                        glow.append(s.glow)
                        times.append(NSNumber(value: u))
                    }
                    for (layer, key, path, values) in [(n.container, "lift", "transform", tr as [Any]),
                                                       (n.lit, "glow", "shadowOpacity", glow as [Any])] {
                        let a = CAKeyframeAnimation(keyPath: path)
                        a.values = values
                        a.keyTimes = times
                        a.beginTime = ca(t0)
                        a.duration = span / rate
                        a.fillMode = .backwards
                        a.preferredFrameRateRange = fps
                        layer.add(a, forKey: key)
                    }
                } else {
                    let final = CATransform3DMakeTranslation(0, -lift, 0)
                    n.container.transform = final
                    let sp = LyricSpring.response(AMSpec.liftResponse / rate)
                    guard n.seg.begin + sp.settlingDuration * rate > position else { continue }
                    let a = sp.animation(keyPath: "transform")
                    a.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
                    a.toValue = NSValue(caTransform3D: final)
                    a.beginTime = ca(n.seg.begin)
                    a.fillMode = .backwards
                    a.preferredFrameRateRange = fps
                    n.container.add(a, forKey: "lift")
                }
            }
        }

        // Длинная строка едет влево за краем заливки.
        let pts = mainFront.keyframes()
        if fit == 1, rows == 1, textWidth > visibleWidth + 1, let first = pts.first, let last = pts.last, last.0 > first.0, last.0 > position {
            scroller.position = CGPoint(x: -followOffset(edge: last.1), y: 0)
            let a = CAKeyframeAnimation(keyPath: "position.x")
            a.values = pts.map { -followOffset(edge: $0.1) }
            a.keyTimes = pts.map { NSNumber(value: ($0.0 - first.0) / (last.0 - first.0)) }
            a.beginTime = ca(first.0)
            a.duration = (last.0 - first.0) / rate
            a.fillMode = .backwards
            a.preferredFrameRateRange = fps
            scroller.add(a, forKey: "follow")
        } else {
            scroller.position = CGPoint(x: -followOffset(edge: mainFront.edge(at: position)), y: 0)
        }
        CATransaction.commit()
    }

    /// Строка перестала быть активной: спетое гаснет за 0,25 с, слоги опускаются пружиной 1/14/7, свечение гаснет,
    /// длинная строка возвращается к началу пружиной смены строки.
    func deactivate(animated: Bool, fps: CAFrameRateRange) {
        guard selected else { return }
        selected = false
        CATransaction.begin(); CATransaction.setDisableActions(true)
        applyColors(selected: false, duration: animated ? AMSpec.lineFinish : 0)
        for n in nodes {
            let from = n.container.presentation()?.transform ?? n.container.transform
            let glow = n.lit.presentation()?.shadowOpacity ?? n.lit.shadowOpacity
            n.container.removeAllAnimations(); n.lit.removeAnimation(forKey: "glow")
            n.container.transform = CATransform3DIdentity
            if n.seg.emphasis != nil { n.lit.shadowOpacity = 0 }
            guard animated else { continue }
            if !CATransform3DIsIdentity(from) {
                let a = AMSpec.dropSpring.animation(keyPath: "transform")
                a.fromValue = NSValue(caTransform3D: from)
                a.toValue = NSValue(caTransform3D: CATransform3DIdentity)
                a.preferredFrameRateRange = fps
                n.container.add(a.startingNow(on: n.container), forKey: "drop")
            }
            if glow > 0.001 { Self.animate(n.lit, "shadowOpacity", from: glow, to: 0, duration: AMSpec.lineFinish) }
        }
        let x = scroller.presentation()?.position.x ?? scroller.position.x
        scroller.removeAllAnimations()
        scroller.position = .zero
        if animated && abs(x) > 0.5 {
            let a = AMSpec.lineChangeSpring.animation(keyPath: "position.x")
            a.fromValue = x; a.toValue = 0
            a.preferredFrameRateRange = fps
            scroller.add(a.startingNow(on: scroller), forKey: "follow")
        }
        CATransaction.commit()
    }

    // MARK: Утилиты

    static func animate(_ layer: CALayer, _ key: String, from: Float? = nil, to value: Float, duration: Double) {
        let cur: Float
        if let from { cur = from } else if key == "opacity" { cur = layer.presentation()?.opacity ?? layer.opacity }
        else { cur = layer.presentation()?.shadowOpacity ?? layer.shadowOpacity }
        if key == "opacity" { layer.opacity = value } else { layer.shadowOpacity = value }
        layer.removeAnimation(forKey: key)
        guard duration > 0, abs(cur - value) > 0.001 else { return }
        let a = CABasicAnimation(keyPath: key)
        a.fromValue = cur
        a.toValue = value
        a.duration = duration
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(a.startingNow(on: layer), forKey: key)
    }

    /// Текст в картинку цветом темы; базовая линия — на `pad + ascent` от верха.
    static func image(_ attr: NSAttributedString, size: CGSize, pad: CGFloat, ascent: CGFloat, scale: CGFloat) -> CGImage? {
        let w = max(1, Int(ceil(size.width * scale))), h = max(1, Int(ceil(size.height * scale)))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.textMatrix = .identity
        ctx.setShouldSmoothFonts(false)
        ctx.textPosition = CGPoint(x: pad, y: size.height - pad - ascent)
        CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
        return ctx.makeImage()
    }
}
