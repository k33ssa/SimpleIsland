import AppKit
import Foundation
import IslandCore

/// Прыжок в окно/вкладку агента: Terminal.app по tty, iTerm2 по ITERM_SESSION_ID (AppleScript, право
/// «Автоматизация»), tmux — select-window/pane по TMUX_PANE, прочие терминалы — просто поднять приложение.
/// Дочерние процессы (osascript, tmux) — только `ManagedProcess` (своя группа, гибнут вместе с приложением),
/// главный поток не ждёт: результат приходит в `completion`.
@MainActor
enum TerminalJumper {
    enum Result: Equatable {
        case ok
        /// Нет права «Автоматизация» на приложение (ошибка -1743).
        case needsAutomation(app: String)
        case failed(String)
    }

    static let terminalBundle = "com.apple.Terminal"
    static let itermBundle = "com.googlecode.iterm2"

    static func jump(_ t: TermInfo, completion: @escaping @MainActor (Result) -> Void) {
        Task { @MainActor in completion(await perform(t)) }
    }

    private static func perform(_ t: TermInfo) async -> Result {
        if t.ssh != nil { return .failed("сессия на другой машине (ssh)") }
        var tty = t.tty
        if let pane = t.tmuxPane {
            let socket = t.tmux?.split(separator: ",").first.map(String.init)
            await tmuxSelect(pane: pane, socket: socket)
            // Внешний терминал того tmux-клиента, что показывает сессию этой панели, — в нём и прыгаем.
            if let clientTTY = await tmuxClientTTY(pane: pane, socket: socket) { tty = clientTTY }
        }
        let bundle = t.bundleId ?? bundleForProgram(t.program)
        switch bundle {
        case terminalBundle:
            guard let tty else { return activate(bundle) }
            return withFallback(await runAppleScript(terminalScript(tty: tty), app: "Терминал"), bundle: bundle)
        case itermBundle:
            if let s = t.itermSession, let uuid = s.split(separator: ":").last {
                return withFallback(await runAppleScript(itermScript(uuid: String(uuid)), app: "iTerm"), bundle: bundle)
            }
            return activate(bundle)
        default:
            return activate(bundle)
        }
    }

    /// Нет «Автоматизации» — нужную вкладку не выбрать, но приложение-терминал всё равно поднять
    /// (так и обещано в настройках); результат `.needsAutomation` остаётся — для плашки «Разрешить…».
    private static func withFallback(_ r: Result, bundle: String?) -> Result {
        if case .needsAutomation = r { _ = activate(bundle) }
        return r
    }

    static func bundleForProgram(_ p: String?) -> String? {
        switch p {
        case "Apple_Terminal": return terminalBundle
        case "iTerm.app": return itermBundle
        case "vscode": return "com.microsoft.VSCode"
        case "ghostty": return "com.mitchellh.ghostty"
        case "WarpTerminal": return "dev.warp.Warp-Stable"
        case "WezTerm": return "com.github.wez.wezterm"
        default: return nil
        }
    }

    private static func activate(_ bundle: String?) -> Result {
        guard let bundle else { return .failed("неизвестный терминал") }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundle)
        guard let app = apps.first else { return .failed("терминал не запущен") }
        return app.activate() ? .ok : .failed("не удалось поднять \(bundle)")
    }

    static func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func terminalScript(tty: String) -> String {
        """
        tell application id "com.apple.Terminal"
          repeat with w in windows
            repeat with t in tabs of w
              if tty of t is "\(appleScriptEscape(tty))" then
                set selected of t to true
                set index of w to 1
                activate
                return "ok"
              end if
            end repeat
          end repeat
          activate
        end tell
        return "notfound"
        """
    }

    static func itermScript(uuid: String) -> String {
        """
        tell application id "com.googlecode.iterm2"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if unique id of s is "\(appleScriptEscape(uuid))" then
                  select w
                  select t
                  select s
                  activate
                  return "ok"
                end if
              end repeat
            end repeat
          end repeat
          activate
        end tell
        return "notfound"
        """
    }

    /// osascript в отдельном процессе: не держит главный поток, ошибка -1743 = нет права «Автоматизация».
    /// Таймаут 60 с — пользователь может отвечать на системный запрос «Автоматизации».
    private static func runAppleScript(_ source: String, app: String) async -> Result {
        guard let r = await ChildRun.run("/usr/bin/osascript", ["-e", source], timeout: 60) else {
            return .failed("osascript не запустился или не ответил")
        }
        if r.status == 0 { return .ok }
        if r.err.contains("-1743") || r.err.contains("Not authorized") { return .needsAutomation(app: app) }
        return .failed(r.err.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func tmuxBinary() -> String? {
        ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    @discardableResult
    private static func tmux(_ args: [String], socket: String?) async -> String? {
        guard let bin = tmuxBinary() else { return nil }
        guard let r = await ChildRun.run(bin, (socket.map { ["-S", $0] } ?? []) + args, timeout: 5), r.status == 0 else { return nil }
        return r.out
    }

    private static func tmuxSelect(pane: String, socket: String?) async {
        await tmux(["select-window", "-t", pane], socket: socket)
        await tmux(["select-pane", "-t", pane], socket: socket)
    }

    /// tty клиента, подключённого к сессии панели (а не первого клиента сервера: их может быть несколько).
    private static func tmuxClientTTY(pane: String, socket: String?) async -> String? {
        guard let session = await tmux(["display-message", "-p", "-t", pane, "#{session_id}"], socket: socket)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !session.isEmpty,
              let s = await tmux(["list-clients", "-t", session, "-F", "#{client_activity} #{client_tty}"], socket: socket)
        else { return nil }
        // Несколько клиентов на одной сессии — берём последний активный.
        let best = s.split(separator: "\n").compactMap { line -> (Int, String)? in
            let p = line.split(separator: " ", maxSplits: 1)
            guard p.count == 2 else { return nil }
            return (Int(p[0]) ?? 0, String(p[1]))
        }.max { $0.0 < $1.0 }
        return best?.1
    }

    /// Системные настройки → Конфиденциальность → Автоматизация.
    static func openAutomationSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(u)
        }
    }
}


/// Разовый дочерний процесс через `ManagedProcess`: вывод целиком, код выхода, потолок по времени.
@MainActor
final class ChildRun {
    struct Output: Sendable { var status: Int32; var out: String; var err: String }

    private let process: ManagedProcess
    private var out: [String] = []
    private var err: [String] = []
    private var finished = false
    private var timeoutWork: DispatchWorkItem?
    private var done: ((Output?) -> Void)?

    private init(_ exe: String, _ args: [String]) {
        process = ManagedProcess(executable: exe, arguments: args, restart: .never)
    }

    /// nil — не запустился или не уложился в `timeout` (тогда группа процесса гасится).
    static func run(_ exe: String, _ args: [String], timeout: TimeInterval) async -> Output? {
        let r = ChildRun(exe, args)
        return await withCheckedContinuation { (cont: CheckedContinuation<Output?, Never>) in
            MainActor.assumeIsolated { r.start(timeout: timeout) { cont.resume(returning: $0) } }
        }
    }

    private func start(timeout: TimeInterval, done: @escaping (Output?) -> Void) {
        self.done = done
        process.onLine = { [weak self] in self?.out.append($0) }
        process.onErrorLine = { [weak self] in self?.err.append($0) }
        process.onExit = { [self] code in
            // Выход и хвост вывода приходят разными путями (выход — источник на главной очереди, вывод — фоновое
            // чтение → главная очередь), порядок не гарантирован: ждём EOF обоих потоков (stderr osascript с −1743,
            // client_tty у tmux). Держим себя до конца.
            self.finishWhenDrained(code, attempt: 0)
        }
        guard process.start() else { finish(nil); return }
        let w = DispatchWorkItem { [self] in MainActor.assumeIsolated { self.process.stop(grace: 0.5); self.finish(nil) } }
        timeoutWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: w)
    }

    /// Ждать EOF обоих потоков шагами по 20 мс; потолок — 1 с (внук держит трубу открытой — отдать, что есть).
    private func finishWhenDrained(_ code: Int32, attempt: Int) {
        guard !finished else { return }
        if process.isOutputDrained || attempt >= 50 {
            finish(Output(status: code, out: out.joined(separator: "\n"), err: err.joined(separator: "\n")))
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [self] in
            MainActor.assumeIsolated { self.finishWhenDrained(code, attempt: attempt + 1) }
        }
    }

    private func finish(_ r: Output?) {
        guard !finished else { return }
        finished = true
        timeoutWork?.cancel(); timeoutWork = nil
        process.onLine = nil; process.onErrorLine = nil; process.onExit = nil
        done?(r); done = nil
    }
}
