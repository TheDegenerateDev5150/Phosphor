import Foundation
import Combine

/// Manages iOS device detection and information retrieval.
/// Primary backend: pymobiledevice3. Fallback: libimobiledevice CLI tools.
@MainActor
final class DeviceManager: ObservableObject {

    @Published var connectedDevices: [DeviceInfo] = []
    @Published var selectedDevice: DeviceInfo?
    @Published var isScanning = false
    @Published var lastError: String?
    @Published var dependencyStatus: [String: Bool] = [:]

    private var pollTimer: Timer?
    private var deviceInfoCache: [String: (device: DeviceInfo, fetchedAt: Date)] = [:]
    private var batteryInfoCache: [String: (info: [String: String], fetchedAt: Date)] = [:]
    private var pairStatusCache: [String: (isPaired: Bool, fetchedAt: Date)] = [:]
    private var networkDeviceCache: (entries: [PyMobileDevice.DeviceEntry], fetchedAt: Date)?
    private let deviceInfoRefreshInterval: TimeInterval = 30
    private let batteryInfoRefreshInterval: TimeInterval = 60
    private let pairStatusRefreshInterval: TimeInterval = 120
    private let networkDeviceRefreshInterval: TimeInterval = 30

    init() {
        checkDependencies()
    }

    // MARK: - Dependency Check

    func checkDependencies() {
        Task {
            dependencyStatus = await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    continuation.resume(returning: Shell.checkDependencies())
                }
            }
        }
    }

    var hasRequiredTools: Bool {
        dependencyStatus["pymobiledevice3"] == true ||
        (dependencyStatus["idevice_id"] == true && dependencyStatus["ideviceinfo"] == true)
    }

    var missingTools: [String] {
        dependencyStatus.filter { !$0.value }.map(\.key).sorted()
    }

    // MARK: - Device Detection

    func scanForDevices(forceRefresh: Bool = false) async {
        if isScanning {
            guard forceRefresh else { return }
            while isScanning {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        isScanning = true
        lastError = nil
        defer { isScanning = false }

        // Primary: pymobiledevice3. Merge the standard usbmux snapshot with the
        // network-only snapshot so devices already paired to this Mac over Wi-Fi
        // can appear even when no USB cable is attached.
        var entries = await PyMobileDevice.listDevicesWithType()
        entries = mergeDeviceEntries(entries + (await cachedNetworkDeviceEntries(forceRefresh: forceRefresh)))

        // Fallback: libimobiledevice. Include both USB and network-only listings.
        if entries.isEmpty {
            entries = await listLibimobiledeviceEntries()
        }

        if entries.isEmpty {
            connectedDevices = []
            selectedDevice = nil
            deviceInfoCache.removeAll()
            batteryInfoCache.removeAll()
            pairStatusCache.removeAll()
            networkDeviceCache = nil
            return
        }

        let visibleUDIDs = Set(entries.map(\.udid))
        deviceInfoCache = deviceInfoCache.filter { visibleUDIDs.contains($0.key) }
        batteryInfoCache = batteryInfoCache.filter { visibleUDIDs.contains($0.key) }
        pairStatusCache = pairStatusCache.filter { visibleUDIDs.contains($0.key) }

        var devices: [DeviceInfo] = []
        for entry in entries {
            let connType: DeviceInfo.ConnectionType = entry.connectionType == "USB" ? .usb : .wifi
            if !forceRefresh, let cached = cachedDevice(udid: entry.udid, connectionType: connType) {
                devices.append(cached)
                continue
            }
            if var device = await fetchDeviceInfo(
                udid: entry.udid,
                connectionType: connType,
                forceRefresh: forceRefresh
            ) {
                device.connectionType = connType
                deviceInfoCache[entry.udid] = (device, Date())
                devices.append(device)
            }
        }

        connectedDevices = devices
        if let selectedID = selectedDevice?.id,
           let refreshedSelection = devices.first(where: { $0.id == selectedID }) {
            selectedDevice = refreshedSelection
        } else {
            selectedDevice = devices.first
        }
    }

    private func cachedNetworkDeviceEntries(forceRefresh: Bool = false) async -> [PyMobileDevice.DeviceEntry] {
        if !forceRefresh,
           let cached = networkDeviceCache,
           Date().timeIntervalSince(cached.fetchedAt) < networkDeviceRefreshInterval {
            return cached.entries
        }
        let entries = await PyMobileDevice.listNetworkDeviceEntries()
        networkDeviceCache = (entries, Date())
        return entries
    }

    private func listLibimobiledeviceEntries() async -> [PyMobileDevice.DeviceEntry] {
        async let usbResult = Shell.runAsync("idevice_id", arguments: ["-l"])
        async let networkResult = Shell.runAsync("idevice_id", arguments: ["-n"])

        var entries: [PyMobileDevice.DeviceEntry] = []
        let usb = await usbResult
        if usb.succeeded {
            entries += parseLibimobiledeviceUDIDs(usb.output, connectionType: "USB")
        }

        let network = await networkResult
        if network.succeeded {
            entries += parseLibimobiledeviceUDIDs(network.output, connectionType: "Network")
        }

        return mergeDeviceEntries(entries)
    }

    private func parseLibimobiledeviceUDIDs(_ output: String, connectionType: String) -> [PyMobileDevice.DeviceEntry] {
        output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { PyMobileDevice.DeviceEntry(udid: $0, connectionType: connectionType) }
    }

    private func mergeDeviceEntries(_ entries: [PyMobileDevice.DeviceEntry]) -> [PyMobileDevice.DeviceEntry] {
        var byUdid: [String: PyMobileDevice.DeviceEntry] = [:]
        var orderedUdids: [String] = []

        for entry in entries {
            if byUdid[entry.udid] == nil { orderedUdids.append(entry.udid) }
            if byUdid[entry.udid]?.connectionType != "USB" || entry.connectionType == "USB" {
                byUdid[entry.udid] = entry
            }
        }

        return orderedUdids.compactMap { byUdid[$0] }
    }

    private func cachedDevice(udid: String, connectionType: DeviceInfo.ConnectionType) -> DeviceInfo? {
        guard let cached = deviceInfoCache[udid],
              Date().timeIntervalSince(cached.fetchedAt) < deviceInfoRefreshInterval else {
            return nil
        }
        var device = cached.device
        device.connectionType = connectionType
        return device
    }

    /// Fetch detailed info for a specific device.
    func fetchDeviceInfo(
        udid: String,
        connectionType: DeviceInfo.ConnectionType = .usb,
        forceRefresh: Bool = false
    ) async -> DeviceInfo? {
        // Primary: pymobiledevice3
        let info = await PyMobileDevice.deviceInfo(udid: udid)
        if !info.isEmpty {
            let batteryInfo = await cachedBatteryInfo(udid: udid, forceRefresh: forceRefresh)
            let isPaired = await cachedPymobiledevicePairStatus(udid: udid, forceRefresh: forceRefresh)

            let batteryLevel = batteryInfo["CurrentCapacity"].flatMap(Int.init)
                ?? batteryInfo["BatteryCurrentCapacity"].flatMap(Int.init)
            let chargingVal = (batteryInfo["IsCharging"] ?? batteryInfo["BatteryIsCharging"] ?? "").lowercased()
            let batteryCharging = chargingVal == "true" || chargingVal == "1"

            let isTruthy: (String?) -> Bool = { val in
                guard let v = val?.lowercased() else { return false }
                return v == "true" || v == "1" || v == "yes"
            }

            return DeviceInfo(
                id: udid,
                name: info["DeviceName"] ?? "Unknown Device",
                model: info["ProductType"] ?? "Unknown",
                modelNumber: info["ModelNumber"] ?? "",
                productType: info["ProductType"] ?? "",
                iosVersion: info["ProductVersion"] ?? "",
                buildVersion: info["BuildVersion"] ?? "",
                serialNumber: info["SerialNumber"] ?? "",
                wifiAddress: info["WiFiAddress"] ?? "",
                bluetoothAddress: info["BluetoothAddress"] ?? "",
                phoneNumber: info["PhoneNumber"],
                imei: info["InternationalMobileEquipmentIdentity"],
                batteryLevel: batteryLevel,
                batteryCharging: batteryCharging,
                totalDiskCapacity: info["TotalDiskCapacity"].flatMap(UInt64.init),
                availableDiskSpace: info["AmountDataAvailable"].flatMap(UInt64.init),
                totalDataCapacity: info["TotalDataCapacity"].flatMap(UInt64.init),
                totalSystemCapacity: info["TotalSystemCapacity"].flatMap(UInt64.init),
                isPaired: isPaired,
                isActivated: info["ActivationState"] == "Activated",
                chipID: info["ChipID"],
                boardId: info["BoardId"] ?? info["HardwareBoard"],
                hardwarePlatform: info["HardwarePlatform"],
                hardwareModel: info["HardwareModel"],
                cpuArchitecture: info["CPUArchitecture"],
                firmwareVersion: info["FirmwareVersion"],
                dieID: info["DieID"] ?? info["UniqueChipID"],
                basebandVersion: info["BasebandVersion"],
                basebandChipID: info["BasebandChipId"],
                basebandSerialNumber: info["BasebandSerialNumber"],
                basebandStatus: info["BasebandStatus"],
                activationState: info["ActivationState"],
                isSupervised: isTruthy(info["IsSupervised"]),
                productionSOC: isTruthy(info["ProductionSOC"]),
                hasPasscode: isTruthy(info["PasswordProtected"]),
                ethernetAddress: info["EthernetAddress"],
                carrierName: info["CarrierBundleInfoArray"] ?? info["PhoneNumber"].flatMap({ _ in info["SIMCarrierNetwork"] }),
                mobileCountryCode: info["MobileSubscriberCountryCode"],
                mobileNetworkCode: info["MobileSubscriberNetworkCode"],
                iccid: info["IntegratedCircuitCardIdentity"],
                connectionType: connectionType
            )
        }

        // Fallback: libimobiledevice
        let networkArgs = connectionType == .wifi ? ["-n"] : []
        let result = await Shell.runAsync("ideviceinfo", arguments: ["-u", udid] + networkArgs)
        guard result.succeeded else { return nil }

        let liInfo = result.output.parseKeyValuePairs()
        let batteryResult = await Shell.runAsync("ideviceinfo", arguments: ["-u", udid] + networkArgs + ["-q", "com.apple.mobile.battery"])
        let batteryInfo = batteryResult.output.parseKeyValuePairs()
        let diskResult = await Shell.runAsync("ideviceinfo", arguments: ["-u", udid] + networkArgs + ["-q", "com.apple.disk_usage"])
        let diskInfo = diskResult.output.parseKeyValuePairs()
        let isPaired = await cachedLibimobiledevicePairStatus(udid: udid, forceRefresh: forceRefresh)

        return DeviceInfo(
            id: udid,
            name: liInfo["DeviceName"] ?? "Unknown Device",
            model: liInfo["ProductType"] ?? "Unknown",
            modelNumber: liInfo["ModelNumber"] ?? "",
            productType: liInfo["ProductType"] ?? "",
            iosVersion: liInfo["ProductVersion"] ?? "",
            buildVersion: liInfo["BuildVersion"] ?? "",
            serialNumber: liInfo["SerialNumber"] ?? "",
            wifiAddress: liInfo["WiFiAddress"] ?? "",
            bluetoothAddress: liInfo["BluetoothAddress"] ?? "",
            phoneNumber: liInfo["PhoneNumber"],
            imei: liInfo["InternationalMobileEquipmentIdentity"],
            batteryLevel: batteryInfo["BatteryCurrentCapacity"].flatMap(Int.init),
            batteryCharging: batteryInfo["BatteryIsCharging"].map { $0 == "true" },
            totalDiskCapacity: diskInfo["TotalDiskCapacity"].flatMap(UInt64.init),
            availableDiskSpace: diskInfo["AmountDataAvailable"].flatMap(UInt64.init),
            totalDataCapacity: diskInfo["TotalDataCapacity"].flatMap(UInt64.init),
            totalSystemCapacity: diskInfo["TotalSystemCapacity"].flatMap(UInt64.init),
            isPaired: isPaired,
            isActivated: liInfo["ActivationState"] == "Activated",
            basebandVersion: liInfo["BasebandVersion"],
            activationState: liInfo["ActivationState"],
            connectionType: connectionType
        )
    }

    private func cachedBatteryInfo(udid: String, forceRefresh: Bool = false) async -> [String: String] {
        if !forceRefresh,
           let cached = batteryInfoCache[udid],
           Date().timeIntervalSince(cached.fetchedAt) < batteryInfoRefreshInterval {
            return cached.info
        }
        let info = await PyMobileDevice.batteryInfo(udid: udid)
        batteryInfoCache[udid] = (info, Date())
        return info
    }

    private func cachedPymobiledevicePairStatus(udid: String, forceRefresh: Bool = false) async -> Bool {
        if !forceRefresh,
           let cached = pairStatusCache[udid],
           Date().timeIntervalSince(cached.fetchedAt) < pairStatusRefreshInterval {
            return cached.isPaired
        }
        let isPaired = await PyMobileDevice.validatePair(udid: udid)
        pairStatusCache[udid] = (isPaired, Date())
        return isPaired
    }

    private func cachedLibimobiledevicePairStatus(udid: String, forceRefresh: Bool = false) async -> Bool {
        if !forceRefresh,
           let cached = pairStatusCache[udid],
           Date().timeIntervalSince(cached.fetchedAt) < pairStatusRefreshInterval {
            return cached.isPaired
        }
        let result = await Shell.runAsync("idevicepair", arguments: ["-u", udid, "validate"])
        pairStatusCache[udid] = (result.succeeded, Date())
        return result.succeeded
    }

    /// Pair with a device.
    func pairDevice(udid: String) async -> Bool {
        pairStatusCache.removeValue(forKey: udid)
        // Primary: pymobiledevice3
        if await PyMobileDevice.pair(udid: udid) {
            pairStatusCache[udid] = (true, Date())
            deviceInfoCache.removeValue(forKey: udid)
            return true
        }
        // Fallback
        let result = await Shell.runAsync("idevicepair", arguments: ["-u", udid, "pair"])
        if result.succeeded {
            pairStatusCache[udid] = (true, Date())
            deviceInfoCache.removeValue(forKey: udid)
        } else {
            lastError = result.stderr.nilIfEmpty ?? result.output
        }
        return result.succeeded
    }

    /// Unpair a device.
    func unpairDevice(udid: String) async -> Bool {
        pairStatusCache.removeValue(forKey: udid)
        var success = await PyMobileDevice.unpair(udid: udid)
        if !success {
            success = (await Shell.runAsync("idevicepair", arguments: ["-u", udid, "unpair"])).succeeded
        }
        if success {
            pairStatusCache[udid] = (false, Date())
            deviceInfoCache.removeValue(forKey: udid)
        }
        return success
    }

    /// Get device name.
    func getDeviceName(udid: String) async -> String? {
        if let name = await PyMobileDevice.deviceName(udid: udid) { return name }
        let result = await Shell.runAsync("idevicename", arguments: ["-u", udid])
        return result.succeeded ? result.output : nil
    }

    /// Set device name.
    func setDeviceName(udid: String, name: String) async -> Bool {
        let result = await Shell.runAsync("idevicename", arguments: ["-u", udid, name])
        return result.succeeded
    }

    /// Take a screenshot of the device.
    func takeScreenshot(udid: String, saveTo path: String) async -> Bool {
        // Primary: pymobiledevice3
        if await PyMobileDevice.screenshot(udid: udid, saveTo: path) { return true }
        // Fallback
        return (await Shell.runAsync("idevicescreenshot", arguments: ["-u", udid, path])).succeeded
    }

    // MARK: - Polling

    func startPolling(interval: TimeInterval = 3.0) {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.scanForDevices()
            }
        }
        Task { await scanForDevices() }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
