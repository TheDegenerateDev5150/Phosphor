from __future__ import annotations

import re
from pathlib import Path


def read(root: Path, rel: str) -> str:
    return (root / rel).read_text()


def test_phosphor_quits_after_last_window_closes(root: Path) -> None:
    src = read(root, "Sources/Phosphor/App/PhosphorApp.swift")
    assert "applicationShouldTerminateAfterLastWindowClosed" in src, "Phosphor should quit when the last app window closes"
    assert "-> Bool {\n        true\n    }" in src, "last-window-close delegate should return true"


def test_phosphor_preserves_reopen_window_recovery(root: Path) -> None:
    src = read(root, "Sources/Phosphor/App/PhosphorApp.swift")
    reopen = re.search(
        r"func\s+applicationShouldHandleReopen\(_ sender: NSApplication,\s*hasVisibleWindows flag: Bool\)\s*->\s*Bool\s*\{(?P<body>.*?)\n    \}",
        src,
        re.S,
    )
    assert reopen is not None, "Dock/app reopen should recreate a missing window"
    assert "ensureWindowSoon()" in reopen.group("body"), "reopen recovery should call the no-window guard inside applicationShouldHandleReopen"
    assert "CommandGroup(replacing: .newItem)" not in src, "do not remove SwiftUI's standard New Window command"

def test_apps_screen_can_reach_backup_extraction_without_leaving_it(root: Path) -> None:
    """Issue #46: Extract Data existed only on the In Backup tab, and that tab
    stayed empty until a backup was selected from the Backups section. Nothing in
    the UI said so, so the feature read as missing."""
    view = read(root, "Sources/Phosphor/Views/Apps/AppManagerView.swift")

    assert "private var backupPicker: some View" in view, "the Apps header needs its own backup picker"
    assert "backupVM.openBackupBrowser(backup)" in view, "picking a backup from Apps must go through the shared browser opener"
    assert "Choose Backup Folder..." in view, "the picker must offer an arbitrary folder, for backups made outside Phosphor"
    assert "if let latest = backupVM.backups.first" in view, "opening Apps should land on the newest backup instead of an empty screen"

    # Without this the list goes stale when the selection changes elsewhere, and
    # Extract Data silently no-ops after the destination panel closes.
    assert ".onChange(of: backupVM.selectedBackup?.path)" in view, "the app list must follow the selected backup"

    assert "actionLabel: \"Use Latest Backup\"" in view, "the no-selection empty state needs a real action, not just instructions"
    assert "Go to In Backup" in view, "the On Device tab must explain where extraction lives"
    assert "LoadingOverlay(message: \"Reading apps from backup...\")" in view, "reading a large backup must show progress, not an empty state"

    view_model = read(root, "Sources/Phosphor/ViewModels/AppViewModel.swift")
    assert "func loadBackupApps(backupPath: String) async" in view_model, "reading a backup's apps must not block the main actor"

    manager = read(root, "Sources/Phosphor/Services/AppManager.swift")
    assert "private nonisolated static func readBackupApps" in manager, "the stat-heavy manifest walk must run off the main actor"
