from __future__ import annotations

from pathlib import Path


def read(root: Path, rel: str) -> str:
    return (root / rel).read_text()


def swift_block_after(text: str, signature: str) -> str:
    start = text.index(signature)
    brace = text.index("{", start)
    depth = 0
    for index in range(brace, len(text)):
        char = text[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return text[start:index + 1]
    raise AssertionError(f"unterminated Swift block after {signature}")


def test_shell_run_does_not_block_global_dispatch_workers(root: Path) -> None:
    src = read(root, "Sources/Phosphor/Utilities/Shell.swift")
    body = swift_block_after(src, "static func run(_ command: String")
    assert "process.terminationHandler" in body, "Shell.run should wait via Process.terminationHandler"
    assert "SIGKILL" in body, "Shell.run should force-kill commands that ignore graceful timeout termination"
    assert "waitUntilExit()" not in body, "Shell.run must not burn a global dispatch worker in waitUntilExit()"
    assert "DispatchQueue.global" not in body, "Shell.run must not allocate a global queue worker per process"


def test_shell_run_async_does_not_block_global_dispatch_workers(root: Path) -> None:
    src = read(root, "Sources/Phosphor/Utilities/Shell.swift")
    body = swift_block_after(src, "static func runAsync(_ command: String")
    assert "process.terminationHandler" in body, "Shell.runAsync should wait via Process.terminationHandler"
    assert "readabilityHandler" in body, "Shell.runAsync should collect pipe output without blocking reader workers"
    assert "SIGKILL" in body, "Shell.runAsync should force-kill commands that ignore graceful timeout termination"
    assert "waitUntilExit()" not in body, "Shell.runAsync must not block a worker in waitUntilExit()"
    assert "DispatchQueue.global" not in body, "Shell.runAsync must not allocate a global queue worker per process"


def test_shell_run_async_cancels_timeout_watchdog_on_finish(root: Path) -> None:
    src = read(root, "Sources/Phosphor/Utilities/Shell.swift")
    body = swift_block_after(src, "static func runAsync(_ command: String")
    assert "attachWatchdog" in body, "runAsync should hand its timeout watchdog to the state so it can be cancelled early"
    assert "pendingWatchdog?.cancel()" in src, "finish should cancel the watchdog so pipe fds are freed the moment the command completes"
    assert "timedOut ? -1 : process.terminationStatus" in body, "runAsync must not read terminationStatus on the timed-out path (process may still be running)"


def test_shell_run_streaming_has_bounded_timeout_and_force_kill(root: Path) -> None:
    src = read(root, "Sources/Phosphor/Utilities/Shell.swift")
    body = src[src.index("static func runStreaming("):src.index("    /// Terminate a long-running child")]
    assert "timeout: TimeInterval?" in body, "Shell.runStreaming should let one-shot streams set a timeout"
    assert "process.terminationHandler" in body, "Shell.runStreaming should complete through Process.terminationHandler"
    assert "readabilityHandler" in body, "Shell.runStreaming should stream pipe output without blocking reader workers"
    assert "SIGKILL" in body, "Shell.runStreaming should force-kill commands that ignore timeout termination"
    assert "setTimeoutTask" in body, "Shell.runStreaming should cancel timeout sleeper tasks on normal completion"
    assert "Task.isCancelled" in body, "Shell.runStreaming timeout task should stop promptly after finish cancels it"
    assert "waitUntilExit()" not in body, "Shell.runStreaming must not block a worker in waitUntilExit()"
    assert "DispatchQueue.global" not in body, "Shell.runStreaming must not allocate a global queue worker per process"


def test_backup_streaming_callers_are_timeout_bounded_and_cancelable(root: Path) -> None:
    backup = read(root, "Sources/Phosphor/Services/BackupManager.swift")
    assert "streamingBackupTimeout" in backup, "backup streams should use a named timeout"
    assert "streamingRestoreTimeout" in backup, "restore streams should use a named timeout"
    assert "timeout: Self.streamingBackupTimeout" in backup, "backup subprocess streams must pass the backup timeout"
    assert "timeout: Self.streamingRestoreTimeout" in backup, "restore subprocess streams must pass the restore timeout"
    assert "activeProcess = Shell.runStreaming" in backup, "fallback streaming processes should be cancelable via activeProcess"
    assert "beginCancellableOperation()" in backup, "backup/restore operations should use operation IDs rather than one shared cancellation boolean"
    assert "cancelledOperationIDs.insert(activeOperationID)" in backup, "cancelBackup should mark the active operation canceled before killing the child"
    assert "operationWasCancelled(operationID)" in backup, "cancelled primary streams should not fall through into fallback backups"
    assert "lastOperationWasCancelled" in backup, "cancellation should be exposed separately from lastError/backup failures"
    assert "if activeOperationID == id" in swift_block_after(backup, "private func markOperationCancelled"), "stale cancelled operations should not overwrite current operation UI state"
    assert "backupCancelled" not in backup, "backup/restore cancellation must not use one shared mutable boolean"
    assert "lastError = nil" in swift_block_after(backup, "func cancelBackup()"), "cancelBackup should not report user cancellation as an error"
    assert "Shell.terminate(activeProcess)" in backup, "cancelBackup should escalate termination for stuck subprocesses"

    backup_vm = read(root, "Sources/Phosphor/ViewModels/BackupViewModel.swift")
    assert "backupManager.lastOperationWasCancelled" in backup_vm, "backup UI should not show failure alerts after user cancellation"
    assert "backupOperationID" in backup_vm, "BackupViewModel should ignore stale backup task progress/completions"
    assert "guard backupOperationID == operationID else { return }" in backup_vm, "stale backup completions should not update alerts or progress"

    time_machine = read(root, "Sources/Phosphor/Views/Backup/BackupTimeMachineView.swift")
    assert "lastOperationWasCancelled" in time_machine, "restore UI should not show a generic failure alert after cancellation"

    diagnostics = read(root, "Sources/Phosphor/Services/DiagnosticsManager.swift")
    assert "syslogStreamID" in diagnostics, "syslog streams should use an identity token so stopped/stale streams cannot update UI"
    assert "let primaryProcess = PyMobileDevice.startSyslog" in diagnostics, "primary syslog launch should be assigned locally before mutating syslogProcess"
    assert "if let primaryProcess" in diagnostics, "primary syslog process should only be stored after synchronous launch-failure completions finish"
    assert "syslogProcess == nil" in diagnostics, "fallback launch should not overwrite or duplicate an already-installed process"
    assert "if exitCode != 0, self.isStreamingSyslog" in diagnostics, "runtime pymobiledevice3 syslog failures should fall back while the stream is current"
    assert "self.startSyslogFallback(udid: udid, streamID: streamID)" in diagnostics, "primary syslog completion should route runtime failures to fallback"
    assert "guard syslogStreamID == streamID, isStreamingSyslog else { return }" in diagnostics, "fallback syslog should not start after Stop or a newer stream"
    assert "guard let self, self.syslogStreamID == streamID else { return }" in diagnostics, "stale syslog output/completions should be ignored"
    assert "syslogStreamID = nil" in swift_block_after(diagnostics, "func stopSyslog()"), "stopSyslog should invalidate stream identity before termination completions fire"
    assert "syslogProcess = Shell.runStreaming" in diagnostics, "syslog fallback should be stoppable via syslogProcess"
    assert "Shell.terminate(syslogProcess)" in diagnostics, "stopSyslog should escalate termination for stuck syslog children"


def test_cancellation_token_model_prevents_cancelled_primary_from_starting_fallback(root: Path) -> None:
    del root
    active_operation_id: str | None = None
    cancelled_operation_ids: set[str] = set()
    fallback_started: list[str] = []
    progress_text = ""

    def begin(operation_id: str) -> str:
        nonlocal active_operation_id
        active_operation_id = operation_id
        return operation_id

    def cancel_current() -> None:
        if active_operation_id is not None:
            cancelled_operation_ids.add(active_operation_id)

    def mark_cancelled(operation_id: str) -> None:
        nonlocal active_operation_id, progress_text
        if active_operation_id == operation_id:
            progress_text = "Cancelled"
            active_operation_id = None
        cancelled_operation_ids.discard(operation_id)

    def primary_completed(operation_id: str, exit_code: int) -> None:
        if operation_id in cancelled_operation_ids:
            mark_cancelled(operation_id)
            return
        if exit_code != 0:
            fallback_started.append(operation_id)

    first = begin("first")
    cancel_current()
    second = begin("second")
    primary_completed(first, exit_code=1)
    primary_completed(second, exit_code=0)

    assert fallback_started == [], "a cancelled primary must not start fallback after a newer operation begins"
    assert cancelled_operation_ids == set(), "cancelled operation IDs should be cleaned up when their completion arrives"
    assert progress_text == "", "stale cancelled completions must not overwrite the current operation's UI"


def test_no_crash_only_swift_shortcuts(root: Path) -> None:
    offenders: list[str] = []
    for path in (root / "Sources").rglob("*.swift"):
        text = path.read_text(errors="ignore")
        for lineno, line in enumerate(text.splitlines(), start=1):
            if "try!" in line or "as!" in line or "fatalError(" in line or "preconditionFailure(" in line:
                offenders.append(f"{path.relative_to(root)}:{lineno}: {line.strip()}")
    assert not offenders, "Avoid crash-only Swift shortcuts:\n" + "\n".join(offenders)
