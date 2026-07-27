import Foundation
import SwiftUI

/// Drives app management UI for both connected devices and backup browsing.
@MainActor
final class AppViewModel: ObservableObject {

    @Published var installedApps: [InstalledApp] = []
    @Published var backupApps: [AppBundle] = []
    @Published var isLoading = false
    @Published var searchQuery = ""
    @Published var showAlert = false
    @Published var alertMessage = ""

    let appManager = AppManager()

    var filteredInstalled: [InstalledApp] {
        guard !searchQuery.isEmpty else { return installedApps }
        return installedApps.filter {
            $0.name.localizedCaseInsensitiveContains(searchQuery) ||
            $0.id.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    var filteredBackup: [AppBundle] {
        guard !searchQuery.isEmpty else { return backupApps }
        return backupApps.filter {
            $0.name.localizedCaseInsensitiveContains(searchQuery) ||
            $0.id.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    func loadInstalledApps(udid: String) async {
        isLoading = true
        await appManager.listInstalledApps(udid: udid)
        installedApps = appManager.installedApps
        isLoading = false
    }

    /// Reading a backup's app list stats every file in every app domain, which is
    /// seconds of work on a large backup. Keep it off the main actor so the list
    /// can show a spinner instead of freezing.
    func loadBackupApps(backupPath: String) async {
        isLoading = true
        defer { isLoading = false }
        await appManager.loadBackupApps(backupPath: backupPath)
        backupApps = appManager.backupApps
        // A manifest that will not open (locked, missing, corrupt) is not the same
        // as a backup with no apps in it. Say which.
        if backupApps.isEmpty, let error = appManager.lastError {
            alertMessage = error
            showAlert = true
        }
    }

    func installIPA(path: String, udid: String) async {
        let ok = await appManager.installIPA(path: path, udid: udid)
        alertMessage = ok ? "App installed" : (appManager.lastError ?? "Installation failed")
        showAlert = true
        if ok { await loadInstalledApps(udid: udid) }
    }

    func uninstall(bundleId: String, udid: String) async {
        let ok = await appManager.uninstallApp(bundleId: bundleId, udid: udid)
        alertMessage = ok ? "App removed" : (appManager.lastError ?? "Removal failed")
        showAlert = true
        if ok { await loadInstalledApps(udid: udid) }
    }

    func extractAppData(bundleId: String, backupPath: String, to dest: String) async {
        let count = await appManager.extractAppData(bundleId: bundleId, from: backupPath, to: dest)
        // A partly-skipped extraction has both a count and a reason; report both
        // rather than letting the skip notice disappear behind a success message.
        if count > 0 {
            let summary = "Extracted \(count) \(count == 1 ? "file" : "files") to \(dest)."
            alertMessage = [summary, appManager.lastError].compactMap { $0 }.joined(separator: "\n")
        } else {
            alertMessage = appManager.lastError ?? "No files extracted"
        }
        showAlert = true
    }
}
