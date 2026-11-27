import AppKit
import ApplicationServices
import CoreGraphics

// Живое чтение строки меню: окна слоя 25 (CGWindowList, права не нужны), владельцы (NSRunningApplication),
// подписи из Универсального доступа (только если право уже есть — здесь его не просим), видимость модулей
// Пункта управления (defaults com.apple.controlcenter — только чтение), вырез основного экрана.
// Ничего не опрашивает само: зовётся по событию (запуск/выход приложения, экраны, открытая вкладка, режим уборки).

enum MenuBarScanner {
    /// Одна последовательная очередь: сканы завершаются в том порядке, в каком начаты (старый не перезапишет новый).
    nonisolated static let queue = DispatchQueue(label: "simpleisland.menubar.scan", qos: .utility)

    /// Разовый снимок. CGWindowList и AX — в фоне (AX у зависшего приложения отвечает до 0,25 с), итог — на главном.
    /// `dividerFrame`/`dividerExpanded` — для macOS 27 (номера окна у разделителя там нет, рамка — из окна кнопки).
    @MainActor
    static func scan(dividerWindowID: CGWindowID?, dividerLength: CGFloat?, dividerFrame: CGRect? = nil,
                     dividerExpanded: Bool = false, completion: @escaping @MainActor (MenuBarInventory) -> Void) {
        let notch = notchRect()
        let screens = cgScreens()
        let own = getpid()
        let axGranted = AXIsProcessTrusted()
        queue.async {
            let inv = read(ownPID: own, dividerWindowID: dividerWindowID, dividerLength: dividerLength,
                           dividerFrame: dividerFrame, dividerExpanded: dividerExpanded, notch: notch, screens: screens,
                           withAX: axGranted)
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(inv) } }
        }
    }

    /// То же синхронно (для переноса: проверить рамки сразу после событий).
    @MainActor static func scanNow(dividerWindowID: CGWindowID?, dividerLength: CGFloat?, dividerFrame: CGRect? = nil,
                                   dividerExpanded: Bool = false) -> MenuBarInventory {
        read(ownPID: getpid(), dividerWindowID: dividerWindowID, dividerLength: dividerLength, dividerFrame: dividerFrame,
             dividerExpanded: dividerExpanded, notch: notchRect(), screens: cgScreens(), withAX: AXIsProcessTrusted())
    }

    /// Выбор источника: macOS 27 — дерево AX MenuBarAgent (без права — пусто, `.agentNoAccess`); старые системы —
    /// окна слоя 25. Если на 27 вдруг снова есть окна значков слоя 25 (откат Apple) — берём их.
    nonisolated static func read(ownPID: pid_t, dividerWindowID: CGWindowID?, dividerLength: CGFloat?,
                                 dividerFrame: CGRect?, dividerExpanded: Bool, notch: CGRect?, screens: [CGRect],
                                 withAX: Bool) -> MenuBarInventory {
        let input = readInput(ownPID: ownPID, dividerWindowID: dividerWindowID, dividerLength: dividerLength,
                              notch: notch, screens: screens, withAX: withAX && !MenuBarAgent.isActive)
        let legacy = MenuBarInventory.parse(input)
        guard MenuBarAgent.isActive, legacy.items.isEmpty else { return legacy }
        guard withAX, let (snap, agentPID) = MenuBarAgent.read() else {
            var inv = MenuBarInventory.empty
            inv.source = .agentNoAccess
            return inv
        }
        var apps: [pid_t: MenuBarAppInfo] = [:]
        for pid in Set(snap.slots.map(\.pid)) {
            let app = NSRunningApplication(processIdentifier: pid)
            apps[pid] = MenuBarAppInfo(bundleId: app?.bundleIdentifier, name: app?.localizedName)
        }
        return MenuBarInventory.parseAgent(MenuBarAgentInput(snapshot: snap, apps: apps, ownPID: ownPID, agentPID: agentPID,
                                                             dividerFrame: dividerFrame, dividerExpanded: dividerExpanded,
                                                             notch: notch))
    }

    nonisolated static func readInput(ownPID: pid_t, dividerWindowID: CGWindowID?, dividerLength: CGFloat?,
                                      notch: CGRect?, screens: [CGRect], withAX: Bool) -> MenuBarScanInput {
        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        let windows = list.compactMap(MenuBarRawWindow.init).filter { $0.layer == MenuBarRawWindow.statusLayer }
        var apps: [pid_t: MenuBarAppInfo] = [:]
        for pid in Set(windows.map(\.pid)) {
            let app = NSRunningApplication(processIdentifier: pid)
            apps[pid] = MenuBarAppInfo(bundleId: app?.bundleIdentifier, name: app?.localizedName)
        }
        let ax = withAX ? axItems(pids: Set(windows.map(\.pid)).subtracting([ownPID])) : []
        return MenuBarScanInput(windows: windows, apps: apps, ownPID: ownPID, dividerWindowID: dividerWindowID,
                                ccVisibility: controlCenterVisibility(), ax: ax, notch: notch, screens: screens,
                                dividerLength: dividerLength)
    }

    /// Экраны в координатах CG (начало — левый верхний угол основного, y вниз), первый — основной.
    @MainActor static func cgScreens() -> [CGRect] {
        guard let main = NSScreen.screens.first else { return [] }
        let h = main.frame.maxY
        return NSScreen.screens.map { CGRect(x: $0.frame.minX, y: h - $0.frame.maxY, width: $0.frame.width, height: $0.frame.height) }
    }

    /// `NSStatusItem Visible <имя>` у Пункта управления — только чтение чужого домена.
    nonisolated static func controlCenterVisibility() -> [String: Bool] {
        guard let d = UserDefaults.standard.persistentDomain(forName: "com.apple.controlcenter") else { return [:] }
        var out: [String: Bool] = [:]
        let prefix = "NSStatusItem Visible "
        for (k, v) in d where k.hasPrefix(prefix) {
            if let n = v as? NSNumber { out[String(k.dropFirst(prefix.count))] = n.boolValue }
        }
        return out
    }

    /// Вырез основного экрана (со строкой меню) в координатах CG; nil — выреза нет.
    @MainActor static func notchRect() -> CGRect? {
        guard let s = NSScreen.screens.first, s.safeAreaInsets.top > 0,
              let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea else { return nil }
        // Основной экран: CG-y сверху = 0.
        return CGRect(x: l.maxX - s.frame.minX, y: 0, width: max(0, r.minX - l.maxX), height: s.safeAreaInsets.top)
    }

    /// Правый край основного экрана в координатах CG.
    @MainActor static var mainScreenMaxX: CGFloat { NSScreen.screens.first.map { $0.frame.maxX } ?? 0 }

    // MARK: Универсальный доступ

    nonisolated static func axElements(pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &bar) == .success, let bar,
              CFGetTypeID(bar) == AXUIElementGetTypeID() else { return [] }
        var kids: CFTypeRef?
        AXUIElementSetMessagingTimeout(bar as! AXUIElement, 0.25)
        guard AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &kids) == .success,
              let arr = kids as? [AXUIElement] else { return [] }
        // Тайм-аут — на каждый элемент: у приложения он на детей не распространяется.
        for el in arr { AXUIElementSetMessagingTimeout(el, 0.25) }
        // macOS 27: у MenuBarAgent значки Пункта управления лежат в AXGroup-хостинге — взять AXMenuBarItem изнутри,
        // индикатор overflow — не значок.
        var out: [AXUIElement] = []
        for el in arr {
            let role = MenuBarAgent.string(el, kAXRoleAttribute)
            if role == "AXMenuBarItem" { out.append(el); continue }
            if role == kAXGroupRole {
                out += MenuBarAgent.children(el).filter { MenuBarAgent.string($0, kAXRoleAttribute) == "AXMenuBarItem" }
            }
        }
        return out
    }

    nonisolated static func axItems(pids: Set<pid_t>) -> [MenuBarAXInfo] {
        var out: [MenuBarAXInfo] = []
        for pid in pids {
            for el in axElements(pid: pid) {
                guard let f = axFrame(el) else { continue }
                out.append(MenuBarAXInfo(pid: pid, frame: f, title: axString(el, kAXTitleAttribute),
                                         detail: axString(el, kAXDescriptionAttribute),
                                         identifier: axString(el, kAXIdentifierAttribute)))
            }
        }
        return out
    }

    /// AX-элемент значка с рамкой ближе всего к `frame` (у приложения может быть несколько значков).
    nonisolated static func axElement(pid: pid_t, near frame: CGRect) -> AXUIElement? {
        axElements(pid: pid)
            .compactMap { el in axFrame(el).map { (el, abs($0.midX - frame.midX)) } }
            .min { $0.1 < $1.1 }?.0
    }

    nonisolated static func axString(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }

    nonisolated static func axFrame(_ el: AXUIElement) -> CGRect? {
        var pv: CFTypeRef?, sv: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pv) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sv) == .success,
              let pv, let sv, CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &p)
        AXValueGetValue(sv as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    /// Видимые окна процесса вне слоя строки меню (поповеры MenuBarExtra(.window), панели, обычные окна). Для
    /// временного показа: что появилось после нажатия — открыто значком.
    nonisolated static func openWindows(pid: pid_t) -> Set<CGWindowID> {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        var out: Set<CGWindowID> = []
        for d in list where (d[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid {
            guard (d[kCGWindowLayer as String] as? Int) != MenuBarRawWindow.statusLayer,
                  let n = (d[kCGWindowNumber as String] as? Int).flatMap({ CGWindowID(exactly: $0) }) else { continue }
            out.insert(n)
        }
        return out
    }

    /// Открыто ли сейчас выпадающее меню процесса (окно слоя kCGPopUpMenuWindowLevel на экране).
    nonisolated static func hasOpenMenu(pid: pid_t) -> Bool {
        let menuLayer = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.contains {
            ($0[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid && ($0[kCGWindowLayer as String] as? Int) == menuLayer
        }
    }
}
