import AVFoundation
import CoreImage.CIFilterBuiltins
import SwiftUI

// MARK: Home

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @State private var conflict: Conflict?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    hero
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
                if !model.conflicts.isEmpty {
                    Section {
                        ForEach(model.conflicts) { c in
                            Button { conflict = c } label: {
                                row(icon: "exclamationmark.triangle", tint: .orange, title: c.fileName,
                                    subtitle: "Changed here and on \(model.deviceLabel(c.CopyBy))", chevron: true)
                            }
                            .foregroundStyle(.primary)
                        }
                    } header: {
                        header("Needs you")
                    }
                }
                Section {
                    NavigationLink { KeptView() } label: {
                        row(icon: "arrow.down.circle", title: "Kept downloaded", value: model.kept.isEmpty ? "None" : "\(model.kept.count)")
                    }
                    NavigationLink { HistoryBrowser() } label: {
                        row(icon: "clock.arrow.circlepath", title: "Version history")
                    }
                    NavigationLink { DevicesView() } label: {
                        row(icon: "laptopcomputer", title: "Devices", value: "\(model.devices.count)")
                    }
                    Toggle(isOn: Binding(get: { model.status.Paused }, set: { model.setPaused($0) })) {
                        row(icon: "pause", title: "Pause syncing")
                    }
                } header: {
                    header("This iPhone")
                }
                Section {
                    Link(destination: URL(string: "shareddocuments://")!) {
                        row(icon: "folder", title: "Open in Files", chevron: true)
                    }
                    .foregroundStyle(.primary)
                } footer: {
                    Text("Magpie is under Locations in the Files app. Files are encrypted on this iPhone before they leave it; your server stores them but can't read them.")
                }
            }
            .textCase(nil)
            .headerProminence(.increased)
            .navigationTitle("")
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $conflict) { c in
                ConflictSheet(conflict: c)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
            .refreshable { model.refresh() }
            .navigationDestination(isPresented: $model.showHistory) { HistoryBrowser() }
        }
    }

    private var hero: some View {
        VStack(spacing: 6) {
            Image(systemName: heroSymbol)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(Color.jade)
                .frame(width: 64, height: 64)
                .background(Circle().fill(Color.jade.opacity(0.16)))
                .contentTransition(.symbolEffect(.replace))
            Text(model.headline).font(.title3.weight(.semibold))
            Text(model.detail).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .animation(.easeOut(duration: 0.2), value: model.headline)
    }

    private var heroSymbol: String {
        if model.status.Paused { return "pause" }
        if model.status.UploadsLeft > 0 || !model.status.Ready { return "arrow.triangle.2.circlepath" }
        if !model.status.Connected { return "icloud.slash" }
        return "checkmark.icloud"
    }
}

/// A section header in sentence case. Plain List headers are drawn in
/// capitals whatever the text case says, so the lists using these also set
/// .headerProminence(.increased), which isn't.
func header(_ title: String) -> some View {
    Text(title).textCase(nil)
}

func row(icon: String, tint: Color = .jade, title: String, subtitle: String? = nil, value: String? = nil, chevron: Bool = false) -> some View {
    HStack(spacing: 12) {
        Image(systemName: icon).foregroundStyle(tint).frame(width: 24)
        VStack(alignment: .leading, spacing: 2) {
            Text(title).lineLimit(1).truncationMode(.middle).monospacedDigit()
            if let subtitle { Text(subtitle).font(.footnote).foregroundStyle(.secondary).lineLimit(2) }
        }
        Spacer(minLength: 8)
        if let value { Text(value).foregroundStyle(.secondary).monospacedDigit() }
        if chevron { Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary) }
    }
    .frame(minHeight: 32)
}

// MARK: Conflict

struct ConflictSheet: View {
    let conflict: Conflict
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var choice: Keep = .both
    @State private var working = false

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 4) {
                Text(conflict.fileName).font(.headline)
                Text("Changed on two devices while one was offline.").font(.subheadline).foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .padding(.top, 20)
            option(.both, icon: "doc.on.doc", title: "Keep both", subtitle: "\(theirs)'s copy is saved beside it")
            option(.original, icon: icon(for: mine), title: "Keep \(sentence(mine))'s", subtitle: versionLine(conflict.OriginalEntry, fallback: conflict.When))
            option(.copy, icon: icon(for: theirs), title: "Keep \(sentence(theirs))'s", subtitle: versionLine(conflict.CopyEntry, fallback: conflict.When))
            Button {
                working = true
                Task {
                    await model.resolve(conflict, keep: choice)
                    dismiss()
                }
            } label: {
                Text(buttonTitle).font(.headline).frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .tint(.primary)
            .foregroundStyle(Color(uiColor: .systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .disabled(working)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    /// The version that kept the file's name, and the one that became the copy.
    private var mine: String { model.deviceLabel(conflict.OriginalEntry?.ModifiedBy ?? "") }
    private var theirs: String { model.deviceLabel(conflict.CopyBy) }

    /// "This iPhone" reads as "this iPhone" mid-sentence.
    private func sentence(_ label: String) -> String {
        label.hasPrefix("This ") ? "this " + label.dropFirst(5) : label
    }

    private func icon(for label: String) -> String {
        if label == "This iPhone" || label.localizedCaseInsensitiveContains("iphone") { return "iphone" }
        if label.localizedCaseInsensitiveContains("ipad") { return "ipad" }
        return "laptopcomputer"
    }

    private var buttonTitle: String {
        switch choice {
        case .both: return "Keep both"
        case .original: return "Keep \(sentence(mine))'s"
        case .copy: return "Keep \(sentence(theirs))'s"
        }
    }

    private func option(_ k: Keep, icon: String, title: String, subtitle: String) -> some View {
        Button { choice = k } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).foregroundStyle(Color.jade).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    Text(subtitle).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)
            .frame(minHeight: 56)
            .background(RoundedRectangle(cornerRadius: 12).strokeBorder(choice == k ? Color.jade : Color(uiColor: .separator), lineWidth: choice == k ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: choice)
    }
}

// MARK: Kept downloaded and devices

struct KeptView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List {
            if model.kept.isEmpty {
                Text("Nothing yet. In the Files app, touch and hold a file or folder in Magpie and choose Keep Downloaded.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.kept, id: \.self) { p in
                row(icon: "arrow.down.circle.fill", title: (p as NSString).lastPathComponent, subtitle: p.contains("/") ? (p as NSString).deletingLastPathComponent : nil)
                    .swipeActions {
                        Button("Remove Download") { model.setKept(p, on: false) }.tint(.orange)
                    }
            }
        }
        .navigationTitle("Kept downloaded")
    }
}

struct DevicesView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List {
            Section {
                ForEach(model.devices) { d in
                    row(icon: d.Hub ? "server.rack" : (d.ThisOne ? "iphone" : "laptopcomputer"), title: d.Name,
                        subtitle: d.ThisOne ? "This iPhone" : d.Hub ? "Server. Holds everything encrypted and can't read it." : "Syncs through Frankfurt")
                }
            } footer: {
                Text("Files are encrypted on each device with a key the server never sees.")
            }
            Section {
                NavigationLink { AddDeviceView() } label: { row(icon: "plus", title: "Add a device") }
            }
        }
        .navigationTitle("Devices")
    }
}

// MARK: Add a device

struct AddDeviceView: View {
    @EnvironmentObject private var model: AppModel
    @State private var link: String?
    @State private var problem: String?

    var body: some View {
        VStack(spacing: 16) {
            if let link, let img = qr(link) {
                Image(uiImage: img)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 200, height: 200)
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.white))
                Text("On the new device, open Magpie and choose Join, then scan this. It works once, for 15 minutes.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                ShareLink(item: link) { Label("Share link", systemImage: "square.and.arrow.up") }
                    .frame(minHeight: 44)
            } else if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            } else {
                ProgressView().frame(height: 232)
            }
            Spacer()
        }
        .padding(24)
        .navigationTitle("Add a device")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            switch await model.invite() {
            case .success(let l): link = l
            case .failure(let f): problem = f.message
            }
        }
    }

    private func qr(_ s: String) -> UIImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(s.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: .init(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: Join

struct JoinView: View {
    @EnvironmentObject private var model: AppModel
    @State private var pasting = false
    @State private var working = false

    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 24)
            Image(systemName: "icloud")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(Color.jade)
                .frame(width: 64, height: 64)
                .background(Circle().fill(Color.jade.opacity(0.16)))
            Text("Join your Magpie").font(.title3.weight(.semibold))
            Text("Scan the code on your Mac, under Settings, Devices, Add Device.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 280)
            CameraArea { code in
                guard !working, code.hasPrefix("magpie1:") else { return }
                join(code)
            }
            .frame(height: 260)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 16)
            if let problem = model.problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.footnote)
            }
            Button("Paste a link instead") {
                if let s = UIPasteboard.general.string, !s.isEmpty { join(s) }
                else { model.problem = "Copy the link on your other device first, then tap Paste." }
            }
            .frame(minHeight: 44)
            .disabled(working)
            Spacer()
        }
        .padding(.horizontal, 16)
    }

    private func join(_ link: String) {
        working = true
        Task {
            await model.join(link: link, deviceName: AppModel.deviceName)
            working = false
        }
    }
}

/// Where the camera goes: the live view with a frame to aim with, or a plain
/// note when there's no camera or Magpie may not use it.
struct CameraArea: View {
    let found: (String) -> Void
    @State private var access = AVCaptureDevice.authorizationStatus(for: .video)
    private let hasCamera = AVCaptureDevice.default(for: .video) != nil

    var body: some View {
        ZStack {
            Color.black
            if !hasCamera && ProcessInfo.processInfo.environment["MAGPIE_SAMPLE"] == "1" {
                // Screenshots run on the Simulator, which has no camera: show the frame.
                aim
            } else if !hasCamera {
                note("This device has no camera. Paste the link instead.")
            } else if access == .authorized {
                Scanner(found: found)
                aim
            } else if access == .notDetermined {
                ProgressView().tint(.white)
            } else {
                VStack(spacing: 12) {
                    note("Magpie needs the camera to scan the code.")
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .frame(minHeight: 44)
                    .tint(.white)
                }
            }
        }
        .task {
            guard hasCamera, access == .notDetermined else { return }
            _ = await AVCaptureDevice.requestAccess(for: .video)
            access = AVCaptureDevice.authorizationStatus(for: .video)
        }
    }

    private var aim: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(.white.opacity(0.9), lineWidth: 3)
                .frame(width: 180, height: 180)
            VStack {
                Spacer()
                Text("Point at the code").font(.footnote).foregroundStyle(.white.opacity(0.8)).padding(.bottom, 12)
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.subheadline).foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center).padding(24)
    }
}

/// The camera, reading QR codes.
struct Scanner: UIViewRepresentable {
    let found: (String) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.backgroundColor = .black
        let session = AVCaptureSession()
        if let cam = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: cam), session.canAddInput(input) {
            session.addInput(input)
            let out = AVCaptureMetadataOutput()
            if session.canAddOutput(out) {
                session.addOutput(out)
                out.setMetadataObjectsDelegate(context.coordinator, queue: .main)
                out.metadataObjectTypes = [.qr]
            }
        }
        v.preview.session = session
        v.preview.videoGravity = .resizeAspectFill
        context.coordinator.session = session
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    static func dismantleUIView(_ uiView: PreviewView, coordinator: Coordinator) {
        coordinator.session?.stopRunning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let found: (String) -> Void
        var session: AVCaptureSession?
        init(found: @escaping (String) -> Void) { self.found = found }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
            if let code = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue {
                found(code)
            }
        }
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
