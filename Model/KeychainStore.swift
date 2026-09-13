import Foundation
import Security

/// Minimal Keychain-Services wrapper. Passwords are stored per profile id,
/// never in the profile file — the same separation Remmina uses via libsecret.
enum KeychainStore {
    private static let service = "se.fjarrconnect.app"

    static func setPassword(_ password: String?, for id: UUID) {
        let account = id.uuidString
        // Clear any existing item first.
        SecItemDelete(query(account: account) as CFDictionary)

        guard let password, !password.isEmpty,
              let data = password.data(using: .utf8) else { return }

        var add = query(account: account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func password(for id: UUID) -> String? {
        var q = query(account: id.uuidString)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deletePassword(for id: UUID) {
        SecItemDelete(query(account: id.uuidString) as CFDictionary)
    }

    private static func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
