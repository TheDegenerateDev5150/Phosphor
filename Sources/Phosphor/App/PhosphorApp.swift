import SwiftUI
import AppKit

final class PhosphorAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Avoid resurrecting a broken 0-window restoration state. SwiftUI owns
        // normal window creation; this only nudges AppKit when launch/reopen
        // completes with no visible app window.
        UserDefaults.standard.set(true, forKey: "ApplePersistenceIgnoreState")
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        ensureWindowSoon()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { ensureWindowSoon() }
        return true
    }

    private func ensureWindowSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            let hasVisibleWindow = NSApp.windows.contains { $0.isVisible && !$0.isMiniaturized }
            guard !hasVisibleWindow else { return }
            NSApp.sendAction(#selector(NSApplication.newWindowForTab(_:)), to: nil, from: nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

@main
struct PhosphorApp: App {

    @NSApplicationDelegateAdaptor(PhosphorAppDelegate.self) private var appDelegate
    @StateObject private var deviceVM = DeviceViewModel()
    @StateObject private var backupVM = BackupViewModel()
    @StateObject private var scheduler = BackupScheduler()
    @AppStorage("phosphor.hasCompletedOnboarding") private var hasCompletedOnboarding = false

    init() {
        // Pre-1.0.4 users defaulted to Apple's MobileSync directory implicitly.
        // Pin that choice explicitly so they don't lose sight of existing backups
        // when the default flips to ~/Documents/Phosphor Backups.
        BackupManager.migrateLegacyBackupDirectory()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(deviceVM)
                .environmentObject(backupVM)
                .frame(minWidth: 960, minHeight: 640)
                .onAppear {
                    deviceVM.deviceManager.startPolling(interval: 4.0)
                    backupVM.loadBackups()
                    scheduler.startMonitoring()
                }
                .sheet(isPresented: showOnboarding) {
                    OnboardingView(isPresented: showOnboarding)
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandMenu("Device") {
                Button("Refresh Devices") {
                    Task { await deviceVM.refresh() }
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("Pair Device") {
                    Task { await deviceVM.pair() }
                }
                .disabled(deviceVM.selectedDevice == nil)

                Divider()

                Button("Take Screenshot") {
                    Task { let _ = await deviceVM.takeScreenshot() }
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(deviceVM.selectedDevice == nil)
            }

            CommandMenu("Backup") {
                Button("New Backup") {
                    guard let udid = deviceVM.selectedDevice?.id else { return }
                    Task { await backupVM.createBackup(udid: udid) }
                }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(deviceVM.selectedDevice == nil)

                Button("Refresh Backups") {
                    backupVM.loadBackups()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
        }
    }

    private var showOnboarding: Binding<Bool> {
        Binding(
            get: { !hasCompletedOnboarding },
            set: { if !$0 { hasCompletedOnboarding = true } }
        )
    }
}
