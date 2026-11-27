import AppKit
import Foundation
import IslandCore

/// Отладка «Встреч» для живой проверки: `SimpleIsland --meetings-upload <файл> [--meetings-server <адрес>]`.
/// От имени уже вошедшей сессии виджета (cookie из Keychain, служба `local.simpleisland.sten`; пароль не нужен и не
/// спрашивается): создаёт встречу, загружает файл POST /audio (как «Загрузить запись» на сайте), печатает /status до
/// готовности (не дольше 40 мин) и сырой JSON /report и /speakers. Адрес по умолчанию — из настроек модуля, иначе
/// стандартный. Запускать бинарником из `dist/SimpleIsland.app` (та же подпись, что у записи в Keychain — без окна
/// «разрешить доступ к связке»).
@MainActor
public enum MeetingsCLI {
    public static func handle(_ args: [String]) -> Int32? {
        guard let i = args.firstIndex(of: "--meetings-upload") else { return nil }
        guard i + 1 < args.count else { print("нужен путь к файлу: --meetings-upload <файл>"); return 2 }
        let file = URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath)
        var serverText = savedServer() ?? StenServer.defaultAddress
        if let j = args.firstIndex(of: "--meetings-server"), j + 1 < args.count { serverText = args[j + 1] }
        guard let server = StenServer(serverText) else { print("непонятный адрес сервера: \(serverText)"); return 2 }
        guard FileManager.default.fileExists(atPath: file.path) else { print("нет файла \(file.path)"); return 2 }
        guard let cookie = FileSessionStore().load(account: server.account) else {
            print("нет сессии для \(server.display) — войдите в виджете «Встречи»"); return 3
        }
        _ = NSApplication.shared
        var code: Int32 = 1
        var done = false
        Task { @MainActor in
            code = await upload(file: file, server: server, cookie: cookie)
            done = true
        }
        while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        return code
    }

    static func savedServer() -> String? {
        guard let d = try? Data(contentsOf: SimpleIslandPaths.settingsFile),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let m = (o["moduleSettings"] as? [String: Any])?["meetings"] as? [String: Any] else { return nil }
        return m["server"] as? String
    }

    static func upload(file: URL, server: StenServer, cookie: String) async -> Int32 {
        let client = StenClient(server: server, cookie: cookie, timeout: 60)
        // Сервер продлил сессию — сохранить, как это сделал бы виджет.
        client.onCookie = { FileSessionStore().save($0, account: server.account) }
        do {
            print("сервер: \(server.display)")
            if let me = try await client.me() { print("сессия: \(me)") }
            let title = "Проверка загрузки " + MeetingsModel.defaultTitle(Date()).replacingOccurrences(of: "Встреча ", with: "")
            let m = try await client.createMeeting(title: title)
            print("встреча \(m.id): \(m.title)")
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
            print("загружаю \(file.lastPathComponent) (\(size) байт, \(Multipart.mime(for: file)))…")
            try await client.uploadAudio(m.id, file: file, mime: Multipart.mime(for: file))
            print("загружено")
            let deadline = Date().addingTimeInterval(40 * 60)
            var last = ""
            while Date() < deadline {
                let raw = String(decoding: try await client.raw("/meetings/\(m.id)/status"), as: UTF8.self)
                if raw != last { print("\(timestamp()) status \(raw)"); last = raw }
                if let s = J.object(Data(raw.utf8)).flatMap(StenStatus.init(json:)) {
                    if s.isReady || s.isError { break }
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
            for path in ["/meetings/\(m.id)/report", "/meetings/\(m.id)/speakers"] {
                print("\n--- GET /api\(path)")
                do { print(String(decoding: try await client.raw(path), as: UTF8.self)) }
                catch { print("ошибка: \(error.localizedDescription)") }
            }
            print("\nна сайте: \(server.consensusPage(m.id).absoluteString)")
            return 0
        } catch {
            print("ошибка: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
            return 1
        }
    }

    private static func timestamp() -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f.string(from: Date())
    }
}
