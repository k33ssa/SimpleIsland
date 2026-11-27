import AppKit
import IslandCore
import Metal
import QuartzCore
import SwiftUI

/// Несколько строк текста «как в Apple Music», приспособленные к острову: активная строка по центру и крупно,
/// соседние — мельче (13/19), прозрачнее (0,175) и размыты (min(расстояние, 4) при 34 pt → доля кегля), смена строки —
/// прокрутка пружиной mass 1 / stiffness 100 / damping 18 с каскадом 0,05 с на строку ниже активной (перенос
/// `LyricsViewController.scroll/updateBlur` из SimpleLyrics). Строки ±2 от активной построены заранее и прячутся за
/// краем: при смене строки они въезжают. Компакт — одна строка без соседей.
@MainActor
final class LyricsStack {
    struct Config: Equatable {
        var themeID: String
        var fontSize: CGFloat
        var colorHex: String
        var light: Bool
        var size: CGSize
        var scale: CGFloat
        /// Компакт: одна строка, без подъёма/роста/свечения, без соседей.
        var compact: Bool
    }

    /// Слой с обрезкой (горизонтально — по ширине места, вертикально — с мягким краем на `bleed`).
    let root = CALayer()
    private let content = CALayer()
    private let fade = CAGradientLayer()
    private(set) var config: Config?
    private var font: ((CGFloat) -> NSFont)?
    private(set) var lyrics: Lyrics?
    /// Индексы непустых строк источника (пустые строки LRC — проигрыш: строки не занимают).
    private(set) var display: [Int] = []
    private(set) var layers: [Int: LyricLineLayer] = [:]
    private(set) var focus: Int?
    private(set) var selected: Int?
    private var clock: KaraokeClock?
    private var animated = true
    private var position: Double = 0
    static let bleed: CGFloat = 6

    init() {
        root.actions = LyricLineLayer.noActions
        content.actions = LyricLineLayer.noActions
        root.masksToBounds = true
        root.addSublayer(content)
        fade.actions = LyricLineLayer.noActions
        root.mask = fade
    }

    var fps: CAFrameRateRange {
        config?.compact == true ? CAFrameRateRange(minimum: 10, maximum: 20, preferred: 20)
                                : CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
    }
    /// Прокрутка строк — короткая, её лучше видно плавной.
    var scrollFPS: CAFrameRateRange { CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60) }

    // MARK: Геометрия слотов

    private var boxHeight: CGFloat { layers.values.first?.boxHeight ?? ceil((config?.fontSize ?? 19) * 1.25) }
    /// Поле слева/справа за краем колонки: рост слова до 1,14 у левого края и свечение не обрезаются.
    var hPad: CGFloat { config.map(LyricsFrameRenderer.hPad) ?? 10 }

    /// Видимая высота строки `k` (ряды × масштаб переноса × масштаб соседа).
    func visualHeight(_ k: Int, selected sel: Bool) -> CGFloat {
        let l = layers[k]
        return (l?.height ?? boxHeight) * (l?.fit ?? 1) * scale(selected: sel)
    }

    /// Центр строки `k` при активной `f` и выбранной `s` (y вниз, в координатах `content`): строки стоят стопкой от
    /// активной по центру, с зазором; ±2 и дальше — целиком за мягким краем (иначе выглядывают хвосты букв).
    func slotY(_ k: Int, focus f: Int, selected s: Int?) -> CGFloat {
        guard let c = config else { return 0 }
        let mid = c.size.height / 2
        if k == f || c.compact { return mid }
        let dir = k > f ? 1 : -1
        var y = mid
        var j = f
        while j != k {
            let next = j + dir
            y += CGFloat(dir) * (visualHeight(j, selected: j == s) / 2 + AMSpec.islandLineGap + visualHeight(next, selected: next == s) / 2)
            j = next
        }
        if abs(k - f) > 1 { y += CGFloat(dir) * (Self.bleed + visualHeight(k, selected: false) / 2) }
        return y
    }

    func scale(selected sel: Bool) -> CGFloat { sel || config?.compact == true ? 1 : AMSpec.islandNeighborScale }

    /// Радиус размытия строки на расстоянии `d` от активной: Apple — min(d, 4) pt при 34 pt, здесь — доля кегля.
    func blur(distance d: Int, selected sel: Bool) -> CGFloat {
        guard let c = config, !c.compact, !sel, d > 0 else { return 0 }
        return min(CGFloat(d), AMSpec.maxBlurRadius) * c.fontSize / AMSpec.baseFontSize
    }

    // MARK: Обновление

    /// Строки, позиция, часы (nil — пауза/«Уменьшить движение»/снимок: статичный кадр по позиции).
    func update(lyrics l: Lyrics, position pos: Double, clock c: KaraokeClock?, animated anim: Bool, config cfg: Config,
                font: @escaping (CGFloat) -> NSFont) {
        self.font = font
        animated = anim
        position = pos
        func sizeless(_ c: Config?) -> Config? { c.map { var o = $0; o.size = .zero; return o } }
        // Ширина — перестройка: длинные строки переносятся под неё.
        let rebuild = l != lyrics || sizeless(cfg) != sizeless(config) || cfg.size.width != config?.size.width
        let resized = cfg.size != config?.size
        config = cfg
        lyrics = l
        let clockChanged = !Self.same(c, clock)
        clock = c
        let (f, s) = Self.focus(l, display: &display, at: pos)
        if rebuild {
            layers.values.forEach { $0.root.removeFromSuperlayer() }
            layers = [:]
            focus = nil; selected = nil
        }
        if rebuild || resized { layoutFrame() }
        if rebuild || f != focus || s != selected {
            move(focus: f, selected: s, animated: anim && !rebuild)
        } else if clockChanged || c == nil || resized {
            restartSelected()
        }
    }

    /// Активная строка (индекс в `display`) и выбранная (спетая сейчас; nil — проигрыш/до начала).
    static func focus(_ l: Lyrics, display: inout [Int], at position: Double) -> (Int?, Int?) {
        display = l.lines.indices.filter { !l.lines[$0].text.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !display.isEmpty else { return (nil, nil) }
        guard let i = l.index(at: position) else { return (0, nil) }
        let f = display.lastIndex { $0 <= i } ?? 0
        return (f, display[f] == i ? f : nil)
    }

    private func layoutFrame() {
        guard let c = config else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let b = c.compact ? 0 : Self.bleed, p = hPad
        root.frame = CGRect(x: -p, y: -b, width: c.size.width + 2 * p, height: c.size.height + 2 * b)
        content.frame = CGRect(x: p, y: b, width: c.size.width, height: c.size.height)
        fade.frame = root.bounds
        if c.compact {
            // Компакт: бегущая строка — мягкие края слева и справа (в поле, текст в покое не тускнеет).
            fade.startPoint = CGPoint(x: 0, y: 0.5); fade.endPoint = CGPoint(x: 1, y: 0.5)
            let e = Double(p / max(1, root.bounds.width))
            fade.locations = [0, NSNumber(value: e), NSNumber(value: 1 - e), 1]
        } else {
            fade.startPoint = CGPoint(x: 0.5, y: 0); fade.endPoint = CGPoint(x: 0.5, y: 1)
            let e = Double(min(0.3, (b + 2) / max(1, root.bounds.height)))
            fade.locations = [0, NSNumber(value: e), NSNumber(value: 1 - e), 1]
        }
        fade.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        for (k, l) in layers {
            l.visibleWidth = c.size.width
            if let f = focus { place(l, y: slotY(k, focus: f, selected: selected), distance: abs(k - f), selected: k == selected) }
        }
        CATransaction.commit()
    }

    private func line(_ k: Int) -> LyricLineLayer? {
        if let l = layers[k] { return l }
        guard let c = config, let font, let lyr = lyrics, display.indices.contains(k) else { return nil }
        let src = lyr.lines[display[k]]
        let color = NSColor(hex: c.colorHex) ?? .white
        let l = LyricLineLayer(line: src, font: font(c.fontSize), bgFont: font(c.fontSize * AMSpec.bgFontRatio),
                               style: .make(color: color, light: c.light), scale: c.scale, visibleWidth: c.size.width,
                               effects: !c.compact, wrap: !c.compact)
        if !c.compact { LayerBlur.install(on: l.root) }
        content.addSublayer(l.root)
        layers[k] = l
        return l
    }

    /// Строка — по левому краю (anchor x = 0): масштаб соседа и переноса не сдвигает её начало.
    private func place(_ l: LyricLineLayer, y: CGFloat, distance d: Int, selected sel: Bool) {
        l.root.position = CGPoint(x: 0, y: y)
        let s = scale(selected: sel) * l.fit
        l.root.transform = CATransform3DMakeScale(s, s, 1)
        LayerBlur.set(blur(distance: d, selected: sel), on: l.root, duration: 0)
    }

    /// Смена активной строки: соседи въезжают пружиной с каскадом, старая гаснет, новая начинает заливку.
    private func move(focus f: Int?, selected s: Int?, animated anim: Bool) {
        guard let f else {
            layers.values.forEach { $0.root.removeFromSuperlayer() }
            layers = [:]; focus = nil; selected = nil
            return
        }
        let old = focus
        let jump = old == nil || abs(f - (old ?? f)) > 2 || !anim
        let window = config?.compact == true ? f...f : max(0, f - 2)...min(display.count - 1, f + 2)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // Новые строки — сперва там, где они были бы при старой активной (за краем), потом едут.
        var fresh: [Int] = []
        for k in window where layers[k] == nil {
            if line(k) != nil { fresh.append(k) }
        }
        // Высоты известны, когда строки построены: новые ставим туда, где они были бы при старой активной.
        for k in fresh {
            let ref = jump ? f : old!
            place(layers[k]!, y: slotY(k, focus: ref, selected: jump ? s : selected), distance: abs(k - ref),
                  selected: jump ? k == s : false)
        }
        // Лишние — прочь (они уже за краем).
        for k in layers.keys where !window.contains(k) && (jump || abs(k - f) > 3) {
            layers[k]?.root.removeFromSuperlayer(); layers[k] = nil
        }
        let now = root.convertTime(CACurrentMediaTime(), from: nil)
        for (k, l) in layers {
            let sel = k == s
            let targetY = slotY(k, focus: f, selected: s)
            let ts = scale(selected: sel) * l.fit
            if jump {
                place(l, y: targetY, distance: abs(k - f), selected: sel)
                continue
            }
            let fromY = l.root.presentation()?.position.y ?? l.root.position.y
            let fromS = (l.root.presentation()?.value(forKeyPath: "transform.scale.x") as? CGFloat) ?? (l.root.value(forKeyPath: "transform.scale.x") as? CGFloat) ?? ts
            l.root.position = CGPoint(x: 0, y: targetY)
            l.root.transform = CATransform3DMakeScale(ts, ts, 1)
            l.root.removeAnimation(forKey: "y"); l.root.removeAnimation(forKey: "scale")
            if abs(fromY - targetY) > 0.3 {
                // Каскад Apple: 0,05 с × номер строки ниже активной (не больше 1 с).
                let a = AMSpec.lineChangeSpring.animation(keyPath: "position.y")
                a.fromValue = fromY; a.toValue = targetY
                a.beginTime = now + min(Double(max(0, k - f)) * AMSpec.lineDelay, 1)
                a.fillMode = .backwards
                a.preferredFrameRateRange = scrollFPS
                l.root.add(a, forKey: "y")
            }
            if abs(fromS - ts) > 0.001 {
                let a = AMSpec.lineChangeSpring.animation(keyPath: "transform")
                a.fromValue = NSValue(caTransform3D: CATransform3DMakeScale(fromS, fromS, 1))
                a.toValue = NSValue(caTransform3D: CATransform3DMakeScale(ts, ts, 1))
                a.preferredFrameRateRange = scrollFPS
                l.root.add(a.startingNow(on: l.root), forKey: "scale")
            }
            LayerBlur.set(blur(distance: abs(k - f), selected: sel), on: l.root, duration: AMSpec.blurDuration)
        }
        // Старая выбранная гаснет, новая — заливка.
        if let os = selected, os != s, let l = layers[os] { l.deactivate(animated: anim && !jump, fps: fps) }
        focus = f
        selected = s
        CATransaction.commit()
        restartSelected(fadeIn: anim && !jump)
    }

    /// Перезапустить заливку выбранной строки по текущим часам (перемотка, скорость, пауза → игра) или статично.
    private func restartSelected(fadeIn: Bool = false) {
        guard let s = selected, let l = layers[s] else { return }
        let now = Date()
        guard let clock else {
            l.setStatic(selected: true, at: position)
            return
        }
        let pos = clock.elapsed + now.timeIntervalSince(clock.timestamp) * clock.rate
        let caNow = root.convertTime(CACurrentMediaTime(), from: nil)
        l.play(ca: { caNow + clock.date(atPosition: $0).timeIntervalSince(now) }, rate: clock.rate, position: pos,
               fps: fps, fadeIn: fadeIn)
    }

    static func same(_ a: KaraokeClock?, _ b: KaraokeClock?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        let now = Date()
        let pa = a.elapsed + now.timeIntervalSince(a.timestamp) * a.rate
        let pb = b.elapsed + now.timeIntervalSince(b.timestamp) * b.rate
        return a.rate == b.rate && abs(pa - pb) < 0.005
    }

    /// Статичный кадр в позиции (снимок, отладочный рендер): всё без анимаций.
    func setStatic(position: Double) {
        guard let s = selected, let l = layers[s] else { return }
        l.setStatic(selected: true, at: position)
    }
}

// MARK: - NSView

final class LyricsStackView: NSView {
    let stack = LyricsStack()
    private var pending: (Lyrics, Double, KaraokeClock?, Bool, LyricsStack.Config, (CGFloat) -> NSFont)?
    private var resizeWork: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.addSublayer(stack.root)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(lyrics: Lyrics, position: Double, clock: KaraokeClock?, animated: Bool, config: LyricsStack.Config,
                font: @escaping (CGFloat) -> NSFont) {
        var cfg = config
        cfg.scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        last = (lyrics, position, clock, animated, cfg, font)
        if let old = stack.config, old.size != cfg.size, stack.lyrics == lyrics {
            // Морф острова: размер меняется каждый кадр — переложить один раз, когда успокоится.
            pending = (lyrics, position, clock, animated, cfg, font)
            resizeWork?.cancel()
            let w = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let p = self.pending else { return }
                    self.pending = nil
                    self.stack.update(lyrics: p.0, position: p.1, clock: p.2, animated: false, config: p.4, font: p.5)
                }
            }
            resizeWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
            return
        }
        stack.update(lyrics: lyrics, position: position, clock: clock, animated: animated, config: cfg, font: font)
    }

    private var last: (Lyrics, Double, KaraokeClock?, Bool, LyricsStack.Config, (CGFloat) -> NSFont)?

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // Другая плотность экрана — перестроить картинки слогов.
        guard let p = last, let s = window?.backingScaleFactor, s != stack.config?.scale else { return }
        update(lyrics: p.0, position: p.1, clock: p.2, animated: false, config: p.4, font: p.5)
    }
}

// MARK: - SwiftUI

/// Строки текста (раскрытый «Медиа» — 3 строки с прокруткой; компакт — одна). В снимке (`ImageRenderer` не рисует
/// NSView) — кадр тех же слоёв через `CARenderer`.
struct LyricsStackRep: View {
    var lyrics: Lyrics
    var position: Double
    var clock: KaraokeClock?
    var fontSize: CGFloat = 19
    var compact = false
    /// Цвет текста: основной темы или (компакт) вторичный.
    var secondaryColor = false
    @Environment(\.islandTheme) private var theme
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.islandMotion) private var motion

    var body: some View {
        GeometryReader { g in
            let cfg = LyricsStack.Config(themeID: theme.id, fontSize: fontSize,
                                         colorHex: secondaryColor ? theme.text.secondary : theme.text.primary,
                                         light: theme.isLight, size: g.size, scale: 2, compact: compact)
            if isSnapshot {
                if let img = LyricsFrameRenderer.stackImage(lyrics: lyrics, position: position, config: cfg,
                                                           font: { AMSpec.font(theme, size: $0) }) {
                    Image(decorative: img, scale: 2)
                        .frame(width: g.size.width + 2 * LyricsFrameRenderer.hPad(cfg), height: g.size.height + 2 * LyricsFrameRenderer.bleed(cfg))
                        .offset(x: -LyricsFrameRenderer.hPad(cfg), y: -LyricsFrameRenderer.bleed(cfg))
                }
            } else {
                Inner(lyrics: lyrics, position: position, clock: clock, animated: motion.allowsContinuousAnimation,
                      config: cfg, theme: theme)
                    .frame(width: g.size.width, height: g.size.height)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(currentText)
    }

    private var currentText: String {
        lyrics.index(at: position).map { lyrics.lines[$0].text } ?? ""
    }

    private struct Inner: NSViewRepresentable {
        var lyrics: Lyrics
        var position: Double
        var clock: KaraokeClock?
        var animated: Bool
        var config: LyricsStack.Config
        var theme: Theme
        func makeNSView(context: Context) -> LyricsStackView { LyricsStackView() }
        func updateNSView(_ v: LyricsStackView, context: Context) {
            let t = theme
            v.update(lyrics: lyrics, position: position, clock: clock, animated: animated, config: config,
                     font: { AMSpec.font(t, size: $0) })
        }
    }
}

// MARK: - Кадр слоёв в картинку

/// Кадр дерева слоёв в момент Core Animation `t` — через `CARenderer` на Metal: с масками, фильтрами (размытие) и
/// анимациями (`layer.render(in:)` их не рисует). Для снимков и отладочного `--render-lyrics-frames`.
@MainActor
enum LyricsFrameRenderer {
    static func bleed(_ c: LyricsStack.Config) -> CGFloat { c.compact ? 0 : LyricsStack.bleed }
    static func hPad(_ c: LyricsStack.Config) -> CGFloat { c.compact ? 5 : 10 }

    /// Статичный кадр строк в позиции (снимок).
    static func stackImage(lyrics: Lyrics, position: Double, config: LyricsStack.Config,
                           font: @escaping (CGFloat) -> NSFont) -> CGImage? {
        guard config.size.width > 1, config.size.height > 1 else { return nil }
        let s = LyricsStack()
        s.update(lyrics: lyrics, position: position, clock: nil, animated: false, config: config, font: font)
        s.setStatic(position: position)
        let b = bleed(config)
        return render(s.root, size: CGSize(width: config.size.width + 2 * hPad(config), height: config.size.height + 2 * b),
                      offset: .zero, scale: config.scale, background: nil,
                      at: CACurrentMediaTime())
    }

    private static let device = MTLCreateSystemDefaultDevice()
    private static let queue = device?.makeCommandQueue()

    static func render(_ layer: CALayer, size: CGSize, offset: CGPoint = .zero, scale: CGFloat, background: CGColor?,
                       at t: CFTimeInterval) -> CGImage? {
        render(layer, size: size, offset: offset, scale: scale, background: background, at: [t]).first ?? nil
    }

    /// `layer` кладётся в свой корень (y вниз) со сдвигом `offset`; кадры — на моменты CA `times`, одним рендерером:
    /// анимации слоёв вне окна живут только до закрытия транзакции, поэтому все кадры — за одно подключение.
    static func render(_ layer: CALayer, size: CGSize, offset: CGPoint = .zero, scale: CGFloat, background: CGColor?,
                       at times: [CFTimeInterval]) -> [CGImage?] {
        guard let device, let queue else { return times.map { _ in nil } }
        let w = max(1, Int(ceil(size.width * scale))), h = max(1, Int(ceil(size.height * scale)))
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead, .shaderWrite]
        d.storageMode = .managed
        guard let tex = device.makeTexture(descriptor: d) else { return times.map { _ in nil } }
        // Анимации — собрать до закрытия неявной транзакции (у слоёв вне окна после неё они пропадают, 16.11).
        var saved: [(CALayer, String, CAAnimation)] = []
        func collect(_ l: CALayer) {
            for k in l.animationKeys() ?? [] {
                if let an = l.animation(forKey: k)?.copy() as? CAAnimation { saved.append((l, k, an)) }
            }
            l.sublayers?.forEach(collect)
            if let m = l.mask { collect(m) }
        }
        collect(layer)
        let oldSuper = layer.superlayer
        let oldFrame = layer.frame
        // Без цикла событий неявная транзакция не закрывается сама: наша вложилась бы в неё и рендерер увидел бы
        // пустое дерево (16.11) — закрыть её до и после.
        CATransaction.flush()
        // Слой рендереру и анимации — в одной транзакции с деревом (иначе кадр пустой / без анимаций: опыт 16.11).
        let r = CARenderer(mtlTexture: tex, options: [kCARendererMetalCommandQueue: queue])
        let host = CALayer(), holder = CALayer()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        host.isGeometryFlipped = true
        host.frame = CGRect(x: 0, y: 0, width: w, height: h)
        host.backgroundColor = background
        holder.anchorPoint = .zero
        holder.frame = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        holder.transform = CATransform3DMakeScale(scale, scale, 1)
        host.addSublayer(holder)
        layer.removeFromSuperlayer()
        holder.addSublayer(layer)
        layer.frame = CGRect(origin: offset, size: oldFrame.size)
        for (l, k, an) in saved { l.add(an, forKey: k) }
        r.layer = host
        r.bounds = host.frame
        CATransaction.commit()
        CATransaction.flush()
        var out: [CGImage?] = []
        for t in times {
            for _ in 0..<2 {
                r.beginFrame(atTime: t, timeStamp: nil)
                r.addUpdate(r.bounds)
                r.render()
                r.endFrame()
            }
            out.append(readback(tex, w: w, h: h, queue: queue))
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.removeFromSuperlayer()
        layer.frame = oldFrame
        oldSuper?.addSublayer(layer)
        for (l, k, an) in saved { l.add(an, forKey: k) }
        CATransaction.commit()
        return out
    }

    private static func readback(_ tex: MTLTexture, w: Int, h: Int, queue: MTLCommandQueue) -> CGImage? {
        guard let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { return nil }
        blit.synchronize(resource: tex)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        tex.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        // Текстура рендерера — снизу вверх: строки картинки перевернуть.
        var flipped = [UInt8](repeating: 0, count: bytes.count)
        for y in 0..<h { flipped.replaceSubrange((y * w * 4)..<((y + 1) * w * 4), with: bytes[((h - 1 - y) * w * 4)..<((h - y) * w * 4)]) }
        guard let provider = CGDataProvider(data: Data(flipped) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
