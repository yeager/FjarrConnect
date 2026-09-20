import Foundation
import Security

/// Update in place so a failed write never deletes a previously saved password.
enum KeychainStore {
    enum Purpose: String { case login, gateway }
    private static let service = "se.fjarrconnect.app"

    struct Failure: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            SecCopyErrorMessageString(status, nil) as String? ?? "Keychain (\(status))"
        }
    }

    static func setPassword(_ password: String?, for id: UUID, purpose: Purpose = .login) throws {
        guard let password else { return }
        guard !password.isEmpty else { try deletePassword(for: id, purpose: purpose); return }
        let data = Data(password.utf8)
        let query = query(id: id, purpose: purpose)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            try check(SecItemAdd(add as CFDictionary, nil))
        } else { try check(status) }
    }

    static func password(for id: UUID, purpose: Purpose = .login) throws -> String? {
        var q = query(id: id, purpose: purpose)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data, let password = String(data: data, encoding: .utf8) else {
            throw Failure(status: errSecDecode)
        }
        return password
    }

    static func deletePassword(for id: UUID, purpose: Purpose = .login) throws {
        let status = SecItemDelete(query(id: id, purpose: purpose) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    private static func query(id: UUID, purpose: Purpose) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (purpose == .login ? service : service + ".rdp-gateway"), kSecAttrAccount as String: id.uuidString]
    }
}
