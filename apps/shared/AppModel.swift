// What the Mac and iPhone apps show, fetched from the File Provider
// extension's service (the engine lives there).
import FileProvider
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var joined = ConfigStore.load() != nil
    @Published private(set) var status = EngineStatus()
    @Published private(set) var conflicts: [Conflict] = []
    @Published private(set) var devices: [DeviceInfo] = []
    @Published private(set) var kept: [String] = []
    @Published private(set) var reachable = false
    @Published var problem: String?

    private var proxy: MagpieService?
    private var connection: NSXPCConnection?
    private var timer: Timer?
    private let sample: Bool

    init(sample: Bool = ProcessInfo.processInfo.environment["MAGPIE_SAMPLE"] == "1") {
        self.sample = sample
        if sample { loadSample() }
        if ProcessInfo.processInfo.environment["MAGPIE_SAMPLE_JOIN"] == "1" { joined = false }
    }

    static let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(Magpie.domainID), displayName: "Magpie")

    // MARK: Joining

    /// Sets this device up from a magpie1: link and adds Magpie to Finder or Files.
    func join(link: String, deviceName: String) async {
        problem = nil
        do {
            let config = try JoinLink.config(from: link, deviceName: deviceName)
            guard ConfigStore.save(config) else { throw JoinLink.Failure("Couldn't save the key to the keychain.") }
            try await NSFileProviderManager.add(Self.domain)
            joined = true
            start()
        } catch {
            problem = error.localizedDescription
        }
    }

    // MARK: Live updates

    func start() {
        guard !sample, joined else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        guard !sample else { return }
        guard let proxy else {
            Task { await connect() }
            return
        }
        proxy.status { data in
            let s = (try? engineDecoder.decode(EngineStatus.self, from: data)) ?? EngineStatus()
            Task { @MainActor in self.status = s; self.reachable = true }
        }
        proxy.conflicts { data in
            let c = (try? engineDecoder.decode([Conflict].self, from: data)) ?? []
            Task { @MainActor in if c != self.conflicts { self.conflicts = c } }
        }
        proxy.devices { data in
            let d = (try? engineDecoder.decode([DeviceInfo].self, from: data)) ?? []
            Task { @MainActor in if d != self.devices { self.devices = d } }
        }
        proxy.keptDownloaded { data in
            let k = (try? JSONDecoder().decode([String].self, from: data)) ?? []
            Task { @MainActor in if k != self.kept { self.kept = k } }
        }
    }

    private func connect() async {
        do {
            guard let manager = NSFileProviderManager(for: Self.domain) else { return }
            let root = try await manager.getUserVisibleURL(for: .rootContainer)
            let services = try await FileManager.default.fileProviderServicesForItem(at: root)
            guard let service = services[Magpie.serviceName] else { return }
            let c = try await service.fileProviderConnection()
            c.remoteObjectInterface = makeServiceInterface()
            c.invalidationHandler = { [weak self] in
                Task { @MainActor in self?.proxy = nil; self?.reachable = false }
            }
            c.interruptionHandler = c.invalidationHandler
            c.resume()
            connection = c
            proxy = c.remoteObjectProxyWithErrorHandler { _ in
                Task { @MainActor in self.proxy = nil; self.reachable = false }
            } as? MagpieService
            refresh()
        } catch {
            reachable = false
        }
    }

    // MARK: Actions

    func setPaused(_ paused: Bool) {
        if sample { status.Paused = paused; return }
        proxy?.setPaused(paused) { Task { @MainActor in self.refresh() } }
    }

    func resolve(_ c: Conflict, keep: Keep) async {
        if sample { conflicts.removeAll { $0 == c }; return }
        let err: String? = await withCheckedContinuation { cont in
            guard let proxy else { return cont.resume(returning: "Magpie isn't reachable right now.") }
            proxy.resolve(copyPath: c.Copy, keep: keep.rawValue) { cont.resume(returning: $0) }
        }
        problem = err
        refresh()
    }

    func invite() async -> Result<String, JoinLink.Failure> {
        if sample { return .success("magpie1:join?sample") }
        return await withCheckedContinuation { cont in
            guard let proxy else { return cont.resume(returning: .failure(.init("Magpie isn't reachable right now."))) }
            proxy.invite { link, err in
                cont.resume(returning: link.map { .success($0) } ?? .failure(.init(err ?? "Couldn't make a code.")))
            }
        }
    }

    func setKept(_ path: String, on: Bool) {
        if sample { if on { kept.append(path) } else { kept.removeAll { $0 == path } }; return }
        proxy?.setKeepDownloaded(path: path, on: on) { err in
            Task { @MainActor in self.problem = err; self.refresh() }
        }
    }

    // MARK: Words the screens use

    var headline: String {
        if !status.Connected && !sample {
            if status.Paused { return "Paused" }
            return reachable ? "Can't reach Frankfurt" : "Starting"
        }
        if !status.Accepted { return "Waiting for the server" }
        if status.UploadsLeft > 0 { return status.UploadsLeft == 1 ? "Sending 1 file" : "Sending \(status.UploadsLeft) files" }
        if !status.Ready { return "Catching up" }
        return "Up to date"
    }

    var detail: String {
        if status.Paused { return "Nothing syncs until you resume." }
        if status.UploadsLeft > 0 { return "\(humanBytes(status.UploadBytes)) left" }
        if !status.Connected && !status.LastError.isEmpty && !sample { return "Keeps trying in the background." }
        let files = status.Files == 1 ? "1 file" : "\(status.Files.formatted()) files"
        return "\(files), \(humanBytes(status.Bytes))"
    }

    // MARK: Sample data (screenshots)

    private func loadSample() {
        joined = true
        reachable = true
        status = EngineStatus(Connected: true, Accepted: true, Ready: true, Paused: false, Files: 1284, Bytes: 6_650_000_000, DeviceID: "SAMPLE")
        let now = Date()
        conflicts = [Conflict(Copy: "Budget.sync-conflict-20261019-140200-ABCDEFG.numbers", Original: "Budget.numbers", CopyBy: "MacBook Air", When: now.addingTimeInterval(-240))]
        devices = [
            DeviceInfo(ID: "A", Name: "iPhone", ThisOne: true, Hub: false),
            DeviceInfo(ID: "B", Name: "MacBook Air", ThisOne: false, Hub: false),
            DeviceInfo(ID: "C", Name: "Frankfurt", ThisOne: false, Hub: true),
        ]
        kept = ["Taxes 2026", "Lisbon itinerary.pages"]
    }
}

/// Reads magpie1: links (made by the server or another device; see
/// lib/magpie/invite.go) into the engine's config.
enum JoinLink {
    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    static func config(from link: String, deviceName: String) throws -> String {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("magpie1:join?"), let comps = URLComponents(string: trimmed.replacingOccurrences(of: "magpie1:join?", with: "magpie1://join?")) else {
            throw Failure("That isn't a Magpie link.")
        }
        var q: [String: String] = [:]
        for item in comps.queryItems ?? [] { q[item.name] = item.value }
        guard let hub = q["h"], let addr = q["a"], let folder = q["f"], let key = q["k"], let token = q["t"],
              let keyData = Data(base64URL: key) else {
            throw Failure("That link is incomplete. Make a new one and try again.")
        }
        // The first device's link (from the server) has no password: this device makes it.
        let password = q["p"] ?? randomPassword()
        let config: [String: Any] = [
            "hubID": hub, "hubAddr": addr, "folderID": folder, "password": password,
            "deviceName": deviceName, "joinToken": token, "inviteKey": keyData.base64EncodedString(),
        ]
        let data = try JSONSerialization.data(withJSONObject: config)
        return String(decoding: data, as: UTF8.self)
    }

    private static func randomPassword() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded()
    }
}

extension Data {
    init?(base64URL s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        self.init(base64Encoded: b)
    }

    func base64URLEncoded() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
