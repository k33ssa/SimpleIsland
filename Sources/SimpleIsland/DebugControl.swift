import AppKit
import SwiftUI
import IslandCore
import Security

/// Отладочное управление живым приложением — для замеров (`scripts/perf.sh`) и живых снимков экрана.
/// Работает **только** при `SIMPLEISLAND_DEBUG=1` в окружении запуска; без него наблюдатель не ставится и в
/// процессе ничего не происходит. Команды приходят распределённым уведомлением `local.simpleisland.debug`
/// (объект — «<токен> <команда>»); отправить — тем же бинарником: `SimpleIsland --debug-send "expand media"`.
///
/// Защита (ревью 14.11: уведомление может послать любой процесс сессии, в том числе из песочницы):
/// * токен — при старте приложение кладёт случайный токен в `<каталог>/.simpleisland-debug-token` (права 0600);
///   команды без него молча игнорируются; `--debug-send` берёт токен из того же файла сам;
/// * файлы (`dump`, `shot`) пишутся только внутрь каталога отладки: `SIMPLEISLAND_DEBUG_DIR`, по умолчанию —
///   каталог, где лежит `SimpleIsland.app` (dist/ своей копии), для голого бинарника — его каталог; путь вне каталога
///   или с `..` отвергается, запись — атомарная (символьная ссылка на месте файла заменяется, а не открывается).
///
/// Команды:
///   expand [вкладка] · collapse · progress <0…1|off> · hover on|off · clear
///   state <состояние ядра из снимков: idle, compact, two-activities, hud-volume, notification, …>
///   mod <модуль> <снимок модуля>   (мок-данные модуля, напр. `mod agents sessions` — сокет и ~/.claude не трогает)
///   theme <id> · tab <id> on|off
///   settings [layout|themes|gestures|visibility|integrations|displays|about|<модуль>] · onboarding · catalog · close
///   dump <путь>   (JSON: состояние, геометрия выреза и острова, окна, курсор)
///   shot <путь> [top|window]   снимок экрана изнутри процесса: свои окна поверх обоев (чужих окон и строки меню
///                 процесс без права «Запись экрана» не видит — права не просим). top — верх экрана по центру
///                 900×560 pt с вырезом (чёрная плашка по геометрии выреза), window — рамка верхнего не-острова окна
@MainActor
final class DebugControl: NSObject {
    static let shared = DebugControl()
    nonisolated static let notificationName = Notification.Name("local.simpleisland.debug")
    nonisolated static var isEnabled: Bool { ProcessInfo.processInfo.environment["SIMPLEISLAND_DEBUG"] == "1" }

    private var env: AppEnvironment?
    private var controller: () -> IslandController? = { nil }

    private var token: String?

    /// Каталог отладки: сюда токен и все файлы `dump`/`shot`.
    nonisolated static var directory: URL {
        if let d = ProcessInfo.processInfo.environment["SIMPLEISLAND_DEBUG_DIR"], !d.isEmpty {
            return URL(fileURLWithPath: d).standardizedFileURL.resolvingSymlinksInPath()
        }
        let b = Bundle.main.bundleURL
        return (b.pathExtension == "app" ? b.deletingLastPathComponent() : b).standardizedFileURL.resolvingSymlinksInPath()
    }
    nonisolated static var tokenFile: URL { directory.appendingPathComponent(".simpleisland-debug-token") }

    /// Отправитель (`--debug-send <команда>`): токен — из файла каталога отладки; уведомление уходит сразу, даже
    /// если приложение «неактивно».
    nonisolated static func send(_ command: String) -> Int32 {
        guard let t = try? String(contentsOf: tokenFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              !t.isEmpty else {
            FileHandle.standardError.write("нет токена отладки в \(tokenFile.path) — приложение запущено с SIMPLEISLAND_DEBUG=1 и тем же SIMPLEISLAND_DEBUG_DIR?\n".data(using: .utf8)!)
            return 1
        }
        DistributedNotificationCenter.default().postNotificationName(notificationName, object: t + " " + command,
                                                                     userInfo: nil, deliverImmediately: true)
        return 0
    }

    /// Случайный токен в файл 0600 (без следования по символьной ссылке).
    private static func writeToken() -> String? {
        var bytes = [UInt8](repeating: 0, count: 24)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        let t = bytes.map { String(format: "%02x", $0) }.joined()
        let path = tokenFile.path
        unlink(path)
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        fchmod(fd, 0o600)
        let data = Array((t + "\n").utf8)
        guard Darwin.write(fd, data, data.count) == data.count else { return nil }
        return t
    }

    /// Путь для записи — только внутри каталога отладки, без `..`; nil — отвергнут.
    private func safeURL(_ raw: String) -> URL? {
        let u = URL(fileURLWithPath: raw)
        guard !u.pathComponents.contains(".."), u.lastPathComponent != ".simpleisland-debug-token" else { return nil }
        let parent = u.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
        let root = Self.directory.path
        guard parent == root || parent.hasPrefix(root + "/") else { return nil }
        return URL(fileURLWithPath: parent).appendingPathComponent(u.lastPathComponent)
    }

    func stop() {
        guard token != nil else { return }
        unlink(Self.tokenFile.path)
        token = nil
    }

    func start(env: AppEnvironment, controller: @escaping () -> IslandController?) {
        guard Self.isEnabled else { return }
        guard let t = Self.writeToken() else {
            NSLog("SimpleIsland: отладка — не записать токен в %@, управление выключено", Self.tokenFile.path)
            return
        }
        token = t
        self.env = env
        self.controller = controller
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(received(_:)),
                                                            name: Self.notificationName, object: nil,
                                                            suspensionBehavior: .deliverImmediately)
        NSLog("SimpleIsland: отладочное управление включено (SIMPLEISLAND_DEBUG=1), каталог %@", Self.directory.path)
    }

    @objc private nonisolated func received(_ n: Notification) {
        guard let message = n.object as? String else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let t = self.token, let sp = message.firstIndex(of: " "),
                      Self.equal(String(message[..<sp]), t) else { return }   // без токена — тишина
                self.run(String(message[message.index(after: sp)...]))
            }
        }
    }

    /// Сравнение без раннего выхода (время не выдаёт совпавший префикс).
    private static func equal(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var d: UInt8 = 0
        for i in x.indices { d |= x[i] ^ y[i] }
        return d == 0
    }

    private func run(_ command: String) {
        guard let env, let c = controller() else { return }
        let model = c.model
        let parts = command.split(separator: " ", maxSplits: 2).map(String.init)
        guard let verb = parts.first else { return }
        let arg = parts.count > 1 ? parts[1] : nil
        switch verb {
        case "expand": model.expand(tab: arg)
        case "collapse": model.collapse()
        case "progress":   // форма интерактивного свайпа на прогрессе 0…1 (из текущего состояния); off — снять
            model.previewSwipe(arg.flatMap(Double.init).map { CGFloat($0) })
        case "hover": model.hovering = arg != "off"
        case "clear":
            model.collapse()
            env.hud.dismiss()
            while env.notifications.current != nil { env.notifications.dismiss() }
            for id in ["media.now", "today.timer", "shelf.download"] { env.activities.remove(id: id) }
            for m in ["agents", "today", "media"] { env.activities.setStatusDot(nil, for: m) }
            env.activities.setAmbientGlow(nil, for: "media")
            env.island.setFileDrag(active: false)
            env.island.setDropTargeted(false)
        case "state":
            guard let arg, let s = SnapshotRunner.coreStates.first(where: { $0.name == arg }) else { return }
            s.apply(env, model)
        case "mod":
            guard let arg, parts.count > 2, let m = env.module(id: arg), let ctx = env.contexts[arg],
                  let snap = m.snapshotStates().first(where: { $0.name == parts[2] }) else { return }
            snap.apply(ctx)
            if snap.presentation == .expanded { model.expand(tab: m.id) }
        case "theme":
            if let arg { env.settings.data.themeId = arg }
        case "tab":
            guard let arg, let i = env.settings.data.tabs.firstIndex(where: { $0.id == arg }) else { return }
            env.settings.data.tabs[i].enabled = parts.count > 2 ? parts[2] != "off" : true
        case "settings":
            let section: SettingsSection? = switch arg ?? "" {
            case "layout": .layout
            case "themes": .themes
            case "gestures": .gestures
            case "visibility": .visibility
            case "integrations": .integrations
            case "displays": .displays
            case "about": .about
            case "": nil
            default: .module(arg ?? "")
            }
            SettingsWindows.shared.showSettings(section: section)
        case "onboarding": SettingsWindows.shared.showOnboarding()
        case "catalog": WidgetCatalogWindow.shared.show(env: env)
        case "close":
            for w in NSApp.windows where w.isVisible && !(w is NotchPanel) { w.close() }
        case "dump":
            guard let arg, let u = safeURL(arg) else { NSLog("SimpleIsland: отладка — путь вне каталога отладки"); return }
            dump(to: u, env: env, controller: c)
        case "shot":
            guard let arg, let u = safeURL(arg) else { NSLog("SimpleIsland: отладка — путь вне каталога отладки"); return }
            shot(to: u, mode: parts.count > 2 ? parts[2] : "top", controller: c)
        default:
            NSLog("SimpleIsland: отладка — неизвестная команда «%@»", command)
        }
    }

    private func shot(to url: URL, mode: String, controller c: IslandController) {
        // «content» — содержимое своего окна (не экран): видно и окно за чужими окнами, права «Запись экрана» не нужно.
        if mode == "content", let w = NSApp.windows.first(where: { $0.isVisible && !($0 is NotchPanel) && $0.frame.width > 200 }),
           let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            return
        }
        guard let screen = c.screen, let mainH = NSScreen.screens.first?.frame.maxY else { return }
        let g = c.model.geometry
        var rect: NSRect
        if mode == "window", let w = NSApp.windows.first(where: { $0.isVisible && !($0 is NotchPanel) && $0.frame.width > 200 }) {
            rect = w.frame.insetBy(dx: -24, dy: -24)
        } else {
            rect = NSRect(x: g.centerX - 450, y: screen.frame.maxY - 560, width: 900, height: 560)   // карточка разрешения агента — до ~540 pt
        }
        rect = rect.intersection(screen.frame)
        // Глобальные координаты CG: начало — верх-лево главного экрана, ось y вниз.
        let cgRect = CGRect(x: rect.minX, y: mainH - rect.maxY, width: rect.width, height: rect.height)
        // CGWindowListCreateImage в Swift-SDK закрыт («используйте ScreenCaptureKit»), а ScreenCaptureKit требует права
        // «Запись экрана» даже для своих окон. Функция в CoreGraphics есть — берём её через dlsym (только отладка).
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"),
              let img = unsafeBitCast(sym, to: CreateImage.self)(cgRect, CGWindowListOption.optionOnScreenOnly.rawValue,
                                                                 kCGNullWindowID,
                                                                 CGWindowImageOption.bestResolution.rawValue)?.takeRetainedValue() else {
            NSLog("SimpleIsland: отладка — снимок не получился"); return
        }
        let scale = CGFloat(img.width) / rect.width
        let rep = NSBitmapImageRep(cgImage: img)
        if mode != "window", g.hasNotch {
            // Физический вырез — чёрная плашка поверх (как его видит глаз); нижние углы скруглены.
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            let notch = NSRect(x: (g.centerX - g.notchWidth / 2 - rect.minX) * scale,
                               y: (rect.height - g.notchHeight) * scale,
                               width: g.notchWidth * scale, height: (g.notchHeight + 12) * scale)
            NSColor.black.setFill()
            NSBezierPath(roundedRect: notch, xRadius: 9 * scale, yRadius: 9 * scale).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        try? rep.representation(using: .png, properties: [:])?.write(to: url, options: .atomic)
    }

    private func dump(to url: URL, env: AppEnvironment, controller c: IslandController) {
        let model = c.model
        let g = model.geometry
        let m = model.currentMetrics
        func rect(_ r: NSRect) -> [Double] { [r.minX, r.minY, r.width, r.height].map { Double($0) } }
        let windows: [[String: Any]] = NSApp.windows.filter(\.isVisible).map {
            ["title": $0.title, "class": String(describing: type(of: $0)), "frame": rect($0.frame)]
        }
        let obj: [String: Any] = [
            "presentation": String(describing: model.presentation),
            "expanded": model.expanded,
            "tab": model.currentTab?.id ?? "",
            "hovering": model.hovering,
            "motion": String(describing: model.motion),
            "theme": env.themes.current.id,
            "geometry": ["notchWidth": g.notchWidth, "notchHeight": g.notchHeight, "hasNotch": g.hasNotch,
                         "centerX": g.centerX, "screenTop": g.screenTop],
            "metrics": ["width": m.width, "height": m.height, "outerWidth": m.outerWidth,
                        "cornerRadius": m.cornerRadius, "earRadius": m.earRadius],
            "islandRect": rect(c.islandRect()),
            "panelFrame": rect(c.panel.frame),
            "panelVisible": c.panel.isVisible,
            "screenFrame": rect(c.screen?.frame ?? .zero),
            "backingScale": Double(c.screen?.backingScaleFactor ?? 0),
            "mouse": [Double(NSEvent.mouseLocation.x), Double(NSEvent.mouseLocation.y)],
            "activities": env.activities.activities.map(\.id),
            // Компакт без срока = «живая» активность (медиа: играет; на паузе у неё срок 90 с).
            "liveActivities": env.activities.activities.filter { $0.expiresAt == nil }.map(\.id),
            "hud": env.hud.current?.kind ?? "",
            "notification": env.notifications.current?.title ?? "",
            "windows": windows,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
