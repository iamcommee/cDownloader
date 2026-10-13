import Foundation
import Security

/// Stores passwords outside the JSON files.
public protocol SecretStore: Sendable {
    func password(for key: String) -> String?
    func setPassword(_ password: String?, for key: String)
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    public init() {}

    public func password(for key: String) -> String? {
        lock.withLock { values[key] }
    }

    public func setPassword(_ password: String?, for key: String) {
        lock.withLock { values[key] = password }
    }
}

/// Passwords in the user's login Keychain as generic password items.
public struct KeychainSecretStore: SecretStore {
    public let service: String

    public init(service: String = "com.cdownloader.app") {
        self.service = service
    }

    public func password(for key: String) -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public func setPassword(_ password: String?, for key: String) {
        SecItemDelete(baseQuery(key) as CFDictionary)
        guard let password, !password.isEmpty else { return }
        var item = baseQuery(key)
        item[kSecValueData as String] = Data(password.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}
