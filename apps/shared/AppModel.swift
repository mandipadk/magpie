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
    /// Set by a magpie1:history link (the Magpie page's "Browse in Magpie").
    @Published var showHistory = false

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

    // MARK: Version history

    /// The server's old versions of a file, newest first.
    func versions(of path: String) async -> Result<[OldVersion], JoinLink.Failure> {
        if sample { return .success(Self.sampleVersions(path)) }
        return await withCheckedContinuation { cont in
            guard let proxy else { return cont.resume(returning: .failure(.init("Magpie isn't reachable right now."))) }
            proxy.versions(path: path) { data, err in
                if let data, let v = try? engineDecoder.decode([OldVersion].self, from: data) {
                    cont.resume(returning: .success(v))
                } else {
                    cont.resume(returning: .failure(.init(err ?? "Couldn't read the history.")))
                }
            }
        }
    }

    /// Deleted files the server still keeps, most recently deleted first.
    func deletedFiles() async -> Result<[OldVersion], JoinLink.Failure> {
        if sample { return .success(Self.sampleDeleted) }
        return await withCheckedContinuation { cont in
            guard let proxy else { return cont.resume(returning: .failure(.init("Magpie isn't reachable right now."))) }
            proxy.deleted { data, err in
                if let data, let v = try? engineDecoder.decode([OldVersion].self, from: data) {
                    cont.resume(returning: .success(v))
                } else {
                    cont.resume(returning: .failure(.init(err ?? "Couldn't read the history.")))
                }
            }
        }
    }

    /// A version written where this app can show it.
    func previewFile(_ v: OldVersion) async -> URL? {
        if sample { return nil }
        return await withCheckedContinuation { cont in
            guard let proxy else { return cont.resume(returning: nil) }
            proxy.preview(id: v.ID) { path, _ in cont.resume(returning: path.map(URL.init(fileURLWithPath:))) }
        }
    }

    /// Puts a version back, in place or as a copy beside the file. Returns
    /// an error message, or nil when it worked.
    func restore(_ v: OldVersion, asCopy: Bool) async -> String? {
        if sample { return nil }
        let err: String? = await withCheckedContinuation { cont in
            guard let proxy else { return cont.resume(returning: "Magpie isn't reachable right now.") }
            proxy.restore(id: v.ID, asCopy: asCopy) { cont.resume(returning: $0) }
        }
        refresh()
        return err
    }

    /// The entries of a folder, for browsing to a file's history.
    func entries(in dir: String) async -> [Entry] {
        if sample { return Self.sampleEntries(dir) }
        return await withCheckedContinuation { cont in
            guard let proxy else { return cont.resume(returning: []) }
            proxy.list(dir: dir) { data in
                let e = (try? engineDecoder.decode([Entry].self, from: data)) ?? []
                cont.resume(returning: e.sorted { ($0.Dir ? 0 : 1, $0.name.lowercased()) < ($1.Dir ? 0 : 1, $1.name.lowercased()) })
            }
        }
    }

    // MARK: Words the screens use

    /// How the screens name a device: this one is "This Mac" or "This iPhone".
    func deviceLabel(_ name: String) -> String {
        if name.isEmpty { return "Another device" }
        if name == devices.first(where: { $0.ThisOne })?.Name {
            #if os(macOS)
            return "This Mac"
            #else
            return "This iPhone"
            #endif
        }
        return name
    }

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
        // Seen from this device: the other one made the conflicting edit.
        #if os(macOS)
        let (me, other) = ("MacBook Air", "iPhone")
        #else
        let (me, other) = ("iPhone", "MacBook Air")
        #endif
        let copy = "Budget.sync-conflict-20261019-140200-ABCDEFG.numbers"
        conflicts = [Conflict(
            Copy: copy, Original: "Budget.numbers", CopyBy: other, When: now.addingTimeInterval(-240),
            CopyEntry: Entry(Path: copy, Dir: false, Size: 186_000, Modified: now.addingTimeInterval(-240), Version: "", OnHub: true, ModifiedBy: other),
            OriginalEntry: Entry(Path: "Budget.numbers", Dir: false, Size: 182_000, Modified: now.addingTimeInterval(-180), Version: "", OnHub: true, ModifiedBy: me))]
        devices = [
            DeviceInfo(ID: "A", Name: me, ThisOne: true, Hub: false),
            DeviceInfo(ID: "B", Name: other, ThisOne: false, Hub: false),
            DeviceInfo(ID: "C", Name: "Frankfurt", ThisOne: false, Hub: true),
        ]
        kept = ["Taxes 2026", "Lisbon itinerary.pages"]
    }

    static func sampleVersions(_ path: String) -> [OldVersion] {
        #if os(macOS)
        let (me, other) = ("MacBook Air", "iPhone")
        #else
        let (me, other) = ("iPhone", "MacBook Air")
        #endif
        // Relative to now, so the sample never sits in the future.
        let now = Date()
        let hour: TimeInterval = 3600, day = 86_400.0
        let rows: [(Date, String, Int64)] = [
            (now - 25 * 60, other, 418_000), (now - 3 * hour, me, 412_000),
            (now - 4 * day - 2 * hour, me, 398_000), (now - 7 * day - 5 * hour, other, 371_000),
            (now - 22 * day, me, 288_000),
        ]
        return rows.enumerated().map { i, r in
            OldVersion(ID: "sample-\(i)", Path: path, Size: r.2, Modified: r.0, ModifiedBy: r.1, Kept: r.0.addingTimeInterval(3600))
        }
    }

    static let sampleDeleted: [OldVersion] = {
        let now = Date()
        return [
            OldVersion(ID: "d1", Path: "Notes/Packing list.txt", Size: 1_200, Modified: now.addingTimeInterval(-86_400 * 2), ModifiedBy: "iPhone", Kept: now.addingTimeInterval(-3_600 * 5)),
            OldVersion(ID: "d2", Path: "Taxes 2026/Receipt 0412.pdf", Size: 182_000, Modified: now.addingTimeInterval(-86_400 * 12), ModifiedBy: "MacBook Air", Kept: now.addingTimeInterval(-86_400 * 3)),
        ]
    }()

    static func sampleEntries(_ dir: String) -> [Entry] {
        let now = Date()
        let names: [(String, Bool, Int64)] = dir.isEmpty
            ? [("Money", true, 0), ("Taxes 2026", true, 0), ("Trips", true, 0), ("Lisbon itinerary.pages", false, 412_000)]
            : [("Budget.numbers", false, 182_000), ("Savings plan.pdf", false, 96_000)]
        return names.map { n in
            Entry(Path: dir.isEmpty ? n.0 : dir + "/" + n.0, Dir: n.1, Size: n.2, Modified: now, Version: "", OnHub: true, ModifiedBy: "MacBook Air")
        }
    }
}

/// Versions grouped the way the history screens list them.
struct HistorySection {
    let title: String
    let versions: [OldVersion]
}

func historySections(_ versions: [OldVersion], now: Date = .now) -> [HistorySection] {
    let cal = Calendar.current
    func title(_ d: Date) -> String {
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        if cal.isDate(d, equalTo: now, toGranularity: .weekOfYear) { return "This week" }
        if let lastWeek = cal.date(byAdding: .weekOfYear, value: -1, to: now),
           cal.isDate(d, equalTo: lastWeek, toGranularity: .weekOfYear) { return "Last week" }
        return cal.isDate(d, equalTo: now, toGranularity: .year)
            ? d.formatted(.dateTime.month(.wide))
            : d.formatted(.dateTime.month(.wide).year())
    }
    var out: [HistorySection] = []
    for v in versions {
        let t = title(v.Modified)
        if let last = out.last, last.title == t {
            out[out.count - 1] = HistorySection(title: t, versions: last.versions + [v])
        } else {
            out.append(HistorySection(title: t, versions: [v]))
        }
    }
    return out
}

/// A version's time in its list: "11:32" today or yesterday (the section
/// says which), "Thu 15 Oct, 20:41" before that.
func versionTime(_ d: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(d) || cal.isDateInYesterday(d) { return d.formatted(date: .omitted, time: .shortened) }
    return "\(d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))), \(d.formatted(date: .omitted, time: .shortened))"
}

extension String {
    /// "Today at 14:02" reads as "today at 14:02" mid-sentence, and so do
    /// "This iPhone" and "Another device".
    var lowercasedFirst: String {
        ["Today", "Yesterday", "This ", "Another "].contains { hasPrefix($0) } ? prefix(1).lowercased() + dropFirst() : self
    }
}

extension Color {
    /// Magpie's one accent. Spelled out rather than taken from the asset
    /// catalog, because on the Mac `accentColor` follows the system setting.
    static let jade: Color = {
        #if os(macOS)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(srgbRed: 0x2f / 255, green: 0x9c / 255, blue: 0x72 / 255, alpha: 1)
                : NSColor(srgbRed: 0x1d / 255, green: 0x7a / 255, blue: 0x58 / 255, alpha: 1)
        })
        #else
        return Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0x3c / 255, green: 0xc2 / 255, blue: 0x8f / 255, alpha: 1)
                : UIColor(red: 0x1d / 255, green: 0x7a / 255, blue: 0x58 / 255, alpha: 1)
        })
        #endif
    }()
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
