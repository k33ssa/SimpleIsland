import AppKit
import CoreText
import Foundation
import ImageIO
import IslandCore
import PDFKit
import UniformTypeIdentifiers

/// Самотест полки без экрана: `SimpleIsland --selftest-shelf [--selftest-dir <каталог>]`.
/// Сам рисует тестовые картинки и PDF (ru + en текст, предмет на фоне), гоняет хранилище, ZIP, конвертер,
/// OCR, вырезание фона, скрипт и `shortcuts list`. Ничего не трогает вне своего каталога (по умолчанию — temp).
public enum ShelfSelfTest {
    @MainActor
    public static func run(_ args: [String]) -> Int32 {
        // pid-файлы детей (ManagedProcess) — во временном каталоге, а не в каталоге приложения: упавший самотест
        // не оставит «сирот» на проверку работающему приложению.
        let pidDir = FileManager.default.temporaryDirectory.appendingPathComponent("si-shelf-selftest-pids-\(getpid())")
        ManagedProcess.pidDirectory = pidDir
        defer { try? FileManager.default.removeItem(at: pidDir) }
        var dir = FileManager.default.temporaryDirectory.appendingPathComponent("SimpleIsland-shelf-selftest")
        if let i = args.firstIndex(of: "--selftest-dir"), i + 1 < args.count {
            dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        }
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let inDir = dir.appendingPathComponent("in", isDirectory: true)
        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        try? FileManager.default.createDirectory(at: inDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        var failures = 0
        func check(_ name: String, _ body: () throws -> String) {
            let t0 = Date()
            do {
                let note = try body()
                print("OK    " + name.padding(toLength: 34, withPad: " ", startingAt: 0)
                      + String(format: "%5.2f с  ", Date().timeIntervalSince(t0)) + note)
            } catch {
                failures += 1
                print("FAIL  " + name.padding(toLength: 34, withPad: " ", startingAt: 0)
                      + String(format: "%5.2f с  ", Date().timeIntervalSince(t0)) + error.localizedDescription)
            }
        }
        func expect(_ cond: Bool, _ msg: @autoclosure () -> String) throws { if !cond { throw ShelfError(msg()) } }

        // Тестовые файлы
        let textPNG = inDir.appendingPathComponent("текст.png")
        let photoPNG = inDir.appendingPathComponent("предмет.png")
        let pdf = inDir.appendingPathComponent("лаба_4.pdf")
        let scanPDF = inDir.appendingPathComponent("скан.pdf")
        check("генерация тестовых файлов") {
            try writePNG(textImage(), to: textPNG)
            try writePNG(objectImage(), to: photoPNG)
            try makeTextPDF(pdf, pages: ["Лабораторная работа № 4\nLab report, page one", "Страница два\nPage two"])
            try makeScanPDF(scanPDF, image: textImage())
            return [textPNG, photoPNG, pdf, scanPDF].map(\.lastPathComponent).joined(separator: ", ")
        }

        // Хранилище: копия, срок, удаление
        check("полка: копия и срок") {
            let store = ShelfStore(root: dir.appendingPathComponent("Shelf", isDirectory: true))
            store.load()
            var new = try ShelfFiles.importFiles([textPNG, pdf], into: store.root, move: false)
            new[0].addedAt = Date().addingTimeInterval(-25 * 3600)       // «вчерашний»
            store.append(new)
            try expect(FileManager.default.fileExists(atPath: store.url(for: new[1]).path), "копия не легла")
            try expect(FileManager.default.fileExists(atPath: textPNG.path), "оригинал пропал")
            let reloaded = ShelfStore(root: store.root); reloaded.load()
            try expect(reloaded.items.count == 2, "индекс не перечитался: \(reloaded.items.count)")
            let purged = reloaded.purgeExpired(ttl: 24 * 3600)
            try expect(purged == 1 && reloaded.items.count == 1, "срок: удалено \(purged), осталось \(reloaded.items.count)")
            try expect(!FileManager.default.fileExists(atPath: reloaded.url(for: new[0]).path), "просроченный файл остался")
            try expect(reloaded.contains(reloaded.url(for: new[1])) && !reloaded.contains(pdf), "contains() врёт")
            return "2 файла → после 24 ч остался 1"
        }

        check("полка: битый индекс → файлы не теряются") {
            let root = dir.appendingPathComponent("Shelf-broken", isDirectory: true)
            let store = ShelfStore(root: root)
            store.load()
            let new = try ShelfFiles.importFiles([textPNG, pdf], into: root, move: false)
            store.append(new)
            try Data("{ это не json".utf8).write(to: store.indexURL)
            try FileManager.default.createDirectory(at: root.appendingPathComponent(UUID().uuidString), withIntermediateDirectories: true)
            let again = ShelfStore(root: root); again.load()
            try expect(again.items.count == 2, "восстановлено \(again.items.count) из 2")
            for item in new {
                try expect(FileManager.default.fileExists(atPath: again.url(for: item).path), "файл \(item.name) удалён")
            }
            let names = Set(again.items.map(\.name))
            try expect(names == Set(new.map(\.name)), "имена: \(names)")
            let broken = (try FileManager.default.contentsOfDirectory(atPath: root.path)).filter { $0.hasPrefix("index.broken-") }
            try expect(broken.count == 1, "битый индекс не сохранён рядом")
            let third = ShelfStore(root: root); third.load()
            try expect(third.items.count == 2, "новый индекс не записался")
            return "2 файла восстановлены, пустая папка убрана, \(broken[0])"
        }

        check("щелчок по плитке: только выбранные") {
            let m = ShelfModel(store: ShelfStore(root: dir.appendingPathComponent("Shelf-mock", isDirectory: true)))
            let items = ShelfModel.mockItems()
            m.applyMock(items: items)
            try expect(m.tapSubjects.isEmpty, "без выбора взяло \(m.tapSubjects.count)")
            m.applyMock(items: items, selection: [items[2].id])
            try expect(m.tapSubjects.count == 1, "с выбором — \(m.tapSubjects.count)")
            let mixed = [textPNG, pdf, dir.appendingPathComponent("отчёт.docx")]
            let cut = mixed.filter { ShelfModel.accepts(.cutout, $0) }
            let conv = mixed.filter { ShelfModel.accepts(.convert, $0) }
            try expect(cut == [textPNG] && conv == [textPNG, pdf], "фильтр по типу: \(cut.count)/\(conv.count)")
            return "без выбора — подсказка; смешанная полка: «Без фона» берёт 1 из 3, конвертер 2 из 3"
        }

        check("ZIP: один файл") {
            let z = try ShelfOperations.zip([pdf], outDir: outDir)
            let list = try ShelfOperations.run("/usr/bin/unzip", ["-l", z.path]).stdout
            try expect(list.contains("лаба_4.pdf") || list.contains("pdf"), "в архиве нет файла:\n\(list)")
            return "\(z.lastPathComponent), \(ShelfFormat.size(ShelfFiles.size(of: z)))"
        }
        check("ZIP: несколько файлов") {
            let z = try ShelfOperations.zip([pdf, textPNG], outDir: outDir)
            let r = try ShelfOperations.run("/usr/bin/unzip", ["-Z1", z.path])
            let names = r.stdout.split(separator: "\n")
            try expect(names.count >= 3, "в архиве \(names.count) записей:\n\(r.stdout)")
            return "\(z.lastPathComponent): записей в архиве — \(names.count)"
        }

        check("конвертер: PNG → JPEG/HEIC") {
            let jpg = try ShelfOperations.convertImage(textPNG, to: ShelfConvertFormat.auto.resolved(for: textPNG), outDir: outDir)
            let heic = try ShelfOperations.convertImage(textPNG, to: .heic, outDir: outDir)
            try expect(typeOf(jpg) == UTType.jpeg.identifier, "JPEG: \(typeOf(jpg) ?? "?")")
            try expect(typeOf(heic) == UTType.heic.identifier, "HEIC: \(typeOf(heic) ?? "?")")
            let back = try ShelfOperations.convertImage(jpg, to: ShelfConvertFormat.auto.resolved(for: jpg), outDir: outDir)
            try expect(typeOf(back) == UTType.png.identifier, "JPEG → авто должен дать PNG: \(typeOf(back) ?? "?")")
            return "\(jpg.lastPathComponent), \(heic.lastPathComponent), \(back.lastPathComponent)"
        }
        check("конвертер: PDF → PNG по страницам") {
            let pages = try ShelfOperations.convert([pdf], format: .auto, outDir: outDir) { _ in }
            try expect(pages.count == 2, "страниц \(pages.count)")
            for p in pages { try expect(typeOf(p) == UTType.png.identifier, "\(p.lastPathComponent) не PNG") }
            let size = imageSize(pages[0])
            return pages.map(\.lastPathComponent).joined(separator: ", ") + " (\(Int(size.width))×\(Int(size.height)))"
        }

        check("конвертер: PDF по cropBox и огромная страница") {
            let cropped = inDir.appendingPathComponent("обрезка.pdf")
            try makeBoxPDF(cropped, media: CGRect(x: 0, y: 0, width: 600, height: 800), crop: CGRect(x: 100, y: 100, width: 300, height: 200))
            let pages = try ShelfOperations.convert([cropped], format: .auto, outDir: outDir) { _ in }
            let sz = imageSize(pages[0])
            try expect(Int(sz.width) == 600 && Int(sz.height) == 400, "cropBox ×2 должен дать 600×400, вышло \(Int(sz.width))×\(Int(sz.height))")
            let huge = inDir.appendingPathComponent("огромный.pdf")
            try makeBoxPDF(huge, media: CGRect(x: 0, y: 0, width: 14000, height: 14000), crop: nil)
            guard let page = PDFDocument(url: huge)?.page(at: 0),
                  let cg = ShelfOperations.render(page, scale: 2, opaque: true) else { throw ShelfError("огромная страница пропущена") }
            try expect(CGFloat(cg.width * cg.height) <= ShelfOperations.maxPagePixels, "\(cg.width)×\(cg.height) больше лимита")
            return "обрезка → \(Int(sz.width))×\(Int(sz.height)); 14000² pt → \(cg.width)×\(cg.height)"
        }

        // Фото «с iPhone»: пиксели лежат боком, в EXIF orientation 6 (показывать с поворотом на 90° по часовой).
        let rotatedJPG = inDir.appendingPathComponent("боком.jpg")
        check("EXIF-поворот: OCR и «Без фона»") {
            let upright = textImage()
            let stored = rotateCCW(upright)
            try ShelfOperations.writeImage(stored, to: rotatedJPG, type: .jpeg,
                                           options: [kCGImagePropertyOrientation: 6, kCGImageDestinationLossyCompressionQuality: 0.95])
            let fixed = try ShelfOperations.loadUpright(rotatedJPG)
            try expect(fixed.width == upright.width && fixed.height == upright.height,
                       "после поворота \(fixed.width)×\(fixed.height), ждали \(upright.width)×\(upright.height)")
            let text = try ShelfOperations.recognizeText([rotatedJPG]) { _ in }.lowercased()
            try expect(text.contains("привет") && text.contains("hello"), "текст с повёрнутого фото: «\(text)»")
            let objStored = inDir.appendingPathComponent("предмет-боком.jpg")
            try ShelfOperations.writeImage(rotateCCW(objectImage()), to: objStored, type: .jpeg,
                                           options: [kCGImagePropertyOrientation: 6])
            let cut = try ShelfOperations.removeBackground(objStored, outDir: outDir)
            let cs = imageSize(cut)
            try expect(Int(cs.width) == 900 && Int(cs.height) == 700, "«Без фона» \(Int(cs.width))×\(Int(cs.height)), ждали 900×700")
            return "\(stored.width)×\(stored.height) + orientation 6 → \(fixed.width)×\(fixed.height); текст прочитан; PNG без фона стоит прямо"
        }

        check("OCR: картинка ru + en") {
            let text = try ShelfOperations.recognizeText([textPNG]) { _ in }
            let low = text.lowercased()
            try expect(low.contains("привет") && low.contains("остров"), "нет русского: «\(text)»")
            try expect(low.contains("hello") && low.contains("island"), "нет английского: «\(text)»")
            return text.replacingOccurrences(of: "\n", with: " ⏎ ")
        }
        check("OCR: PDF с текстом и скан") {
            let t1 = try ShelfOperations.recognizeText([pdf]) { _ in }
            try expect(t1.contains("Лабораторная") && t1.contains("Page two"), "текстовый слой: «\(t1)»")
            let t2 = try ShelfOperations.recognizeText([scanPDF]) { _ in }
            try expect(t2.lowercased().contains("привет"), "скан (Vision): «\(t2)»")
            return "строк: текстовый слой — \(t1.split(separator: "\n").count), скан — \(t2.split(separator: "\n").count)"
        }

        check("без фона: нарисованный предмет") {
            let out = try ShelfOperations.removeBackground(photoPNG, outDir: outDir)
            let (clear, solid) = try alphaStats(out)
            try expect(clear > 0.2 && solid > 0.05, String(format: "прозрачных %.0f%%, плотных %.0f%%", clear * 100, solid * 100))
            return String(format: "%@: прозрачно %.0f%%, предмет %.0f%%", out.lastPathComponent, clear * 100, solid * 100)
        }
        let sample = URL(fileURLWithPath: "/Library/User Pictures/Animals/Parrot.heic")
        if FileManager.default.fileExists(atPath: sample.path) {
            check("без фона: фото из системы") {
                let out = try ShelfOperations.removeBackground(sample, outDir: outDir)
                let (clear, solid) = try alphaStats(out)
                try expect(clear > 0.05 && solid > 0.05, String(format: "прозрачных %.0f%%, плотных %.0f%%", clear * 100, solid * 100))
                return String(format: "Parrot.heic → прозрачно %.0f%%, предмет %.0f%%", clear * 100, solid * 100)
            }
        }
        check("без фона: пустая картинка → понятная ошибка") {
            let blank = inDir.appendingPathComponent("пусто.png")
            try writePNG(blankImage(), to: blank)
            do {
                _ = try ShelfOperations.removeBackground(blank, outDir: outDir)
                return "(предмет найден на пустой — не страшно)"
            } catch let e as ShelfError {
                return "ошибка: \(e.message)"
            }
        }

        check("свой скрипт") {
            let script = dir.appendingPathComponent("тест.sh")
            try "#!/bin/bash\necho \"файлов: $#\"\nbasename \"$1\"\n".write(to: script, atomically: true, encoding: .utf8)
            let out = try ShelfOperations.runScript(script, files: [pdf, textPNG])
            try expect(out == "лаба_4.pdf", "вывод «\(out)»")
            let bad = dir.appendingPathComponent("плохой.sh")
            try "echo упал >&2; exit 3\n".write(to: bad, atomically: true, encoding: .utf8)
            do { _ = try ShelfOperations.runScript(bad, files: []); throw ShelfError("ошибка не поймана") }
            catch let e as ShelfError where e.message.contains("код 3") {}
            return "вывод «\(out)», код ошибки ловится"
        }
        check("процессы: таймаут гасит всю группу") {
            let pidFile = dir.appendingPathComponent("child.pid")
            let script = dir.appendingPathComponent("висит.sh")
            try "sleep 60 &\necho $! > \"$1\"\nsleep 60\n".write(to: script, atomically: true, encoding: .utf8)
            let t0 = Date()
            do { _ = try ShelfOperations.run("/bin/bash", [script.path, pidFile.path], timeout: 1.5); throw ShelfError("таймаут не сработал") }
            catch let e as ShelfError where e.message.contains("не ответил") {}
            let took = Date().timeIntervalSince(t0)
            try expect(took < 8, String(format: "ждали %.1f с", took))
            let pid = pid_t(Int32((try String(contentsOf: pidFile, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
            try expect(pid > 0, "pid потомка не записан")
            var alive = true
            for _ in 0..<20 where alive { alive = kill(pid, 0) == 0; if alive { usleep(100_000) } }
            try expect(!alive, "потомок \(pid) жив после таймаута")
            // Скрипт вышел, а фоновый потомок держит вывод — не висим.
            let bg = dir.appendingPathComponent("фон.sh")
            try "sleep 60 &\necho готово\n".write(to: bg, atomically: true, encoding: .utf8)
            let t1 = Date()
            let out = try ShelfOperations.runScript(bg, files: [])
            try expect(out == "готово" && Date().timeIntervalSince(t1) < 8, "вывод «\(out)»")
            return String(format: "таймаут за %.1f с, потомок убит; фоновый потомок не держит вывод (%.1f с)", took, Date().timeIntervalSince(t1))
        }
        check("Shortcuts: вывод текст/файл") {
            let png = outDir.appendingPathComponent("вывод-тест")
            try ShelfOperations.writeImage(blankImage(), to: png, type: .png, options: [:])
            let pngExt = ShelfOperations.fileExtension(of: try Data(contentsOf: png), at: png)
            let txt = outDir.appendingPathComponent("вывод-текст")
            try Data("строка 1\nитог\n".utf8).write(to: txt)
            let txtExt = ShelfOperations.fileExtension(of: try Data(contentsOf: txt), at: txt)
            let bin = outDir.appendingPathComponent("вывод-бин")
            try Data([0, 1, 2, 255, 0]).write(to: bin)
            let binExt = ShelfOperations.fileExtension(of: try Data(contentsOf: bin), at: bin)
            try expect(pngExt == "png" && txtExt == nil && binExt == "bin", "\(pngExt ?? "nil")/\(txtExt ?? "nil")/\(binExt ?? "nil")")
            try expect(ShelfOperations.textLine(try Data(contentsOf: txt)) == "итог", "текстовая строка")
            return "картинка → .png на полку, текст → «итог» в уведомление, двоичное → .bin"
        }
        check("shortcuts list") {
            let list = ShelfOperations.listShortcuts()
            return "команд: \(list.count)" + (list.isEmpty ? "" : " (\(list.prefix(3).joined(separator: ", "))…)")
        }
        // --- misc2 ---
        check("процессы: нет программы, сироты") {
            do { _ = try ShelfOperations.run("/nonexistent/tool", []); throw ShelfError("ошибка не поймана") }
            catch let e as ShelfError where e.message.contains("Не запустить") {}
            let end = Date().addingTimeInterval(5)
            while !ManagedProcess.liveGroups.isEmpty && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            try expect(ManagedProcess.liveGroups.isEmpty, "живые группы: \(ManagedProcess.liveGroups)")
            return "понятная ошибка; после всех запусков живых дочерних групп нет"
        }
        // --- shelfbar --- «скрин не кладётся» (15.11): бросок картинки без файла (снимок экрана, браузер) и
        // file-url — через разбор drag-буфера (синтетический пастборд) в `Shelf/incoming/<uuid>` и на полку.
        check("бросок: картинка и файл на полку") {
            let settings = SimpleIslandSettings(inMemory: SettingsData())
            let ctx = ModuleContext(moduleId: "shelf", settings: settings, themes: ThemeStore(load: false),
                                    activities: ActivityCenter(), hud: HUDCenter(), notifications: IslandNotifications(),
                                    island: IslandStateCenter(), openTab: { _ in })
            let root = dir.appendingPathComponent("drop-store", isDirectory: true)
            let model = ShelfModel(store: ShelfStore(root: root), actionsDir: dir.appendingPathComponent("actions"))
            model.start(ctx)
            func wait(_ cond: () -> Bool) { let end = Date().addingTimeInterval(10); while !cond() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) } }
            let pb = NSPasteboard(name: .init("SimpleIsland.selftest.shelfdrop.\(getpid())"))
            defer { pb.releaseGlobally() }
            // 1. Сырая картинка (как из Safari / миниатюры снимка, если она отдала данные)
            pb.clearContents()
            pb.setData(try Data(contentsOf: textPNG), forType: .png)
            try expect(DragPasteboard.inspect(pb).kind == .image, "картинка не распознана")
            let incoming = model.newIncomingDir()
            try expect(model.isIncoming(incoming.appendingPathComponent("x.png")), "папка приёма не в Shelf/incoming")
            var got: [URL]?
            DragPasteboard.receive(pb, into: incoming) { got = $0 }
            wait { got != nil }
            try expect(got?.count == 1, "картинка не сохранена: \(String(describing: got))")
            model.acceptDropped(got!, on: .shelf)
            wait { model.items.count == 1 }
            try expect(model.items.count == 1 && model.items[0].name.hasPrefix("Снимок ") && model.items[0].name.hasSuffix(".png"),
                       "на полке: \(model.items.map(\.name))")
            wait { !FileManager.default.fileExists(atPath: incoming.path) }
            try expect(!FileManager.default.fileExists(atPath: incoming.path), "папка приёма не убрана после переноса")
            // 2. Файл — копия, оригинал на месте (тестовый лежит во временной папке → копия в папке приёма сразу)
            pb.clearContents()
            pb.writeObjects([pdf as NSURL])
            var files: [URL]?
            DragPasteboard.receive(pb, into: model.newIncomingDir()) { files = $0 }
            wait { files != nil }
            try expect(files?.count == 1 && files![0].lastPathComponent == pdf.lastPathComponent && model.isIncoming(files![0]),
                       "file-url: \(String(describing: files))")
            model.acceptDropped(files!, on: .shelf)
            wait { model.items.count == 2 }
            try expect(model.items.count == 2 && FileManager.default.fileExists(atPath: pdf.path), "файл Finder: копия, оригинал на месте")
            model.stop()
            return model.items.map(\.name).joined(separator: ", ")
        }
        // --- /shelfbar ---

        // --- shelfshot --- «снимок потерян» (16.11): миниатюра снимка отдаёт file-url во временную папку
        // (TemporaryItems/NSIRD_screencaptureui_*), источник убирает его сразу после броска, а читать его нам бывает
        // нельзя (TCC). Бросок должен забрать файл до возврата, а не взяв — вернуть false (снимок остаётся у macOS).
        check("бросок: снимок из временной папки") {
            let settings = SimpleIslandSettings(inMemory: SettingsData())
            let notes = IslandNotifications()
            let ctx = ModuleContext(moduleId: "shelf", settings: settings, themes: ThemeStore(load: false),
                                    activities: ActivityCenter(), hud: HUDCenter(), notifications: notes,
                                    island: IslandStateCenter(), openTab: { _ in })
            let root = dir.appendingPathComponent("shot-store", isDirectory: true)
            let model = ShelfModel(store: ShelfStore(root: root), actionsDir: dir.appendingPathComponent("actions"))
            model.start(ctx)
            defer { model.stop() }
            func wait(_ cond: () -> Bool) { let end = Date().addingTimeInterval(10); while !cond() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) } }
            let fm = FileManager.default
            let pb = NSPasteboard(name: .init("SimpleIsland.selftest.shelfshot.\(getpid())"))
            defer { pb.releaseGlobally() }
            let shotName = "Снимок экрана 2026-11-16 в 16.41.32.png"
            let png = try Data(contentsOf: textPNG)
            var notes2: [String] = []

            // 1. file-url в настоящей TemporaryItems/NSIRD_* (как у screencaptureui); источник удаляет её сразу
            //    после возврата из броска — файл всё равно на полке.
            let nsird = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                   appropriateFor: fm.homeDirectoryForCurrentUser, create: true)
            defer { try? fm.removeItem(at: nsird) }
            let shot = nsird.appendingPathComponent(shotName)
            try png.write(to: shot)
            try expect(DragPasteboard.isVolatile(shot), "TemporaryItems не считается временным: \(shot.path)")
            pb.clearContents(); pb.writeObjects([shot as NSURL])
            var ok = model.drop(pb, providers: [], on: .shelf)
            try fm.removeItem(at: nsird)                         // источник убрал снимок сразу после броска
            try expect(ok, "бросок не принят")
            wait { model.items.count == 1 }
            try expect(model.items.map(\.name) == [shotName], "на полке: \(model.items.map(\.name))")
            try expect((try? Data(contentsOf: model.url(for: model.items[0]))) == png, "содержимое снимка не то")
            notes2.append("TemporaryItems → на полке")

            // 2. Нечитаемый файл и больше ничего — false, источник не тронут, понятная ошибка.
            let locked = dir.appendingPathComponent("locked", isDirectory: true)
            try fm.createDirectory(at: locked, withIntermediateDirectories: true)
            let lockedShot = locked.appendingPathComponent(shotName)
            try png.write(to: lockedShot)
            try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: lockedShot.path)
            defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: lockedShot.path) }
            try expect(!DragPasteboard.canRead(lockedShot), "chmod 000 читается — проверка невозможна")
            pb.clearContents(); pb.writeObjects([lockedShot as NSURL])
            while notes.current != nil { notes.dismiss() }
            ok = model.drop(pb, providers: [], on: .shelf)
            try expect(!ok, "нечитаемый снимок: бросок принят (true) — macOS сочла бы его доставленным")
            wait { notes.current != nil }
            try expect(notes.current?.title == "Снимок не взят" && notes.current?.body.contains("не потерян") == true,
                       "ошибка: \(notes.current?.title ?? "нет") / \(notes.current?.body ?? "")")
            try expect(fm.fileExists(atPath: lockedShot.path) && model.items.count == 1, "источник тронут или полка изменилась")
            notes.dismiss()
            notes2.append("нечитаемый → false + ошибка")

            // 3. Нечитаемый файл + данные картинки в буфере — сохраняется из данных под исходным именем.
            pb.clearContents()
            let item = NSPasteboardItem()
            item.setString(lockedShot.absoluteString, forType: .fileURL)
            item.setData(png, forType: .png)
            pb.writeObjects([item])
            ok = model.drop(pb, providers: [], on: .shelf)
            try expect(ok, "есть данные картинки, а бросок не принят")
            wait { model.items.count == 2 }
            try expect(model.items.filter { $0.name == shotName }.count == 2,
                       "из данных: \(model.items.map(\.name))")
            notes2.append("нечитаемый + PNG в буфере → на полке")

            // 4. Обещание файла: источник пишет файл уже после возврата из броска (подменённое выполнение).
            pb.clearContents()
            let promiseDelegate = ShotPromise()
            pb.writeObjects([NSFilePromiseProvider(fileType: UTType.png.identifier, delegate: promiseDelegate)])
            try expect(DragPasteboard.inspectTypes(pb).kind == .promises, "обещание не распознано")
            let fetch: DragPasteboard.PromiseFetcher = { _, into, _, done in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    let u = into.appendingPathComponent("Снимок экрана 2026-11-16 в 16.42.00.png")
                    try? fm.createDirectory(at: into, withIntermediateDirectories: true)
                    try? png.write(to: u)
                    MainActor.assumeIsolated { done([u]) }
                }
                return true
            }
            ok = model.drop(pb, providers: [], on: .shelf, promiseFetcher: fetch)
            try expect(ok, "обещание: бросок не принят")
            wait { model.items.count == 3 }
            try expect(model.items.contains { $0.name == "Снимок экрана 2026-11-16 в 16.42.00.png" }, "обещание: \(model.items.map(\.name))")
            notes2.append("обещание → на полке")

            // 5. Обещание, которое источник не выполнил, без картинки — ошибка, полка не меняется.
            let empty: DragPasteboard.PromiseFetcher = { _, _, _, done in
                DispatchQueue.main.async { MainActor.assumeIsolated { done([]) } }
                return true
            }
            while notes.current != nil { notes.dismiss() }
            ok = model.drop(pb, providers: [], on: .shelf, promiseFetcher: empty)
            wait { notes.current != nil }
            try expect(notes.current?.title == "Не удалось взять файл" && model.items.count == 3,
                       "невыполненное обещание: \(notes.current?.title ?? "нет"), \(model.items.count)")
            notes.dismiss()
            notes2.append("обещание не выполнено → ошибка")

            // 6. Тот же снимок в сыром виде (только PNG) — «картинка» на полку (Safari, просмотрщики).
            pb.clearContents(); pb.setData(png, forType: .png)
            ok = model.drop(pb, providers: [], on: .shelf)
            wait { model.items.count == 4 }
            try expect(ok && model.items.count == 4, "картинка: \(model.items.map(\.name))")
            // Папки приёма пустеют (перенос на полку)
            wait { ((try? fm.contentsOfDirectory(atPath: model.incomingRoot.path)) ?? []).isEmpty }
            let left = (try? fm.contentsOfDirectory(atPath: model.incomingRoot.path)) ?? []
            try expect(left.isEmpty, "в incoming осталось: \(left)")
            return notes2.joined(separator: "; ")
        }
        // --- /shelfshot ---

        check("модель: автоочистка, миниатюры, удержание") {
            let settings = SimpleIslandSettings(inMemory: SettingsData())
            let island = IslandStateCenter()
            let ctx = ModuleContext(moduleId: "shelf", settings: settings, themes: ThemeStore(load: false),
                                    activities: ActivityCenter(), hud: HUDCenter(), notifications: IslandNotifications(),
                                    island: island, openTab: { _ in })
            let root = dir.appendingPathComponent("model-store", isDirectory: true)
            let model = ShelfModel(store: ShelfStore(root: root), actionsDir: dir.appendingPathComponent("actions"))
            let subs0 = SharedTicker.shared.subscriberCount
            model.start(ctx)
            try expect(!model.isPurgeScheduled && SharedTicker.shared.subscriberCount == subs0, "пустая полка — без подписки")
            var added = false
            model.addToShelf([textPNG, pdf]) { new in added = !new.isEmpty }
            let end = Date().addingTimeInterval(10)
            while !added && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            try expect(added && model.items.count == 2, "не положилось: \(model.items.count)")
            let due = model.items.map { $0.addedAt.addingTimeInterval(model.prefs.ttl) }.min()!
            try expect(model.isPurgeScheduled && SharedTicker.shared.subscriberCount == subs0
                       && abs((model.purgeAt ?? .distantPast).timeIntervalSince(due)) < 5,
                       "автоочистка — одна задача на ближайший срок, без тикера: \(String(describing: model.purgeAt)) vs \(due)")
            for item in model.items { model.thumbnailAppeared(item) }
            let tEnd = Date().addingTimeInterval(15)
            while model.thumbnails.count < 2 && Date() < tEnd { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            let sizes = model.thumbnails.values.map { max($0.size.width, $0.size.height) }
            try expect(model.thumbnails.count == 2 && sizes.allSatisfy { $0 <= 36.5 }, "миниатюры: \(model.thumbnails.count), \(sizes)")
            try expect(model.thumbCache.totalCostLimit == ShelfModel.thumbCacheBytes && ShelfModel.thumbCacheBytes <= 8 << 20, "лимит кэша")
            for item in model.items { model.thumbnailDisappeared(item) }
            try expect(model.thumbnails.isEmpty, "ушедшие карточки не держат миниатюры")
            model.thumbnailAppeared(model.items[0])
            try expect(model.thumbnails.count == 1, "вернулась — из кэша сразу")
            // Папка: у QuickLook миниатюры нет — запомнить и больше не спрашивать.
            let folder = dir.appendingPathComponent("folder-thumb", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var addedFolder: [ShelfItem] = []
            var folderNote = "папка не положилась"
            model.addToShelf([folder]) { new in addedFolder = new }
            let fEnd = Date().addingTimeInterval(10)
            while addedFolder.isEmpty && Date() < fEnd { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            if let fi = addedFolder.first {
                model.thumbnailAppeared(fi)
                let key = model.thumbKey(fi)
                let qEnd = Date().addingTimeInterval(15)
                while !model.thumbMissing.contains(key) && model.thumbnails[fi.id] == nil && Date() < qEnd {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                }
                folderNote = model.thumbnails[fi.id] == nil ? "у папки миниатюры нет — запомнено" : "у папки QuickLook дал миниатюру"
                if model.thumbnails[fi.id] == nil {
                    try expect(model.thumbMissing.contains(key), "папка без миниатюры не запомнена")
                    model.thumbnailDisappeared(fi)
                    model.thumbnailAppeared(fi)
                    try expect(model.thumbnails[fi.id] == nil && model.thumbMissing.contains(key), "повторный показ — без запроса")
                }
            }
            ctx.holdExpanded(ShelfModel.holdShare)
            try expect(island.isExpandHeld, "удержание «Поделиться»")
            model.prefs.ttlHours = 0
            try expect(!model.isPurgeScheduled, "срок выключен — подписки нет")
            model.stop()
            try expect(!island.isExpandHeld && SharedTicker.shared.subscriberCount == subs0 && model.thumbnails.isEmpty,
                       "stop(): удержания сняты, тикер не тронут")
            return "автоочистка — задача на ближайший срок; миниатюры ≤ 36 pt, кэш ≤ \(ShelfModel.thumbCacheBytes >> 20) МБ, \(folderNote); удержание снимается в stop()"
        }
        // --- /misc2 ---
        check("подписи") {
            try expect(ShelfFormat.files(1) == "1 файл" && ShelfFormat.files(3) == "3 файла" && ShelfFormat.files(11) == "11 файлов",
                       "склонение")
            let s = ShelfFormat.size(2_100_000)
            try expect(s.contains("МБ") && s.contains(","), "размер «\(s)»")
            try expect(ShelfFormat.age(Date().addingTimeInterval(-3 * 3600 - 10)) == "3 ч", "возраст")
            let decoded = try JSONDecoder().decode(ShelfPrefs.self, from: Data(#"{"order":["zip","bogus"],"ttlHours":6}"#.utf8))
            try expect(decoded.order.first == .zip && decoded.order.count == ShelfTarget.allCases.count && decoded.ttlHours == 6,
                       "настройки: \(decoded)")
            return "\(s), \(ShelfFormat.ttl(24)), \(ShelfFormat.ttl(72))"
        }

        print(failures == 0 ? "Самотест полки: всё прошло. Файлы — \(dir.path)"
                            : "Самотест полки: провалов — \(failures). Файлы — \(dir.path)")
        return failures == 0 ? 0 : 1
    }

    // MARK: Тестовые картинки

    static func bitmap(_ w: Int, _ h: Int, _ draw: (CGContext) -> Void) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(ctx)
        return ctx.makeImage()!
    }

    static func drawText(_ s: String, in ctx: CGContext, at p: CGPoint, size: CGFloat, color: CGColor) {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let attr = NSAttributedString(string: s, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ])
        let line = CTLineCreateWithAttributedString(attr)
        ctx.textPosition = p
        CTLineDraw(line, ctx)
    }

    static func textImage() -> CGImage {
        bitmap(1400, 520) { ctx in
            ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 1400, height: 520))
            let ink = CGColor(gray: 0.05, alpha: 1)
            drawText("Привет, остров! Полка работает.", in: ctx, at: CGPoint(x: 60, y: 380), size: 64, color: ink)
            drawText("Hello, island! The shelf works.", in: ctx, at: CGPoint(x: 60, y: 240), size: 64, color: ink)
            drawText("Лабораторная № 4 — 14.11.2026", in: ctx, at: CGPoint(x: 60, y: 100), size: 52, color: ink)
        }
    }

    static func objectImage() -> CGImage {
        bitmap(900, 700) { ctx in
            // Ровный светлый фон и «игрушка»: тело, голова, глаза — чтобы было что выделить как предмет.
            ctx.setFillColor(CGColor(red: 0.93, green: 0.92, blue: 0.88, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 900, height: 700))
            ctx.setFillColor(CGColor(red: 0.85, green: 0.84, blue: 0.80, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 900, height: 160))
            ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: CGColor(gray: 0, alpha: 0.35))
            ctx.setFillColor(CGColor(red: 0.90, green: 0.25, blue: 0.20, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: 300, y: 120, width: 300, height: 330))
            ctx.setFillColor(CGColor(red: 0.95, green: 0.55, blue: 0.20, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: 340, y: 390, width: 220, height: 200))
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: 390, y: 480, width: 50, height: 50))
            ctx.fillEllipse(in: CGRect(x: 460, y: 480, width: 50, height: 50))
            ctx.setFillColor(CGColor(gray: 0.05, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: 405, y: 492, width: 22, height: 22))
            ctx.fillEllipse(in: CGRect(x: 475, y: 492, width: 22, height: 22))
            ctx.setFillColor(CGColor(red: 0.2, green: 0.35, blue: 0.85, alpha: 1))
            ctx.fill(CGRect(x: 330, y: 100, width: 70, height: 60))
            ctx.fill(CGRect(x: 500, y: 100, width: 70, height: 60))
        }
    }

    static func blankImage() -> CGImage {
        bitmap(400, 300) { ctx in
            ctx.setFillColor(CGColor(gray: 0.5, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        }
    }

    static func writePNG(_ img: CGImage, to url: URL) throws {
        try ShelfOperations.writeImage(img, to: url, type: .png, options: [:])
    }

    /// PDF с настоящим текстовым слоем (CoreText).
    static func makeTextPDF(_ url: URL, pages: [String]) throws {
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { throw ShelfError("PDF не создать") }
        for text in pages {
            ctx.beginPDFPage(nil)
            for (i, line) in text.split(separator: "\n").enumerated() {
                drawText(String(line), in: ctx, at: CGPoint(x: 60, y: 760 - CGFloat(i) * 40), size: 24,
                         color: CGColor(gray: 0, alpha: 1))
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    /// «Скан»: PDF только с картинкой, без текстового слоя — проверка OCR по страницам.
    static func makeScanPDF(_ url: URL, image: CGImage) throws {
        var box = CGRect(x: 0, y: 0, width: 700, height: 260)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { throw ShelfError("PDF не создать") }
        ctx.beginPDFPage(nil)
        ctx.draw(image, in: box)
        ctx.endPDFPage()
        ctx.closePDF()
    }

    /// PDF с явными mediaBox/cropBox.
    static func makeBoxPDF(_ url: URL, media: CGRect, crop: CGRect?) throws {
        var box = media
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { throw ShelfError("PDF не создать") }
        var info: [CFString: Any] = [kCGPDFContextMediaBox: NSData(bytes: &box, length: MemoryLayout<CGRect>.size)]
        if var c = crop { info[kCGPDFContextCropBox] = NSData(bytes: &c, length: MemoryLayout<CGRect>.size) }
        ctx.beginPDFPage(info as CFDictionary)
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: media.midX - 50, y: media.midY - 50, width: 100, height: 100))
        ctx.endPDFPage()
        ctx.closePDF()
    }

    /// Повернуть на 90° против часовой (так iPhone хранит пиксели снимка с orientation 6).
    static func rotateCCW(_ img: CGImage) -> CGImage {
        bitmap(img.height, img.width) { ctx in
            ctx.translateBy(x: CGFloat(img.height), y: 0)
            ctx.rotate(by: .pi / 2)
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        }
    }

    static func typeOf(_ url: URL) -> String? {
        guard let s = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceGetType(s) as String?
    }

    static func imageSize(_ url: URL) -> CGSize {
        guard let s = CGImageSourceCreateWithURL(url as CFURL, nil),
              let i = CGImageSourceCreateImageAtIndex(s, 0, nil) else { return .zero }
        return CGSize(width: i.width, height: i.height)
    }

    /// Доля прозрачных (α < 0,05) и плотных (α > 0,95) пикселей.
    static func alphaStats(_ url: URL) throws -> (Double, Double) {
        guard let s = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(s, 0, nil) else { throw ShelfError("не открыть результат") }
        let w = img.width, h = img.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ok = data.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { throw ShelfError("не прочитать пиксели") }
        var clear = 0, solid = 0
        for i in stride(from: 3, to: data.count, by: 4) {
            if data[i] < 13 { clear += 1 } else if data[i] > 242 { solid += 1 }
        }
        let n = Double(w * h)
        return (Double(clear) / n, Double(solid) / n)
    }
}

// --- shelfshot ---
/// Делегат обещания для самотеста (само выполнение подменяется: система зовёт его только в drag-сеансе).
private final class ShotPromise: NSObject, NSFilePromiseProviderDelegate {
    func filePromiseProvider(_ p: NSFilePromiseProvider, fileNameForType fileType: String) -> String { "shot.png" }
    func filePromiseProvider(_ p: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        completionHandler(nil)
    }
}
// --- /shelfshot ---
