from __future__ import annotations

from pathlib import Path


def read(root: Path, rel: str) -> str:
    return (root / rel).read_text()


def test_no_conflict_markers(root: Path) -> None:
    for path in (root / "Sources").rglob("*.swift"):
        text = path.read_text(errors="ignore")
        assert "<<<<<<<" not in text and ">>>>>>>" not in text, f"conflict marker in {path.relative_to(root)}"


def test_key_source_files_exist(root: Path) -> None:
    for rel in [
        "Sources/Phosphor/App/PhosphorApp.swift",
        "Sources/Phosphor/Services/MessageExporter.swift",
        "Sources/Phosphor/Services/BackupManager.swift",
        "Sources/Phosphor/Views/Messages/MessageListView.swift",
        "Sources/Phosphor/Views/Backup/BackupListView.swift",
    ]:
        assert (root / rel).exists(), f"missing {rel}"


def test_message_export_formats_are_registered(root: Path) -> None:
    src = read(root, "Sources/Phosphor/Models/Message.swift")
    for case in ["csv", "txt", "html", "json", "mbox"]:
        assert f"case {case}" in src, f"MessageExportFormat missing {case}"
