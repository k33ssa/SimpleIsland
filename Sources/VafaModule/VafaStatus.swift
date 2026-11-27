import Foundation

/// Файл статуса Vafa (`vpn-guard` переписывает его атомарно — `tmp` + `mv` — каждый круг, ~1 с).
/// Пример: `{"time":…,"state":"up","vpn":true,"iface":"utun225","country":"DE","on_down":"freeze",
/// "apps":[{"path":"/Applications/Claude.app","locked":false,"procs":28,"frozen":0}],
/// "cli":{"locked":false,"procs":6,"frozen":0}}`. Лишние поля (net, geo, countries…) не мешают, отсутствующие — по умолчанию.
public struct VafaStatus: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable {
        public var path: String
        /// Запуск запрещён (снят +x).
        public var locked: Bool
        public var procs: Int
        public var frozen: Int

        public init(path: String, locked: Bool = false, procs: Int = 0, frozen: Int = 0) {
            self.path = path; self.locked = locked; self.procs = procs; self.frozen = frozen
        }

        enum CodingKeys: String, CodingKey { case path, locked, procs, frozen }
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            path = (try? c.decode(String.self, forKey: .path)) ?? ""
            locked = (try? c.decode(Bool.self, forKey: .locked)) ?? false
            procs = (try? c.decode(Int.self, forKey: .procs)) ?? 0
            frozen = (try? c.decode(Int.self, forKey: .frozen)) ?? 0
        }

        /// Имя для людей: «/Applications/Claude.app» → «Claude».
        public var name: String { VafaStatus.displayName(path) }
        public var isBlocked: Bool { locked || frozen > 0 }
    }

    public var time: Double
    /// up — VPN есть и страна подтверждена; unsure — маршрут есть, страна не подтверждена (или пауза GRACE); down — VPN нет.
    public var state: String
    public var vpn: Bool
    public var iface: String
    public var country: String
    /// Что делать без VPN: freeze (заморозить) и т. п.
    public var onDown: String
    public var apps: [Item]
    /// Claude Code CLI (если Vafa присматривает за ним).
    public var cli: Item?
    /// VPN-клиент в режиме системного прокси (адрес прокси; пусто — нет).
    public var proxy: String = ""
    /// Режим фильтра сети (pf): `hold`/`block` — сеть к сервисам Claude закрыта, `via:utunN`/`open` — открыта.
    public var net: String = ""

    public init(time: Double = Date().timeIntervalSince1970, state: String = "up", vpn: Bool = true,
                iface: String = "utun4", country: String = "", onDown: String = "freeze",
                apps: [Item] = [], cli: Item? = nil) {
        self.time = time; self.state = state; self.vpn = vpn; self.iface = iface; self.country = country
        self.onDown = onDown; self.apps = apps; self.cli = cli
    }

    enum CodingKeys: String, CodingKey { case time, state, vpn, iface, country, onDown = "on_down", apps, cli, proxy, net }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        time = (try? c.decode(Double.self, forKey: .time)) ?? 0
        state = (try? c.decode(String.self, forKey: .state)) ?? "init"
        vpn = (try? c.decode(Bool.self, forKey: .vpn)) ?? false
        iface = (try? c.decode(String.self, forKey: .iface)) ?? ""
        country = (try? c.decode(String.self, forKey: .country)) ?? ""
        onDown = (try? c.decode(String.self, forKey: .onDown)) ?? ""
        apps = (try? c.decode([Item].self, forKey: .apps)) ?? []
        cli = try? c.decode(Item.self, forKey: .cli)
        proxy = (try? c.decode(String.self, forKey: .proxy)) ?? ""
        net = (try? c.decode(String.self, forKey: .net)) ?? ""
        if cli?.path.isEmpty == true { cli?.path = VafaStatus.cliName }
    }

    public static func parse(_ data: Data) -> VafaStatus? {
        guard !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(VafaStatus.self, from: data)
    }

    static let cliName = "Claude Code в терминале"

    static func displayName(_ path: String) -> String {
        if path == cliName { return path }
        let last = (path as NSString).lastPathComponent
        return last.hasSuffix(".app") ? String(last.dropLast(4)) : last
    }

    /// Всё, за чем присматривают: приложения, затем CLI.
    public var items: [Item] { apps + (cli.map { [$0] } ?? []) }
    /// Что сейчас заморожено или не даёт запуститься.
    public var blocked: [Item] { items.filter(\.isBlocked) }
    public var frozenCount: Int { items.reduce(0) { $0 + $1.frozen } }

    /// Сколько пунктов именно заморожено (а не только с запретом запуска) — число в компакте.
    public var frozenItems: [Item] { items.filter { $0.frozen > 0 } }

    /// Охрана сработала: VPN нет (down) или что-то заморожено/заблокировано. «unsure» без заморозки —
    /// только «проверяю» (страна не подтверждена или пауза GRACE): не дёргать человека на каждой проверке.
    /// Сеть к сервисам Claude в `unsure` уже закрыта (`net: hold`) — это видно на вкладке, но тревоги нет
    /// (вопрос пользователю — TODO.md §0).
    public var guardTriggered: Bool { state == "down" || !blocked.isEmpty }

    /// Маршрут идёт через VPN (туннель или прокси VPN-клиента) — как `_route_is_vpn` в vpn-guard.
    /// В `unsure` отличает «страна не подтверждена» (маршрут через VPN) от паузы GRACE (VPN пропал).
    public var routeIsVPN: Bool {
        if !proxy.isEmpty { return true }
        return ["utun", "ppp", "ipsec", "tun", "tap"].contains { iface.hasPrefix($0) }
    }

    /// Сеть к сервисам Claude закрыта фильтром (pf `hold`/`block`).
    public var netClosed: Bool { net == "hold" || net == "block" }

    /// «Claude, VLC и Claude Code в терминале».
    public static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " и " + names.last!
        }
    }
}

/// Что показывает модуль: сводка файла статуса.
public enum VafaPhase: Equatable, Sendable {
    /// Нет файла статуса (и нет самой Vafa).
    case notInstalled
    /// Vafa установлена (`VafaPaths.installMarkers`), но файла статуса нет — служба ещё не запускалась.
    case notRunning
    /// Файл есть, но давно не обновлялся — служба Vafa не работает.
    case stale
    /// Всё работает: VPN есть, ничего не заморожено.
    case ok
    /// `unsure`: страна выхода не подтверждена или пауза GRACE после пропажи VPN — ничего не заморожено.
    case checking
    /// Охрана сработала.
    case triggered

    /// Файл старше этого — служба не отвечает (vpn-guard пишет каждый круг, ~1 с).
    public static let staleAfter: TimeInterval = 120

    public static func of(_ s: VafaStatus?, now: Date = Date(), installed: Bool = false) -> VafaPhase {
        guard let s else { return installed ? .notRunning : .notInstalled }
        if s.time > 0, now.timeIntervalSince1970 - s.time > staleAfter { return .stale }
        if s.guardTriggered { return .triggered }
        if s.state == "up" { return .ok }
        return .checking
    }
}

/// Где Vafa держит файлы. `SIMPLEISLAND_VAFA_STATUS` — свой путь (самотест, отладка).
public enum VafaPaths {
    public static var statusFile: URL {
        if let p = ProcessInfo.processInfo.environment["SIMPLEISLAND_VAFA_STATUS"], !p.isEmpty {
            return URL(fileURLWithPath: p)
        }
        return URL(fileURLWithPath: "/usr/local/var/vpn-guard/status.json")
    }
    /// Признаки установленной Vafa.
    public static let installMarkers = ["/usr/local/bin/vpn-guard", "/Applications/Vafa.app"]
    public static var isInstalled: Bool { installMarkers.contains { FileManager.default.fileExists(atPath: $0) } }
}
