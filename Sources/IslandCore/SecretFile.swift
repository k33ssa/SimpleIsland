import Foundation
import Security

/// Секреты острова (cookie сессии Sten, токен Apple Music) — в файле `~/Library/Application Support/SimpleIsland/
/// secrets.json` с правами 600 (каталог 700), а не в Keychain (16.11).
///
/// Почему не Keychain: приложение подписано своей локальной подписью без команды разработчика, и macOS привязывает
/// доступ к элементу Keychain к хэшу кода. Каждая пересборка — новый хэш и новое окно «SimpleIsland хочет
/// использовать конфиденциальную информацию…» на каждом запуске после обновления. Файл с правами 600 читает
/// только эта учётная запись — тот же уровень, что у токенов в ~/.config других программ.
///
/// Переезд: значение, которого ещё нет в файле, один раз читается из прежнего элемента Keychain (`service`/`account`)
/// и переносится в файл; элемент Keychain после этого не трогается (удаление спросило бы пароль ещё раз).
/// Значения не логируются.
public final class SecretFile: @unchecked Sendable {
    /// Самотесты и снимки (`--selftest-*`, `--snapshot*`, `--render-*`) секретов не касаются вовсе: ни файла, ни
    /// Keychain (иначе каждая отладочная сборка агентов снова звала окно пароля, 16.11).
    public static let shared: SecretFile = {
        let a = CommandLine.arguments.dropFirst()
        let tool = a.contains { $0.hasPrefix("--selftest") || $0.hasPrefix("--snapshot") || $0.hasPrefix("--render") }
        return tool ? SecretFile(memoryOnly: true) : SecretFile()
    }()
    private let memoryOnly: Bool

    private let url: URL
    private let lock = NSLock()
    private var cache: [String: String]?
    /// Самотест: не ходить в Keychain.
    private let migrateFromKeychain: Bool

    public init(url: URL? = nil, migrateFromKeychain: Bool = true, memoryOnly: Bool = false) {
        self.memoryOnly = memoryOnly
        if let url { self.url = url } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.url = base.appendingPathComponent("SimpleIsland", isDirectory: true).appendingPathComponent("secrets.json")
        }
        self.migrateFromKeychain = migrateFromKeychain && !memoryOnly
        if memoryOnly { cache = [:] }
    }

    private static func key(_ service: String, _ account: String) -> String { service + "|" + account }

    /// Значение; нет в файле — один раз из Keychain (переезд).
    public func value(service: String, account: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        var all = loadLocked()
        let k = Self.key(service, account)
        if let v = all[k] { return v.isEmpty ? nil : v }
        guard migrateFromKeychain else { return nil }
        // Пустая строка — «уже смотрели в Keychain, там нет»: не спрашивать его снова.
        let found = Self.keychainRead(service: service, account: account)
        all[k] = found ?? ""
        writeLocked(all)
        return found
    }

    /// `nil` — удалить (и пометить, что в Keychain за ним ходить не надо).
    public func set(_ value: String?, service: String, account: String) {
        lock.lock(); defer { lock.unlock() }
        var all = loadLocked()
        all[Self.key(service, account)] = value ?? ""
        writeLocked(all)
    }

    // MARK: Файл

    private func loadLocked() -> [String: String] {
        if let c = cache { return c }
        let d = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        cache = d
        return d
    }

    private func writeLocked(_ all: [String: String]) {
        cache = all
        if memoryOnly { return }
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONEncoder().encode(all) else { return }
        // Сначала файл с правами 600, потом содержимое — секрет ни мгновения не лежит открытым.
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        defer { try? h.close() }
        try? h.truncate(atOffset: 0)
        try? h.write(contentsOf: data)
    }

    // MARK: Keychain (только чтение для переезда)

    private static func keychainRead(service: String, account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        let s = String(decoding: d, as: UTF8.self)
        return s.isEmpty ? nil : s
    }
}
