// Draws the Mac app's panels and windows with sample data, light and dark,
// into TEST_RUNNER_SNAPSHOT_DIR (set by CI), so every screen can be looked at
// before a release.
import AppKit
import Sparkle
import SwiftUI
import XCTest

@MainActor
final class Screens: XCTestCase {
    private let updater = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil).updater

    func testScreens() throws {
        let dir = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"].map(URL.init(fileURLWithPath:))
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("magpie-screens")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = AppModel(sample: true)
        let window = Color(nsColor: .windowBackgroundColor)
        let screens: [(String, AnyView)] = [
            ("menu-panel", AnyView(MenuPanel().environmentObject(model).background(.regularMaterial))),
            ("join", AnyView(JoinView().environmentObject(AppModel(sample: false)).background(window))),
            ("conflict", AnyView(ConflictsView().environmentObject(model).background(window))),
            ("settings", AnyView(SettingsView(updater: updater).environmentObject(model))),
            ("settings-devices", AnyView(SettingsView(updater: updater, tab: .devices).environmentObject(model))),
            ("settings-updates", AnyView(SettingsView(updater: updater, tab: .updates).environmentObject(model))),
            ("add-device", AnyView(AddDeviceSheet().environmentObject(model).background(window))),
        ]
        for (name, view) in screens {
            for dark in [false, true] {
                let png = try render(view, dark: dark)
                try png.write(to: dir.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
            }
        }
    }

    private func render(_ view: AnyView, dark: Bool) throws -> Data {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        window.setContentSize(size)
        host.frame = .init(origin: .zero, size: size)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6)) // let .task and images settle
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        return png
    }
}
