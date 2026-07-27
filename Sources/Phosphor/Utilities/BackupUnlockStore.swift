import Foundation

/// Session-scoped registry of unlocked encrypted backups.
///
/// `BackupManifest` consults this on every open, so unlocking a backup once makes
/// it readable everywhere - Messages, Photos, Apps, Notes, Contacts, Call Log,
/// Calendar, Safari, Health and WhatsApp all go through the same manifest layer
/// and none of them need their own prompt.
///
/// Passwords live in memory for the lifetime of the process. Nothing here touches
/// preferences or the filesystem, so a password cannot outlive the session unless
/// the user explicitly opts in to the Keychain.
final class BackupUnlockStore: @unchecked Sendable {

    static let shared = BackupUnlockStore()

    private let lock = NSLock()
    private var decryptors: [String: BackupDecryptor] = [:]

    private init() {}

    /// Normalizing keeps `/tmp/x` and `/private/tmp/x/` pointing at one entry.
    private func key(_ backupPath: String) -> String {
        (backupPath as NSString).standardizingPath
    }

    /// Derive the keys for this backup and remember them for the session.
    /// Throws `BackupDecryptor.DecryptError.wrongPassword` so callers can re-prompt.
    @discardableResult
    func unlock(backupPath: String, password: String) throws -> BackupDecryptor {
        let decryptor = try BackupDecryptor(backupPath: backupPath, password: password)
        lock.lock()
        decryptors[key(backupPath)] = decryptor
        lock.unlock()
        return decryptor
    }

    func decryptor(for backupPath: String) -> BackupDecryptor? {
        lock.lock()
        defer { lock.unlock() }
        return decryptors[key(backupPath)]
    }

    func isUnlocked(_ backupPath: String) -> Bool {
        decryptor(for: backupPath) != nil
    }

    func forget(_ backupPath: String) {
        lock.lock()
        decryptors.removeValue(forKey: key(backupPath))
        lock.unlock()
    }

    func forgetAll() {
        lock.lock()
        decryptors.removeAll()
        lock.unlock()
    }
}
