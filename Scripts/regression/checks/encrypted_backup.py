from __future__ import annotations

from pathlib import Path
import subprocess
import tempfile


def read(root: Path, rel: str) -> str:
    return (root / rel).read_text()


def test_encrypted_backup_decrypts_without_python_or_external_tools(root: Path) -> None:
    """Build a synthetic encrypted backup exactly the way iOS does, then unlock it
    with the shipping BackupDecryptor.

    This is a behavioural check, not a substring match: it exercises the TLV keybag
    parser, the chained PBKDF2 (SHA-256 pre-round then SHA-1), RFC 3394 key unwrap,
    and AES-256-CBC with a zero IV. A wrong password must be rejected by the key
    unwrap integrity check rather than producing garbage plaintext.
    """
    crypto_path = root / "Sources/Phosphor/Utilities/BackupCrypto.swift"
    assert crypto_path.exists(), "native backup decryption must live in BackupCrypto.swift"

    crypto = read(root, "Sources/Phosphor/Utilities/BackupCrypto.swift")
    assert "iphone_backup_decrypt" not in crypto, "decryption must not shell out to a Python package"
    assert "Shell.runAsync" not in crypto, "decryption must not spawn a subprocess with the backup password"
    for path in ["Sources/Phosphor/Utilities/BackupCrypto.swift", "Sources/Phosphor/Utilities/BackupUnlockStore.swift"]:
        source = read(root, path)
        assert "UserDefaults" not in source, f"{path} must never persist a backup password to preferences"
        assert "write(toFile:" not in source, f"{path} must never write the backup password to disk"

    assert not (root / "Sources/Phosphor/Services/EncryptedBackupReader.swift").exists(), \
        "the Python-bridge reader interpolated the password into a temp script; it must be gone"

    plist_shim = (
        "import Foundation\n"
        "enum PlistParser {\n"
        "    static func parse(data: Data) -> [String: Any]? {\n"
        "        try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]\n"
        "    }\n"
        "}\n"
    )

    with tempfile.TemporaryDirectory() as temp_dir:
        temp = Path(temp_dir)
        (temp / "PlistParserStub.swift").write_text(plist_shim)
        (temp / "main.swift").write_text(PROBE)
        executable = temp / "backup-crypto-probe"
        compile_result = subprocess.run(
            [
                "swiftc",
                str(crypto_path),
                str(temp / "PlistParserStub.swift"),
                str(temp / "main.swift"),
                "-o",
                str(executable),
            ],
            capture_output=True,
            text=True,
            timeout=120,
        )
        assert compile_result.returncode == 0, compile_result.stderr
        result = subprocess.run(
            [str(executable), str(temp / "backup")],
            capture_output=True,
            text=True,
            timeout=60,
        )

    assert result.returncode == 0, result.stderr or result.stdout
    lines = result.stdout.split()
    assert "MANIFEST-OK" in lines, f"Manifest.db did not round-trip: {result.stdout!r}"
    assert "FILE-OK" in lines, f"file blob did not round-trip: {result.stdout!r}"
    assert "WRONGPASS-REJECTED" in lines, f"a wrong password must be rejected: {result.stdout!r}"
    assert "PASS" in lines, result.stdout


PROBE = r'''
import Foundation
import CommonCrypto

// Builds a synthetic encrypted iOS backup the same way iOS does, then unlocks it
// with BackupDecryptor to prove the native keybag/key-unwrap/AES chain is correct.

func randomData(_ n: Int) -> Data {
    var d = Data(count: n)
    _ = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, n, $0.baseAddress!) }
    return d
}

func aesKeyWrap(kek: Data, raw: Data) -> Data {
    var wrappedLen = CCSymmetricWrappedSize(CCWrappingAlgorithm(kCCWRAPAES), raw.count)
    var wrapped = Data(count: wrappedLen)
    let status: Int32 = wrapped.withUnsafeMutableBytes { wp in
        raw.withUnsafeBytes { rp in kek.withUnsafeBytes { kp in
            CCSymmetricKeyWrap(CCWrappingAlgorithm(kCCWRAPAES),
                CCrfc3394_iv, CCrfc3394_ivLen,
                kp.baseAddress!.assumingMemoryBound(to: UInt8.self), kek.count,
                rp.baseAddress!.assumingMemoryBound(to: UInt8.self), raw.count,
                wp.baseAddress!.assumingMemoryBound(to: UInt8.self), &wrappedLen)
        }}
    }
    precondition(status == Int32(kCCSuccess), "wrap failed \(status)")
    return wrapped.prefix(wrappedLen)
}

func aesCBCEncrypt(key: Data, data: Data) -> Data {
    let iv = Data(count: kCCBlockSizeAES128)
    let capacity = data.count + kCCBlockSizeAES128
    var out = Data(count: capacity)
    var moved = 0
    let status: Int32 = out.withUnsafeMutableBytes { op in
        data.withUnsafeBytes { dp in iv.withUnsafeBytes { ip in key.withUnsafeBytes { kp in
            CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(0),
                    kp.baseAddress!, key.count, ip.baseAddress!,
                    dp.baseAddress!, data.count, op.baseAddress!, capacity, &moved)
        }}}
    }
    precondition(status == Int32(kCCSuccess), "encrypt failed \(status)")
    return out.prefix(moved)
}

func tlv(_ tag: String, _ value: Data) -> Data {
    var out = Data(tag.utf8)
    var len = UInt32(value.count).bigEndian
    out.append(Data(bytes: &len, count: 4))
    out.append(value)
    return out
}
func tlvUInt32(_ tag: String, _ value: UInt32) -> Data {
    var be = value.bigEndian
    return tlv(tag, Data(bytes: &be, count: 4))
}

let password = "correct horse battery staple"
let salt = randomData(20)
let iterations: UInt32 = 1000
let doubleSalt = randomData(20)
let doubleIterations: UInt32 = 1000
let protectionClasses: [UInt32] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]
let manifestClass: UInt32 = 4

// iOS 10.2+ derivation: SHA-256 pre-round, then SHA-1.
let stretched = BackupCrypto.pbkdf2(prf: kCCPRFHmacAlgSHA256, password: Data(password.utf8),
                                    salt: doubleSalt, rounds: doubleIterations, length: 32)!
let passcodeKey = BackupCrypto.pbkdf2(prf: kCCPRFHmacAlgSHA1, password: stretched,
                                      salt: salt, rounds: iterations, length: 32)!

var classKeys: [UInt32: Data] = [:]
var keybag = Data()
keybag += tlvUInt32("VERS", 4)
keybag += tlvUInt32("TYPE", 1)
keybag += tlv("UUID", randomData(16))
keybag += tlv("HMCK", randomData(40))
keybag += tlvUInt32("WRAP", 0)
keybag += tlv("SALT", salt)
keybag += tlvUInt32("ITER", iterations)
keybag += tlv("DPSL", doubleSalt)
keybag += tlvUInt32("DPIC", doubleIterations)
for clas in protectionClasses {
    let classKey = randomData(32)
    classKeys[clas] = classKey
    keybag += tlv("UUID", randomData(16))
    keybag += tlvUInt32("CLAS", clas)
    keybag += tlvUInt32("WRAP", 2)
    keybag += tlvUInt32("KTYP", 0)
    keybag += tlv("WPKY", aesKeyWrap(kek: passcodeKey, raw: classKey))
}

// A real SQLite database standing in for Manifest.db.
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let plainDBPath = root.appendingPathComponent("plain.db").path
let sqlite = Process()
sqlite.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
sqlite.arguments = [plainDBPath, "CREATE TABLE Files (fileID TEXT PRIMARY KEY, domain TEXT, relativePath TEXT, flags INTEGER, file BLOB); INSERT INTO Files VALUES ('abc','HomeDomain','Library/SMS/sms.db',1,NULL);"]
try sqlite.run(); sqlite.waitUntilExit()
let plainDB = try Data(contentsOf: URL(fileURLWithPath: plainDBPath))
precondition(plainDB.count % 16 == 0, "sqlite page size is a multiple of the AES block size")

let manifestKey = randomData(32)
var manifestKeyBlob = withUnsafeBytes(of: manifestClass.littleEndian) { Data($0) }
manifestKeyBlob += aesKeyWrap(kek: classKeys[manifestClass]!, raw: manifestKey)
precondition(manifestKeyBlob.count == 44, "ManifestKey is 4 + 40 bytes")

try aesCBCEncrypt(key: manifestKey, data: plainDB).write(to: root.appendingPathComponent("Manifest.db"))
let manifestPlist: [String: Any] = [
    "Version": "10.0", "IsEncrypted": true,
    "BackupKeyBag": keybag, "ManifestKey": manifestKeyBlob,
]
try PropertyListSerialization.data(fromPropertyList: manifestPlist, format: .binary, options: 0)
    .write(to: root.appendingPathComponent("Manifest.plist"))

// A file blob: encrypted with its own class key, padded, truncated on read to Size.
let payload = Data("phosphor encrypted backup round trip".utf8)
let fileKey = randomData(32)
var fileKeyBlob = withUnsafeBytes(of: UInt32(3).littleEndian) { Data($0) }
fileKeyBlob += aesKeyWrap(kek: classKeys[3]!, raw: fileKey)
var padded = payload
let padLength = 16 - (payload.count % 16)
padded.append(Data(repeating: UInt8(padLength), count: padLength))
try FileManager.default.createDirectory(at: root.appendingPathComponent("ab"), withIntermediateDirectories: true)
let blobPath = root.appendingPathComponent("ab/abc").path
try aesCBCEncrypt(key: fileKey, data: padded).write(to: URL(fileURLWithPath: blobPath))

// Manifest.db stores each row's metadata as an NSKeyedArchiver archive of an
// MBFile object, which encodes its properties as direct dictionary keys and
// points at Digest/EncryptionKey/RelativePath by archiver UID. Foundation's
// plist writer cannot emit archiver UIDs from Swift, so the cross-references
// here are plain integers - BackupFileRecord never dereferences them, it locates
// the record by the keys MBFile writes inline and the 44-byte wrapped-key blob.
let fileArchivePlist: [String: Any] = [
    "$version": 100_000,
    "$archiver": "NSKeyedArchiver",
    "$top": ["root": 1],
    "$objects": [
        "$null",
        [
            "$class": 8,
            "Birth": 1_770_000_000,
            "Digest": 4,
            "EncryptionKey": 5,
            "GroupID": 501,
            "InodeNumber": 123_456,
            "LastModified": 1_770_000_000,
            "LastStatusChange": 1_770_000_000,
            "Mode": 33188,
            "ProtectionClass": 3,
            "RelativePath": 2,
            "Size": payload.count,
            "UserID": 501,
        ] as [String: Any],
        "Library/SMS/sms.db",
        "HomeDomain",
        ["$class": 7, "NS.data": randomData(20)] as [String: Any],
        ["$class": 7, "NS.data": fileKeyBlob] as [String: Any],
        ["$classes": ["NSMutableData", "NSData", "NSObject"], "$classname": "NSMutableData"] as [String: Any],
        ["$classes": ["MBFile", "NSObject"], "$classname": "MBFile"] as [String: Any],
    ],
]
let fileArchiveData = try PropertyListSerialization.data(
    fromPropertyList: fileArchivePlist, format: .binary, options: 0
)

// --- Assertions against the shipping implementation ---
let decryptor = try BackupDecryptor(backupPath: root.path, password: password)
let decryptedDB = try decryptor.decryptedManifestDatabase()
precondition(decryptedDB == plainDB, "decrypted Manifest.db must byte-match the plaintext database")
print("MANIFEST-OK")

guard let record = BackupFileRecord(fileBlob: fileArchiveData) else {
    print("RECORD-FAIL"); exit(1)
}
precondition(record.size == payload.count, "record size \(record.size)")
precondition(record.protectionClass == 3, "record class \(record.protectionClass)")
let decryptedFile = try decryptor.decryptFile(at: blobPath, record: record, displayName: "sms.db")
precondition(decryptedFile == payload, "decrypted file must match and be trimmed to Size")
print("FILE-OK")

do {
    _ = try BackupDecryptor(backupPath: root.path, password: "wrong password")
    print("WRONGPASS-ACCEPTED"); exit(1)
} catch BackupDecryptor.DecryptError.wrongPassword {
    print("WRONGPASS-REJECTED")
} catch {
    print("WRONGPASS-OTHER \(error)"); exit(1)
}
print("PASS")
'''


def test_encrypted_backup_has_a_password_prompt_wired_to_every_entry_point(root: Path) -> None:
    """Issue #51: the decryptor existed but was dead code - no view or view model
    referenced it, so there was no way to enter a password anywhere."""
    view_model = read(root, "Sources/Phosphor/ViewModels/BackupViewModel.swift")
    assert "@Published var pendingUnlock: BackupInfo?" in view_model, "a locked backup must raise a prompt instead of a dead-end error"
    assert "BackupUnlockStore.shared.isUnlocked(backup.path)" in view_model, "an already-unlocked backup must open without re-prompting"
    assert "func submitUnlock(password: String, remember: Bool) async" in view_model, "the sheet needs an async submit; key derivation is deliberately slow"
    assert "Task.detached" in view_model, "two chained PBKDF2 rounds must not run on the main actor"

    sheet = read(root, "Sources/Phosphor/Views/Backup/BackupUnlockSheet.swift")
    assert "SecureField" in sheet, "the password field must be secure"
    assert "backupVM.unlockError" in sheet, "a wrong password must re-prompt with the reason, not close the sheet"

    # Presented at the root so Backups, Messages, Photos, Apps and the time machine
    # all get the same prompt rather than each needing their own.
    content = read(root, "Sources/Phosphor/Views/ContentView.swift")
    assert ".sheet(item: $backupVM.pendingUnlock)" in content, "the unlock sheet must be presented once, at the root"

    keychain = read(root, "Sources/Phosphor/Utilities/BackupPasswordKeychain.swift")
    assert "kSecAttrAccessibleWhenUnlockedThisDeviceOnly" in keychain, "a remembered backup password must not sync or migrate off this Mac"

    # Consumers that read blobs directly would see ciphertext; they all have to go
    # through the manifest's decrypting accessors.
    for path in [
        "Sources/Phosphor/Services/WhatsAppExporter.swift",
        "Sources/Phosphor/Services/NotesExtractor.swift",
        "Sources/Phosphor/Services/CallLogExtractor.swift",
        "Sources/Phosphor/Services/SafariExtractor.swift",
        "Sources/Phosphor/Services/HealthExtractor.swift",
        "Sources/Phosphor/Services/CalendarExtractor.swift",
        "Sources/Phosphor/Services/ContactsExtractor.swift",
        "Sources/Phosphor/Services/AppleWatchExtractor.swift",
    ]:
        source = read(root, path)
        assert "diskPath(backupRoot: backupPath)" not in source, \
            f"{path} still reads the raw blob path, which is ciphertext on an encrypted backup"

    exporter = read(root, "Sources/Phosphor/Services/MessageExporter.swift")
    assert "unlockedManifest" in exporter, "sms.db and attachments must resolve through the manifest when the backup is encrypted"


def test_known_hash_fast_paths_are_skipped_on_encrypted_backups(root: Path) -> None:
    """Several extractors short-circuit to a well-known SHA-1 blob path and only
    fall back to the manifest when that file is missing. On an encrypted backup the
    file IS there - as ciphertext - so the fast path wins and SQLite is handed
    garbage. The fast path has to be skipped while decrypting."""
    for path in [
        "Sources/Phosphor/Services/ContactsExtractor.swift",
        "Sources/Phosphor/Services/CalendarExtractor.swift",
        "Sources/Phosphor/Services/AppleWatchExtractor.swift",
    ]:
        source = read(root, path)
        assert "manifest.isDecrypting" in source, \
            f"{path} must not trust a known-hash blob path when the backup is encrypted"

    manifest = read(root, "Sources/Phosphor/Utilities/BackupManifest.swift")
    assert "var isDecrypting: Bool { decryptor != nil }" in manifest, "consumers need to know whether the manifest is serving decrypted content"
