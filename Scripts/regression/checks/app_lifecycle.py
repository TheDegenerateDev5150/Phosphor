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