import Foundation
import Security

/// The tokens for one signed-in instance.
struct StoredSession: Codable, Equatable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date

    /// Treated as expiring a little early, so a request is not sent with a
    /// token that dies in flight.
    var isExpired: Bool {
        Date() >= expiresAt.addingTimeInterval(-60)
    }
}

/// Token storage.
///
/// The Keychain rather than `UserDefaults` because these are credentials: a
/// refresh token is a long-lived bearer of someone's account. `UserDefaults` is
/// a plist in the app container, readable from a backup; the Keychain is
/// encrypted and, with `ThisDeviceOnly`, does not travel in one.
actor SessionKeychain {

    static let shared = SessionKeychain()

    private let service = "net.vela.session"
    private let account = "peertube"

    func save(_ session: StoredSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            // Tokens are useless on another device and should not ride along in
            // an iCloud backup.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert.merge(attributes) { current, _ in current }
            SecItemAdd(insert as CFDictionary, nil)
        }
    }

    func load() -> StoredSession? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(StoredSession.self, from: data)
    }

    func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
