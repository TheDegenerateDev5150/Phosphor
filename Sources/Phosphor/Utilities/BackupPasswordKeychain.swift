import Foundation
import Security

/// Optional, opt-in storage for a backup password in the macOS Keychain.
///
/// Nothing calls `save` unless the user ticks "Remember this password". The
/// default path keeps the password in memory only, in `BackupUnlockStore`.
enum BackupPasswordKeychain {

    private static let service = "com.phosphor.app.backup-password"

    private static func account(for backupPath: String) -> String {
        (backupPath as NSString).standardizingPath
    }

    private static func baseQuery(for backupPath: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: backupPath),
        ]
    }

    @discardableResult
    static func save(password: String, backupPath: String) -> Bool {
        guard !password.isEmpty else { return false }
        delete(backupPath: backupPath)

        var query = baseQuery(for: backupPath)
        query[kSecValueData as String] = Data(password.utf8)
        // Only readable while the Mac is unlocked, and never synced to iCloud or
        // migrated to another machine.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func password(for backupPath: String) -> String? {
        var query = baseQuery(for: backupPath)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let password = String(data: data, encoding: .utf8),
              !password.isEmpty else { return nil }
        return password
    }

    static func hasStoredPassword(for backupPath: String) -> Bool {
        password(for: backupPath) != nil
    }

    @discardableResult
    static func delete(backupPath: String) -> Bool {
        SecItemDelete(baseQuery(for: backupPath) as CFDictionary) == errSecSuccess
    }
}
