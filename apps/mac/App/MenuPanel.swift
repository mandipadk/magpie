import SwiftUI

/// The panel under the menu bar icon: status, pause, what needs the owner,
/// the devices, and the usual menu items.
struct MenuPanel: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.joined {
                header
                Divider().padding(.horizontal, 14).padding(.vertical, 5)
                HStack {
                    Label("Pause syncing", systemImage: "pause")
                    Spacer()
                    Toggle("Pause syncing", isOn: Binding(get: { model.status.Paused }, set: { model.setPaused($0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                if model.finderOff {
                    Divider().padding(.horizontal, 14).padding(.vertical, 5)
                    row(icon: "exclamationmark.triangle", tint: .orange, title: "Magpie is off in Finder",
                        subtitle: "Click Enable at the top of the Magpie window") {
                        Button("Open…") { model.revealInFinder() }
                            .controlSize(.small)
                    }
                }
                if !model.conflicts.isEmpty {
                    Divider().padding(.horizontal, 14).padding(.vertical, 5)
                    section("Needs you")
                    ForEach(model.conflicts.prefix(3)) { c in
                        row(icon: "exclamationmark.triangle", tint: .orange, title: c.fileName,
                            subtitle: "Changed on \(model.deviceLabel(c.CopyBy)) and here") {
                            Button("Resolve…") { open("conflicts") }
                                .controlSize(.small)
                        }
                    }
                }
                if !otherDevices.isEmpty {
                    Divider().padding(.horizontal, 14).padding(.vertical, 5)
                    section("Devices")
                    ForEach(otherDevices) { d in
                        row(icon: d.Hub ? "server.rack" : (d.Name.localizedCaseInsensitiveContains("iphone") ? "iphone" : "laptopcomputer"),
                            title: d.Name, subtitle: d.Hub ? "Server, encrypted" : "Syncs through Frankfurt") {
                            if d.Hub {
                                Text(model.status.Connected ? "Connected" : "Not connected")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Magpie isn't set up on this Mac").font(.headline)
                    Text("Join with a link from your server or another device.")
                        .foregroundStyle(.secondary)
                    Button("Join…") { open("join") }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(14)
            }
            Divider().padding(.horizontal, 14).padding(.vertical, 5)
            if model.joined {
                item("Open Magpie in Finder") { model.revealInFinder() }
                item("Add Device…") { open("add-device") }
            }
            item("Settings…", key: ",") { openSettings(); NSApp.activate(ignoringOtherApps: true) }
            item("Quit Magpie", key: "q") { NSApp.terminate(nil) }
        }
        .padding(.vertical, 6)
        .frame(width: 320)
        .onAppear { model.refresh(); model.checkFinder() }
    }

    private var otherDevices: [DeviceInfo] {
        model.devices.filter { !$0.ThisOne }.sorted { $0.Hub && !$1.Hub }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(model.status.Paused ? Color.secondary.opacity(0.4) : model.conflicts.isEmpty ? Color.jade : Color.orange)
                Image(systemName: headerSymbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.headline).fontWeight(.semibold)
                Text(model.detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .animation(.easeOut(duration: 0.2), value: model.headline)
    }

    private var headerSymbol: String {
        if model.status.Paused { return "pause.fill" }
        if model.status.UploadsLeft > 0 || !model.status.Ready { return "arrow.triangle.2.circlepath" }
        if !model.status.Connected { return "icloud.slash" }
        if !model.conflicts.isEmpty { return "exclamationmark" }
        return "checkmark"
    }

    private func section(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .padding(.bottom, 2)
    }

    private func row<Trailing: View>(icon: String, tint: Color = .secondary, title: String, subtitle: String,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint).frame(width: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).lineLimit(1).truncationMode(.middle)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }

    private func item(_ title: String, key: KeyEquivalent? = nil, action: @escaping () -> Void) -> some View {
        MenuItemButton(title: title, key: key, action: action)
    }

    private func open(_ id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// A plain menu-style row that highlights on hover, like a real menu item.
private struct MenuItemButton: View {
    let title: String
    let key: KeyEquivalent?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if let key {
                    Text("⌘" + String(key.character).uppercased()).foregroundStyle(hover ? .white.opacity(0.75) : .secondary)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .foregroundStyle(hover ? .white : .primary)
            .background(RoundedRectangle(cornerRadius: 5).fill(hover ? Color.accentColor : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 5)
        .onHover { hover = $0 }
        .modifier(OptionalShortcut(key: key))
    }
}

private struct OptionalShortcut: ViewModifier {
    let key: KeyEquivalent?
    func body(content: Content) -> some View {
        if let key { content.keyboardShortcut(key, modifiers: .command) } else { content }
    }
}
