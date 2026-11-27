import Foundation
import Security
import IslandCore

/// Где лежит cookie сессии Sten. Пароль не хранится нигде — только cookie, который выдал сервер после входа.
public protocol StenSessionStore: AnyObject {
    func load(account: String) -> String?
    func save(_ cookie: String, account: String)
    func delete(account: String)
}

/// Keychain, служба `local.simpleisland.sten`, учётная запись — хост + путь сервера.
public final class KeychainSessionStore: StenSessionStore {
    public static let service = "local.simpleisland.sten"
    public init() {}

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: account]
    }

    public func load(account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        let s = String(decoding: d, as: UTF8.self)
        return s.isEmpty ? nil : s
    }

    public func save(_ cookie: String, account: String) {
        let data = Data(cookie.utf8)
        let q = query(account)
        let st = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if st == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecAttrLabel as String] = "SimpleIsland — сессия Sten"
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    public func delete(account: String) { SecItemDelete(query(account) as CFDictionary) }
}

/// Файл секретов острова (`SecretFile`, права 600) — без окон Keychain после каждой пересборки (16.11). Прежняя
/// cookie из Keychain переезжает в файл один раз (одно окно доступа).
public final class FileSessionStore: StenSessionStore {
    private let file: SecretFile
    public init(file: SecretFile = .shared) { self.file = file }
    public func load(account: String) -> String? { file.value(service: KeychainSessionStore.service, account: account) }
    public func save(_ cookie: String, account: String) { file.set(cookie, service: KeychainSessionStore.service, account: account) }
    public func delete(account: String) { file.set(nil, service: KeychainSessionStore.service, account: account) }
}

/// Хранилище в памяти — самотесты и снимки (Keychain не трогают).
public final class MemorySessionStore: StenSessionStore {
    public private(set) var items: [String: String] = [:]
    public init() {}
    public func load(account: String) -> String? { items[account] }
    public func save(_ cookie: String, account: String) { items[account] = cookie }
    public func delete(account: String) { items[account] = nil }
}
