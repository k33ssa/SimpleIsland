import AppKit
import Foundation

/// Сессия Claude Code, запущенная в приложении Claude (не в терминале): открыть именно её ссылкой
/// `claude://code/continue?session=local_…` (27.11: «кнопка Открыть не работает» — прыжок умел только в терминал,
/// а Claude, который и так спереди, просто «поднимался»). Номер `local_…` приложение хранит в
/// `~/Library/Application Support/Claude/claude-code-sessions/<орг>/<пользователь>/local_*.json` вместе с `cliSessionId`
/// — номером сессии Claude Code, который приходит в хуках. Читаем только служебные поля, не содержимое разговора.
enum ClaudeDesktopLink {
    static let bundleId = "com.anthropic.claudefordesktop"

    static var sessionsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true)
    }

    /// Номер `local_…` по номеру сессии Claude Code. Свежие файлы — первыми.
    static func localId(forCLISession cli: String, root: URL = sessionsRoot) -> String? {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                                    options: [.skipsHiddenFiles]) else { return nil }
        var files: [(URL, Date)] = []
        for case let u as URL in e where u.lastPathComponent.hasPrefix("local_") && u.pathExtension == "json" {
            let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            files.append((u, d))
        }
        let needle = Data(cli.utf8)
        for (u, _) in files.sorted(by: { $0.1 > $1.1 }) {
            guard let data = try? Data(contentsOf: u), data.range(of: needle) != nil,
                  let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            let ids = [o["cliSessionId"], o["lastAssistantCliSessionId"]].compactMap { $0 as? String }
            if ids.contains(cli), let local = o["sessionId"] as? String, local.hasPrefix("local_") { return local }
        }
        return nil
    }

    static func url(local: String) -> URL? {
        var c = URLComponents(string: "claude://code/continue")
        c?.queryItems = [URLQueryItem(name: "session", value: local), URLQueryItem(name: "source", value: "desktop_action")]
        return c?.url
    }

    /// Открыть сессию в Claude; `done(true)` — ссылка ушла.
    static func open(cliSession cli: String, done: @escaping @MainActor (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let local = localId(forCLISession: cli)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let local, let u = url(local: local) else { done(false); return }
                    NSWorkspace.shared.open(u)
                    done(true)
                }
            }
        }
    }
}
