import CoreImage.CIFilterBuiltins
import ServiceManagement
import Sparkle
import SwiftUI
import UniformTypeIdentifiers

// MARK: First run

struct JoinView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var link = ""
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // on a light tile, as in the app icon, so the ink bird reads in dark mode
            Image("Mark")
                .resizable()
                .frame(width: 40, height: 40)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(white: 0.965)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Join your Magpie").font(.title3).fontWeight(.semibold)
                Text("Paste the link from another of your devices, or the setup link from your server.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField("magpie1:join?…", text: $link)
                .textFieldStyle(.roundedBorder)
                .onSubmit(join)
            if let problem = model.problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
            Text("Your files are encrypted on this Mac before they leave it. Frankfurt stores them but can't read them.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                Button("Join", action: join)
                    .keyboardShortcut(.defaultAction)
                    .disabled(link.isEmpty || working)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear {
            if let s = UserDefaults.standard.string(forKey: "pendingJoinLink") {
                link = s
                UserDefaults.standard.removeObject(forKey: "pendingJoinLink")
            } else if let s = NSPasteboard.general.string(forType: .string), s.hasPrefix("magpie1:") { link = s }
        }
        .onChange(of: model.joined) { _, joined in
            if joined {
                dismissWindow(id: "join")
                model.revealInFinder()
            }
        }
    }

    private func join() {
        working = true
        Task {
            await model.join(link: link, deviceName: AppModel.deviceName)
            working = false
        }
    }
}

// MARK: Conflicts

struct ConflictsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if let c = model.conflicts.first {
                ConflictDialog(conflict: c)
                    .id(c.id)
                    .transition(.opacity)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle").font(.largeTitle).foregroundStyle(Color.jade)
                    Text("No conflicts").font(.headline)
                    Text("Every file has one version.").foregroundStyle(.secondary)
                }
                .padding(40)
                .frame(width: 460)
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.conflicts.first?.id)
    }
}

private struct ConflictDialog: View {
    let conflict: Conflict
    @EnvironmentObject private var model: AppModel
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(conflict.fileName) was changed on two devices").font(.headline)
                Text("Both edits happened while one of them was offline. Nothing has been lost.")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                version(title: mine, subtitle: versionLine(conflict.OriginalEntry, fallback: conflict.When))
                version(title: theirs, subtitle: versionLine(conflict.CopyEntry, fallback: conflict.When))
            }
            HStack {
                // In the order of the cards above.
                Button("Keep \(mine)’s") { resolve(.original) }
                Button("Keep \(theirs)’s") { resolve(.copy) }
                Spacer()
                Button("Keep Both") { resolve(.both) }
                    .keyboardShortcut(.defaultAction)
            }
            .disabled(working)
            if model.conflicts.count > 1 {
                Text("\(model.conflicts.count - 1) more after this one.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    /// The version that kept the file's name, and the one that became the copy.
    private var mine: String { model.deviceLabel(conflict.OriginalEntry?.ModifiedBy ?? "") }
    private var theirs: String { model.deviceLabel(conflict.CopyBy) }

    private func version(title: String, subtitle: String) -> some View {
        VStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(for: .init(filenameExtension: (conflict.Original as NSString).pathExtension) ?? .data))
                .resizable()
                .frame(width: 64, height: 64)
            Text(title).lineLimit(1)
            Text(subtitle).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    }

    private func resolve(_ keep: Keep) {
        working = true
        Task {
            await model.resolve(conflict, keep: keep)
            working = false
        }
    }
}

// MARK: Settings

struct SettingsView: View {
    enum Tab { case general, devices, history, updates }

    let updater: SPUUpdater
    @EnvironmentObject private var model: AppModel
    @State private var tab: Tab

    init(updater: SPUUpdater, tab: Tab = .general) {
        self.updater = updater
        _tab = State(initialValue: tab)
    }

    var body: some View {
        TabView(selection: $tab) {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general)
            DevicesTab()
                .tabItem { Label("Devices", systemImage: "laptopcomputer") }
                .tag(Tab.devices)
            HistoryTab()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(Tab.history)
            UpdatesTab(updater: updater)
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
                .tag(Tab.updates)
        }
        .frame(width: 520)
        .environmentObject(model)
        .onReceive(model.$showHistory.filter { $0 }) { _ in
            tab = .history
            model.showHistory = false
        }
    }
}

private struct GeneralTab: View {
    @EnvironmentObject private var model: AppModel
    @State private var atLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Toggle("Open Magpie at login", isOn: $atLogin)
                .onChange(of: atLogin) { _, on in
                    try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                }
            LabeledContent("Status", value: model.headline)
            LabeledContent("In Magpie", value: model.detail).monospacedDigit()
            if !model.kept.isEmpty {
                Section("Kept downloaded") {
                    ForEach(model.kept, id: \.self) { p in
                        HStack {
                            Text(p).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Remove Download") { model.setKept(p, on: false) }.controlSize(.small)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 260)
    }
}

private struct DevicesTab: View {
    @EnvironmentObject private var model: AppModel
    @State private var adding = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    if model.devices.isEmpty {
                        Text(model.reachable ? "Looking for your devices…" : "Connecting to Magpie…")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.devices) { d in
                        HStack(spacing: 10) {
                            Image(systemName: d.Hub ? "server.rack" : (d.Name.localizedCaseInsensitiveContains("iphone") ? "iphone" : "laptopcomputer"))
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(d.Name)
                                Text(d.ThisOne ? "This Mac" : d.Hub ? "Server. Holds everything encrypted and can't read it." : "Syncs through Frankfurt")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .contextMenu {
                            if !d.ThisOne && !d.Hub {
                                // The server decides who's in, so removal happens on the page.
                                Button("Remove on the Magpie Page…") { NSWorkspace.shared.open(Magpie.pageURL) }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            // The button lives outside the Form: a grouped Form drops a
            // section's footer when the section has no rows.
            HStack {
                Text("Files are encrypted on each device with a key the server never sees.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Add Device…") { adding = true }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .frame(minHeight: 260)
        .sheet(isPresented: $adding) { AddDeviceSheet() }
    }
}

struct AddDeviceSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var link: String?
    @State private var problem: String?
    @State private var made = Date()
    @State private var now = Date()
    @State private var copied = false
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add a device").font(.headline)
                Text("On your iPhone, open Magpie, tap Join and scan this code.").foregroundStyle(.secondary)
            }
            Group {
                if let link, let image = qrImage(link) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 168, height: 168)
                        .padding(16)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.white))
                } else if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                } else {
                    ProgressView().frame(width: 200, height: 200)
                }
            }
            .frame(maxWidth: .infinity)
            Text(expiry).font(.callout).foregroundStyle(.secondary).monospacedDigit().frame(maxWidth: .infinity)
            HStack {
                Button {
                    if let link {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(link, forType: .string)
                        copied = true
                        Task { try? await Task.sleep(for: .seconds(2)); copied = false }
                    }
                } label: { Label(copied ? "Copied" : "Copy Link", systemImage: copied ? "checkmark" : "doc.on.doc") }
                .keyboardShortcut("c", modifiers: .command)
                .disabled(link == nil)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 400)
        .task { await make() }
        .onReceive(tick) { now = $0 }
    }

    private var expiry: String {
        let left = max(0, Int(made.addingTimeInterval(15 * 60).timeIntervalSince(now)))
        return left == 0 ? "This code has expired." : String(format: "Expires in %d:%02d", left / 60, left % 60)
    }

    private func make() async {
        switch await model.invite() {
        case .success(let l): link = l; made = Date(); now = made
        case .failure(let f): problem = f.message
        }
    }

    private func qrImage(_ text: String) -> NSImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: .init(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: out)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}

private struct UpdatesTab: View {
    let updater: SPUUpdater
    @State private var auto = true

    var body: some View {
        Form {
            Toggle("Check for updates automatically", isOn: $auto)
                .onChange(of: auto) { _, on in updater.automaticallyChecksForUpdates = on }
            LabeledContent("Version", value: Bundle(for: AppModel.self).version)
            HStack {
                Spacer()
                Button("Check for Updates…") { updater.checkForUpdates() }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 160)
        .onAppear { auto = updater.automaticallyChecksForUpdates }
    }
}

extension Bundle {
    var version: String {
        let v = object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }
}
