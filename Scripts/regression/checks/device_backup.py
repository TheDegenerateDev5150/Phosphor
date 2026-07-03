from __future__ import annotations

import re
from pathlib import Path


def read(root: Path, rel: str) -> str:
    return (root / rel).read_text()


def assert_contains(text: str, needle: str, message: str) -> None:
    assert needle in text, message


def assert_not_contains(text: str, needle: str, message: str) -> None:
    assert needle not in text, message


def test_pymobiledevice_queries_usb_and_network_before_fallback(root: Path) -> None:
    src = read(root, "Sources/Phosphor/Utilities/PyMobileDevice.swift")
    assert_contains(src, 'runAsync(["usbmux", "list", "--usb"]', "device discovery must explicitly query USB devices")
    assert_contains(src, 'runAsync(["usbmux", "list", "--network"]', "device discovery must explicitly query network devices")
    assert_contains(src, 'runAsync(["usbmux", "list"])', "device discovery should retain default usbmux fallback")
    assert_contains(src, 'entry["ConnectionType"] as? String', "usbmux JSON parser should inspect top-level ConnectionType")
    assert_contains(src, '(entry["Properties"] as? [String: Any])?["ConnectionType"] as? String', "usbmux JSON parser should inspect nested Properties.ConnectionType")


def test_bonjour_finder_visible_devices_are_discovery_hints(root: Path) -> None:
    src = read(root, "Sources/Phosphor/Utilities/PyMobileDevice.swift")
    assert_contains(src, "struct BonjourDevice", "Bonjour-discovered devices should use a separate hint model")
    assert_contains(src, '"/usr/bin/dns-sd"', "Bonjour fallback should use macOS dns-sd directly")
    assert_contains(src, '"_apple-mobdev2._tcp"', "Bonjour fallback should browse Apple's MobileDevice service")
    assert_contains(src, "parseBonjourBrowseOutput", "Bonjour browse output should be parsed explicitly")
    assert_contains(src, "parseBonjourHost", "Bonjour resolve output should preserve the advertised host")
    assert_contains(src, "not the device UDID", "Bonjour identifiers must not be treated as backup-capable UDIDs")

    manager = read(root, "Sources/Phosphor/Services/DeviceManager.swift")
    assert_contains(manager, "nearbyWirelessDevices", "DeviceManager should publish Finder-visible wireless hints")
    assert_contains(manager, "cachedBonjourDevices", "Bonjour discovery should be cached to avoid polling dns-sd constantly")
    assert_contains(manager, "connectedDevices = []", "Bonjour-only devices should not be mixed into backup-capable devices")

    view = read(root, "Sources/Phosphor/Views/Device/DeviceOverviewView.swift")
    assert_contains(view, "Finder-visible devices", "Empty device state should disclose devices Finder can see")
    assert_contains(view, "cannot open a usbmux connection", "UI should explain why Finder visibility is not enough")


def test_mobdev2_wireless_discovery_is_a_non_backup_hint(root: Path) -> None:
    src = read(root, "Sources/Phosphor/Utilities/PyMobileDevice.swift")
    assert_contains(src, '["bonjour", "mobdev2", "--timeout", "3"]', "wireless discovery should query pymobiledevice3 mobdev2 with a bounded browse timeout")
    assert_contains(src, "parseMobdev2DeviceEntries", "mobdev2 JSON should be parsed into typed device entries")
    assert_contains(src, 'entry["UniqueDeviceID"] as? String', "mobdev2 discovery must use the real device UDID")
    assert_contains(src, 'discoveryMethod: "mobdev2"', "mobdev2 entries should preserve their discovery method")
    assert_contains(src, "mobdev2Devices.map", "mobdev2 metadata should feed Finder-visible nearby-device hints")
    assert_contains(src, "still a discovery hint", "mobdev2 devices should not be treated as backup-capable targets")
    assert_not_contains(src, 'args.append("--mobdev2")', "pymobiledevice3 backup must not invoke interactive mobdev2 in a non-TTY app")

    manager = read(root, "Sources/Phosphor/Services/DeviceManager.swift")
    assert_contains(manager, "cachedBonjourDevices", "DeviceManager should show mobdev2/Finder-visible devices as nearby hints")
    assert_contains(manager, "connectedDevices = []", "mobdev2-only devices should not be mixed into backup-capable devices")

    backup = read(root, "Sources/Phosphor/Services/BackupManager.swift")
    assert_contains(backup, "preferNetwork: preferNetwork", "BackupManager should thread Wi-Fi preference into pymobiledevice3 backup")


def test_device_entry_merge_prefers_usb_without_dropping_network_only(root: Path) -> None:
    src = read(root, "Sources/Phosphor/Utilities/PyMobileDevice.swift")
    merge = re.search(r"private static func mergeDeviceEntries\(_ entries: \[DeviceEntry\]\).*?\n    \}", src, re.S)
    assert merge is not None, "PyMobileDevice.mergeDeviceEntries should exist"
    body = merge.group(0)
    assert_contains(body, "orderedUdids", "merge should preserve stable discovery order")
    assert_contains(body, 'connectionType != "USB" || entry.connectionType == "USB"', "merge should prefer USB when both transports are visible")

    manager = read(root, "Sources/Phosphor/Services/DeviceManager.swift")
    assert_contains(manager, "deviceInfoCache.removeAll()", "zero-device scans should clear stale device cache")
    assert_contains(manager, "networkDeviceCache = nil", "zero-device scans should clear stale network-device cache")


def test_wifi_schedules_use_network_discovery_and_network_backup_flag(root: Path) -> None:
    scheduler = read(root, "Sources/Phosphor/Services/BackupScheduler.swift")
    assert_contains(scheduler, "pyEntries.filter { $0.connectionType != \"USB\" }", "Wi-Fi-only schedules should filter out USB pymobiledevice entries")
    assert_contains(scheduler, "PyMobileDevice.listNetworkDevices()", "Wi-Fi-only schedules should probe network devices explicitly")
    assert_contains(scheduler, 'let fallbackArgs = schedule.wifiOnly ? ["-n"] : ["-l"]', "Wi-Fi-only fallback should use idevice_id -n")
    assert_contains(scheduler, "createIncrementalBackup(udid: udid, preferNetwork: preferNetwork)", "scheduled incremental backups should preserve network preference")
    assert_contains(scheduler, "createBackup(udid: udid, preferNetwork: preferNetwork)", "scheduled full backups should preserve network preference")


def test_idevicebackup2_network_argument_order_is_before_backup_subcommand(root: Path) -> None:
    manager = read(root, "Sources/Phosphor/Services/BackupManager.swift")
    match = re.search(r"private func idevicebackupArguments\(.*?\) -> \[String\] \{(?P<body>.*?)\n    \}", manager, re.S)
    assert match is not None, "idevicebackupArguments should centralize fallback argument order"
    body = match.group("body")
    assert_contains(body, 'var args = ["-u", udid]', "idevicebackup2 should start with the target UDID")
    assert body.index('if preferNetwork { args.append("-n") }') < body.index('args.append("backup")'), "idevicebackup2 -n must come before backup subcommand"
    assert body.index('args.append("backup")') < body.index('if full { args.append("--full") }'), "backup subcommand should come before --full"
