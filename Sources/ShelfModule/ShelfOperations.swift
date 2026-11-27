import AppKit
import CoreImage
import Foundation
import ImageIO
import IslandCore
import PDFKit
import UniformTypeIdentifiers
import Vision

/// Ошибка операции полки — текст сразу по-русски, для уведомления острова.
struct ShelfError: LocalizedError, Sendable {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Формат конвертера.
public enum ShelfConvertFormat: String, Codable, CaseIterable, Sendable {
    /// PNG → JPEG, остальное → PNG.
    case auto, png, jpeg, heic

    var title: String {
        switch self {
        case .auto: return "Авто (PNG ↔ JPEG)"
        case .png: return "PNG"
        case .jpeg: return "JPEG"
        case .heic: return "HEIC"
        }
    }

    func resolved(for src: URL) -> ShelfConvertFormat {
        guard self == .auto else { return self }
        let t = UTType(filenameExtension: src.pathExtension.lowercased())
        return t?.conforms(to: .png) == true ? .jpeg : .png
    }

    var utType: UTType {
        switch self {
        case .auto, .png: return .png
        case .jpeg: return .jpeg
        case .heic: return .heic
        }
    }

    var ext: String {
        switch self {
        case .auto, .png: return "png"
        case .jpeg: return "jpg"
        case .heic: return "heic"
        }
    }
}

/// Тяжёлые операции. Всё `nonisolated` и без общего состояния: зовутся из `DispatchQueue.global(qos: .utility)`.
/// `progress` — 0…1 (можно звать с любого потока).
enum ShelfOperations {
    typealias Progress = @Sendable (Double) -> Void

    // MARK: ZIP

    /// `ditto -c -k --sequesterRsrc --keepParent`. Несколько файлов — через временную папку «Архив».
    static func zip(_ urls: [URL], outDir: URL) throws -> URL {
        guard !urls.isEmpty else { throw ShelfError("Нечего сжимать") }
        let fm = FileManager.default
        var src = urls[0]
        var tmp: URL?
        let name: String
        if urls.count == 1 {
            name = src.lastPathComponent              // как Finder: «отчёт.pdf.zip»
        } else {
            let t = try ShelfFiles.makeTempDir().appendingPathComponent("Архив", isDirectory: true)
            try fm.createDirectory(at: t, withIntermediateDirectories: true)
            for u in urls { try fm.copyItem(at: u, to: ShelfFiles.uniqueURL(in: t, name: u.lastPathComponent)) }
            src = t; tmp = t.deletingLastPathComponent()
            name = "Архив"
        }
        defer { if let tmp { try? fm.removeItem(at: tmp) } }
        let dst = ShelfFiles.uniqueURL(in: outDir, name: name + ".zip")
        // Большие папки сжимаются минутами — срок длинный, но не вечный (зависший ditto не живёт до выхода).
        let r = try run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", src.path, dst.path], timeout: 1800)
        guard r.status == 0, fm.fileExists(atPath: dst.path) else {
            throw ShelfError("ZIP не собрался: \(r.stderr.isEmpty ? "ditto \(r.status)" : r.stderr)")
        }
        return dst
    }

    // MARK: Конвертер

    static func isPDF(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension.lowercased())?.conforms(to: .pdf) == true
    }

    static func isImage(_ url: URL) -> Bool {
        guard let t = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return t.conforms(to: .image) && !t.conforms(to: .pdf)
    }

    /// Картинка → PNG/JPEG/HEIC (ImageIO), PDF → PNG постранично (PDFKit, 2×).
    static func convert(_ urls: [URL], format: ShelfConvertFormat, outDir: URL, progress: Progress) throws -> [URL] {
        var out: [URL] = []
        for (i, u) in urls.enumerated() {
            let base = Double(i) / Double(urls.count), span = 1 / Double(urls.count)
            if isPDF(u) {
                out += try pdfToPNG(u, outDir: outDir) { progress(base + span * $0) }
            } else if isImage(u) {
                out.append(try convertImage(u, to: format.resolved(for: u), outDir: outDir))
            } else {
                throw ShelfError("«\(u.lastPathComponent)» — не картинка и не PDF")
            }
            progress(base + span)
        }
        return out
    }

    static func convertImage(_ src: URL, to format: ShelfConvertFormat, outDir: URL) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(src as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ShelfError("Не открыть картинку «\(src.lastPathComponent)»")
        }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let name = (src.lastPathComponent as NSString).deletingPathExtension + "." + format.ext
        let dst = ShelfFiles.uniqueURL(in: outDir, name: name)
        var opts: [CFString: Any] = [:]
        if let o = props?[kCGImagePropertyOrientation] { opts[kCGImagePropertyOrientation] = o }
        var img = image
        if format == .jpeg, image.alphaInfo != .none, image.alphaInfo != .noneSkipFirst, image.alphaInfo != .noneSkipLast {
            img = flattened(image) ?? image          // у JPEG нет прозрачности — подложить белый
        }
        if format != .png { opts[kCGImageDestinationLossyCompressionQuality] = 0.9 }
        try writeImage(img, to: dst, type: format.utType, options: opts)
        return dst
    }

    static func pdfToPNG(_ src: URL, outDir: URL, scale: CGFloat = 2, progress: Progress) throws -> [URL] {
        guard let doc = PDFDocument(url: src), doc.pageCount > 0 else {
            throw ShelfError("Не открыть PDF «\(src.lastPathComponent)»")
        }
        let base = (src.lastPathComponent as NSString).deletingPathExtension
        var out: [URL] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            guard let cg = render(page, scale: scale, opaque: true) else {
                throw ShelfError("PDF «\(src.lastPathComponent)»: не отрисовать страницу \(i + 1)")
            }
            let name = doc.pageCount == 1 ? "\(base).png" : "\(base) — стр. \(i + 1).png"
            let dst = ShelfFiles.uniqueURL(in: outDir, name: name)
            try writeImage(cg, to: dst, type: .png, options: [:])
            out.append(dst)
            progress(Double(i + 1) / Double(doc.pageCount))
        }
        if out.isEmpty { throw ShelfError("В PDF «\(src.lastPathComponent)» нет страниц") }
        return out
    }

    /// Не больше стольких пикселей на страницу (64 Мп ≈ 256 МБ памяти): огромные страницы уменьшаются, а не пропускаются.
    static let maxPagePixels: CGFloat = 64_000_000

    /// Страница по `.cropBox` (видимая область, как в Просмотре) с поворотом страницы.
    static func render(_ page: PDFPage, scale wanted: CGFloat, opaque: Bool) -> CGImage? {
        let box = page.bounds(for: .cropBox)
        let rotated = page.rotation % 180 != 0
        let bw = rotated ? box.height : box.width, bh = rotated ? box.width : box.height
        guard bw >= 1, bh >= 1 else { return nil }
        let scale = min(wanted, (maxPagePixels / (bw * bh)).squareRoot())
        let w = max(1, Int(bw * scale)), h = max(1, Int(bh * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        if opaque { ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h)) }
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: ctx)
        return ctx.makeImage()
    }

    static func flattened(_ image: CGImage) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let r = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(r)
        ctx.draw(image, in: r)
        return ctx.makeImage()
    }

    static func writeImage(_ image: CGImage, to url: URL, type: UTType, options: [CFString: Any]) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw ShelfError("Формат \(type.preferredFilenameExtension ?? type.identifier) не поддерживается")
        }
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ShelfError("Не записать «\(url.lastPathComponent)»") }
    }

    /// Картинка «как её видит человек»: с учётом EXIF-ориентации (фото с iPhone хранятся боком, orientation 6/8).
    /// Thumbnail с `WithTransform` на полный размер — ImageIO сам поворачивает пиксели.
    static func loadUpright(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ShelfError("Не открыть картинку «\(url.lastPathComponent)»")
        }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (props?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        if orientation != 1,
           let w = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
           let h = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(w, h),
                kCGImageSourceShouldCacheImmediately: true,
            ]
            if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) { return cg }
        }
        guard let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ShelfError("Не открыть картинку «\(url.lastPathComponent)»")
        }
        return cg
    }

    // MARK: Распознавание текста

    /// Картинки — Vision (ru + en, accurate); PDF — текстовый слой, если есть, иначе Vision по страницам.
    /// Возвращает текст (строки через \n).
    static func recognizeText(_ urls: [URL], progress: @escaping Progress) throws -> String {
        var chunks: [String] = []
        for (i, u) in urls.enumerated() {
            let base = Double(i) / Double(urls.count), span = 1 / Double(urls.count)
            if isPDF(u) {
                guard let doc = PDFDocument(url: u) else { throw ShelfError("Не открыть PDF «\(u.lastPathComponent)»") }
                for p in 0..<doc.pageCount {
                    guard let page = doc.page(at: p) else { continue }
                    let layer = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !layer.isEmpty {
                        chunks.append(layer)
                    } else if let cg = render(page, scale: 2, opaque: true) {
                        chunks.append(try ocr(cg))
                    }
                    progress(base + span * Double(p + 1) / Double(max(1, doc.pageCount)))
                }
            } else if isImage(u) {
                let cg = try loadUpright(u)
                chunks.append(try ocr(cg) { progress(base + span * $0) })
            } else {
                throw ShelfError("«\(u.lastPathComponent)» — не картинка и не PDF")
            }
        }
        return chunks.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    static func ocr(_ image: CGImage, progress: Progress? = nil) throws -> String {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        let supported = (try? req.supportedRecognitionLanguages()) ?? []
        let wanted = ["ru-RU", "en-US"].filter { supported.contains($0) }
        req.recognitionLanguages = wanted.isEmpty ? ["en-US"] : wanted
        if let progress { req.progressHandler = { _, p, _ in progress(p) } }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([req]) } catch {
            throw ShelfError("Распознавание не удалось: \(error.localizedDescription)")
        }
        let lines = (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }

    // MARK: Без фона

    /// VNGenerateForegroundInstanceMaskRequest → PNG с прозрачностью.
    static func removeBackground(_ src: URL, outDir: URL) throws -> URL {
        let cg = try loadUpright(src)
        let req = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do { try handler.perform([req]) } catch {
            throw ShelfError("Вырезание фона не удалось: \(error.localizedDescription)")
        }
        guard let result = req.results?.first, !result.allInstances.isEmpty else {
            throw ShelfError("Не нашёл на «\(src.lastPathComponent)» предмета, который можно вырезать")
        }
        let buffer: CVPixelBuffer
        do {
            buffer = try result.generateMaskedImage(ofInstances: result.allInstances, from: handler,
                                                    croppedToInstancesExtent: false)
        } catch {
            throw ShelfError("Маска не построилась: \(error.localizedDescription)")
        }
        let ci = CIImage(cvPixelBuffer: buffer)
        let ctx = CIContext(options: [.cacheIntermediates: false])
        guard let out = ctx.createCGImage(ci, from: ci.extent, format: .RGBA8,
                                          colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else {
            throw ShelfError("Не собрать PNG")
        }
        let name = (src.lastPathComponent as NSString).deletingPathExtension + " — без фона.png"
        let dst = ShelfFiles.uniqueURL(in: outDir, name: name)
        try writeImage(out, to: dst, type: .png, options: [:])
        return dst
    }

    // MARK: Свои действия

    /// Скрипт `*.sh` из папки действий: `/bin/bash скрипт путь…`. Вывод — последняя строка stdout.
    static func runScript(_ script: URL, files: [URL]) throws -> String {
        let r = try run("/bin/bash", [script.path] + files.map(\.path), timeout: 600)
        guard r.status == 0 else {
            throw ShelfError("«\(script.deletingPathExtension().lastPathComponent)»: код \(r.status)"
                             + (r.stderr.isEmpty ? "" : " — \(lastLine(r.stderr))"))
        }
        return lastLine(r.stdout)
    }

    /// Что вернула команда Shortcuts: текст (в уведомление) или файл (на полку).
    enum ShortcutOutput: Sendable { case text(String), file(URL) }

    /// `shortcuts run <имя> -i <файл>… -o <временный файл>`. Вывод — в файл, а не в stdout:
    /// команда может вернуть картинку или документ, и тогда в уведомление попал бы двоичный мусор.
    static func runShortcut(_ name: String, files: [URL], outDir: URL) throws -> ShortcutOutput {
        var args = ["run", name]
        for f in files { args += ["-i", f.path] }
        let raw = outDir.appendingPathComponent("вывод")
        args += ["-o", raw.path]
        let r = try run("/usr/bin/shortcuts", args, timeout: 600)
        guard r.status == 0 else {
            throw ShelfError("Команда «\(name)»: \(r.stderr.isEmpty ? "код \(r.status)" : lastLine(r.stderr))")
        }
        guard let data = try? Data(contentsOf: raw), !data.isEmpty else {
            try? FileManager.default.removeItem(at: raw)
            return .text(textLine(Data(r.stdout.utf8)) ?? "")
        }
        if let ext = fileExtension(of: data, at: raw) {
            let dst = ShelfFiles.uniqueURL(in: outDir, name: "\(name) — результат.\(ext)")
            try FileManager.default.moveItem(at: raw, to: dst)
            return .file(dst)
        }
        try? FileManager.default.removeItem(at: raw)
        return .text(textLine(data) ?? "")
    }

    /// Расширение для двоичного вывода; nil — это обычный текст.
    static func fileExtension(of data: Data, at url: URL) -> String? {
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0,
           let type = CGImageSourceGetType(src) as String?, let ut = UTType(type), !ut.conforms(to: .pdf) {
            return ut.preferredFilenameExtension ?? "png"
        }
        if data.starts(with: Array("%PDF".utf8)) { return "pdf" }
        if data.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return "zip" }
        return textLine(data) == nil ? "bin" : nil
    }

    /// Последняя строка, если данные — текст (UTF-8 без нулевых байтов), иначе nil.
    static func textLine(_ data: Data) -> String? {
        guard !data.contains(0), let s = String(data: data, encoding: .utf8) else { return nil }
        return lastLine(s)
    }

    /// Список команд Shortcuts (`shortcuts list`). Пусто — нет команд или нет утилиты.
    static func listShortcuts() -> [String] {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/shortcuts"),
              let r = try? run("/usr/bin/shortcuts", ["list"], timeout: 20), r.status == 0 else { return [] }
        return r.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func lastLine(_ s: String) -> String {
        s.split(separator: "\n").last.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
    }

    // MARK: Процессы

    struct RunResult: Sendable { var status: Int32; var stdout: String; var stderr: String }

    /// Запустить и дождаться (из фона, не из пула Swift concurrency — ждёт блокирующе). Через
    /// `ManagedProcess.runCollectingBlocking`: своя группа процессов, по таймауту — SIGTERM группе и через 2 с
    /// SIGKILL (вместе с потомками скрипта), при выходе/падении приложения дети гасятся ядром, сироты после
    /// `kill -9` добиваются при следующем запуске. Вывод — через файлы: фоновый потомок (`cmd &`) его не держит,
    /// после выхода скрипта остаток группы добивается.
    static func run(_ exe: String, _ args: [String], timeout: TimeInterval = 120) throws -> RunResult {
        let name = URL(fileURLWithPath: exe).lastPathComponent
        let r = ManagedProcess.runCollectingBlocking(exe, args, timeout: timeout)
        if r.launchFailed { throw ShelfError("Не запустить \(name): \(r.stderr)") }
        if r.timedOut { throw ShelfError("\(name): не ответил за \(Int(timeout)) с") }
        // Убит сигналом — как у оболочки: 128 + номер.
        let code: Int32 = r.status < 0 ? 128 - r.status : r.status
        return RunResult(status: code, stdout: r.stdout,
                         stderr: r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
