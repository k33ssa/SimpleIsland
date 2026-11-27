import AppKit
import ApplicationServices
import CoreGraphics

// macOS 27: значки строки меню рисует системный процесс MenuBarAgent (com.apple.MenuBarAgent). Окон слоя 25 у
// значков больше нет (в CGWindowList — только два окна слоя 24 «MenuBarAgent» во всю ширину), у своего
// NSStatusItem номер окна — заглушка 2^32. Источник правды — дерево Универсального доступа MenuBarAgent
// (измерено 20.11.2026, macOS 27.2.1, docs/MENUBAR.md §10):
// * окна AXDialog 0,0 ширина×33; их дети — «слоты» AXGroup, по одному на значок, рамка = место в строке;
//   внутри слота — элемент владельца (AXButton / AXApplication / AXGroup-хостинг у модулей Пункта управления),
//   pid владельца — `AXUIElementGetPid` этого элемента; у модулей Пункта управления (pid MenuBarAgent) внутри —
//   AXMenuBarItem с AXIdentifier `com.apple.menuextra.<модуль>` и человеческим AXDescription;
// * системный overflow: AXButton `menu-bar-overflow-indicator` (свёрнут, «Показать скрытые элементы строки меню») /
//   `menu-bar-overflow-indicator-expanded` (раскрыт). Скрытые значки стоят ЛЕВЕЕ индикатора: свёрнут — все в одной
//   точке под вырезом, раскрыт — в ряд левее выреза.
// Без Универсального доступа дерево не читается — инвентаря на 27 нет (вкладка говорит это прямо).

/// Слот значка в строке меню по данным MenuBarAgent.
public struct MenuBarAgentSlot: Equatable, Sendable {
    public var pid: pid_t
    /// Рамка в координатах CG (начало — левый верхний угол основного экрана).
    public var frame: CGRect
    public var title: String?
    public var detail: String?
    /// `com.apple.menuextra.wifi` у модулей Пункта управления; у приложений обычно нет.
    public var identifier: String?
    /// Порядок в дереве AX (скрытые в свёрнутом overflow стоят в одной точке — различаем по нему).
    public var order: Int
    public init(pid: pid_t, frame: CGRect, title: String? = nil, detail: String? = nil, identifier: String? = nil,
                order: Int = 0) {
        self.pid = pid; self.frame = frame; self.title = title; self.detail = detail; self.identifier = identifier
        self.order = order
    }
}

/// Снимок строки меню macOS 27.
public struct MenuBarAgentSnapshot: Equatable, Sendable {
    public var slots: [MenuBarAgentSlot]
    /// Кнопка системного overflow (nil — всё помещается, скрытых нет).
    public var indicator: CGRect?
    public var expanded: Bool
    public init(slots: [MenuBarAgentSlot], indicator: CGRect?, expanded: Bool) {
        self.slots = slots; self.indicator = indicator; self.expanded = expanded
    }
}

/// Вход разбора macOS 27.
public struct MenuBarAgentInput: Sendable {
    public var snapshot: MenuBarAgentSnapshot
    public var apps: [pid_t: MenuBarAppInfo]
    public var ownPID: pid_t
    /// pid процесса MenuBarAgent (его слоты — модули Пункта управления).
    public var agentPID: pid_t
    /// Рамка нашего разделителя (CG) из окна его кнопки; nil — разделителя нет.
    public var dividerFrame: CGRect?
    /// Разделитель развёрнут (прячет всё левее себя).
    public var dividerExpanded: Bool
    public var notch: CGRect?
    public init(snapshot: MenuBarAgentSnapshot, apps: [pid_t: MenuBarAppInfo], ownPID: pid_t, agentPID: pid_t,
                dividerFrame: CGRect? = nil, dividerExpanded: Bool = false, notch: CGRect? = nil) {
        self.snapshot = snapshot; self.apps = apps; self.ownPID = ownPID; self.agentPID = agentPID
        self.dividerFrame = dividerFrame; self.dividerExpanded = dividerExpanded; self.notch = notch
    }
}

/// Откуда инвентарь.
public enum MenuBarSource: String, Equatable, Sendable {
    /// macOS 15/26: окна значков слоя 25 (CGWindowList).
    case windows
    /// macOS 27: дерево AX процесса MenuBarAgent.
    case agent
    /// macOS 27 без Универсального доступа: значки не прочитать.
    case agentNoAccess
}

enum MenuBarAgent {
    static let bundleId = "com.apple.MenuBarAgent"
    static let indicatorID = "menu-bar-overflow-indicator"
    static let indicatorExpandedID = "menu-bar-overflow-indicator-expanded"

    /// Модули Пункта управления: суффикс `com.apple.menuextra.<…>` → имя модуля, как в старых ключах
    /// (`NSStatusItem Visible <имя>`), чтобы назначения с 15/26 остались на тех же значках.
    static let moduleBySuffix: [String: String] = [
        "wifi": "WiFi", "battery": "Battery", "clock": "Clock", "controlcenter": "BentoBox", "focusmode": "FocusModes",
        "sound": "Sound", "bluetooth": "Bluetooth", "display": "Display", "airdrop": "AirDrop",
        "nowplaying": "NowPlaying", "screenmirroring": "ScreenMirroring", "stagemanager": "StageManager",
        "audiovideo": "AudioVideoModule", "audiovideomodule": "AudioVideoModule", "keyboardbrightness": "KeyboardBrightness",
        "userswitcher": "UserSwitcher", "accessibility": "Accessibility", "hearing": "Hearing", "timer": "Timer",
        "weather": "Weather", "musicrecognition": "MusicRecognition", "shortcuts": "Shortcuts", "siri": "Siri",
        "spotlight": "Spotlight", "facetime": "FaceTime",
    ]

    static func module(forIdentifier id: String?) -> String? {
        guard let id, id.hasPrefix("com.apple.menuextra.") else { return nil }
        let suffix = String(id.dropFirst("com.apple.menuextra.".count))
        return moduleBySuffix[suffix.lowercased()] ?? suffix
    }

    /// Синтетический «номер окна» значка (у значков на 27 окон нет): устойчив, пока значок у того же процесса на
    /// той же позиции среди его значков. Старший бит 0x4000_0000 — чтобы не совпасть с настоящими окнами.
    static func syntheticID(pid: pid_t, ordinal: Int, identifier: String?) -> CGWindowID {
        if let identifier {
            var h: UInt32 = 2_166_136_261
            for b in identifier.utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
            return 0x6000_0000 | (h & 0x1FFF_FFFF)
        }
        return 0x4000_0000 | ((UInt32(truncatingIfNeeded: pid) & 0x7_FFFF) << 6) | UInt32(min(max(ordinal, 0), 63))
    }

    /// Скрыт системой: стоит левее кнопки overflow. Свёрнутый ряд выровнен по правому краю у кнопки (38-pt значок —
    /// 975…1013, 28-pt — 985…1013 при кнопке 996…1014: середина узкого правее начала кнопки — поэтому по правому
    /// краю), раскрытый — левее выреза. Видимые начинаются правее кнопки (1021).
    static func isHidden(_ f: CGRect, indicator: CGRect?) -> Bool {
        guard let ind = indicator else { return false }
        return f.maxX <= ind.maxX + 1
    }

    /// Раскрыт ли overflow — по геометрии (id копий кнопки бывает устаревшим): скрытые слоты стоят далеко левее
    /// кнопки (ряд левее выреза), а не прижаты к ней. Скрытых нет — по id.
    static func isExpanded(_ slots: [MenuBarAgentSlot], indicator: CGRect?, byID: Bool) -> Bool {
        guard let ind = indicator else { return false }
        let hidden = slots.filter { isHidden($0.frame, indicator: ind) }
        guard !hidden.isEmpty else { return byID }
        return hidden.allSatisfy { $0.frame.maxX < ind.minX - 30 }
    }

    // MARK: Живое чтение (AX, только чтение атрибутов)

    static func agentApp() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleId }
    }

    /// macOS 27+: значки рисует MenuBarAgent. Решение — по версии системы и наличию процесса (на 26 его нет).
    nonisolated static var isActive: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 && agentApp() != nil
    }

    static func attr(_ e: AXUIElement, _ a: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
    }
    static func string(_ e: AXUIElement, _ a: String) -> String? {
        (attr(e, a) as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
    static func children(_ e: AXUIElement) -> [AXUIElement] {
        let kids = (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        for k in kids { AXUIElementSetMessagingTimeout(k, 0.25) }
        return kids
    }

    /// Элементы-корни MenuBarAgent: его AXExtrasMenuBar и окна (у индикатора бывает несколько копий, часть — с
    /// устаревшим состоянием; измерено 20.11).
    static func roots(_ pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var out: [AXUIElement] = []
        if let bar = attr(app, "AXExtrasMenuBar"), CFGetTypeID(bar) == AXUIElementGetTypeID() {
            out.append(bar as! AXUIElement)
        }
        out += (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        for r in out { AXUIElementSetMessagingTimeout(r, 0.25) }
        return out
    }

    /// Прочитать снимок. nil — нет MenuBarAgent или Универсального доступа.
    nonisolated static func read() -> (MenuBarAgentSnapshot, agentPID: pid_t)? {
        guard AXIsProcessTrusted(), let agent = agentApp() else { return nil }
        let pid = agent.processIdentifier
        var perWindow: [[MenuBarAgentSlot]] = []
        var indicator: CGRect?
        var expanded = false
        for root in roots(pid) {
            let isWindow = string(root, kAXRoleAttribute) == kAXWindowRole
            var slots: [MenuBarAgentSlot] = []
            for g in children(root) {
                let role = string(g, kAXRoleAttribute)
                if role == kAXButtonRole, let id = string(g, kAXIdentifierAttribute), id.hasPrefix(indicatorID) {
                    // Копия в AXExtrasMenuBar бывает устаревшей — состояние берём из окна.
                    if indicator == nil || isWindow {
                        indicator = MenuBarScanner.axFrame(g)
                        expanded = id == indicatorExpandedID
                    }
                    continue
                }
                guard isWindow, role == kAXGroupRole, let f = MenuBarScanner.axFrame(g), f.width > 1 else { continue }
                guard let c = children(g).first else { continue }
                var owner: pid_t = 0
                AXUIElementGetPid(c, &owner)
                var slot = MenuBarAgentSlot(pid: owner, frame: f, order: slots.count)
                switch string(c, kAXRoleAttribute) {
                case kAXButtonRole?:
                    slot.title = string(c, kAXTitleAttribute)
                    slot.detail = string(c, kAXDescriptionAttribute) ?? string(c, kAXHelpAttribute)
                    slot.identifier = string(c, kAXIdentifierAttribute)
                case kAXGroupRole?:
                    // Модуль Пункта управления: AXMenuBarItem внутри хостинга.
                    if let item = children(c).first(where: { string($0, kAXRoleAttribute) == "AXMenuBarItem" }) {
                        slot.detail = string(item, kAXDescriptionAttribute)
                        slot.identifier = string(item, kAXIdentifierAttribute)
                        slot.title = (attr(item, kAXValueAttribute) as? String).flatMap { $0.isEmpty ? nil : $0 }
                    }
                default: break   // AXApplication: подписи — из другого окна (там AXButton)
                }
                slots.append(slot)
            }
            if !slots.isEmpty { perWindow.append(slots) }
        }
        let slots = merge(perWindow)
        return (MenuBarAgentSnapshot(slots: slots, indicator: indicator,
                                     expanded: isExpanded(slots, indicator: indicator, byID: expanded)), pid)
    }

    /// Одни и те же места приходят из двух окон (в одном — AXApplication владельца, в другом — AXButton с
    /// подписью). Основа — окно с большим числом слотов; подписи из остальных — один к одному по pid и рамке
    /// (несколько значков процесса в свёрнутом overflow стоят в одной точке — поэтому строго по одному).
    static func merge(_ perWindow: [[MenuBarAgentSlot]]) -> [MenuBarAgentSlot] {
        guard var base = perWindow.max(by: { $0.count < $1.count }) else { return [] }
        let baseIndex = perWindow.firstIndex(of: base)
        for (wi, other) in perWindow.enumerated() where wi != baseIndex {
            var used = Set<Int>()
            for s in other {
                guard let i = base.indices.first(where: { !used.contains($0) && base[$0].pid == s.pid
                                                          && base[$0].frame.integral == s.frame.integral
                                                          && (base[$0].identifier == nil || s.identifier == nil
                                                              || base[$0].identifier == s.identifier) }) else { continue }
                used.insert(i)
                base[i].title = base[i].title ?? s.title
                base[i].detail = base[i].detail ?? s.detail
                base[i].identifier = base[i].identifier ?? s.identifier
            }
        }
        return base
    }

    /// Раскрыть/свернуть системный overflow (AXPress кнопки). Копий кнопки несколько, часть с устаревшим состоянием
    /// (нажатие ничего не делает — измерено 20.11): жмём по очереди и после каждой проверяем по геометрии слотов.
    /// Блокирует до ~3 с — звать не с главного потока. true — overflow в нужном состоянии.
    @discardableResult
    nonisolated static func setOverflow(expanded want: Bool) -> Bool {
        guard AXIsProcessTrusted(), let agent = agentApp() else { return false }
        func state() -> Bool? { read().map { $0.0.indicator == nil ? nil : $0.0.expanded } ?? nil }
        guard let now = state() else { return !want }   // кнопки нет — скрытых нет
        if now == want { return true }
        let preferred = want ? indicatorID : indicatorExpandedID
        var cands: [AXUIElement] = []
        for root in roots(agent.processIdentifier).reversed() {   // окна — первыми
            let ks = children(root).filter { string($0, kAXIdentifierAttribute)?.hasPrefix(indicatorID) == true }
            cands += ks.filter { string($0, kAXIdentifierAttribute) == preferred }
            cands += ks.filter { string($0, kAXIdentifierAttribute) != preferred }
        }
        for el in cands.prefix(4) {
            guard AXUIElementPerformAction(el, kAXPressAction as CFString) == .success else { continue }
            for _ in 0..<6 {
                usleep(250_000)
                if state() == want { return true }
            }
        }
        return state() == want
    }
}

// MARK: - Разбор снимка macOS 27

extension MenuBarInventory {
    /// Инвентарь по снимку MenuBarAgent. Разделы:
    /// * левее кнопки overflow — скрыт системой (она прячет «префикс» строки — всё левее, измерено 20.11): при нашем
    ///   развёрнутом разделителе (что-то спрятано нами) — `.island`, иначе — `.notch` (не поместился);
    /// * остальное — `.visible`.
    /// Наши значки (свой pid, другие экземпляры SimpleIsland) в список не идут; призраков на 27 нет.
    public static func parseAgent(_ input: MenuBarAgentInput) -> MenuBarInventory {
        let snap = input.snapshot
        let ownSlots = snap.slots.filter { $0.pid == input.ownPID }
        // Разделитель «на месте» — его слот виден в строке (не в overflow): тогда он что-то прячет.
        let dividerSlot: MenuBarAgentSlot? = input.dividerFrame.flatMap { d in
            ownSlots.min { abs($0.frame.midX - d.midX) < abs($1.frame.midX - d.midX) }
                .flatMap { abs($0.frame.midX - d.midX) <= max(8, d.width / 2) ? $0 : nil }
        }
        let dividerInBar = dividerSlot.map { !MenuBarAgent.isHidden($0.frame, indicator: snap.indicator) } ?? false
        let foreign = snap.slots.filter { s in
            s.pid != input.ownPID && s.pid > 0
                && !(input.apps[s.pid]?.bundleId.map(ownBundles.contains) ?? false)
                && !(input.apps[s.pid]?.bundleId?.hasPrefix("local.simpleisland") ?? false)
        }
        // Порядковые номера значков одного процесса: справа налево, в одной точке — по порядку в AX.
        var ordinals: [Int: Int] = [:]
        var perPid: [pid_t: Int] = [:]
        for (pid, group) in Dictionary(grouping: foreign.indices, by: { foreign[$0].pid }) {
            perPid[pid] = group.count
            let sorted = group.sorted {
                let a = foreign[$0], b = foreign[$1]
                return a.frame.midX != b.frame.midX ? a.frame.midX > b.frame.midX : a.order < b.order
            }
            for (i, idx) in sorted.enumerated() { ordinals[idx] = i }
        }
        var items: [MenuBarItem] = []
        for (idx, s) in foreign.enumerated() {
            let isCC = s.pid == input.agentPID
            let module = isCC ? MenuBarAgent.module(forIdentifier: s.identifier) : nil
            var app = input.apps[s.pid]
            if isCC { app = MenuBarAppInfo(bundleId: MenuBarNames.controlCenterBundle, name: "Пункт управления") }
            let kind: MenuBarItemKind
            if isCC { kind = .controlCenter(module: module) }
            else if let b = app?.bundleId, let sys = MenuBarNames.systemBundles[b] { kind = .system(sys) }
            else { kind = .app }
            let hidden = MenuBarAgent.isHidden(s.frame, indicator: snap.indicator)
            // Скрытое системой при нашем разделителе — «в острове» (переносом мы кладём значки именно в overflow);
        // без разделителя — «под вырезом» (просто не влезло).
        let section: MenuBarSection = hidden ? (input.dividerExpanded ? .island : .notch) : .visible
            let owner = app?.bundleId ?? app?.name ?? "pid\(s.pid)"
            let ordinal = "#\(ordinals[idx] ?? 0)"
            let label = module ?? (isCC ? nil : cleanTitle(s.identifier))
            let ownerName = isCC ? "Пункт управления" : (app?.name ?? owner)
            let raw = MenuBarRawWindow(windowID: 0, pid: s.pid, ownerName: ownerName, name: module, frame: s.frame,
                                       onScreen: !hidden)
            let ax = MenuBarAXInfo(pid: s.pid, frame: s.frame, title: s.title, detail: s.detail, identifier: s.identifier)
            var name = displayName(raw, kind: kind, app: app, ax: ax)
            if isCC, let d = cleanTitle(s.detail), module.flatMap({ MenuBarNames.ccNames[$0] }) == nil { name = d }
            var it = MenuBarItem(windowID: MenuBarAgent.syntheticID(pid: s.pid, ordinal: ordinals[idx] ?? 0,
                                                                   identifier: isCC ? s.identifier : nil),
                                 pid: s.pid, ownerName: ownerName, bundleId: app?.bundleId, windowName: module,
                                 frame: s.frame, onScreen: !hidden, kind: kind, key: "\(owner)|\(label ?? ordinal)",
                                 displayName: name, axTitle: cleanTitle(isCC ? s.title : (s.title ?? s.detail)),
                                 section: section)
            it.hasStableKey = label != nil || (perPid[s.pid] ?? 0) <= 1
            it.altKeys = [label, ordinal].compactMap { $0 }.map { "\(owner)|\($0)" }
            items.append(it)
        }
        let rank: [MenuBarSection: Int] = [.visible: 0, .notch: 1, .island: 2]
        items.sort { a, b in
            if a.section != b.section { return rank[a.section]! < rank[b.section]! }
            return a.frame.midX != b.frame.midX ? a.frame.midX > b.frame.midX : a.windowID < b.windowID
        }
        var inv = MenuBarInventory(items: items, dividerFrame: dividerInBar ? dividerSlot?.frame : nil, ghosts: 0)
        inv.source = .agent
        inv.overflowIndicator = snap.indicator
        inv.overflowExpanded = snap.expanded
        inv.dividerInOverflow = dividerSlot != nil && !dividerInBar
        return inv
    }
}
