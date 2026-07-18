from __future__ import annotations

import json
import re
import sqlite3
import tempfile
from pathlib import Path


def read(root: Path, rel: str) -> str:
    return (root / rel).read_text()


def assert_contains(text: str, needle: str, message: str) -> None:
    assert needle in text, message


def test_streaming_exports_truncate_before_write(root: Path) -> None:
    src = read(root, "Sources/Phosphor/Services/MessageExporter.swift")
    for func_name in ["exportCSV", "exportPlainText", "exportHTML", "exportMbox", "exportJSON"]:
        match = re.search(rf"private func {func_name}.*?(?=\n    private func|\n    ///|\Z)", src, re.S)
        assert match is not None, f"{func_name} not found"
        body = match.group(0)
        assert_contains(body, "removeItem(at: outputURL)", f"{func_name} must remove existing output before streaming")
        assert_contains(body, "FileHandle(forWritingTo: outputURL)", f"{func_name} must stream through FileHandle")





def test_bulk_message_exports_use_collision_safe_filenames(root: Path) -> None:
    src = read(root, "Sources/Phosphor/Services/MessageExporter.swift")
    assert_contains(src, "private func exportFilename(for chat", "Bulk message export should centralize filename generation")
    assert_contains(src, "-chat-\\(chat.id)", "Bulk message export filenames should include chat id to avoid duplicate-title overwrites")
    export_all = re.search(r"func exportAllChats\(.*?\) throws -> Int \{(?P<body>.*?)\n    \}", src, re.S)
    assert export_all is not None, "exportAllChats should exist"
    assert_contains(export_all.group("body"), "exportFilename(for: chat", "exportAllChats should use collision-safe filenames")


def test_html_export_cleans_stale_attachment_folder(root: Path) -> None:
    src = read(root, "Sources/Phosphor/Services/MessageExporter.swift")
    assert_contains(src, "private func removeAttachmentFolder(forHTMLPath", "HTML export should have explicit stale attachment cleanup")
    html = re.search(r"private func exportHTML\(.*?\) throws \{(?P<body>.*?)\n    \}", src, re.S)
    assert html is not None, "exportHTML should exist"
    assert_contains(html.group("body"), "removeAttachmentFolder(forHTMLPath: path)", "HTML export should remove stale attachment folders before staging/writing")
def test_json_overwrite_fixture_has_no_stale_tail(root: Path) -> None:
    del root  # fixture mirrors the Swift export invariant without touching source files.
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "export.json"
        long_payload = {"messages": [{"text": "x" * 10_000}]}
        short_payload = {"messages": []}
        path.write_text(json.dumps(long_payload), encoding="utf-8")
        path.unlink(missing_ok=True)
        with path.open("w", encoding="utf-8") as handle:
            handle.write(json.dumps(short_payload))
        assert json.loads(path.read_text(encoding="utf-8")) == short_payload


def test_attachment_path_cache_invariants(root: Path) -> None:
    src = read(root, "Sources/Phosphor/Services/MessageExporter.swift")
    assert_contains(src, "attachmentDiskPathCache", "attachment path cache should exist")
    assert_contains(src, "missingAttachmentDiskPaths", "missing attachment cache should exist")
    assert_contains(src, "if let cached = attachmentDiskPathCache[filename]", "resolver should hit positive cache")
    assert_contains(src, "missingAttachmentDiskPaths.contains(filename)", "resolver should hit negative cache")
    assert_contains(src, "attachmentDiskPathCache[filename] = candidate", "resolver should store positive cache")
    assert_contains(src, "missingAttachmentDiskPaths.insert(filename)", "resolver should store negative cache")


def test_message_view_clears_stale_loaded_backup_and_preserves_readiness(root: Path) -> None:
    view_model = read(root, "Sources/Phosphor/ViewModels/MessageViewModel.swift")
    assert_contains(view_model, "func clear()", "MessageViewModel should expose a clear path for stale backup state")
    assert_contains(view_model, "var loadedBackupPath", "MessageViewModel should expose the loaded backup path for UI reconciliation")
    assert_contains(view_model, "exportOperationID", "Message exports should ignore stale detached task completions after clearing/switching backups")
    assert_contains(view_model, "invalidateExportForBackupSwitch", "Switching backups should cancel and clear active export state")
    assert_contains(view_model, "exportTask?.cancel()", "Switching/clearing backups should cancel active detached export work")
    assert_contains(view_model, "self.exportOperationID == exportID", "Detached export completions should only update current export state")
    assert_contains(view_model, "self.backupPath == backupPath", "Detached export completions should not update UI after the loaded backup changes")

    view = read(root, "Sources/Phosphor/Views/Messages/MessageListView.swift")
    assert_contains(view, ".onChange(of: backupVM.selectedBackup?.id)", "Messages should react when BackupViewModel clears or changes the selected backup")
    assert_contains(view, ".onChange(of: backupVM.backups.map(\\.path))", "Messages should react when the backup folder/list changes")
    assert_contains(view, "reconcileLoadedBackupWithAvailableBackups", "Messages should clear old chats when their backup path disappears")
    assert_contains(view, "messageVM.clear()", "Messages should clear stale conversations/export state")
    assert_contains(view, "messageVM.loadedBackupPath != nil && loadedBackupIsCurrent && messageVM.chats.isEmpty", "Messages readiness should render even when BackupViewModel selectedBackup is nil after manifest-open failure")
    assert_contains(view, "guard loadedBackupIsCurrent", "Export actions should be gated to the currently loaded backup")


def test_stale_export_completion_model_requires_current_operation_and_backup(root: Path) -> None:
    del root
    state = {
        "exportOperationID": "export-1",
        "backupPath": "/backups/A",
        "isExporting": True,
        "exportResult": None,
    }

    def complete(export_id: str, backup_path: str, result: str) -> None:
        if state["exportOperationID"] != export_id or state["backupPath"] != backup_path:
            return
        state["isExporting"] = False
        state["exportOperationID"] = None
        state["exportResult"] = result

    def fail_or_cancel(export_id: str, backup_path: str, message: str) -> None:
        if state["exportOperationID"] != export_id or state["backupPath"] != backup_path:
            return
        state["isExporting"] = False
        state["exportOperationID"] = None
        state["alertMessage"] = message

    def switch_backup(path: str) -> None:
        if state["backupPath"] != path:
            state["exportOperationID"] = None
            state["isExporting"] = False
        state["backupPath"] = path

    state["exportOperationID"] = None  # MessageViewModel.clear()
    complete("export-1", "/backups/A", "stale clear completion")
    fail_or_cancel("export-1", "/backups/A", "stale clear failure")
    assert state["exportResult"] is None, "cleared exports must ignore stale completions"
    assert "alertMessage" not in state, "cleared exports must ignore stale failure/cancel alerts"

    state.update(exportOperationID="export-2", backupPath="/backups/A", isExporting=True)
    switch_backup("/backups/B")
    complete("export-2", "/backups/A", "stale backup completion")
    fail_or_cancel("export-2", "/backups/A", "stale backup failure")
    assert state["exportResult"] is None, "backup switches must ignore completions from the old backup"
    assert "alertMessage" not in state, "backup switches must ignore failure/cancel alerts from the old backup"
    assert state["isExporting"] is False, "backup switches should not leave the export overlay stuck"

    state.update(exportOperationID="export-3", backupPath="/backups/B", isExporting=True)
    complete("export-3", "/backups/B", "current completion")
    assert state["exportResult"] == "current completion"
    assert state["isExporting"] is False


def test_message_exports_escape_csv_and_mbox_headers(root: Path) -> None:
    src = read(root, "Sources/Phosphor/Services/MessageExporter.swift")
    helper = read(root, "Sources/Phosphor/Utilities/CSVExport.swift")
    assert_contains(helper, "enum CSVExport", "CSV export escaping should be centralized for all CSV surfaces")
    assert_contains(helper, "static func field", "CSV helper should expose field escaping")
    assert_contains(helper, "drop(while:", "CSV helper should detect formula payloads after leading whitespace")
    assert_contains(helper, '["=", "+", "-", "@"].contains', "CSV helper should neutralize spreadsheet formula-leading cells")
    assert_contains(src, "fields.map(CSVExport.field)", "Message CSV export should escape every field, not only message text")
    assert_contains(src, "private func mboxToken", "MBOX export should sanitize Message-ID/boundary tokens")
    assert_contains(src, "private func headerToken", "MBOX export should sanitize MIME header tokens")
    assert_contains(src, ".replacingOccurrences(of: \"\\n\", with: \" \")", "MBOX header encoding should strip raw newlines")
    assert_contains(src, "embeddedAttachments", "MBOX export should collect every embeddable attachment")
    assert_contains(src, "for embedded in embeddedAttachments", "MBOX export should emit all non-payload attachments, not just the first")


def test_csv_exports_share_formula_safe_helper(root: Path) -> None:
    helper = read(root, "Sources/Phosphor/Utilities/CSVExport.swift")
    assert_contains(helper, "static func row", "CSV helper should centralize whole-row creation")
    for rel in [
        "Sources/Phosphor/Services/CalendarExtractor.swift",
        "Sources/Phosphor/Services/CallLogExtractor.swift",
        "Sources/Phosphor/Services/ContactsExtractor.swift",
        "Sources/Phosphor/Services/HealthExtractor.swift",
        "Sources/Phosphor/Services/SafariExtractor.swift",
        "Sources/Phosphor/Services/WhatsAppExporter.swift",
    ]:
        src = read(root, rel)
        assert_contains(src, "CSVExport.row", f"{rel} should use the shared CSV escaping/formula-neutralization helper")


def test_message_export_writers_check_cancellation_inside_long_loops(root: Path) -> None:
    src = read(root, "Sources/Phosphor/Services/MessageExporter.swift")
    assert_contains(src, "cancellationCheck: (() throws -> Void)?", "Message exports should accept a cancellation checkpoint")
    for func_name in ["exportCSV", "exportPlainText", "exportHTML", "exportMbox", "exportJSON"]:
        match = re.search(rf"private func {func_name}.*?(?=\n    private func|\n    ///|\Z)", src, re.S)
        assert match is not None, f"{func_name} not found"
        assert_contains(match.group(0), "try cancellationCheck?()", f"{func_name} should stop promptly during large single-chat exports")
    stage = re.search(r"private func stageAttachments.*?(?=\n    private func|\n    ///|\Z)", src, re.S)
    assert stage is not None, "stageAttachments should exist"
    assert_contains(stage.group(0), "try cancellationCheck?()", "HTML attachment staging should be cancellable")


def test_minimal_sms_schema_fixture_supports_limited_attachment_query(root: Path) -> None:
    del root
    with tempfile.TemporaryDirectory() as tmp:
        db_path = Path(tmp) / "sms.db"
        con = sqlite3.connect(db_path)
        con.executescript(
            """
            CREATE TABLE attachment (ROWID INTEGER PRIMARY KEY, guid TEXT, filename TEXT, mime_type TEXT, transfer_name TEXT, total_bytes INTEGER);
            CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);
            INSERT INTO attachment VALUES (1,'a','~/Library/SMS/Attachments/a.jpg','image/jpeg','a.jpg',10);
            INSERT INTO attachment VALUES (2,'b','~/Library/SMS/Attachments/b.jpg','image/jpeg','b.jpg',20);
            INSERT INTO message_attachment_join VALUES (100,1);
            INSERT INTO message_attachment_join VALUES (200,2);
            """
        )
        rows = con.execute(
            """
            SELECT maj.message_id, a.ROWID, a.guid, a.filename, a.mime_type, a.transfer_name, a.total_bytes
            FROM attachment a JOIN message_attachment_join maj ON maj.attachment_id = a.ROWID
            WHERE maj.message_id IN (?)
            """,
            (100,),
        ).fetchall()
        con.close()
        assert len(rows) == 1 and rows[0][0] == 100, "limited attachment query should only load requested message IDs"


def test_message_exporter_caches_schema_and_preserves_tapback_context(root: Path) -> None:
    src = read(root, "Sources/Phosphor/Services/MessageExporter.swift")
    assert_contains(src, "private let messageColumns", "message table columns should be cached per exporter")
    assert_contains(src, "private func foldRows", "reaction/tapback folding should be centralized")
    assert_contains(src, "reactionEventsByTarget", "tapback rows must be folded with their target messages")
    assert_contains(src, "associated_message_type", "tapback detection should use associated_message_type when present")
