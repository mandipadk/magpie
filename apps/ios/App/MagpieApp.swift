// Magpie for iPhone: the files live in the Files app (the File Provider
// extension); this app shows status, what needs you, and adds devices.
import SwiftUI
import UIKit

@main
struct MagpieApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            Group {
                if model.joined {
                    HomeView()
                } else {
                    JoinView()
                }
            }
            .environmentObject(model)
            .tint(Color.jade)
            .onOpenURL { url in
                guard url.scheme == "magpie1", !model.joined else { return }
                Task { await model.join(link: url.absoluteString, deviceName: AppModel.deviceName) }
            }
            .onChange(of: phase) { _, p in
                if p == .active { model.start() } else { model.stop() }
            }
        }
    }
}

extension AppModel {
    static var deviceName: String {
        let n = UIDevice.current.name
        return n.isEmpty ? "iPhone" : n
    }
}
