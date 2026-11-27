import AppKit
import IslandCore
import SwiftUI

// Мок-данные и снимки модуля «Строка меню». Значки — SF Symbols (свои рисунки, без чужих логотипов), имена — как
// в строке меню пользователя на макете 12. Систему не трогают.

enum MenuBarMocks {
    struct Spec { var key: String; var name: String; var symbol: String; var kind: MenuBarItemKind; var width: CGFloat }

    /// Строка меню как на макете 12 (справа налево): часы, Пункт управления, Spotlight, Wi-Fi, батарея, раскладка,
    /// Ollama, звук, Claude, Vafa; под вырезом — Docker, Облако, Скриншоты.
    static let bar: [Spec] = [
        Spec(key: "cc|Clock", name: "Часы", symbol: "clock", kind: .controlCenter(module: "Clock"), width: 132),
        Spec(key: "cc|BentoBox", name: "Пункт управления", symbol: "switch.2", kind: .controlCenter(module: "BentoBox"), width: 32),
        Spec(key: "spotlight|0", name: "Spotlight", symbol: "magnifyingglass", kind: .system("Spotlight"), width: 30),
        Spec(key: "cc|WiFi", name: "Wi-Fi", symbol: "wifi", kind: .controlCenter(module: "WiFi"), width: 32),
        Spec(key: "cc|Battery", name: "Батарея", symbol: "battery.75percent", kind: .controlCenter(module: "Battery"), width: 34),
        Spec(key: "input|0", name: "Раскладка", symbol: "keyboard", kind: .system("TextInput"), width: 34),
        Spec(key: "ollama|0", name: "Ollama", symbol: "pawprint.fill", kind: .app, width: 30),
        Spec(key: "cc|Sound", name: "Звук", symbol: "speaker.wave.2.fill", kind: .controlCenter(module: "Sound"), width: 32),
        Spec(key: "claude|0", name: "Claude", symbol: "asterisk", kind: .app, width: 30),
        Spec(key: "vafa|0", name: "Vafa", symbol: "lock.shield", kind: .app, width: 30),
    ]
    static let notch: [Spec] = [
        Spec(key: "docker|0", name: "Docker", symbol: "shippingbox", kind: .app, width: 30),
        Spec(key: "cloud|0", name: "Облако", symbol: "cloud", kind: .app, width: 30),
        Spec(key: "shots|0", name: "Скриншоты", symbol: "camera.viewfinder", kind: .app, width: 30),
    ]

    static func item(_ s: Spec, x: CGFloat, section: MenuBarSection, id: CGWindowID) -> MenuBarItem {
        MenuBarItem(windowID: id, pid: 0, ownerName: s.name, bundleId: nil, windowName: nil,
                    frame: CGRect(x: x, y: 0, width: s.width, height: 38), onScreen: section == .visible, kind: s.kind,
                    key: s.key, displayName: s.name, axTitle: nil, section: section)
    }

    /// Строка до уборки на холсте шириной `width` (правый край — часы).
    static func barInventory(width: CGFloat) -> MenuBarInventory {
        var x = width - 6
        var items: [MenuBarItem] = []
        var id: CGWindowID = 100
        for s in bar {
            x -= s.width + 3
            items.append(item(s, x: x, section: .visible, id: id)); id += 1
        }
        var nx: CGFloat = 330
        for s in notch {
            items.append(item(s, x: nx, section: .notch, id: id)); id += 1; nx += s.width
        }
        return MenuBarInventory(items: items, dividerFrame: nil, ghosts: 0)
    }

    /// Вкладка: в острове Ollama, Claude, Vafa, Звук, под вырезом — Docker, Облако, Скриншоты.
    static func islandInventory() -> MenuBarInventory {
        var items: [MenuBarItem] = []
        var id: CGWindowID = 200
        let island = ["ollama|0", "claude|0", "vafa|0", "cc|Sound"]
        for s in bar where !island.contains(s.key) {
            items.append(item(s, x: 900, section: .visible, id: id)); id += 1
        }
        for k in island { if let s = bar.first(where: { $0.key == k }) { items.append(item(s, x: -9000, section: .island, id: id)); id += 1 } }
        for s in notch { items.append(item(s, x: 400, section: .notch, id: id)); id += 1 }
        return MenuBarInventory(items: items, dividerFrame: CGRect(x: -8000, y: 0, width: 10000, height: 38), ghosts: 0)
    }

    /// Для снимка раздела настроек: строка с назначениями (в острове 4, спрятано 2 незапущенных).
    @MainActor static let settingsModel: MenuBarModel = {
        let m = MenuBarModel()
        m.mockSymbols = symbols()
        m.axGranted = true
        m.inventory = islandInventory()
        var p = MenuBarPrefs()
        for k in ["ollama|0", "claude|0", "vafa|0", "cc|Sound"] { p.placements[k] = .island }
        p.placements["telegram|0"] = .hidden; p.names["telegram|0"] = "Telegram"
        p.placements["istat|cpu"] = .hidden; p.names["istat|cpu"] = "iStat Menus"
        m.prefs = p
        return m
    }()

    @MainActor static func symbols() -> [String: String] {
        Dictionary(uniqueKeysWithValues: (bar + notch).map { ($0.key, $0.symbol) })
    }

    @MainActor static func apply(to model: MenuBarModel, ctx: ModuleContext, axGranted: Bool, empty: Bool = false,
                                 beforeCleanup: Bool = false) {
        model.mockSymbols = symbols()
        model.axGranted = axGranted
        if empty {
            model.inventory = MenuBarInventory(items: [], dividerFrame: nil, ghosts: 0)
        } else if beforeCleanup {
            model.inventory = barInventory(width: 1000)
        } else {
            model.inventory = islandInventory()
            var p = MenuBarPrefs()
            for k in ["ollama|0", "claude|0", "vafa|0", "cc|Sound"] { p.placements[k] = .island }
            p.placements["telegram|0"] = .hidden
            p.placements["istat|cpu"] = .hidden
            model.prefs = p
        }
    }
}

/// Снимки оверлея уборки и карточек: `<тема>-mod-menubar-scene-<имя>.png` (холст 1500×560, как сцены макета 12).
@MainActor
public enum MenuBarSnapshots {
    public static func render(outDir: URL, theme: Theme) -> Int {
        let size = CGSize(width: 1500, height: 560)
        let scenes: [(String, (MenuBarModel) -> Void)] = [
            ("cleanup-hover", { m in m.cleanup.hoveredKey = "ollama|0" }),
            ("confirm", { m in CleanupKeys.click("ollama|0", state: &m.cleanup) }),
            ("confirm-system", { m in CleanupKeys.click("cc|WiFi", state: &m.cleanup) }),
            ("confirm-quit", { m in CleanupKeys.click("ollama|0", state: &m.cleanup); m.cleanup.optionIndex = 2
                m.cleanup.confirmingQuit = true }),
            ("confirm-noaccess", { m in m.axGranted = false; CleanupKeys.click("ollama|0", state: &m.cleanup) }),
            ("confirm-notch", { m in CleanupKeys.click("docker|0", state: &m.cleanup) }),
            ("confirm-clock", { m in CleanupKeys.click("cc|Clock", state: &m.cleanup) }),
        ]
        var n = 0
        for (name, setup) in scenes {
            let m = MenuBarModel()
            m.mockSymbols = MenuBarMocks.symbols()
            m.axGranted = true
            m.inventory = MenuBarMocks.barInventory(width: size.width)
            setup(m)
            let notch = CGRect(x: (size.width - 186) / 2, y: 0, width: 186, height: 38)
            let view = MenuBarScene(model: m, size: size, notch: notch)
                .environment(\.islandTheme, theme)
                .environment(\.isSnapshot, true)
            let r = ImageRenderer(content: view)
            r.scale = 2
            let url = outDir.appendingPathComponent("\(theme.id)-mod-menubar-scene-\(name).png")
            guard let cg = r.cgImage, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]),
                  (try? png.write(to: url)) != nil else {
                fputs("SimpleIsland: не отрисован \(url.lastPathComponent)\n", stderr); continue
            }
            n += 1
        }
        return n
    }
}

/// Кусок рабочего стола: фон, строка меню с мок-значками, вырез, остров в режиме уборки и сам оверлей.
struct MenuBarScene: View {
    @ObservedObject var model: MenuBarModel
    var size: CGSize
    var notch: CGRect
    @Environment(\.islandTheme) private var theme

    var body: some View {
        let menuH: CGFloat = 38
        ZStack(alignment: .topLeading) {
            Color(hex: "#0B0A1F")
            RadialGradient(colors: [Color(hex: "#FF6A3D"), .clear], center: UnitPoint(x: 0.18, y: 1.2), startRadius: 0, endRadius: 420)
            RadialGradient(colors: [Color(hex: "#C2187A"), .clear], center: UnitPoint(x: 0.82, y: 1.1), startRadius: 0, endRadius: 420)
            RadialGradient(colors: [Color(hex: "#3B1D8F"), .clear], center: UnitPoint(x: 0.6, y: 0.3), startRadius: 0, endRadius: 520)
            // Строка меню: слева меню приложения, справа значки.
            HStack(spacing: 18) {
                Image(systemName: "apple.logo").font(.system(size: 14, weight: .semibold))
                Text("Finder").font(.system(size: 13, weight: .bold))
                Text("Файл"); Text("Правка"); Text("Вид")
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .padding(.leading, 20)
            .frame(height: menuH)
            ForEach(model.inventory.visible) { item in
                Group {
                    if case .controlCenter(let m) = item.kind, m == "Clock" {
                        Text("Сб 14 нояб. 16:05").font(.system(size: 13, weight: .medium)).monospacedDigit()
                    } else if case .system(let s) = item.kind, s == "TextInput" {
                        Text("РУ").font(.system(size: 10.5, weight: .bold))
                            .padding(.horizontal, 3)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.white, lineWidth: 1.4))
                    } else {
                        Image(systemName: model.mockSymbols[item.key] ?? "circle").font(.system(size: 14, weight: .medium))
                    }
                }
                .foregroundStyle(.white)
                .position(x: item.frame.midX, y: menuH / 2)
            }
            UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10)
                .fill(Color.black)
                .frame(width: notch.width, height: notch.height)
                .position(x: notch.midX, y: notch.midY)
            CleanupOverlayView(model: model, size: size, menuBarHeight: menuH, notch: notch)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }
}
