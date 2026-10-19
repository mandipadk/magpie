// Version history on the iPhone: browse to a file, see what the server
// kept of it, preview a version and put it back, or bring back a file that
// was deleted.
import QuickLook
import SwiftUI

struct HistoryBrowser: View {
    var dir = ""
    @EnvironmentObject private var model: AppModel
    @State private var entries: [Entry] = []
    @State private var deleted: [OldVersion] = []
    @State private var picked: OldVersion?

    var body: some View {
        List {
            if dir.isEmpty && !deleted.isEmpty {
                Section {
                    ForEach(deleted) { v in
                        Button { picked = v } label: {
                            row(icon: "doc", tint: .secondary, title: v.name,
                                subtitle: "In \(folderName(v.Path)), deleted \(friendlyTime(v.Kept).lowercasedFirst)", chevron: true)
                        }
                        .foregroundStyle(.primary)
                    }
                } header: {
                    header("Recently deleted")
                }
            }
            Section {
                ForEach(entries, id: \.Path) { e in
                    NavigationLink {
                        if e.Dir { HistoryBrowser(dir: e.Path) } else { VersionsView(path: e.Path) }
                    } label: {
                        row(icon: e.Dir ? "folder" : "doc", title: e.name)
                    }
                }
            } header: {
                if dir.isEmpty { header("Files") }
            } footer: {
                if dir.isEmpty {
                    Text("Frankfurt keeps every change and every deleted file for a year, fewer versions as they age.")
                }
            }
        }
        .textCase(nil)
        .headerProminence(.increased)
        .navigationTitle(dir.isEmpty ? "Version history" : (dir as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            entries = await model.entries(in: dir)
            if dir.isEmpty, case .success(let d) = await model.deletedFiles() { deleted = d }
        }
        .sheet(item: $picked) { v in
            VersionSheet(version: v, deleted: true) { deleted.removeAll { $0.ID == v.ID } }
        }
    }
}

struct VersionsView: View {
    let path: String
    @EnvironmentObject private var model: AppModel
    @State private var versions: [OldVersion] = []
    @State private var loading = true
    @State private var problem: String?
    @State private var picked: OldVersion?

    var body: some View {
        List {
            if loading {
                ProgressView().frame(maxWidth: .infinity)
            } else if versions.isEmpty {
                Text(problem ?? "No older versions yet. Each time this file changes, Frankfurt keeps the version before.")
                    .foregroundStyle(.secondary)
            }
            ForEach(historySections(versions), id: \.title) { section in
                Section {
                    ForEach(section.versions) { v in
                        Button { picked = v } label: {
                            row(icon: deviceIcon(model.deviceLabel(v.ModifiedBy)), title: versionTime(v.Modified),
                                subtitle: model.deviceLabel(v.ModifiedBy), value: humanBytes(v.Size), chevron: true)
                        }
                        .foregroundStyle(.primary)
                    }
                } header: {
                    header(section.title)
                }
            }
        }
        .textCase(nil)
        .headerProminence(.increased)
        .navigationTitle((path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            switch await model.versions(of: path) {
            case .success(let v): versions = v
            case .failure(let f): problem = f.message
            }
            loading = false
        }
        .sheet(item: $picked) { v in VersionSheet(version: v, deleted: false) {} }
    }
}

/// One version: a preview, and putting it back.
struct VersionSheet: View {
    let version: OldVersion
    let deleted: Bool
    let restored: () -> Void
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var preview: URL?
    @State private var loading = true
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Group {
                    if let preview {
                        QuickLookPreview(url: preview)
                    } else if loading {
                        ProgressView()
                    } else {
                        Image(systemName: "doc").font(.system(size: 48)).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: .secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                VStack(spacing: 2) {
                    Text("\(friendlyTime(version.Modified)) on \(model.deviceLabel(version.ModifiedBy).lowercasedFirst)")
                        .font(.subheadline)
                    Text(humanBytes(version.Size)).font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                }
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.footnote)
                }
                Button { restore(asCopy: false) } label: {
                    Text(deleted ? "Put it back" : "Restore this version").font(.headline).frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .tint(.primary)
                .foregroundStyle(Color(uiColor: .systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .disabled(working)
                if !deleted {
                    Button("Restore as a copy") { restore(asCopy: true) }
                        .frame(minHeight: 44)
                        .disabled(working)
                }
            }
            .padding(16)
            .navigationTitle(version.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDragIndicator(.visible)
        .task {
            preview = await model.previewFile(version)
            loading = false
        }
    }

    private func restore(asCopy: Bool) {
        working = true
        Task {
            problem = await model.restore(version, asCopy: asCopy)
            working = false
            if problem == nil {
                restored()
                dismiss()
            }
        }
    }
}

/// Quick Look for one file.
struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let c = QLPreviewController()
        c.dataSource = context.coordinator
        return c
    }

    func updateUIViewController(_ c: QLPreviewController, context: Context) {
        context.coordinator.url = url
        c.reloadData()
    }

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}

/// "In Notes": the folder a file was in.
func folderName(_ path: String) -> String {
    let dir = (path as NSString).deletingLastPathComponent
    return dir.isEmpty ? "Magpie" : (dir as NSString).lastPathComponent
}

/// The glyph for whoever saved a version.
func deviceIcon(_ label: String) -> String {
    if label.localizedCaseInsensitiveContains("iphone") { return "iphone" }
    if label.localizedCaseInsensitiveContains("ipad") { return "ipad" }
    return "laptopcomputer"
}
