import Foundation
import Security

public enum CredentialKey: String, Sendable, CaseIterable {
    /// Cookie `media-user-token` пользователя music.apple.com. По сути пароль: хранить только в Keychain, не логировать.
    case mediaUserToken
    /// Developer token веб-плеера (JSON `{"token":…,"exp":…}`), кэш до `exp`.
    case appleDeveloperToken
    /// Storefront подписки (`us`, `ru`).
    case appleStorefront
}

/// Хранилище секретов. Реализация Keychain — ниже; в тестах — `InMemoryCredentialStore`.
public protocol CredentialStore: Sendable {
    func value(for key: CredentialKey) async throws -> String?
    /// `nil` удаляет значение.
    func set(_ value: String?, for key: CredentialKey) async throws
}

public actor InMemoryCredentialStore: CredentialStore {
    private var values: [CredentialKey: String]
    public init(_ initial: [CredentialKey: String] = [:]) { values = initial }
    public func value(for key: CredentialKey) async throws -> String? { values[key] }
    public func set(_ value: String?, for key: CredentialKey) async throws { values[key] = value }
}

/// Keychain (iOS и macOS). Элементы доступны после первой разблокировки, только на этом устройстве, не синхронизируются.
public struct KeychainCredentialStore: CredentialStore {
    public let service: String
    public let accessGroup: String?

    public init(service: String = "app.amnl.lyrics", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    private func baseQuery(_ key: CredentialKey) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecAttrSynchronizable as String: false,
        ]
        if let g = accessGroup { q[kSecAttrAccessGroup as String] = g }
        return q
    }

    public func value(for key: CredentialKey) async throws -> String? {
        var q = baseQuery(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        switch st {
        case errSecSuccess:
            guard let d = out as? Data else { return nil }
            return String(data: d, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw LyricsError.notConfigured("Keychain: код \(st)")
        }
    }

    public func set(_ value: String?, for key: CredentialKey) async throws {
        let q = baseQuery(key)
        guard let value else {
            let st = SecItemDelete(q as CFDictionary)
            if st != errSecSuccess && st != errSecItemNotFound { throw LyricsError.notConfigured("Keychain: код \(st)") }
            return
        }
        let data = Data(value.utf8)
        let update = [kSecValueData as String: data]
        var st = SecItemUpdate(q as CFDictionary, update as CFDictionary)
        if st == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            st = SecItemAdd(add as CFDictionary, nil)
        }
        if st != errSecSuccess { throw LyricsError.notConfigured("Keychain: код \(st)") }
    }
}
