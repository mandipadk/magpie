// Version history on the Mac: the window Finder's "Version History…" opens
// (versions by day, a Quick Look preview, restore in place or as a copy),
// and the Settings tab for files deleted from Magpie.
import Quartz
import SwiftUI

/// Finder's "Version History…" posts a Darwin notification after leaving the
/// file's path in the shared defaults; the menu bar icon opens the window.
final class HistoryRequests: ObservableObject {
    @Published var path: String?

    init() {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let me = Unmanaged<HistoryRequests>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async {
                    me.path = UserDefaults(suiteName: Magpie.appGroup)?.string(forKey: Magpie.historyRequest)
                }
            },
            Magpie.historyRequest as CFString, nil, .deliverImmediately)
    }
}

struct HistoryWindow: View {
    let path: String
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var versions: [OldVersion] = []
    @State private var selection: OldVersion.ID?
    @State private var preview: URL?
    @State private var loading = true
    @State private var previewing = false
    @State private var problem: String?
    @State private var working = false

    private var selected: OldVersion? { versions.first { $0.ID == selection } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(historySections(versions), id: \.title) { section in
                        Section(section.title) {
                            ForEach(section.versions) { v in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(versionTime(v.Modified)).monospacedDigit()
                                    Text(model.deviceLabel(v.ModifiedBy)).font(.caption).foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 2)
                                .tag(v.ID)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .frame(width: 210)
                Divider()
                previewArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .textBackgroundColor))
            }
            Divider()
            HStack {
                Button("Restore a Copy") { restore(asCopy: true) }
                    .disabled(selected == nil || working)
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).font(.callout).lineLimit(1)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Restore") { restore(asCopy: false) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected == nil || working)
            }
            .padding(12)
        }
        .frame(width: 640, height: 420)
        .navigationTitle((path as NSString).lastPathComponent)
        .task(id: path) { await load() }
        .onChange(of: selection) { _, _ in Task { await loadPreview() } }
    }

    @ViewBuilder private var previewArea: some View {
        if loading {
            ProgressView()
        } else if versions.isEmpty {
            VStack(spacing: 6) {
                Text("No older versions yet").font(.headline)
                Text("Each time this file changes, Frankfurt keeps the version before.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(32)
        } else if let preview {
            QuickLookView(url: preview)
        } else if previewing {
            ProgressView()
        } else if let v = selected {
            VStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(for: .init(filenameExtension: (v.Path as NSString).pathExtension) ?? .data))
                    .resizable().frame(width: 96, height: 96)
                Text(v.name)
                Text("\(friendlyTime(v.Modified)), \(humanBytes(v.Size))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    private func load() async {
        loading = true
        switch await model.versions(of: path) {
        case .success(let v):
            versions = v
            selection = v.first?.ID
        case .failure(let f):
            problem = f.message
        }
        loading = false
    }

    private func loadPreview() async {
        preview = nil
        guard let v = selected else { return }
        previewing = true
        let url = await model.previewFile(v)
        if v.ID == selection { preview = url }
        previewing = false
    }

    private func restore(asCopy: Bool) {
        guard let v = selected else { return }
        working = true
        Task {
            problem = await model.restore(v, asCopy: asCopy)
            working = false
            if problem == nil { dismiss() }
        }
    }
}

/// Quick Look, as Finder shows it.
struct QuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let v = QLPreviewView(frame: .zero, style: .normal)!
        v.autostarts = true
        v.previewItem = url as NSURL
        return v
    }

    func updateNSView(_ v: QLPreviewView, context: Context) {
        if (v.previewItem as? NSURL) as URL? != url { v.previewItem = url as NSURL }
    }
}

/// Settings > History: what the server keeps, and files deleted from Magpie.
struct HistoryTab: View {
    @EnvironmentObject private var model: AppModel
    @State private var deleted: [OldVersion] = []
    @State private var loading = true
    @State private var problem: String?
    @State private var restoring: OldVersion.ID?

    var body: some View {
        Form {
            Section {
                if loading {
                    ProgressView().frame(maxWidth: .infinity)
                } else if deleted.isEmpty {
                    Text(problem ?? "Nothing deleted lately.").foregroundStyle(.secondary)
                }
                ForEach(deleted) { v in
                    HStack(spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(for: .init(filenameExtension: (v.Path as NSString).pathExtension) ?? .data))
                            .resizable().frame(width: 20, height: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(v.name).lineLimit(1).truncationMode(.middle)
                            Text("Deleted \(friendlyTime(v.Kept).lowercasedFirst), from \(folderName(v.Path))")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("Restore") { restore(v) }
                            .disabled(restoring != nil)
                    }
                }
            } header: {
                Text("Recently deleted")
            } footer: {
                Text("Frankfurt keeps every change and every deleted file for a year, fewer versions as they age. Right-click a file in Finder and choose Version History to go back.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 260)
        .task { await load() }
    }

    private func load() async {
        loading = true
        switch await model.deletedFiles() {
        case .success(let d): deleted = d; problem = nil
        case .failure(let f): problem = f.message
        }
        loading = false
    }

    private func restore(_ v: OldVersion) {
        restoring = v.ID
        Task {
            if let err = await model.restore(v, asCopy: false) {
                problem = err
            } else {
                deleted.removeAll { $0.ID == v.ID }
            }
            restoring = nil
        }
    }

    private func folderName(_ path: String) -> String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty ? "Magpie" : (dir as NSString).lastPathComponent
    }
}
