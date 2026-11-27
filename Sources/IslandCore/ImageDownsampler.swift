import AppKit
import CryptoKit
import ImageIO
import SwiftUI

/// Обложки и миниатюры — через ImageIO до нужного размера, с кэшем по стоимости (грабли M1/M4: у Atoll
/// `tiffRepresentation` иконки давал ~74 МБ на вызов и >1 ГБ; у Boring Notch кэш миниатюр без лимита — 284–336 МБ).
///
/// * Декодирование сразу в уменьшенный размер (`CGImageSourceCreateThumbnailAtIndex`,
///   `kCGImageSourceThumbnailMaxPixelSize`): полноразмерный битмап в память не попадает.
/// * Кэш `NSCache` с `totalCostLimit` (по умолчанию 24 МБ), стоимость = ширина × высота × 4.
/// * Ключ — свой (`key:`) или SHA-256 исходных байтов (одна обложка того же альбома не декодируется заново).
/// * Работа в фоне (`async`), результат — `NSImage` для `ArtworkView`.
/// * Средний цвет для свечения — с уже уменьшенной картинки (8×8), не с оригинала.
///
/// ```swift
/// let cover = await ImageDownsampler.shared.image(data: artworkData, maxPointSize: 64)   // ×2 под Retina
/// let glow = cover.flatMap { ImageDownsampler.dominantColors(of: $0) }
/// ```
/// Запрещено: `NSImage.tiffRepresentation`, `NSImage(data:)` для больших картинок, кэш без лимита.
public final class ImageDownsampler: @unchecked Sendable {
    public static let shared = ImageDownsampler()

    private let cache = NSCache<NSString, NSImage>()
    private let queue = DispatchQueue(label: "simpleisland.downsampler", qos: .utility, attributes: .concurrent)

    /// `costLimit` — байт декодированных пикселей в кэше.
    public init(costLimit: Int = 24 << 20, countLimit: Int = 200) {
        cache.totalCostLimit = costLimit
        cache.countLimit = countLimit
    }

    public var costLimit: Int { cache.totalCostLimit }
    public func removeAll() { cache.removeAllObjects() }

    // MARK: Синхронно (в фоне вызывающего)

    /// Уменьшить данные картинки так, чтобы бóльшая сторона была ≤ `maxPixelSize` пикселей.
    public static func downsample(data: Data, maxPixelSize: Int) -> CGImage? {
        let srcOpts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(data as CFData, srcOpts) else { return nil }
        return thumbnail(src, maxPixelSize)
    }

    public static func downsample(url: URL, maxPixelSize: Int) -> CGImage? {
        let srcOpts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url as CFURL, srcOpts) else { return nil }
        return thumbnail(src, maxPixelSize)
    }

    private static func thumbnail(_ src: CGImageSource, _ maxPixelSize: Int) -> CGImage? {
        let opts = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts)
    }

    // MARK: С кэшем

    /// Картинка из данных под размер показа `maxPointSize` (pt) × `scale` (по умолчанию 2 — Retina).
    /// Декодирование — в фоне (utility), `NSImage` и кэш — на главном потоке (вызывать из `@MainActor`-кода модуля).
    @MainActor
    public func image(data: Data, maxPointSize: CGFloat, scale: CGFloat = 2, key: String? = nil) async -> NSImage? {
        let px = Int((maxPointSize * scale).rounded(.up))
        // SHA-256 по всем байтам обложки — в фоне, не на главном потоке.
        let id: String
        if let key { id = key } else {
            id = await withCheckedContinuation { cont in queue.async { cont.resume(returning: Self.digest(data)) } }
        }
        let k = "\(id)@\(px)"
        if let hit = cache.object(forKey: k as NSString) { return hit }
        let cg: CGImage? = await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: Self.downsample(data: data, maxPixelSize: px)) }
        }
        return cg.map { store($0, key: k as NSString, scale: scale) }
    }

    @MainActor
    public func image(url: URL, maxPointSize: CGFloat, scale: CGFloat = 2) async -> NSImage? {
        let px = Int((maxPointSize * scale).rounded(.up))
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?
            .timeIntervalSince1970 ?? 0
        let k = "\(url.path)#\(mtime)@\(px)"
        if let hit = cache.object(forKey: k as NSString) { return hit }
        let cg: CGImage? = await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: Self.downsample(url: url, maxPixelSize: px)) }
        }
        return cg.map { store($0, key: k as NSString, scale: scale) }
    }

    /// Синхронно из кэша (для `body`): nil — нет в кэше.
    public func cached(key: String, maxPointSize: CGFloat, scale: CGFloat = 2) -> NSImage? {
        cache.object(forKey: "\(key)@\(Int((maxPointSize * scale).rounded(.up)))" as NSString)
    }

    private func store(_ cg: CGImage, key: NSString, scale: CGFloat) -> NSImage {
        let img = NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / scale, height: CGFloat(cg.height) / scale))
        cache.setObject(img, forKey: key, cost: cg.width * cg.height * 4)
        return img
    }

    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Цвета для свечения

    /// 2–3 преобладающих цвета (усреднение по сетке 8×8 уменьшенной копии). Для `setGlow`.
    public static func dominantColors(of image: NSImage, count: Int = 3) -> [Color]? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return dominantColors(of: cg, count: count)
    }

    public static func dominantColors(of cg: CGImage, count: Int = 3) -> [Color]? {
        let side = 8
        var px = [UInt8](repeating: 0, count: side * side * 4)
        guard let ctx = CGContext(data: &px, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        // Полосы слева направо → `count` средних цветов (свечение — градиент слева направо).
        let n = max(1, min(count, side))
        var result: [Color] = []
        for band in 0..<n {
            let x0 = band * side / n, x1 = (band + 1) * side / n
            var r = 0, g = 0, b = 0, c = 0
            for y in 0..<side { for x in x0..<x1 {
                let i = (y * side + x) * 4
                r += Int(px[i]); g += Int(px[i + 1]); b += Int(px[i + 2]); c += 1
            } }
            guard c > 0 else { continue }
            result.append(Color(red: Double(r) / Double(c) / 255, green: Double(g) / Double(c) / 255,
                                blue: Double(b) / Double(c) / 255))
        }
        return result.isEmpty ? nil : result
    }
}
