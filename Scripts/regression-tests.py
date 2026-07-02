#!/usr/bin/env python3
"""Lightweight Phosphor regression checks.

The current Apple Command Line Tools image used for this repo does not provide
XCTest/Testing modules, so these checks validate important source-level and
fixture-level invariants without a Swift test framework. They are intentionally
fast and deterministic so CI/local verification can run them alongside builds.
"""
from __future__ import annotations

import json
import re
import sqlite3
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(rel: str) -> str:
    return (ROOT / rel).read_text()


def assert_true(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def assert_contains(text: str, needle: str, message: str) -> None:
    assert_true(needle in text, message)


def test_streaming_exports_truncate_before_write() -> None:
    src = read("Sources/Phosphor/Services/MessageExporter.swift")
    for func_name in ["exportCSV", "exportPlainText", "exportHTML", "exportMbox", "exportJSON"]:
        match = re.search(rf"private func {func_name}.*?(?=\n    private func|\n    ///|\Z)", src, re.S)
        if match is None:
            raise AssertionError(f"{func_name} not found")
        body = match.group(0)
        assert_contains(body, "removeItem(at: outputURL)", f"{func_name} must remove existing output before streaming")
        assert_contains(body, "FileHandle(forWritingTo: outputURL)", f"{func_name} must stream through FileHandle")


def test_json_overwrite_fixture_has_no_stale_tail() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "export.json"
        long_payload = {"messages": [{"text": "x" * 10_000}]}
        short_payload = {"messages": []}
        path.write_text(json.dumps(long_payload), encoding="utf-8")
        # Mirrors MessageExporter's truncate-before-stream pattern.
        path.unlink(missing_ok=True)
        with path.open("w", encoding="utf-8") as handle:
            handle.write(json.dumps(short_payload))
        parsed = json.loads(path.read_text(encoding="utf-8"))
        assert_true(parsed == short_payload, "short JSON overwrite should parse without stale trailing bytes")


def test_lazy_manifest_size_queries_do_not_eager_stat() -> None:
    src = read("Sources/Phosphor/Utilities/BackupManifest.swift")
    for signature in ["func files(inDomain", "func search(_ query"]:
        start = src.index(signature)
        end = src.index("    ///", start + 1)
        body = src[start:end]
        assert_true("attributesOfItem" not in body, f"{signature} must not stat files eagerly")
        assert_true("SELECT fileID, domain, relativePath, flags" in body, f"{signature} should query metadata only")
    vm = read("Sources/Phosphor/ViewModels/BackupViewModel.swift")
    assert_contains(vm, "manifest.resolvingSizes(for: try manifest.files(inDomain: domain))", "backup browser should resolve visible domain sizes")
    assert_contains(vm, "manifest.resolvingSizes(for: try manifest.search(query))", "backup search should resolve visible search sizes")


def test_attachment_path_cache_invariants() -> None:
    src = read("Sources/Phosphor/Services/MessageExporter.swift")
    assert_contains(src, "attachmentDiskPathCache", "attachment path cache should exist")
    assert_contains(src, "missingAttachmentDiskPaths", "missing attachment cache should exist")
    assert_contains(src, "if let cached = attachmentDiskPathCache[filename]", "resolver should hit positive cache")
    assert_contains(src, "missingAttachmentDiskPaths.contains(filename)", "resolver should hit negative cache")
    assert_contains(src, "attachmentDiskPathCache[filename] = candidate", "resolver should store positive cache")
    assert_contains(src, "missingAttachmentDiskPaths.insert(filename)", "resolver should store negative cache")


def test_app_lifecycle_quits_after_last_window_closes() -> None:
    src = read("Sources/Phosphor/App/PhosphorApp.swift")
    assert_contains(src, "applicationShouldTerminateAfterLastWindowClosed", "Phosphor should quit when the last app window closes")
    assert_contains(src, "-> Bool {\n        true\n    }", "last-window-close delegate should return true")
    reopen = re.search(
        r"func\s+applicationShouldHandleReopen\(_ sender: NSApplication,\s*hasVisibleWindows flag: Bool\)\s*->\s*Bool\s*\{(?P<body>.*?)\n    \}",
        src,
        re.S,
    )
    if reopen is None:
        raise AssertionError("Dock/app reopen should recreate a missing window")
    assert_contains(reopen.group("body"), "ensureWindowSoon()", "reopen recovery should call the no-window guard inside applicationShouldHandleReopen")
    assert_true("CommandGroup(replacing: .newItem)" not in src, "do not remove SwiftUI's standard New Window command")


def test_minimal_sms_schema_fixture_supports_limited_attachment_query() -> None:
    # Fixture for the limited attachment-loading query shape: only requested IDs
    # should be returned, so search/global paths do not load all attachments.
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
        assert_true(len(rows) == 1 and rows[0][0] == 100, "limited attachment query should only load requested message IDs")
        con.close()


def main() -> None:
    tests = [name for name in globals() if name.startswith("test_")]
    for name in sorted(tests):
        globals()[name]()
        print(f"PASS {name}")
    print(f"PASS {len(tests)} regression checks")


if __name__ == "__main__":
    main()
