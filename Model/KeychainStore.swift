import Foundation
import Security
import LocalAuthentication

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

/// Keeps the UI authentication boundary ahead of every Keychain read for a
/// protected profile. This does not alter the Keychain item's access control,
/// so users can turn protection off later without losing a saved credential.
enum ProfileAccessAuthenticator {
    static func authenticate(reason: String, completion: @escaping (Result<Void, Error>) -> Void) {
        let context = LAContext()
        var failure: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &failure) else {
            completion(.failure(failure ?? AuthenticationFailure.unavailable))
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { success, error in
            if success { completion(.success(())) }
            else { completion(.failure(error ?? AuthenticationFailure.cancelled)) }
        }
    }

    enum AuthenticationFailure: LocalizedError {
        case unavailable, cancelled

        var errorDescription: String? {
            switch self {
            case .unavailable: return NSLocalizedString("profile.touchID.unavailable", comment: "")
            case .cancelled: return NSLocalizedString("profile.touchID.failed", comment: "")
            }
        }
    }
}
