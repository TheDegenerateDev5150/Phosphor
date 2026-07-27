from __future__ import annotations

from pathlib import Path
import subprocess
import tempfile


def read(root: Path, rel: str) -> str:
    return (root / rel).read_text()


def test_whatsapp_html_export_escapes_title_and_sender(root: Path) -> None:
    """Issue #38: chat title and sender are device-controlled and must be HTML
    escaped in the WhatsApp HTML export, or a crafted group subject / sender
    injects script into the exported document (stored XSS)."""
    src = read(root, "Sources/Phosphor/Services/WhatsAppExporter.swift")
    assert "<h1>\\(title)</h1>" not in src, "WhatsApp HTML export must not interpolate the raw chat title into <h1>"
    assert "<h1>\\(title.htmlEscaped)</h1>" in src, "WhatsApp HTML export must escape the chat title in <h1>"
    assert "class=\\\"sender\\\">\\(sender)</div>" not in src, "WhatsApp HTML export must not interpolate the raw sender"
    assert "sender.htmlEscaped" in src, "WhatsApp HTML export must escape the sender"
    assert "\\(title.htmlEscaped) - WhatsApp Export" in src, "WhatsApp HTML export must escape the title in <title>"


def test_shared_html_escaper_covers_all_dangerous_characters(root: Path) -> None:
    """The shared escaper must neutralize every character that can break out of
    an HTML text or attribute context."""
    src = read(root, "Sources/Phosphor/Utilities/HTMLEscaping.swift")
    for entity in ("&amp;", "&lt;", "&gt;", "&quot;", "&#39;"):
        assert entity in src, f"shared htmlEscaped must emit {entity}"


def test_backup_password_is_not_passed_on_the_command_line(root: Path) -> None:
    """Issue #39: the backup encryption password must reach the tool via the
    BACKUP_PASSWORD / BACKUP_PASSWORD_NEW environment variables (invisible to
    `ps`), not as a positional argument on the primary path."""
    backup = read(root, "Sources/Phosphor/Services/BackupManager.swift")
    assert "BACKUP_PASSWORD" in backup, "encryption toggle must pass the password via BACKUP_PASSWORD env var"
    assert "BACKUP_PASSWORD_NEW" in backup, "changepw must pass the new password via BACKUP_PASSWORD_NEW env var"
    # The old argv-based idevicebackup2 encryption invocations must be gone.
    assert '"encryption", "on", password' not in backup, "password must not be an idevicebackup2 argv value"
    assert '"encryption", "off", password' not in backup, "password must not be an idevicebackup2 argv value"


def test_app_extraction_rejects_traversal_and_symlink_components(root: Path) -> None:
    utility_path = root / "Sources/Phosphor/Utilities/SafeExtractionPath.swift"
    assert utility_path.exists(), "app extraction needs a shared safe destination resolver"

    app_manager = read(root, "Sources/Phosphor/Services/AppManager.swift")
    assert "SafeExtractionPath.prepareExtractionRoot" in app_manager, "AppManager must validate the untrusted bundle ID beneath the selected directory"
    assert "SafeExtractionPath.prepareDestination" in app_manager, "app extraction must validate every manifest relative path before writing"
    assert "appendingPathComponent(entry.relativePath)" not in app_manager, "untrusted manifest paths must not be appended directly"
    assert "lastError = nil" in app_manager[app_manager.index("func extractAppData("):], "app extraction should clear stale errors before validating paths"

    app_view = read(root, "Sources/Phosphor/Views/Apps/AppManagerView.swift")
    assert "appendingPathComponent(app.id)" not in app_view, "the view must not turn an untrusted bundle ID into the trusted extraction root"
    assert "to: url.path" in app_view, "AppManager needs the selected directory so it can enforce the boundary itself"

    app_view_model = read(root, "Sources/Phosphor/ViewModels/AppViewModel.swift")
    assert 'appManager.lastError ?? "No files extracted"' in app_view_model, "unsafe-path failures should be shown instead of a generic empty result"
    # One malformed manifest row should cost that row, not the whole extraction.
    assert "rejected += 1" in app_manager, "app extraction should skip unsafe entries and report the count, not abort the whole run"

    # Every sink that consumes a manifest-controlled path needs the same boundary.
    # Leaving one unguarded makes the fix cosmetic: a crafted backup just uses the
    # other one.
    for path, why in [
        ("Sources/Phosphor/Services/AppleWatchExtractor.swift", "the Watch extractor joins a manifest-controlled domain onto the chosen folder"),
        ("Sources/Phosphor/Services/PhotoExtractor.swift", "the photo extractor joins a manifest-controlled relativePath in its preserveStructure branch"),
        ("Sources/Phosphor/Services/BackupManager.swift", "selective backup extraction creates intermediate directories, which follows a planted symlink"),
    ]:
        assert "SafeExtractionPath.prepareDestination" in read(root, path), f"{path} must resolve destinations through SafeExtractionPath: {why}"

    probe = r'''
import Foundation

@main
struct SafePathProbe {
    static func main() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let outside = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: root.appendingPathComponent("symlinked-app"), withDestinationURL: outside)

        let extractionRoot = try SafeExtractionPath.prepareExtractionRoot(
            selectedDirectory: root,
            component: "com.example.app",
            fileManager: fm
        )
        try fm.createSymbolicLink(at: extractionRoot.appendingPathComponent("linked"), withDestinationURL: outside)

        let safe = try SafeExtractionPath.prepareDestination(
            root: extractionRoot,
            relativePath: "Documents/file.txt",
            fileManager: fm
        )
        guard safe.path == extractionRoot.appendingPathComponent("Documents/file.txt").path else {
            throw NSError(domain: "Probe", code: 1)
        }

        for component in ["", ".", "..", "../outside", "nested/app", "/tmp/absolute", "symlinked-app"] {
            do {
                _ = try SafeExtractionPath.prepareExtractionRoot(
                    selectedDirectory: root,
                    component: component,
                    fileManager: fm
                )
                print("ALLOWED_ROOT|\(component)")
                throw NSError(domain: "Probe", code: 2)
            } catch SafeExtractionPath.PathError.unsafePath {
                continue
            }
        }

        // A symlink sitting at the LEAF destination is the case a prefix check
        // cannot see: the path stays inside the root but the write lands wherever
        // the link points. Cover both a live link and a dangling one.
        try fm.createSymbolicLink(
            at: extractionRoot.appendingPathComponent("leaf-link.txt"),
            withDestinationURL: outside.appendingPathComponent("victim.txt")
        )
        try fm.createSymbolicLink(
            at: extractionRoot.appendingPathComponent("dangling-link.txt"),
            withDestinationURL: outside.appendingPathComponent("does-not-exist.txt")
        )

        let unsafe = [
            "",
            "/tmp/absolute.txt",
            "../victim.txt",
            "Documents/../../victim.txt",
            "Documents/./file.txt",
            "linked/victim.txt",
            "leaf-link.txt",
            "dangling-link.txt"
        ]
        for path in unsafe {
            do {
                _ = try SafeExtractionPath.prepareDestination(root: extractionRoot, relativePath: path, fileManager: fm)
                print("ALLOWED|\(path)")
                throw NSError(domain: "Probe", code: 2)
            } catch SafeExtractionPath.PathError.unsafePath {
                continue
            }
        }
        print("PASS")
    }
}
'''

    with tempfile.TemporaryDirectory() as temp_dir:
        temp = Path(temp_dir)
        probe_path = temp / "Probe.swift"
        probe_path.write_text(probe)
        executable = temp / "safe-path-probe"
        compile_result = subprocess.run(
            ["swiftc", "-parse-as-library", str(utility_path), str(probe_path), "-o", str(executable)],
            capture_output=True,
            text=True,
            timeout=60,
        )
        assert compile_result.returncode == 0, compile_result.stderr
        result = subprocess.run(
            [str(executable), str(temp / "root"), str(temp / "outside")],
            capture_output=True,
            text=True,
            timeout=10,
        )

    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "PASS", result.stdout


def test_shell_runasync_supports_extra_environment(root: Path) -> None:
    """Shell.runAsync must accept extra environment entries so secrets can be
    passed out-of-band from argv."""
    src = read(root, "Sources/Phosphor/Utilities/Shell.swift")
    assert "extraEnvironment" in src, "Shell.runAsync must expose an extraEnvironment parameter"
