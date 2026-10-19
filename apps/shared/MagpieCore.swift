// The engine's types as the apps see them, and where the apps keep the
// device's Magpie config (the keychain, shared by the app and its File
// Provider extension).
import FileProvider
import Foundation
import Security

enum Magpie {
    /// Shared between the app and the extension.
    static let appGroup: String = {
        #if os(macOS)
        return "UK74VYMUP7.dev.mandip.magpie"
        #else
        return "group.dev.mandip.magpie"
        #endif
    }()
    static let keychainGroup = "UK74VYMUP7.dev.mandip.magpie.shared"
    static let domainID = "magpie"
    static let serviceName = NSFileProviderServiceName("dev.mandip.magpie.service")
    /// Finder's "Version History…" asks the app (Mac): the path goes in the
    /// shared defaults under this key, then a Darwin notification of this name.
    static let historyRequest = "dev.mandip.magpie.history"
    /// Opens version history in the app; the Magpie page links to it.
    static let historyLink = "magpie1:history"
    /// Opens Add Device (the Mac's invite window).
    static let addDeviceLink = "magpie1:add-device"
    /// The owner's Magpie page: the server's status, and removing devices.
    static let pageURL = URL(string: "https://magpie.mandip.dev")!
    /// Who may connect to the extension's service (Mac): only the Magpie app,
    /// signed by this team. Invites carry the folder's password and invite key.
    /// apps/mac/check-app.sh checks the shipped app against it.
    static let appRequirement = #"anchor apple generic and certificate leaf[subject.OU] = "UK74VYMUP7" and identifier "dev.mandip.magpie""#

    static var containerURL: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            ?? FileManager.default.temporaryDirectory
    }
    /// The engine's state: device certificate, index, outbox. Only the
    /// File Provider extension opens it.
    static var engineDir: URL { containerURL.appendingPathComponent("engine", isDirectory: true) }
}

struct Entry: Codable, Hashable {
    var Path: String
    var Dir: Bool
    var Size: Int64
    var Modified: Date
    var Version: String
    var OnHub: Bool
    var ModifiedBy: String

    var name: String { (Path as NSString).lastPathComponent }
    var parent: String {
        let p = (Path as NSString).deletingLastPathComponent
        return p == "/" ? "" : p
    }
}

/// One old version of a file, kept by the server (lib/magpie/history.go).
struct OldVersion: Codable, Hashable, Identifiable {
    var ID: String
    var Path: String
    var Size: Int64
    var Modified: Date
    var ModifiedBy: String
    /// When the server put it aside: the file was replaced or deleted then.
    var Kept: Date
    var id: String { self.ID }
    var name: String { (Path as NSString).lastPathComponent }
}

/// The engine's errors in words for the screens.
func friendlyError(_ error: Error) -> String {
    let msg = (error as NSError).localizedDescription
    if msg.hasPrefix("offline:") { return "Can't reach Frankfurt right now. Try again in a moment." }
    if msg.hasPrefix("paused:") { return "Syncing is paused. Resume it first." }
    if msg.hasPrefix("notfound:") { return "The server no longer has that version." }
    return msg
}

struct EngineStatus: Codable, Equatable {
    var Connected = false
    var Accepted = false
    var Ready = false
    var Paused = false
    var Files = 0
    var Bytes: Int64 = 0
    var UploadsLeft = 0
    var UploadBytes: Int64 = 0
    var LastError = ""
    var DeviceID = ""
}

struct Conflict: Codable, Hashable, Identifiable {
    var Copy: String
    var Original: String
    var CopyBy: String
    var When: Date
    /// The two versions side by side (absent from older engines).
    var CopyEntry: Entry?
    var OriginalEntry: Entry?
    var id: String { Copy }
    var fileName: String { (Original as NSString).lastPathComponent }
}

struct DeviceInfo: Codable, Hashable, Identifiable {
    var ID: String
    var Name: String
    var ThisOne: Bool
    var Hub: Bool
    var id: String { self.ID }
}

enum Keep: Int { case both = 0, original = 1, copy = 2 }

/// Decodes the engine's JSON (Go's time.Time is RFC 3339 with fractions).
let engineDecoder: JSONDecoder = {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .custom { dec in
        let s = try dec.singleValueContainer().decode(String.self)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = f.date(from: s) { return date }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s) ?? Date(timeIntervalSince1970: 0)
    }
    return d
}()

/// The device's Magpie config (hub, folder, password, invite key) as the
/// engine's JSON, kept in the shared keychain group.
enum ConfigStore {
    private static let account = "magpie-config"

    static func load() -> String? {
        var q = base()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ json: String) -> Bool {
        SecItemDelete(base() as CFDictionary)
        var q = base()
        q[kSecValueData as String] = Data(json.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    /// Replaces the kept config in place (no moment without one, which the
    /// extension might read).
    @discardableResult
    static func update(_ json: String) -> Bool {
        SecItemUpdate(base() as CFDictionary, [kSecValueData as String: Data(json.utf8)] as CFDictionary) == errSecSuccess
    }

    static func clear() { SecItemDelete(base() as CFDictionary) }

    private static func base() -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dev.mandip.magpie",
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: Magpie.keychainGroup,
        ]
        #if os(macOS)
        q[kSecUseDataProtectionKeychain as String] = true
        #endif
        return q
    }
}

/// A short human size: "6.2 GB".
func humanBytes(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}

/// "Today at 14:02", "Yesterday at 9:15", "Oct 12 at 18:40".
func friendlyTime(_ d: Date) -> String {
    let cal = Calendar.current
    let time = d.formatted(date: .omitted, time: .shortened)
    if cal.isDateInToday(d) { return "Today at \(time)" }
    if cal.isDateInYesterday(d) { return "Yesterday at \(time)" }
    let day = cal.isDate(d, equalTo: .now, toGranularity: .year)
        ? d.formatted(.dateTime.month(.abbreviated).day())
        : d.formatted(.dateTime.month(.abbreviated).day().year())
    return "\(day) at \(time)"
}

/// A conflict side's time and size, e.g. "Today at 14:02, 182 KB".
func versionLine(_ e: Entry?, fallback: Date) -> String {
    guard let e, e.Modified.timeIntervalSince1970 > 0 else { return friendlyTime(fallback) }
    return "\(friendlyTime(e.Modified)), \(humanBytes(e.Size))"
}
