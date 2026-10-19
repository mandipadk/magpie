// Magpie for Mac: a menu bar item (status, pause, conflicts), Magpie in the
// Finder sidebar (the File Provider extension), and Settings. No Dock icon.
import FileProvider
import Sparkle
import SwiftUI

#if !SCREENS
@main
#endif
struct MagpieApp: App {
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

/// The menu bar icon. It is drawn at launch, so it also opens the first-run
/// window when this Mac hasn't joined a Magpie yet.
struct MenuLabel: View {
    let symbol: String
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var history: HistoryRequests
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: symbol)
            .accessibilityLabel("Magpie, \(model.headline)")
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
