import Foundation
import Security

/// Minimal SecItem wrapper storing the optional per-host unlock secret.
/// One generic-password item per host, keyed by the host UUID.
enum Keychain {
    enum KeychainError: Error {
        case unexpectedStatus(OSStatus)
        case badData
    }

    private static let service = "dev.mhrsntrk.Landline.unlock"

    static func unlockSecret(hostID: UUID) -> String? {
        var query = baseQuery(hostID: hostID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let secret = String(data: data, encoding: .utf8)
        else { return nil }
        return secret
    }

    static func setUnlockSecret(_ secret: String, hostID: UUID) throws {
        guard let data = secret.data(using: .utf8) else { throw KeychainError.badData }

        let query = baseQuery(hostID: hostID)
        let update: [String: Any] = [kSecValueData as String: data]

        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    static func deleteUnlockSecret(hostID: UUID) throws {
        let status = SecItemDelete(baseQuery(hostID: hostID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private static func baseQuery(hostID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: hostID.uuidString,
        ]
    }
}
