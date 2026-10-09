import Foundation
import Security

/// Generic-password items for secrets the user types into Settings (hosted
/// writing-model API keys). The value lives only in this Mac's Keychain:
/// never in UserDefaults, `secrets.env`, Info.plist, logs or analytics.
/// Mirrors the SecItem pattern in `SharePublishing` (update, then add).
///
/// Persistence across updates: items land in the login Keychain with an
/// access list that trusts the creating app's designated requirement
/// (bundle id + Developer ID team), not one specific binary. Every release
/// is signed with the same identity, so a Sparkle update or a reinstall of
/// a newer version reads the key silently. A differently signed build (an
/// ad-hoc dev build) gets the system "allow access?" prompt instead; never
/// change the bundle id or signing team without migrating these items.
enum Keychain {
    struct SaveFailed: Error { let status: OSStatus }

    static func save(_ value: String, service: String, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: account]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: Data(value.utf8)] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = Data(value.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw SaveFailed(status: added) }
        } else if status != errSecSuccess {
            throw SaveFailed(status: status)
        }
    }

    static func read(service: String, account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: account,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let value = String(data: data, encoding: .utf8) else { return nil }
        return value
    }

    static func delete(service: String, account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}
