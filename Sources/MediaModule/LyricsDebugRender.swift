import AppKit
import IslandCore
import QuartzCore

/// Отладка: `SimpleIsland --render-lyrics-frames <каталог> [тема]` — кадры настоящих анимаций строк (мок «Полуночный
/// трамвай») через `CARenderer` в PNG: прокрутка на смене строки (0–0,6 с) и заливка/рост выделенного слова «везёт».
/// Без окна и без прав; GUI не запускает.
public enum LyricsDebugRender {
    @MainActor
    public static func run(_ args: [String]) -> Int32 {
        guard let dir = args.first else { print("нужен каталог"); return 2 }
        let out = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let long = args.contains("long")
        let rest = args.dropFirst().filter { $0 != "long" }
        let name = rest.first ?? "obsidian"
        let theme: Theme? = SimpleIslandPaths.repoThemes.flatMap { try? Data(contentsOf: $0.appendingPathComponent("\(name).json")) }
            .flatMap { try? Theme.decode($0) } ?? Theme.obsidian
        let lyr = long ? longLyrics : MediaMocks.lyrics
        let size = CGSize(width: 480, height: 60)
        let cfg = LyricsStack.Config(themeID: theme?.id ?? "default", fontSize: 19, colorHex: theme?.text.primary ?? "#FFFFFF",
                                     light: theme?.isLight ?? false, size: size, scale: 2, compact: false)
        let font: (CGFloat) -> NSFont = { s in theme.map { AMSpec.font($0, size: s) } ?? .systemFont(ofSize: s, weight: .bold) }
        let s = LyricsStack()
        // Строка 2 (105 с) уже за 0,3 с до начала — потом смена строки «сейчас».
        let t0 = Date()
        let start = lyr.lines[2].time
        s.update(lyrics: lyr, position: start - 0.3, clock: KaraokeClock(timestamp: t0, elapsed: start - 0.3, rate: 1), animated: true,
                 config: cfg, font: font)
        let now = Date()
        s.update(lyrics: lyr, position: start, clock: KaraokeClock(timestamp: now, elapsed: start, rate: 1), animated: true,
                 config: cfg, font: font)
        let ca = s.root.convertTime(CACurrentMediaTime(), from: nil)
        if let sel = s.selected, let l = s.layers[sel] {
            let fills = l.nodes.filter { $0.mask.animation(forKey: "fill") != nil }.count
            let b = l.nodes.first?.mask.animation(forKey: "fill")?.beginTime ?? 0
            print("строка \(sel): узлов \(l.nodes.count), заливок \(fills), начало заливки через \(String(format: "%.2f", b - ca)) с")
        }
        let bg = NSColor.black.cgColor
        var frames: [(String, Double)] = []
        for dt in [0.0, 0.1, 0.2, 0.35, 0.6, 1.0] { frames.append((String(format: "scroll-%.2f", dt), dt)) }
        let fills = long ? [0.8, 1.6, 2.5, 3.5, 4.5, 5.5, 6.5, 7.6] : [2.6, 3.0, 3.4, 3.7, 4.0, 4.4, 5.2, 6.0, 7.6]
        for d in fills {
            frames.append((String(format: "fill-%.1f", start + d), d))
        }
        var ok = 0
        let imgs = LyricsFrameRenderer.render(s.root, size: CGSize(width: size.width + 2 * s.hPad, height: size.height + 2 * LyricsStack.bleed),
                                              scale: 2, background: bg, at: frames.map { ca + $0.1 })
        for ((name, _), img) in zip(frames, imgs) {
            guard let img, let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else { continue }
            let url = out.appendingPathComponent("\(name).png")
            if (try? png.write(to: url)) != nil { ok += 1; print(url.path) }
        }
        if long {
            // Компакт: одна строка 12 pt бегущей строкой за фронтом, края мягкие.
            let csize = CGSize(width: 220, height: 18)
            var ccfg = cfg; ccfg.size = csize; ccfg.compact = true; ccfg.fontSize = 12
            let c = LyricsStack()
            c.update(lyrics: Lyrics(lines: [lyr.lines[2]]), position: start, clock: KaraokeClock(timestamp: Date(), elapsed: start, rate: 1),
                     animated: true, config: ccfg, font: font)
            let cca = c.root.convertTime(CACurrentMediaTime(), from: nil)
            let cts = [0.5, 2.5, 4.5, 6.5, 7.6]
            let cimgs = LyricsFrameRenderer.render(c.root, size: CGSize(width: csize.width + 2 * c.hPad, height: csize.height),
                                                   scale: 2, background: bg, at: cts.map { cca + $0 })
            for (d, img) in zip(cts, cimgs) {
                guard let img, let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else { continue }
                let url = out.appendingPathComponent(String(format: "compact-%.1f.png", start + d))
                if (try? png.write(to: url)) != nil { print(url.path) }
            }
        }
        return ok == frames.count ? 0 : 1
    }

    /// Длинные строки (вымышленные): активная — длиннее трёх колонок острова; первое слово выделено (рост 1,14 у
    /// левого края). Слова поровну делят время строки.
    static let longLyrics: Lyrics = {
        let texts = [
            "мы стояли у окна",
            "и считали поезда до рассвета",
            "Ооо ты не знаешь почему всё вокруг опять стало другим и почему мы снова здесь (как так?)",
            "а город спит",
            "и нам не нужно спать до самого утра пока горят огни на набережной",
        ]
        var lines: [LyricLine] = []
        var t = 10.0
        for (i, text) in texts.enumerated() {
            let parts = text.split(separator: " ").map(String.init)
            let dur = i == 2 ? 8.0 : 4.0
            var words: [LyricWord] = []
            var wt = t
            for (k, w) in parts.enumerated() {
                let d = (i == 2 && k == 0) ? 1.6 : (dur - (i == 2 ? 1.6 : 0)) / Double(parts.count - (i == 2 ? 1 : 0))
                words.append(LyricWord(text: w, begin: wt, end: wt + d - 0.03))
                wt += d
            }
            lines.append(LyricLine(time: t, text: text, end: t + dur, words: words))
            t += dur + 0.5
        }
        return Lyrics(lines: lines)
    }()
}
