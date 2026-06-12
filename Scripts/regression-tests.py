#!/usr/bin/env python3
"""Lightweight Wi-Fi backup/device regression checks for Phosphor."""
from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(rel: str) -> str:
    return (ROOT / rel).read_text()


def assert_true(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def assert_contains(text: str, needle: str, message: str) -> None:
    assert_true(needle in text, message)


def test_device_polling_cache_and_refresh_invariants() -> None:
    src = read("Sources/Phosphor/Services/DeviceManager.swift")
    assert_contains(src, "func scanForDevices(forceRefresh: Bool = false)", "scan should expose forceRefresh")
    assert_contains(src, "while isScanning", "force refresh should wait for active scans instead of racing")
    assert_contains(src, "deviceInfoCache.removeAll()", "zero-device scan should clear device cache")
    assert_contains(src, "batteryInfoCache.removeAll()", "zero-device scan should clear battery cache")
    assert_contains(src, "pairStatusCache.removeAll()", "zero-device scan should clear pair cache")
    assert_contains(src, "if !forceRefresh, let cached = cachedDevice", "normal polling should use device cache")
    assert_contains(src, "cachedBatteryInfo(udid: udid, forceRefresh: forceRefresh)", "force refresh should bypass battery cache")
    assert_contains(src, "cachedPymobiledevicePairStatus(udid: udid, forceRefresh: forceRefresh)", "force refresh should bypass pair cache")
    assert_contains(src, "pairStatusCache.removeValue(forKey: udid)", "pair/unpair should invalidate pair cache")


def test_wifi_backup_ui_and_scheduler_invariants() -> None:
    view = read("Sources/Phosphor/Views/Backup/BackupListView.swift")
    assert_contains(view, "Incremental Wi-Fi Backup (Recommended)", "Wi-Fi backup menu should recommend incremental backups")
    assert_contains(view, "Full Wi-Fi Backup (Slower)", "Wi-Fi full backup should be clearly labeled slower")
    assert_contains(view, "Full Wi-Fi Backup?", "full Wi-Fi backup should require confirmation")
    assert_contains(view, "device.connectionType == .wifi && !incremental", "full Wi-Fi preflight should only trigger for Wi-Fi full backup")

    scheduler = read("Sources/Phosphor/Services/BackupScheduler.swift")
    assert_contains(scheduler, "pyEntries.filter { $0.connectionType != \"USB\" }", "Wi-Fi-only scheduler should exclude USB entries")
    assert_contains(scheduler, "PyMobileDevice.listNetworkDevices()", "Wi-Fi scheduler should retain pymobiledevice network fallback")
    assert_contains(scheduler, "schedule.wifiOnly ? [\"-n\"] : [\"-l\"]", "libimobiledevice fallback should use network-only mode for Wi-Fi schedules")


def test_wifi_paired_device_discovery_invariants() -> None:
    manager = read("Sources/Phosphor/Services/DeviceManager.swift")
    py = read("Sources/Phosphor/Utilities/PyMobileDevice.swift")

    assert_contains(manager, "cachedNetworkDeviceEntries(forceRefresh: forceRefresh)", "device scans should merge cached network-only discovery")
    assert_contains(manager, "PyMobileDevice.listNetworkDeviceEntries()", "device manager should call pymobiledevice network discovery")
    assert_contains(manager, "Shell.runAsync(\"idevice_id\", arguments: [\"-n\"])", "libimobiledevice fallback should include network devices")
    assert_contains(manager, "mergeDeviceEntries(entries)", "device discovery should dedupe USB/network duplicate UDIDs")
    assert_contains(manager, "networkDeviceCache = nil", "zero-device scans should clear network discovery cache")
    assert_contains(manager, "let networkArgs = connectionType == .wifi ? [\"-n\"] : []", "libimobiledevice info fallback should query Wi-Fi devices with -n")

    assert_contains(py, "runAsync([\"usbmux\", \"list\", \"--usb\"])", "primary pymobiledevice scan should be USB-only so network entries are not misclassified as USB")
    assert_contains(py, "static func listNetworkDeviceEntries() async -> [DeviceEntry]", "pymobiledevice wrapper should expose network device entries with connection type")
    assert_contains(py, "parseUsbmuxDeviceEntries(from: result.output, defaultConnectionType: \"Network\")", "network usbmux parsing should mark entries as Network")
    assert_contains(py, "entry[\"Identifier\"] as? String", "network JSON parsing should support Identifier keys")
    assert_contains(py, "entry[\"UniqueDeviceID\"] as? String", "network JSON parsing should support UniqueDeviceID keys")


def test_wifi_backup_uses_network_devices() -> None:
    backup = read("Sources/Phosphor/Services/BackupManager.swift")
    view_model = read("Sources/Phosphor/ViewModels/BackupViewModel.swift")
    view = read("Sources/Phosphor/Views/Backup/BackupListView.swift")
    py = read("Sources/Phosphor/Utilities/PyMobileDevice.swift")

    assert_contains(view_model, "preferNetwork: Bool = false", "backup view model should thread preferNetwork")
    assert_contains(view, "preferNetwork: device.connectionType == .wifi", "Wi-Fi UI should request network backup path")
    assert_contains(backup, "preferNetwork: Bool = false", "backup manager should accept preferNetwork")
    assert_contains(backup, "idevicebackupArguments(udid: udid, full: true, preferNetwork: preferNetwork)", "full backup fallback should use network-aware identifiers")
    assert_contains(backup, "idevicebackupArguments(udid: udid, full: false, preferNetwork: preferNetwork)", "incremental backup fallback should use network-aware identifiers")
    assert_contains(backup, "idevicebackup2", "libimobiledevice backup fallback should remain available")
    assert_contains(backup, "if preferNetwork { args.append(\"-n\") }\n        args.append(\"backup\")", "idevicebackup2 Wi-Fi fallback should put -n before backup")


def main() -> None:
    tests = [name for name in globals() if name.startswith("test_")]
    for name in sorted(tests):
        globals()[name]()
        print(f"PASS {name}")
    print(f"PASS {len(tests)} regression checks")


if __name__ == "__main__":
    main()
