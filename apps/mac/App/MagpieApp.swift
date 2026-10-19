// Magpie for Mac: a menu bar item (status, pause, conflicts), Magpie in the
// Finder sidebar (the File Provider extension), and Settings. No Dock icon.
import FileProvider
import Sparkle
import SwiftUI

#if !SCREENS
@main
#endif
struct MagpieApp: App {
    @NSApplicationDelegateAdaptor private var links: LinkDelegate
    @StateObject private var model = AppModel()
    @StateObject private var history = HistoryRequests()
    private let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    var body: some Scene {
        MenuBarExtra {
            MenuPanel()
                .environmentObject(model)
        } label: {
            MenuLabel(symbol: menuSymbol)
                .environmentObject(model)
                .environmentObject(history)
        }
        .menuBarExtraStyle(.window)

        Window("Join your Magpie", id: "join") {
            JoinView()
                .environmentObject(model)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        WindowGroup("Version History", id: "history", for: String.self) { $path in
            HistoryWindow(path: path ?? "")
                .environmentObject(model)
        }
        .windowResizability(.contentSize)

        Window("Add a Device", id: "add-device") {
            AddDeviceSheet()
                .environmentObject(model)
        }
        .windowResizability(.contentSize)

        Window("Conflicts", id: "conflicts") {
            ConflictsView()
                .environmentObject(model)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView(updater: updater.updater)
                .environmentObject(model)
        }
    }

    private var menuSymbol: String {
        if !model.joined { return "icloud.slash" }
        if model.status.Paused { return "pause.circle" }
        if !model.conflicts.isEmpty { return "exclamationmark.icloud" }
        if model.status.UploadsLeft > 0 || (model.status.Connected && !model.status.Ready) { return "arrow.triangle.2.circlepath.icloud" }
        if !model.status.Connected { return "icloud.slash" }
        return "checkmark.icloud"
    }
}

/// magpie1: links. A history link (from the Magpie page) opens Settings at
/// History; a join link opens the join window with it filled in.
final class LinkDelegate: NSObject, NSApplicationDelegate {
    static let open = Notification.Name("dev.mandip.magpie.link")

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "magpie1" {
            NotificationCenter.default.post(name: Self.open, object: url.absoluteString)
        }
    }
}

/// The menu bar icon. It is drawn at launch, so it also opens the first-run
/// window when this Mac hasn't joined a Magpie yet.
struct MenuLabel: View {
    let symbol: String
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var history: HistoryRequests
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Image(systemName: symbol)
            .onReceive(NotificationCenter.default.publisher(for: LinkDelegate.open)) { note in
                guard let link = note.object as? String else { return }
                if link == Magpie.historyLink, model.joined {
                    model.showHistory = true
                    openSettings()
                } else if link == Magpie.addDeviceLink, model.joined {
                    openWindow(id: "add-device")
                } else if link.hasPrefix("magpie1:join?"), !model.joined {
                    UserDefaults.standard.set(link, forKey: "pendingJoinLink")
                    openWindow(id: "join")
                }
                NSApp.activate(ignoringOtherApps: true)
            }
            .accessibilityLabel(model.conflicts.isEmpty ? "Magpie, \(model.headline)"
                : "Magpie, \(model.conflicts.count == 1 ? "a conflict needs you" : "\(model.conflicts.count) conflicts need you")")
            .onReceive(history.$path.compactMap { $0 }) { path in
                history.path = nil
                openWindow(id: "history", value: path)
                NSApp.activate(ignoringOtherApps: true)
            }
            .task {
                if model.joined {
                    model.start()
                } else {
                    openWindow(id: "join")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
    }
}

extension AppModel {
    /// Shows Magpie in a Finder window.
    func revealInFinder() {
        Task {
            guard let manager = NSFileProviderManager(for: AppModel.domain),
                  let url = try? await manager.getUserVisibleURL(for: .rootContainer) else { return }
            NSWorkspace.shared.open(url)
        }
    }

    static var deviceName: String { Host.current().localizedName ?? "Mac" }
}
