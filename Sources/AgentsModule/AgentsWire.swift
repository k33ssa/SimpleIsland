import Darwin
import Foundation
import IslandCore

// Протокол «хук → остров» (docs/TECH.md §6): Unix-сокет, один JSON на строку.
// Хук → остров: {"v":1,"ev":"pretooluse","id":"…"?, "agent":"claude", "session":"…", "cwd":"…", "tool":"…",
//                "input":{…}, "suggestions":[…], "term":{…}, "ts":…}
// Остров → хук (только на "permission"): {"id":"…","decision":"allow|deny|ask","message":"…","updatedPermissions":[…]}

/// Пути и переопределения окружением (для тестов и SSH-моста).
public enum AgentsPaths {
    /// `SIMPLEISLAND_AGENTS_SOCK` — свой путь к сокету (самотест, проброс `ssh -R`).
    public static var socketPath: String {
        if let p = ProcessInfo.processInfo.environment["SIMPLEISLAND_AGENTS_SOCK"], !p.isEmpty { return p }
        return NSHomeDirectory() + "/Library/Application Support/SimpleIsland/agents.sock"
    }

    /// Путь к сокету для текста (`~/…`).
    public static var socketDisplayPath: String {
        let p = socketPath, home = NSHomeDirectory()
        return p.hasPrefix(home + "/") ? "~" + p.dropFirst(home.count) : p
    }

    /// Домашний каталог для установщика. `SIMPLEISLAND_HOME` — временный HOME в тестах.
    public static var home: URL {
        if let p = ProcessInfo.processInfo.environment["SIMPLEISLAND_HOME"], !p.isEmpty {
            return URL(fileURLWithPath: p, isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    /// Бинарь, который пишется в хуки: исполняемый файл этого процесса (в .app — Contents/MacOS/SimpleIsland).
    public static var executablePath: String {
        let p = Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? CommandLine.arguments[0]
        return URL(fileURLWithPath: p).standardizedFileURL.path
    }

    static func hostName() -> String {
        var buf = [CChar](repeating: 0, count: 256)
        guard gethostname(&buf, buf.count) == 0 else { return "" }
        let s = String(cString: buf)
        return s.split(separator: ".").first.map(String.init) ?? s
    }
}

/// Где запущен агент: терминал, вкладка, tmux, SSH. Собирает хук-клиент из своего окружения.
public struct TermInfo: Codable, Equatable, Sendable {
    public var program: String?        // TERM_PROGRAM: Apple_Terminal, iTerm.app, tmux, vscode, ghostty, WarpTerminal…
    public var bundleId: String?       // __CFBundleIdentifier — приложение-терминал (есть и под tmux)
    public var itermSession: String?   // ITERM_SESSION_ID = w0t1p0:UUID
    public var termSession: String?    // TERM_SESSION_ID (Terminal.app)
    public var tmux: String?           // TMUX = <сокет>,<pid>,<сессия>
    public var tmuxPane: String?       // TMUX_PANE = %3
    public var tty: String?            // /dev/ttys003 — управляющий терминал агента
    public var pid: Int32?             // родитель хука — обычно `sh -c` агента, не сам агент; только для отладки
    public var ssh: String?            // SSH_CONNECTION, если агент в SSH-сессии
    public var host: String?

    public init(program: String? = nil, bundleId: String? = nil, itermSession: String? = nil, termSession: String? = nil,
                tmux: String? = nil, tmuxPane: String? = nil, tty: String? = nil, pid: Int32? = nil,
                ssh: String? = nil, host: String? = nil) {
        self.program = program; self.bundleId = bundleId; self.itermSession = itermSession
        self.termSession = termSession; self.tmux = tmux; self.tmuxPane = tmuxPane; self.tty = tty
        self.pid = pid; self.ssh = ssh; self.host = host
    }

    /// Из окружения текущего процесса (хук — дочерний процесс агента и наследует его окружение).
    static func current() -> TermInfo {
        let env = ProcessInfo.processInfo.environment
        func v(_ k: String) -> String? { env[k].flatMap { $0.isEmpty ? nil : $0 } }
        let parent = getppid()
        return TermInfo(program: v("TERM_PROGRAM"), bundleId: v("__CFBundleIdentifier"),
                        itermSession: v("ITERM_SESSION_ID"), termSession: v("TERM_SESSION_ID"),
                        tmux: v("TMUX"), tmuxPane: v("TMUX_PANE"), tty: controllingTTY(),
                        pid: parent > 1 ? parent : nil, ssh: v("SSH_CONNECTION") ?? v("SSH_CLIENT"),
                        host: AgentsPaths.hostName())
    }

    /// Управляющий терминал: свой, иначе ближайшего предка (хук запускают с перенаправленным stdin).
    static func controllingTTY() -> String? {
        var pid = getpid()
        for _ in 0..<6 {
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
            let dev = info.kp_eproc.e_tdev
            if dev != -1, dev != 0, let name = devname(dev, S_IFCHR) {
                return "/dev/" + String(cString: name)
            }
            let ppid = info.kp_eproc.e_ppid
            guard ppid > 1 else { return nil }
            pid = ppid
        }
        return nil
    }

    /// Подпись «где»: `ssh devbox`, `tmux %3`, `iTerm · вкладка 2`, `Терминал · ttys003`.
    public var placeLabel: String? {
        if ssh != nil { return "ssh " + (host ?? "") }
        if let pane = tmuxPane { return "tmux " + pane }
        if let s = itermSession, let tab = Self.itermTabIndex(s) { return "вкладка \(tab + 1)" }
        if let tty { return (tty as NSString).lastPathComponent }
        return appLabel
    }

    /// Название приложения-терминала для подписи.
    public var appLabel: String? {
        switch program ?? "" {
        case "Apple_Terminal": return "Терминал"
        case "iTerm.app": return "iTerm"
        case "vscode": return "VS Code"
        case "ghostty": return "Ghostty"
        case "WarpTerminal": return "Warp"
        case "WezTerm": return "WezTerm"
        case "": return nil
        default: return program
        }
    }

    static func itermTabIndex(_ id: String) -> Int? {
        // w0t1p0:UUID → 1
        guard let t = id.firstIndex(of: "t"), let p = id.firstIndex(of: "p"), t < p else { return nil }
        return Int(id[id.index(after: t)..<p])
    }

    /// Можно ли прыгнуть хоть куда-то.
    public var canJump: Bool { ssh == nil && (tty != nil || tmuxPane != nil || itermSession != nil || bundleId != nil) }
}

/// Сообщение хука, как его видит остров.
struct WireMessage: Decodable {
    var v: Int?
    var ev: String
    var id: String?
    var agent: String?
    var session: String?
    var cwd: String?
    var tool: String?
    var toolUseId: String?
    /// `agent_id` — событие из субагента (у субагента своя «остановка», SubagentStop).
    var agentId: String?
    var input: JSONValue?
    var suggestions: [JSONValue]?
    var message: String?
    var title: String?
    /// notification_type / source / reason / error / agent_type — смотря по событию.
    var kind: String?
    var prompt: String?
    var lastMessage: String?
    var permissionMode: String?
    var term: TermInfo?
    var ts: Double?
}

extension JSONValue {
    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }
    var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }
    var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }

    /// В обычный объект для JSONSerialization.
    var foundation: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n
        case .string(let s): return s
        case .array(let a): return a.map(\.foundation)
        case .object(let o): return o.mapValues(\.foundation)
        }
    }
}
