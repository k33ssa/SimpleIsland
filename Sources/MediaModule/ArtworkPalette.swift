import AppKit
import SwiftUI

/// Три доминирующих цвета обложки — для свечения под островом и темы «Хамелеон».
/// Порядок: [главный (фон/свечение), акцент (самый насыщенный), третий]. Считается в фоне по картинке 32×32.
enum ArtworkPalette {
    struct RGB: Equatable, Sendable {
        var r: Double, g: Double, b: Double
        var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }
        var color: Color { Color(nsColor) }
        var hsb: (h: Double, s: Double, v: Double) {
            let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
            var h = 0.0
            if d > 0 {
                if mx == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
                else if mx == g { h = (b - r) / d + 2 }
                else { h = (r - g) / d + 4 }
                h /= 6; if h < 0 { h += 1 }
            }
            return (h, mx == 0 ? 0 : d / mx, mx)
        }
        static func hsb(_ h: Double, _ s: Double, _ v: Double) -> RGB {
            let c = NSColor(hue: h, saturation: s, brightness: v, alpha: 1).usingColorSpace(.sRGB)!
            return RGB(r: c.redComponent, g: c.greenComponent, b: c.blueComponent)
        }
    }

    /// Сколько раз цвета считались на главном потоке (самотест: у живых обложек — 0, считаются в фоне).
    private static let counterLock = NSLock()
    nonisolated(unsafe) private static var mainCalls = 0
    static var mainThreadCalls: Int { counterLock.lock(); defer { counterLock.unlock() }; return mainCalls }

    /// Доминирующие цвета (обычно 3; для одноцветной картинки — оттенки одного). Вызывать с уменьшенной копии
    /// (миниатюра ImageDownsampler), не с оригинала; живые обложки — в фоне.
    static func dominantColors(of image: CGImage, count: Int = 3) -> [RGB] {
        if Thread.isMainThread { counterLock.lock(); mainCalls += 1; counterLock.unlock() }
        let side = 32
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              ctx.bytesPerRow == side * 4 else { return [] }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let raw = ctx.data else { return [] }
        let px = Array(UnsafeBufferPointer(start: raw.assumingMemoryBound(to: UInt8.self), count: side * side * 4))

        // Корзины: 12 оттенков × 3 насыщенности × 3 яркости + 3 серых.
        struct Bucket { var n = 0.0; var r = 0.0; var g = 0.0; var b = 0.0; var weight = 0.0 }
        var buckets: [Int: Bucket] = [:]
        for i in stride(from: 0, to: px.count, by: 4) {
            let a = Double(px[i + 3]) / 255
            guard a > 0.5 else { continue }
            let c = RGB(r: Double(px[i]) / 255 / a, g: Double(px[i + 1]) / 255 / a, b: Double(px[i + 2]) / 255 / a)
            let (h, s, v) = c.hsb
            let key: Int
            if s < 0.15 || v < 0.12 {
                key = 1000 + min(2, Int(v * 3))
            } else {
                key = min(11, Int(h * 12)) * 9 + min(2, Int(s * 3)) * 3 + min(2, Int(v * 3))
            }
            var bk = buckets[key] ?? Bucket()
            // Среднее по корзине — с упором на насыщенные пиксели, иначе переходы градиента дают «пастель».
            let pw = 0.2 + s * s * 2
            bk.n += pw; bk.r += c.r * pw; bk.g += c.g * pw; bk.b += c.b * pw
            // Свечению нужны живые цвета: насыщенные и не слишком тёмные весят больше серых.
            bk.weight += 0.25 + s * 1.2 + (v > 0.25 ? 0.3 : 0)
            buckets[key] = bk
        }
        let ranked = buckets.values.sorted { $0.weight > $1.weight }
            .map { RGB(r: $0.r / $0.n, g: $0.g / $0.n, b: $0.b / $0.n) }
        var picked: [RGB] = []
        for c in ranked where picked.count < count {
            if picked.allSatisfy({ distance($0, c) > 0.18 }) { picked.append(c) }
        }
        if picked.isEmpty, let first = ranked.first { picked = [first] }
        // Не хватило различимых — дополняем оттенками главного.
        while !picked.isEmpty && picked.count < count {
            let (h, s, v) = picked[0].hsb
            picked.append(.hsb(h, s, picked.count == 1 ? max(0.2, v * 0.6) : min(1, v * 1.3 + 0.1)))
        }
        return picked
    }

    /// Цвета для свечения: чуть ярче и насыщеннее, слишком тёмные поднимаем.
    static func glow(_ colors: [RGB]) -> [Color] {
        colors.map { c in
            let (h, s, v) = c.hsb
            return RGB.hsb(h, min(1, s * 1.15), max(0.45, min(1, v * 1.1))).color
        }
    }

    /// Самый насыщенный из цветов — акцент (проигранная часть волны в «Хамелеоне»).
    static func accent(_ colors: [RGB]) -> RGB? {
        colors.max { a, b in a.hsb.s * (0.4 + a.hsb.v) < b.hsb.s * (0.4 + b.hsb.v) }
    }

    static func distance(_ a: RGB, _ b: RGB) -> Double {
        let dr = a.r - b.r, dg = a.g - b.g, db = a.b - b.b
        return (dr * dr * 0.3 + dg * dg * 0.59 + db * db * 0.11).squareRoot() * 1.6
    }
}

extension NSImage {
    var cgImageForPalette: CGImage? {
        var rect = CGRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}

/// Псевдоволна трека: высоты полос детерминированы id трека (звук не анализируем, макет 01).
enum Waveform {
    static func bars(seed key: String, count: Int) -> [Double] {
        // FNV-1a от ключа → линейный конгруэнтный генератор, как в макете.
        var h: UInt64 = 1469598103934665603
        for b in key.utf8 { h ^= UInt64(b); h = h &* 1099511628211 }
        var s = Double(h % 233280)
        let phase = Double(h % 97) / 97 * .pi
        let period = 7 + Double(h % 5)
        return (0..<count).map { k in
            s = (s * 9301 + 49297).truncatingRemainder(dividingBy: 233280)
            let e = 0.45 + 0.55 * abs(sin(Double(k) / period + phase))
            return 0.2 + 0.8 * e * (0.5 + 0.5 * s / 233280)
        }
    }
}
