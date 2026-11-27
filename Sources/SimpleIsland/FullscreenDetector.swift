import AppKit
import CoreGraphics
import os

/// «Прятать в полноэкранном»: занят ли экран полноэкранным окном (видео в Safari/Chrome/YouTube, QuickTime, IINA,
/// игра). Чистая логика над снимком `CGWindowListCopyWindowInfo` — её проверяет `--selftest-core fullscreen`.
///
/// Правило (15.11.2026, жалоба «остров не должен отображаться в полноэкранном режиме при просмотре любого видео»):
/// окно обычного слоя (0) **любого** приложения (не нашего), видимое (альфа > 0), по ширине и нижнему краю равно
/// экрану, а верх
/// * у самого края экрана (игра, «окно на весь экран» поверх строки меню), или
/// * выше, чем может встать обычное окно: обычное окно не заходит под строку меню (на 16" с вырезом строка 37 pt,
///   окно начинается с y = 37–38), полноэкранное — сразу под вырезом (y = 32) или с нуля; порог — `safeTop + 3`
///   (без выреза — 22 pt при строке 24–25), или
/// * строки меню на этом экране нет (окно «Menubar» у Window Server, слой 24, не пересекает экран) — запасной
///   признак, если macOS поставит полноэкранное окно ниже.
/// Слой 20 у Dock и слой 24 у «Снимка экрана» — тоже окна на весь экран (измерено 15.11), поэтому только слой 0.
/// Не только переднее приложение: видео на весь экран на втором мониторе прячет остров того монитора.
enum FullscreenDetector {
    struct Window: Equatable {
        var id: CGWindowID
        var pid: pid_t
        var owner: String
        var name: String?
        var layer: Int
        /// Координаты CG: начало — левый верхний угол основного экрана, y вниз.
        var frame: CGRect
        var alpha: Double
    }

    static let menuLayer = Int(CGWindowLevelForKey(.mainMenuWindow))   // 24

    static func parse(_ list: [[String: Any]]) -> [Window] {
        list.compactMap { d in
            guard let id = (d[kCGWindowNumber as String] as? Int).flatMap({ CGWindowID(exactly: $0) }), let pid = d[kCGWindowOwnerPID as String] as? Int,
                  let layer = d[kCGWindowLayer as String] as? Int,
                  let b = d[kCGWindowBounds as String] as? [String: Any] else { return nil }
            func num(_ k: String) -> CGFloat {
                if let v = b[k] as? CGFloat { return v }
                if let v = b[k] as? Double { return CGFloat(v) }
                if let v = b[k] as? Int { return CGFloat(v) }
                return 0
            }
            return Window(id: id, pid: pid_t(pid), owner: d[kCGWindowOwnerName as String] as? String ?? "",
                          name: d[kCGWindowName as String] as? String, layer: layer,
                          frame: CGRect(x: num("X"), y: num("Y"), width: num("Width"), height: num("Height")),
                          alpha: (d[kCGWindowAlpha as String] as? Double) ?? 1)
        }
    }

    /// Видна ли строка меню на экране `screen` (CG): окно Window Server слоя 24 пересекает его верхнюю полосу.
    static func menuBarVisible(screen: CGRect, windows: [Window]) -> Bool {
        windows.contains { w in
            w.layer == menuLayer && w.owner == "Window Server" && w.frame.height > 0
                && w.frame.intersects(CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: 4))
        }
    }

    /// Номер полноэкранного окна на экране `screen` (CG) или nil. `safeTop` — высота выреза (0 — нет).
    static func coveringWindow(screen: CGRect, safeTop: CGFloat, windows: [Window], ownPID: pid_t) -> CGWindowID? {
        let menuBar = menuBarVisible(screen: screen, windows: windows)
        let band = max(safeTop + 3, 22)
        for w in windows where w.layer == 0 && w.pid != ownPID && w.alpha > 0.05 {
            let r = w.frame
            guard abs(r.minX - screen.minX) < 2, abs(r.width - screen.width) < 2, abs(r.maxY - screen.maxY) < 2 else {
                continue
            }
            let gap = r.minY - screen.minY
            if gap < 1 { return w.id }                                    // ровно весь экран
            if gap < band { return w.id }                                 // выше, чем встаёт обычное окно
            if !menuBar && gap <= max(safeTop + 5, 25) + 2 { return w.id } // строки меню нет — окно на её месте
        }
        return nil
    }

    /// Рамка экрана AppKit → CG.
    static func cgFrame(of screenFrame: CGRect) -> CGRect {
        let mainHeight = NSScreen.screens.first?.frame.height ?? screenFrame.height
        return CGRect(x: screenFrame.minX, y: mainHeight - screenFrame.maxY, width: screenFrame.width,
                      height: screenFrame.height)
    }

    /// Живой снимок окон (только на экране, без рабочего стола). Дёшево (~1–3 мс), зовётся по событиям.
    static func liveWindows() -> [Window] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return parse(list)
    }

    /// Карточка «нужен ответ» (разрешение агента и т. п.): без срока и с кнопками. Её по настройке показываем и в
    /// полноэкранном.
    static func isCritical(duration: TimeInterval?, actionCount: Int) -> Bool { duration == nil && actionCount > 0 }

    /// Когда перепроверять после события (смена стола/приложения/экранов): анимация входа в полноэкранный режим
    /// длится ~0,7–1 с, окно встаёт на место не сразу. Прежде проверка была одна, через 0,4 с, и попадала в середину
    /// анимации — остров оставался.
    ///
    /// 15.11 (ночь): серия доходит до 5 с, а после неё до `pollWindow` секунд идёт проверка раз в 1 с через
    /// SharedTicker — только после события, не вечный опрос.
    static let recheckDelays: [TimeInterval] = [0.3, 0.9, 1.8, 3.2, 5.0]
    /// Сколько секунд после события (смена стола/приложения) перепроверять раз в секунду.
    static let pollWindow: TimeInterval = 8

    // MARK: Решение (тип стола + окна)

    /// Почему остров прячется.
    enum Reason: String {
        case none = "нет"
        /// Текущий стол экрана — полноэкранный (тип 4 у SkyLight): Chrome/Safari/плеер в «полный экран».
        case fullscreenSpace = "полноэкранный стол"
        /// Окно на весь экран на обычном столе (игра, «окно поверх строки меню»).
        case coveringWindow = "окно на весь экран"
    }

    /// Решение для одного экрана. `spaceType` — тип текущего стола экрана (`SpaceProbe`), nil — неизвестен.
    ///
    /// Почему не только окна (15.11, живой лог: «полноэкранный — экраны 1», через 0,63 с — «нет»): в конце входа
    /// Chrome в полный экран на 16" его окно стоит в `0, 37, 1728×1080`, а окно строки меню Window Server остаётся
    /// в списке «на экране» (строка спрятана, но окно есть). Ровно такую же рамку даёт обычное развёрнутое окно при
    /// скрытом Dock — по рамкам их не различить. Различает тип стола: у полноэкранного он 4.
    static func decide(screen: CGRect, safeTop: CGFloat, windows: [Window], ownPID: pid_t,
                       spaceType: Int?) -> (window: CGWindowID?, reason: Reason) {
        if spaceType == SpaceProbe.fullscreenType {
            // Номер окна — для журнала; если окно ещё в анимации — 0.
            let w = windows.first { $0.layer == 0 && $0.pid != ownPID && $0.alpha > 0.05
                && abs($0.frame.width - screen.width) < 2 && abs($0.frame.maxY - screen.maxY) < 2
                && $0.frame.minX >= screen.minX - 2 && $0.frame.minX <= screen.minX + 2 }
            return (w?.id ?? 0, .fullscreenSpace)
        }
        if let id = coveringWindow(screen: screen, safeTop: safeTop, windows: windows, ownPID: ownPID) {
            return (id, .coveringWindow)
        }
        return (nil, .none)
    }

    /// Журнал решений: `log show --predicate 'subsystem == "local.simpleisland" AND category == "fullscreen"'`
    /// (в zsh — `/usr/bin/log`: `log` там встроенная команда оболочки и молча ничего не показывает).
    static let log = Logger(subsystem: "local.simpleisland", category: "fullscreen")

    /// Кратко об окнах слоя 0 на всю ширину экрана — для журнала.
    static func describeCandidates(screen: CGRect, windows: [Window], ownPID: pid_t) -> String {
        let c = windows.filter { $0.layer == 0 && $0.pid != ownPID && abs($0.frame.width - screen.width) < 2 }
        guard !c.isEmpty else { return "окон на ширину экрана нет" }
        return c.prefix(4).map { w in
            "\(w.owner) y=\(Int(w.frame.minY)) h=\(Int(w.frame.height)) a=\(String(format: "%.2f", w.alpha))"
        }.joined(separator: "; ")
    }

    /// Есть ли у приложения `pid` окно слоя 0 на всю ширину экрана (кандидат в полноэкранное) — пока есть,
    /// после события стоит перепроверять.
    static func hasScreenWideWindow(pid: pid_t, screens: [CGRect], windows: [Window]) -> Bool {
        windows.contains { w in
            w.pid == pid && w.layer == 0 && w.alpha > 0.05
                && screens.contains { abs(w.frame.width - $0.width) < 2 && abs(w.frame.maxY - $0.maxY) < 40 }
        }
    }
}

/// Тип текущего стола (Space) каждого экрана — частный SkyLight (`SLSCopyManagedDisplaySpaces`), найденный через
/// `dlsym`: нет функции — nil, детектор работает по окнам, как раньше. Только чтение. Измерено 15.11: обычный стол —
/// тип 0, полноэкранный (Chrome) — 4; у экрана «Display Identifier» — UUID, при общих столах на все мониторы — «Main».
enum SpaceProbe {
    static let fullscreenType = 4

    private typealias ConnFn = @convention(c) () -> Int32
    private typealias CopyFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private static let fns: (ConnFn, CopyFn)? = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let c = dlsym(h, "SLSMainConnectionID"), let f = dlsym(h, "SLSCopyManagedDisplaySpaces") else { return nil }
        return (unsafeBitCast(c, to: ConnFn.self), unsafeBitCast(f, to: CopyFn.self))
    }()

    static var isAvailable: Bool { fns != nil }

    /// Идентификатор экрана (UUID заглавными) → тип текущего стола. nil — API недоступно.
    static func currentSpaceTypes() -> [String: Int]? {
        guard let (conn, copy) = fns, let arr = copy(conn())?.takeRetainedValue() as? [[String: Any]] else { return nil }
        return parse(arr)
    }

    /// Разбор ответа `SLSCopyManagedDisplaySpaces` (вынесен для самотеста).
    static func parse(_ arr: [[String: Any]]) -> [String: Int] {
        var out: [String: Int] = [:]
        for d in arr {
            guard let id = d["Display Identifier"] as? String,
                  let cur = d["Current Space"] as? [String: Any] else { continue }
            out[id.uppercased()] = (cur["type"] as? Int) ?? (cur["type"] as? NSNumber)?.intValue ?? 0
        }
        return out
    }

    /// Тип стола экрана `displayID`: по UUID, иначе «Main» (общие столы), иначе единственный.
    static func spaceType(for uuid: String?, in types: [String: Int]) -> Int? {
        if let uuid, let t = types[uuid.uppercased()] { return t }
        if let t = types["MAIN"] { return t }
        return types.count == 1 ? types.values.first : nil
    }

    static func uuid(of displayID: CGDirectDisplayID) -> String? {
        guard let u = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
        return (CFUUIDCreateString(nil, u) as String?)?.uppercased()
    }
}
