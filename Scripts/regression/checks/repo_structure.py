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
    for case in ["csv", "txt", "pdf", "html", "json", "mbox"]:
        assert f"case {case}" in src, f"MessageExportFormat missing {case}"


def test_tag_release_job_yields_to_an_already_published_dmg(root: Path) -> None:
    """Scripts/release-local.sh publishes the DMG and then pushes the tag, which
    starts the CI release job. Without a guard, CI rebuilds and notarizes its own
    DMG and overwrites the published asset, so both Homebrew casks end up pointing
    at a SHA that no longer exists (the issue #21 failure mode)."""
    workflow = (root / ".github/workflows/build.yml").read_text()
    assert "release-guard:" in workflow, "the tag release job needs a guard against clobbering a published DMG"
    assert "should_release" in workflow, "the guard must publish its decision as a job output"
    assert "grep -qx 'Phosphor.dmg'" in workflow, "the guard must decide by checking for an already-attached DMG"
    assert "if: needs.release-guard.outputs.should_release == 'true'" in workflow, "the release job must be gated on the guard"
    assert "git rebase origin/main" in workflow, "the cask bump must rebase; the tag is behind main by the time it runs"
